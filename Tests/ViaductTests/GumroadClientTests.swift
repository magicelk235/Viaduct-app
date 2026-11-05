@testable import Viaduct
import XCTest

final class GumroadClientTests: XCTestCase {
    private func body(_ s: String) -> Data { Data(s.utf8) }

    func testGoodPurchasePasses() {
        XCTAssertNil(GumroadClient.outcome(status: 200, body: body(#"{"success":true,"uses":3,"purchase":{"refunded":false,"disputed":false,"chargebacked":false}}"#)))
    }

    func testRefundIsRejected() {
        XCTAssertEqual(GumroadClient.outcome(status: 200, body: body(#"{"success":true,"purchase":{"refunded":true}}"#)),
                       .rejected("This purchase was refunded; the license is no longer valid."))
    }

    func testUnknownKeyIsRejectedInGumroadsWords() {
        XCTAssertEqual(GumroadClient.outcome(status: 404, body: body(#"{"success":false,"message":"That license does not exist for the provided product."}"#)),
                       .rejected("That license does not exist for the provided product."))
    }

    func testOutagesAndCaptivePortalsKeepTheKey() {
        XCTAssertEqual(GumroadClient.outcome(status: 500, body: body(#"{"success":false}"#)), .unreachable)
        XCTAssertEqual(GumroadClient.outcome(status: 429, body: body(#"{"success":false,"message":"Too many requests"}"#)), .unreachable)
        XCTAssertEqual(GumroadClient.outcome(status: 200, body: body("<html><body>Sign in to Wi-Fi</body></html>")), .unreachable)
    }
}
