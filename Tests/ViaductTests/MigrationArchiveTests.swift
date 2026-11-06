import XCTest
@testable import Viaduct

@MainActor
final class MigrationArchiveTests: XCTestCase {
    func test_exportFromAnOlderVersionImportsForSafari() throws {
        let json = #"{"format":1,"exported":"2026-10-01T00:00:00Z","extensions":[{"name":"Dark Reader","appName":"Dark Reader","storeId":"eimadpbcbfnmbkopoojfekhnkhdbieeh"}]}"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let items = MigrationArchive.queueItems(from: try d.decode(MigrationArchive.Manifest.self, from: Data(json.utf8)), root: TempDir.make())
        XCTAssertEqual(items.map(\.browser), [.safari])
        XCTAssertEqual(items.map(\.name), ["Dark Reader"])
        XCTAssertEqual(items.first?.storeId, "eimadpbcbfnmbkopoojfekhnkhdbieeh")
    }

    func test_firefoxEntriesComeBackAsFirefox() throws {
        let addons = FirefoxAddons(persist: FakePersist(), agent: FakeAgent(status: .enabled), defaults: TestDefaults.make(#function + ".firefox"))
        let history = ConversionHistory(defaults: TestDefaults.make(#function + ".history"), firefox: addons)
        let sources = TempDir.make()
        for name in ["A", "B"] {
            try Data("zip \(name)".utf8).write(to: sources.appendingPathComponent("\(name).zip"))
        }
        history.add(browser: .safari, name: "A", sourcePath: sources.appendingPathComponent("A.zip").path, appName: "A",
                    installedPath: nil, adHoc: false, iconData: nil)
        history.add(browser: .firefox, name: "B", sourcePath: sources.appendingPathComponent("B.zip").path, appName: "B",
                    installedPath: nil, adHoc: nil, iconData: nil, addonId: "b@viaduct", profilePath: "/profiles/a")

        let zip = TempDir.make().appendingPathComponent("Viaduct extensions.zip")
        XCTAssertEqual(try MigrationArchive.export(history.records, to: zip), 2)
        let unpacked = try MigrationArchive.unpack(zip)
        defer { MigrationArchive.removeExtracted(unpacked.folder, keeping: []) }
        XCTAssertEqual(Set(unpacked.items.map { "\($0.name)/\($0.browser.rawValue)" }), ["A/safari", "B/firefox"])
    }
}
