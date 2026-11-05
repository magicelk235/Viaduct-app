import ServiceManagement
@testable import Viaduct

/// The order fakes were called in, shared between them.
final class FakeEvents { var events: [String] = [] }

/// Persist in memory. Main-actor bound, like everything that calls it.
@MainActor final class FakePersist: PersistClientProtocol {
    struct Install: Equatable { let staged: URL; let profile: String?; let firefox: String; let restart: Bool; let launch: Bool }
    struct Uninstall: Equatable { let id: String; let profile: String?; let restart: Bool }
    let log: FakeEvents
    var kept: [PersistAddon] = []
    var profilesResult = PersistProfiles(firefoxes: [], profiles: [FirefoxFixtures.profile()])
    var statusResult = PersistStatus(agent: .init(running: true, pid: 1), profiles: [])
    var installResult: Result<PersistResult, PersistError> = .success(FirefoxFixtures.result())
    var uninstallError: PersistError?
    var listError: PersistError?
    var onList: (() -> Void)?
    /// Awaited while an install runs, after a successful one is kept, the way
    /// persist records an add-on before it waits on Firefox.
    var onInstall: (() async -> Void)?
    private(set) var installs: [Install] = []
    private(set) var uninstalls: [Uninstall] = []

    init(log: FakeEvents = FakeEvents()) { self.log = log }

    func install(staged: URL, profile: String?, firefox: String, restart: Bool, launch: Bool) async throws -> PersistResult {
        log.events.append("install")
        installs.append(Install(staged: staged, profile: profile, firefox: firefox, restart: restart, launch: launch))
        if case .success(let result) = installResult {
            kept.removeAll { $0.id == result.id && $0.profilePath == result.profilePath }
            kept.append(PersistAddon(id: result.id, name: result.name, version: result.version,
                                     profilePath: result.profilePath, dir: "/state/\(result.id)", firefox: firefox))
        }
        await onInstall?()
        return try installResult.get()
    }

    func uninstall(id: String, profile: String?, restart: Bool) async throws -> PersistResult {
        log.events.append("uninstall")
        uninstalls.append(Uninstall(id: id, profile: profile, restart: restart))
        if let uninstallError { throw uninstallError }
        kept.removeAll { $0.id == id && (profile == nil || $0.profilePath == profile) }
        return FirefoxFixtures.result(id: id)
    }

    func list() async throws -> [PersistAddon] {
        onList?()
        if let listError { throw listError }
        return kept
    }

    func status() async throws -> PersistStatus { statusResult }

    func profiles(firefox: String?) async throws -> PersistProfiles { profilesResult }
}

/// The Firefox agent, as a status the test sets and register/unregister calls it counts.
final class FakeAgent: FirefoxAgentControlling {
    let log: FakeEvents
    var status: SMAppService.Status
    var statusAfterRegister: SMAppService.Status = .enabled
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    init(log: FakeEvents = FakeEvents(), status: SMAppService.Status = .notRegistered) { self.log = log; self.status = status }
    func register() throws { registerCount += 1; log.events.append("register"); status = statusAfterRegister }
    func unregister() throws { unregisterCount += 1; log.events.append("unregister"); status = .notRegistered }
}

/// Dark Reader in the default profile of /Applications/Firefox.app, unless a test says otherwise.
enum FirefoxFixtures {
    static func addon(id: String = "darkreader@viaduct", profilePath: String = "/profiles/a", version: String = "4.9.99") -> PersistAddon {
        PersistAddon(id: id, name: "Dark Reader", version: version, profilePath: profilePath,
                     dir: "/state/\(id)", firefox: "/Applications/Firefox.app")
    }

    static func result(id: String = "darkreader@viaduct", profilePath: String = "/profiles/a", pending: Bool = false) -> PersistResult {
        PersistResult(id: id, name: "Dark Reader", version: "4.9.99", profilePath: profilePath, pending: pending)
    }

    static func profile(name: String = "default-release", path: String = "/profiles/a", isDefault: Bool = true,
                        inUse: Bool = false) -> PersistProfiles.Profile {
        PersistProfiles.Profile(name: name, path: path, isDefault: isDefault, inUse: inUse)
    }

    static func install(path: String = "/Applications/Firefox.app") -> FirefoxLocator.Install {
        FirefoxLocator.Install(bundleID: "org.mozilla.firefox", appURL: URL(fileURLWithPath: path),
                               displayName: "Firefox", version: "160.0")
    }
}
