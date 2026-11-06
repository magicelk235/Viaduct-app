import XCTest
@testable import Viaduct

@MainActor
final class ShortcutsTests: XCTestCase {
    func test_listIncludesFirefoxAndSkipsDeletedSafariApps() throws {
        let addons = FirefoxAddons(persist: FakePersist(), agent: FakeAgent(status: .enabled), defaults: TestDefaults.make(#function + ".firefox"))
        let history = ConversionHistory(defaults: TestDefaults.make(#function + ".history"), firefox: addons)
        let app = TempDir.make().appendingPathComponent("A.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        history.add(browser: .safari, name: "A", sourcePath: "/s/A.crx", appName: "A",
                    installedPath: app.path, adHoc: false, iconData: nil)
        history.add(browser: .safari, name: "B", sourcePath: "/s/B.crx", appName: "B",
                    installedPath: TempDir.make().appendingPathComponent("B.app").path, adHoc: false, iconData: nil)
        history.add(browser: .firefox, name: "A", sourcePath: "/s/firefox/A.crx", appName: "A",
                    installedPath: nil, adHoc: nil, iconData: nil, addonId: "a@viaduct", profilePath: "/profiles/a")

        let entries = ListConvertedExtensionsIntent.entries(in: history)
        let got = entries.map { "\($0.name)/\($0.browser.rawValue)" }
        XCTAssertEqual(Set(got), ["A/safari", "A/firefox"])
        XCTAssertEqual(got.count, 2)
        // Each entry is its record, so Shortcuts can look it up again by id.
        let ids = history.records.filter { history.isPresent($0) }.map(\.id)
        XCTAssertEqual(entries.map(\.id), ids)
    }

    func test_entryReadsAsItsNameWithTheBrowserUnderneath() throws {
        let addons = FirefoxAddons(persist: FakePersist(), agent: FakeAgent(status: .enabled), defaults: TestDefaults.make(#function + ".firefox"))
        let history = ConversionHistory(defaults: TestDefaults.make(#function + ".history"), firefox: addons)
        history.add(browser: .firefox, name: "Dark Reader", sourcePath: "/s/firefox/x.crx", appName: "Dark Reader",
                    installedPath: nil, adHoc: nil, iconData: nil, addonId: "d@viaduct", profilePath: "/profiles/a")
        let entry = try XCTUnwrap(ListConvertedExtensionsIntent.entries(in: history).first)
        XCTAssertEqual(String(localized: entry.displayRepresentation.title), "Dark Reader")
        XCTAssertEqual(entry.displayRepresentation.subtitle.map { String(localized: $0) }, "Firefox")
    }
}
