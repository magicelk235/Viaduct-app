import Foundation

/// A UserDefaults suite of its own for each test. The test host is the real
/// app, so `UserDefaults.standard` is the user's actual settings.
enum TestDefaults {
    /// The suite `ViaductTests.<file>.<name>`, emptied first so nothing
    /// carries over from an earlier run.
    static func make(_ name: String = #function, file: String = #fileID) -> UserDefaults {
        let raw = "ViaductTests.\(file).\(name)"
        let suite = String(raw.map { $0.isLetter || $0.isNumber || $0 == "." ? $0 : "-" })
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
