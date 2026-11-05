import XCTest
@testable import Viaduct

final class CompatibilityCheckTests: XCTestCase {
    func testShimmedIssuesNeverBlockFirefox() {
        let report = #"{"issues":[{"severity":"error","category":"api","message":"chrome.offscreen is missing","autoFixed":false,"shimmed":true}]}"#
        XCTAssertNil(CompatibilityCheck.verdict(fromReport: Data(report.utf8), browser: .firefox))
    }

    func testAFirefoxVerdictNamesFirefox() throws {
        let report = #"{"issues":[{"severity":"error","category":"manifest","message":"background.js is missing","autoFixed":false}]}"#
        let verdict = try XCTUnwrap(CompatibilityCheck.verdict(fromReport: Data(report.utf8), browser: .firefox))
        XCTAssertEqual(verdict.title, "This extension won't work in Firefox")
        XCTAssertEqual(verdict.details, ["background.js is missing"])
    }

    func testTheCheckAsksTheFirefoxEngine() {
        XCTAssertEqual(CompatibilityCheck.arguments(path: "/x.crx", browser: .firefox), ["/x.crx", "--browser", "firefox", "--analyze", "--json"])
        XCTAssertEqual(CompatibilityCheck.arguments(path: "/x.crx", browser: .safari), ["/x.crx", "--analyze", "--json"])
    }
}
