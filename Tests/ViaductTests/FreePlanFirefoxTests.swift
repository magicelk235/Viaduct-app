import XCTest
@testable import Viaduct

@MainActor
final class FreePlanFirefoxTests: XCTestCase {
    private let now = LicenseFixtures.now

    private func makePlan(keys: [StoredKey] = [], test: String = #function) async -> (FreePlan, ConversionHistory, FakePersist) {
        let persist = FakePersist(); persist.kept = [FirefoxFixtures.addon()]
        let addons = FirefoxAddons(persist: persist, agent: FakeAgent(status: .enabled), defaults: TestDefaults.make(test + ".firefox"))
        let history = ConversionHistory(defaults: TestDefaults.make(test + ".history"), firefox: addons)
        history.add(browser: .firefox, name: "Dark Reader", sourcePath: TempDir.make().appendingPathComponent("a.crx").path,
                    appName: "Dark Reader", installedPath: nil, adHoc: nil, iconData: nil,
                    freeRemovesAt: now.addingTimeInterval(-60), addonId: "darkreader@viaduct", profilePath: "/profiles/a")
        let license = await LicenseFixtures.manager(keys: keys, name: test)
        let plan = FreePlan(history: history, license: license, now: { self.now }, notifications: nil)
        return (plan, history, persist)
    }

    func testAnExpiredFreeFirefoxAddonIsUninstalledWithoutRestartingFirefox() async {
        let (plan, history, persist) = await makePlan()
        let removed = await plan.runSync()
        XCTAssertEqual(removed.map(\.name), ["Dark Reader"])
        XCTAssertEqual(persist.uninstalls, [.init(id: "darkreader@viaduct", profile: "/profiles/a", restart: false)])
        XCTAssertTrue(history.records.isEmpty)
    }

    func testAFirefoxAddonFirefoxWontReleaseIsKeptAndRetriedLater() async {
        let (plan, history, persist) = await makePlan()
        persist.uninstallError = .failed("Firefox has /profiles/a open and has to restart before the add-on's data can be removed.")
        let removed = await plan.runSync()
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(history.records.count, 1)
    }

    func testNextSweepDate() {
        XCTAssertEqual(FreePlan.nextSweepDate(removalDates: [now.addingTimeInterval(-60)], now: now), now.addingTimeInterval(3600))
        XCTAssertEqual(FreePlan.nextSweepDate(removalDates: [now.addingTimeInterval(7200), now.addingTimeInterval(60)], now: now), now.addingTimeInterval(60))
        XCTAssertEqual(FreePlan.nextSweepDate(removalDates: [now.addingTimeInterval(-1), now.addingTimeInterval(120)], now: now), now.addingTimeInterval(120))
        XCTAssertNil(FreePlan.nextSweepDate(removalDates: [], now: now))
    }

    func testAFirefoxKeyKeepsFirefoxAddonsButNotSafariOnes() async throws {
        let (plan, history, persist) = await makePlan(keys: [LicenseFixtures.key(.firefox)])
        let src = TempDir.make().appendingPathComponent("s.crx"); try Data("s".utf8).write(to: src)
        history.add(browser: .safari, name: "uBlock", sourcePath: src.path, appName: "uBlock", installedPath: nil,
                    adHoc: false, iconData: nil, freeRemovesAt: now.addingTimeInterval(-60))
        await plan.runSync()
        XCTAssertEqual(history.records.map(\.browser), [.firefox])
        XCTAssertNil(history.records.first?.freeRemovesAt)
        XCTAssertTrue(persist.uninstalls.isEmpty)
    }

    func testTheRemovedNoticeOffersTheBrowserTheRemovedShare() {
        typealias Removed = FreePlan.RemovedExtension
        XCTAssertEqual(Removed.browser(of: [Removed(name: "A", browser: .firefox), Removed(name: "B", browser: .firefox)]), .firefox)
        XCTAssertNil(Removed.browser(of: [Removed(name: "A", browser: .firefox), Removed(name: "B", browser: .safari)]))
    }

    func testRemovedNamesSavedBeforeFirefoxReadAsSafari() {
        let defaults = TestDefaults.make()
        defaults.set(["uBlock"], forKey: "freePlanRemoved")
        XCTAssertEqual(FreePlan.RemovedExtension.saved(in: defaults), [.init(name: "uBlock", browser: .safari)])
        FreePlan.RemovedExtension.save([.init(name: "Dark Reader", browser: .firefox)], in: defaults)
        XCTAssertEqual(FreePlan.RemovedExtension.saved(in: defaults), [.init(name: "Dark Reader", browser: .firefox)])
    }

    func testAReminderNamesTheRecordItWarnsAbout() {
        let id = UUID()
        XCTAssertEqual(FreePlan.recordID(inReminder: "free-plan-removal-\(id.uuidString)-3"), id)
        XCTAssertNil(FreePlan.recordID(inReminder: "free-plan-removed-\(id.uuidString)"))
    }
}
