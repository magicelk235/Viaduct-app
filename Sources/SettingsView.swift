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
                    historyCard
                    supportCard
                }
                .padding(Theme.Space.xl)
            }
        }
        .frame(width: 460, height: 600)
    }

    // MARK: - Cards

    private var supportCard: some View {
        SettingsSection(title: "Support", symbol: "ladybug") {
            Text("Something broken? Opens a GitHub issue pre-filled with your app version and the last error so it can be reproduced.")
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.Colors.mute)
            Button("Report a Bug") { NSWorkspace.shared.open(bugReportURL) }
                .buttonStyle(.raycastTertiary)
        }
    }

    /// GitHub new-issue URL with environment details pre-filled — one click
    /// from "it broke" to a reproducible report.
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
        SettingsSection(title: "Interface", symbol: "macwindow") {
            PillTabPicker(options: AppMode.allCases, label: \.label, selection: $mode)
            Text(mode.blurb)
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.Colors.mute)
        }
    }

    private var cliCard: some View {
        SettingsSection(title: "Command-line tool", symbol: "terminal") {
            SettingsRow(icon: "shippingbox", title: "Installed version") {
                Text(vm.installedVersion)
                    .font(Theme.Font.mono())
                    .foregroundStyle(Theme.Colors.body)
            }
            Divider().overlay(Theme.Colors.hairlineSoft)
            HStack {
                Button("Check for Updates") { vm.checkForUpdates() }
                    .buttonStyle(.raycastTertiary)
                    .disabled(vm.updateChecking || vm.isRunning)
                if vm.updateAvailable {
                    Button("Update Now") { vm.updateCLI() }
                        .buttonStyle(.raycastPrimary)
                        .disabled(vm.isRunning)
                }
                Spacer()
                if vm.updateChecking {
                    HStack(spacing: Theme.Space.xs) {
                        ProgressView().controlSize(.small)
                        Text("Checking…")
                            .font(Theme.Font.caption())
                            .foregroundStyle(Theme.Colors.mute)
                    }
                } else if vm.updateAvailable {
                    Label("Update available", systemImage: "arrow.down.circle.fill")
                        .font(Theme.Font.caption())
                        .foregroundStyle(Theme.Colors.accentBlue)
                }
            }
        }
    }

    private var licenseCard: some View {
        SettingsSection(title: "License", symbol: "checkmark.seal") {
            if license.isLicensed {
                ProBadge(color: Theme.Colors.accentGreen)
            }
        } content: {
            if license.isLicensed {
                Text("Your license is active — unlimited conversions and auto-renew.")
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.Colors.mute)
                Button("Deactivate on this Mac") { showDeactivateConfirm = true }
                    .buttonStyle(.raycastTertiary)
                    .confirmationDialog("Deactivate the license on this Mac?",
                                        isPresented: $showDeactivateConfirm) {
                        Button("Deactivate", role: .destructive) {
                            license.deactivateAndClear()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("You'll need to re-enter your key to reactivate. Use this when moving to another Mac.")
                    }
            } else {
                Text("Running on the free tier (\(license.freeConversionsRemaining) of \(license.freeQuota) conversions left). Activate a license for unlimited conversions and auto-renew.")
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
            SettingsRow(icon: "shippingbox", title: "Viaduct version") {
                Text(Bundle.main
                    .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                    .font(Theme.Font.mono())
                    .foregroundStyle(Theme.Colors.body)
            }
            Divider().overlay(Theme.Colors.hairlineSoft)
            Toggle("Install updates automatically",
                   isOn: Binding(get: { updater.automaticallyChecksForUpdates },
                                 set: { updater.automaticallyChecksForUpdates = $0 }))
                .toggleStyle(.glass)
            Text("Checks daily and installs new versions in the background. The update takes effect the next time Viaduct starts.")
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.Colors.mute)
            Button("Check for Updates") { updater.checkForUpdates() }
                .buttonStyle(.raycastTertiary)
        }
    }

    private var signingCard: some View {
        let licensed = license.isLicensed
        return SettingsSection(title: "Signing", symbol: "signature") {
            if !licensed {
                ProBadge(color: Theme.Colors.accentBlue)
            }
        } content: {
            // Free users always see (and get) OFF: the binding reads false and
            // ignores writes. Licensed users get the real stored toggle.
            Toggle("Auto-renew extensions before they expire",
                   isOn: licensed
                       ? $vm.autoRenew
                       : .constant(false))
                .toggleStyle(.glass)
                .disabled(!licensed)
                .onChange(of: vm.autoRenew) { _ in vm.startAutoRenew() }
            Text("Free Apple accounts sign extensions for ~7 days. This rebuilds and re-signs your installed extensions before that lapses, so Safari never drops them. Uses the Apple identity from Xcode automatically.")
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.Colors.mute)

            Divider().overlay(Theme.Colors.hairlineSoft)

            Toggle("Auto-update extensions from the Chrome Web Store",
                   isOn: licensed
                       ? $vm.autoUpdate
                       : .constant(false))
                .toggleStyle(.glass)
                .disabled(!licensed)
                .onChange(of: vm.autoUpdate) { _ in vm.startAutoRenew() }
            Text("When an extension you installed from the Chrome Web Store ships a new version, Viaduct rebuilds and reinstalls it automatically (checked weekly). Off by default; store-page installs only.")
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.Colors.mute)
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

    private var historyCard: some View {
        SettingsSection(title: "Converted extensions", symbol: "clock.arrow.circlepath") {
            if !history.records.isEmpty {
                Button("Clear") { history.clear() }
                    .buttonStyle(.raycastGhost)
            }
        } content: {
            if history.records.isEmpty {
                Text("Extensions you convert will be listed here.")
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

    /// Auto-renew state for a row: failure is loud (red), otherwise show next renew.
    /// Only shown to licensed users — free tier doesn't auto-renew.
    @ViewBuilder
    private func renewStatus(_ rec: ConversionRecord) -> some View {
        if license.isLicensed && vm.autoRenew {
            if rec.lastRenewFailed == true {
                Label("Renew failed — reconvert before \(rec.expiresAt.formatted(date: .abbreviated, time: .omitted))",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.Colors.accentRed)
                    .lineLimit(1)
            } else {
                Text("Renews \(rec.expiresAt.formatted(.relative(presentation: .named)))")
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
            .help("Delete and stop auto-renewing")
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

/// A labeled row: leading icon, title, trailing value.
private struct SettingsRow<Value: View>: View {
    let icon: String
    let title: String
    @ViewBuilder var value: () -> Value

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Colors.primary)
                .frame(width: 18)
            Text(title)
                .font(Theme.Font.body())
                .foregroundStyle(Theme.Colors.body)
            Spacer()
            value()
        }
    }
}
