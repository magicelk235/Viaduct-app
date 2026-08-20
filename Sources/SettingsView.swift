import SwiftUI
import AppKit

struct SettingsView: View {
    @Binding var mode: AppMode
    @ObservedObject var vm: ConverterViewModel
    @ObservedObject private var history: ConversionHistory
    @ObservedObject private var license = LicenseManager.shared
    @ObservedObject private var updater = Updater.shared
    @State private var showDeactivateConfirm = false
    @State private var licenseKey = ""
    /// "Up to date" confirmation after a manual CLI check, cleared on a timer so
    /// it doesn't linger as permanent chrome.
    @State private var cliUpToDate = false
    /// True only between a click on the version number and that check finishing,
    /// so background checks never trigger the inline confirmation.
    @State private var cliCheckRequested = false

    init(mode: Binding<AppMode>, vm: ConverterViewModel) {
        _mode = mode
        self.vm = vm
        _history = ObservedObject(wrappedValue: vm.history)
    }

    var body: some View {
        ZStack {
            Theme.Colors.canvas.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    Text("Settings")
                        .font(Theme.Font.headingXL())
                        .foregroundStyle(Theme.Colors.ink)
                        .padding(.bottom, Theme.Space.xxs)

                    interfaceCard
                    licenseCard
                    appUpdateCard
                    cliCard
                    signingCard
                    warningsCard
                    supportCard
                    historyCard
                }
                .padding(Theme.Space.xl)
            }
        }
        .frame(width: 460, height: 600)
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
        Viaduct \(app) · CLI \(vm.installedVersion)
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

    private var interfaceCard: some View {
        SettingsSection(title: "Mode", symbol: "macwindow") {
            PillTabPicker(options: AppMode.allCases, label: \.label, selection: $mode)
            Text(mode.blurb)
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.Colors.mute)
        }
    }

    private var cliCard: some View {
        SettingsSection(title: "Command-line tool", symbol: "terminal") {
            VersionRow(version: vm.installedVersion,
                       status: cliStatus,
                       check: checkCLI) {
                if vm.updateAvailable {
                    Button("Update Now") { vm.updateCLI() }
                        .buttonStyle(.raycastPrimary)
                        .disabled(vm.isRunning)
                }
            }
            .onChange(of: vm.updateChecking) { checking in
                if !checking { cliCheckFinished() }
            }
        }
    }

    private var cliStatus: String? {
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
        SettingsSection(title: "License", symbol: "checkmark.seal") {
            if license.isLicensed {
                ProBadge(color: Theme.Colors.accentGreen)
            }
        } content: {
            if license.isLicensed {
                Button("Deactivate on this Mac") { showDeactivateConfirm = true }
                    .buttonStyle(.raycastTertiary)
                    .confirmationDialog("Viaduct will go back to the free tier on this Mac",
                                        isPresented: $showDeactivateConfirm) {
                        Button("Deactivate", role: .destructive) {
                            license.deactivateAndClear()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Frees up the seat for another Mac. You'll need your key to activate again.")
                    }
            } else {
                Text("\(license.freeConversionsRemaining) of \(license.freeQuota) free conversions left. A license removes the limit and turns on auto-renew, so Safari stops dropping your extensions after a week.")
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.Colors.mute)

                // Key entry lives here so a user who already bought can activate
                // WITHOUT first spending their free conversions to trigger the
                // paywall sheet (the only other place the key field appeared).
                TextField("XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX", text: $licenseKey)
                    .textFieldStyle(.glass)
                    .disabled(license.state == .checking)
                    .onSubmit(activate)

                if let err = license.lastError {
                    Text(err)
                        .font(Theme.Font.caption())
                        .foregroundStyle(Theme.Colors.accentRed)
                }

                HStack {
                    Button {
                        activate()
                    } label: {
                        HStack(spacing: 6) {
                            if license.state == .checking { ProgressView().controlSize(.small) }
                            Text(license.state == .checking ? "Activating…" : "Activate")
                        }
                    }
                    .buttonStyle(.raycastPrimary)
                    .disabled(license.state == .checking
                              || licenseKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                    Link("Buy a license",
                         destination: URL(string: "https://magicelk235.gumroad.com/l/viaduct")!)
                        .font(Theme.Font.caption())
                        .foregroundStyle(Theme.Colors.accentBlue)
                }
            }
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

    private var signingCard: some View {
        let licensed = license.isLicensed
        return SettingsSection(title: "Keeping extensions working", symbol: "signature") {
            if !licensed {
                ProBadge(color: Theme.Colors.accentBlue)
            }
        } content: {
            // Free users always see (and get) OFF: the binding reads false and
            // ignores writes. Licensed users get the real stored toggle.
            Toggle("Re-sign extensions before they expire",
                   isOn: licensed
                       ? $vm.autoRenew
                       : .constant(false))
                .toggleStyle(.glass)
                .disabled(!licensed)
                .onChange(of: vm.autoRenew) { _ in vm.startAutoRenew() }
            Divider().overlay(Theme.Colors.hairlineSoft)

            Toggle("Update Chrome Web Store extensions weekly",
                   isOn: licensed
                       ? $vm.autoUpdate
                       : .constant(false))
                .toggleStyle(.glass)
                .disabled(!licensed)
                .onChange(of: vm.autoUpdate) { _ in vm.startAutoRenew() }
            if !licensed {
                // Settings is its own window; the activation sheet lives on the
                // main window. Just send them to buy — converting again surfaces
                // the in-app paywall to paste the key.
                Link("Unlock with a license",
                     destination: URL(string: "https://magicelk235.gumroad.com/l/viaduct")!)
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.Colors.accentBlue)
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
            Text("When this is on, Viaduct converts without asking, even when this Mac can't sign with your Apple team. Safari turns those extensions off every time it quits.")
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.Colors.mute)
        }
    }

    private var historyCard: some View {
        SettingsSection(title: "Converted extensions", symbol: "clock.arrow.circlepath") {
            if !history.records.isEmpty {
                Button("Clear") { history.clear() }
                    .buttonStyle(.raycastGhost)
            }
        } content: {
            if history.records.isEmpty {
                Text("Nothing converted yet. Drop an extension on the main window to start.")
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.Colors.mute)
            } else {
                ScrollView {
                    VStack(spacing: Theme.Space.xs) {
                        ForEach(history.records) { historyRow($0) }
                    }
                }
                .frame(maxHeight: 180)
            }
        }
    }

    private var supportCard: some View {
        SettingsSection(title: "Support", symbol: "ladybug") {
            Button("Report a Bug") { NSWorkspace.shared.open(bugReportURL) }
                .buttonStyle(.raycastTertiary)
        }
    }

    /// Auto-renew state for a row: failure is loud (red), otherwise show next renew.
    /// Only shown to licensed users — free tier doesn't auto-renew.
    @ViewBuilder
    private func renewStatus(_ rec: ConversionRecord) -> some View {
        if license.isLicensed && vm.autoRenew {
            if rec.lastRenewFailed == true {
                Label("Couldn't re-sign. Convert it again before \(rec.expiresAt.formatted(date: .abbreviated, time: .omitted))",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.Colors.accentRed)
                    .lineLimit(1)
            } else {
                Text("Re-signs \(rec.expiresAt.formatted(.relative(presentation: .named)))")
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.Colors.ash)
            }
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
                Text(rec.date.formatted(date: .abbreviated, time: .shortened))
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.Colors.mute)
                renewStatus(rec)
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
                history.remove(rec)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.raycastGhost)
            .help("Forget this extension and stop renewing it")
        }
        .padding(.vertical, Theme.Space.xs)
        .padding(.horizontal, Theme.Space.sm)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
            .fill(Theme.Colors.surfaceElevated))
    }

    private func activate() {
        license.activate(key: licenseKey)
    }
}

/// A small "PRO" tag. White text on a solid accent fill — a same-hue text on a
/// low-alpha same-hue capsule washed out to near-invisible in light mode.
struct ProBadge: View {
    var color: Color
    var body: some View {
        Text("PRO")
            .font(Theme.Font.caption())
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color))
    }
}

// MARK: - Settings building blocks

/// A glass card with an icon + title header and an optional trailing accessory.
private struct SettingsSection<Accessory: View, Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(title: String, symbol: String,
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
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Colors.primary)
                        .frame(width: 18)
                    Text(title)
                        .font(Theme.Font.headingSM())
                        .foregroundStyle(Theme.Colors.ink)
                    Spacer()
                    accessory()
                }
                content()
            }
        }
    }
}

/// A version row that doubles as the update control: the number underlines on
/// hover and runs `check` on click, so the card needs no permanent button.
/// `status` carries the inline result ("Checking…", "Up to date"), and any
/// trailing action (an Update Now button) is supplied by the caller.
private struct VersionRow<Trailing: View>: View {
    let version: String
    var status: String?
    let check: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    @State private var hovering = false

    init(version: String, status: String? = nil, check: @escaping () -> Void,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.version = version
        self.status = status
        self.check = check
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "shippingbox")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Colors.primary)
                .frame(width: 18)
            Text("Version")
                .font(Theme.Font.body())
                .foregroundStyle(Theme.Colors.body)
            Spacer()
            if let status {
                Text(status)
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.Colors.mute)
                    .transition(.opacity)
            }
            Text(version)
                .font(Theme.Font.mono())
                .foregroundStyle(Theme.Colors.body)
                .underline(hovering)
                .onHover { inside in
                    hovering = inside
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                .onTapGesture(perform: check)
                .help("Check for updates")
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Check for updates")
            trailing()
        }
        .animation(.easeInOut(duration: 0.15), value: status)
    }
}
