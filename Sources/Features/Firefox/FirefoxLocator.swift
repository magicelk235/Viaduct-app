import AppKit

/// Finds the Firefox a conversion installs into.
enum FirefoxLocator {
    struct Install: Equatable {
        let bundleID: String
        let appURL: URL
        let displayName: String
        let version: String?
    }

    /// Checked in this order. Release, Beta and ESR all share the first id.
    static let bundleIDs = ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"]
    static let downloadURL = URL(string: "https://www.mozilla.org/firefox/new/")!

    static func find(lookup: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }) -> Install? {
        for bundleID in bundleIDs {
            guard let appURL = lookup(bundleID) else { continue }
            return Install(
                bundleID: bundleID,
                appURL: appURL,
                displayName: appURL.deletingPathExtension().lastPathComponent,
                version: Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            )
        }
        return nil
    }

    static func open(_ install: Install) {
        NSWorkspace.shared.openApplication(at: install.appURL, configuration: NSWorkspace.OpenConfiguration())
    }
}
