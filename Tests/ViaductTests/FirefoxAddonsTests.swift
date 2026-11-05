import XCTest
import ServiceManagement
@testable import Viaduct

@MainActor
final class FirefoxAddonsTests: XCTestCase {
    private let staged = URL(fileURLWithPath: "/cache/Dark Reader/staged_extension")
    private let t0 = Date(timeIntervalSince1970: 1_793_664_000)

    private func make(kept: [PersistAddon] = [], agent status: SMAppService.Status = .notRegistered,
                      test: String = #function) -> (FirefoxAddons, FakePersist, FakeAgent, FakeEvents) {
        let events = FakeEvents()
        let persist = FakePersist(log: events); persist.kept = kept
        let agent = FakeAgent(log: events, status: status)
        return (FirefoxAddons(persist: persist, agent: agent, defaults: TestDefaults.make(test)), persist, agent, events)
    }

    private func install(_ addons: FirefoxAddons, restart: Bool = true) async throws -> PersistResult {
        try await addons.install(staged: staged, profile: "/profiles/a", firefox: "/Applications/Firefox.app", restart: restart, launch: true)
    }

    func testInstallRegistersTheAgentFirst() async throws {
        let (addons, persist, _, events) = make()
        _ = try await addons.install(staged: staged, profile: "/profiles/a", firefox: "/Applications/Firefox.app", restart: true, launch: true)
        XCTAssertEqual(events.events, ["register", "install"])
        XCTAssertEqual(persist.installs.first?.restart, true)
    }

    func testInstallStopsWhenViaductIsOffInLoginItems() async {
        let (addons, persist, agent, _) = make()
        agent.statusAfterRegister = .requiresApproval
        do {
            _ = try await addons.install(staged: staged, profile: nil, firefox: "/Applications/Firefox.app", restart: true, launch: true)
            XCTFail("installed without the agent")
        } catch { XCTAssertEqual(error as? FirefoxAddonsError, .loginItemOff) }
        XCTAssertTrue(persist.installs.isEmpty)
    }

    func testRemovingTheLastAddonUnregistersTheAgent() async throws {
        let (addons, _, agent, _) = make(kept: [FirefoxFixtures.addon()], agent: .enabled)
        try await addons.uninstall(id: "darkreader@viaduct", profile: "/profiles/a", restart: true)
        XCTAssertEqual(agent.unregisterCount, 1)
    }

    func testAgentStaysWhileAnotherAddonIsKept() async throws {
        let (addons, _, agent, _) = make(kept: [FirefoxFixtures.addon(), FirefoxFixtures.addon(id: "store-button@viaduct.magicelklabs.com")], agent: .enabled)
        try await addons.uninstall(id: "darkreader@viaduct", profile: "/profiles/a", restart: true)
        XCTAssertEqual(agent.unregisterCount, 0)
    }

    func testAFailedUninstallOfAnAddonPersistNoLongerKeepsCountsAsDone() async throws {
        let (addons, persist, _, _) = make(kept: [], agent: .enabled)
        persist.uninstallError = .failed(#"No add-on named "darkreader@viaduct" or with that ID is kept for /profiles/a. Run list to see the kept add-ons."#)
        try await addons.uninstall(id: "darkreader@viaduct", profile: "/profiles/a", restart: true)
    }

    func testAFailedUninstallOfAKeptAddonThrows() async {
        let (addons, persist, _, _) = make(kept: [FirefoxFixtures.addon()], agent: .enabled)
        persist.uninstallError = .failed("Firefox is busy")
        do { try await addons.uninstall(id: "darkreader@viaduct", profile: "/profiles/a", restart: true); XCTFail("no error") }
        catch { XCTAssertEqual(error as? PersistError, .failed("Firefox is busy")) }
    }

    func testProfileChoiceFallsBackToTheDefault() {
        let a = FirefoxFixtures.profile(name: "default-release", path: "/profiles/a", isDefault: true)
        let b = FirefoxFixtures.profile(name: "work", path: "/profiles/b", isDefault: false)
        XCTAssertEqual(FirefoxProfileChoice.resolve(stored: "/profiles/b", in: [a, b]), b)
        XCTAssertEqual(FirefoxProfileChoice.resolve(stored: "/profiles/deleted", in: [a, b]), a)
        XCTAssertEqual(FirefoxProfileChoice.resolve(stored: nil, in: [b, a]), a)
        XCTAssertEqual(FirefoxProfileChoice.resolve(stored: nil, in: [b]), b)
        XCTAssertNil(FirefoxProfileChoice.resolve(stored: nil, in: []))
    }

    func testFirefoxWithoutAProfileStopsBeforeConverting() async {
        let (addons, persist, _, _) = make()
        persist.profilesResult = PersistProfiles(firefoxes: [], profiles: [])
        do { _ = try await addons.target(firefox: FirefoxFixtures.install()); XCTFail("no error") }
        catch { XCTAssertEqual(error as? FirefoxAddonsError, .noProfile) }
    }

    func testRestartQuestion() {
        XCTAssertFalse(FirefoxAddons.restartQuestionNeeded(profileInUse: false, keptInProfile: 0, pendingSince: nil, lastLoad: nil))
        XCTAssertTrue(FirefoxAddons.restartQuestionNeeded(profileInUse: true, keptInProfile: 0, pendingSince: nil, lastLoad: nil))
        XCTAssertFalse(FirefoxAddons.restartQuestionNeeded(profileInUse: true, keptInProfile: 2, pendingSince: nil, lastLoad: t0))
        XCTAssertTrue(FirefoxAddons.restartQuestionNeeded(profileInUse: true, keptInProfile: 1, pendingSince: t0, lastLoad: t0 - 60))
        XCTAssertFalse(FirefoxAddons.restartQuestionNeeded(profileInUse: true, keptInProfile: 1, pendingSince: t0, lastLoad: t0 + 60))
    }

    func testAfterLaterTheNextInstallIntoTheOpenProfileAsksAgain() async throws {
        let (addons, persist, _, _) = make(agent: .enabled)
        persist.profilesResult = PersistProfiles(firefoxes: [], profiles: [FirefoxFixtures.profile(inUse: true)])
        persist.installResult = .success(FirefoxFixtures.result(pending: true))   // "Later"
        _ = try await addons.install(staged: staged, profile: "/profiles/a", firefox: "/Applications/Firefox.app", restart: false, launch: true)
        let target = try await addons.target(firefox: FirefoxFixtures.install())
        XCTAssertEqual(target, FirefoxTarget(profilePath: "/profiles/a", askRestart: true))
    }

    // MARK: - Pending add-ons

    func testAnInstallThatLoadsEndsThePendingState() async throws {
        let (addons, persist, _, _) = make(agent: .enabled)
        persist.installResult = .success(FirefoxFixtures.result(pending: true))
        _ = try await install(addons, restart: false)
        XCTAssertNotNil(addons.pendingSince(profilePath: "/profiles/a"))
        persist.installResult = .success(FirefoxFixtures.result(pending: false))
        _ = try await install(addons)
        XCTAssertNil(addons.pendingSince(profilePath: "/profiles/a"))
    }

    func testALoadAfterLaterEndsThePendingState() async throws {
        let (addons, persist, _, _) = make(agent: .enabled)
        persist.profilesResult = PersistProfiles(firefoxes: [], profiles: [FirefoxFixtures.profile(inUse: true)])
        persist.installResult = .success(FirefoxFixtures.result(pending: true))
        _ = try await install(addons, restart: false)
        let loaded = PersistStatus.Profile(profilePath: "/profiles/a", lastLoad: Date().addingTimeInterval(60), lastError: nil)
        persist.statusResult = PersistStatus(agent: .init(running: true, pid: 1), profiles: [loaded])
        let target = try await addons.target(firefox: FirefoxFixtures.install())
        XCTAssertEqual(target, FirefoxTarget(profilePath: "/profiles/a", askRestart: false))
        XCTAssertNil(addons.pendingSince(profilePath: "/profiles/a"))
    }

    // MARK: - Agent lifetime

    func testAnInstallRestartsAnAgentPersistSaysIsntRunning() async throws {
        let (addons, persist, _, events) = make(kept: [FirefoxFixtures.addon()], agent: .enabled)
        persist.statusResult = PersistStatus(agent: .init(running: false, pid: nil), profiles: [])
        _ = try await install(addons)
        XCTAssertEqual(events.events, ["unregister", "register", "install"])
    }

    func testAnInstallLeavesARunningAgentAlone() async throws {
        let (addons, _, _, events) = make(kept: [FirefoxFixtures.addon()], agent: .enabled)
        _ = try await install(addons)
        XCTAssertEqual(events.events, ["install"])
    }

    func testAFailedFirstInstallUnregistersTheAgent() async {
        let (addons, persist, _, events) = make()
        persist.installResult = .failure(.failed("Firefox is busy"))
        do { _ = try await install(addons); XCTFail("no error") }
        catch { XCTAssertEqual(error as? PersistError, .failed("Firefox is busy")) }
        XCTAssertEqual(events.events, ["register", "install", "unregister"])
    }

    func testAFailedInstallKeepsTheAgentForAddonsStillKept() async {
        let (addons, persist, agent, _) = make(kept: [FirefoxFixtures.addon()], agent: .enabled)
        persist.installResult = .failure(.failed("Firefox is busy"))
        _ = try? await install(addons)
        XCTAssertEqual(agent.unregisterCount, 0)
    }

    /// Unregistered, the agent would drop out of Login Items, where the user has to turn it on.
    func testAnInstallStoppedAtLoginItemsLeavesTheAgentThere() async {
        let (addons, _, agent, _) = make()
        agent.statusAfterRegister = .requiresApproval
        _ = try? await install(addons)
        XCTAssertEqual(agent.status, .requiresApproval)
    }

    /// Persist hasn't kept anything for the running install yet, and it still might.
    func testAnUninstallLeavesTheAgentWhileAnInstallRuns() async throws {
        let (addons, persist, agent, _) = make(kept: [FirefoxFixtures.addon()], agent: .enabled)
        persist.installResult = .failure(.failed("Firefox is busy"))
        let hold = Hold()
        persist.onInstall = { await hold.wait() }
        let installing = Task { try await install(addons) }
        await hold.reached()

        try await addons.uninstall(id: "darkreader@viaduct", profile: "/profiles/a", restart: false)
        XCTAssertEqual(agent.unregisterCount, 0)

        hold.release()
        _ = try? await installing.value
        XCTAssertEqual(agent.unregisterCount, 1)
    }

    /// Persist kept the install's add-on, then the uninstall took it out and ended first.
    func testTheLastCallToEndChecksTheAgentAgain() async throws {
        let (addons, persist, agent, _) = make()
        let hold = Hold()
        persist.onInstall = { await hold.wait() }
        let installing = Task { try await install(addons) }
        await hold.reached()

        try await addons.uninstall(id: "darkreader@viaduct", profile: "/profiles/a", restart: false)
        XCTAssertEqual(agent.unregisterCount, 0)

        hold.release()
        _ = try await installing.value
        XCTAssertEqual(agent.unregisterCount, 1)
    }

    // MARK: - App updates

    func testAgentRestartAfterAnUpdate() {
        XCTAssertTrue(FirefoxAddons.agentNeedsRestart(status: .enabled, startedBy: "1.4.0", appBuild: "1.5.0"))
        XCTAssertTrue(FirefoxAddons.agentNeedsRestart(status: .enabled, startedBy: nil, appBuild: "1.5.0"))
        XCTAssertFalse(FirefoxAddons.agentNeedsRestart(status: .enabled, startedBy: "1.5.0", appBuild: "1.5.0"))
        XCTAssertFalse(FirefoxAddons.agentNeedsRestart(status: .notRegistered, startedBy: "1.4.0", appBuild: "1.5.0"))
        XCTAssertFalse(FirefoxAddons.agentNeedsRestart(status: .requiresApproval, startedBy: "1.4.0", appBuild: "1.5.0"))
    }

    /// Registered by a build from before the app noted which build that was.
    func testALaunchRestartsAnAgentWithNoBuildNoted() throws {
        let (addons, _, _, events) = make(agent: .enabled)
        try addons.restartAgentAfterUpdate()
        XCTAssertEqual(events.events, ["unregister", "register"])
    }

    func testOnlyALaunchOfANewBuildRestartsTheAgent() async throws {
        let events = FakeEvents()
        let persist = FakePersist(log: events)
        let agent = FakeAgent(log: events)
        let defaults = TestDefaults.make()
        func launch(_ build: String) -> FirefoxAddons {
            FirefoxAddons(persist: persist, agent: agent, defaults: defaults, appBuild: build)
        }

        _ = try await install(launch("1.4.0"))
        try launch("1.4.0").restartAgentAfterUpdate()
        XCTAssertEqual(events.events, ["register", "install"])

        try launch("1.5.0").restartAgentAfterUpdate()
        try launch("1.5.0").restartAgentAfterUpdate()
        XCTAssertEqual(events.events, ["register", "install", "unregister", "register"])
    }

    func testErrorsReadAsTheirCopy() {
        XCTAssertEqual(FirefoxAddonsError.noProfile.localizedDescription,
                       "Open Firefox once so it can set up your profile, then try again.")
        XCTAssertEqual(FirefoxAddonsError.loginItemOff.localizedDescription,
                       "Firefox only keeps your add-ons while Viaduct can run in the background. Turn Viaduct on in Login Items, then try again.")
    }
}

/// Keeps a fake persist call running until `release()`.
@MainActor
private final class Hold {
    private var waiting: CheckedContinuation<Void, Never>?

    func wait() async { await withCheckedContinuation { waiting = $0 } }

    /// Lets the other task run until its call waits here.
    func reached() async {
        for _ in 0..<1_000 where waiting == nil { await Task.yield() }
    }

    func release() {
        waiting?.resume()
        waiting = nil
    }
}
