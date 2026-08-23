import AppKit
import SafariServices

/// The bundled Safari extension that puts an "Add to Safari" button on Chrome
/// Web Store pages. Safari keeps it off until the user enables it once in its
/// own settings, and nothing about the app makes that discoverable — so the
/// app tracks whether it's on and points the user at the checkbox.
///
/// Enabled-detection is a heartbeat, not SFSafariExtensionManager: that API
/// answers SFErrorNoExtensionFound for this web-extension appex even when
/// Safari runs it happily. Instead the extension's background worker sends a
/// "hello" native message every time Safari starts it — which Safari does
/// while (and only while) the extension is enabled — and the appex relays it
/// here over the same distributed-notification bus the progress bridge uses.
enum StoreButton {
    /// The appex's bundle id (project.yml, ViaductExtension target).
    static let identifier = "com.magicelk235.viaduct.Extension"

    /// Posted by the appex when the extension's background worker says hello.
    /// The name is duplicated in SafariWebExtensionHandler.swift — the appex
    /// target can't see this file.
    static let aliveNote = Notification.Name("com.magicelk235.viaduct.storebutton.alive")

    private static let lastSeenKey = "storeButtonLastSeen"

    /// How fresh a heartbeat still counts as "on". Safari restarts background
    /// workers at least once per launch, so a week of silence means the
    /// extension is off, or Safari hasn't run — either way the row may as well
    /// offer the switch again.
    private static let freshness: TimeInterval = 7 * 24 * 3600

    /// Stamp a heartbeat (called when the alive note arrives).
    static func markAlive() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastSeenKey)
    }

    /// True while the last heartbeat is fresh enough to trust.
    static var isEnabled: Bool {
        let last = UserDefaults.standard.double(forKey: lastSeenKey)
        return last > 0 && Date().timeIntervalSince1970 - last < freshness
    }

    /// Open Safari's extension settings with Viaduct's row selected, so the
    /// user lands on the checkbox instead of instructions for finding it.
    /// The lookup can fail the same way the state API does (see above), and it
    /// fails silently — so on error, at least bring Safari up; the UI next to
    /// this button names the path (Settings → Extensions).
    static func openSafariSettings() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: identifier) { error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                guard let safari = NSWorkspace.shared
                    .urlForApplication(withBundleIdentifier: "com.apple.Safari") else { return }
                NSWorkspace.shared.openApplication(at: safari,
                                                   configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }

    /// Open the Chrome Web Store in Safari, explicitly. The button only exists
    /// in Safari, and the default browser may well be Chrome — this is an app
    /// for people who use Chrome extensions.
    static func openWebStore() {
        let store = URL(string: "https://chromewebstore.google.com/")!
        guard let safari = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
            NSWorkspace.shared.open(store)
            return
        }
        NSWorkspace.shared.open([store], withApplicationAt: safari,
                                configuration: NSWorkspace.OpenConfiguration())
    }
}
