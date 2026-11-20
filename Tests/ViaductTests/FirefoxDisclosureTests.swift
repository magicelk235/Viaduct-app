import XCTest
@testable import Viaduct

final class FirefoxDisclosureTests: XCTestCase {
    func testTheDisclosureIsAcceptedOnceAndRemembered() {
        let defaults = TestDefaults.make()
        XCTAssertFalse(FirefoxDisclosure.isAccepted(defaults))
        FirefoxDisclosure.accept(defaults)
        XCTAssertTrue(FirefoxDisclosure.isAccepted(defaults))
        XCTAssertTrue(defaults.bool(forKey: "firefoxDisclosureAccepted"))
    }

    // A build without persist.mjs can't install into Firefox, so a stored
    // Firefox choice comes back as Safari there.
    func testFirefoxUnavailableWithoutPersistFallsBackToSafari() {
        XCTAssertEqual(BrowserPicker.storedBrowser("firefox", firefoxAvailable: false), .safari)
        XCTAssertEqual(BrowserPicker.storedBrowser("firefox", firefoxAvailable: true), .firefox)
        XCTAssertEqual(BrowserPicker.storedBrowser("safari", firefoxAvailable: false), .safari)
        XCTAssertEqual(BrowserPicker.storedBrowser(nil, firefoxAvailable: true), .safari)
        XCTAssertEqual(BrowserPicker.storedBrowser("opera", firefoxAvailable: true), .safari)
    }
}
