import Sparkle
import SwiftUI

/// App self-updating, via Sparkle. Feed, public key and the
/// install-in-the-background preference all live in Info.plist; this exists so
/// SwiftUI has something observable to bind the Settings card to.
///
/// Sparkle asks permission once on first launch before it ever phones home.
/// After that it checks daily and installs silently — the new version is live
/// the next time the app starts.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    private init() {}

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
}
