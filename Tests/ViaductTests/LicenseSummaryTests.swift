@testable import Viaduct
import XCTest

final class LicenseSummaryTests: XCTestCase {
    func testSummarySaysWhatIsUnlimited() {
        XCTAssertEqual(Entitlements.mixed.summary(freeLeft: 2, quota: 2),
                       "Safari and Firefox are unlimited on this Mac.")
        XCTAssertEqual(LicenseTier.safari.entitlements.summary(freeLeft: 1, quota: 2),
                       "Safari is unlimited on this Mac. Firefox has 1 of 2 free conversions left.")
        XCTAssertEqual(LicenseTier.firefox.entitlements.summary(freeLeft: 0, quota: 2),
                       "Firefox is unlimited on this Mac. Safari has 0 of 2 free conversions left.")
        XCTAssertEqual(Entitlements.none.summary(freeLeft: 2, quota: 2),
                       "2 of 2 free conversions left. On the free plan, Viaduct removes what you convert after 7 days.")
    }
}
