@testable import Viaduct
import XCTest

final class BrowserTests: XCTestCase {
    // History records and viaduct:// links store these strings.
    func testRawValuesAreTheStoredStrings() throws {
        XCTAssertEqual(Browser.allCases.map(\.rawValue), ["safari", "firefox"])
        XCTAssertEqual(try JSONDecoder().decode([Browser].self, from: Data(#"["firefox","safari"]"#.utf8)),
                       [.firefox, .safari])
        XCTAssertEqual(Browser.safari.displayName, "Safari")
        XCTAssertEqual(Browser.firefox.displayName, "Firefox")
    }
}
