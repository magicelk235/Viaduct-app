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

    func testTheDisclosureIsTheApprovedText() {
        XCTAssertEqual(FirefoxDisclosure.title, "Keeping add-ons in Firefox")
        XCTAssertEqual(FirefoxDisclosure.message, """
        Firefox only keeps add-ons that Mozilla has signed. To keep yours, Viaduct briefly turns on Firefox's remote debugging each time Firefox opens, loads your add-ons, and turns it off again.

        This leaves one Firefox setting changed: Firefox won't ask before a debugger connects. Another program on this Mac could use that to control Firefox, though a program that can do that could already change Firefox's settings.

        Removing your last Firefox add-on puts these settings back.
        """)
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
