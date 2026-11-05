import SwiftUI
import AppKit
import ServiceManagement
import Combine
import UserNotifications

/// Turns on macOS native window tabbing so Cmd+T / the tab bar work. SwiftUI
/// leaves `allowsAutomaticWindowTabbing` off by default, which disables Cmd+T.
/// Also owns the quit policy: quitting a window retreats to the menu bar.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the menu-bar "Quit Viaduct" so terminate actually terminates.
    /// Static: SwiftUI wraps the adaptor delegate in its own NSApp.delegate,
    /// so instance access via `NSApp.delegate as? AppDelegate` can fail.
    static var allowRealQuit = false

    /// True when this process is only hosting the unit tests.
    static let isHostingTests: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
    }()

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
    }

    /// Launch work lives here, not on the window: the app often starts with no
    /// window at all (at login, or relaunched after quitting to the menu bar),
    /// and the background timers and store-page handler are needed either way.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A test run launches the app only to host the tests. Bootstrapping
        // would check the license, fetch from npm and register the login
        // item, reaching the network and changing the real app's settings.
        // With no launch answer the window just shows LaunchGateView.
        guard !Self.isHostingTests else { return }
        ViaductApp.bootstrap()
    }

    /// Cmd+Q / Quit from a window doesn't kill the process — it closes the
    /// windows and drops the Dock icon, leaving the menu-bar item (and the
    /// background timers) alive. Real quit is in the menu-bar menu.
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
    @StateObject private var vm = ConverterViewModel.shared
    @StateObject private var license = LicenseManager.shared

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
                // conversions). Only block on the brief launch license check,
                // not on a key being activated later; the paywall is presented
                // in-flow when the free quota runs out.
                if license.hasLaunchAnswer {
                    RootView(vm: vm)
                } else {
                    LaunchGateView()
                }
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
                    // Whichever Xcode this Mac actually has — an Xcode beta on a
                    // macOS beta is often the only one installed.
                    if let app = CLIRunner.installedXcodeApp() {
                        NSWorkspace.shared.open(app)
                    }
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
            .sheet(isPresented: $vm.showPaywall, onDismiss: { vm.paywallDidClose() }) {
                ActivationView(license: license, extensionCount: vm.history.records.count) { vm.showPaywall = false }
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

            ChromeImportCommands()
            // Settings lives in an AppKit window (see SettingsWindowController),
            // so ⌘, has to be wired to it by hand.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { SettingsWindowController.show(vm: vm) }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }

        // Always present: quitting a window only retreats the app here (the
        // process stays alive so its background timers keep firing).
        // Real quit lives in this menu.
        MenuBarExtra {
            StatusMenu(vm: vm)
        } label: {
            MenuBarLabel()
        }
    }

    /// Everything the app needs running whether or not a window is open.
    /// Called once, from `applicationDidFinishLaunching`.
    @MainActor
    static func bootstrap() {
        let vm = ConverterViewModel.shared
        // Set before launch finishes, so a click on a notification that
        // launched the app still gets routed.
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        LicenseManager.shared.bootstrap()
        vm.onLaunch()
        // Starts Sparkle's background checks. It also needs to know when the
        // CLI is busy so an update never relaunches us mid-xcodebuild.
        Updater.shared.isBusy = { [weak vm] in vm?.isBusy ?? false }
        InstallProgressBridge.shared.start()
        InstallProgressBridge.shared.snapshot = { [weak vm] queryId in
            ViaductApp.progressSnapshot(vm, queryId: queryId)
        }
        AppDelegate.openURLHandler = { handleOpenURL($0, vm: vm) }
    }

    private static func handleOpenURL(_ url: URL, vm: ConverterViewModel) {
        guard url.scheme == "viaduct" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        let id = items?.first(where: { $0.name == "id" })?.value
        switch url.host {
        case "install":
            guard let id else { return }
            // Starting a store install resets the flow, which would wipe the
            // conversion or batch already running (and record its app under
            // this one's name). Show what's running instead.
            guard !vm.isRunning, !ConversionQueue.shared.isRunning,
                  !InstallProgressBridge.shared.downloading,
                  OfficialVersionPrompt.shared.question == nil else {
                MainWindow.show()
                return
            }
            // The store URL is /detail/NAME/ID — pass NAME so the app isn't named
            // after the random-looking ID when the manifest name is an __MSG_ i18n key.
            let name = items?.first(where: { $0.name == "name" })?.value
            OfficialVersionPrompt.shared.checkBeforeStoreInstall(chromeId: id) {
                // Install came from the Safari extension on the store page — the
                // page renders the progress bar (via InstallProgressBridge), so
                // keep the app out of the user's way instead of coming forward.
                NSApp.hide(nil)
                vm.resetUserFlow()
                InstallProgressBridge.shared.downloading = true
                downloadAndConvert(extensionId: id, displayName: name, vm: vm)
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
        if vm.showAdhocWarning || OfficialVersionPrompt.shared.question != nil {
            return ["state": "active", "fraction": 0.04,
                    "title": "Needs your answer",
                    "subtitle": "Open Viaduct to continue"]
        }
        switch vm.phase {
        case .failed:
            return ["state": "failed",
                    "message": vm.failureSummary ?? "Conversion failed. Open Viaduct for details."]
        case .finishing, .done:
            if vm.phase == .finishing, NSApp.isHidden {
                // Headless (store-page install, app hidden): the in-app orbit
                // animation that normally fires this after its last absorption
                // may be paused, so nudge it. Never fires while the window is
                // visible — the animation gets to finish on screen.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { vm.completeFinishing() }
            }
            return ["state": "done"]
        case .idle:
            // The engine downloads on first launch, and a store-page install can
            // land in the middle of it. Say so, otherwise the page's bar drops
            // back to idle and the install looks like it never started.
            if vm.cliInstalling {
                return ["state": "active", "fraction": 0.03,
                        "title": "Getting Viaduct ready",
                        "subtitle": "Installing the converter engine"]
            }
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

    private static func downloadAndConvert(extensionId: String, displayName: String?, vm: ConverterViewModel) {
        Task {
            do {
                let downloaded = try await ChromeStore.downloadCRX(id: extensionId)
                // Settings saved by the same extension in a browser on this Mac
                // come along.
                let carried = await Task.detached(priority: .userInitiated) {
                    SettingsCarryOver.apply(to: downloaded, chromeId: extensionId, profile: nil,
                                            name: displayName ?? extensionId)
                }.value
                let finalURL = carried.url
                let settingsNote = carried.note
                await MainActor.run {
                    // Download over — never leave the flag stuck on a flow that
                    // stops before the convert phases start (e.g. ad-hoc alert).
                    InstallProgressBridge.shared.downloading = false
                    vm.resetUserFlow()
                    if let settingsNote { vm.appendLog("→ \(settingsNote)") }
                    vm.selectInput(path: finalURL.path)
                    // Store name beats the manifest's __MSG_ key / the .crx filename.
                    if let displayName, !displayName.isEmpty {
                        vm.options.appName = displayName
                    }
                    // Stamped onto the history record so auto-update can
                    // re-download this extension by id.
                    vm.pendingStoreId = extensionId
                    vm.userConvert()
                }
            } catch {
                await MainActor.run {
                    InstallProgressBridge.shared.downloading = false
                    vm.failureSummary = (error as? ChromeStore.DownloadError)?.errorDescription
                        ?? "Failed to download extension: \(error.localizedDescription)"
                    vm.phase = .failed
                }
            }
        }
    }
}

/// The menu-bar icon. Also where `MainWindow` gets its way to open the main
/// window when the app launched without one: the status item is on screen
/// from launch, the window may never have been.
private struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: ViaductApp.menubarIcon)
            .onAppear { MainWindow.openAction = openWindow }
    }
}

/// The menu-bar dropdown: installed extensions at a glance + quick actions.
/// Lives here so the app stays resident (and its background timers keep
/// firing) after the window is closed.
struct StatusMenu: View {
    @ObservedObject var vm: ConverterViewModel
    @ObservedObject private var history: ConversionHistory
    @ObservedObject private var license = LicenseManager.shared
    @Environment(\.openWindow) private var openWindow

    init(vm: ConverterViewModel) {
        self.vm = vm
        _history = ObservedObject(wrappedValue: vm.history)
    }

    /// Whatever goes soonest on the free plan first, then the rest.
    private var sortedRecords: [ConversionRecord] {
        history.records.sorted {
            ($0.freeRemovesAt ?? .distantFuture) < ($1.freeRemovesAt ?? .distantFuture)
        }
    }

    var body: some View {
        if history.records.isEmpty {
            Text("No extensions installed")
        } else {
            Section("Extensions") {
                ForEach(sortedRecords.prefix(8)) { rec in
                    if let removesAt = rec.freeRemovesAt {
                        Text("\(rec.name): removed \(removesAt.formatted(.relative(presentation: .numeric)))")
                    } else if rec.lastUpdateFailed == true {
                        Text("⚠︎ \(rec.name): update failed")
                    } else {
                        Text(rec.name)
                    }
                }
                if history.records.count > 8 {
                    Text("…and \(history.records.count - 8) more")
                }
            }
        }

        if !license.isLicensed {
            Divider()
            Button("Unlock with Pro") {
                NSApp.setActivationPolicy(.regular)
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                vm.presentPaywall(for: nil)
            }
        }

        Divider()
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

/// Routes between first-launch setup and the converter.
struct RootView: View {
    @ObservedObject var vm: ConverterViewModel
    @ObservedObject private var queue = ConversionQueue.shared
    @ObservedObject private var chromeImport = ChromeImport.shared
    @ObservedObject private var setup = SetupFlow.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if setup.isActive {
                SetupView(vm: vm, flow: setup)
            } else {
                UserModeView(vm: vm)
            }
        }
        .onAppear {
            MainWindow.openAction = openWindow
            setup.startIfFreshInstall(history: vm.history)
            vm.checkForUpdates()
        }
        .sheet(isPresented: $queue.isPresented) {
            ConversionQueueView(queue: queue, vm: vm)
                .interactiveDismissDisabled(queue.isRunning)
        }
        .background(
            Color.clear.sheet(isPresented: $chromeImport.isPresented) {
                ChromeImportView(vm: vm) { chromeImport.isPresented = false }
            })
        .officialVersionPrompt()
        // Its own host view: two alerts on one view can swallow each other.
        .background(Color.clear.freePlanRemovedNotice(vm: vm,
                                                      blocked: queue.isPresented || setup.isActive))
    }
}
