@testable import Viaduct
import XCTest

@MainActor
final class PaywallTests: XCTestCase {
    func testTitleOnlySaysTheQuotaIsUsedWhenItIs() {
        XCTAssertEqual(ActivationView.title(freeLeft: 0, quota: 2), "You've used your 2 free conversions")
        XCTAssertEqual(ActivationView.title(freeLeft: 1, quota: 2), "Choose a license")
    }

    func testFailedActivationKeepsTheTypedKey() async {
        let m = await LicenseFixtures.manager()   // Polar can't be reached
        let entry = KeyEntry()
        entry.text = "SOME-KEY"
        await entry.submit(to: m)
        XCTAssertEqual(entry.text, "SOME-KEY")
        XCTAssertEqual(entry.error, .unreachable)
    }

    func testSuccessfulActivationClearsTheField() async {
        let polar = FakePolar()
        polar.activateResult = .success(PolarActivation(activationId: "act-1", benefitId: LicenseFixtures.benefitIds[.safari]!))
        let m = await LicenseFixtures.manager(polar: polar)
        let entry = KeyEntry()
        entry.text = "NEW-KEY"
        await entry.submit(to: m)
        XCTAssertEqual(entry.text, "")
        XCTAssertNil(entry.error)
        XCTAssertTrue(m.unlimited(.safari))
    }
}
