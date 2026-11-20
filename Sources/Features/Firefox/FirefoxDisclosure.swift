import Foundation

/// What keeping add-ons changes in Firefox. The user accepts it once, before
/// the first Firefox install.
enum FirefoxDisclosure {
    static let key = "firefoxDisclosureAccepted"

    static let title = "Keeping add-ons in Firefox"
    static let message = """
    Viaduct loads your add-ons each time Firefox opens. To do that, Firefox stops asking before a debugger connects.

    Removing your last Firefox add-on turns this back on.
    """

    static func isAccepted(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    static func accept(_ defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key)
    }
}
