import XCTest
@testable import Viaduct

@MainActor
final class ConversionHistoryTests: XCTestCase {
    func makeHistory(kept: [PersistAddon] = [], defaults: UserDefaults? = nil, test: String = #function) -> (ConversionHistory, FakePersist) {
        let persist = FakePersist(); persist.kept = kept
        let addons = FirefoxAddons(persist: persist, agent: FakeAgent(status: .enabled), defaults: TestDefaults.make(test + ".firefox"))
        return (ConversionHistory(defaults: defaults ?? TestDefaults.make(test + ".history"), firefox: addons), persist)
    }

    func addFirefox(_ history: ConversionHistory, name: String = "Dark Reader", id: String = "darkreader@viaduct",
                    profile: String = "/profiles/a", version: String = "4.9.99", freeRemovesAt: Date? = nil) {
        history.add(browser: .firefox, name: name, sourcePath: TempDir.make().appendingPathComponent("\(name).crx").path,
                    appName: name, installedPath: nil, adHoc: nil, iconData: nil, storeId: "eimadpbcbfnmbkopoojfekhnkhdbieeh",
                    version: version, freeRemovesAt: freeRemovesAt, addonId: id, profilePath: profile)
    }

    func testRecordsWrittenBeforeFirefoxDecodeAsSafari() throws {
        let json = #"[{"id":"5C1F9E9A-0B5D-4E8B-9C59-3F2A1D7E6B10","name":"Dark Reader","sourcePath":"/sources/Dark Reader.crx","appName":"Dark Reader","installedPath":"/Applications/Dark Reader.app","date":783820800,"adHoc":false,"lastUpdateFailed":true,"iconData":"iVBORw0KGgo=","storeId":"eimadpbcbfnmbkopoojfekhnkhdbieeh","chromeId":"eimadpbcbfnmbkopoojfekhnkhdbieeh","version":"4.9.99","lastUpdateCheck":783907200,"freeRemovesAt":784425600}]"#
        let defaults = TestDefaults.make()
        defaults.set(Data(json.utf8), forKey: "conversionHistory")
        let rec = try XCTUnwrap(makeHistory(defaults: defaults).0.records.first)   // a decode failure would drop all history
        XCTAssertEqual(rec.browser, .safari)
        XCTAssertNil(rec.addonId); XCTAssertNil(rec.profilePath)
        XCTAssertEqual(rec.id.uuidString, "5C1F9E9A-0B5D-4E8B-9C59-3F2A1D7E6B10")
        XCTAssertEqual(rec.installedPath, "/Applications/Dark Reader.app")
        XCTAssertEqual(rec.date, Date(timeIntervalSinceReferenceDate: 783_820_800))
        XCTAssertEqual(rec.adHoc, false); XCTAssertEqual(rec.lastUpdateFailed, true)
        XCTAssertEqual(rec.iconData, Data(base64Encoded: "iVBORw0KGgo="))
        XCTAssertEqual(rec.chromeId, "eimadpbcbfnmbkopoojfekhnkhdbieeh"); XCTAssertEqual(rec.version, "4.9.99")
        XCTAssertEqual(rec.lastUpdateCheck, Date(timeIntervalSinceReferenceDate: 783_907_200))
        XCTAssertEqual(rec.freeRemovesAt, Date(timeIntervalSinceReferenceDate: 784_425_600))
    }

    func testFirefoxFieldsSurviveASaveAndReload() {
        let defaults = TestDefaults.make()
        addFirefox(makeHistory(defaults: defaults).0)
        let rec = makeHistory(defaults: defaults).0.records.first
        XCTAssertEqual(rec?.browser, .firefox)
        XCTAssertEqual(rec?.addonId, "darkreader@viaduct")
        XCTAssertEqual(rec?.profilePath, "/profiles/a")
    }

    func testSameNameInBothBrowsersStaysTwoRecords() throws {
        let (history, _) = makeHistory()
        let app = TempDir.make().appendingPathComponent("Dark Reader.app")
        history.add(browser: .safari, name: "Dark Reader", sourcePath: "/s/Dark Reader.crx", appName: "Dark Reader",
                    installedPath: app.path, adHoc: false, iconData: nil, storeId: "eimadpbcbfnmbkopoojfekhnkhdbieeh")
        addFirefox(history)
        addFirefox(history, version: "4.9.100")                     // Convert Again: replaces only the Firefox one
        XCTAssertEqual(history.records.map(\.browser), [.firefox, .safari])
        XCTAssertEqual(history.records.first?.version, "4.9.100")
        addFirefox(history, profile: "/profiles/b")                 // another profile is another install
        XCTAssertEqual(history.records.count, 3)
        XCTAssertTrue(history.isInstalled(storeId: "eimadpbcbfnmbkopoojfekhnkhdbieeh", browser: .firefox))
        XCTAssertFalse(history.isInstalled(storeId: "eimadpbcbfnmbkopoojfekhnkhdbieeh", browser: .safari))   // no .app yet
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertTrue(history.isInstalled(storeId: "eimadpbcbfnmbkopoojfekhnkhdbieeh", browser: .safari))
    }

    func testArchivedSourcesOfBothBrowsersDoNotCollide() throws {
        let root = TempDir.make()
        let crx = TempDir.make().appendingPathComponent("x.crx"); try Data("crx".utf8).write(to: crx)
        let safari = ExtensionUpdater.archiveSource(crx.path, appName: "Dark Reader", browser: .safari, root: root)
        let firefox = ExtensionUpdater.archiveSource(crx.path, appName: "Dark Reader", browser: .firefox, root: root)
        XCTAssertEqual(safari, root.appendingPathComponent("Dark Reader.crx").path)
        XCTAssertEqual(firefox, root.appendingPathComponent("firefox/Dark Reader.crx").path)
    }

    func testArchivingTheArchivedCopyAgainKeepsIt() throws {   // what Convert Again does
        let root = TempDir.make()
        let crx = TempDir.make().appendingPathComponent("x.crx"); try Data("crx".utf8).write(to: crx)
        let first = try XCTUnwrap(ExtensionUpdater.archiveSource(crx.path, appName: "Dark Reader", browser: .firefox, root: root))
        XCTAssertEqual(ExtensionUpdater.archiveSource(first, appName: "Dark Reader", browser: .firefox, root: root), first)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: first)), Data("crx".utf8))
    }
}
