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

    /// Where every Firefox keeps its profiles, and profiles.ini, the list of them.
    static var dataFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Firefox", isDirectory: true)
    }

    /// Firefox's folder is there, but Viaduct may not read it or the profile
    /// list in it. Until Viaduct has Full Disk Access, macOS can answer EPERM
    /// for another app's data, and persist then lists no profiles. A folder
    /// that isn't there is a Firefox that has never run.
    static func dataBlocked(at folder: URL = dataFolder) -> Bool {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            _ = try Data(contentsOf: folder.appendingPathComponent("profiles.ini"))
            return false
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            // EPERM and EACCES both come out as this.
            return true
        } catch {
            return false
        }
    }
}
