import XCTest
@testable import Viaduct

/// Starting a new flow must not carry the last run's log or progress into it:
/// the failure card's title, its report and the won't-work check all read them.
@MainActor
final class ConverterFlowResetTests: XCTestCase {
    func testStartingAFlowForgetsTheLastRunsLogAndPhase() {
        let vm = ConverterViewModel.shared
        vm.appendLog("✗ Some other extension failed to build")
        vm.lastReachedTrackPhase = .packaging

        vm.resetUserFlow()

        XCTAssertEqual(vm.logLines, [])
        XCTAssertNil(vm.lastReachedTrackPhase)
    }
}
