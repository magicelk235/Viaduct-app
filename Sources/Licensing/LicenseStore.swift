import Foundation
import Security

/// The license keys on this Mac, kept as a JSON list in licenses.json.
///
/// Stored in a plain file under Application Support, NOT the Keychain. The
/// Keychain binds an item to the build's code signature, so every re-signed
/// release/auto-update triggered a login-password prompt; the
/// `keychain-access-groups` entitlement that would fix that is restricted to
/// provisioning-profile builds (a plain Developer ID app can't claim it — it
/// fails to launch). A license key isn't a secret worth that friction, so a
/// file it is. File over Keychain — the key is a purchase receipt, not a
/// password.
///
/// 1.4.0 and earlier kept a single Gumroad key in `license` next to it, with
/// its last good check in the `license-last-valid` default. Both are only
/// read, for the migration, so an older Viaduct opened on the same Mac still
/// finds its key.
struct LicenseStore {
    let file: URL
    let legacyFile: URL
    let defaults: UserDefaults
    let legacyKeychainKey: () -> String?

    init(file: URL, legacyFile: URL? = nil, defaults: UserDefaults, legacyKeychainKey: @escaping () -> String?) {
        self.file = file
        self.legacyFile = legacyFile ?? file.deletingLastPathComponent().appendingPathComponent("license")
        self.defaults = defaults
        self.legacyKeychainKey = legacyKeychainKey
    }

    /// ~/Library/Application Support/Viaduct. Its creation date doubles as the
    /// install date: the CLI is installed there on first launch.
    static let supportDir: URL =
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Viaduct", isDirectory: true)

    static let live = LicenseStore(file: supportDir.appendingPathComponent("licenses.json"),
                                   legacyFile: supportDir.appendingPathComponent("license"),
                                   defaults: .standard,
                                   legacyKeychainKey: Keychain.readLegacyLicense)

    /// The saved keys, or the old single key when nothing has been saved yet.
    /// Never writes: the migration finishes on the first save.
    func load() -> [StoredKey] {
        if FileManager.default.fileExists(atPath: file.path) {
            // A list we can't read stays on disk untouched rather than being
            // treated as no keys and replaced by the old one.
            guard let data = try? Data(contentsOf: file) else { return [] }
            return (try? JSONDecoder().decode([StoredKey].self, from: data)) ?? []
        }
        var key = (try? String(contentsOf: legacyFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if key.isEmpty { key = legacyKeychainKey() ?? "" }
        guard !key.isEmpty else { return [] }
        return [StoredKey(provider: .gumroad, key: key, activationId: nil, tier: .mixed,
                          lastValidated: Date(timeIntervalSince1970: defaults.double(forKey: "license-last-valid")))]
    }

    /// Writes the list, empty or not, so a removed key doesn't come back from
    /// the old file. An existing list that can't be read is moved aside first.
    func save(_ keys: [StoredKey]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: file.path),
           (try? Data(contentsOf: file)).flatMap({ try? JSONDecoder().decode([StoredKey].self, from: $0) }) == nil {
            let aside = file.deletingLastPathComponent()
                .appendingPathComponent("\(file.lastPathComponent).unreadable-\(Int(Date().timeIntervalSince1970))")
            try? fm.moveItem(at: file, to: aside)
        }
        guard let data = try? JSONEncoder().encode(keys) else { return }
        try? data.write(to: file, options: .atomic)
    }
}

// MARK: - Legacy Keychain migration (read-only, one-time)

enum Keychain {
    /// Read a license key an older (Keychain-backed) build may have stored, so a
    /// paying user isn't logged out by the switch to file storage. Read-only:
    /// nothing new is ever written to the Keychain. Checks both service names
    /// ever used. Returns nil (no prompt) when no such item exists — the case
    /// for essentially everyone.
    static func readLegacyLicense() -> String? {
        for service in ["com.magicelk235.viaduct.license", "com.viaduct.app.license"] {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: "license-key",
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var out: AnyObject?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
               let data = out as? Data, let key = String(data: data, encoding: .utf8) {
                return key
            }
        }
        return nil
    }
}
