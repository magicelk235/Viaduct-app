import SwiftUI
import AppKit
import ServiceManagement
import Combine

/// Turns on macOS native window tabbing so Cmd+T / the tab bar work. SwiftUI
/// leaves `allowsAutomaticWindowTabbing` off by default, which disables Cmd+T.
/// Also owns the quit policy: quitting a window retreats to the menu bar.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the menu-bar "Quit Viaduct" so terminate actually terminates.
    /// Static: SwiftUI wraps the adaptor delegate in its own NSApp.delegate,
    /// so instance access via `NSApp.delegate as? AppDelegate` can fail.
    static var allowRealQuit = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
    }

    /// Cmd+Q / Quit from a window doesn't kill the process — it closes the
    /// windows and drops the Dock icon, leaving the menu-bar item (and the
    /// daily auto-renew timer) alive. Real quit is in the menu-bar menu.
    /// Logout/shutdown/restart still terminate normally, or the app would
    /// block the whole logout.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.allowRealQuit { return .terminateNow }
        if let why = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue,
           [UInt32(kAELogOut), UInt32(kAEReallyLogOut),
            UInt32(kAERestart), UInt32(kAEShowRestartDialog),
            UInt32(kAEShutDown), UInt32(kAEShowShutdownDialog)].contains(why) {
            return .terminateNow
        }
        for w in sender.windows where w.styleMask.contains(.titled) { w.close() }
        sender.setActivationPolicy(.accessory)
        return .terminateCancel
    }

    /// Reopen (Dock-less app launched again from Finder/Spotlight): come back
    /// as a regular app; AppKit/SwiftUI restores the window on the default path.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        sender.setActivationPolicy(.regular)
        return true
    }

    /// viaduct:// URLs land here, NOT on SwiftUI's .onOpenURL: that modifier
    /// lives on the window's view, so after quit-to-menubar (window closed,
    /// process alive) it never fires and store installs would hang.
    /// URLs arriving before the app wires up `openURLHandler` are buffered.
    static var openURLHandler: ((URL) -> Void)? {
        didSet {
            guard openURLHandler != nil else { return }
            let queued = pendingURLs
            pendingURLs.removeAll()
            queued.forEach { openURLHandler?($0) }
        }
    }
    private static var pendingURLs: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let handler = Self.openURLHandler {
                handler(url)
            } else {
                Self.pendingURLs.append(url)
            }
        }
    }
}

@main
struct ViaductApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var vm = ConverterViewModel()
    @StateObject private var license = LicenseManager.shared
    @AppStorage("appMode") private var modeRaw = AppMode.user.rawValue

    private var mode: Binding<AppMode> {
        Binding(get: { AppMode(rawValue: modeRaw) ?? .user },
                set: { modeRaw = $0.rawValue })
    }

    /// Menu-bar glyph: the bundled brand mark (icon.png), rendered as a template
    /// so macOS tints it to the menu-bar's adaptive light/dark color. Falls back
    /// to a system symbol if missing.
    static let menubarIcon: NSImage = {
        // icon.png is what's bundled (project.yml). The old code asked for
        // icon.svg — never bundled, and NSImage can't reliably render SVG — so
        // it always fell through to the arrows symbol. isTemplate below renders
        // it as an adaptive monochrome menu-bar mark.
        let img = Bundle.main.url(forResource: "icon", withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                       accessibilityDescription: "Viaduct")!
        img.size = NSSize(width: 18 * (img.size.width / max(img.size.height, 1)),
                          height: 18)   // fit menu-bar height, keep aspect
        img.isTemplate = true
        return img
    }()

    var body: some Scene {
        // Single window (not WindowGroup) — one app window, no Cmd+N duplicates.
        Window("Viaduct", id: "main") {
            Group {
                // Freemium: the app is usable without a license (2 free
                // conversions). Only block on the brief launch license check;
                // the paywall is presented in-flow when the free quota runs out.
                switch license.state {
                case .unknown, .checking:
                    LaunchGateView()
                case .licensed, .unlicensed:
                    RootView(vm: vm, mode: mode)
                }
            }
            .onAppear {
                license.bootstrap(); vm.onLaunch()
                // Starts Sparkle's background checks. It also needs to know when
                // a conversion is running so an update never relaunches us
                // mid-xcodebuild.
                Updater.shared.isBusy = { [weak vm] in vm?.isRunning ?? false }
                InstallProgressBridge.shared.start()
                InstallProgressBridge.shared.snapshot = { [weak vm] queryId in
                    ViaductApp.progressSnapshot(vm, queryId: queryId)
                }
                AppDelegate.openURLHandler = { handleOpenURL($0) }
            }
            // If the Xcode gate is up, a finished download / component install /
            // toolchain switch usually happens while the user is away in the App
            // Store or Xcode. Re-diagnose on focus so the card clears itself.
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)) { _ in
                vm.recheckXcode()
            }
            // Pre-convert warning: no Apple account in Xcode means ad-hoc
            // signing, which Safari disables on every quit. "Convert Anyway" is
            // a one-time pass, so the next conversion asks again; silencing it
            // for good is a deliberate trip to Settings → Warnings. Every button
            // leaves the flow in a terminal state — a store-page progress card
            // polling us must never be left spinning on an abandoned conversion.
            .alert(vm.adhocDespiteAccount ? "Xcode hasn't issued a signing certificate"
                                          : "No Apple account in Xcode",
                   isPresented: $vm.showAdhocWarning) {
                Button("Convert Anyway") { vm.convertIgnoringSigning() }
                Button("Open Xcode") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Xcode.app"))
                    vm.needsAppleAccount = true
                    vm.failureSummary = vm.adhocDespiteAccount
                        ? "In Xcode: Settings → Accounts, select your Apple ID, click Manage Certificates, click +, and choose Apple Development. Then install again."
                        : "Sign into Xcode (Settings → Accounts) with any free Apple ID, then install again."
                    vm.phase = .failed
                }
                Button("Cancel", role: .cancel) {
                    vm.failureSummary = "Install cancelled."
                    vm.phase = .failed
                }
            } message: {
                // Two different failures wear the same symptom. Telling someone who
                // already signed in to go sign in is the fastest way to lose them.
                Text(vm.adhocDespiteAccount ? """
                Your Apple ID is in Xcode, but Xcode hasn't issued a signing \
                certificate yet. Without one, Safari turns this extension off \
                every time it quits and you have to re-enable it from the \
                Develop menu.

                Xcode only issues the certificate when you ask for it. In Xcode: \
                Settings → Accounts, select your Apple ID, click Manage \
                Certificates at the bottom right, click + at the bottom left, \
                and choose Apple Development. Then convert again.
                """ : """
                Viaduct couldn't find an Apple account in Xcode. Without one, \
                Safari turns this extension off every time it quits and you have \
                to re-enable it from the Develop menu.

                Sign into Xcode with any free Apple ID (Xcode → Settings → \
                Accounts), then convert again. Signing in under System Settings \
                → Apple Account is a different thing and won't work.
                """)
            }
            // Paywall: shown when an unlicensed user hits the free-quota wall.
            // Dismisses itself once activation flips the license to .licensed.
            .sheet(isPresented: $vm.showPaywall) {
                ActivationView(license: license) { vm.showPaywall = false }
                    .onChange(of: license.state) { newState in
                        if newState == .licensed { vm.showPaywall = false }
                    }
            }
            // Brand teal as the app-wide accent for in-app SwiftUI controls.
            .tint(Theme.Colors.primary)
            // Follow the system appearance (light OR dark). Chrome is neutral and
            // adaptive; the brand teal accent reads on both — the Apple model.
        }
        .windowResizability(.contentMinSize)
        .commands {

            CommandGroup(after: .toolbar) {
                Picker("Mode", selection: mode) {
                    ForEach(AppMode.allCases) { Text($0.label).tag($0) }
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }
        }

        // Always present: quitting a window only retreats the app here (the
        // process stays alive so the daily auto-renew timer keeps firing).
        // Real quit lives in this menu.
        MenuBarExtra {
            RenewMenu(vm: vm)
        } label: {
            Image(nsImage: Self.menubarIcon)
        }

        Settings {
            SettingsView(mode: mode, vm: vm)
        }
    }

    private func handleOpenURL(_ url: URL) {
        guard url.scheme == "viaduct" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        let id = items?.first(where: { $0.name == "id" })?.value
        switch url.host {
        case "install":
            if let id {
                // The store URL is /detail/NAME/ID — pass NAME so the app isn't named
                // after the random-looking ID when the manifest name is an __MSG_ i18n key.
                let name = items?.first(where: { $0.name == "name" })?.value
                // Install came from the Safari extension on the store page — the
                // page renders the progress bar (via InstallProgressBridge), so
                // keep the app out of the user's way instead of coming forward.
                NSApp.hide(nil)
                vm.resetUserFlow()
                InstallProgressBridge.shared.downloading = true
                downloadAndConvert(extensionId: id, displayName: name)
            }
        case "remove":
            // Store-page "Remove from Safari": delete every install for this CWS
            // id (its .app + archived source + history record). Headless like
            // install — the page confirms the result by re-polling installed state.
            if let id { vm.history.removeByStoreId(id) }
        default:
            break
        }
    }

    /// The state dict the Safari extension polls for; rendered as the install
    /// bar on the Chrome Web Store page. When `queryId` is set, also answers
    /// whether that CWS id is installed (drives the Add/Remove button).
    @MainActor
    private static func progressSnapshot(_ vm: ConverterViewModel?, queryId: String?) -> [String: Any] {
        var dict = baseSnapshot(vm)
        // Only added when asked: this snapshot is broadcast on an unauthenticated
        // bus, so we never volunteer the user's full installed set — just a
        // yes/no for the single id they queried.
        if let queryId {
            dict["forId"] = queryId
            dict["installed"] = vm?.history.isInstalled(storeId: queryId) ?? false
        }
        return dict
    }

    @MainActor
    private static func baseSnapshot(_ vm: ConverterViewModel?) -> [String: Any] {
        guard let vm else { return ["state": "idle"] }
        if vm.showPaywall {
            // Reason kept generic on purpose: this snapshot is broadcast on a
            // system-wide DistributedNotificationCenter (unauthenticated — any
            // local process can read it), so it must never leak license/trial
            // state. The full reason shows only in the app window.
            return ["state": "failed", "message": "Open Viaduct to continue."]
        }
        if vm.showAdhocWarning {
            return ["state": "active", "fraction": 0.04,
                    "title": "Needs your answer",
                    "subtitle": "Open Viaduct to continue"]
        }
        switch vm.phase {
        case .failed:
            return ["state": "failed",
                    "message": vm.failureSummary ?? "Conversion failed. Open Viaduct for details."]
        case .finishing, .done:
            if vm.phase == .finishing {
                // Headless: the in-app progress bar (which normally fires this
                // at 100%) may be paused while the app is hidden, so nudge it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { vm.completeFinishing() }
            }
            return ["state": "done"]
        case .idle:
            if InstallProgressBridge.shared.downloading {
                return ["state": "active", "fraction": 0.06,
                        "title": "Downloading from Chrome Web Store",
                        "subtitle": "This usually takes a few seconds"]
            }
            return ["state": "idle"]
        default:
            return ["state": "active", "fraction": vm.phase.fraction,
                    "title": vm.phase.title, "subtitle": vm.phase.subtitle]
        }
    }

    private func downloadAndConvert(extensionId: String, displayName: String? = nil) {
        Task {
            do {
                let finalURL = try await ChromeStore.downloadCRX(id: extensionId)
                await MainActor.run {
                    // Download over — never leave the flag stuck on a flow that
                    // stops before the convert phases start (e.g. ad-hoc alert).
                    InstallProgressBridge.shared.downloading = false
                    modeRaw = AppMode.user.rawValue
                    vm.resetUserFlow()
                    vm.selectInput(path: finalURL.path)
                    // Store name beats the manifest's __MSG_ key / the .crx filename.
                    if let displayName, !displayName.isEmpty {
                        vm.options.appName = displayName
                    }
                    // Stamped onto the history record so auto-renew can
                    // re-download this extension by id if the source vanishes.
                    vm.pendingStoreId = extensionId
                    vm.userConvert()
                }
            } catch {
                await MainActor.run {
                    InstallProgressBridge.shared.downloading = false
                    modeRaw = AppMode.user.rawValue
                    vm.failureSummary = (error as? ChromeStore.DownloadError)?.errorDescription
                        ?? "Failed to download extension: \(error.localizedDescription)"
                    vm.phase = .failed
                }
            }
        }
    }
}

/// The menu-bar dropdown: renew status at a glance + quick actions. Lives here so
/// the app stays resident (and the daily renew timer keeps firing) after the
/// window is closed.
struct RenewMenu: View {
    @ObservedObject var vm: ConverterViewModel
    @ObservedObject private var history: ConversionHistory
    @ObservedObject private var license = LicenseManager.shared
    @Environment(\.openWindow) private var openWindow

    init(vm: ConverterViewModel) {
        self.vm = vm
        _history = ObservedObject(wrappedValue: vm.history)
    }

    /// Failures first (they need action), then whatever expires soonest.
    private var sortedRecords: [ConversionRecord] {
        history.records.sorted {
            if ($0.lastRenewFailed == true) != ($1.lastRenewFailed == true) {
                return $0.lastRenewFailed == true
            }
            return $0.expiresAt < $1.expiresAt
        }
    }

    var body: some View {
        // Expiry tracking + renewal is a Pro feature. Free users see an upsell,
        // not extension expiry rows or a Renew action they can't use.
        if !license.isLicensed {
            Text("Auto-renew keeps Safari from dropping extensions")
            Button("Unlock with Pro") {
                NSApp.setActivationPolicy(.regular)
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                vm.showPaywall = true
            }
        } else if history.records.isEmpty {
            // One row per installed extension, soonest expiry first, failures on top.
            Text("No extensions installed")
        } else {
            Section("Extensions") {
                ForEach(sortedRecords.prefix(8)) { rec in
                    if rec.lastRenewFailed == true {
                        Text("⚠︎ \(rec.resolvedAppName) — renew failed")
                    } else {
                        Text("\(rec.resolvedAppName) — expires \(rec.expiresAt.formatted(.relative(presentation: .named)))")
                    }
                }
                if history.records.count > 8 {
                    Text("…and \(history.records.count - 8) more")
                }
            }
        }

        Divider()

        if license.isLicensed {
            Button("Renew Now") { vm.renewNow() }
                .disabled(vm.isRunning)
        }
        Button("Open Viaduct") {
            // Restore the Dock icon (quit-to-menubar drops it) and the window.
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit Viaduct") {
            AppDelegate.allowRealQuit = true
            NSApp.terminate(nil)
        }
    }
}

/// Brief splash while we validate a stored license on launch.
struct LaunchGateView: View {
    var body: some View {
        ZStack {
            Theme.Colors.canvas.ignoresSafeArea()
            ProgressView().controlSize(.large)
        }
        .frame(minWidth: 540, minHeight: 600)
    }
}

/// Routes between the simple User surface and the full Developer surface.
struct RootView: View {
    @ObservedObject var vm: ConverterViewModel
    @Binding var mode: AppMode

    var body: some View {
        Group {
            switch mode {
            case .user:
                UserModeView(vm: vm, mode: $mode)
            case .developer:
                ContentView(vm: vm, mode: $mode)
                    .frame(minWidth: 820, minHeight: 640)
            }
        }
        .onAppear { vm.checkForUpdates() }
    }
}
