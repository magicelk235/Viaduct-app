import Foundation
import Combine

/// Gates the app behind a Gumroad license key.
///
/// Flow: user pastes a key → `activate` calls Gumroad's license verify
/// endpoint. On success we store the key in the Keychain. Every launch we
/// re-verify, but a previously-verified key keeps working offline via the
/// cached timestamp so a flaky network never locks a paying user out.
///
/// Gumroad license API: https://docs.gumroad.com/#verify-a-license
/// POST https://api.gumroad.com/v2/licenses/verify
///   product_id=<id>&license_key=<key>&increment_uses_count=false
/// Returns: { success, uses, purchase:{ refunded, disputed, chargebacked, ... } }
@MainActor
final class LicenseManager: ObservableObject {
    static let shared = LicenseManager()

    // MARK: - Config (fill in from your Gumroad product)

    /// Gumroad product ID — stable even if you rename the product URL slug.
    /// From the product's Settings/Advanced page.
    private let productID = "-7WMe9QfKNdzB5rmGZjMdw=="

    /// Optional hard cap on activations per key. Gumroad increments `uses` each
    /// verify; we only bump it on first activation. 0 = unlimited.
    private let maxActivations = 0

    // MARK: - Published state

    enum State: Equatable {
        case unknown          // still checking on launch
        case unlicensed       // no key, show activation
        case licensed         // good to go
        case checking         // network call in flight
    }

    @Published private(set) var state: State = .unknown
    @Published var lastError: String?
    /// Whether the launch check has an answer yet. Separate from `state`,
    /// which also reads `.checking` while a typed key is being verified.
    @Published private(set) var hasLaunchAnswer = false

    // MARK: - License storage
    //
    // Stored in a plain file under Application Support, NOT the Keychain. The
    // Keychain binds an item to the build's code signature, so every re-signed
    // release/auto-update triggered a login-password prompt; the
    // `keychain-access-groups` entitlement that would fix that is restricted to
    // provisioning-profile builds (a plain Developer ID app can't claim it — it
    // fails to launch). A Gumroad license key isn't a secret worth that
    // friction, so a file it is. File over Keychain — the key is a
    // purchase receipt, not a password.

    /// ~/Library/Application Support/Viaduct. Its creation date doubles as the
    /// install date: the CLI is installed there on first launch.
    private static let supportDir: URL =
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Viaduct", isDirectory: true)

    /// ~/Library/Application Support/Viaduct/license (created lazily on first write).
    private static let licenseFile = supportDir.appendingPathComponent("license")

    private var storedKey: String? {
        get {
            if let key = try? String(contentsOf: Self.licenseFile, encoding: .utf8), !key.isEmpty {
                return key
            }
            // One-time migration: pull a key an older build left in the Keychain,
            // then persist it to the file so we never touch the Keychain again.
            if let legacy = Keychain.readLegacyLicense() {
                Self.persist(legacy)
                return legacy
            }
            return nil
        }
        set { Self.persist(newValue) }
    }

    /// Write the key to the license file (nil/empty clears it). Static so the
    /// getter's migration path can call it without re-entering `storedKey`.
    private static func persist(_ value: String?) {
        guard let value, !value.isEmpty else {
            try? FileManager.default.removeItem(at: licenseFile)
            return
        }
        try? FileManager.default.createDirectory(at: licenseFile.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? value.write(to: licenseFile, atomically: true, encoding: .utf8)
    }

    /// Last time a server verification succeeded — used for the offline grace window.
    private var lastValidEpoch: Double {
        get { UserDefaults.standard.double(forKey: "license-last-valid") }
        set { UserDefaults.standard.set(newValue, forKey: "license-last-valid") }
    }

    /// How long a cached-valid license keeps working with no network.
    private let offlineGraceDays: Double = 14

    private let verifyURL = URL(string: "https://api.gumroad.com/v2/licenses/verify")!

    var isLicensed: Bool { state == .licensed }

    // MARK: - Free tier (freemium)

    /// How many conversions an unlicensed user gets before the hard lock.
    let freeQuota = 2

    /// Monotonic count of conversions an unlicensed user has spent. Soft
    /// (UserDefaults) — a prefs wipe resets it, but that only buys 2 more free
    /// signed conversions before the wall returns. Soft counter, move
    /// to StoreKit/server only if free-tier abuse proves material.
    private(set) var freeConversionsUsed: Int {
        get { UserDefaults.standard.integer(forKey: "freeConversionsUsed") }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: "freeConversionsUsed")
        }
    }

    /// Free conversions left before the paywall (0 once exhausted).
    var freeConversionsRemaining: Int { max(0, freeQuota - freeConversionsUsed) }

    /// The gate `userConvert()` checks: licensed users always pass; unlicensed
    /// users pass until they've spent their free quota.
    var canConvert: Bool { isLicensed || freeConversionsRemaining > 0 }

    /// Spend one free conversion. No-op for licensed users (unlimited).
    func recordFreeConversion() {
        guard !isLicensed else { return }
        freeConversionsUsed += 1
    }

    // MARK: - Checkout

    /// Where a Buy link was clicked, reported with the purchase.
    enum CheckoutSource: String {
        case paywall, settings
    }

    /// Gumroad checkout link. `wanted=true` skips the product page and opens
    /// the payment form. The other query items are anonymous usage counts;
    /// Gumroad attaches them to the sale as `url_params`. Keep this list in
    /// sync with the privacy page.
    func checkoutURL(source: CheckoutSource, extensionCount: Int) -> URL {
        var items = [
            URLQueryItem(name: "wanted", value: "true"),
            URLQueryItem(name: "conversions", value: String(freeConversionsUsed)),
            URLQueryItem(name: "installed", value: String(extensionCount)),
        ]
        if let created = try? Self.supportDir.resourceValues(forKeys: [.creationDateKey]).creationDate {
            let days = Calendar.current.dateComponents([.day], from: created, to: Date()).day ?? 0
            items.append(URLQueryItem(name: "days", value: String(max(0, days))))
        }
        items.append(URLQueryItem(name: "source", value: source.rawValue))
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            items.append(URLQueryItem(name: "app", value: version))
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        items.append(URLQueryItem(name: "macos", value: "\(os.majorVersion).\(os.minorVersion)"))

        var components = URLComponents(string: "https://magicelk235.gumroad.com/l/viaduct")!
        components.queryItems = items
        return components.url!
    }

    // MARK: - Launch check

    /// Decide initial state. If we have a stored key, re-verify online;
    /// fall back to the offline grace window when the network is down.
    func bootstrap() {
        guard let key = storedKey, !key.isEmpty else {
            state = .unlicensed
            hasLaunchAnswer = true
            return
        }
        state = .checking
        Task {
            defer { hasLaunchAnswer = true }
            do {
                // Don't bump the uses counter on a routine launch re-check.
                try await verify(key: key, incrementUses: false)
                lastValidEpoch = Date().timeIntervalSince1970
                state = .licensed
            } catch let e as LicenseError where e.serverSaidNo {
                // Server reached us and rejected it (refunded/disputed/invalid).
                clear()
                state = .unlicensed
                lastError = e.message
            } catch {
                // Network failure — honor the offline grace window.
                if withinOfflineGrace() {
                    state = .licensed
                } else {
                    state = .unlicensed
                    lastError = "Couldn't verify your license and the offline grace period expired. Reconnect and try again."
                }
            }
        }
    }

    private func withinOfflineGrace() -> Bool {
        guard lastValidEpoch > 0 else { return false }
        let age = Date().timeIntervalSince1970 - lastValidEpoch
        return age < offlineGraceDays * 86_400
    }

    // MARK: - Activate (first-run key entry)

    func activate(key rawKey: String) {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { lastError = "Enter a license key."; return }
        lastError = nil
        state = .checking
        Task {
            do {
                // First activation: bump the uses counter so we can enforce a cap.
                try await verify(key: key, incrementUses: maxActivations > 0)
                storedKey = key
                lastValidEpoch = Date().timeIntervalSince1970
                state = .licensed
            } catch let e as LicenseError {
                lastError = e.message
                state = .unlicensed
            } catch {
                lastError = "Activation failed: \(error.localizedDescription)"
                state = .unlicensed
            }
        }
    }

    func clear() {
        storedKey = nil
        lastValidEpoch = 0
    }

    /// Gumroad has no server-side deactivation; this just forgets the key locally
    /// so the user can enter a different one (e.g. moving machines).
    func deactivateAndClear() {
        clear()
        state = .unlicensed
    }

    // MARK: - Networking

    struct LicenseError: Error {
        let message: String
        /// True when the server explicitly rejected the key (vs a network failure).
        /// Drives whether bootstrap clears the stored key or applies offline grace.
        var serverSaidNo = false
    }

    /// POST /verify. Throws `LicenseError(serverSaidNo: true)` when Gumroad
    /// rejects the key, plain `LicenseError` / transport error otherwise.
    private func verify(key: String, incrementUses: Bool) async throws {
        let body = "product_id=\(enc(productID))"
            + "&license_key=\(enc(key))"
            + "&increment_uses_count=\(incrementUses ? "true" : "false")"

        var req = URLRequest(url: verifyURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = body.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        guard let http = resp as? HTTPURLResponse else {
            throw LicenseError(message: "No response from license server.")
        }

        let success = (json["success"] as? Bool) ?? false
        // Gumroad returns 404 + {success:false, message:"..."} for an unknown key.
        if !success {
            let msg = (json["message"] as? String) ?? "Invalid license key."
            throw LicenseError(message: msg, serverSaidNo: http.statusCode != 0 && http.statusCode < 500)
        }

        // Refunded / disputed / chargebacked purchases must lose access.
        if let purchase = json["purchase"] as? [String: Any] {
            for flag in ["refunded", "disputed", "chargebacked"] where (purchase[flag] as? Bool) == true {
                throw LicenseError(message: "This purchase was \(flag); the license is no longer valid.",
                                   serverSaidNo: true)
            }
            // Subscription products: reject if cancelled/ended.
            if let ended = purchase["subscription_ended_at"] as? String, !ended.isEmpty {
                throw LicenseError(message: "This subscription has ended.", serverSaidNo: true)
            }
        }

        // Optional activation cap.
        if maxActivations > 0, let uses = json["uses"] as? Int, uses > maxActivations {
            throw LicenseError(message: "This key has been activated on too many machines.",
                               serverSaidNo: true)
        }
    }

    private func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
}
