import XCTest

final class StoreButtonAddonTests: XCTestCase {
    func appex(_ name: String) -> URL {
        Bundle.main.builtInPlugInsURL!.appendingPathComponent("ViaductExtension.appex/Contents/Resources/\(name)")
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
}
