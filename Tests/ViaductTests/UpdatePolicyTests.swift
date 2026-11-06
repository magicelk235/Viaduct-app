@testable import Viaduct
import XCTest

final class UpdatePolicyTests: XCTestCase {
    private let day: TimeInterval = 24 * 3600

    func testVersionChanged() {
        XCTAssertTrue(UpdatePolicy.versionChanged(stored: "1.2.0", latest: "1.3.0"))
        XCTAssertFalse(UpdatePolicy.versionChanged(stored: "1.2.0", latest: "1.2.0"))
        XCTAssertTrue(UpdatePolicy.versionChanged(stored: nil, latest: "1.0.0"),
                      "nil stored → unknown → treat as changed")
    }

    func testWeeklyGate() {
        let now = Date()
        XCTAssertTrue(UpdatePolicy.dueForUpdateCheck(lastCheck: nil, now: now),
                      "never checked → due")
        XCTAssertFalse(UpdatePolicy.dueForUpdateCheck(lastCheck: now.addingTimeInterval(-3 * day), now: now),
                       "checked 3 days ago → not due (weekly)")
        XCTAssertTrue(UpdatePolicy.dueForUpdateCheck(lastCheck: now.addingTimeInterval(-8 * day), now: now),
                      "checked 8 days ago → due")
    }
}
