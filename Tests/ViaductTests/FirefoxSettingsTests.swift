import XCTest
@testable import Viaduct

final class FirefoxSettingsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_664_000)
    private let firefox = FirefoxLocator.Install(bundleID: "org.mozilla.firefox",
                                                 appURL: URL(fileURLWithPath: "/Applications/Firefox.app"),
                                                 displayName: "Firefox", version: "160.0")

    private func profile(lastLoad: Date? = nil, lastError: String? = nil) -> PersistStatus.Profile {
        PersistStatus.Profile(profilePath: "/profiles/abc.default-release", lastLoad: lastLoad, lastError: lastError)
    }

    func testProfileNameComesFromFirefoxElseTheFolder() {
        let known = [PersistProfiles.Profile(name: "Work", path: "/profiles/xyz.Work", isDefault: false, inUse: false)]
        XCTAssertEqual(FirefoxAgentSection.name(of: "/profiles/xyz.Work", in: known), "Work")
        XCTAssertEqual(FirefoxAgentSection.name(of: "/profiles/abc.default-release", in: known), "abc.default-release")
    }

    func testNeverLoadedProfile() {
        let state = FirefoxAgentSection.loadState(of: profile(), firefox: firefox, now: now)
        XCTAssertEqual(state.text, "Not loaded yet")
        XCTAssertNil(state.error)
    }

    func testLoadedProfileSaysWhen() {
        let state = FirefoxAgentSection.loadState(of: profile(lastLoad: now.addingTimeInterval(-300)), firefox: firefox, now: now)
        XCTAssertTrue(state.text.hasPrefix("Loaded "), state.text)
        XCTAssertNotEqual(state.text, "Loaded ")
        XCTAssertNil(state.error)
    }

    func testBlockedLoadNamesTheFirefoxAndKeepsItsError() {
        let message = "the add-on is not signed"
        let state = FirefoxAgentSection.loadState(of: profile(lastLoad: now, lastError: message), firefox: firefox, now: now)
        XCTAssertEqual(state.text, "Firefox 160.0 blocked loading")
        XCTAssertEqual(state.error, message)
    }

    func testBlockedLoadWithoutAFoundFirefox() {
        let state = FirefoxAgentSection.loadState(of: profile(lastError: "x"), firefox: nil, now: now)
        XCTAssertEqual(state.text, "Firefox blocked loading")
    }
}
