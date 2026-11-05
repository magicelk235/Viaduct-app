import XCTest
@testable import Viaduct

final class StoreRequestTests: XCTestCase {
    let id = "eimadpbcbfnmbkopoojfekhnkhdbieeh"

    func test_installWithoutBrowserIsSafari() {
        XCTAssertEqual(StoreRequest(url: URL(string: "viaduct://install?id=\(id)&name=Dark%20Reader")!),
                       StoreRequest(action: .install(name: "Dark Reader"), storeId: id, browser: .safari))
    }

    func test_removeWithoutBrowserIsSafari() {
        XCTAssertEqual(StoreRequest(url: URL(string: "viaduct://remove?id=\(id)")!),
                       StoreRequest(action: .remove, storeId: id, browser: .safari))
    }

    func test_firefoxParameter() {
        XCTAssertEqual(StoreRequest(url: URL(string: "viaduct://install?id=\(id)&browser=firefox")!)?.browser, .firefox)
        XCTAssertEqual(StoreRequest(url: URL(string: "viaduct://remove?id=\(id)&browser=firefox")!),
                       StoreRequest(action: .remove, storeId: id, browser: .firefox))
    }

    func test_unknownBrowserIsIgnoredNotSafari() {
        XCTAssertNil(StoreRequest(url: URL(string: "viaduct://install?id=\(id)&browser=chrome")!))
        XCTAssertNil(StoreRequest(url: URL(string: "viaduct://install?id=\(id)&browser=Firefox")!))
    }

    func test_browserWithoutAValueIsIgnoredNotSafari() {
        XCTAssertNil(StoreRequest(url: URL(string: "viaduct://install?id=\(id)&browser")!))
        XCTAssertNil(StoreRequest(url: URL(string: "viaduct://remove?id=\(id)&browser=")!))
    }

    func test_rejectsMalformed() {
        for s in ["https://install?id=\(id)", "viaduct://open?id=\(id)", "viaduct://install",
                  "viaduct://install?id=abc", "viaduct://remove?id=../\(id)"] {
            XCTAssertNil(StoreRequest(url: URL(string: s)!), s)
        }
    }

    func test_namesSurviveTheRoundTrip() {
        for name in ["C++ & Tools", "Übersetzer / 翻訳", "a=b?c#d", "100% Dark"] {
            let r = StoreRequest(action: .install(name: name), storeId: id, browser: .firefox)
            XCTAssertEqual(StoreRequest(url: r.url), r, name)
        }
    }

    func test_urlAlwaysCarriesTheBrowser() {
        let r = StoreRequest(action: .remove, storeId: id, browser: .safari)
        XCTAssertEqual(r.url.absoluteString, "viaduct://remove?id=\(id)&browser=safari")
    }

    func test_installedQueryKeepsTheShippedSafariFormat() {
        XCTAssertEqual(InstalledQuery.busObject(storeId: id, browser: .safari), id)
        XCTAssertTrue(InstalledQuery.parse(id) == (id, .safari))
        XCTAssertTrue(InstalledQuery.parse(InstalledQuery.busObject(storeId: id, browser: .firefox)) == (id, .firefox))
    }

    func test_busNamesMatchTheShippedSafariExtension() {
        XCTAssertEqual(ProgressBus.request.rawValue, "com.magicelk235.viaduct.progress.request")
        XCTAssertEqual(ProgressBus.state.rawValue, "com.magicelk235.viaduct.progress.state")
    }
}
