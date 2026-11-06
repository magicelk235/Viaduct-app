import XCTest
@testable import Viaduct

@MainActor
final class FirefoxBatchTests: XCTestCase {
    func ext(_ id: String, enabled: Bool = true, unpacked: Bool = false) -> InstalledBrowserExtension {
        InstalledBrowserExtension(chromeId: id, profile: BrowserProfile(browser: .chrome, directory: URL(fileURLWithPath: "/tmp/Default"), profileName: "Person 1"),
                                  name: id, version: "1", folder: URL(fileURLWithPath: "/tmp/\(id)"), iconPNG: nil,
                                  fromWebStore: true, enabled: enabled, unpacked: unpacked, hasStoredSettings: false)
    }

    func test_firefoxImportKeepsExtensionsThatHaveASafariVersion() {
        let found = [ext(String(repeating: "a", count: 32)), ext(String(repeating: "b", count: 32))]
        let official = { (id: String) in id.hasPrefix("a") }
        XCTAssertEqual(ChromeImportView.defaultSelection(found, browser: .firefox, alreadyIn: { _ in false }, hasOfficialSafariVersion: official).count, 2)
        XCTAssertEqual(ChromeImportView.defaultSelection(found, browser: .safari, alreadyIn: { _ in false }, hasOfficialSafariVersion: official), [found[1].id])
    }

    func test_alreadyInIsAskedPerBrowser() {
        let found = [ext(String(repeating: "a", count: 32)), ext(String(repeating: "b", count: 32))]
        for browser in Browser.allCases {
            let selection = ChromeImportView.defaultSelection(found, browser: browser,
                                                              alreadyIn: { $0.id == found[0].id },
                                                              hasOfficialSafariVersion: { _ in false })
            XCTAssertEqual(selection, [found[1].id], "\(browser)")
        }
    }

    func test_offAndUnpackedStartUnticked() {
        let found = [ext(String(repeating: "a", count: 32), enabled: false),
                     ext(String(repeating: "b", count: 32), unpacked: true),
                     ext(String(repeating: "c", count: 32))]
        XCTAssertEqual(ChromeImportView.defaultSelection(found, browser: .firefox, alreadyIn: { _ in false },
                                                         hasOfficialSafariVersion: { _ in false }),
                       [found[2].id])
    }

    func test_quotaNoteNamesTheBrowsersLicense() {
        XCTAssertEqual(ChromeImportView.quotaNote(selected: 3, freeLeft: 2, unlimited: false, browser: .firefox), "2 free, 1 need a Firefox license")
        XCTAssertEqual(ChromeImportView.quotaNote(selected: 4, freeLeft: 0, unlimited: false, browser: .safari), "0 free, 4 need a Safari license")
        XCTAssertNil(ChromeImportView.quotaNote(selected: 3, freeLeft: 0, unlimited: true, browser: .firefox))
        XCTAssertNil(ChromeImportView.quotaNote(selected: 2, freeLeft: 2, unlimited: false, browser: .safari))
    }

    func test_doneBrowsersDecideTheEndOfBatchButtons() {
        var s = QueueItem(name: "a", browser: .safari) { URL(fileURLWithPath: "/") }; s.status = .done
        var f = QueueItem(name: "b", browser: .firefox) { URL(fileURLWithPath: "/") }; f.status = .done
        var x = QueueItem(name: "c", browser: .firefox) { URL(fileURLWithPath: "/") }; x.status = .failed("no")
        XCTAssertEqual(ConversionQueue.doneBrowsers([s, f, x]), [.safari, .firefox])
        XCTAssertEqual(ConversionQueue.doneBrowsers([x]), [])
    }

    func test_firefoxGateSkipsOnlyTheFirefoxItemsLeft() {
        func item(_ browser: Browser, _ status: QueueItem.Status) -> QueueItem {
            var i = QueueItem(name: "x", browser: browser) { URL(fileURLWithPath: "/") }; i.status = status; return i
        }
        let items = [item(.firefox, .done), item(.firefox, .failed("gate")), item(.safari, .pending),
                     item(.firefox, .pending), item(.safari, .pending), item(.firefox, .pending)]
        XCTAssertEqual(ConversionQueue.skippedByFirefoxGate(items), [3, 5])
    }

    func test_gatesWordTheBatchStop() {
        XCTAssertEqual(FirefoxGate.notInstalled.batchHint, "install Firefox, then run the rest again")
        XCTAssertEqual(FirefoxGate.noProfile.batchHint, "open Firefox once, then run the rest again")
        XCTAssertEqual(FirefoxGate.loginItemOff.batchHint, "turn Viaduct on in Login Items, then run the rest again")
        XCTAssertEqual(FirefoxGate.notInstalled.skippedNote, "Needs Firefox")
        XCTAssertEqual(FirefoxGate.noProfile.skippedNote, "Needs a Firefox profile")
        XCTAssertEqual(FirefoxGate.loginItemOff.skippedNote, "Needs Viaduct in Login Items")
    }
}
