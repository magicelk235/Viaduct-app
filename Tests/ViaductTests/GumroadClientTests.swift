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

    func testWhichAnswersMeanNo() {
        let cases: [(status: Int, body: String, expected: LicenseError?)] = [
            (200, #"{"success":false,"message":"That license does not exist for the provided product."}"#,
             .rejected("That license does not exist for the provided product.")),
            (400, #"{"success":false,"message":"Bad request"}"#, .unreachable),
            (401, #"{"success":false,"message":"Unauthorized"}"#, .unreachable),
            (403, #"{"success":false,"message":"Forbidden"}"#, .unreachable),
            (200, #"{"success":true,"purchase":{"disputed":true}}"#,
             .rejected("This purchase was disputed; the license is no longer valid.")),
            (200, #"{"success":true,"purchase":{"chargebacked":true}}"#,
             .rejected("This purchase was chargebacked; the license is no longer valid.")),
            (200, #"{"success":true,"purchase":{"subscription_ended_at":"2026-10-01T00:00:00Z"}}"#,
             .rejected("This subscription has ended.")),
            (200, #"{"uses":3,"purchase":{}}"#, .unreachable),
        ]
        for (status, json, expected) in cases {
            XCTAssertEqual(GumroadClient.outcome(status: status, body: body(json)), expected, "\(status) \(json)")
        }
    }
}
