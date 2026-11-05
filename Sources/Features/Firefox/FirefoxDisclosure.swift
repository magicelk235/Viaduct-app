import Foundation

/// What keeping add-ons changes in Firefox. The user accepts it once, before
/// the first Firefox install.
enum FirefoxDisclosure {
    static let key = "firefoxDisclosureAccepted"

    static let title = "Keeping add-ons in Firefox"
    static let message = """
    Firefox only keeps add-ons that Mozilla has signed. To keep yours, Viaduct briefly turns on Firefox's remote debugging each time Firefox opens, loads your add-ons, and turns it off again.

    This leaves one Firefox setting changed: Firefox won't ask before a debugger connects. Another program on this Mac could use that to control Firefox, though a program that can do that could already change Firefox's settings.

    Removing your last Firefox add-on puts these settings back.
    """

    static func isAccepted(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    static func accept(_ defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key)
    }
}
