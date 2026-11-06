import XCTest
@testable import Viaduct

final class ConvertPhaseTests: XCTestCase {
    func testAFirefoxRunMovesThroughUnpackingAndConverting() {
        XCTAssertEqual(ConvertPhase.detect(from: "› Extracting Dark Reader.crx …", browser: .firefox), .extracting)
        XCTAssertEqual(ConvertPhase.detect(from: #"✓ Loaded "Dark Reader" (MV3)"#, browser: .firefox), .staging)
        XCTAssertEqual(ConvertPhase.detect(from: "› Staging clean extension assets …", browser: .firefox), .staging)
        XCTAssertNil(ConvertPhase.detect(from: "✓ Installed → /profiles/a", browser: .firefox))   // the app sets .installing itself
    }

    func testSafariDetectionIsUnchanged() {
        XCTAssertEqual(ConvertPhase.detect(from: "Building (Release)…", browser: .safari), .building)
        XCTAssertEqual(ConvertPhase.detect(from: "✓ Installed → /Applications/Dark Reader.app", browser: .safari), .installing)
    }

    func testFirefoxCopy() {
        XCTAssertEqual(ConvertPhase.extracting.title(for: .firefox), "Unpacking extension")
        XCTAssertEqual(ConvertPhase.staging.title(for: .firefox), "Converting for Firefox")
        XCTAssertEqual(ConvertPhase.installing.title(for: .firefox), "Adding to Firefox")
        XCTAssertEqual(ConvertPhase.installing.title(for: .safari), "Installing to Safari")
    }
}
