import JavaScriptCore
import XCTest
@testable import Viaduct

/// Runs the settings seed against a fake chrome.storage, to prove it only fills
/// empty areas and never replaces what the extension saved itself.
@MainActor
final class SettingsSeedTests: XCTestCase {
    private let chromeSettings = #"{ "theme": "dark" }"#

    /// A context with a fake chrome.storage whose areas start with `local` and
    /// `sync` (JSON). `get` answers synchronously with a deep copy, the way a
    /// browser hands back a fresh object.
    private func makeContext(local: String = "{}", sync: String = "{}") -> JSContext {
        let context = JSContext()!
        context.exceptionHandler = { _, exception in
            XCTFail("JavaScript error: \(exception?.toString() ?? "unknown")")
        }
        context.evaluateScript("""
        var stores = { local: \(local), sync: \(sync) };
        function makeArea(name) {
          return {
            get: function (keys, cb) {
              var copy = JSON.parse(JSON.stringify(stores[name]));
              if (cb) cb(copy);
            },
            set: function (items, cb) {
              for (var key in items) stores[name][key] = JSON.parse(JSON.stringify(items[key]));
              if (cb) cb();
            }
          };
        }
        var chrome = { storage: { local: makeArea("local"), sync: makeArea("sync") }, runtime: {} };
        """)
        return context
    }

    private func seed(_ context: JSContext, local: String? = nil, sync: String = "{}") {
        context.evaluateScript(ExtensionSettingsTransfer.seedScript(local: local ?? chromeSettings, sync: sync))
    }

    private func store(_ context: JSContext, _ name: String) throws -> [String: Any] {
        let json = try XCTUnwrap(context.evaluateScript("JSON.stringify(stores.\(name))")?.toString())
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func test_emptyAreaGetsChromesSettings() throws {
        let context = makeContext()
        seed(context)
        XCTAssertEqual(try store(context, "local") as? [String: String], ["theme": "dark"])
    }

    func test_savedSettingsAreNeverReplaced() throws {
        let context = makeContext(local: #"{ "theme": "light" }"#)
        seed(context)
        XCTAssertEqual(try store(context, "local") as? [String: String], ["theme": "light"])
    }

    func test_runtimeBookkeepingStillCountsAsEmpty() throws {
        let context = makeContext(local: #"{ "__viaduct_debug_log__": [] }"#)
        seed(context)
        let local = try store(context, "local")
        XCTAssertEqual(local["theme"] as? String, "dark")
        XCTAssertEqual((local["__viaduct_debug_log__"] as? [Any])?.count, 0)
        XCTAssertEqual(Set(local.keys), ["theme", "__viaduct_debug_log__"])
    }

    func test_reloadAfterAChangeKeepsTheChange() throws {
        let context = makeContext()
        seed(context)
        context.evaluateScript(#"chrome.storage.local.set({ theme: "light" }, function () {});"#)
        XCTAssertEqual(try store(context, "local") as? [String: String], ["theme": "light"])

        // persist loads the same seed again the next time Firefox starts.
        seed(context)
        XCTAssertEqual(try store(context, "local") as? [String: String], ["theme": "light"])
    }

    func test_storageCallsWaitForTheSeed() throws {
        let context = makeContext()
        // The extension's own first read runs right after the seed starts, in the
        // same script, before any of the seed's promise work has happened.
        context.evaluateScript(
            ExtensionSettingsTransfer.seedScript(local: chromeSettings, sync: "{}")
                + #"var seen = null; chrome.storage.local.get(null, function (items) { seen = items; });"#
        )
        let json = try XCTUnwrap(context.evaluateScript("JSON.stringify(seen)")?.toString())
        let seen = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])
        XCTAssertEqual(seen, ["theme": "dark"])
    }
}
