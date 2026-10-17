import SwiftUI
import AppKit

/// Presentation state for the import sheet, so the menu command and the
/// button on the main card open the same thing.
@MainActor
final class ChromeImport: ObservableObject {
    static let shared = ChromeImport()
    @Published var isPresented = false

    /// Whether any Chromium browser is installed. Doesn't read inside its
    /// folder, so it never sets off the privacy prompt just by drawing a button.
    static let hasBrowsers = !BrowserProfiles.installed().isEmpty
}

/// File → Import from Chrome…
struct ChromeImportCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Import from Chrome…") {
                NSApp.setActivationPolicy(.regular)
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                ChromeImport.shared.isPresented = true
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
        }
    }
}

/// Every extension installed in the user's Chromium browsers, with a tick box
/// each, converted in one batch.
struct ChromeImportView: View {
    @ObservedObject var vm: ConverterViewModel
    let dismiss: () -> Void

    @ObservedObject private var license = LicenseManager.shared
    @State private var extensions: [InstalledBrowserExtension]?
    @State private var selected: Set<String> = []
    /// Browsers macOS wouldn't let Viaduct read on the last scan.
    @State private var blocked: [ChromiumBrowser] = []
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            // Same name as the button and menu item that open it.
            Text("Import from Chrome")
                .font(Theme.Font.headingMD())
                .foregroundStyle(Theme.Colors.ink)

            if !blocked.isEmpty { blockedNotice }

            list
                .frame(minHeight: 220, maxHeight: 380)

            footer
        }
        .padding(Theme.Space.xl)
        .frame(width: 520)
        .background(AmbientBackground())
        .task { await load() }
        // Back from System Settings with access granted: look again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard !blocked.isEmpty else { return }
            Task { await load() }
        }
    }

    private var blockedNotice: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Label("macOS is keeping Viaduct out of \(ListFormatter.localizedString(byJoining: blocked.map(\.name)))",
                  systemImage: "lock.fill")
                .font(Theme.Font.bodyStrong())
                .foregroundStyle(Theme.Colors.ink)
            Text("Reading a browser's extensions needs your OK. If you didn't see the question or said no, turn Viaduct on under Full Disk Access, then come back here.")
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.Colors.body)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Privacy & Security") { NSWorkspace.shared.open(BrowserProfiles.privacySettingsURL) }
                .buttonStyle(.raycastTertiary)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.clear.liquidGlass(radius: Theme.Radius.md, tint: Theme.Colors.accentYellow.opacity(0.15)))
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if let extensions {
            if extensions.isEmpty {
                Text(blocked.isEmpty
                     ? "No extensions found in Chrome, Brave, Edge, Arc, Vivaldi or Opera."
                     : "Nothing to show until Viaduct can read your browsers.")
                    .font(Theme.Font.body())
                    .foregroundStyle(Theme.Colors.mute)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let profiles = orderedProfiles(extensions)
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.md) {
                        ForEach(profiles, id: \.self) { profile in
                            VStack(alignment: .leading, spacing: 2) {
                                // One profile: the sheet's title already names it.
                                if profiles.count > 1 {
                                    Text(profile.label(among: profiles))
                                        .font(Theme.Font.caption())
                                        .foregroundStyle(Theme.Colors.mute)
                                        .padding(.leading, Theme.Space.sm)
                                }
                                ForEach(extensions.filter { $0.profile == profile }) { row($0) }
                            }
                        }
                    }
                }
            }
        } else {
            VStack(spacing: Theme.Space.sm) {
                ProgressView().controlSize(.small)
                Text("Looking through your browsers…")
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.Colors.mute)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// One line for what it is, at most one more for why it's unticked. The
    /// official-version link sits at the trailing edge, where the eye lands
    /// before ticking the box.
    private func row(_ ext: InstalledBrowserExtension) -> some View {
        let isOn = Binding(get: { selected.contains(ext.id) },
                           set: { on in if on { selected.insert(ext.id) } else { selected.remove(ext.id) } })
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
        return HStack(spacing: Theme.Space.sm) {
            Toggle("", isOn: isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
            HistoryIcon(iconData: ext.iconPNG,
                        monogram: ext.name.first.map(String.init)?.uppercased() ?? "?")
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                    Text(ext.name)
                        .font(Theme.Font.body())
                        .foregroundStyle(Theme.Colors.ink)
                        .lineLimit(1).truncationMode(.middle)
                    Text(ext.version)
                        .font(Theme.Font.mono())
                        .foregroundStyle(Theme.Colors.mute)
                        .lineLimit(1)
                }
                if let status = status(ext) {
                    Text(status)
                        .font(Theme.Font.caption())
                        .foregroundStyle(Theme.Colors.mute)
                }
            }
            Spacer(minLength: Theme.Space.sm)
            if let alt = SafariAlternatives.lookup(chromeId: ext.chromeId) {
                Button { NSWorkspace.shared.open(alt.url) } label: {
                    Label("Safari version", systemImage: "safari")
                        .font(Theme.Font.caption())
                        .foregroundStyle(Theme.Colors.primary)
                }
                .buttonStyle(.plain)
                .help("\(alt.name) publishes its own Safari version")
            }
        }
        .padding(.horizontal, Theme.Space.sm)
        .padding(.vertical, 6)
        .background(shape.fill(hovered == ext.id ? Theme.Colors.surfaceElevated : .clear))
        .contentShape(shape)
        .onHover { hovered = $0 ? ext.id : (hovered == ext.id ? nil : hovered) }
        .onTapGesture { isOn.wrappedValue.toggle() }
    }

    /// The one reason a row starts unticked, if there is one.
    private func status(_ ext: InstalledBrowserExtension) -> String? {
        if alreadyInSafari(ext) { return "Already in Safari" }
        if !ext.enabled { return "Off in \(ext.profile.browser.name)" }
        if ext.unpacked { return "Loaded unpacked" }
        return nil
    }

    // MARK: - Footer

    private var footer: some View {
        let count = selected.count
        let left = license.freeConversionsRemaining
        return HStack(alignment: .center) {
            Button("Cancel", action: dismiss)
                .buttonStyle(.raycastGhost)
                .keyboardShortcut(.cancelAction)
            Spacer()
            // Only when it changes the outcome: more ticked than the free tier covers.
            if !license.isLicensed, count > left {
                Text("\(left) free, \(count - left) need Pro")
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.Colors.body)
            }
            Button(count == 0 ? "Convert" : "Convert \(count)") { start() }
                .buttonStyle(.raycastPrimary)
                .disabled(count == 0)
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Actions

    private func load() async {
        let (found, denied) = await Task.detached(priority: .userInitiated) {
            (BrowserExtensionScanner.scan(), BrowserProfiles.blocked())
        }.value
        blocked = denied
        extensions = found
        // Start with what's worth converting: on in the browser, installed from
        // a store (an unpacked folder is someone's work in progress), not
        // already in Safari, and not something its maker already ships for Safari.
        selected = Set(found.filter { ext in
            ext.enabled && !ext.unpacked && !alreadyInSafari(ext)
                && SafariAlternatives.lookup(chromeId: ext.chromeId) == nil
        }.map(\.id))
    }

    private func start() {
        guard let extensions else { return }
        let items = extensions.filter { selected.contains($0.id) }.map { ext in
            QueueItem(name: ext.name, iconPNG: ext.iconPNG,
                      storeId: ext.fromWebStore ? ext.chromeId : nil,
                      chromeId: ext.chromeId,
                      settingsProfile: ext.profile) {
                try await Task.detached(priority: .userInitiated) {
                    try BrowserExtensionScanner.stage(ext)
                }.value
            }
        }
        dismiss()
        // The queue's sheet opens on the same window; let this one close first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            ConversionQueue.shared.start(items, vm: vm)
        }
    }

    private func alreadyInSafari(_ ext: InstalledBrowserExtension) -> Bool {
        vm.history.isInstalled(chromeId: ext.chromeId)
    }

    private func orderedProfiles(_ list: [InstalledBrowserExtension]) -> [BrowserProfile] {
        var seen = Set<BrowserProfile>()
        return list.map(\.profile).filter { seen.insert($0).inserted }
    }
}
