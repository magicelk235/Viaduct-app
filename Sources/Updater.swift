import Sparkle
import SwiftUI

/// App self-updating, via Sparkle. Feed, public key and the
/// install-in-the-background preference all live in Info.plist; this exists so
/// SwiftUI has something observable to bind the Settings card to, and to decide
/// when a downloaded update is allowed to install itself.
///
/// Sparkle asks permission once on first launch before it ever phones home.
/// After that it checks daily and installs in the background.
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = Updater()

    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)

    /// Set at launch to report whether a conversion is in flight. An update
    /// that relaunches the app mid-convert would kill xcodebuild halfway.
    var isBusy: () -> Bool = { false }

    private override init() {
        super.init()
        _ = controller   // starts the updater and its background checks
    }

    /// Sparkle persists this in user defaults; we only mirror it for the toggle.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// Settings "Check Now" — shows Sparkle's UI, including "you're up to date".
    func checkForUpdates() { controller.updater.checkForUpdates() }

    /// Sparkle's default is to install a downloaded update when the app quits.
    /// Viaduct doesn't quit: Cmd+Q closes the windows and leaves the menu-bar
    /// item running, so an update could sit staged for weeks. Install it now
    /// instead — Sparkle relaunches us with no UI — unless a conversion is
    /// running, in which case falling back to install-on-quit is the safe move.
    @objc func updater(_ updater: SPUUpdater,
                       willInstallUpdateOnQuit item: SUAppcastItem,
                       immediateInstallationBlock: @escaping () -> Void) -> Bool {
        guard !isBusy() else { return false }
        // Installing means terminating, and the normal quit path answers
        // .terminateCancel — Sparkle would ask forever and never install.
        AppDelegate.allowRealQuit = true
        immediateInstallationBlock()
        // If the install bails out, don't leave Cmd+Q permanently able to kill
        // the app when it should be retreating to the menu bar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            AppDelegate.allowRealQuit = false
        }
        return true
    }
}
