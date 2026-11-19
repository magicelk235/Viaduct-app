import XCTest
@testable import Viaduct

/// A store install or Convert Again can set the card to the browser the picker
/// doesn't show. The picker shows the card's browser, and picking the other one
/// moves the card even when that is the browser saved as the window's choice.
@MainActor
final class BrowserPickerFollowsCardTests: XCTestCase {
    func testPickingTheSavedBrowserStillMovesACardSetToTheOther() {
        let vm = ConverterViewModel.shared
        vm.resetUserFlow()
        vm.targetBrowser = .safari
        vm.options.browser = .firefox
        vm.phase = .failed
        XCTAssertEqual(vm.pickedBrowser, .firefox)

        vm.pickBrowser(.safari)

        XCTAssertEqual(vm.options.browser, .safari)
        XCTAssertEqual(vm.pickedBrowser, .safari)
        XCTAssertEqual(vm.phase, .idle)
        XCTAssertEqual(vm.targetBrowser, .safari)
    }
}
