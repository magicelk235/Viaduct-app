import SwiftUI
import AppKit
import ServiceManagement
import Combine

@MainActor
final class ConverterViewModel: ObservableObject {
    @Published var options = ConvertOptions() {
        didSet {
            // A verdict is for one browser, and so is a check still running.
            guard options.browser != oldValue.browser else { return }
            compatibilityCheck?.cancel()
            compatibility = nil
        }
    }
    @Published var logLines: [String] = []
    @Published var isRunning = false

    @Published var updateChecking = false
    @Published var updateAvailable = false
    @Published var installedVersion: String = "not installed"

    /// True while the CLI is being fetched from npm because none is installed.
    /// The engine isn't shipped in the .app, so on a first launch (or after
    /// someone clears Application Support) this is the one wait the user can't
    /// skip — it has to be visible instead of looking like a dead button.
    @Published var cliInstalling = false

    /// Why the first install failed, if it did — almost always no network.
    @Published var cliInstallError: String?

    // User-mode flow
    @Published var phase: ConvertPhase = .idle
    @Published var installedAppPath: String? = nil
    @Published var failureSummary: String? = nil
    @Published var extInfo: ExtensionInfo? = nil
    @Published var inspecting = false
    /// Highest real track phase reached this run — survives the flip to `.failed`
    /// so the failure card can name the step that broke.
    @Published var lastReachedTrackPhase: ConvertPhase? = nil
    /// Set when the picked extension can't work in the browser it's for: by
    /// the check that runs as soon as it's picked, or read off a conversion
    /// the CLI refused. Switching browsers clears it.
    @Published var compatibility: CompatibilityVerdict?
    private var compatibilityCheck: Task<Void, Never>?

    /// True when the conversion that just finished came out ad-hoc signed. The
    /// CLI rebuilds ad-hoc when the team it detected can't sign, so a run the
    /// app expected to be team-signed can still land unsigned — and Safari then
    /// refuses the extension until the unsigned toggle is on, which the done
    /// card has to say out loud.
    @Published var lastBuildAdHoc = false

    /// Drives the paywall sheet. Open it with `presentPaywall(for:)`.
    @Published var showPaywall = false
    /// The browser that ran out of free conversions, so the paywall can point
    /// at what unlocks it. Nil when the paywall was opened some other way.
    @Published private(set) var paywallBrowser: Browser?

    func presentPaywall(for browser: Browser?) {
        paywallBrowser = browser
        showPaywall = true
    }

    /// The paywall sheet calls this once it's gone, so whatever opens it next
    /// doesn't inherit the last browser.
    func paywallDidClose() {
        paywallBrowser = nil
    }

    /// Free-plan extensions Viaduct removed that the user hasn't been told
    /// about in the window yet. Saved, because the removal usually happens
    /// while the window is closed, and the message waits for the next open.
    @Published var removedOnFreePlan: [FreePlan.RemovedExtension] = FreePlan.RemovedExtension.saved(in: .standard) {
        didSet { FreePlan.RemovedExtension.save(removedOnFreePlan, in: .standard) }
    }

    /// Whether the bundled Safari extension (the Add-to-Safari button on
    /// Chrome Web Store pages) is enabled in Safari. nil until Safari answers,
    /// which the UI reads as off. Refreshed at launch and on focus regain, so
    /// enabling it in Safari shows up the moment the user switches back.
    @Published var storeButtonEnabled: Bool?

    /// Set when a conversion needs full Xcode but it isn't installed/selected.
    /// Drives the honest "install Xcode" card instead of a silent build failure.
    @Published var needsXcode = false

    /// The precise reason the Xcode gate is up — drives which one-click fix the
    /// card offers (install / re-select / finish setup) instead of one dead-end
    /// "install Xcode" message that keeps re-failing for users who already did.
    @Published var xcodeStatus: CLIRunner.XcodeStatus = .ready

    /// True while a privileged Xcode fix is running. `-runFirstLaunch` installs
    /// packages and can take minutes, so the card has to say something is
    /// happening instead of freezing behind a synchronous call.
    @Published var xcodeFixing = false

    /// Set when converting would fall back to ad-hoc signing (no Apple account
    /// in Xcode). Drives a pre-convert warning instead of letting the extension
    /// silently vanish on the next Safari quit.
    @Published var showAdhocWarning = false

    /// Set when a conversion was parked waiting on an Apple account in Xcode.
    /// Unlike the Xcode gate this lands in a plain .failed state, so without its
    /// own flag the focus-regain recheck skips it and the user has to relaunch
    /// the app before it notices they signed in.
    @Published var needsAppleAccount = false

    /// True when Xcode knows about an Apple ID but still can't team-sign. The
    /// account is signed in and the warning would otherwise tell the user to do
    /// the thing they already did, so the message has to say what's actually
    /// missing: the signing certificate Xcode only creates once a project
    /// targets the team.
    @Published var adhocDespiteAccount = false

    /// Silences the pre-convert signing warning for good. Off unless the user
    /// turns it on under Settings → Warnings. "Convert Anyway" on the alert
    /// deliberately doesn't set this: one click shouldn't leave every later
    /// conversion signing ad-hoc with nothing said.
    @AppStorage("adhocAcknowledged") var adhocAcknowledged = false

    /// One-time pass from "Convert Anyway", consumed by the gate that raised the
    /// alert. In memory only, so the warning is back on the next conversion and
    /// on the next launch.
    private var adhocBypassOnce = false

    /// Chrome Web Store id of the install in flight (store flow only). Stamped
    /// onto the history record so auto-update can re-download it by id.
    var pendingStoreId: String?
    /// Chrome id of the install in flight when it's known up front (Import
    /// from Chrome), recorded so a later import can tell it's already here.
    var pendingChromeId: String?

    /// Fired when a user-mode conversion that actually started comes to an end,
    /// with whether it installed. The batch queue advances on it.
    var userRunEnded: ((Bool) -> Void)?

    /// "Convert Anyway" answered once for a whole batch, so a queue of nine
    /// extensions asks about signing once rather than nine times. The queue
    /// clears it when the batch ends.
    var signingWarningAnsweredForBatch = false
    var batchActive = false

    /// The one view model the app runs on. Shared rather than owned by the
    /// window, because launch work (license check, store auto-update, the store-page
    /// URL handler) has to run even when the app starts with no window open.
    static let shared = ConverterViewModel()

    let history = ConversionHistory()

    /// Every Apple team this Mac can sign with, best first. Cached here because
    /// detecting them shells out to `defaults` and scans the keychain, which is
    /// far too costly to run from a SwiftUI body. Empty until the first
    /// detection lands, and on a Mac with no Apple account at all.
    @Published var signingTeams: [SigningAccount.Team] = []

    /// The team the next conversion signs with.
    var signingTeam: SigningAccount.Team? {
        SigningAccount.signingTeam(from: signingTeams)
    }

    /// Auto-update installed store extensions when the Chrome Web Store ships a
    /// newer version. Off by default — it polls the CWS, so it's opt-in. Needs
    /// a license.
    @AppStorage("autoUpdate") var autoUpdate = false

    /// The stored toggle AND a license that unlocks it: a free user can't
    /// enable CWS polling by flipping the persisted flag some other way.
    var autoUpdateEnabled: Bool { autoUpdate && ExtensionUpdater.isUnlocked(by: LicenseManager.shared.entitlements) }

    private let runner = CLIRunner.shared
    private let updater = CLIUpdater.shared
    private lazy var extensionUpdater = ExtensionUpdater(history: history)
    private lazy var freePlan: FreePlan = {
        let plan = FreePlan(history: history)
        plan.onRemoved = { [weak self] removed in
            self?.removedOnFreePlan += removed.map { FreePlan.RemovedExtension(name: $0.name, browser: $0.browser) }
        }
        return plan
    }()
    private var updateTimer: Timer?
    private var licenseWatch: AnyCancellable?
    private var historyWatch: AnyCancellable?
    /// Bumped whenever a CLI run starts or is cancelled. A cancelled process
    /// still prints and exits after SIGTERM; its callbacks check this and stay
    /// quiet, so they can't fail the card or end a batch item that came later.
    private var runGeneration = 0
    /// An update found while a conversion was in flight, applied as soon as the
    /// run finishes. Dropping it meant anyone who only installs from the store
    /// URL scheme never updated at all: the app cold-launches, the conversion
    /// starts before the npm check comes back, and the check then finds itself
    /// "busy" every single time.
    private var updatePendingAfterRun = false
    /// Last `✗` line the CLI printed this run, used as the failure reason.
    private var lastCLIError: String?
    /// The first-install download in flight, so concurrent callers share it.
    private var cliInstallTask: Task<Bool, Never>?

    private init() {
        installedVersion = updater.installedVersion ?? "not installed"
        // The store-button heartbeat: the appex relays the extension's hello
        // over the distributed bus whenever Safari starts its worker. Stamp it
        // and flip the flag, so an open "turn it on" popup stands down live.
        DistributedNotificationCenter.default().addObserver(
            forName: StoreButton.aliveNote, object: nil, queue: .main
        ) { [weak self] _ in
            StoreButton.markAlive()
            self?.storeButtonEnabled = true
        }
    }

    /// Launch hook: make sure the CLI exists (first launch downloads it), keep it
    /// current, and start store auto-update. Idempotent.
    func onLaunch() {
        if updater.isInstalled {
            // Auto-update the CLI on launch (self-installs if a newer version exists).
            checkForUpdates()
        } else {
            // Nothing to compare against yet: fetch the published package now so
            // the engine is there before the user drops anything on the window.
            Task { await ensureCLIInstalled() }
        }
        // Forget extensions the user deleted from Finder, and Firefox add-ons
        // persist no longer keeps.
        Task { await history.pruneDeleted() }
        refreshSigningTeams()
        refreshStoreButton()
        // Nothing is decided until the launch check has an answer. After that,
        // every change to what's unlimited can keep or sweep free-plan
        // extensions and switch store updates on or off.
        licenseWatch = LicenseManager.shared.$entitlements
            .combineLatest(LicenseManager.shared.$hasLaunchAnswer)
            .filter { $0.1 }
            .map { $0.0 }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] entitlements in
                // Free-plan removals: a license keeps the ones it covers. That
                // changes the list, and the history watch below then brings
                // the login item in line.
                self?.freePlan.sync()
                // Bought after the fact: nothing left to upsell for a browser
                // that's now unlimited. A Safari key still has something to
                // offer someone whose Firefox add-on was removed.
                self?.removedOnFreePlan.removeAll { entitlements.unlimited($0.browser) }
                self?.startAutoUpdate()
            }
        // Any change to the list (a conversion, a removal from Settings or the
        // store page, an app deleted in Finder) can add or retire a free-plan
        // removal; keep its timer, reminder and the login item current.
        historyWatch = history.$records
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.freePlan.sync()
                self?.syncLoginItem()
            }
    }

    /// Re-read the store-button heartbeat (live changes arrive via the
    /// observer in init).
    func refreshStoreButton() {
        storeButtonEnabled = StoreButton.isEnabled
    }

    /// Work out which Apple teams this Mac can sign with, and whether it can
    /// team-sign at all. Off the main thread: it's four `defaults` reads, a
    /// keychain scan and the provisioning profiles on disk, and nothing on
    /// screen is waiting for the answer.
    func refreshSigningTeams() {
        Task.detached(priority: .utility) {
            let teams = SigningAccount.availableTeams()
            await MainActor.run { self.signingTeams = teams }
        }
    }

    /// Install the CLI if it isn't on disk, and report whether it is now. Several
    /// callers can race here — launch, a conversion started from the store page,
    /// a click on Convert — so they all join one download instead of each
    /// starting their own.
    @discardableResult
    func ensureCLIInstalled() async -> Bool {
        if updater.isInstalled { return true }
        if let inFlight = cliInstallTask { return await inFlight.value }
        let task = Task { @MainActor () -> Bool in
            cliInstalling = true
            cliInstallError = nil
            appendLog("→ Installing the viaduct engine from npm…")
            do {
                try await updater.update(rawLog: { [weak self] line in self?.appendLog(line) })
            } catch {
                cliInstallError = error.localizedDescription
                appendLog("✗ \(error.localizedDescription)")
            }
            cliInstalling = false
            cliInstallTask = nil
            installedVersion = updater.installedVersion ?? "not installed"
            let ok = updater.isInstalled
            if ok {
                updateAvailable = false
                // Auto-update was skipped at launch for want of an engine; now
                // there is one, so give it its pass — unless a conversion is
                // already queued behind this download, since an update would
                // take the single CLI slot out from under it.
                if !isRunning { startAutoUpdate() }
            } else {
                let msg = cliInstallError ?? "The converter engine could not be installed."
                cliInstallError = msg
            }
            return ok
        }
        cliInstallTask = task
        return await task.value
    }

    /// Start store auto-update at launch and re-check daily. Idempotent. The
    /// per-record weekly gate keeps CWS polling to at most once a week.
    func startAutoUpdate() {
        // Nothing to decide until the license check has an answer.
        guard LicenseManager.shared.hasLaunchAnswer else { return }
        syncLoginItem()
        guard autoUpdateEnabled else { return }
        extensionUpdater.updateIfNeeded()
        guard updateTimer == nil else { return }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.autoUpdateEnabled, !self.isRunning, !self.batchActive else { return }
                self.extensionUpdater.updateIfNeeded()
            }
        }
    }

    /// Something holds the CLI: a user conversion or a background update. The
    /// CLI folder mustn't be swapped and the app mustn't relaunch under either.
    var isBusy: Bool { isRunning || runner.isRunning || extensionUpdater.isRunning }

    /// Register/unregister the app as a login item for whatever needs it
    /// running. SMAppService.mainApp — no separate helper bundle/plist to maintain.
    func syncLoginItem() {
        // Not before the launch check answers: "no answer yet" read as "no
        // license" would drop the login item for every paying user.
        guard LicenseManager.shared.hasLaunchAnswer else { return }
        do {
            if Self.wantsLoginItem(autoUpdate: autoUpdate, records: history.records,
                                   entitlements: LicenseManager.shared.entitlements) {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            appendLog("⚠︎ Login-item update failed: \(error.localizedDescription)")
        }
    }

    /// Background features need the app relaunched at login so their timers
    /// survive reboots: the weekly store update, when it covers a record, and
    /// the free-plan removal that would otherwise never happen if the user
    /// just quit.
    nonisolated static func wantsLoginItem(autoUpdate: Bool, records: [ConversionRecord],
                                           entitlements: Entitlements) -> Bool {
        (autoUpdate && records.contains { ExtensionUpdater.covers($0, entitlements: entitlements) })
            || records.contains { $0.freeRemovesAt != nil }
    }

    // MARK: - Logging

    @discardableResult
    func appendLog(_ line: String) -> String {
        let clean = stripANSI(line)
        logLines.append(clean)
        if logLines.count > 5000 { logLines.removeFirst(logLines.count - 5000) }
        return clean
    }

    // MARK: - Convert

    /// Convert + install + register with Safari. Drives `phase` for the
    /// animated UI instead of exposing the raw log.
    func userConvert() {
        guard !isRunning else { return }
        guard !options.inputPath.isEmpty,
              FileManager.default.fileExists(atPath: options.inputPath) else {
            failureSummary = "Pick an extension first."
            phase = .failed
            return
        }
        // The freemium gate is enforced in runCLI, the choke point every
        // conversion path (single, batch, store page, Shortcuts) goes through.

        if options.appName.isEmpty {
            options.appName = URL(fileURLWithPath: options.inputPath)
                .deletingPathExtension().lastPathComponent
        }

        // Full Xcode is required to package + sign the extension (Apple ships the
        // Safari packager only with Xcode). Detect it up front and explain, rather
        // than letting the run die deep inside xcodebuild with a cryptic log.
        let status = CLIRunner.xcodeStatus()
        guard status == .ready else {
            xcodeStatus = status
            needsXcode = true
            failureSummary = Self.xcodeMessage(for: status)
            phase = .failed
            Feedback.failure()
            return
        }

        // Read the teams here rather than trusting the launch-time answer: the
        // user may have signed into Xcode since, and the row that lets them pick
        // between two accounts has to be picking between the current two.
        signingTeams = SigningAccount.availableTeams()

        // The CLI silently falls back to ad-hoc signing when Xcode has no Apple
        // account — and Safari disables ad-hoc extensions on every quit. Warn
        // up front instead of letting the extension quietly vanish later.
        if !adhocAcknowledged, !adhocBypassOnce, !signingWarningAnsweredForBatch, signingTeams.isEmpty {
            adhocDespiteAccount = SigningAccount.xcodeAccountPresent()
            // Surface the alert even for headless viaduct:// installs. It lives
            // on the main window, which may be closed (quit to the menu bar).
            MainWindow.show()
            showAdhocWarning = true
            return
        }
        // Past the gate, so the pass has done its job.
        adhocBypassOnce = false

        // Sign with the best team this Mac has. The id goes to the CLI explicitly:
        // left to detect a team itself it takes whichever Xcode cached first, which
        // on a Mac with a personal team and a paid one isn't the paid one.
        options.useTeam(signingTeam?.id)

        installedAppPath = nil
        failureSummary = nil
        lastReachedTrackPhase = nil
        lastBuildAdHoc = false
        // The run analyzes it anyway, and a refusal is read off its log.
        compatibilityCheck?.cancel()
        phase = .extracting
        var args = options.conversionArgs()
        // Ask the CLI to launch the host app hidden (it still registers with
        // Safari) so its window doesn't pop over the converting animation —
        // `completeFinishing()` opens it once the animation is done. Older CLIs
        // reject unknown flags outright, so only ask when the flag exists.
        if let v = updater.installedVersion, !CLIUpdater.semverLess(v, "1.11.8") {
            args.append("--background-launch")
        }
        runCLI(args: args)
    }

    /// "Convert Anyway" on the signing warning: run this one conversion without
    /// the gate. The next one asks again unless the user silences the warning in
    /// Settings.
    func convertIgnoringSigning() {
        adhocBypassOnce = true
        if batchActive { signingWarningAnsweredForBatch = true }
        userConvert()
    }

    /// Save the just-finished conversion to history.
    private func recordConversion() {
        // Manifest name unless it's an unresolved __MSG_ i18n key; then the store
        // display name (appName), then the filename — which for store installs is
        // the random-looking extension id, so it's the last resort.
        let name = extInfo?.name.hasPrefix("__MSG_") == false
            ? extInfo!.name
            : (!options.appName.isEmpty
                ? options.appName
                : URL(fileURLWithPath: options.inputPath).deletingPathExtension().lastPathComponent)
        // Stash a durable copy of the source so it can be rebuilt or moved to
        // another Mac even if the user moves/deletes the original (or the cached
        // store .crx is purged).
        let archived = ExtensionUpdater.archiveSource(options.inputPath, appName: options.appName,
                                                      browser: options.browser)
        // Read the artifact, because a run can succeed and still have come out
        // ad-hoc.
        let build = SigningAccount.inspectBuild(installedAppPath: installedAppPath)
        lastBuildAdHoc = build.adHoc
        history.add(browser: options.browser, name: name, sourcePath: archived ?? options.inputPath,
                    appName: options.appName,
                    installedPath: installedAppPath,
                    adHoc: build.adHoc,
                    iconData: extInfo?.icon?.pngData(),
                    storeId: pendingStoreId,
                    chromeId: pendingChromeId ?? pendingStoreId
                        ?? ExtensionIdentity.chromeId(forSource: options.inputPath),
                    version: extInfo?.version,
                    freeRemovesAt: FreePlan.removalDate(unlimited: LicenseManager.shared.unlimited(.safari)))
        pendingStoreId = nil
        pendingChromeId = nil
        // Count this against the free quota (does nothing once Safari is unlimited).
        LicenseManager.shared.recordFreeConversion(.safari)
    }

    /// Honest, per-state guidance for the Xcode gate. Each case names exactly
    /// what's wrong and what the button will do, so a user who already has Xcode
    /// never hits the same dead-end "install Xcode" text again.
    static func xcodeMessage(for status: CLIRunner.XcodeStatus) -> String {
        switch status {
        case .ready:
            return ""
        case .notInstalled:
            return "Building a Safari extension needs Apple's Xcode, so Viaduct can't bundle it. It's free on the App Store."
        case let .notSelected(dev):
            // Name the copy: with an Xcode beta beside a release, "point macOS at
            // Xcode" is otherwise a blind switch between two different Xcodes.
            return "\(Self.appName(developerDir: dev)) is installed, but macOS is still pointed at the Command Line Tools. Viaduct can point macOS at it for you; you'll be asked for your password."
        case .setupIncomplete:
            return "Xcode hasn't finished its first-launch setup, so nothing can build yet. Viaduct can accept the license and install the missing components. You'll be asked for your password, and it takes a few minutes."
        case .installIncomplete:
            return "This copy of Xcode is missing the pieces that build Safari extensions, so the install is incomplete or damaged. Reinstalling Xcode should sort it out."
        }
    }

    /// Display name of the Xcode behind a developer dir ("Xcode", "Xcode-beta"),
    /// falling back to "Xcode" for a path that isn't inside an app bundle.
    private static func appName(developerDir: String) -> String {
        let app = URL(fileURLWithPath: developerDir)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return app.pathExtension == "app"
            ? app.deletingPathExtension().lastPathComponent
            : "Xcode"
    }

    /// Open Xcode's App Store page so the user can install it in one click.
    func openXcodeInstall() {
        // Apple\u{2019}s Xcode App Store product page.
        if let url = URL(string: "macappstore://apps.apple.com/app/xcode/id497799835") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Apple's developer downloads, filtered to Xcode. The route for anyone the
    /// App Store can't serve: a macOS beta (where the released Xcode won't run)
    /// or a Mac that needs an older Xcode. Free Apple ID, same as signing.
    func openXcodeDeveloperDownloads() {
        if let url = URL(string: "https://developer.apple.com/download/all/?q=xcode") {
            NSWorkspace.shared.open(url)
        }
    }

    /// One-click recovery for the "Xcode installed but not selected" trap: point
    /// macOS at Xcode (admin prompt), then, if that clears the gate, resume the
    /// conversion the user was trying to run.
    func fixXcodeSelection() {
        guard case let .notSelected(dev) = xcodeStatus else { return }
        runXcodeFix { CLIRunner.selectXcode(developerDir: dev) }
    }

    /// One-click recovery for a fresh Xcode that hasn't finished first-launch.
    func finishXcodeSetup() {
        runXcodeFix { CLIRunner.finishXcodeFirstLaunch() }
    }

    /// Run a privileged fix off the main thread, then act on what actually
    /// happened. Reporting the command's own output matters: a fix that cannot
    /// work otherwise looks exactly like one the user cancelled, which is how a
    /// stuck machine ends up clicking the same button forever.
    private func runXcodeFix(_ fix: @escaping () -> CLIRunner.FixOutcome) {
        guard !xcodeFixing else { return }
        xcodeFixing = true
        Task.detached(priority: .userInitiated) {
            let outcome = fix()
            await MainActor.run { self.applyXcodeFix(outcome) }
        }
    }

    private func applyXcodeFix(_ outcome: CLIRunner.FixOutcome) {
        xcodeFixing = false
        switch outcome {
        case .fixed:
            clearXcodeGateAndRetry()
        case .cancelled:
            recheckXcode()
        case let .failed(detail):
            recheckXcode()
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            appendLog("\u{2717} " + trimmed)
            // The card stays readable; the untruncated text is in the log the
            // failure view can copy.
            let short = trimmed.count > 300
                ? String(trimmed.prefix(300)) + "\u{2026}"
                : trimmed
            failureSummary = (failureSummary.map { $0 + "\n\n" } ?? "") + "Xcode said: " + short
        }
    }

    /// Re-diagnose Xcode; drop the gate if it's now clear. Called when the app
    /// regains focus so a finished download/install/switch clears the card
    /// without the user hunting for a "try again" button. Keeps the picked
    /// extension so the CTA falls back to "Convert & Install".
    func recheckXcode() {
        // Someone who joined the Developer Program in another window shouldn't
        // have to relaunch to see the year they now sign for.
        refreshSigningTeams()
        // Same trip: the focus regain after "Turn On in Safari" is when the
        // store-button nudge learns it can stand down.
        refreshStoreButton()
        // Signing into Xcode and switching back should be enough. Resume the
        // parked conversion the same way the Xcode gate's one-click fixes do.
        if needsAppleAccount, SigningAccount.xcodeTeamPresent() {
            needsAppleAccount = false
            failureSummary = nil
            phase = .idle
            if !options.inputPath.isEmpty { userConvert() }
            return
        }
        guard needsXcode else { return }
        let status = CLIRunner.xcodeStatus()
        xcodeStatus = status
        if status == .ready {
            needsXcode = false
            failureSummary = nil
            if phase == .failed { phase = .idle }
        } else {
            failureSummary = Self.xcodeMessage(for: status)
        }
    }

    /// Gate is clear after a one-click fix: resume the conversion in flight, or
    /// just drop the card if there's nothing queued.
    private func clearXcodeGateAndRetry() {
        needsXcode = false
        xcodeStatus = .ready
        failureSummary = nil
        if options.inputPath.isEmpty { phase = .idle }
        else { phase = .idle; userConvert() }
    }

    /// Reveal a previously-installed extension app in Finder (used by history).
    func reveal(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Re-run a past conversion: reload its source and kick off the one-tap flow.
    /// Skips silently if the source file is gone (e.g. moved/deleted since).
    func reconvert(_ record: ConversionRecord) {
        guard FileManager.default.fileExists(atPath: record.sourcePath) else {
            failureSummary = "The original file has moved or been deleted, so it can't be converted again. It was at \(record.sourcePath)."
            phase = .failed
            return
        }
        resetUserFlow()
        selectInput(path: record.sourcePath)
        userConvert()
    }

    /// Put the whole log on the pasteboard (used by the failure card).
    func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logLines.joined(separator: "\n"), forType: .string)
    }

    func resetUserFlow() {
        phase = .idle
        installedAppPath = nil
        failureSummary = nil
        extInfo = nil
        needsXcode = false
        needsAppleAccount = false
        lastBuildAdHoc = false
        options.inputPath = ""
        compatibilityCheck?.cancel()
        compatibility = nil
        options.appName = ""
        // A store install that stopped early would otherwise stamp its id on
        // the next, unrelated conversion.
        pendingStoreId = nil
        pendingChromeId = nil
    }

    private func runCLI(args: [String]) {
        if let err = options.validationError() {
            appendLog("✗ \(err)")
            failureSummary = err
            phase = .failed
            return
        }
        if !LicenseManager.shared.canConvert(.safari) {
            presentPaywall(for: .safari)
            appendLog("✗ Free conversion limit reached.")
            phase = .idle
            return
        }
        // No engine yet (first launch, or the launch fetch hasn't landed): get it,
        // then start the run. `isRunning` covers the download too, so a second
        // click can't queue a second conversion behind the same fetch, and
        // Sparkle won't relaunch us mid-download.
        if !updater.isInstalled {
            isRunning = true
            runGeneration += 1
            let generation = runGeneration
            Task {
                let ok = await ensureCLIInstalled()
                // Cancelled while the download ran (cancel() bumps the
                // generation), or a newer run took over.
                guard isRunning, runGeneration == generation else { return }
                isRunning = false
                guard ok else {
                    failureSummary = cliInstallError ?? "The converter engine could not be installed."
                    phase = .failed
                    userRunEnded?(false)
                    return
                }
                runCLI(args: args)
            }
            return
        }
        // A background store update may hold the CLI (it runs at launch and daily).
        // Wait for it rather than failing with "A task is already running".
        if runner.isRunning {
            isRunning = true
            runGeneration += 1
            let generation = runGeneration
            appendLog("→ Waiting for a background update to finish…")
            Task {
                while runner.isRunning {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                guard isRunning, runGeneration == generation else { return }
                isRunning = false
                runCLI(args: args)
            }
            return
        }
        isRunning = true
        lastCLIError = nil
        runGeneration += 1
        let generation = runGeneration
        appendLog("$ viaduct \(args.joined(separator: " "))")
        do {
            try runner.run(args: args, onLine: { [weak self] line in
                guard let self, self.runGeneration == generation else { return }
                let clean = self.appendLog(line)
                // Keep the CLI's own reason for failing. The log stays hidden, so
                // without this every failure reads as the same generic sentence — which
                // is how a specific, actionable message like "the extension is ad-hoc"
                // ends up invisible to the person who needs it.
                if let reason = Self.errorReason(in: clean) { self.lastCLIError = reason }
                self.advancePhase(from: clean)
            }, onExit: { [weak self] code in
                guard let self, self.runGeneration == generation else { return }
                self.isRunning = false
                self.appendLog(code == 0 ? "✓ Done." : "✗ Exit \(code).")
                // Refused only for being a webRequest content blocker: it still
                // installs and its element hiding works, so convert it anyway.
                if code != 0, !args.contains("--force"),
                   let refused = CompatibilityCheck.refusal(inLog: self.logLines),
                   !refused.isEmpty, refused.allSatisfy(\.isContentBlocker) {
                    self.runCLI(args: args + ["--force"])
                    return
                }
                if code == 0 { self.recordConversion() }
                self.finishUserPhase(code: code)
                self.userRunEnded?(code == 0)
                // Pick up an update the check had to skip while this run held
                // the CLI. Swapping now is safe: nothing is executing it.
                if self.updatePendingAfterRun {
                    self.updatePendingAfterRun = false
                    Task { await self.applyUpdate() }
                }
            })
        } catch {
            isRunning = false
            appendLog("✗ \(error.localizedDescription)")
            failureSummary = error.localizedDescription
            phase = .failed
            userRunEnded?(false)
        }
    }

    /// Move `phase` forward (never backward) based on a CLI line; capture the
    /// Safari app's install path. A Firefox run installs through persist instead.
    private func advancePhase(from line: String) {
        if options.browser == .safari, let installed = installedPath(from: line) { installedAppPath = installed }
        if let next = ConvertPhase.detect(from: line, browser: options.browser), next.rawValue > phase.rawValue {
            phase = next
            if ConvertPhase.track.contains(next) { lastReachedTrackPhase = next }
            Feedback.step()
        }
    }

    /// The CLI's own failure text, recognised by the `✗` it prefixes errors with.
    /// Returns nil for anything else, so ordinary progress lines never masquerade
    /// as a reason.
    static func errorReason(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("✗") else { return nil }
        let text = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private func finishUserPhase(code: Int32) {
        if code == 0 {
            // CLI is done, but let the orbit absorb its last satellites first.
            // `completeFinishing()` (fired after the final absorption lands)
            // flips to .done, which surfaces the "Open extension" button.
            phase = .finishing
        } else {
            if let verdict = CompatibilityCheck.verdict(fromLog: logLines, browser: options.browser) {
                compatibility = verdict
                failureSummary = verdict.message
            } else {
                failureSummary = lastCLIError
                    ?? "The conversion stopped partway through. Copy the log to see what failed, or report it."
            }
            phase = .failed
            Feedback.failure()
        }
    }

    /// Called by the conversion orbit once everything is absorbed during
    /// `.finishing`. Marks the flow done and opens the converted extension app
    /// so its enable-in-Safari window appears — after the animation, never over
    /// it (the CLI's own install launch is hidden via --background-launch).
    func completeFinishing() {
        guard phase == .finishing else { return }
        phase = .done
        Feedback.success()
        // A batch opens Safari's settings once at the end instead of launching
        // every converted app over the queue.
        if !batchActive { openConvertedApp() }
    }

    /// Launch the freshly-built Safari Web Extension host app so its enable
    /// sheet appears. Falls back to revealing it in Finder if launch fails.
    func openConvertedApp() {
        guard let path = installedAppPath else { return }
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.openApplication(at: url,
                                           configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if error != nil {
                DispatchQueue.main.async {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
    }

    /// Pull the installed .app path out of "Installed → /path" or "Installed: /path".
    private func installedPath(from line: String) -> String? {
        for marker in ["Installed → ", "Installed: "] {
            if let r = line.range(of: marker) {
                let p = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !p.isEmpty { return p }
            }
        }
        return nil
    }

    func cancel() {
        runGeneration += 1
        runner.cancel()
        appendLog("⚠︎ Cancelled.")
        isRunning = false
    }

    // MARK: - Update

    /// Check the registry and, if a newer CLI exists, install it immediately —
    /// no "Update Now" click. Skips if a conversion is mid-flight (don't swap the
    /// CLI out from under a running process).
    func checkForUpdates() {
        // Not installed yet: there is no version to compare against, so this is
        // an install, not an update check.
        guard updater.isInstalled else { Task { await ensureCLIInstalled() }; return }
        guard !updateChecking else { return }
        updateChecking = true
        Task {
            defer { updateChecking = false }
            // A failed check just waits for the next launch.
            guard let available = try? await updater.updateAvailable() else { return }
            updateAvailable = available
            guard available else { return }
            guard !isBusy else {
                updatePendingAfterRun = true
                return
            }
            await applyUpdate()
        }
    }

    /// Download + swap the latest CLI. Shared by auto-update and the manual button.
    private func applyUpdate() async {
        // Nothing installed yet, so this is the first install rather than an
        // update; that path owns the "installing" UI and coalesces racing
        // callers onto one download.
        guard updater.isInstalled else {
            await ensureCLIInstalled()
            return
        }
        appendLog("→ Auto-updating CLI…")
        do {
            try await updater.update(rawLog: { [weak self] line in self?.appendLog(line) })
            installedVersion = updater.installedVersion ?? "not installed"
            updateAvailable = false
        } catch {
            // Kept in the log: Settings re-checks, and the next launch retries.
            appendLog("✗ \(error.localizedDescription)")
        }
    }

    func updateCLI() {
        Task { await applyUpdate() }
    }

    // MARK: - File pickers

    /// Set the input path, derive a default app name, and inspect for name + icon.
    func selectInput(path: String) {
        options.inputPath = path
        if options.appName.isEmpty {
            options.appName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
        extInfo = nil
        inspecting = true
        ExtensionInspector.inspect(path: path) { [weak self] info in
            guard let self else { return }
            self.inspecting = false
            self.extInfo = info
            // Prefer the manifest name for the app if the user hasn't typed one.
            if let n = info?.name, !n.hasPrefix("__MSG_"), self.options.appName.isEmpty {
                self.options.appName = n
            }
        }
        // Say up front when it can't work, before Xcode, signing or a free
        // conversion come into it. A batch starts converting straight away and
        // gets the same answer from the run's log instead.
        compatibilityCheck?.cancel()
        compatibility = nil
        guard !batchActive else { return }
        let browser = options.browser
        compatibilityCheck = Task { [weak self] in
            let verdict = await CompatibilityCheck.run(path: path, browser: browser)
            guard !Task.isCancelled, let self, self.options.inputPath == path,
                  self.options.browser == browser, self.phase == .idle else { return }
            self.compatibility = verdict
        }
    }

    /// `allowBatch` lets user mode pick several at once; more than one goes to
    /// the batch queue.
    func pickInput(allowBatch: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = allowBatch
        panel.message = panel.allowsMultipleSelection
            ? "Choose one or more .zip, .crx, or unpacked extension folders."
            : "Choose a .zip, .crx, or unpacked extension folder."
        guard panel.runModal() == .OK else { return }
        if panel.urls.count > 1 {
            BatchConvert.start(panel.urls, vm: self)
        } else if let url = panel.url {
            selectInput(path: url.path)
        }
    }

    // MARK: - Helpers

    private func stripANSI(_ s: String) -> String {
        // Remove CSI escape sequences the CLI emits for color.
        guard s.contains("\u{1B}[") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "\u{1B}",
               let next = s.index(i, offsetBy: 1, limitedBy: s.endIndex),
               next < s.endIndex, s[next] == "[" {
                var j = s.index(after: next)
                while j < s.endIndex, !("@"..."~").contains(s[j]) {
                    j = s.index(after: j)
                }
                if j < s.endIndex { j = s.index(after: j) }
                i = j
            } else {
                out.append(s[i])
                i = s.index(after: i)
            }
        }
        return out
    }
}
