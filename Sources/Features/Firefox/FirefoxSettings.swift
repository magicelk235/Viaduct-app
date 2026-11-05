import SwiftUI
import AppKit
import ServiceManagement

/// Settings → Extensions card: which Firefox conversions go into, and the
/// profile when Firefox has more than one.
struct FirefoxSection: View {
    @State private var firefox = FirefoxLocator.find()
    @State private var profiles: [PersistProfiles.Profile] = []
    @AppStorage(FirefoxAddons.profileKey) private var storedProfile: String?

    var body: some View {
        SettingsSection(title: "Firefox", symbol: "flame") {
            if let firefox {
                FirefoxValueRow {
                    StateDot(color: Theme.Colors.accentGreen)
                } value: {
                    Text(firefox.displayName).foregroundColor(Theme.Colors.ink)
                        + Text(firefox.version.map { " \($0)" } ?? "").font(Theme.Font.mono())
                            .foregroundColor(Theme.Colors.body)
                }
                if profiles.count > 1 {
                    Divider().overlay(Theme.Colors.hairlineSoft)
                    HStack(spacing: Theme.Space.sm) {
                        Text("Profile")
                            .font(Theme.Font.body())
                            .foregroundStyle(Theme.Colors.body)
                        Spacer(minLength: Theme.Space.sm)
                        Picker("Profile", selection: profileSelection) {
                            ForEach(profiles) { Text($0.name).tag($0.path) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            } else {
                FirefoxValueRow {
                    StateDot(color: Theme.Colors.ash)
                } value: {
                    Text("Not installed").foregroundColor(Theme.Colors.body)
                } trailing: {
                    Button("Get Firefox") { NSWorkspace.shared.open(FirefoxLocator.downloadURL) }
                        .buttonStyle(.raycastTertiary)
                        .fixedSize()
                }
            }
        }
        .task { await loadProfiles() }
    }

    /// Shows the profile the next install goes into, so a profile that's
    /// since been deleted reads as the default rather than as nothing.
    private var profileSelection: Binding<String> {
        Binding(get: { FirefoxProfileChoice.resolve(stored: storedProfile, in: profiles)?.path ?? "" },
                set: { storedProfile = $0 })
    }

    private func loadProfiles() async {
        guard let firefox else { return }
        profiles = (try? await FirefoxAddons.shared.persist.profiles(firefox: firefox.appURL.path).profiles) ?? []
    }
}

/// Settings → General card for the agent that loads Firefox add-ons: whether
/// it runs, and when each profile last loaded them.
struct FirefoxAgentSection: View {
    @ObservedObject var history: ConversionHistory
    @State private var agentStatus = FirefoxAddons.shared.agentStatus
    @State private var status: PersistStatus?
    /// Persist takes a moment to answer; until then the row doesn't claim either way.
    @State private var loaded = false
    @State private var profiles: [PersistProfiles.Profile] = []
    @State private var firefox = FirefoxLocator.find()
    /// Why the last Restart Agent didn't go through.
    @State private var restartError: String?

    init(history: ConversionHistory) {
        self.history = history
    }

    var body: some View {
        if history.records.contains(where: { $0.browser == .firefox })
            || agentStatus == .enabled || agentStatus == .requiresApproval {
            SettingsSection(title: "Firefox agent", symbol: "flame") {
                agentRow
                ForEach(status?.profiles ?? [], id: \.profilePath) { profile in
                    Divider().overlay(Theme.Colors.hairlineSoft)
                    profileRow(profile)
                }
            }
            .task { await load() }
            .alert("Couldn't restart the Firefox agent",
                   isPresented: Binding(get: { restartError != nil }, set: { if !$0 { restartError = nil } }),
                   presenting: restartError) { _ in
                Button("OK", role: .cancel) {}
            } message: { Text($0) }
        }
    }

    @ViewBuilder
    private var agentRow: some View {
        if agentStatus == .requiresApproval {
            FirefoxValueRow {
                StateDot(color: Theme.Colors.accentRed)
            } value: {
                Text("Off in Login Items").foregroundColor(Theme.Colors.ink)
            } trailing: {
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    .buttonStyle(.raycastTertiary)
                    .fixedSize()
            }
        } else {
            let running = status?.agent.running == true
            FirefoxValueRow {
                StateDot(color: running ? Theme.Colors.accentGreen : Theme.Colors.ash)
            } value: {
                Text(loaded ? (running ? "Running" : "Not running") : " ").foregroundColor(Theme.Colors.ink)
            } trailing: {
                Button("Restart Agent") { restart() }
                    .buttonStyle(.raycastTertiary)
                    .fixedSize()
            }
        }
    }

    private func profileRow(_ profile: PersistStatus.Profile) -> some View {
        let state = Self.loadState(of: profile, firefox: firefox)
        return FirefoxValueRow {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Colors.primary)
        } value: {
            Text(Self.name(of: profile.profilePath, in: profiles))
                .foregroundColor(Theme.Colors.ink)
                .lineLimit(1).truncationMode(.middle)
        } trailing: {
            Text(state.text)
                .tracked()
                .font(Theme.Font.caption())
                .foregroundStyle(state.error == nil ? Theme.Colors.mute : Theme.Colors.accentRed)
                .fixedSize()
                .help(state.error ?? "")
        }
    }

    private func restart() {
        do {
            try FirefoxAddons.shared.restartAgent()
        } catch {
            restartError = error.localizedDescription
        }
        Task {
            // launchd takes a moment to start it again.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await load()
        }
    }

    private func load() async {
        let persist = FirefoxAddons.shared.persist
        let newStatus = try? await persist.status()
        let newProfiles = (try? await persist.profiles(firefox: firefox?.appURL.path).profiles) ?? []
        // Set together, so the rows don't show folder names first.
        agentStatus = FirefoxAddons.shared.agentStatus
        status = newStatus
        profiles = newProfiles
        loaded = true
    }

    /// The profile's name in Firefox, else its folder name.
    nonisolated static func name(of path: String, in profiles: [PersistProfiles.Profile]) -> String {
        profiles.first { $0.path == path }?.name ?? URL(fileURLWithPath: path).lastPathComponent
    }

    /// What a profile row says about its last load. `error` is set when
    /// Firefox refused the add-ons, and holds Firefox's own message.
    nonisolated static func loadState(of profile: PersistStatus.Profile, firefox: FirefoxLocator.Install?,
                                      now: Date = Date()) -> (text: String, error: String?) {
        if let error = profile.lastError {
            let name = [firefox?.displayName ?? "Firefox", firefox?.version].compactMap { $0 }.joined(separator: " ")
            return ("\(name) blocked loading", error)
        }
        guard let lastLoad = profile.lastLoad else { return ("Not loaded yet", nil) }
        let when = RelativeDateTimeFormatter().localizedString(for: min(lastLoad, now), relativeTo: now)
        return ("Loaded \(when)", nil)
    }
}

/// A settings row in the shape of the version rows: an 18pt leading mark, the
/// value, and an optional trailing control.
private struct FirefoxValueRow<Lead: View, Value: View, Trailing: View>: View {
    @ViewBuilder var lead: () -> Lead
    @ViewBuilder var value: () -> Value
    @ViewBuilder var trailing: () -> Trailing

    init(@ViewBuilder lead: @escaping () -> Lead,
         @ViewBuilder value: @escaping () -> Value,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.lead = lead
        self.value = value
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            lead().frame(width: 18)
            value().font(Theme.Font.body())
            Spacer(minLength: Theme.Space.sm)
            trailing()
        }
        .frame(minHeight: 28)
    }
}

/// The small state light on a value row.
private struct StateDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
    }
}
