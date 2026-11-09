import XCTest
@testable import Viaduct

@MainActor
final class SetupStepsTests: XCTestCase {
    func testChoosingFirefoxSkipsXcodeAndTheAppleAccount() {
        XCTAssertEqual(SetupFlow.steps(for: .firefox, hasBrowsers: true), [.firefox, .diskAccess, .firefoxStoreButton, .license])
        XCTAssertEqual(SetupFlow.steps(for: .safari, hasBrowsers: true), [.xcode, .appleAccount, .diskAccess, .storeButton, .license])
    }

    /// Viaduct reads Firefox's profiles to put add-ons in them, whether or not
    /// there's a Chromium browser to import from.
    func testFirefoxAlwaysAsksForDiskAccess() {
        XCTAssertEqual(SetupFlow.steps(for: .firefox, hasBrowsers: false), [.firefox, .diskAccess, .firefoxStoreButton, .license])
        XCTAssertEqual(SetupFlow.steps(for: .safari, hasBrowsers: false), [.xcode, .appleAccount, .storeButton, .license])
    }

    func testFirefoxSetupWaitsOnFirefoxsFolderToo() {
        XCTAssertNil(SetupFlow.blockedNames(chromium: nil, firefox: nil, for: .firefox))
        // Checked while Safari was picked, so Firefox's folder hasn't been looked at.
        XCTAssertNil(SetupFlow.blockedNames(chromium: [], firefox: nil, for: .firefox))
        XCTAssertEqual(SetupFlow.blockedNames(chromium: [.chrome], firefox: true, for: .firefox), ["Firefox", "Chrome"])
        XCTAssertEqual(SetupFlow.blockedNames(chromium: [], firefox: false, for: .firefox), [])
    }

    func testSafariSetupLeavesFirefoxsFolderOut() {
        XCTAssertNil(SetupFlow.blockedNames(chromium: nil, firefox: nil, for: .safari))
        XCTAssertEqual(SetupFlow.blockedNames(chromium: [.chrome], firefox: true, for: .safari), ["Chrome"])
        XCTAssertEqual(SetupFlow.blockedNames(chromium: [], firefox: nil, for: .safari), [])
    }
}
