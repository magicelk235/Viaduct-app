import XCTest
@testable import Viaduct

final class NativeHostProtocolTests: XCTestCase {
    let id = "eimadpbcbfnmbkopoojfekhnkhdbieeh"

    func test_frameIsLittleEndianLengthThenJSON() {
        XCTAssertEqual(NativeHostProtocol.frame(Data("{}".utf8)), Data([2, 0, 0, 0]) + Data("{}".utf8))
    }

    func test_lengthHeaderBounds() {
        XCTAssertEqual(NativeHostProtocol.messageLength(header: Data([0x10, 0, 0, 0])), 16)
        XCTAssertNil(NativeHostProtocol.messageLength(header: Data([2, 0, 0])))
        XCTAssertNil(NativeHostProtocol.messageLength(header: Data([0, 0, 0, 0])))
        XCTAssertNil(NativeHostProtocol.messageLength(header: NativeHostProtocol.frame(Data(count: 1_048_577)).prefix(4)))
    }

    func test_installOpensAFirefoxURLWithTheNameIntact() {
        XCTAssertEqual(NativeHostProtocol.action(for: ["type": "install", "id": id, "name": "C++ & Co"]),
                       .open(StoreRequest(action: .install(name: "C++ & Co"), storeId: id, browser: .firefox).url))
    }

    func test_installKeepsSpacesAroundTheName() {
        XCTAssertEqual(NativeHostProtocol.action(for: ["type": "install", "id": id, "name": " Dark Reader "]),
                       .open(StoreRequest(action: .install(name: " Dark Reader "), storeId: id, browser: .firefox).url))
    }

    func test_removeOpensAFirefoxRemoveURL() {
        XCTAssertEqual(NativeHostProtocol.action(for: ["type": "remove", "id": id]),
                       .open(StoreRequest(action: .remove, storeId: id, browser: .firefox).url))
    }

    func test_badOrMissingIdIsRejected() {
        guard case .reject = NativeHostProtocol.action(for: ["type": "install", "id": "../../x"]) else { return XCTFail() }
        guard case .reject = NativeHostProtocol.action(for: ["type": "remove"]) else { return XCTFail() }
        guard case .reject = NativeHostProtocol.action(for: ["type": "hello"]) else { return XCTFail() }
    }

    func test_progressPollUsesTheFirefoxBusObject() {
        XCTAssertEqual(NativeHostProtocol.action(for: ["type": "progress", "id": id]), .progress(busObject: "firefox:\(id)"))
    }

    func test_progressPollFromAnOlderAddonStillWorks() {
        XCTAssertEqual(NativeHostProtocol.action(for: ["type": "progress"]), .progress(busObject: nil))
    }

    func test_progressPollWithABadIdIsRejected() {
        guard case .reject = NativeHostProtocol.action(for: ["type": "progress", "id": "../../x"]) else { return XCTFail() }
    }

    func test_progressReplyIgnoresOtherPolls() {
        let mine = "firefox:\(id)"
        XCTAssertNil(NativeHostProtocol.progressReply(from: ["state": "active", "forId": id], busObject: mine))
        XCTAssertNil(NativeHostProtocol.progressReply(from: ["state": "active"], busObject: mine))
        XCTAssertEqual(NativeHostProtocol.progressReply(from: ["state": "done", "forId": mine], busObject: mine)?["state"] as? String, "done")
        // An unscoped poll never takes another page's answer.
        XCTAssertNil(NativeHostProtocol.progressReply(from: ["state": "active", "forId": mine], busObject: nil))
        XCTAssertEqual(NativeHostProtocol.progressReply(from: ["state": "idle"], busObject: nil)?["state"] as? String, "idle")
    }

    func test_installedQueryUsesTheFirefoxBusObject() {
        XCTAssertEqual(NativeHostProtocol.action(for: ["type": "installed", "id": id]), .installed(busObject: "firefox:\(id)"))
    }

    func test_installedReplyIgnoresOtherQueries() {
        let mine = "firefox:\(id)"
        XCTAssertNil(NativeHostProtocol.installedReply(from: ["forId": id, "installed": true], busObject: mine))
        XCTAssertNil(NativeHostProtocol.installedReply(from: ["state": "active"], busObject: mine))
        XCTAssertEqual(NativeHostProtocol.installedReply(from: ["forId": mine, "installed": true], busObject: mine)?["installed"] as? Bool, true)
    }

    func test_launchDetection() {
        let manifest = NSHomeDirectory() + "/Library/Application Support/Mozilla/NativeMessagingHosts/com.magicelk235.viaduct.json"
        XCTAssertTrue(NativeHostProtocol.isLaunchedByFirefox(arguments: [manifest, NativeHostProtocol.storeButtonId]))
        XCTAssertFalse(NativeHostProtocol.isLaunchedByFirefox(arguments: ["agent"]))
        XCTAssertFalse(NativeHostProtocol.isLaunchedByFirefox(arguments: [manifest, "other@example.com"]))
    }

    func test_appBundleFromHelperPath() {
        XCTAssertEqual(NativeHostProtocol.appBundle(helperExecutable: URL(fileURLWithPath: "/Applications/Viaduct.app/Contents/Helpers/ViaductHelper")).path,
                       "/Applications/Viaduct.app")
    }
}

/// Which store page gets the app's install progress.
final class InstallProgressScopeTests: XCTestCase {
    typealias Install = InstallProgressBridge.StoreInstall
    let x = "eimadpbcbfnmbkopoojfekhnkhdbieeh"
    let y = "cjpalhdlnbpafiamejdnhcphjbkeiagm"

    func answer(_ query: String?, _ current: Install?, refused: Set<String> = []) -> InstallProgressBridge.Answer {
        InstallProgressBridge.answer(to: query, current: current, refused: refused)
    }

    func test_onlyThePageWhoseInstallIsRunningGetsProgress() {
        let firefoxX = Install(storeId: x, browser: .firefox, stage: .downloading)
        XCTAssertEqual(answer(InstalledQuery.busObject(storeId: x, browser: .firefox), firefoxX), .snapshot)
        XCTAssertEqual(answer(InstalledQuery.busObject(storeId: y, browser: .safari), firefoxX), .idle)
        XCTAssertEqual(answer(InstalledQuery.busObject(storeId: y, browser: .firefox), firefoxX), .idle)
        // Same extension, other browser.
        XCTAssertEqual(answer(InstalledQuery.busObject(storeId: x, browser: .safari), firefoxX), .idle)
    }

    func test_nothingRunningMeansIdle() {
        XCTAssertEqual(answer(InstalledQuery.busObject(storeId: x, browser: .safari), nil), .idle)
    }

    func test_aRefusedInstallEndsItsCard() {
        let firefoxX = Install(storeId: x, browser: .firefox, stage: .converting(inputPath: "/tmp/x.crx"))
        let safariY = InstalledQuery.busObject(storeId: y, browser: .safari)
        XCTAssertEqual(answer(safariY, firefoxX, refused: [safariY]), .refused)
        XCTAssertEqual(answer(safariY, nil, refused: [safariY]), .refused)
        // A second tab asking for the running install follows it instead.
        let firefoxXQuery = InstalledQuery.busObject(storeId: x, browser: .firefox)
        XCTAssertEqual(answer(firefoxXQuery, firefoxX, refused: [firefoxXQuery]), .snapshot)
    }

    func test_unscopedPollFromAnOlderPageScriptKeepsTheSnapshot() {
        XCTAssertEqual(answer(nil, nil), .snapshot)
        XCTAssertEqual(answer(nil, Install(storeId: x, browser: .firefox, stage: .downloading)), .snapshot)
    }

    func test_anInstallStopsBeingCurrentWhenTheFlowMovesOn() {
        let asking = Install(storeId: x, browser: .safari, stage: .asking)
        XCTAssertTrue(asking.isCurrent(inputPath: "", browser: .safari, asking: true))
        XCTAssertFalse(asking.isCurrent(inputPath: "", browser: .safari, asking: false))

        let downloading = Install(storeId: x, browser: .firefox, stage: .downloading)
        XCTAssertTrue(downloading.isCurrent(inputPath: "", browser: .safari, asking: false))
        XCTAssertFalse(downloading.isCurrent(inputPath: "/tmp/other.crx", browser: .safari, asking: false))

        let converting = Install(storeId: x, browser: .firefox, stage: .converting(inputPath: "/tmp/x.crx"))
        XCTAssertTrue(converting.isCurrent(inputPath: "/tmp/x.crx", browser: .firefox, asking: false))
        XCTAssertFalse(converting.isCurrent(inputPath: "/tmp/other.crx", browser: .firefox, asking: false))
        XCTAssertFalse(converting.isCurrent(inputPath: "/tmp/x.crx", browser: .safari, asking: false))
        XCTAssertFalse(converting.isCurrent(inputPath: "", browser: .firefox, asking: false))
    }

    func test_bridgeForgetsARefusalOnceThatInstallIsTakenOn() {
        let bridge = InstallProgressBridge()
        bridge.refuse(storeId: y, browser: .safari)
        XCTAssertEqual(bridge.refused, [y])
        bridge.begin(storeId: y, browser: .safari)
        XCTAssertEqual(bridge.refused, [])
        XCTAssertEqual(bridge.install, Install(storeId: y, browser: .safari, stage: .asking))
        bridge.advance(to: .downloading)
        XCTAssertEqual(bridge.install?.stage, .downloading)
    }
}
