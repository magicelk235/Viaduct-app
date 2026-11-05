import Foundation

/// Scratch folders for tests, so nothing touches the real Application Support.
enum TempDir {
    /// A new, empty folder at `NSTemporaryDirectory()/ViaductTests/<UUID>`.
    static func make() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ViaductTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
