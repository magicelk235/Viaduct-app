import SwiftUI
import AppKit
import ServiceManagement

@MainActor
final class ConverterViewModel: ObservableObject {
    @Published var options = ConvertOptions()
    @Published var logLines: [String] = []
    @Published var isRunning = false
    @Published var statusMessage = "Ready."
    @Published var lastExitCode: Int32? = nil

    @Published var updateChecking = false
    @Published var updateAvailable = false
    @Published var installedVersion: String = "unknown"

    // User-mode flow
    @Published var phase: ConvertPhase = .idle
    @Published var installedAppPath: String? = nil
    @Published var failureSummary: String? = nil
    @Published var extInfo: ExtensionInfo? = nil
    @Published var inspecting = false
    /// Highest real track phase reached this run — survives the flip to `.failed`
    /// so the failure card can name the step that broke.
    @Published var lastReachedTrackPhase: ConvertPhase? = nil

    /// Set when an unlicensed user hits the free-quota wall; drives the paywall sheet.
    @Published var showPaywall = false

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
    /// onto the history record so auto-renew can re-download the source by id.
    var pendingStoreId: String?

    let history = ConversionHistory()

    /// Auto re-sign installed extensions before the free-account 7-day signature
    /// lapses. On by default — it's the thing that keeps extensions from vanishing.
    /// Pro-only: unlicensed users can't keep extensions alive past the ~7-day
    /// Apple free-signing window, which is the upgrade lever.
    @AppStorage("autoRenew") var autoRenew = true

    /// Whether auto-renew is actually allowed to run — the stored toggle AND a
    /// valid license. Gating here (not just the toggle UI) means a free user
    /// can't keep renewing by flipping the persisted flag some other way.
    var autoRenewEnabled: Bool { autoRenew && LicenseManager.shared.isLicensed }

    /// Auto-update installed store extensions when the Chrome Web Store ships a
    /// newer version. Off by default — it polls the CWS, so it's opt-in. Pro-only.
    @AppStorage("autoUpdate") var autoUpdate = false

    /// Same license gate as auto-renew: a free user can't enable CWS polling by
    /// flipping the persisted flag.
    var autoUpdateEnabled: Bool { autoUpdate && LicenseManager.shared.isLicensed }

    private let runner = CLIRunner.shared
    private let updater = CLIUpdater.shared
    private lazy var renewer = ExtensionRenewer(history: history)
    private var renewTimer: Timer?
    /// An update found while a conversion was in flight, applied as soon as the
    /// run finishes. Dropping it meant anyone who only installs from the store
    /// URL scheme never updated at all: the app cold-launches, the conversion
    /// starts before the npm check comes back, and the check then finds itself
    /// "busy" every single time.
    private var updatePendingAfterRun = false
    /// Last `✗` line the CLI printed this run, used as the failure reason.
    private var lastCLIError: String?

    init() {
        installedVersion = updater.installedVersion ?? "unknown"
    }

    /// Launch hook: auto-update the CLI and start auto-renew. Idempotent.
    func onLaunch() {
        // Auto-update the CLI on launch (self-installs if a newer version exists).
        checkForUpdates()
        // Forget extensions the user deleted from Finder, regardless of renew state.
        history.pruneDeleted()
        startAutoRenew()
    }

    /// Kick off auto-renew at launch and re-check daily. Idempotent.
    func startAutoRenew() {
        // Relaunch at login so the daily renew timer survives reboots — auto-renew
        // is worthless if the app isn't running when the 7-day window closes.
        syncLoginItem()
        // Auto-update shares the renew timer; its own per-record weekly gate keeps
        // CWS polling to at most once/week regardless of the daily tick.
        guard autoRenewEnabled || autoUpdateEnabled else { return }
        if autoRenewEnabled { renewer.renewIfNeeded() }
        if autoUpdateEnabled { renewer.updateIfNeeded() }
        guard renewTimer == nil else { return }
        renewTimer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isRunning else { return }
                if self.autoRenewEnabled { self.renewer.renewIfNeeded() }
                if self.autoUpdateEnabled { self.renewer.updateIfNeeded() }
            }
        }
    }

    /// Manual renew trigger from the menu bar. Same due-check as the timer.
    /// Pro-only: re-signing before expiry is a paid feature (matches the
    /// Settings auto-renew toggle, which is also licensed-only). Guard here so
    /// no caller can trigger a renew on the free tier.
    func renewNow() {
        guard LicenseManager.shared.isLicensed else { showPaywall = true; return }
        guard autoRenewEnabled, !isRunning else { return }
        renewer.renewIfNeeded()
    }

    /// Register/unregister the app as a login item to match `autoRenewEnabled`.
    /// SMAppService.mainApp — no separate helper bundle/plist to maintain.
    func syncLoginItem() {
        do {
            // Either background feature needs the app relaunched at login so its
            // daily timer survives reboots.
            if autoRenewEnabled || autoUpdateEnabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            appendLog("⚠︎ Login-item update failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Logging

    @discardableResult
    func appendLog(_ line: String) -> String {
        let clean = stripANSI(line)
        logLines.append(clean)
        if logLines.count > 5000 { logLines.removeFirst(logLines.count - 5000) }
        return clean
    }

    func clearLog() { logLines.removeAll() }

    // MARK: - Run actions

    func runConversion() {
        let args = options.conversionArgs()
        // A real build/sign needs full Xcode; --no-build / --temp-load do not.
        let needsBuild = !args.contains("--no-build") && !args.contains("--temp-load")
        if needsBuild {
            let status = CLIRunner.xcodeStatus()
            if status != .ready {
                xcodeStatus = status
                needsXcode = true
                statusMessage = "Full Xcode required for build/sign."
                appendLog("\u{2717} " + Self.xcodeMessage(for: status))
                appendLog("  Tip: use --temp-load or --no-build to convert without Xcode.")
                return
            }
        }
        runCLI(args: args, label: "Conversion")
    }
    func runAnalyze()    { runCLI(args: options.analyzeArgs(),   label: "Analysis") }
    func runDoctor()     { runCLI(args: ConvertOptions.doctorArgs(), label: "Toolchain check") }

    // MARK: - User-mode one-tap convert

    /// Convert + auto-install + register, forcing the simplest safe option set.
    /// Drives `phase` for the animated UI instead of exposing the raw log.
    func userConvert() {
        guard !isRunning else { return }
        guard !options.inputPath.isEmpty,
              FileManager.default.fileExists(atPath: options.inputPath) else {
            failureSummary = "Pick an extension first."
            phase = .failed
            return
        }
        // Freemium gate is enforced in runCLI (the choke point all conversion
        // paths funnel through, including Developer mode), so it can't be
        // bypassed by switching modes.

        // Force the user-friendly path: build, install to Applications, register with Safari.
        options.noBuild = false
        options.tempLoad = false
        options.install = true
        // Auto-detect the Apple identity (free or paid). A team-signed extension
        // survives Safari quitting, and lets auto-renew re-sign before expiry.
        // The CLI falls back to ad-hoc on its own if no team is found.
        options.signing = .autoTeam
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

        // The CLI silently falls back to ad-hoc signing when Xcode has no Apple
        // account — and Safari disables ad-hoc extensions on every quit. Warn
        // up front instead of letting the extension quietly vanish later.
        if !adhocAcknowledged, !adhocBypassOnce, !Self.xcodeTeamPresent() {
            adhocDespiteAccount = Self.xcodeAccountPresent()
            // Surface the alert even for headless viaduct:// installs.
            NSApp.activate(ignoringOtherApps: true)
            showAdhocWarning = true
            return
        }
        // Past the gate, so the pass has done its job.
        adhocBypassOnce = false

        installedAppPath = nil
        failureSummary = nil
        lastReachedTrackPhase = nil
        phase = .extracting
        runCLI(args: options.conversionArgs(), label: "Conversion", userMode: true)
    }

    /// "Convert Anyway" on the signing warning: run this one conversion without
    /// the gate. The next one asks again unless the user silences the warning in
    /// Settings.
    func convertIgnoringSigning() {
        adhocBypassOnce = true
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
        // Stash a durable copy of the source so auto-renew can rebuild later even if
        // the user moves/deletes the original (or the cached store .crx is purged).
        let archived = ExtensionRenewer.archiveSource(options.inputPath, appName: options.appName)
        history.add(name: name, sourcePath: archived ?? options.inputPath,
                    appName: options.appName,
                    installedPath: installedAppPath, iconData: extInfo?.icon?.pngData(),
                    storeId: pendingStoreId, version: extInfo?.version)
        pendingStoreId = nil
        // Count this against the free quota (no-op once licensed).
        LicenseManager.shared.recordFreeConversion()
    }

    /// True when the machine can team-sign. This has to agree with the CLI's own
    /// detectXcodeTeam() (`src/build/packager.ts`, as of 1.10.3): the app only
    /// decides whether to warn, the CLI decides how it actually signs, and when
    /// they disagree the user gets a silently ad-hoc build with no warning at
    /// all — or, the way it drifted this time, a warning on a machine the CLI
    /// would have team-signed on. They did drift once before too: the bundled
    /// CLI sat at 1.0.0, which had no keychain fallback, so the bundle is now
    /// synced from npm at build time (`sync-cli.sh`).
    ///
    /// Three source groups, in the CLI's order, cheapest first: the team ids
    /// Xcode caches in its preferences, any provisioning profile already on
    /// disk, then a signing certificate in the keychain. None of the earlier
    /// ones is authoritative — the preference cache is written asynchronously
    /// and stays empty on setups where the account is signed in but no team has
    /// been fetched yet — so a miss has to fall through rather than decide.
    static func xcodeTeamPresent() -> Bool {
        teamInPreferences() || teamInProvisioningProfiles() || teamInKeychain()
    }

    /// Team ids Xcode caches once an account is added. Two keys across two
    /// domains: current Xcode writes IDEProvisioningTeamByIdentifier, older
    /// versions and xcodebuild itself write IDEProvisioningTeams, and the
    /// xcodebuild domain is sometimes populated when the Xcode one is not.
    /// Which combination exists varies by Xcode version, and all four are cheap
    /// `defaults` reads.
    private static func teamInPreferences() -> Bool {
        for domain in ["com.apple.dt.Xcode", "com.apple.dt.xcodebuild"] {
            for key in ["IDEProvisioningTeamByIdentifier", "IDEProvisioningTeams"] {
                guard let out = shellOutput("/usr/bin/defaults", ["read", domain, key]) else {
                    continue
                }
                // Boundary after the 10 chars so a longer token isn't truncated
                // into a wrong-but-plausible id; a real team id is exactly 10.
                if out.range(of: #"teamID\s*=\s*"?[A-Z0-9]{10}(?![A-Z0-9])"?"#,
                             options: .regularExpression) != nil {
                    return true
                }
            }
        }
        return false
    }

    /// Where Xcode downloads provisioning profiles: Xcode 16+ first, then the
    /// location older versions used.
    private static let provisioningProfileDirs = [
        "Library/Developer/Xcode/UserData/Provisioning Profiles",
        "Library/MobileDevice/Provisioning Profiles",
    ]

    /// True when a provisioning profile on disk names a team. Profiles are
    /// CMS-signed, but the payload plist sits in the blob as plain XML, so
    /// scanning the bytes beats shelling out to `security cms -D` once per file.
    /// They're decoded as ISO-8859-1 because the CMS wrapper is binary and a
    /// UTF-8 decode of it fails outright; the plist itself is ASCII either way.
    private static func teamInProvisioningProfiles() -> Bool {
        // TeamIdentifier is the modern key. Profiles cut before Xcode 6 carry
        // only ApplicationIdentifierPrefix, whose single element is the team id.
        let pattern = #"<key>(TeamIdentifier|ApplicationIdentifierPrefix|com\.apple\.developer\.team-identifier)</key>\s*(<array>\s*)?<string>[A-Z0-9]{10}(?![A-Z0-9])</string>"#
        let home = FileManager.default.homeDirectoryForCurrentUser
        for dir in provisioningProfileDirs {
            let dirURL = home.appendingPathComponent(dir)
            guard let names = try? FileManager.default
                .contentsOfDirectory(atPath: dirURL.path) else { continue }
            for name in names
            where name.hasSuffix(".provisionprofile") || name.hasSuffix(".mobileprovision") {
                guard let bytes = try? Data(contentsOf: dirURL.appendingPathComponent(name)),
                      let blob = String(data: bytes, encoding: .isoLatin1) else { continue }
                if blob.range(of: pattern, options: .regularExpression) != nil { return true }
            }
        }
        return false
    }

    /// True when the keychain holds an Apple certificate that carries a team id.
    /// Development certs are the ones the build asks for, but Developer ID and
    /// App Store certs count too: the build runs `xcodebuild
    /// -allowProvisioningUpdates`, so the team id is the only thing missing and
    /// Xcode mints the development certificate itself. Apple puts the same team
    /// id in every cert's subject OU, and a Developer ID cert is the only Apple
    /// certificate on the machine of anyone who has shipped a notarized app and
    /// nothing else — those users can team-sign, so don't warn them.
    private static func teamInKeychain() -> Bool {
        guard let identities = shellOutput("/usr/bin/security",
                                           ["find-identity", "-v", "-p", "codesigning"]) else {
            return false
        }
        // Lines look like:  1) <sha1> "Apple Development: me@example.com (XXXXXXXXXX)"
        return identities.range(
            of: #""(Apple Development|Mac Developer|Apple Distribution|iPhone Developer|Developer ID Application|3rd Party Mac Developer Application):"#,
            options: .regularExpression) != nil
    }

    /// True when an Apple ID is registered in Xcode's Accounts pane. Xcode writes
    /// this list as soon as the account is added, well before it has a team or a
    /// certificate, so it separates "never signed in" from "signed in but Xcode
    /// hasn't issued a signing certificate yet" — two states that need opposite
    /// instructions.
    static func xcodeAccountPresent() -> Bool {
        guard let out = shellOutput("/usr/bin/defaults",
                                    ["read", "com.apple.dt.Xcode",
                                     "DVTDeveloperAccountManagerAppleIDLists"]) else {
            return false
        }
        return out.range(of: #"identifier\s*="#, options: .regularExpression) != nil
    }

    /// Run a tool and return stdout, or nil if it fails to launch or exits non-zero.
    private static func shellOutput(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        // Read before waiting: a full pipe buffer would deadlock the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Honest, per-state guidance for the Xcode gate. Each case names exactly
    /// what's wrong and what the button will do, so a user who already has Xcode
    /// never hits the same dead-end "install Xcode" text again.
    static func xcodeMessage(for status: CLIRunner.XcodeStatus) -> String {
        switch status {
        case .ready:
            return ""
        case .notInstalled:
            return "Converting to a Safari extension needs Apple's full Xcode, and only Apple can hand that out, so Viaduct can't bundle it. It's free on the App Store, though it's a big download. Once it's there, Viaduct picks it up on its own."
        case .notSelected:
            return "Xcode is installed, but macOS is still pointed at the Command Line Tools, so the Safari packager can't be found. Viaduct can point macOS at Xcode for you; you'll be asked for your password."
        case .setupIncomplete:
            return "Xcode hasn't finished its first-launch setup, so nothing can build yet. Viaduct can accept the license and install the missing components. You'll be asked for your password, and it takes a few minutes."
        case .installIncomplete:
            return "macOS is pointed at Xcode, but this copy doesn't include the Safari extension packager, so the install is incomplete or damaged. Reinstalling Xcode should sort it out."
        }
    }

    /// Open Xcode's App Store page so the user can install it in one click.
    func openXcodeInstall() {
        // Apple\u{2019}s Xcode App Store product page.
        if let url = URL(string: "macappstore://apps.apple.com/app/xcode/id497799835") {
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
        // Signing into Xcode and switching back should be enough. Resume the
        // parked conversion the same way the Xcode gate's one-click fixes do.
        if needsAppleAccount, Self.xcodeTeamPresent() {
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
        lastExitCode = nil
        extInfo = nil
        needsXcode = false
        needsAppleAccount = false
        options.inputPath = ""
        options.appName = ""
    }

    private func runCLI(args: [String], label: String, userMode: Bool = false) {
        if let err = preflight(args: args) {
            statusMessage = err
            appendLog("✗ \(err)")
            if userMode { failureSummary = err; phase = .failed }
            return
        }
        // Freemium gate at the choke point: every conversion path lands here,
        // so an unlicensed user can't bypass the quota via Developer mode.
        // Analyze/doctor runs aren't conversions and stay free.
        if label == "Conversion", !LicenseManager.shared.canConvert {
            showPaywall = true
            statusMessage = "Free conversions used. Activate a license to continue."
            appendLog("✗ Free conversion limit reached.")
            if userMode { phase = .idle }
            return
        }
        isRunning = true
        lastExitCode = nil
        lastCLIError = nil
        statusMessage = "\(label) running…"
        appendLog("$ viaduct \(args.joined(separator: " "))")
        do {
            try runner.run(args: args, onLine: { [weak self] line in
                guard let self else { return }
                let clean = self.appendLog(line)
                // Keep the CLI's own reason for failing. User mode hides the log, so
                // without this every failure reads as the same generic sentence — which
                // is how a specific, actionable message like "the extension is ad-hoc"
                // ends up invisible to the person who needs it.
                if let reason = Self.errorReason(in: clean) { self.lastCLIError = reason }
                if userMode { self.advancePhase(from: clean) }
            }, onExit: { [weak self] code in
                guard let self else { return }
                self.isRunning = false
                self.lastExitCode = code
                self.statusMessage = code == 0
                    ? "\(label) finished."
                    : "\(label) failed (exit \(code))."
                self.appendLog(code == 0 ? "✓ Done." : "✗ Exit \(code).")
                if code == 0, label == "Conversion" { self.recordConversion() }
                if userMode { self.finishUserPhase(code: code) }
                // Pick up an update the check had to skip while this run held
                // the CLI. Swapping now is safe: nothing is executing it.
                if self.updatePendingAfterRun {
                    self.updatePendingAfterRun = false
                    Task { await self.applyUpdate() }
                }
            })
        } catch {
            isRunning = false
            statusMessage = error.localizedDescription
            appendLog("✗ \(error.localizedDescription)")
            if userMode { failureSummary = error.localizedDescription; phase = .failed }
        }
    }

    /// Move `phase` forward (never backward) based on a CLI line; capture install path.
    private func advancePhase(from line: String) {
        if let installed = installedPath(from: line) { installedAppPath = installed }
        if let next = ConvertPhase.detect(from: line), next.rawValue > phase.rawValue {
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
            // CLI is done, but let the bar race the last stretch to 100% first.
            // `completeFinishing()` (fired by the progress bar at 100%) flips to
            // .done and opens the freshly-converted extension app.
            phase = .finishing
        } else {
            failureSummary = lastCLIError
                ?? "The conversion stopped partway through. Copy the log or switch to Developer mode to see what failed."
            phase = .failed
            Feedback.failure()
        }
    }

    /// Called by the progress bar once it reaches 100% during `.finishing`.
    /// Marks the flow done. The user opens the converted extension manually via
    /// the "Open extension" button — we no longer launch it automatically.
    func completeFinishing() {
        guard phase == .finishing else { return }
        phase = .done
        Feedback.success()
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

    private func preflight(args: [String]) -> String? {
        // Doctor/analyze only need input for analyze.
        if args.contains("--analyze") || args == ConvertOptions.doctorArgs() {
            if args.contains("--analyze"), options.inputPath.isEmpty {
                return "Choose an input first."
            }
            return nil
        }
        return options.validationError()
    }

    func cancel() {
        runner.cancel()
        appendLog("⚠︎ Cancelled.")
        statusMessage = "Cancelled."
        isRunning = false
    }

    // MARK: - Update

    /// Check the registry and, if a newer CLI exists, install it immediately —
    /// no "Update Now" click. Skips if a conversion is mid-flight (don't swap the
    /// CLI out from under a running process).
    func checkForUpdates() {
        guard !updateChecking else { return }
        updateChecking = true
        Task {
            defer { updateChecking = false }
            do {
                let available = try await updater.updateAvailable()
                updateAvailable = available
                guard available else { statusMessage = "CLI is up to date."; return }
                guard !isRunning else {
                    updatePendingAfterRun = true
                    statusMessage = "CLI update queued (runs after this conversion)."
                    return
                }
                await applyUpdate()
            } catch {
                statusMessage = "Update check failed: \(error.localizedDescription)"
            }
        }
    }

    /// Download + swap the latest CLI. Shared by auto-update and the manual button.
    private func applyUpdate() async {
        statusMessage = "Updating CLI…"
        appendLog("→ Auto-updating CLI…")
        do {
            try await updater.update(rawLog: { [weak self] line in self?.appendLog(line) })
            installedVersion = updater.installedVersion ?? "unknown"
            updateAvailable = false
            statusMessage = "CLI updated to \(installedVersion)."
        } catch {
            statusMessage = "Update failed: \(error.localizedDescription)"
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
    }

    func pickInput() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a .zip, .crx, or unpacked extension folder."
        if panel.runModal() == .OK, let url = panel.url {
            selectInput(path: url.path)
        }
    }

    func pickOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Choose an output directory."
        if panel.runModal() == .OK, let url = panel.url {
            options.outputDir = url.path
        }
    }

    func pickInstallDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Choose an install directory."
        if panel.runModal() == .OK, let url = panel.url {
            options.installDir = url.path
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
