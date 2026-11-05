import Foundation

/// `ViaductHelper agent`: what launchd runs for the Firefox agent. It becomes
/// the app's bundled node running `persist.mjs supervise`.
enum HelperAgent {
    /// This helper's own executable. Under launchd argv[0] is just
    /// `ViaductHelper`, so the path has to come from the bundle instead.
    static var executableURL: URL {
        Bundle.main.executableURL!.resolvingSymlinksInPath()
    }

    /// Node and persist.mjs from the app the helper sits in, two levels up from
    /// `Contents/Helpers/ViaductHelper`. Nil unless both are there.
    static func bundledRuntime(helperURL: URL) -> (node: URL, persist: URL)? {
        let contents = helperURL.deletingLastPathComponent().deletingLastPathComponent()
        let node = contents.appendingPathComponent("Resources/bin/node")
        let persist = contents.appendingPathComponent("Resources/firefox/persist.mjs")
        let files = FileManager.default
        guard files.fileExists(atPath: node.path), files.fileExists(atPath: persist.path) else { return nil }
        return (node, persist)
    }

    /// Replaces this process with `node persist.mjs supervise`. Any failure
    /// exits 1, and launchd's KeepAlive starts the helper again.
    static func run() -> Never {
        let helper = executableURL
        guard let runtime = bundledRuntime(helperURL: helper) else {
            fail("node or persist.mjs is missing from the app around \(helper.path)")
        }
        // The app registers the agent itself, so persist must never write or
        // load a launchd job of its own.
        guard setenv("LAVADUCT_PERSIST_AGENT", "external", 1) == 0 else {
            let reason = String(cString: strerror(errno))
            fail("can't set LAVADUCT_PERSIST_AGENT: \(reason)")
        }
        let argv = [runtime.node.path, runtime.persist.path, "supervise"].map { strdup($0) } + [nil]
        execv(runtime.node.path, argv)
        // execv only returns when it failed. errno is read before the message
        // is built, since that allocation can overwrite it.
        let reason = String(cString: strerror(errno))
        fail("can't run \(runtime.node.path): \(reason)")
    }

    private static func fail(_ reason: String) -> Never {
        FileHandle.standardError.write(Data("ViaductHelper: \(reason)\n".utf8))
        exit(1)
    }
}
