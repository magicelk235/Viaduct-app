import Foundation

/// The one call conversion paths make to bring an extension's Chrome settings
/// along: finds them, and if there are any, swaps the input for a copy that
/// seeds them on first run. Never fails the conversion over it; the worst case
/// is converting without settings, with a note saying why.
enum SettingsCarryOver {
    /// Blocking (reads LevelDB, copies the extension); call off the main thread.
    static func apply(to source: URL, chromeId: String, profile: BrowserProfile?,
                      name: String) -> (url: URL, note: String?) {
        guard let from = profile ?? ExtensionSettingsTransfer.locate(chromeId: chromeId) else {
            // Nothing found reads the same as "macOS said no", so say which.
            let blocked = BrowserProfiles.blocked()
            guard !blocked.isEmpty else { return (source, nil) }
            return (source, "Settings stay behind: macOS isn't letting Viaduct read \(blocked[0].name). Allow it under Privacy & Security → Full Disk Access.")
        }
        do {
            let snapshot = try ExtensionSettingsTransfer.snapshot(chromeId: chromeId, profile: from)
            guard !snapshot.isEmpty else { return (source, nil) }
            let seeded = try ExtensionSettingsTransfer.stageWithSeed(source: source, snapshot: snapshot, name: name)
            let count = snapshot.local.count + snapshot.sync.count
            return (seeded, "Bringing \(count) saved setting\(count == 1 ? "" : "s") over from \(from.browser.name)")
        } catch {
            return (source, "Settings stay behind: \(error.localizedDescription)")
        }
    }
}
