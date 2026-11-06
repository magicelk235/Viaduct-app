import XCTest
@testable import Viaduct

@MainActor
final class IssueReportTests: XCTestCase {
    /// The issue form's fields, by query parameter.
    private func items(_ url: URL) -> [String: String] {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(query.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    }

    func test_firefoxFailureReportCarriesBrowserAndPersist() {
        let q = items(IssueReport.conversionFailure(extensionName: "Dark Reader", version: "4.9", storeId: nil, summary: nil,
                                                    log: ["✗ boom"], cliVersion: "2.0.0", browser: .firefox, persistVersion: "0.2.0 (lavaduct 0.1.0)"))
        XCTAssertEqual(q["template"], "conversion-failure.yml")
        XCTAssertEqual(q["browser"], "Firefox")
        XCTAssertTrue(q["error"]!.contains("CLI 2.0.0 · persist 0.2.0 (lavaduct 0.1.0) · Firefox"))
        XCTAssertTrue(q["error"]!.hasSuffix("✗ boom"))
        XCTAssertTrue(q["os"]!.hasPrefix("macOS ")); XCTAssertTrue(q["os"]!.contains("Firefox")); XCTAssertFalse(q["os"]!.contains("Xcode"))
    }

    func test_safariFailureReportKeepsXcodeAndLeavesPersistOut() {
        let q = items(IssueReport.conversionFailure(extensionName: "Dark Reader", version: "4.9", storeId: nil, summary: nil,
                                                    log: ["✗ boom"], cliVersion: "2.0.0", browser: .safari, persistVersion: "0.2.0 (lavaduct 0.1.0)"))
        XCTAssertEqual(q["browser"], "Safari")
        XCTAssertTrue(q["error"]!.contains("CLI 2.0.0 · Safari"))
        XCTAssertFalse(q["error"]!.contains("persist"))
        XCTAssertTrue(q["os"]!.hasPrefix("macOS "))
        XCTAssertTrue(q["os"]!.contains("Xcode") || q["os"]!.contains("no Xcode found"))
        XCTAssertFalse(q["os"]!.contains("Firefox"))
    }

    func test_firefoxFailureReportWithoutAPersistVersionSaysSo() {
        let q = items(IssueReport.conversionFailure(extensionName: "Dark Reader", version: nil, storeId: nil, summary: nil,
                                                    log: [], cliVersion: "2.0.0", browser: .firefox, persistVersion: nil))
        XCTAssertTrue(q["error"]!.contains("CLI 2.0.0 · persist ? · Firefox"))
    }

    func test_brokenFirefoxExtensionReport() {
        let q = items(IssueReport.convertedButBroken(extensionName: "Dark Reader", version: nil, storeId: nil, browser: .firefox,
                                                     cliVersion: "2.0.0", persistVersion: "0.2.0 (lavaduct 0.1.0)"))
        XCTAssertEqual(q["title"], "Dark Reader doesn't work in Firefox")
        XCTAssertEqual(q["browser"], "Firefox")
        XCTAssertTrue(q["steps"]!.contains("Opened it in Firefox"))
        XCTAssertTrue(q["steps"]!.contains("(CLI 2.0.0, persist 0.2.0 (lavaduct 0.1.0))"))
        XCTAssertTrue(q["safari-version"]!.hasPrefix("Firefox "))
        XCTAssertTrue(q["safari-version"]!.contains(", macOS "))
    }

    func test_brokenSafariExtensionReport() {
        let q = items(IssueReport.convertedButBroken(extensionName: "Dark Reader", version: "4.9", storeId: nil, browser: .safari,
                                                     cliVersion: "2.0.0", persistVersion: "0.2.0 (lavaduct 0.1.0)"))
        XCTAssertEqual(q["title"], "Dark Reader doesn't work in Safari")
        XCTAssertEqual(q["browser"], "Safari")
        XCTAssertTrue(q["steps"]!.contains("(CLI 2.0.0)\n2. Turned it on in Safari"))
        XCTAssertFalse(q["steps"]!.contains("persist"))
        XCTAssertTrue(q["safari-version"]!.hasPrefix("Safari "))
    }
}
