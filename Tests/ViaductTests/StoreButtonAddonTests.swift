import JavaScriptCore
import XCTest
@testable import Viaduct

final class StoreButtonAddonTests: XCTestCase {
    func appex(_ name: String) -> URL {
        Bundle.main.builtInPlugInsURL!.appendingPathComponent("ViaductExtension.appex/Contents/Resources/\(name)")
    }

    func firefox(_ name: String) -> URL {
        Bundle.main.resourceURL!.appendingPathComponent("firefox/store-button/\(name)")
    }

    func test_sharedPageScriptNamesNoBrowser() throws {
        let js = try String(contentsOf: appex("content.js"))
        for s in ["Add to Safari", "Remove from Safari", "add to safari", "remove from safari",
                  "Gone from Safari", "the Safari app", "Safari →", "viaduct://", "browser.runtime"] {
            XCTAssertFalse(js.contains(s), "content.js still has \(s)")
        }
    }

    func test_safariLoadsItsTransportFirst() throws {
        let m = try JSONSerialization.jsonObject(with: Data(contentsOf: appex("manifest.json"))) as! [String: Any]
        let cs = (m["content_scripts"] as! [[String: Any]])[0]
        XCTAssertEqual(cs["js"] as? [String], ["transport.js", "content.js"])
    }

    func test_firefoxAddonIsTheOneTheAppTalksTo() throws {
        let m = try JSONSerialization.jsonObject(with: Data(contentsOf: firefox("manifest.json"))) as! [String: Any]
        let gecko = (m["browser_specific_settings"] as! [String: Any])["gecko"] as! [String: Any]
        XCTAssertEqual(gecko["id"] as? String, NativeHostProtocol.storeButtonId)
        XCTAssertEqual(m["version"] as? String, Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        XCTAssertEqual(((m["content_scripts"] as! [[String: Any]])[0])["js"] as? [String], ["transport.js", "content.js"])
        let bg = m["background"] as! [String: Any]
        XCTAssertEqual(bg["scripts"] as? [String], ["background.js"]); XCTAssertNil(bg["service_worker"])
    }

    func test_firefoxBackgroundUsesTheAppsHostAndNoHeartbeat() throws {
        let js = try String(contentsOf: firefox("background.js"))
        XCTAssertTrue(js.contains("'\(NativeHostProtocol.hostName)'")); XCTAssertFalse(js.contains("hello"))
    }

    func test_bothBrowsersShipTheSamePageScript() throws {
        XCTAssertEqual(try Data(contentsOf: firefox("content.js")), try Data(contentsOf: appex("content.js")))
        XCTAssertEqual(try Data(contentsOf: firefox("icon.png")), try Data(contentsOf: appex("icon.png")))
    }

    // MARK: - Firefox scripts, run in JavaScriptCore against a fake `browser`

    /// A context with a `browser.runtime` that records what the scripts send.
    /// `sendNativeMessage` resolves with `nativeReply`, or rejects when it's a string.
    func context(nativeReply: Any = ["installed": true]) -> JSContext {
        let ctx = JSContext()!
        ctx.exceptionHandler = { _, e in XCTFail("JS threw: \(e?.toString() ?? "?")") }
        ctx.setObject(nativeReply, forKeyedSubscript: "nativeReply" as NSString)
        ctx.evaluateScript("""
            var sent = [], native = [], listener = null;
            var browser = { runtime: {
              sendMessage(m) { sent.push(m); return Promise.resolve({ state: 'idle' }); },
              sendNativeMessage(host, m) {
                native.push({ host, m });
                return typeof nativeReply === 'string' ? Promise.reject(new Error(nativeReply))
                                                       : Promise.resolve(nativeReply);
              },
              onMessage: { addListener(f) { listener = f; } },
            } };
            """)
        return ctx
    }

    func json(_ ctx: JSContext, _ expression: String) -> String {
        ctx.evaluateScript("JSON.stringify(\(expression))").toString()
    }

    func test_firefoxTransportAsksTheBackgroundAndNeverOpensALink() throws {
        let ctx = context()
        ctx.evaluateScript(try String(contentsOf: firefox("transport.js")))
        ctx.evaluateScript("""
            viaductTransport.install('abcdefghijklmnopabcdefghijklmnop', 'Dark Reader');
            viaductTransport.remove('abcdefghijklmnopabcdefghijklmnop');
            viaductTransport.progress();
            viaductTransport.installed('abcdefghijklmnopabcdefghijklmnop');
            """)
        XCTAssertEqual(json(ctx, "sent"), """
            [{"type":"viaduct-open","action":"install","id":"abcdefghijklmnopabcdefghijklmnop","name":"Dark Reader"},\
            {"type":"viaduct-open","action":"remove","id":"abcdefghijklmnopabcdefghijklmnop"},\
            {"type":"viaduct-progress"},\
            {"type":"viaduct-installed","id":"abcdefghijklmnopabcdefghijklmnop"}]
            """)
        XCTAssertEqual(ctx.evaluateScript("viaductTransport.browser").toString(), "Firefox")
        XCTAssertEqual(ctx.evaluateScript("viaductTransport.doneMessage({ state: 'done', pending: true })").toString(),
                       "It arrives the next time you open Firefox")
        XCTAssertEqual(ctx.evaluateScript("viaductTransport.doneMessage({ state: 'done' })").toString(),
                       "Ready to use in Firefox")
        XCTAssertEqual(ctx.evaluateScript("viaductTransport.removeTimeoutMs").toInt32(), 30000)
    }

    func test_firefoxBackgroundRelaysEachRequestToTheHost() throws {
        let ctx = context()
        ctx.evaluateScript(try String(contentsOf: firefox("background.js")))
        ctx.evaluateScript("""
            var replies = [], kept = [];
            for (const m of [{ type: 'viaduct-progress' },
                             { type: 'viaduct-installed', id: 'abcdefghijklmnopabcdefghijklmnop' },
                             { type: 'viaduct-open', action: 'install', id: 'abcdefghijklmnopabcdefghijklmnop', name: 'Dark Reader' },
                             { type: 'viaduct-open', action: 'remove', id: 'abcdefghijklmnopabcdefghijklmnop' }]) {
              kept.push(listener(m, {}, (r) => replies.push(r)));
            }
            """)
        XCTAssertEqual(json(ctx, "native"), """
            [{"host":"\(NativeHostProtocol.hostName)","m":{"type":"progress"}},\
            {"host":"\(NativeHostProtocol.hostName)","m":{"type":"installed","id":"abcdefghijklmnopabcdefghijklmnop"}},\
            {"host":"\(NativeHostProtocol.hostName)","m":{"type":"install","id":"abcdefghijklmnopabcdefghijklmnop","name":"Dark Reader"}},\
            {"host":"\(NativeHostProtocol.hostName)","m":{"type":"remove","id":"abcdefghijklmnopabcdefghijklmnop"}}]
            """)
        // Answered through sendResponse, with the channel held open for it.
        XCTAssertEqual(json(ctx, "kept"), "[true,true,true,true]")
        XCTAssertEqual(json(ctx, "replies"), #"[{"installed":true},{"installed":true},{"installed":true},{"installed":true}]"#)
    }

    func test_firefoxBackgroundAnswersUnreachableWhenTheHostFails() throws {
        let ctx = context(nativeReply: "No such native application com.magicelk235.viaduct")
        ctx.evaluateScript(try String(contentsOf: firefox("background.js")))
        ctx.evaluateScript("""
            var replies = [];
            listener({ type: 'viaduct-installed', id: 'abcdefghijklmnopabcdefghijklmnop' }, {}, (r) => replies.push(r));
            """)
        XCTAssertEqual(json(ctx, "replies"),
                       #"[{"state":"unreachable","installed":false,"error":"No such native application com.magicelk235.viaduct"}]"#)
    }

    func test_firefoxBackgroundIgnoresOtherMessages() throws {
        let ctx = context()
        ctx.evaluateScript(try String(contentsOf: firefox("background.js")))
        XCTAssertTrue(ctx.evaluateScript("listener({ type: 'hello' }, {}, () => {})").isUndefined)
        XCTAssertEqual(json(ctx, "native"), "[]")
    }

    // MARK: - The shared page script against an unreachable app

    /// content.js loaded with a stub DOM and a transport whose installed() answers `installedReply`.
    /// The page's own painting and timers are swapped for recorders.
    func pageScript(installedReply: String) throws -> JSContext {
        let ctx = JSContext()!
        ctx.exceptionHandler = { _, e in XCTFail("JS threw: \(e?.toString() ?? "?")") }
        ctx.evaluateScript("""
            var location = { href: 'https://chromewebstore.google.com/', pathname: '/' };
            var window = { location };
            var document = { body: null, addEventListener() {} };
            var viaductTransport = {
              browser: 'Firefox', remove() {}, removingMessage: 'Removing', removedMessage: 'Gone',
              removeTimeoutMs: 30000, installed() { return Promise.resolve(\(installedReply)); },
            };
            """)
        ctx.evaluateScript(try String(contentsOf: appex("content.js")))
        ctx.evaluateScript("""
            var states = [], timers = 0;
            apply = function () {}; renderProgress = function () {};
            setState = function (title) { states.push(title); };
            setTimeout = function () { timers++; };
            """)
        return ctx
    }

    func test_pageNeverCachesAnUnreachableAppAsNotInstalled() throws {
        for reply in ["{ installed: false, state: 'unreachable' }", "{ installed: false, error: 'no host' }"] {
            let ctx = try pageScript(installedReply: reply)
            ctx.evaluateScript("refreshInstalled('abcdefghijklmnopabcdefghijklmnop')")
            XCTAssertFalse(ctx.evaluateScript("installedById.has('abcdefghijklmnopabcdefghijklmnop')").toBool(), reply)
        }
        let ctx = try pageScript(installedReply: "{ installed: false }")
        ctx.evaluateScript("refreshInstalled('abcdefghijklmnopabcdefghijklmnop')")
        XCTAssertEqual(json(ctx, "installedById.get('abcdefghijklmnopabcdefghijklmnop')"), "false")
    }

    func test_removeNeverReportsRemovedWhileTheAppIsUnreachable() throws {
        for reply in ["{ installed: false, state: 'unreachable' }", "{ installed: false, error: 'no host' }"] {
            let ctx = try pageScript(installedReply: reply)
            ctx.evaluateScript("removeViaduct('abcdefghijklmnopabcdefghijklmnop', null)")
            XCTAssertEqual(json(ctx, "states"), #"["Removing…"]"#, reply)
            XCTAssertFalse(ctx.evaluateScript("installedById.has('abcdefghijklmnopabcdefghijklmnop')").toBool(), reply)
        }
        let ctx = try pageScript(installedReply: "{ installed: false }")
        ctx.evaluateScript("removeViaduct('abcdefghijklmnopabcdefghijklmnop', null)")
        XCTAssertEqual(json(ctx, "states"), #"["Removing…","Removed ✓"]"#)
    }
}
