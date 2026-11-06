import XCTest
@testable import Viaduct

@MainActor
final class SetupStepsTests: XCTestCase {
    func testChoosingFirefoxSkipsXcodeAndTheAppleAccount() {
        XCTAssertEqual(SetupFlow.steps(for: .firefox, hasBrowsers: true), [.firefox, .diskAccess, .firefoxStoreButton, .license])
        XCTAssertEqual(SetupFlow.steps(for: .firefox, hasBrowsers: false), [.firefox, .firefoxStoreButton, .license])
        XCTAssertEqual(SetupFlow.steps(for: .safari, hasBrowsers: true), [.xcode, .appleAccount, .diskAccess, .storeButton, .license])
    }
}
