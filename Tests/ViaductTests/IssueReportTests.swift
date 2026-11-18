import XCTest
@testable import Viaduct

@MainActor
final class IssueReportTests: XCTestCase {
    /// The issue form's fields, by query parameter.
    private func items(_ url: URL) -> [String: String] {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(query.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    }

    private func section(_ report: ProblemReport, _ heading: String) -> String? {
        report.sections.first { $0.heading == heading }?.text
    }

    func test_firefoxFailureReportCarriesBrowserAndPersist() {
        let report = IssueReport.conversionFailure(extensionName: "Dark Reader", version: "4.9", storeId: nil, summary: nil,
                                                   log: ["✗ boom"], cliVersion: "2.0.0", browser: .firefox, persistVersion: "0.2.0 (lavaduct 0.1.0)")
        XCTAssertEqual(report.kind, .conversionFailure)
        XCTAssertEqual(report.log, ["✗ boom"])
        XCTAssertTrue(section(report, "Versions")!.contains("CLI 2.0.0 · persist 0.2.0 (lavaduct 0.1.0) · Firefox"))
        let os = section(report, "OS & Xcode/Firefox version")!
        XCTAssertTrue(os.hasPrefix("macOS ")); XCTAssertTrue(os.contains("Firefox")); XCTAssertFalse(os.contains("Xcode"))

        let q = items(report.fallback(""))
        XCTAssertEqual(q["template"], "conversion-failure.yml")
        XCTAssertEqual(q["browser"], "Firefox")
        XCTAssertTrue(q["error"]!.hasSuffix("✗ boom"))
    }

    func test_safariFailureReportKeepsXcodeAndLeavesPersistOut() {
        let report = IssueReport.conversionFailure(extensionName: "Dark Reader", version: "4.9", storeId: nil, summary: nil,
                                                   log: ["✗ boom"], cliVersion: "2.0.0", browser: .safari, persistVersion: "0.2.0 (lavaduct 0.1.0)")
        let versions = section(report, "Versions")!
        XCTAssertTrue(versions.contains("CLI 2.0.0 · Safari"))
        XCTAssertFalse(versions.contains("persist"))
        let os = section(report, "OS & Xcode/Firefox version")!
        XCTAssertTrue(os.contains("Xcode") || os.contains("no Xcode found"))
        XCTAssertFalse(os.contains("Firefox"))
    }

    func test_firefoxFailureReportWithoutAPersistVersionSaysSo() {
        let report = IssueReport.conversionFailure(extensionName: "Dark Reader", version: nil, storeId: nil, summary: nil,
                                                   log: [], cliVersion: "2.0.0", browser: .firefox, persistVersion: nil)
        XCTAssertTrue(section(report, "Versions")!.contains("CLI 2.0.0 · persist ? · Firefox"))
    }

    func test_failureFallbackLinkCarriesWhatTheUserWroteAndFitsGitHub() {
        let log = (0..<500).map { "line \($0) " + String(repeating: "x", count: 100) }
        let report = IssueReport.conversionFailure(extensionName: "Dark Reader", version: nil, storeId: nil, summary: nil,
                                                   log: log, cliVersion: "2.0.0", browser: .safari, persistVersion: nil)
        let url = report.fallback("It hangs at signing")
        XCTAssertLessThanOrEqual(url.absoluteString.count, 7_500)
        let error = items(url)["error"]!
        XCTAssertTrue(error.hasPrefix("What happened: It hangs at signing\n"))
        XCTAssertTrue(error.hasSuffix(log.last!))
    }

    func test_brokenFirefoxExtensionReport() {
        let report = IssueReport.convertedButBroken(extensionName: "Dark Reader", version: nil, storeId: nil, browser: .firefox,
                                                    cliVersion: "2.0.0", persistVersion: "0.2.0 (lavaduct 0.1.0)")
        XCTAssertEqual(report.title, "Dark Reader doesn't work in Firefox")
        XCTAssertTrue(report.needsDescription)
        let steps = section(report, "Steps to reproduce")!
        XCTAssertTrue(steps.contains("Opened it in Firefox"))
        XCTAssertTrue(steps.contains("(CLI 2.0.0, persist 0.2.0 (lavaduct 0.1.0))"))
        XCTAssertTrue(section(report, "Browser & OS version")!.hasPrefix("Firefox "))

        let q = items(report.fallback("Pages stay white"))
        XCTAssertEqual(q["template"], "converted-but-broken.yml")
        XCTAssertEqual(q["actual"], "Pages stay white")
        XCTAssertTrue(q["safari-version"]!.contains(", macOS "))
    }

    func test_brokenSafariExtensionReport() {
        let report = IssueReport.convertedButBroken(extensionName: "Dark Reader", version: "4.9", storeId: nil, browser: .safari,
                                                    cliVersion: "2.0.0", persistVersion: "0.2.0 (lavaduct 0.1.0)")
        XCTAssertEqual(report.title, "Dark Reader doesn't work in Safari")
        let steps = section(report, "Steps to reproduce")!
        XCTAssertTrue(steps.contains("(CLI 2.0.0)\n2. Turned it on in Safari"))
        XCTAssertFalse(steps.contains("persist"))
        XCTAssertTrue(section(report, "Browser & OS version")!.hasPrefix("Safari "))
    }

    func test_generalReportIsTitledByWhatTheUserWrote() {
        let report = IssueReport.general(browser: .safari, cliVersion: "2.0.0", persistVersion: nil, lastError: "Signing failed")
        XCTAssertEqual(report.title(describing: "  Settings won't open\nmore detail"), "Settings won't open")
        XCTAssertEqual(report.title(describing: ""), "Problem report")
        XCTAssertEqual(section(report, "Last error"), "Signing failed")
        XCTAssertTrue(items(report.fallback("Settings won't open"))["body"]!.hasPrefix("Settings won't open\n\n"))
    }

    func test_generalReportCarriesThePickedBrowser() {
        let safari = IssueReport.general(browser: .safari, cliVersion: "2.0.0", persistVersion: "0.2.0", lastError: nil)
        XCTAssertEqual(section(safari, "Browser"), "Safari")
        XCTAssertTrue(section(safari, "Versions")!.contains(", Safari "))
        XCTAssertFalse(section(safari, "Versions")!.contains("persist"))

        let firefox = IssueReport.general(browser: .firefox, cliVersion: "2.0.0", persistVersion: "0.2.0", lastError: nil)
        XCTAssertEqual(section(firefox, "Browser"), "Firefox")
        XCTAssertTrue(section(firefox, "Versions")!.contains("CLI 2.0.0 · persist 0.2.0"))
        XCTAssertTrue(section(firefox, "Versions")!.contains(", Firefox "))
    }

    // MARK: - Privacy and size

    func test_homeFolderNeverReachesThePublicReport() {
        let home = NSHomeDirectory()
        let report = IssueReport.conversionFailure(
            extensionName: "Dark Reader", version: nil, storeId: nil, summary: "Couldn't read \(home)/Downloads/x.zip",
            log: ["✗ \(home)/Library/Viaduct/out failed", "other user /Users/alice/x", "shared /Users/Shared/y"],
            cliVersion: "2.0.0", browser: .safari, persistVersion: nil)
        let everything = report.preview + items(report.fallback("")).values.joined()
        XCTAssertFalse(everything.contains(home))
        XCTAssertFalse(everything.contains("alice"))
        XCTAssertTrue(report.log[0].contains("~/Library/Viaduct/out"))
        XCTAssertTrue(report.log[2].contains("/Users/Shared/y"))
    }

    func test_longLogsKeepTheNewestLinesWithinTheRelayLimits() {
        let log = (0..<3_000).map { "line \($0) " + String(repeating: "é", count: 2_000) }
        let report = ProblemReport(kind: .conversionFailure, title: "t", sections: [], log: log) { _ in URL(string: "https://x")! }
        XCTAssertEqual(report.log.last?.hasPrefix("line 2999 "), true)
        XCTAssertTrue(report.log.allSatisfy { $0.utf16.count <= ProblemReport.maxLogLine })
        XCTAssertLessThanOrEqual(report.log.reduce(0) { $0 + $1.utf8.count + 1 }, ProblemReport.logBudget)
    }

    func test_clipNeverSplitsACharacter() {
        XCTAssertEqual(ProblemReport.clip("ab👍🏽c", 3), "ab")
        XCTAssertEqual(ProblemReport.clip("short", 10), "short")
    }

    // MARK: - Relay answers

    private func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    func test_relayAnswers() throws {
        XCTAssertEqual(try ReportClient.outcome(status: 201, body: json(["number": 3, "url": "https://github.com/o/r/issues/3"])),
                       URL(string: "https://github.com/o/r/issues/3"))
        XCTAssertThrowsError(try ReportClient.outcome(status: 429, body: json(["error": "Too many reports."]))) {
            XCTAssertEqual($0 as? ReportError, .rejected("Too many reports."))
        }
        XCTAssertThrowsError(try ReportClient.outcome(status: 503, body: json(["error": "Off."]))) {
            XCTAssertEqual($0 as? ReportError, .rejected("Off."))
        }
        // GitHub down behind the relay, or a proxy's HTML page: the user gets the GitHub link.
        XCTAssertThrowsError(try ReportClient.outcome(status: 502, body: json(["error": "Couldn't reach GitHub."]))) {
            XCTAssertEqual($0 as? ReportError, .unreachable)
        }
        XCTAssertThrowsError(try ReportClient.outcome(status: 200, body: Data("<html>".utf8))) {
            XCTAssertEqual($0 as? ReportError, .unreachable)
        }
    }
}
