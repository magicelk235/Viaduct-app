import SwiftUI
import AppKit

/// The pages in the Settings sidebar.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, license, extensions

    var id: Self { self }

    var title: String {
        switch self {
        case .general:    return "General"
        case .license:    return "License"
        case .extensions: return "Extensions"
        }
    }

    var systemImage: String {
        switch self {
        case .general:    return "gearshape"
        case .license:    return "checkmark.seal"
        case .extensions: return "puzzlepiece.extension"
        }
    }
}

/// Which page is showing. Shared so other code can open Settings on a page.
@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var selectedTab: SettingsTab? = .general
}

struct SettingsView: View {
    @ObservedObject var vm: ConverterViewModel
    @ObservedObject private var history: ConversionHistory
    @ObservedObject private var license = LicenseManager.shared
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var navigation = SettingsNavigation.shared
    @StateObject private var keyEntry = KeyEntry()
    /// The key whose Remove was clicked, while its confirmation is up.
    @State private var keyToRemove: StoredKey?
    /// Keys whose Remove is talking to Polar, so it can't be clicked twice.
    @State private var keysBeingRemoved: Set<String> = []
    /// Extensions whose trash is waiting on the uninstall, so it can't be clicked twice.
    @State private var recordsBeingRemoved: Set<ConversionRecord.ID> = []
    /// The removal that didn't go through, while its alert is up.
    @State private var removalFailure: RemovalFailure?
    /// "Up to date" confirmation after a manual CLI check, cleared on a timer so
    /// it doesn't linger as permanent chrome.
    @State private var cliUpToDate = false
    /// True only between a click on the version number and that check finishing,
    /// so background checks never trigger the inline confirmation.
    @State private var cliCheckRequested = false
    /// Back/forward through the pages visited, like System Settings.
    @State private var visited: [SettingsTab] = [.general]
    @State private var visitedIndex = 0
    @State private var steppingThroughHistory = false

    init(vm: ConverterViewModel) {
        self.vm = vm
        _history = ObservedObject(wrappedValue: vm.history)
    }

    private var activeTab: SettingsTab { navigation.selectedTab ?? .general }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 190, max: 190)
                .removingSidebarToggle()
        } detail: {
            page(activeTab)
                .navigationTitle(activeTab.title)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Settings")
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 680, minHeight: 520)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(visitedIndex == 0)
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(visitedIndex >= visited.count - 1)
            }
        }
        .onChange(of: navigation.selectedTab) { _ in recordVisit() }
        // Settings can be the first window a menu-bar-resident launch ever
        // shows, so the store-button state can't rely on the launch hook.
        .task { vm.refreshStoreButton() }
        .removalFailureAlert($removalFailure) { remove($0, restartingFirefox: true) }
    }

    private var sidebar: some View {
        // Clicking empty sidebar space or cmd-clicking the selected row would
        // clear the selection; keep the current page instead.
        List(selection: Binding(get: { navigation.selectedTab },
                                set: { if let tab = $0 { navigation.selectedTab = tab } })) {
            ForEach(SettingsTab.allCases) { tab in
                Label(tab.title, systemImage: tab.systemImage).tag(tab)
            }
        }
        .listStyle(.sidebar)
        .softScrollEdges()
    }

    @ViewBuilder
    private func page(_ tab: SettingsTab) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                switch tab {
                case .general:
                    appUpdateCard
                    cliCard
                    FirefoxAgentSection(history: history)
                    warningsCard
                    SetupAgainSection(vm: vm)
                    supportCard
                case .license:
                    licenseCard
                case .extensions:
                    storeCard
                    // A build without Firefox support has nothing to set here.
                    if BrowserPicker.firefoxAvailable {
                        FirefoxSection()
                        FirefoxStoreButtonCard(button: .shared)
                    }
                    MigrationSection(vm: vm, history: history)
                    // Kept last: the list grows with every conversion, so it
                    // shouldn't push the other sections down.
                    historyCard
                }
            }
            // System Settings' rhythm: one readable column, not cards stretched
            // across whatever width the window happens to be.
            .frame(maxWidth: 560, alignment: .leading)
            .padding(Theme.Space.xl)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.Colors.canvas)
        // A page of its own, so switching pages doesn't keep the last scroll offset.
        .id(tab)
    }

    // MARK: - Page history

    private func step(_ delta: Int) {
        let target = visitedIndex + delta
        guard visited.indices.contains(target) else { return }
        steppingThroughHistory = true
        visitedIndex = target
        navigation.selectedTab = visited[target]
        DispatchQueue.main.async { steppingThroughHistory = false }
    }

    private func recordVisit() {
        guard !steppingThroughHistory, let tab = navigation.selectedTab, visited[visitedIndex] != tab else { return }
        visited = Array(visited.prefix(visitedIndex + 1)) + [tab]
        visitedIndex = visited.count - 1
    }

    // MARK: - Cards

    /// GitHub new-issue URL with the app version, CLI version, macOS version and
    /// last error filled in, so a report arrives with enough to reproduce it.
    private var bugReportURL: URL {
        let app = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        var body = """
        **What happened:**

        **What I expected:**

        ---
        Viaduct \(app) · CLI \(vm.installedVersion)\(vm.persistVersion.map { " · persist \($0)" } ?? "")
        \(ProcessInfo.processInfo.operatingSystemVersionString)
        """
        if let fail = vm.failureSummary {
            body += "\n**Last error:** \(fail)"
        }
        var c = URLComponents(string: "https://github.com/magicelk235/viaduct-app/issues/new")!
        c.queryItems = [
            .init(name: "title", value: "Bug: "),
            .init(name: "body", value: body),
        ]
        return c.url!
    }

    private var cliCard: some View {
        SettingsSection(title: "Command-line tool", symbol: "terminal") {
            VersionRow(version: vm.installedVersion,
                       status: cliStatus,
                       check: checkCLI,
                       checkDisabled: vm.updateChecking || vm.cliInstalling || vm.isRunning,
                       update: vm.updateAvailable ? { vm.updateCLI() } : nil,
                       updateDisabled: vm.isRunning)
            .onChange(of: vm.updateChecking) { checking in
                if !checking { cliCheckFinished() }
            }
        }
    }

    private var cliStatus: String? {
        if vm.cliInstalling { return "Installing…" }
        if vm.updateChecking { return "Checking…" }
        if vm.updateAvailable { return "Update available" }
        return cliUpToDate ? "Up to date" : nil
    }

    /// Manual CLI check. `vm.checkForUpdates()` installs a newer version on its
    /// own, so "up to date" is confirmed when the check finishes with nothing
    /// available. Driven by the checking flag flipping back (see .onChange
    /// below) rather than a fixed delay, which a slow check would outrun.
    private func checkCLI() {
        guard !vm.updateChecking, !vm.isRunning else { return }
        cliUpToDate = false
        cliCheckRequested = true
        vm.checkForUpdates()
    }

    /// Called when a check finishes: show the confirmation briefly, then clear.
    private func cliCheckFinished() {
        guard cliCheckRequested else { return }
        cliCheckRequested = false
        guard !vm.updateAvailable else { return }
        cliUpToDate = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { cliUpToDate = false }
    }

    private var licenseCard: some View {
        let upgrades = LicenseTier.upgrades(from: license.entitlements)
        return SettingsSection {
            Text(license.entitlements.summary(freeLeft: license.freeConversionsRemaining,
                                              quota: license.freeQuota))
                .font(Theme.Font.body())
                .foregroundStyle(Theme.Colors.body)
            if let problem = license.problem {
                Text(problem)
                    .tracked()
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.Colors.accentRed)
            }
            if license.problem == LicenseManager.activationNotFreed, let portal = PolarConfig.portalURL {
                Button("Manage Activations") { NSWorkspace.shared.open(portal) }
                    .buttonStyle(.raycastTertiary)
            }

            if !license.keys.isEmpty {
                ForEach(license.keys) { keyRow($0) }
                Divider().overlay(Theme.Colors.hairlineSoft)
            }

            // Key entry lives here so a user who already bought can activate
            // WITHOUT first spending their free conversions to trigger the
            // paywall sheet.
            TextField("XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX", text: $keyEntry.text)
                .textFieldStyle(.glass)
                .disabled(license.isAddingKey)
                .accessibilityLabel("License key")
                .onSubmit { Task { await keyEntry.submit(to: license) } }
            KeyErrorText(error: keyEntry.error)
            Button {
                Task { await keyEntry.submit(to: license) }
            } label: {
                HStack(spacing: 6) {
                    if license.isAddingKey { ProgressView().controlSize(.small) }
                    Text(license.isAddingKey ? "Activating…" : "Activate")
                }
            }
            .buttonStyle(.raycastPrimary)
            .disabled(!keyEntry.hasText || license.isAddingKey)

            if !upgrades.isEmpty {
                Divider().overlay(Theme.Colors.hairlineSoft)
                VStack(spacing: Theme.Space.sm) {
                    ForEach(upgrades) { tier in
                        TierRow(tier: tier, highlighted: false, owned: false,
                                buyURL: license.checkoutURL(for: tier, source: .settings,
                                                            extensionCount: history.records.count))
                    }
                }
            }
        }
        .confirmationDialog(keyToRemove.map { "Remove the \($0.tier.displayName) license from this Mac?" } ?? "",
                            isPresented: Binding(get: { keyToRemove != nil },
                                                 set: { if !$0 { keyToRemove = nil } }),
                            presenting: keyToRemove) { key in
            Button("Remove", role: .destructive) {
                keysBeingRemoved.insert(key.key)
                Task {
                    await license.removeKey(key)
                    keysBeingRemoved.remove(key.key)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { key in
            switch key.provider {
            case .polar: Text("This frees it for another Mac. You'll need the key to add it again.")
            case .gumroad: Text("You'll need the key to add it again.")
            }
        }
    }

    /// A key on this Mac: the license it is, enough of the key to tell it
    /// apart, and Remove.
    private func keyRow(_ key: StoredKey) -> some View {
        HStack(spacing: Theme.Space.sm) {
            TierBadge(tier: key.tier, color: Theme.Colors.accentGreen)
            Text(key.maskedKey)
                .font(Theme.Font.mono())
                .foregroundStyle(Theme.Colors.body)
                .accessibilityLabel("Key ending in \(String(key.key.suffix(6)))")
            Spacer()
            Button("Remove") { keyToRemove = key }
                .buttonStyle(.raycastTertiary)
                .disabled(keysBeingRemoved.contains(key.key))
                .accessibilityLabel("Remove the \(key.tier.displayName) license")
        }
    }

    private var appUpdateCard: some View {
        SettingsSection(title: "App updates", symbol: "arrow.down.app") {
            // Sparkle presents its own progress and "you're up to date" window,
            // so this row only needs to start the check.
            VersionRow(version: Bundle.main
                .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
                       check: updater.checkForUpdates)
            Divider().overlay(Theme.Colors.hairlineSoft)
            Toggle("Install updates automatically",
                   isOn: Binding(get: { updater.automaticallyChecksForUpdates },
                                 set: { updater.automaticallyChecksForUpdates = $0 }))
                .toggleStyle(.glass)
        }
    }

    /// The bundled Safari extension that adds an Add-to-Safari button to
    /// Chrome Web Store pages. Safari ships it off, so this card is its
    /// permanent home: state, the switch, and (once on) a store shortcut.
    private var storeCard: some View {
        let enabled = vm.storeButtonEnabled == true
        let unlocked = ExtensionUpdater.isUnlocked(by: license.entitlements)
        return SettingsSection(title: "Chrome Web Store", symbol: "safari") {
            if enabled {
                StatusBadge(text: "ON", color: Theme.Colors.accentGreen)
            }
        } content: {
            if enabled {
                Button("Open the Chrome Web Store") { StoreButton.openWebStore() }
                    .buttonStyle(.raycastTertiary)
            } else {
                Button("Turn On in Safari") { StoreButton.openSafariSettings() }
                    .buttonStyle(.raycastPrimary)
            }
            Divider().overlay(Theme.Colors.hairlineSoft)

            // Without the license it needs, the toggle always reads (and
            // stays) off: the binding ignores writes.
            Toggle("Update Chrome Web Store extensions weekly",
                   isOn: unlocked ? $vm.autoUpdate : .constant(false))
                .toggleStyle(.glass)
                .disabled(!unlocked)
                .onChange(of: vm.autoUpdate) { _ in vm.startAutoUpdate() }
            if !unlocked {
                HStack(spacing: Theme.Space.sm) {
                    TierBadge(tier: .single(for: vm.targetBrowser), color: Theme.Colors.accentBlue)
                    // The License page has the key field and the Buy rows.
                    Button("Unlock with a license") { navigation.selectedTab = .license }
                        .buttonStyle(.plain)
                        .font(Theme.Font.caption())
                        .foregroundStyle(Theme.Colors.accentBlue)
                }
            }
        }
    }

    /// Shows and clears the pre-convert signing warning's opt-out. "Convert
    /// Anyway" on that alert stores the choice for good, so this is where a user
    /// sees that the warning is off and turns it back on. Without it, one click
    /// leaves every later conversion signing ad-hoc with nothing said.
    private var warningsCard: some View {
        SettingsSection(title: "Warnings", symbol: "exclamationmark.triangle") {
            Toggle("Ignore the signing warning", isOn: $vm.adhocAcknowledged)
                .toggleStyle(.glass)
        }
    }

    private var historyCard: some View {
        SettingsSection(title: "Converted extensions", symbol: "clock.arrow.circlepath") {
        } content: {
            if !history.records.isEmpty{
                ScrollView {
                    VStack(spacing: Theme.Space.xs) {
                        ForEach(history.records) { historyRow($0) }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
    }

    private var supportCard: some View {
        SettingsSection(title: "Support", symbol: "ladybug") {
            Button("Report a Bug") { NSWorkspace.shared.open(bugReportURL) }
                .buttonStyle(.raycastTertiary)
        }
    }

    /// Per-row state. Ad-hoc shows for everyone, because Safari turns those
    /// extensions off every time it quits; then a store update that didn't go
    /// through.
    @ViewBuilder
    private func rowStatus(_ rec: ConversionRecord) -> some View {
        if rec.adHoc == true {
            Label("No Apple signature: Safari turns it off every time it quits",
                  systemImage: "exclamationmark.triangle.fill")
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.Colors.accentYellow)
                // Two lines: the row is narrow enough that one truncates this to
                // "Ad-hoc signed: Safari turn…", which says nothing.
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help("This build has no Apple signature, so Safari only loads it while Allow Unsigned Extensions is on in the Develop menu. Sign in to Xcode under Settings → Accounts, then convert it again to get a signed build.")
        } else if rec.lastUpdateFailed == true {
            Label("Couldn't update to the new store version. This one still works.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.Colors.accentYellow)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func historyRow(_ rec: ConversionRecord) -> some View {
        HStack(spacing: Theme.Space.md) {
            HistoryIcon(iconData: rec.iconData,
                        monogram: rec.name.first.map(String.init)?.uppercased() ?? "?")
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(rec.name)
                    .font(Theme.Font.bodyStrong())
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    BrowserGlyph(browser: rec.browser)
                    Text(rec.date.formatted(date: .abbreviated, time: .shortened))
                        .font(Theme.Font.caption())
                        .foregroundStyle(Theme.Colors.mute)
                }
                rowStatus(rec)
            }
            Spacer()
            if let path = rec.installedPath {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(Theme.Colors.primary)
                }
                .buttonStyle(.raycastGhost)
                .help("Reveal in Finder")
            }
            Button {
                remove(rec)
            } label: {
                if recordsBeingRemoved.contains(rec.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "trash")
                        .foregroundStyle(Color.red)
                }
            }
            .buttonStyle(.raycastGhost)
            .disabled(recordsBeingRemoved.contains(rec.id))
            .help("Remove this extension")
        }
        .padding(.vertical, Theme.Space.xs)
        .padding(.horizontal, Theme.Space.sm)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
            .fill(Theme.Colors.surfaceElevated))
    }

    private func remove(_ rec: ConversionRecord, restartingFirefox: Bool = false) {
        recordsBeingRemoved.insert(rec.id)
        Task {
            do {
                try await history.remove(rec, restartFirefox: restartingFirefox)
            } catch {
                removalFailure = RemovalFailure(record: rec, error: error)
            }
            recordsBeingRemoved.remove(rec.id)
        }
    }
}

/// A small capsule tag. White text on a solid accent fill — a same-hue text on a
/// low-alpha same-hue capsule washed out to near-invisible in light mode.
struct StatusBadge: View {
    let text: String
    var color: Color
    var body: some View {
        Text(text)
            .font(Theme.Font.caption())
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color))
    }
}

/// The tag naming the license a feature needs.
struct TierBadge: View {
    let tier: LicenseTier
    var color: Color
    var body: some View { StatusBadge(text: tier.displayName.uppercased(), color: color) }
}

// MARK: - Settings building blocks

/// A glass card with an icon + title header and an optional trailing accessory.
/// A card that is the only thing on its page passes no title: the page title
/// already says it, and a card saying it again is the same label twice.
struct SettingsSection<Accessory: View, Content: View>: View {
    let title: String?
    let symbol: String?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(title: String? = nil, symbol: String? = nil,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.symbol = symbol
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        RaycastCard(glass: true) {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                if let title {
                    HStack(spacing: Theme.Space.sm) {
                        if let symbol {
                            Image(systemName: symbol)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.Colors.primary)
                                .frame(width: 18)
                        }
                        Text(title)
                            .font(Theme.Font.headingSM())
                            .foregroundStyle(Theme.Colors.ink)
                        Spacer()
                        accessory()
                    }
                }
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Version line with an explicit update control: the number is plain text and
/// the action is a real button, so nothing is hidden behind clicking the
/// version. `status` carries the inline result ("Checking…", "Up to date").
/// When a newer version is already known, the check button gives way to
/// "Update Now" — the two never compete for the same row.
private struct VersionRow: View {
    let version: String
    var status: String?
    let check: () -> Void
    var checkDisabled = false
    var update: (() -> Void)?
    var updateDisabled = false

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "shippingbox")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Colors.primary)
                .frame(width: 18)
            // No "Version" label: the card title already says what this is, and
            // the word costs the width the button needs to stay on one line
            // once a status ("Up to date") shares the row.
            Text(version)
                .font(Theme.Font.mono())
                .foregroundStyle(Theme.Colors.body)
            Spacer(minLength: Theme.Space.sm)
            if let status {
                Text(status)
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.Colors.mute)
                    .fixedSize()
                    .transition(.opacity)
            }
            if let update {
                Button("Update Now", action: update)
                    .buttonStyle(.raycastPrimary)
                    .fixedSize()
                    .disabled(updateDisabled)
            } else {
                Button("Check for Updates", action: check)
                    .buttonStyle(.raycastTertiary)
                    .fixedSize()
                    .disabled(checkDisabled)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: status)
    }
}
