@testable import Viaduct
import XCTest

final class PolarClientTests: XCTestCase {
    private func body(_ s: String) -> Data { Data(s.utf8) }

    func testActivationReadsItsIdAndTheKeysBenefit() throws {
        let json = #"{"id":"act-1","license_key_id":"lk-1","label":"Mac","meta":{},"created_at":"2026-11-03T00:00:00Z","modified_at":null,"license_key":{"id":"lk-1","benefit_id":"b-sa","key":"K","status":"granted"}}"#
        XCTAssertEqual(try PolarClient.activation(from: body(json)), PolarActivation(activationId: "act-1", benefitId: "b-sa"))
    }

    func testValidationReadsTheBenefit() throws {
        let json = #"{"id":"lk-1","benefit_id":"b-ff","key":"K","status":"granted","activation":{"id":"act-1"}}"#
        XCTAssertEqual(try PolarClient.benefitId(from: body(json)), "b-ff")
    }

    func testActivationLimitIsItsOwnError() {
        XCTAssertEqual(PolarClient.error(status: 403, body: body(#"{"error":"NotPermitted","detail":"License key activation limit already reached"}"#)),
                       .activationLimitReached("License key activation limit already reached"))
    }

    func testRevokedAndUnknownKeys() {
        XCTAssertEqual(PolarClient.error(status: 403, body: body(#"{"error":"NotPermitted","detail":"License key has expired."}"#)),
                       .rejected("License key has expired."))
        XCTAssertEqual(PolarClient.error(status: 404, body: body(#"{"error":"ResourceNotFound","detail":"License key is no longer active."}"#)),
                       .rejected("License key is no longer active."))
        XCTAssertEqual(PolarClient.error(status: 404, body: body(#"{"error":"ResourceNotFound","detail":"Not found"}"#)),
                       .unknownKey)
    }

    func testAnythingUnexpectedKeepsTheKey() {
        XCTAssertEqual(PolarClient.error(status: 404, body: body("<html>Not Found</html>")), .unreachable)
        XCTAssertEqual(PolarClient.error(status: 503, body: Data()), .unreachable)
        XCTAssertEqual(PolarClient.error(status: 422, body: body(#"{"detail":[{"loc":["body","organization_id"],"msg":"invalid","type":"uuid_parsing"}]}"#)), .unreachable)
        XCTAssertThrowsError(try PolarClient.benefitId(from: body(#"{"benefit":"b-ff"}"#))) {
            XCTAssertEqual($0 as? LicenseError, .unreachable)
        }
    }
}
