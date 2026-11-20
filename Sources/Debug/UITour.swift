#if DEBUG
import AppKit
import SwiftUI

/// A scripted walk through the app's screens and states, for screenshots.
///
/// Launch a Debug build with `VIADUCT_UI_TOUR=<dir>` and it skips the normal
/// launch work and runs this instead. Every step sets up one state, shows it
/// in light and then in dark, and for each writes `<dir>/steps/<n>.json`
/// naming the windows to shoot, then waits for `<dir>/steps/<n>.done` from
/// whoever takes the screenshots. After the last one it writes
/// `<dir>/steps/end` and quits for real.
///
/// What's on screen is made up here: the history, the free plan, the
/// extension being converted. Nothing goes to the network, Application
/// Support is only read, and the app never comes to the front. Defaults the
/// views write along the way are put back before it quits.
@MainActor
enum UITour {
    /// Puts the tour's made-up state in place. Has to run before anything
    /// reads defaults, the view model's history above all, so `ViaductApp`
    /// calls it from its initializer. Does nothing on a normal launch.
    static func prepare() {
        guard directory != nil, !prepared else { return }
        prepared = true
        let defaults = UserDefaults.standard
        savedDefaults = defaults.persistentDomain(forName: bundleID)
        // The argument domain wins over the app's own, so the views read the
        // made-up state while the real values stay where they are.
        var overlay = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        overlay.merge(fixtureDefaults()) { _, tour in tour }
        defaults.setVolatileDomain(overlay, forName: UserDefaults.argumentDomain)
        stayInBackground()
        drawWindowsAsActive()
        restoreDefaultsOnSignal()
    }

    /// Runs the tour if VIADUCT_UI_TOUR asks for one. False on a normal launch.
    static func start() -> Bool {
        guard directory != nil else { return false }
        prepare()
        Task { await run() }
        return true
    }

    // MARK: - Setup

    private nonisolated static let directory: URL? = {
        guard let path = ProcessInfo.processInfo.environment["VIADUCT_UI_TOUR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }()

    private static var stepsDir: URL { directory!.appendingPathComponent("steps", isDirectory: true) }
    private nonisolated static var fixturesDir: URL { directory!.appendingPathComponent("fixtures", isDirectory: true) }
    private static let bundleID = Bundle.main.bundleIdentifier ?? "com.magicelk235.viaduct"

    /// The app's defaults as they were before the tour touched anything.
    private static var savedDefaults: [String: Any]?
    private static var prepared = false
    private static var stepCount = 0
    private static var signalSources: [DispatchSourceSignal] = []
    /// The batch item that sits in "preparing" until the queue step is over.
    private static var heldQueueItem: CheckedContinuation<URL, Error>?

    private static var vm: ConverterViewModel { .shared }

    private static func fixtureDefaults() -> [String: Any] {
        [
            "conversionHistory": (try? JSONEncoder().encode(fixtureHistory())) ?? Data(),
            "freeConversionsUsed": 1,
            "freePlanRemoved": Data("[]".utf8),
            "setupDone": true,
            "storeButtonPromptSeen": true,
            "targetBrowser": Browser.safari.rawValue,
            FirefoxDisclosure.key: true,
            "adhocAcknowledged": false,
            "autoUpdate": false,
            // Sparkle starts with the Settings window. A check that just
            // happened keeps it from looking for an update during the tour.
            "SUEnableAutomaticChecks": true,
            "SUHasLaunchedBefore": true,
            "SULastCheckTime": Date(),
            // No saved window state for this run to leave behind.
            "ApplePersistence": false,
            "NSQuitAlwaysKeepsWindows": false,
        ]
    }

    private static func setOverlay(_ key: String, _ value: Any) {
        let defaults = UserDefaults.standard
        var overlay = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        overlay[key] = value
        defaults.setVolatileDomain(overlay, forName: UserDefaults.argumentDomain)
    }

    private static func restoreDefaults() {
        let defaults = UserDefaults.standard
        if let savedDefaults {
            defaults.setPersistentDomain(savedDefaults, forName: bundleID)
        } else {
            defaults.removePersistentDomain(forName: bundleID)
        }
        CFPreferencesAppSynchronize(bundleID as CFString)
    }

    /// Killed partway, the tour still leaves the real defaults as it found them.
    private static func restoreDefaultsOnSignal() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                Task { @MainActor in
                    restoreDefaults()
                    exit(1)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Settings and a few other paths bring the app forward. During the tour
    /// that would pull focus away from whatever the user is doing.
    private static func stayInBackground() {
        let app: AnyClass = NSApplication.self
        let ignoringOtherApps: @convention(block) (AnyObject, Bool) -> Void = { _, _ in }
        let plain: @convention(block) (AnyObject) -> Void = { _ in }
        if let method = class_getInstanceMethod(app, NSSelectorFromString("activateIgnoringOtherApps:")) {
            method_setImplementation(method, imp_implementationWithBlock(ignoringOtherApps))
        }
        if let method = class_getInstanceMethod(app, NSSelectorFromString("activate")) {
            method_setImplementation(method, imp_implementationWithBlock(plain))
        }
    }

    /// The app stays in the background, so its windows would otherwise be
    /// shot the way an inactive window looks: grey traffic lights, no accent
    /// color on the buttons. These are AppKit's own answers to "does this
    /// window look active", private but stable for years.
    private static func drawWindowsAsActive() {
        let window: AnyClass = NSWindow.self
        let yes: @convention(block) (AnyObject) -> Bool = { _ in true }
        let yesForButton: @convention(block) (AnyObject, Int) -> Bool = { _, _ in true }
        for name in ["hasKeyAppearance", "hasMainAppearance", "_hasActiveAppearance",
                     "_hasActiveAppearanceIgnoringKeyFocus", "_hasKeyAppearance", "_hasMainAppearance"] {
            if let method = class_getInstanceMethod(window, NSSelectorFromString(name)) {
                method_setImplementation(method, imp_implementationWithBlock(yes))
            }
        }
        if let method = class_getInstanceMethod(window, NSSelectorFromString("_hasActiveAppearanceForStandardWindowButton:")) {
            method_setImplementation(method, imp_implementationWithBlock(yesForButton))
        }
        if let method = class_getInstanceMethod(NSApplication.self, NSSelectorFromString("_isActiveApp")) {
            method_setImplementation(method, imp_implementationWithBlock(yes))
        }
    }

    // MARK: - Running

    private struct TourError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static func run() async {
        var finished = false
        do {
            try FileManager.default.createDirectory(at: stepsDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: fixturesDir, withIntermediateDirectories: true)
            for sample in [picked] + others {
                FileManager.default.createFile(atPath: sample.file.path, contents: Data())
            }
            try await walk()
            finished = true
        } catch {
            NSLog("UI tour stopped: %@", String(describing: error))
        }
        for window in NSApp.windows where window.isVisible {
            for sheet in window.sheets { window.endSheet(sheet) }
            window.orderOut(nil)
        }
        restoreDefaults()
        if finished {
            FileManager.default.createFile(atPath: stepsDir.appendingPathComponent("end").path, contents: Data())
        }
        AppDelegate.allowRealQuit = true
        NSApp.terminate(nil)
    }

    private static func walk() async throws {
        // RootView fetches the engine when there's none, and a fresh download
        // is exactly what the tour mustn't do.
        guard CLIUpdater.shared.isInstalled else {
            throw TourError("the converter engine isn't installed; open Viaduct once to fetch it")
        }
        let main = try await mainWindow()
        // The splash's spinner starts a beat after the window shows.
        await pause(600)

        try await shoot("launch", "checking", "Checking the license at launch", [main])

        // RootView looks for a newer engine on npm when it first appears. A
        // check already in flight makes it skip that.
        vm.updateChecking = true
        LicenseManager.shared.useFreePlanForUITour()
        await pause(800)
        vm.updateChecking = false

        try await mainStates(main)
        try await alerts(main)
        try await sheets(main)
        try await setup(main)
        try await settings(main)
    }

    private static func mainStates(_ main: NSWindow) async throws {
        try await showMain(main, "empty", "No extension picked") {}
        try await showMain(main, "getting-ready", "Downloading the converter engine") {
            vm.cliInstalling = true
        }
        try await showMain(main, "ready", "Extension picked, ready to convert") {
            pickSample()
        }
        try await showMain(main, "wont-work", "Extension that can't work in Safari") {
            pickSample()
            vm.compatibility = CompatibilityVerdict(
                blockingErrors: [BlockingError(category: "missing-file",
                                               message: "background.service_worker \"js/background.js\" is not in the package")],
                browser: .safari)
        }
        try await showMain(main, "converting-safari", "Converting for Safari") {
            pickSample()
            vm.isRunning = true
            vm.lastReachedTrackPhase = .building
            vm.phase = .building
        }
        try await showMain(main, "installing-firefox", "Adding to Firefox") {
            pickSample(for: .firefox)
            vm.isRunning = true
            vm.lastReachedTrackPhase = .installing
            vm.phase = .installing
        }
        try await showMain(main, "done", "Installed in Safari") {
            pickSample()
            vm.installedAppPath = "/Applications/\(picked.name).app"
            vm.phase = .done
        }
        try await showMain(main, "failed", "Conversion failed") {
            pickSample()
            vm.logLines = failureLog
            vm.lastReachedTrackPhase = .building
            vm.failureSummary = failureSummary
            vm.phase = .failed
        }
        let xcodeGates: [(String, String, CLIRunner.XcodeStatus)] = [
            ("xcode-missing", "Xcode isn't installed", CLIRunner.XcodeStatus.notInstalled),
            ("xcode-not-selected", "macOS isn't pointed at Xcode",
             .notSelected(developerDir: "/Applications/Xcode.app/Contents/Developer")),
        ]
        for (state, title, status) in xcodeGates {
            try await showMain(main, state, title) {
                pickSample()
                vm.needsXcode = true
                vm.xcodeStatus = status
                vm.failureSummary = ConverterViewModel.xcodeMessage(for: status)
                vm.phase = .failed
            }
        }
        try await showMain(main, "firefox-gate", "Firefox isn't set up yet") {
            pickSample(for: .firefox)
            vm.firefoxGate = .noProfile
            vm.failureSummary = FirefoxGate.noProfile.message
            vm.phase = .failed
        }
    }

    private static func alerts(_ main: NSWindow) async throws {
        try await showOver(main, "alerts", "no-apple-account", "No Apple account in Xcode",
                           before: { pickSample() },
                           present: { vm.showAdhocWarning = true },
                           dismiss: { vm.showAdhocWarning = false })
        try await showOver(main, "alerts", "firefox-disclosure", "Keeping add-ons in Firefox",
                           before: { pickSample(for: .firefox) },
                           present: { vm.showFirefoxDisclosure = true },
                           dismiss: { vm.showFirefoxDisclosure = false })
        try await showOver(main, "alerts", "firefox-restart", "Firefox will restart once",
                           before: { pickSample(for: .firefox) },
                           present: { vm.showFirefoxRestartPrompt = true },
                           dismiss: { vm.showFirefoxRestartPrompt = false })
        if let darkReader = SafariAlternatives.lookup(chromeId: "eimadpbcbfnmbkopoojfekhnkhdbieeh") {
            try await showOver(main, "alerts", "official-version", "Official Safari version before a store install",
                               present: { OfficialVersionPrompt.shared.question = .init(alternative: darkReader, convert: {}) },
                               dismiss: { OfficialVersionPrompt.shared.question = nil })
        }
        try await showOver(main, "alerts", "free-plan-removed", "Free-plan extension removed",
                           present: { vm.removedOnFreePlan = [.init(name: others[2].name, browser: .safari)] },
                           dismiss: { vm.removedOnFreePlan = [] })
    }

    private static func sheets(_ main: NSWindow) async throws {
        try await showOver(main, "sheets", "paywall", "Out of free conversions",
                           before: {
                               pickSample()
                               setOverlay("freeConversionsUsed", 2)
                               LicenseManager.shared.objectWillChange.send()
                           },
                           present: { vm.presentPaywall(for: .safari) },
                           dismiss: {
                               vm.showPaywall = false
                               setOverlay("freeConversionsUsed", 1)
                               LicenseManager.shared.objectWillChange.send()
                           })

        let queue = ConversionQueue.shared
        try await showOver(main, "sheets", "queue-running", "Converting a batch",
                           present: { queue.start(queueItems(), vm: vm) },
                           ready: { queue.items.contains { $0.status == .preparing } },
                           afterShot: {
                               queue.cancel()
                               heldQueueItem?.resume(throwing: CancellationError())
                               heldQueueItem = nil
                               await pause(300)
                               try await shoot("sheets", "queue-stopped", "Batch stopped partway", [main])
                           },
                           dismiss: { queue.dismiss() })

        // The import list is the user's own browsers, read from disk.
        try await showOver(main, "sheets", "chrome-import", "Import from Chrome", settle: 1500,
                           present: { ChromeImport.shared.isPresented = true },
                           dismiss: { ChromeImport.shared.isPresented = false })

        var hosted: NSWindow?
        try await showOver(main, "sheets", "store-button", "Add to Safari button prompt",
                           present: { hosted = presentSheet(StoreButtonPrompt {}, on: main) },
                           dismiss: { if let hosted { main.endSheet(hosted) } })
        try await showOver(main, "sheets", "report", "Report a problem",
                           before: {
                               pickSample()
                               vm.logLines = failureLog
                               vm.lastReachedTrackPhase = .building
                               vm.failureSummary = failureSummary
                               vm.phase = .failed
                           },
                           present: { hosted = presentSheet(ReportSheet(report: failureReport()) {}, on: main) },
                           dismiss: { if let hosted { main.endSheet(hosted) } })
        if let record = vm.history.records.first {
            try await showOver(main, "sheets", "history-detail", "A converted extension",
                               present: {
                                   hosted = presentSheet(HistoryDetailSheet(record: record, vm: vm, history: vm.history) {},
                                                         on: main)
                               },
                               dismiss: { if let hosted { main.endSheet(hosted) } })
        }
    }

    private static func setup(_ main: NSWindow) async throws {
        baseline()
        let flow = SetupFlow.shared
        flow.start()
        await waitUntil(timeout: 10_000) { !flow.preparing }
        await pause(800)
        try await shoot("setup", "checklist", "First-launch setup", [main])
        if let last = flow.steps.last { flow.select(last) }
        flow.next()
        await waitUntil { flow.showingWelcome }
        await pause(900)
        try await shoot("setup", "welcome", "Setup finished", [main])
        flow.finish(openImport: false)
        await pause(500)
    }

    private static func settings(_ main: NSWindow) async throws {
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        SettingsNavigation.shared.selectedTab = .general
        SettingsWindowController.show(vm: vm)
        var settings: NSWindow?
        await waitUntil {
            settings = NSApp.windows.first {
                !before.contains(ObjectIdentifier($0)) && $0.isVisible && $0.styleMask.contains(.titled)
            }
            return settings != nil
        }
        guard let settings else { throw TourError("the Settings window never opened") }
        for tab in SettingsTab.allCases {
            SettingsNavigation.shared.selectedTab = tab
            // Extensions asks persist about Firefox, which takes a moment.
            await pause(tab == .extensions ? 1500 : 700)
            try await shoot("settings", tab.rawValue, tab.title, [settings])
        }
        SettingsNavigation.shared.selectedTab = .license
        LicenseManager.shared.useEverythingUnlockedForUITour()
        await pause(700)
        try await shoot("settings", "license-unlocked", "License, everything unlocked", [settings])
        LicenseManager.shared.useFreePlanForUITour()
        settings.close()
    }

    // MARK: - Steps

    /// Puts the main window back to an empty card, ready for the next state.
    private static func baseline() {
        vm.isRunning = false
        vm.resetUserFlow()
        vm.cliInstalling = false
        vm.options.browser = .safari
    }

    private static func pickSample(for browser: Browser = .safari) {
        vm.options.browser = browser
        vm.options.inputPath = picked.file.path
        vm.options.appName = picked.name
        vm.extInfo = ExtensionInfo(name: picked.name, icon: picked.icon, version: picked.version)
    }

    private static func showMain(_ main: NSWindow, _ state: String, _ title: String,
                                 _ configure: () -> Void) async throws {
        baseline()
        configure()
        // The card morphs on a spring.
        await pause(600)
        try await shoot("main", state, title, [main])
    }

    /// A state that sits on the main window as a sheet or an alert.
    private static func showOver(_ main: NSWindow, _ group: String, _ state: String, _ title: String,
                                 settle: Int = 0,
                                 before: () -> Void = {},
                                 present: () -> Void,
                                 ready: () -> Bool = { true },
                                 afterShot: () async throws -> Void = {},
                                 dismiss: () -> Void) async throws {
        baseline()
        before()
        await pause(300)
        present()
        guard await waitUntil({ main.attachedSheet != nil && ready() }) else {
            dismiss()
            throw TourError("\(group)/\(state) never showed up")
        }
        await pause(settle)
        try await shoot(group, state, title, [main])
        try await afterShot()
        dismiss()
        await waitUntil { main.attachedSheet == nil }
        await pause(300)
    }

    /// Hosts a view as a sheet, for the ones whose presentation lives in a
    /// view's private state.
    private static func presentSheet<Content: View>(_ content: Content, on main: NSWindow) -> NSWindow {
        let host = NSHostingController(rootView: content.tint(Theme.Colors.primary))
        let sheet = NSWindow(contentViewController: host)
        sheet.setContentSize(host.view.fittingSize)
        main.beginSheet(sheet)
        return sheet
    }

    /// Shows the current state in light and then dark, handing each to the
    /// shooter and waiting until it has its screenshots.
    private static func shoot(_ group: String, _ state: String, _ title: String, _ windows: [NSWindow]) async throws {
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            await pause(400)
            stepCount += 1
            let step: [String: Any] = [
                "id": "\(group)/\(state)/\(theme)",
                "group": group,
                "title": title,
                "state": state,
                "theme": theme,
                "windowNumbers": windows.map(\.windowNumber),
                "scale": windows.first?.backingScaleFactor ?? 2,
            ]
            let file = stepsDir.appendingPathComponent("\(stepCount).json")
            let partial = stepsDir.appendingPathComponent(".\(stepCount).json.partial")
            try JSONSerialization.data(withJSONObject: step, options: [.prettyPrinted, .sortedKeys]).write(to: partial)
            guard rename(partial.path, file.path) == 0 else { throw TourError("couldn't write \(file.path)") }
            let done = stepsDir.appendingPathComponent("\(stepCount).done").path
            guard await waitUntil(timeout: 120_000, { FileManager.default.fileExists(atPath: done) }) else {
                throw TourError("no screenshots came for step \(stepCount) (\(group)/\(state)/\(theme))")
            }
        }
    }

    private static func mainWindow() async throws -> NSWindow {
        func find() -> NSWindow? {
            NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }
        }
        let opened = await waitUntil(timeout: 3000) { find() != nil }
        if !opened {
            // Launched without its window, say after it was closed last time.
            MainWindow.openAction?(id: "main")
            await waitUntil { find() != nil }
        }
        guard let main = find() else { throw TourError("the main window never opened") }
        main.isRestorable = false
        // Long enough for the recent list under the card.
        main.setContentSize(NSSize(width: 560, height: 760))
        return main
    }

    private static func pause(_ milliseconds: Int) async {
        try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }

    @discardableResult
    private static func waitUntil(timeout milliseconds: Int = 5000, _ condition: () -> Bool) async -> Bool {
        var waited = 0
        while !condition() {
            guard waited < milliseconds else { return false }
            await pause(50)
            waited += 50
        }
        return true
    }

    // MARK: - Fixtures

    private struct Sample {
        let name: String
        let version: String
        let chromeId: String
        let symbol: String
        let colors: (NSColor, NSColor)

        var file: URL { UITour.fixturesDir.appendingPathComponent("\(name).crx") }

        /// A stand-in for the extension's own icon: its color, its glyph.
        var icon: NSImage {
            let (top, bottom) = colors
            let symbol = symbol
            return NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
                let tile = NSBezierPath(roundedRect: rect.insetBy(dx: 6, dy: 6), xRadius: 28, yRadius: 28)
                NSGradient(starting: top, ending: bottom)?.draw(in: tile, angle: -90)
                let config = NSImage.SymbolConfiguration(pointSize: 58, weight: .semibold)
                    .applying(.init(paletteColors: [.white]))
                if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(config) {
                    let size = glyph.size
                    glyph.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                          width: size.width, height: size.height))
                }
                return true
            }
        }
    }

    private static let picked = Sample(
        name: "Return YouTube Dislike", version: "3.0.0.18", chromeId: "gebbhagfogifgggkldgodflihgfeippi",
        symbol: "hand.thumbsdown.fill",
        colors: (NSColor(red: 0.95, green: 0.27, blue: 0.27, alpha: 1), NSColor(red: 0.74, green: 0.07, blue: 0.13, alpha: 1)))

    private static let others: [Sample] = [
        Sample(name: "Raindrop.io", version: "6.6.43", chromeId: "ldgfbffkinooeloadekpmfoklnobpien",
               symbol: "drop.fill",
               colors: (NSColor(red: 0.20, green: 0.62, blue: 0.98, alpha: 1), NSColor(red: 0.10, green: 0.36, blue: 0.85, alpha: 1))),
        Sample(name: "Momentum", version: "2.32.1", chromeId: "laookkfknpbbblfpciffpaejjkokdgca",
               symbol: "sun.max.fill",
               colors: (NSColor(red: 0.99, green: 0.66, blue: 0.24, alpha: 1), NSColor(red: 0.93, green: 0.40, blue: 0.16, alpha: 1))),
        Sample(name: "Wappalyzer", version: "6.10.73", chromeId: "gppongmhjkpfnbhagpmjfkannfbllamg",
               symbol: "wand.and.stars",
               colors: (NSColor(red: 0.58, green: 0.38, blue: 0.96, alpha: 1), NSColor(red: 0.38, green: 0.19, blue: 0.78, alpha: 1))),
        Sample(name: "JSON Viewer", version: "0.18.1", chromeId: "gbmdgpbipfallnflgajpaliibnhdgobh",
               symbol: "curlybraces",
               colors: (NSColor(red: 0.29, green: 0.33, blue: 0.40, alpha: 1), NSColor(red: 0.13, green: 0.15, blue: 0.19, alpha: 1))),
    ]

    private static func fixtureHistory() -> [ConversionRecord] {
        let now = Date()
        func record(_ sample: Sample, _ browser: Browser, hoursAgo: Double, freeDaysLeft: Double? = nil) -> ConversionRecord {
            var record = ConversionRecord(
                name: sample.name, sourcePath: sample.file.path, appName: sample.name,
                installedPath: browser == .safari ? "/Applications/\(sample.name).app" : nil,
                date: now.addingTimeInterval(-hoursAgo * 3600), adHoc: false,
                iconData: sample.icon.pngData(), storeId: sample.chromeId, chromeId: sample.chromeId,
                version: sample.version)
            record.browser = browser
            record.freeRemovesAt = freeDaysLeft.map { now.addingTimeInterval($0 * 86_400) }
            if browser == .firefox { record.addonId = "\(sample.chromeId)@viaduct" }
            return record
        }
        return [
            record(others[0], .safari, hoursAgo: 26, freeDaysLeft: 5.9),
            record(others[1], .firefox, hoursAgo: 75),
            record(others[3], .safari, hoursAgo: 290),
        ]
    }

    private static let failureSummary = "xcodebuild: Command CodeSign failed with a nonzero exit code (exit 65)"

    private static var failureLog: [String] {
        [
            "$ viaduct convert \"\(picked.file.path)\" --app-name \"\(picked.name)\"",
            "→ Extracting \(picked.name).crx",
            "✓ Loaded \"\(picked.name)\" \(picked.version) (Manifest V3)",
            "→ Staging clean copy",
            "→ Running safari-web-extension-packager",
            "→ Building (Release, team-signed)",
            "✗ \(failureSummary)",
        ]
    }

    private static func failureReport() -> ProblemReport {
        IssueReport.conversionFailure(
            extensionName: picked.name, version: picked.version, storeId: picked.chromeId,
            summary: failureSummary, log: failureLog, cliVersion: vm.installedVersion,
            engineVersion: vm.engineVersion(for: .safari), browser: .safari, persistVersion: vm.persistVersion)
    }

    /// A batch caught partway: the first one failed, the second is getting
    /// ready and stays that way until the step is over, the rest wait.
    private static func queueItems() -> [QueueItem] {
        let gone = others[2]
        let failing = QueueItem(name: gone.name, iconPNG: gone.icon.pngData(), chromeId: gone.chromeId) {
            let home = FileManager.default.homeDirectoryForCurrentUser
            throw BrowserExtensionScanner.StageError.missingSource(home.appendingPathComponent(
                "Library/Application Support/Google/Chrome/Default/Extensions/\(gone.chromeId)/\(gone.version)_0"))
        }
        let held = QueueItem(name: picked.name, iconPNG: picked.icon.pngData(), chromeId: picked.chromeId) {
            try await withCheckedThrowingContinuation { continuation in
                Task { @MainActor in heldQueueItem = continuation }
            }
        }
        let waiting = [others[0], others[1]].map { sample in
            QueueItem(name: sample.name, iconPNG: sample.icon.pngData(), chromeId: sample.chromeId,
                      browser: sample.name == others[1].name ? .firefox : .safari) { sample.file }
        }
        return [failing, held] + waiting
    }
}
#endif
