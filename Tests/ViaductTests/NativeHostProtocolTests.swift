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

    func test_progressNeedsNoId() {
        XCTAssertEqual(NativeHostProtocol.action(for: ["type": "progress"]), .progress)
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
