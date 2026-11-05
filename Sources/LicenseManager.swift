import Foundation
import Combine
import SystemConfiguration

/// The license keys on this Mac and what they unlock.
///
/// Each key unlocks one tier: Firefox, Safari, or Mixed for both. A Polar
/// key's tier comes from the benefit it was sold under; a Pro key bought on
/// Gumroad before the tiers counts as Mixed. The keys add up per browser, and
/// a browser none of them covers follows the free plan: the shared quota
/// below, and removal after a week.
///
/// Every launch checks each key with its store. A key the store turns down is
/// dropped. A key that can't be checked keeps working for 14 days from its
/// last good check, so a flaky network never locks a paying user out.
@MainActor
final class LicenseManager: ObservableObject {
    static let shared = LicenseManager()

    @Published private(set) var keys: [StoredKey]
    /// What the keys unlock between them. Set from the saved keys at launch,
    /// so a paying user's menu and badges are right before the check answers;
    /// the check can only take keys away.
    @Published private(set) var entitlements: Entitlements
    /// Whether the launch check has an answer yet.
    @Published private(set) var hasLaunchAnswer = false
    @Published private(set) var isAddingKey = false
    /// What the launch check wants the user to know: a key it dropped, or one
    /// it couldn't check for too long.
    @Published private(set) var problem: String?

    private let store: LicenseStore
    private let polar: PolarLicensing
    private let gumroad: GumroadLicensing
    private let benefitIds: [LicenseTier: String]
    private let defaults: UserDefaults
    private let now: () -> Date
    private let macName: () -> String
    /// Keys on their way in, so pasting one twice can't use up a second
    /// activation.
    private var keysBeingAdded: Set<String> = []

    init(store: LicenseStore = .live, polar: PolarLicensing = PolarClient.live,
         gumroad: GumroadLicensing = GumroadClient(),
         benefitIds: [LicenseTier: String] = PolarConfig.benefitIds,
         defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
         macName: @escaping () -> String = LicenseManager.computerName) {
        self.store = store
        self.polar = polar
        self.gumroad = gumroad
        self.benefitIds = benefitIds
        self.defaults = defaults
        self.now = now
        self.macName = macName
        let keys = store.load()
        self.keys = keys
        entitlements = Self.unlocked(by: keys, at: now())
    }

    /// What the keys still within their grace unlock between them.
    private static func unlocked(by keys: [StoredKey], at date: Date) -> Entitlements {
        Entitlements(tiers: keys.filter { $0.isUsable(at: date) }.map(\.tier))
    }

    // MARK: - Free plan

    /// Free conversions per Mac, shared by every browser no key covers.
    let freeQuota = 2

    /// Monotonic count of conversions spent on the free plan. Soft
    /// (UserDefaults) — a prefs wipe resets it, but that only buys 2 more free
    /// conversions before the wall returns. Move it to a server only if
    /// free-plan abuse proves material.
    private(set) var freeConversionsUsed: Int {
        get { defaults.integer(forKey: "freeConversionsUsed") }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: "freeConversionsUsed")
        }
    }

    /// Free conversions left before the paywall (0 once exhausted).
    var freeConversionsRemaining: Int { max(0, freeQuota - freeConversionsUsed) }

    /// Whether a key covers this browser, so it converts with no limit.
    func unlimited(_ browser: Browser) -> Bool { entitlements.unlimited(browser) }

    /// The gate a conversion checks: a covered browser always passes, any
    /// other until the free quota is spent.
    func canConvert(_ browser: Browser) -> Bool {
        unlimited(browser) || freeConversionsRemaining > 0
    }

    /// Spend one free conversion. Does nothing for a browser a key covers.
    func recordFreeConversion(_ browser: Browser) {
        guard !unlimited(browser) else { return }
        freeConversionsUsed += 1
    }

    // MARK: - Launch check

    /// Starts the launch check.
    func bootstrap() {
        Task { await validateStoredKeys() }
    }

    /// Checks every key with its store, all at once, so the launch waits for
    /// the slowest answer rather than the sum.
    func validateStoredKeys() async {
        problem = nil
        guard !keys.isEmpty else {
            hasLaunchAnswer = true
            return
        }
        let checked = keys
        let polar = self.polar, gumroad = self.gumroad, benefitIds = self.benefitIds
        let answers = await withTaskGroup(of: (String, Answer).self) { group -> [String: Answer] in
            for key in checked {
                group.addTask { (key.key, await Self.check(key, polar: polar, gumroad: gumroad, benefitIds: benefitIds)) }
            }
            var answers: [String: Answer] = [:]
            for await (key, answer) in group { answers[key] = answer }
            return answers
        }

        // By key string, so a key added or removed while the checks ran is
        // left alone. In list order, so the problem shown is the first
        // failing key's, whichever answer arrived first.
        let date = now()
        for key in checked {
            guard let answer = answers[key.key], let i = keys.firstIndex(where: { $0.key == key.key }) else { continue }
            switch answer {
            case .good(let tier):
                keys[i].tier = tier
                keys[i].lastValidated = date
            case .refused(let reason):
                let message = "Your \(keys[i].tier.displayName) license key no longer works on this Mac."
                keys.remove(at: i)
                problem = problem ?? reason.map { "\(message) \($0)" } ?? message
            case .unanswered:
                if !keys[i].isUsable(at: date) {
                    problem = problem ?? "Couldn't check your license key for 14 days. Viaduct checks again the next time it opens with an internet connection."
                }
            }
        }
        store.save(keys)
        entitlements = Self.unlocked(by: keys, at: date)
        hasLaunchAnswer = true
    }

    /// What a store said about one key.
    private enum Answer {
        case good(LicenseTier)
        /// It turned the key down, in its own words when it gave some.
        case refused(String?)
        /// Nothing that settles it, so the key stays as it was.
        case unanswered
    }

    /// Asks the key's store about it. A Polar benefit that isn't in
    /// `benefitIds` counts as no answer: drift in the settings mustn't cost a
    /// paying user their key.
    private nonisolated static func check(_ key: StoredKey, polar: PolarLicensing, gumroad: GumroadLicensing,
                                          benefitIds: [LicenseTier: String]) async -> Answer {
        do {
            switch key.provider {
            case .polar:
                let benefitId = try await polar.validate(key: key.key, activationId: key.activationId)
                return LicenseTier(benefitId: benefitId, in: benefitIds).map(Answer.good) ?? .unanswered
            case .gumroad:
                try await gumroad.verify(key: key.key)
                return .good(.mixed)
            }
        } catch LicenseError.rejected(let message) {
            return .refused(message)
        } catch LicenseError.unknownKey {
            return .refused(nil)
        } catch {
            return .unanswered
        }
    }

    // MARK: - Adding and removing keys

    /// Adds a key the user typed or pasted. Polar activates it for this Mac.
    /// A key Polar has never heard of can still be a Pro key from Gumroad,
    /// which counts as Mixed. Throws a `LicenseError`.
    func addKey(_ typed: String) async throws {
        let key = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw LicenseError.unknownKey }
        guard !keys.contains(where: { $0.key == key }), !keysBeingAdded.contains(key) else {
            throw LicenseError.alreadyAdded
        }
        keysBeingAdded.insert(key)
        isAddingKey = true
        defer {
            keysBeingAdded.remove(key)
            isAddingKey = !keysBeingAdded.isEmpty
        }

        let added: StoredKey
        do {
            let activation = try await polar.activate(key: key, label: macName())
            guard let tier = LicenseTier(benefitId: activation.benefitId, in: benefitIds) else {
                // A key for another product on the same Polar account.
                try? await polar.deactivate(key: key, activationId: activation.activationId)
                throw LicenseError.notForViaduct
            }
            added = StoredKey(provider: .polar, key: key, activationId: activation.activationId, tier: tier,
                              lastValidated: now())
        } catch LicenseError.unknownKey {
            do {
                try await gumroad.verify(key: key)
            } catch LicenseError.rejected {
                throw LicenseError.unknownKey
            }
            added = StoredKey(provider: .gumroad, key: key, activationId: nil, tier: .mixed, lastValidated: now())
        }
        keys.append(added)
        store.save(keys)
        entitlements = Self.unlocked(by: keys, at: now())
        problem = nil
    }

    /// Forgets a key on this Mac. A Polar key gives its activation back
    /// first, so it can go on another Mac, and goes anyway when Polar can't
    /// be reached. Gumroad has nothing to give back.
    func removeKey(_ key: StoredKey) async {
        if key.provider == .polar, let activationId = key.activationId {
            try? await polar.deactivate(key: key.key, activationId: activationId)
        }
        keys.removeAll { $0.key == key.key }
        store.save(keys)
        entitlements = Self.unlocked(by: keys, at: now())
    }

    // MARK: - Checkout

    /// Where a Buy link was clicked, reported with the purchase.
    enum CheckoutSource: String {
        case paywall, settings
    }

    /// The tier's Polar checkout, or nil when this build has none. The utm_*
    /// items are anonymous usage counts; Polar attaches them to the checkout's
    /// metadata, which carries over to the order. Keep this list in sync with
    /// the privacy page.
    func checkoutURL(for tier: LicenseTier, source: CheckoutSource, extensionCount: Int) -> URL? {
        guard let link = PolarConfig.checkoutURLs[tier],
              var components = URLComponents(url: link, resolvingAgainstBaseURL: false) else { return nil }
        let installed = try? LicenseStore.supportDir.resourceValues(forKeys: [.creationDateKey]).creationDate
        let days = installed.flatMap { Calendar.current.dateComponents([.day], from: $0, to: now()).day } ?? 0
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let os = ProcessInfo.processInfo.operatingSystemVersion
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "utm_source", value: "app"),
            URLQueryItem(name: "utm_medium", value: source.rawValue),
            URLQueryItem(name: "utm_content",
                         value: "conversions-\(freeConversionsUsed)_installed-\(extensionCount)_days-\(max(0, days))"),
            URLQueryItem(name: "utm_term", value: "app-\(version)_macos-\(os.majorVersion).\(os.minorVersion)"),
        ]
        return components.url
    }

    // MARK: - This Mac

    /// The Mac's name from Sharing settings, the label its Polar activation
    /// goes by. Not `Host.current().localizedName`, which can block on the
    /// network.
    nonisolated static func computerName() -> String {
        guard let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty else { return "Mac" }
        return name
    }
}
