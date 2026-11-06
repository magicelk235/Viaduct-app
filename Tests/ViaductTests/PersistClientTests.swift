import XCTest
@testable import Viaduct

final class PersistClientTests: XCTestCase {
    private let staged = URL(fileURLWithPath: "/Users/me/Library/Caches/Viaduct/firefox/Dark Reader/staged_extension")

    func testInstallOutcomeDecodesTheResult() throws {
        let line = #"{"ok":true,"id":"darkreader@viaduct","name":"Dark Reader","version":"4.9.99","profilePath":"/profiles/a","pending":true}"#
        XCTAssertEqual(try PersistClient.decodeOutcome(Data(line.utf8)),
                       PersistResult(id: "darkreader@viaduct", name: "Dark Reader", version: "4.9.99",
                                     profilePath: "/profiles/a", pending: true))
    }

    func testFailedOutcomeThrowsPersistsOwnError() {
        let line = #"{"ok":false,"error":"Firefox 160.0 refused the add-on: background.js is missing"}"#
        XCTAssertThrowsError(try PersistClient.decodeOutcome(Data(line.utf8))) {
            XCTAssertEqual($0 as? PersistError, .failed("Firefox 160.0 refused the add-on: background.js is missing"))
        }
    }

    func testEmptyOutputIsNeverTakenAsSuccess() {
        XCTAssertThrowsError(try PersistClient.decodeOutcome(Data())) {
            guard case .unreadableOutput = $0 as? PersistError else { return XCTFail("\($0)") }
        }
    }

    func testStatusReadsDatesWithMilliseconds() throws {
        let json = #"{"agent":{"running":true,"pid":4242},"profiles":[{"profilePath":"/profiles/a","lastLoad":"2026-11-03T10:15:30.123Z","lastError":null},{"profilePath":"/profiles/b","lastLoad":null,"lastError":"connection refused"}]}"#
        let status = try PersistClient.decoder.decode(PersistStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.agent, .init(running: true, pid: 4242))
        XCTAssertEqual(try XCTUnwrap(status.profiles[0].lastLoad).timeIntervalSince1970, 1_793_700_930.123, accuracy: 0.001)
        XCTAssertNil(status.profiles[1].lastLoad)
        XCTAssertEqual(status.profiles[1].lastError, "connection refused")
    }

    func testProfilesMarkTheDefaultAndOpenOnes() throws {
        let json = #"{"firefoxes":[{"channel":"release","version":"160.0","path":"/Applications/Firefox.app/Contents/MacOS/firefox"}],"profiles":[{"name":"default-release","path":"/profiles/a","isDefault":true,"inUse":true},{"name":"work","path":"/profiles/b","isDefault":false,"inUse":false}]}"#
        let found = try PersistClient.decoder.decode(PersistProfiles.self, from: Data(json.utf8))
        XCTAssertEqual(found.firefoxes.map(\.version), ["160.0"])
        XCTAssertEqual(found.profiles.map(\.isDefault), [true, false])
        XCTAssertEqual(found.profiles.map(\.inUse), [true, false])
    }

    func testListUnwrapsTheKeptAddons() throws {
        let json = #"{"addons":[{"id":"darkreader@viaduct","name":"Dark Reader","version":"4.9.99","profilePath":"/profiles/a","dir":"/state/persistent/abc/darkreader@viaduct","firefox":"/Applications/Firefox.app/Contents/MacOS/firefox"}]}"#
        XCTAssertEqual(try PersistClient.decodeList(Data(json.utf8)).map(\.id), ["darkreader@viaduct"])
    }

    func testInstallArgumentsFollowTheSpec() {
        XCTAssertEqual(PersistClient.installArguments(staged: staged, profile: "/profiles/a", firefox: "/Applications/Firefox.app", restart: true, launch: true),
                       ["install", staged.path, "--profile", "/profiles/a", "--firefox", "/Applications/Firefox.app", "--json"])
    }

    func testLaterAndNoLaunchAddTheirFlags() {
        XCTAssertEqual(PersistClient.installArguments(staged: staged, profile: nil, firefox: "/Applications/Firefox.app", restart: false, launch: false),
                       ["install", staged.path, "--firefox", "/Applications/Firefox.app", "--json", "--no-firefox-restart", "--no-launch"])
    }

    func testUninstallCanBeToldNeverToRestartFirefox() {
        XCTAssertEqual(PersistClient.uninstallArguments(id: "darkreader@viaduct", profile: "/profiles/a", restart: false),
                       ["uninstall", "darkreader@viaduct", "--profile", "/profiles/a", "--json", "--no-firefox-restart"])
    }

    func testPersistNeverManagesItsOwnLaunchAgent() {
        XCTAssertEqual(PersistClient.environment(base: ["PATH": "/usr/bin"])["LAVADUCT_PERSIST_AGENT"], "external")
    }
}
