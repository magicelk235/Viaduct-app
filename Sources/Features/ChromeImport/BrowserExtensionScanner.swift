import Foundation
import AppKit

/// An extension found in a Chromium browser profile, ready to offer for import.
struct InstalledBrowserExtension: Identifiable, Hashable {
    /// 32-character a–p extension id.
    let chromeId: String
    let profile: BrowserProfile
    /// Manifest name with any __MSG_ placeholder resolved.
    let name: String
    let version: String
    /// The version folder the browser is running, or the unpacked source path.
    let folder: URL
    /// Best icon as PNG. Kept as Data so the struct stays cheap to hash.
    let iconPNG: Data?
    /// The id can be looked up on the Chrome Web Store.
    let fromWebStore: Bool
    let enabled: Bool
    /// Loaded with "Load unpacked" (or --load-extension).
    let unpacked: Bool
    /// The extension has chrome.storage data in Local/Sync Extension Settings.
    let hasStoredSettings: Bool

    var id: String { profile.id + "/" + chromeId }
}

enum BrowserExtensionScanner {

    enum StageError: LocalizedError {
        case missingSource(URL)

        var errorDescription: String? {
            switch self {
            case .missingSource(let url):
                return "The extension folder at \(url.path) no longer exists."
            }
        }
    }

    /// Every user-installed extension across all Chromium browser profiles. Blocking; call off the main thread.
    static func scan() -> [InstalledBrowserExtension] {
        // all() is already in browser order with Default first inside each
        // browser, so sorting by name per profile gives the full ordering.
        BrowserProfiles.all().flatMap { profile in
            scan(profile: profile).sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    /// Copy an installed extension into Caches/Viaduct/import/<chromeId>/ (replacing any old copy), dropping Chrome-only bits (`_metadata/`, Chrome's verified_contents), so the CLI gets a clean unpacked folder with no version-suffixed name. Returns the staged folder.
    static func stage(_ ext: InstalledBrowserExtension) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: ext.folder.appendingPathComponent("manifest.json").path) else {
            throw StageError.missingSource(ext.folder)
        }
        let importDir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Viaduct", isDirectory: true)
            .appendingPathComponent("import", isDirectory: true)
        try fm.createDirectory(at: importDir, withIntermediateDirectories: true)

        let dest = importDir.appendingPathComponent(ext.chromeId, isDirectory: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: ext.folder, to: dest)
        StagedFolder.makeOwnerWritable(dest)

        // _metadata holds the Web Store's signed hashes (verified_contents.json,
        // computed_hashes.json). They describe Chrome's copy, go stale as soon
        // as the converter touches a file, and Safari has no use for them.
        // Very old installs kept verified_contents.json at the top level.
        for leftover in ["_metadata", "verified_contents.json"] {
            let url = dest.appendingPathComponent(leftover)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
        return dest
    }

    // MARK: - Per profile

    /// Chrome's Manifest::Location values that matter here.
    private enum Location {
        static let unpacked = 4
        static let component = 5
        static let commandLine = 8      // --load-extension, also an unpacked folder
        static let externalComponent = 10
    }

    /// Ids that ship with the browser rather than being chosen by the user.
    /// Most are also flagged was_installed_by_default or component, but older
    /// profiles don't always carry those flags.
    private static let builtInIds: Set<String> = [
        "nmmhkkegccagdldgiimedpiccmgmieda", // Chrome Web Store Payments
        "ghbmnnjooekpmoecnnnilnnbdlolhkhi", // Google Docs Offline
        "ahfgeienlihckogmohjhadlkjgocpleb", // Web Store app
        "mhjfbmdgcfjbbpaeojofohoefgiehjai", // Chrome PDF Viewer
        "nkeimhogjdpnpccoofpliimaahmaaome", // Hangouts services
    ]

    private static func scan(profile: BrowserProfile) -> [InstalledBrowserExtension] {
        let fm = FileManager.default
        let settings = extensionSettings(profile: profile)

        var ids = Set((try? fm.contentsOfDirectory(atPath: profile.extensionsDir.path)) ?? [])
            .filter(isExtensionId)
        // Unpacked extensions live wherever the developer keeps them, so the
        // only record of them is in Preferences.
        for (id, entry) in settings ?? [:] where isUnpacked(entry) && entry["path"] is String {
            ids.insert(id)
        }

        return ids.compactMap { id in
            let entry = settings?[id]
            // Chrome deletes an uninstalled extension's folder on the next
            // launch; until then it's on disk but gone from Preferences.
            if let settings, !settings.isEmpty, entry == nil { return nil }
            return makeExtension(id: id, entry: entry ?? [:], profile: profile)
        }
    }

    private static func makeExtension(id: String, entry: [String: Any],
                                      profile: BrowserProfile) -> InstalledBrowserExtension? {
        if builtInIds.contains(id) { return nil }
        if entry["was_installed_by_default"] as? Bool == true { return nil }
        if let location = entry["location"] as? Int,
           location == Location.component || location == Location.externalComponent {
            return nil
        }

        let unpacked = isUnpacked(entry)
        guard let folder = unpacked
                ? unpackedFolder(entry: entry, profile: profile)
                : installedFolder(id: id, entry: entry, profile: profile),
              let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              manifest["name"] is String
        else { return nil }

        // Themes and hosted/packaged apps aren't extensions Safari can run.
        if manifest["theme"] != nil || manifest["app"] != nil { return nil }

        let info = ExtensionInspector.inspectSync(path: folder.path)
        let version = info?.version
            ?? (manifest["version"] as? String)
            ?? folder.lastPathComponent
        let name = info?.name ?? (manifest["name"] as? String) ?? id

        return InstalledBrowserExtension(
            chromeId: id,
            profile: profile,
            name: name,
            version: version,
            folder: folder,
            iconPNG: info?.icon?.pngData(),
            fromWebStore: (entry["from_webstore"] as? Bool)
                ?? (!unpacked && profile.browser.usesChromeWebStore),
            enabled: isEnabled(entry),
            unpacked: unpacked,
            hasStoredSettings: hasStoredData(id: id, profile: profile)
        )
    }

    // MARK: - Preferences

    /// extensions.settings merged from Preferences and Secure Preferences.
    /// Recent Chrome keeps nearly everything in Secure Preferences; older
    /// builds and some forks still use Preferences. nil when neither file has
    /// the dictionary, so callers can tell "no record" from "unknown".
    private static func extensionSettings(profile: BrowserProfile) -> [String: [String: Any]]? {
        var merged: [String: [String: Any]]?
        for file in ["Preferences", "Secure Preferences"] {
            guard let data = try? Data(contentsOf: profile.directory.appendingPathComponent(file)),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let extensions = root["extensions"] as? [String: Any],
                  let settings = extensions["settings"] as? [String: Any]
            else { continue }
            var result = merged ?? [:]
            for (id, value) in settings {
                guard let entry = value as? [String: Any] else { continue }
                // Secure Preferences is read second, so its keys win.
                result[id, default: [:]].merge(entry) { _, new in new }
            }
            merged = result
        }
        return merged
    }

    private static func isUnpacked(_ entry: [String: Any]) -> Bool {
        guard let location = entry["location"] as? Int else { return false }
        return location == Location.unpacked || location == Location.commandLine
    }

    /// Older Chrome writes `state` (0 disabled, 1 enabled) next to a
    /// disable_reasons bitmask; current Chrome drops `state` and stores
    /// disable_reasons as a list. Any reason at all means it's off.
    private static func isEnabled(_ entry: [String: Any]) -> Bool {
        if let state = entry["state"] as? Int, state == 0 { return false }
        if let reasons = entry["disable_reasons"] as? [Any], !reasons.isEmpty { return false }
        if let reasons = entry["disable_reasons"] as? Int, reasons != 0 { return false }
        return true
    }

    // MARK: - Folders

    private static func unpackedFolder(entry: [String: Any], profile: BrowserProfile) -> URL? {
        guard let path = entry["path"] as? String, !path.isEmpty else { return nil }
        let url = path.hasPrefix("/")
            ? URL(fileURLWithPath: path, isDirectory: true)
            : profile.extensionsDir.appendingPathComponent(path, isDirectory: true)
        return url.standardizedFileURL
    }

    /// The version folder Preferences says is live, falling back to the
    /// newest one on disk (an update can leave the old folder behind until
    /// the next restart).
    private static func installedFolder(id: String, entry: [String: Any],
                                        profile: BrowserProfile) -> URL? {
        let fm = FileManager.default
        let idDir = profile.extensionsDir.appendingPathComponent(id, isDirectory: true)

        if let path = entry["path"] as? String, !path.isEmpty, !path.hasPrefix("/") {
            let url = profile.extensionsDir.appendingPathComponent(path, isDirectory: true)
            if fm.fileExists(atPath: url.appendingPathComponent("manifest.json").path) {
                return url
            }
        }

        let versions = ((try? fm.contentsOfDirectory(atPath: idDir.path)) ?? [])
            .filter { !$0.hasPrefix(".") && $0 != "Temp" }
            .filter { fm.fileExists(atPath: idDir.appendingPathComponent($0).appendingPathComponent("manifest.json").path) }
        guard let newest = versions.max(by: { versionKey($0).lexicographicallyPrecedes(versionKey($1)) })
        else { return nil }
        return idDir.appendingPathComponent(newest, isDirectory: true)
    }

    /// "1.2.10_0" → [1, 2, 10, 0, …] padded so 1.2 and 1.2.0 compare equal and
    /// the install-counter suffix only breaks ties.
    private static func versionKey(_ folder: String) -> [Int] {
        let parts = folder.split(separator: "_", maxSplits: 1)
        var numbers = (parts.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
        while numbers.count < 4 { numbers.append(0) }
        let suffix = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        return numbers + [suffix]
    }

    private static func isExtensionId(_ s: String) -> Bool {
        s.utf8.count == 32 && s.utf8.allSatisfy { $0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "p") }
    }

    // MARK: - Storage

    /// chrome.storage.local / .sync live in per-extension LevelDB folders. A
    /// fresh LevelDB has only an empty .log, so look for a .ldb or .log with
    /// actual bytes in it.
    private static func hasStoredData(id: String, profile: BrowserProfile) -> Bool {
        let fm = FileManager.default
        for base in [profile.localSettingsDir, profile.syncSettingsDir] {
            let dir = base.appendingPathComponent(id, isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
            else { continue }
            for file in files where file.pathExtension == "ldb" || file.pathExtension == "log" {
                if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
                    return true
                }
            }
        }
        return false
    }
}
