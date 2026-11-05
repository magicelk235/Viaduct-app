import Foundation
import ServiceManagement

/// Why a Firefox install can't go ahead. This is the one copy of these
/// messages: anything else that explains these cases shows `errorDescription`.
enum FirefoxAddonsError: LocalizedError, Equatable {
    case noProfile
    case loginItemOff

    var errorDescription: String? {
        switch self {
        case .noProfile:
            return "Open Firefox once so it can set up your profile, then try again."
        case .loginItemOff:
            return "Firefox only keeps your add-ons while Viaduct can run in the background. Turn Viaduct on in Login Items, then try again."
        }
    }
}

/// Where the next install goes, and whether to ask before Firefox restarts for it.
struct FirefoxTarget: Equatable {
    let profilePath: String?
    let askRestart: Bool
}

enum FirefoxProfileChoice {
    /// The stored profile while Firefox still lists it, else Firefox's default
    /// profile, else the first one.
    static func resolve(stored: String?, in profiles: [PersistProfiles.Profile]) -> PersistProfiles.Profile? {
        profiles.first { $0.path == stored } ?? profiles.first(where: \.isDefault) ?? profiles.first
    }
}

/// The one place that installs and removes Firefox add-ons through persist,
/// and that keeps the agent loading them registered while any are kept.
@MainActor
final class FirefoxAddons {
    static let shared = FirefoxAddons(
        persist: PersistClient(log: { line in
            DispatchQueue.main.async { ConverterViewModel.shared.appendLog(line) }
        }),
        agent: FirefoxAgent(),
        defaults: .standard
    )

    static let profileKey = "firefoxProfilePath"
    /// When an install last came back pending, as seconds since 1970 per profile path.
    private static let pendingKey = "firefoxPendingSince"

    let persist: PersistClientProtocol
    private let agent: FirefoxAgentControlling
    private let defaults: UserDefaults
    private var callsInFlight = 0
    /// An agent check was skipped while other calls ran, so the last one to end does it.
    private var agentCheckDeferred = false

    init(persist: PersistClientProtocol, agent: FirefoxAgentControlling, defaults: UserDefaults) {
        self.persist = persist
        self.agent = agent
        self.defaults = defaults
    }

    /// A persist install or uninstall is running.
    var isWorking: Bool { callsInFlight > 0 }

    var agentStatus: SMAppService.Status { agent.status }

    var agentNeedsApproval: Bool { agentStatus == .requiresApproval }

    func install(staged: URL, profile: String?, firefox: String, restart: Bool, launch: Bool) async throws -> PersistResult {
        callsInFlight += 1
        var reachedPersist = false
        do {
            try await readyAgent()
            reachedPersist = true
            let result = try await persist.install(staged: staged, profile: profile, firefox: firefox, restart: restart, launch: launch)
            setPendingSince(result.pending ? Date() : nil, profilePath: result.profilePath)
            await endCall()
            return result
        } catch {
            // A failed install can leave the agent with nothing to load. A
            // failure at the agent leaves it alone: off in Login Items, it has
            // to stay listed there for the user to turn it on.
            await endCall(checkingAgent: reachedPersist)
            throw error
        }
    }

    func uninstall(id: String, profile: String?, restart: Bool) async throws {
        callsInFlight += 1
        do {
            _ = try await persist.uninstall(id: id, profile: profile, restart: restart)
        } catch {
            // Gone from persist's list is as good as removed. A list that
            // fails says nothing, so the error stands.
            guard let kept = try? await persist.list(),
                  !kept.contains(where: { $0.id == id && (profile == nil || $0.profilePath == profile) })
            else {
                await endCall()
                throw error
            }
        }
        await endCall(checkingAgent: true)
    }

    func restartAgent() throws {
        try? agent.unregister()
        try ensureAgent()
    }

    /// The profile the next install goes into, and whether Firefox has it open
    /// in a way that needs the restart question.
    func target(firefox: FirefoxLocator.Install, preferring profilePath: String? = nil) async throws -> FirefoxTarget {
        let profiles = try await persist.profiles(firefox: firefox.appURL.path).profiles
        guard let profile = FirefoxProfileChoice.resolve(stored: profilePath ?? defaults.string(forKey: Self.profileKey),
                                                         in: profiles)
        else { throw FirefoxAddonsError.noProfile }

        // A list that fails counts as nothing kept, so the user is asked rather
        // than having Firefox restart by surprise.
        let kept = (try? await persist.list())?.filter { $0.profilePath == profile.path }.count ?? 0
        let lastLoad = (try? await persist.status())?.profiles.first { $0.profilePath == profile.path }?.lastLoad
        var pending = pendingSince(profilePath: profile.path)
        if let since = pending, let lastLoad, lastLoad > since {
            setPendingSince(nil, profilePath: profile.path)
            pending = nil
        }
        let ask = Self.restartQuestionNeeded(profileInUse: profile.inUse, keptInProfile: kept,
                                             pendingSince: pending, lastLoad: lastLoad)
        return FirefoxTarget(profilePath: profile.path, askRestart: ask)
    }

    /// When an install into the profile came back pending, until Firefox loads it.
    func pendingSince(profilePath: String) -> Date? {
        (defaults.dictionary(forKey: Self.pendingKey)?[profilePath] as? Double).map(Date.init(timeIntervalSince1970:))
    }

    /// Firefox only has to restart for an install when it has the profile open
    /// without persist's setup: nothing is kept there yet, or an add-on that
    /// came back pending hasn't loaded since.
    nonisolated static func restartQuestionNeeded(profileInUse: Bool, keptInProfile: Int, pendingSince: Date?, lastLoad: Date?) -> Bool {
        guard profileInUse else { return false }
        if keptInProfile == 0 { return true }
        guard let pendingSince else { return false }
        return lastLoad.map { pendingSince >= $0 } ?? true
    }

    // MARK: - Agent

    private func ensureAgent() throws {
        switch agent.status {
        case .enabled:
            return
        case .requiresApproval:
            throw FirefoxAddonsError.loginItemOff
        default:
            try agent.register()
            if agent.status == .requiresApproval { throw FirefoxAddonsError.loginItemOff }
        }
    }

    /// Registers the agent before an install. One that's registered but that
    /// persist says isn't running gets restarted, so the add-on loads at
    /// Firefox's next start.
    private func readyAgent() async throws {
        guard agent.status == .enabled else { return try ensureAgent() }
        // A status that fails says nothing either way, and a restart can't fix persist.
        guard let status = try? await persist.status(), !status.agent.running else { return }
        try restartAgent()
    }

    /// Ends a call counted in `callsInFlight`. `checkingAgent` unregisters the
    /// agent when persist keeps nothing. That goes by persist's list, not the
    /// history: not every kept add-on has a record.
    private func endCall(checkingAgent: Bool = false) async {
        if checkingAgent || agentCheckDeferred { await unregisterAgentIfNothingKept() }
        callsInFlight -= 1
    }

    /// While another install or uninstall runs, persist may not have recorded
    /// its add-on yet, so the check waits for the last call to end.
    private func unregisterAgentIfNothingKept() async {
        guard callsInFlight == 1 else { agentCheckDeferred = true; return }
        agentCheckDeferred = false
        guard let kept = try? await persist.list(), kept.isEmpty else { return }
        guard callsInFlight == 1 else { agentCheckDeferred = true; return }
        try? agent.unregister()
    }

    // MARK: - Pending installs

    private func setPendingSince(_ date: Date?, profilePath: String) {
        var since = defaults.dictionary(forKey: Self.pendingKey) as? [String: Double] ?? [:]
        since[profilePath] = date?.timeIntervalSince1970
        defaults.set(since, forKey: Self.pendingKey)
    }
}
