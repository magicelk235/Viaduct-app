import Foundation

/// Chromium-based browsers whose profiles Viaduct can read extensions and
/// extension storage from. All of them use Chrome's on-disk layout.
enum ChromiumBrowser: String, CaseIterable, Identifiable {
    case chrome, chromeBeta, chromeCanary, chromium, brave, edge, arc, vivaldi, opera

    var id: String { rawValue }

    var name: String {
        switch self {
        case .chrome:       return "Chrome"
        case .chromeBeta:   return "Chrome Beta"
        case .chromeCanary: return "Chrome Canary"
        case .chromium:     return "Chromium"
        case .brave:        return "Brave"
        case .edge:         return "Edge"
        case .arc:          return "Arc"
        case .vivaldi:      return "Vivaldi"
        case .opera:        return "Opera"
        }
    }

    /// Path under ~/Library/Application Support.
    private var relativePath: String {
        switch self {
        case .chrome:       return "Google/Chrome"
        case .chromeBeta:   return "Google/Chrome Beta"
        case .chromeCanary: return "Google/Chrome Canary"
        case .chromium:     return "Chromium"
        case .brave:        return "BraveSoftware/Brave-Browser"
        case .edge:         return "Microsoft Edge"
        case .arc:          return "Arc/User Data"
        case .vivaldi:      return "Vivaldi"
        case .opera:        return "com.operasoftware.Opera"
        }
    }

    var userDataDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(relativePath, isDirectory: true)
    }

    /// Edge and Opera run their own add-on stores, so an id from them can't be
    /// assumed to exist on the Chrome Web Store.
    var usesChromeWebStore: Bool {
        self != .edge && self != .opera
    }
}

/// One browser profile directory ("Default", "Profile 1", …).
struct BrowserProfile: Identifiable, Hashable {
    let browser: ChromiumBrowser
    let directory: URL
    /// The name the user gave the profile, from the browser's Local State.
    let profileName: String

    var id: String { directory.path }

    /// "Chrome" for a browser's only profile, "Chrome — Work" otherwise.
    func label(among all: [BrowserProfile]) -> String {
        let siblings = all.filter { $0.browser == browser }.count
        return siblings > 1 ? "\(browser.name) — \(profileName)" : browser.name
    }

    var extensionsDir: URL { directory.appendingPathComponent("Extensions", isDirectory: true) }
    var localSettingsDir: URL { directory.appendingPathComponent("Local Extension Settings", isDirectory: true) }
    var syncSettingsDir: URL { directory.appendingPathComponent("Sync Extension Settings", isDirectory: true) }
}

enum BrowserProfiles {
    /// Every profile of every installed Chromium browser that has an
    /// Extensions folder, in browser order.
    static func all() -> [BrowserProfile] {
        ChromiumBrowser.allCases.flatMap(profiles(of:))
    }

    /// Browsers with a data folder on this Mac, whether or not Viaduct may
    /// read it. A bare existence check, which never triggers the privacy prompt.
    static func installed() -> [ChromiumBrowser] {
        ChromiumBrowser.allCases.filter { FileManager.default.fileExists(atPath: $0.userDataDir.path) }
    }

    /// Browsers whose folder exists but macOS won't let Viaduct list. Recent
    /// macOS guards every app's data behind an "access data from other apps"
    /// consent; until the user allows it, every read fails with EPERM, which
    /// otherwise looks exactly like a browser with no extensions.
    static func blocked() -> [ChromiumBrowser] {
        installed().filter { browser in
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: browser.userDataDir.path)
                return false
            } catch let error as CocoaError where error.code == .fileReadNoPermission {
                return true
            } catch {
                return false
            }
        }
    }

    /// Where to send someone who said no. Full Disk Access covers other apps'
    /// data and, unlike the one-time prompt, can be turned on after a denial.
    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!

    static func profiles(of browser: ChromiumBrowser) -> [BrowserProfile] {
        let fm = FileManager.default
        let root = browser.userDataDir
        guard fm.fileExists(atPath: root.path) else { return [] }

        // Opera keeps a single profile directly in its user-data dir.
        if fm.fileExists(atPath: root.appendingPathComponent("Extensions").path),
           !fm.fileExists(atPath: root.appendingPathComponent("Default").path) {
            return [BrowserProfile(browser: browser, directory: root, profileName: browser.name)]
        }

        let names = profileNames(root: root)
        let entries = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        return entries
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
            .sorted { a, b in
                // Default first, then Profile 1, Profile 2, … numerically.
                if a == "Default" { return b != "Default" }
                if b == "Default" { return false }
                return a.localizedStandardCompare(b) == .orderedAscending
            }
            .map { root.appendingPathComponent($0, isDirectory: true) }
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("Extensions").path) }
            .map { dir in
                BrowserProfile(browser: browser, directory: dir,
                               profileName: names[dir.lastPathComponent] ?? dir.lastPathComponent)
            }
    }

    /// Profile dir name → display name, from Local State's profile.info_cache.
    private static func profileNames(root: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("Local State")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = obj["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (dir, info) in cache {
            if let name = (info as? [String: Any])?["name"] as? String, !name.isEmpty {
                out[dir] = name
            }
        }
        return out
    }
}
