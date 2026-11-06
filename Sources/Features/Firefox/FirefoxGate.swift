import AppKit
import ServiceManagement

/// What stops a Firefox install from going ahead, and the one thing that
/// clears it.
enum FirefoxGate: Equatable {
    case notInstalled, noProfile, loginItemOff

    var headline: String {
        switch self {
        case .notInstalled: return "Firefox isn't installed"
        case .noProfile: return "Firefox isn't set up yet"
        case .loginItemOff: return "Viaduct is off in Login Items"
        }
    }

    var message: String {
        switch self {
        case .notInstalled:
            return "Viaduct adds the extension to Firefox on this Mac. Get Firefox, then try again."
        // The install errors own these two, so a gate reads the same as the
        // error it stands for.
        case .noProfile:
            return FirefoxAddonsError.noProfile.localizedDescription
        case .loginItemOff:
            return FirefoxAddonsError.loginItemOff.localizedDescription
        }
    }

    var actionTitle: String {
        switch self {
        case .notInstalled: return "Get Firefox"
        case .noProfile: return "Open Firefox"
        case .loginItemOff: return "Open Login Items"
        }
    }

    @MainActor func perform() {
        switch self {
        case .notInstalled: NSWorkspace.shared.open(FirefoxLocator.downloadURL)
        case .noProfile: FirefoxLocator.find().map(FirefoxLocator.open)
        case .loginItemOff: SMAppService.openSystemSettingsLoginItems()
        }
    }
}
