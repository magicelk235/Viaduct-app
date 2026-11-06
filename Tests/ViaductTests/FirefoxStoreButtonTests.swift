import XCTest
@testable import Viaduct

@MainActor
final class FirefoxStoreButtonTests: XCTestCase {
    private let P1 = "/tmp/p/default-release"
    private let P2 = "/tmp/p/work"
    private let button = NativeHostProtocol.storeButtonId
    private let firefox = FirefoxLocator.Install(bundleID: "org.mozilla.firefox", appURL: URL(fileURLWithPath: "/Applications/Firefox.app"),
                                                 displayName: "Firefox", version: "145.0")
    private lazy var events = FakeEvents()
    private lazy var persist = FakePersist(log: events)
    private lazy var agent = FakeAgent(log: events)
    private lazy var defaults = TestDefaults.make(name)
    /// The built add-on at 2.0.0, and a host manifest folder of the test's own.
    private lazy var files: FirefoxStoreButton.Files = {
        let root = TempDir.make()
        let addon = root.appendingPathComponent("addon", isDirectory: true)
        try! FileManager.default.createDirectory(at: addon, withIntermediateDirectories: true)
        try! Data(#"{"version": "2.0.0"}"#.utf8).write(to: addon.appendingPathComponent("manifest.json"))
        return FirefoxStoreButton.Files(addon: addon,
                                        hostManifest: root.appendingPathComponent("NativeMessagingHosts/com.magicelk235.viaduct.json"),
                                        helper: URL(fileURLWithPath: "/Applications/Viaduct.app/Contents/Helpers/ViaductHelper"))
    }()

    private func make() -> FirefoxStoreButton { make(firefox: firefox) }

    private func make(firefox: FirefoxLocator.Install?) -> FirefoxStoreButton {
        FirefoxStoreButton(addons: FirefoxAddons(persist: persist, agent: agent, defaults: defaults),
                           files: files, defaults: defaults, locate: { firefox })
    }

    /// Firefox's default profile P1, and P2.
    private func twoProfiles(p1InUse: Bool = false) -> PersistProfiles {
        PersistProfiles(firefoxes: [], profiles: [FirefoxFixtures.profile(name: "default-release", path: P1, isDefault: true, inUse: p1InUse),
                                                  FirefoxFixtures.profile(name: "work", path: P2, isDefault: false)])
    }

    private var keptMixedVersions: [PersistAddon] {
        [FirefoxFixtures.addon(id: button, profilePath: P1, version: "1.4.0"),
         FirefoxFixtures.addon(id: button, profilePath: P2, version: "2.0.0"),
         FirefoxFixtures.addon(id: "dr@lavaduct", profilePath: P1, version: "1.0")]
    }

    /// The host manifest as an earlier install left it.
    private func writeManifest(helper: String = "/Applications/Viaduct.app/Contents/Helpers/ViaductHelper") throws {
        try FileManager.default.createDirectory(at: files.hostManifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FirefoxStoreButton.hostManifest(helperPath: helper).write(to: files.hostManifest)
    }

    private var manifestExists: Bool { FileManager.default.fileExists(atPath: files.hostManifest.path) }

    /// Changes whenever the manifest is written again, even with the same bytes.
    private func manifestFileNumber() throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: files.hostManifest.path)[.systemFileNumber] as? Int
    }

    // MARK: - Which copies count

    func test_isOnOnlyInTheChosenProfile() {
        let kept = [FirefoxFixtures.addon(id: NativeHostProtocol.storeButtonId, profilePath: P1)]
        XCTAssertTrue(FirefoxStoreButton.isOn(kept: kept, profilePath: P1))
        XCTAssertFalse(FirefoxStoreButton.isOn(kept: kept, profilePath: P2))
        XCTAssertFalse(FirefoxStoreButton.isOn(kept: [FirefoxFixtures.addon(id: "dr@lavaduct", profilePath: P1)], profilePath: P1))
        // Without a chosen profile, a copy kept anywhere counts.
        XCTAssertTrue(FirefoxStoreButton.isOn(kept: kept, profilePath: nil))
        XCTAssertFalse(FirefoxStoreButton.isOn(kept: [FirefoxFixtures.addon(id: "dr@lavaduct", profilePath: P1)], profilePath: nil))
    }

    func test_onlyStaleCopiesAreRefreshed() {   // button 1.4.0 in P1, 2.0.0 in P2, another add-on 1.0 in P1
        XCTAssertEqual(FirefoxStoreButton.profilesNeedingRefresh(kept: keptMixedVersions, bundledVersion: "2.0.0"), [P1])
    }

    func test_bundledVersionComesFromTheBuiltManifest() {
        XCTAssertEqual(FirefoxStoreButton.bundledVersion(addon: files.addon), "2.0.0")
        XCTAssertNil(FirefoxStoreButton.bundledVersion(addon: TempDir.make()))
    }

    func test_hostManifestLetsOnlyTheButtonReachTheHelper() throws {
        let m = try JSONSerialization.jsonObject(with: FirefoxStoreButton.hostManifest(helperPath: "/Applications/Viaduct.app/Contents/Helpers/ViaductHelper")) as! [String: Any]
        XCTAssertEqual(m["name"] as? String, NativeHostProtocol.hostName); XCTAssertEqual(m["type"] as? String, "stdio")
        XCTAssertEqual(m["path"] as? String, "/Applications/Viaduct.app/Contents/Helpers/ViaductHelper")
        XCTAssertEqual(m["allowed_extensions"] as? [String], [NativeHostProtocol.storeButtonId])
        XCTAssertEqual(m["description"] as? String, "Viaduct")
    }

    /// The app's own files: the add-on the build stamped, the helper it embeds,
    /// and the manifest name the helper checks for when Firefox starts it.
    func test_liveFilesAreTheBuiltAddonTheHelperAndFirefoxsHostFolder() {
        let live = FirefoxStoreButton.Files.live
        XCTAssertEqual(FirefoxStoreButton.bundledVersion(addon: live.addon), Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: live.helper.path))
        XCTAssertEqual(live.hostManifest.path, NSHomeDirectory() + "/Library/Application Support/Mozilla/NativeMessagingHosts/com.magicelk235.viaduct.json")
        XCTAssertTrue(NativeHostProtocol.isLaunchedByFirefox(arguments: [live.hostManifest.path, NativeHostProtocol.storeButtonId]))
    }

    // MARK: - Installing

    func test_disclosureComesBeforeAnyInstall() async {   // disclosure not accepted
        let b = make(); await b.requestInstall()
        XCTAssertEqual(b.prompt, .disclosure); XCTAssertTrue(persist.installs.isEmpty)
        XCTAssertFalse(manifestExists)
    }

    func test_acceptingTheDisclosureGoesOnToInstall() async {
        let b = make(); await b.requestInstall()
        await b.answerDisclosure(accepted: false)
        XCTAssertNil(b.prompt); XCTAssertFalse(FirefoxDisclosure.isAccepted(defaults)); XCTAssertTrue(persist.installs.isEmpty)
        await b.requestInstall()
        await b.answerDisclosure(accepted: true)
        XCTAssertTrue(FirefoxDisclosure.isAccepted(defaults))
        XCTAssertEqual(persist.installs.map(\.staged), [files.addon])
        XCTAssertNil(b.prompt); XCTAssertEqual(b.state, .on)
    }

    func test_withoutFirefoxThereIsNothingToAskOrInstall() async {
        let b = make(firefox: nil)
        await b.requestInstall()
        XCTAssertEqual(b.state, .needsFirefox); XCTAssertNil(b.prompt); XCTAssertTrue(persist.installs.isEmpty)
        await b.refresh()
        XCTAssertEqual(b.state, .needsFirefox)
    }

    func test_firefoxWithoutAProfileHasToOpenOnceFirst() async {
        FirefoxDisclosure.accept(defaults)
        persist.profilesResult = PersistProfiles(firefoxes: [], profiles: [])
        let b = make(); await b.requestInstall()
        XCTAssertEqual(b.state, .failed(FirefoxAddonsError.noProfile.localizedDescription))
        XCTAssertTrue(persist.installs.isEmpty); XCTAssertFalse(manifestExists)
    }

    func test_restartIsAskedAndLaterInstallsPending() async {   // accepted; profile needs a restart; installResult pending: true
        FirefoxDisclosure.accept(defaults)
        persist.profilesResult = twoProfiles(p1InUse: true)
        persist.installResult = .success(FirefoxFixtures.result(id: button, profilePath: P1, pending: true))
        let b = make(); await b.requestInstall(); XCTAssertEqual(b.prompt, .restart)
        XCTAssertTrue(persist.installs.isEmpty)
        await b.answerRestart(restartNow: false)
        XCTAssertEqual(persist.installs.last?.restart, false); XCTAssertTrue(b.arrivesLater)
        XCTAssertEqual(persist.installs.last?.launch, false); XCTAssertEqual(persist.installs.last?.profile, P1)
        XCTAssertNil(b.prompt); XCTAssertEqual(b.state, .on)
    }

    /// Persist only restarts a Firefox it may start again, so the restart the
    /// user agreed to has to come with launch.
    func test_restartNowLetsPersistRestartFirefox() async {
        FirefoxDisclosure.accept(defaults)
        persist.profilesResult = twoProfiles(p1InUse: true)
        let b = make(); await b.requestInstall()
        await b.answerRestart(restartNow: true)
        XCTAssertEqual(persist.installs.map(\.restart), [true]); XCTAssertEqual(persist.installs.map(\.launch), [true])
        XCTAssertFalse(b.arrivesLater); XCTAssertEqual(b.state, .on)
    }

    func test_installNeverLaunchesFirefoxAndWritesTheHostManifest() async throws {   // accepted; no restart needed
        FirefoxDisclosure.accept(defaults)
        var manifestBeforeInstall = false
        persist.onInstall = { [files] in manifestBeforeInstall = FileManager.default.fileExists(atPath: files.hostManifest.path) }
        let b = make(); await b.requestInstall()
        XCTAssertEqual(persist.installs.last?.staged, files.addon); XCTAssertEqual(persist.installs.last?.launch, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.hostManifest.path))
        XCTAssertEqual(persist.installs.last?.restart, false)
        XCTAssertEqual(persist.installs.last?.firefox, "/Applications/Firefox.app")
        // In place before the button can load and look for the app.
        XCTAssertTrue(manifestBeforeInstall)
        XCTAssertEqual(try Data(contentsOf: files.hostManifest), FirefoxStoreButton.hostManifest(helperPath: files.helper.path))
        XCTAssertEqual(b.state, .on)
    }

    func test_aFailedInstallKeepsTheManifestOnlyForAKeptCopy() async {
        FirefoxDisclosure.accept(defaults)
        persist.installResult = .failure(.failed("Firefox refused the add-on."))
        let b = make(); await b.requestInstall()
        XCTAssertEqual(b.state, .failed("Firefox refused the add-on.")); XCTAssertFalse(manifestExists)
        persist.kept = [FirefoxFixtures.addon(id: button, profilePath: P2)]
        await b.requestInstall()
        XCTAssertEqual(b.state, .failed("Firefox refused the add-on.")); XCTAssertTrue(manifestExists)
    }

    // MARK: - State

    func test_refreshFollowsTheChosenProfile() async {
        persist.profilesResult = twoProfiles()
        persist.kept = [FirefoxFixtures.addon(id: button, profilePath: P2)]
        let b = make()
        XCTAssertEqual(b.state, .checking)
        await b.refresh()
        XCTAssertEqual(b.state, .off)
        persist.kept = [FirefoxFixtures.addon(id: button, profilePath: P1)]
        await b.refresh()
        XCTAssertEqual(b.state, .on)
        // Before Firefox has a profile, a copy kept anywhere counts.
        persist.profilesResult = PersistProfiles(firefoxes: [], profiles: [])
        persist.kept = [FirefoxFixtures.addon(id: button, profilePath: P2)]
        await b.refresh()
        XCTAssertEqual(b.state, .on)
        persist.listError = .failed("Persist couldn't read its list.")
        await b.refresh()
        XCTAssertEqual(b.state, .failed("Persist couldn't read its list."))
    }

    func test_refreshLeavesAnInstallUnderWayAlone() async {   // accepted; no restart needed
        FirefoxDisclosure.accept(defaults)
        let b = make()
        var stateDuringInstall: FirefoxStoreButton.State?
        // The fake keeps the button before this runs, so a refresh would read it as on.
        persist.onInstall = { await b.refresh(); stateDuringInstall = b.state }
        await b.requestInstall()
        XCTAssertEqual(stateDuringInstall, .installing)
        XCTAssertEqual(b.state, .on)
    }

    func test_arrivesLaterClearsOnceFirefoxLoadsTheProfile() async {   // accepted; P1 open; install comes back pending
        FirefoxDisclosure.accept(defaults)
        persist.profilesResult = twoProfiles(p1InUse: true)
        persist.installResult = .success(FirefoxFixtures.result(id: button, profilePath: P1, pending: true))
        let b = make(); await b.requestInstall()
        await b.answerRestart(restartNow: false)
        XCTAssertTrue(b.arrivesLater)
        // Firefox hasn't loaded the profile since.
        await b.refresh()
        XCTAssertTrue(b.arrivesLater); XCTAssertEqual(b.state, .on)
        persist.statusResult = PersistStatus(agent: .init(running: true, pid: 1),
                                             profiles: [.init(profilePath: P1, lastLoad: Date().addingTimeInterval(60), lastError: nil)])
        await b.refresh()
        XCTAssertFalse(b.arrivesLater); XCTAssertEqual(b.state, .on)
    }

    // MARK: - Launch

    func test_launchSyncRefreshesWithoutStartingOrRestartingFirefox() async {   // kept: button 1.4.0 in P1, current in P2
        persist.kept = [FirefoxFixtures.addon(id: button, profilePath: P1, version: "1.4.0"),
                        FirefoxFixtures.addon(id: button, profilePath: P2, version: "2.0.0")]
        await make().syncAfterLaunch()
        XCTAssertEqual(persist.installs.map(\.profile), [P1])
        XCTAssertEqual(persist.installs.last?.restart, false); XCTAssertEqual(persist.installs.last?.launch, false)
        XCTAssertEqual(persist.installs.last?.staged, files.addon)
        // Through the Firefox that copy was kept for.
        XCTAssertEqual(persist.installs.last?.firefox, FirefoxFixtures.binary())
    }

    func test_launchSyncNeverPromptsOrFails() async {   // disclosure not accepted, profile open, install fails
        persist.profilesResult = twoProfiles(p1InUse: true)
        persist.kept = [FirefoxFixtures.addon(id: button, profilePath: P1, version: "1.4.0")]
        persist.installResult = .failure(.failed("Firefox refused the add-on."))
        let b = make(); await b.syncAfterLaunch()
        XCTAssertEqual(persist.installs.count, 1)
        XCTAssertNil(b.prompt); XCTAssertEqual(b.state, .checking)
    }

    func test_launchSyncPointsTheManifestAtThisCopyOfTheHelper() async throws {
        persist.kept = [FirefoxFixtures.addon(id: button, profilePath: P1, version: "2.0.0")]
        try writeManifest(helper: "/Volumes/Old/Viaduct.app/Contents/Helpers/ViaductHelper")
        let b = make(); await b.syncAfterLaunch()
        XCTAssertEqual(try Data(contentsOf: files.hostManifest), FirefoxStoreButton.hostManifest(helperPath: files.helper.path))
        XCTAssertTrue(persist.installs.isEmpty)
        // A manifest that already says the same isn't written again.
        let written = try manifestFileNumber()
        await b.syncAfterLaunch()
        XCTAssertEqual(try manifestFileNumber(), written)
    }

    func test_launchSyncDropsAManifestNothingNeeds() async throws {
        try writeManifest()
        persist.listError = .failed("Persist couldn't read its list.")
        let b = make(); await b.syncAfterLaunch()
        XCTAssertTrue(manifestExists)   // a list that fails says nothing
        persist.listError = nil
        persist.kept = [FirefoxFixtures.addon(id: "dr@lavaduct", profilePath: P1)]
        await b.syncAfterLaunch()
        XCTAssertFalse(manifestExists); XCTAssertTrue(persist.installs.isEmpty)
    }

    // MARK: - Removing

    func test_removeDeletesTheHostManifestOnlyWhenNoProfileKeepsTheButton() async throws {
        // Kept in P1 and P2, chosen P1: the manifest stays. Then with P2 chosen, it goes.
        persist.profilesResult = twoProfiles()
        persist.kept = [FirefoxFixtures.addon(id: button, profilePath: P1), FirefoxFixtures.addon(id: button, profilePath: P2)]
        try writeManifest()
        let b = make(); await b.remove()
        XCTAssertEqual(persist.uninstalls, [.init(id: button, profile: P1, restart: false)])
        XCTAssertTrue(manifestExists); XCTAssertEqual(b.state, .off)
        defaults.set(P2, forKey: FirefoxAddons.profileKey)
        await b.remove()
        XCTAssertEqual(persist.uninstalls, [.init(id: button, profile: P1, restart: false), .init(id: button, profile: P2, restart: false)])
        XCTAssertFalse(manifestExists); XCTAssertEqual(b.state, .off)
    }

    func test_removeWithoutAProfileTakesOneThatKeepsTheButton() async throws {
        persist.profilesResult = PersistProfiles(firefoxes: [], profiles: [])
        persist.kept = [FirefoxFixtures.addon(id: "dr@lavaduct", profilePath: P1), FirefoxFixtures.addon(id: button, profilePath: P2)]
        try writeManifest()
        let b = make(); await b.remove()
        XCTAssertEqual(persist.uninstalls, [.init(id: button, profile: P2, restart: false)])
        XCTAssertFalse(manifestExists); XCTAssertEqual(b.state, .off)
    }

    /// Persist's own words for this name a profile path and a command-line flag.
    func test_aRemovalFirefoxHoldsUpAsksToQuitFirefox() async throws {
        persist.kept = [FirefoxFixtures.addon(id: button)]
        persist.uninstallError = .failed("Firefox has /profiles/a open and has to restart before the add-on's data can be removed. Quit it first, or drop --no-firefox-restart.")
        try writeManifest()
        let b = make(); await b.remove()
        XCTAssertEqual(b.state, .failed("Quit Firefox, then try again."))
        XCTAssertTrue(manifestExists)
        // Try Again re-reads the state, so it offers Remove again rather than an install.
        await b.refresh()
        XCTAssertEqual(b.state, .on); XCTAssertTrue(persist.installs.isEmpty)
    }

    // MARK: - No record, so the free plan and the agent leave it be

    func test_removingTheLastConvertedAddonKeepsTheAgentForTheButton() async throws {
        persist.kept = [FirefoxFixtures.addon(id: "dr@lavaduct", profilePath: P1), FirefoxFixtures.addon(id: NativeHostProtocol.storeButtonId, profilePath: P1)]
        let addons = FirefoxAddons(persist: persist, agent: agent, defaults: defaults)
        try await addons.uninstall(id: "dr@lavaduct", profile: P1, restart: false)
        XCTAssertEqual(agent.unregisterCount, 0)
        try await addons.uninstall(id: NativeHostProtocol.storeButtonId, profile: P1, restart: false)
        XCTAssertEqual(agent.unregisterCount, 1)
    }

    func test_freePlanExpiryNeverRemovesTheButton() async {
        persist.kept = [FirefoxFixtures.addon(id: "dr@lavaduct", profilePath: P1), FirefoxFixtures.addon(id: button, profilePath: P1)]
        let history = ConversionHistory(defaults: defaults, firefox: FirefoxAddons(persist: persist, agent: agent, defaults: defaults))
        history.add(browser: .firefox, name: "Dark Reader", sourcePath: TempDir.make().appendingPathComponent("dr.crx").path,
                    appName: "Dark Reader", installedPath: nil, adHoc: nil, iconData: nil,
                    freeRemovesAt: LicenseFixtures.now.addingTimeInterval(-60), addonId: "dr@lavaduct", profilePath: P1)
        let license = await LicenseFixtures.manager(name: #function + ".license")
        // What FreePlan.sync() runs.
        await FreePlan(history: history, license: license, now: { LicenseFixtures.now }, notifications: nil).runSync()
        XCTAssertEqual(persist.uninstalls.map(\.id), ["dr@lavaduct"])
        XCTAssertEqual(persist.kept.map(\.id), [NativeHostProtocol.storeButtonId])
        XCTAssertEqual(agent.unregisterCount, 0)
        XCTAssertTrue(history.records.isEmpty)
    }
}
