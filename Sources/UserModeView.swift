import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Clean, card-centric User surface: one glass drop-zone card holds the whole
/// flow — drop/browse, then the extension's icon + name, then live phase text
/// while converting. A single morphing CTA below drives convert → open Safari.
/// No arrow, no aurora; flat near-black canvas, Raycast glass.
struct UserModeView: View {
    @ObservedObject var vm: ConverterViewModel
    @ObservedObject private var license = LicenseManager.shared

    @State private var isTargeted = false
    @State private var copiedLog = false

    /// The store-button popup: shown once, the first time Safari reports the
    /// bundled extension off. `seen` persists so it never nags twice.
    @AppStorage("storeButtonPromptSeen") private var storePromptSeen = false
    @State private var showStorePrompt = false

    /// Show the recent list only on the calm idle/done screens, never mid-convert.
    private var showsHistory: Bool {
        vm.phase == .idle || vm.phase == .done
    }

    var body: some View {
        ZStack {
            AmbientBackground()

            VStack(spacing: Theme.Space.lg) {
                Spacer(minLength: Theme.Space.xl)
                header
                dropCard
                ctaBlock
                freeUsesBadge
                if showsHistory {
                    RecentConversions(history: vm.history, vm: vm)
                        .frame(maxHeight: 200)
                }
                Spacer(minLength: Theme.Space.lg)
            }
            .frame(maxWidth: 440)
            .frame(maxHeight: .infinity)
            .padding(.horizontal, Theme.Space.xl)
            .padding(.vertical, Theme.Space.xl)
        }
        .frame(minWidth: 540, minHeight: 600)
        .onAppear {
            // Offer the store button once. Heartbeat state is synchronous, so
            // this can't race the launch hook.
            if !storePromptSeen, !StoreButton.isEnabled, vm.phase == .idle {
                showStorePrompt = true
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted.animation(.easeInOut(duration: 0.15)),
                perform: handleDrop)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: vm.phase)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: vm.options.inputPath)
        .onChange(of: vm.phase) { phase in
            copiedLog = false
            // A conversion started (drop, store install): the popup would sit
            // over the converting card, so it steps aside. Not marked seen —
            // it may offer again next launch.
            if phase != .idle { showStorePrompt = false }
        }
        // The heartbeat arrived (user flipped the switch in Safari): the
        // popup's job is done, close it under them.
        .onChange(of: vm.storeButtonEnabled) { enabled in
            if enabled == true { showStorePrompt = false }
        }
        .sheet(isPresented: $showStorePrompt) {
            StoreButtonPrompt {
                storePromptSeen = true
                showStorePrompt = false
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        BrandLockup(subtitle: "Run Chrome extensions in Safari.")
    }

    // MARK: - Free-uses badge

    /// Tells free-plan users how many free conversions remain, so the paywall
    /// isn't a surprise. Hidden for anyone whose license covers Safari, and mid-convert.
    @ViewBuilder
    private var freeUsesBadge: some View {
        if !license.unlimited(.safari) && showsHistory {
            let left = license.freeConversionsRemaining
            Text(left > 0
                 ? "\(left) free conversion\(left == 1 ? "" : "s") left"
                 : "No free conversions left. Activate a license to keep going.")
                .font(Theme.Font.caption())
                .foregroundStyle(left > 0 ? Theme.Colors.mute : Theme.Colors.accentBlue)
                .transition(.opacity)
        }
    }

    // MARK: - Drop card (centerpiece)

    /// Taller while converting: the orbit stage needs more room than the
    /// idle/done cards. Animated by the phase spring on the outer VStack.
    private var dropCardHeight: CGFloat {
        switch vm.phase {
        case .idle, .done, .failed: return 230
        default: return 300
        }
    }

    private var dropCard: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
        // Glass is applied to the sized frame (not a ZStack sibling), so the
        // pane and its border can never disagree with the card's real bounds.
        return ZStack {
            cardContent
                .padding(Theme.Space.xl)
        }
        .frame(maxWidth: .infinity)
        .frame(height: dropCardHeight)
        .liquidGlass(radius: Theme.Radius.xl)
        .overlay(
            shape.strokeBorder(
                isTargeted ? Theme.Colors.primary : Theme.Colors.hairlineStrong,
                style: StrokeStyle(lineWidth: isTargeted ? 2 : 1,
                                   dash: vm.options.inputPath.isEmpty ? [6, 5] : []))
        )
        .overlay(            // soft aqua glow swells under the cursor while dragging
            shape.fill(Theme.Colors.accentBlue.opacity(isTargeted ? 0.10 : 0))
                .blur(radius: 8))
        .scaleEffect(isTargeted ? 1.02 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isTargeted)
        .contentShape(shape)
        .onTapGesture {
            if vm.phase == .idle || vm.phase == .done || vm.phase == .failed {
                reselect()
            }
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        if vm.cliInstalling {
            preparingCard
        } else {
            switch vm.phase {
            case .idle where vm.options.inputPath.isEmpty:
                emptyCard
            case .failed:
                failedCard
            case .idle, .done:
                readyOrDoneCard
            default:
                convertingCard
            }
        }
    }

    // First launch: the converter engine isn't inside the app, it comes from npm.
    // One short wait, said out loud instead of hidden behind a button that looks
    // like it did nothing.
    private var preparingCard: some View {
        VStack(spacing: Theme.Space.md) {
            ProgressView().controlSize(.small)
            VStack(spacing: Theme.Space.xxs) {
                Text("Getting Viaduct ready")
                    .font(Theme.Font.headingSM())
                    .foregroundStyle(Theme.Colors.ink)
                Text("Downloading the converter engine. This happens once.")
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.Colors.mute)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // Empty: invite to drop / browse. The icon gently floats + the glyph nudges
    // down on a slow loop so the first-run screen feels inviting, not inert.
    private var emptyCard: some View {
        VStack(spacing: Theme.Space.md) {
            ArchDropGlyph(active: isTargeted)

            VStack(spacing: Theme.Space.xxs) {
                Text(isTargeted ? "Release to add" : "Drop extension here")
                    .font(Theme.Font.headingSM())
                    .foregroundStyle(Theme.Colors.ink)
            }
        }
    }

    // Picked (ready) or finished (done): icon + name + sublabel.
    @ViewBuilder
    private var readyOrDoneCard: some View {
        if vm.inspecting {
            VStack(spacing: Theme.Space.md) {
                ProgressView().controlSize(.small)
                Text("Reading extension…")
                    .font(Theme.Font.body()).foregroundStyle(Theme.Colors.mute)
            }
        } else if let info = vm.extInfo {
            VStack(spacing: Theme.Space.md) {
                ExtensionIcon(image: info.icon)
                Text(displayName(info))
                    .font(Theme.Font.headingMD())
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1).truncationMode(.middle)
                if vm.phase == .done {
                    DoneBadge()
                    // A run can succeed and still come out ad-hoc: the CLI
                    // rebuilds that way when the team it found can't sign.
                    // Safari then refuses the extension outright until the
                    // unsigned toggle is on, so this can't stay in the log.
                    if vm.lastBuildAdHoc {
                        Text("This build has no Apple signature. Safari only loads it while Allow Unsigned Extensions is on in the Develop menu, and forgets that setting every time it quits.")
                            .font(Theme.Font.caption())
                            .foregroundStyle(Theme.Colors.accentYellow)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if let verdict = vm.compatibility {
                    CompatibilityNotice(verdict: verdict)
                } else {
                    if let version = info.version, !version.isEmpty {
                        Text("Version \(version)")
                            .font(Theme.Font.caption())
                            .foregroundStyle(Theme.Colors.mute)
                    }
                    OfficialVersionBanner(path: vm.options.inputPath, storeId: vm.pendingStoreId)
                }
            }
            .transition(.scale(scale: 0.92).combined(with: .opacity))
        }
    }

    // Converting / finishing: the extension's icon center stage, absorbing its
    // orbiting parts (manifest, scripts, images, styles, pages, build) one per
    // phase — over live phase text.
    private var convertingCard: some View {
        VStack(spacing: Theme.Space.sm) {
            ConversionOrbit(phase: vm.phase,
                            icon: vm.extInfo?.icon,
                            finishing: vm.phase.isFinishing,
                            onComplete: { vm.completeFinishing() })

            VStack(spacing: 2) {
                Text(vm.phase.title)
                    .font(Theme.Font.headingSM())
                    .foregroundStyle(Theme.Colors.ink)
                    .id("title\(vm.phase.rawValue)")
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)))
                Text(vm.phase.subtitle)
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.Colors.mute)
                    .id("sub\(vm.phase.rawValue)")
                    .transition(.opacity)
            }

            Button("Cancel") { vm.cancel(); vm.resetUserFlow() }
                .buttonStyle(.raycastGhost)
                .disabled(vm.phase.isFinishing)
                .opacity(vm.phase.isFinishing ? 0.4 : 1)
        }
    }

    // Failed: red mark + which step broke + summary + a "Copy log" affordance.
    // Recovery actions (Try again / Report) live in the CTA block below.
    private var failedCard: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(Theme.Colors.accentRed)
            Text(failedHeadline)
                .font(Theme.Font.headingSM())
                .foregroundStyle(Theme.Colors.ink)
                .multilineTextAlignment(.center)
            Text(vm.failureSummary ?? vm.phase.subtitle)
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.Colors.mute)
                .multilineTextAlignment(.center)
                // Room for the gate's explanation plus whatever Xcode itself
                // printed when a one-click fix didn't take; the untruncated text
                // is still in the log behind "Copy log".
                .lineLimit(6)
            if !vm.logLines.isEmpty {
                Button {
                    vm.copyLog()
                    copiedLog = true
                } label: {
                    Label(copiedLog ? "Copied" : "Copy log",
                          systemImage: copiedLog ? "checkmark" : "doc.on.doc")
                        .font(Theme.Font.caption())
                }
                .buttonStyle(.raycastGhost)
            }
        }
    }

    /// Name the step that failed, pulled from how far `phase` advanced before
    /// the CLI bailed. Falls back to a generic headline.
    private var failedHeadline: String {
        if let verdict = vm.compatibility { return verdict.title }
        if vm.needsXcode {
            switch vm.xcodeStatus {
            case .notSelected:       return "macOS isn't pointed at Xcode yet"
            case .setupIncomplete:   return "Xcode setup isn't finished"
            case .installIncomplete: return "This Xcode install is incomplete"
            default:                 return "Xcode is required to sign extensions"
            }
        }
        if let last = vm.lastReachedTrackPhase {
            return "Failed while \(last.title.lowercased())"
        }
        return "Conversion failed"
    }

    // MARK: - CTA block (single morphing action)

    @ViewBuilder
    private var ctaBlock: some View {
        switch vm.phase {
        case .idle where vm.options.inputPath.isEmpty:
            Button("Choose extension") { vm.pickInput(allowBatch: true) }
                .buttonStyle(.raycastPrimary)
                .frame(maxWidth: .infinity)

        // Nothing to retry and nothing to set up: the extension itself is the
        // problem, so the way forward is a different one.
        case .idle where vm.compatibility != nil, .failed where vm.compatibility != nil:
            VStack(spacing: Theme.Space.sm) {
                Button {
                    vm.resetUserFlow()
                    vm.pickInput(allowBatch: true)
                } label: {
                    Text("Choose another extension")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.raycastPrimary)
                Button("Think this is wrong? Report it") { NSWorkspace.shared.open(failureReportURL) }
                    .buttonStyle(.raycastTertiary)
            }

        case .idle:
            Button { vm.userConvert() } label: {
                Text(vm.cliInstalling ? "Getting ready…" : "Convert & Install")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.raycastPrimary)
            .disabled(vm.inspecting || vm.cliInstalling)

        case .done:
            VStack(spacing: Theme.Space.sm) {
                Button {
                    Feedback.haptic(.generic)
                    vm.openConvertedApp()
                } label: {
                    Text("Open extension")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.raycastPrimary)
                Button("Convert another") { vm.resetUserFlow() }
                    .buttonStyle(.raycastGhost)
            }

        case .failed where vm.needsXcode:
            // The honest Xcode gate — but the primary action now matches the
            // actual problem, so "installed but still blocked" isn't a dead end.
            VStack(spacing: Theme.Space.sm) {
                switch vm.xcodeStatus {
                case .notSelected:
                    Button {
                        Feedback.haptic(.generic)
                        vm.fixXcodeSelection()
                    } label: {
                        fixLabel("Point macOS at Xcode", busy: "Pointing macOS at Xcode")
                    }
                    .buttonStyle(.raycastPrimary)
                    .disabled(vm.xcodeFixing)
                    Button("Install a different Xcode") { vm.openXcodeInstall() }
                        .buttonStyle(.raycastGhost)
                        .disabled(vm.xcodeFixing)
                case let .setupIncomplete(dev):
                    Button {
                        Feedback.haptic(.generic)
                        vm.finishXcodeSetup()
                    } label: {
                        fixLabel("Finish Xcode setup", busy: "Finishing setup, this takes a few minutes")
                    }
                    .buttonStyle(.raycastPrimary)
                    .disabled(vm.xcodeFixing)
                    Button("Open Xcode") { openXcode(developerDir: dev) }
                        .buttonStyle(.raycastGhost)
                        .disabled(vm.xcodeFixing)
                case .installIncomplete:
                    // Nothing xcodebuild can do puts a missing packager back, so
                    // the only action offered here is the one that can.
                    Button {
                        Feedback.haptic(.generic)
                        vm.openXcodeInstall()
                    } label: {
                        Label("Reinstall Xcode", systemImage: "arrow.down.app")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.raycastPrimary)
                    Button("Check again") { vm.recheckXcode() }
                        .buttonStyle(.raycastGhost)
                default:
                    Button {
                        Feedback.haptic(.generic)
                        vm.openXcodeInstall()
                    } label: {
                        Label("Install Xcode (free)", systemImage: "arrow.down.app")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.raycastPrimary)
                    // The App Store is a dead end on a prerelease macOS: it only
                    // offers the released Xcode, which won't launch there. Apple's
                    // developer downloads carry the matching beta.
                    Button("Get Xcode from Apple instead") { vm.openXcodeDeveloperDownloads() }
                        .buttonStyle(.raycastGhost)
                    Button("I installed it, try again") { vm.recheckXcode() }
                        .buttonStyle(.raycastTertiary)
                }
            }

        case .failed:
            VStack(spacing: Theme.Space.sm) {
                Button { vm.resetUserFlow() } label: {
                    Text("Try again")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.raycastPrimary)
                Button("Report this issue") { NSWorkspace.shared.open(failureReportURL) }
                .buttonStyle(.raycastTertiary)
                .frame(maxWidth: .infinity)
            }

        default:
            // Converting: the Cancel button lives inside the converting card.
            EmptyView()
        }
    }

    // MARK: - Helpers

    /// Tapping the card (any time, including mid-conversion) cancels,
    /// resets, and reopens the picker to switch extensions.
    private func reselect() {
        if vm.isRunning { vm.cancel() }
        vm.resetUserFlow()
        vm.pickInput(allowBatch: true)
    }

    /// Label for a one-click Xcode fix. `-runFirstLaunch` installs packages and
    /// can run for minutes, so the button has to keep saying something while it
    /// works instead of looking dead.
    @ViewBuilder
    private func fixLabel(_ title: String, busy: String) -> some View {
        HStack(spacing: 6) {
            if vm.xcodeFixing {
                ProgressView().controlSize(.small)
                Text(busy)
            } else {
                Image(systemName: "wrench.and.screwdriver")
                Text(title)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Open the Xcode that macOS is actually pointed at, which is not always the
    /// one in /Applications.
    private func openXcode(developerDir: String) {
        let app = URL(fileURLWithPath: developerDir)      // …/Xcode.app/Contents/Developer
            .deletingLastPathComponent()                  // …/Xcode.app/Contents
            .deletingLastPathComponent()                  // …/Xcode.app
        let target = app.pathExtension == "app"
            ? app
            : CLIRunner.installedXcodeApp()
        guard let target else { return }
        NSWorkspace.shared.open(target)
    }

    private func displayName(_ info: ExtensionInfo) -> String {
        if info.name.hasPrefix("__MSG_") {
            return URL(fileURLWithPath: vm.options.inputPath)
                .deletingPathExtension().lastPathComponent
        }
        return info.name
    }

    /// The CLI's failure form, filled in when that's switched on.
    private var failureReportURL: URL {
        let name = vm.extInfo.map(displayName)
            ?? URL(fileURLWithPath: vm.options.inputPath).deletingPathExtension().lastPathComponent
        // A verdict from the check alone has no log; the analyzer's findings
        // are what someone needs to tell whether it was right.
        let log = vm.phase == .failed ? vm.logLines : (vm.compatibility?.details ?? vm.logLines)
        return IssueReport.conversionFailure(
            extensionName: name, version: vm.extInfo?.version,
            storeId: vm.pendingStoreId ?? ExtensionIdentity.chromeId(forSource: vm.options.inputPath),
            summary: vm.compatibility?.title ?? vm.failureSummary, log: log, cliVersion: vm.installedVersion)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard vm.phase == .idle || vm.phase == .done || vm.phase == .failed else { return false }
        guard !providers.isEmpty else { return false }
        if providers.count > 1 {
            BatchConvert.loadURLs(from: providers) { urls in
                if vm.phase != .idle { vm.resetUserFlow() }
                BatchConvert.start(urls, vm: vm)
            }
            return true
        }
        _ = providers[0].loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async {
                if vm.phase != .idle { vm.resetUserFlow() }
                vm.selectInput(path: url.path)
            }
        }
        return true
    }
}

/// A quiet "Recently converted" list under the idle CTA, styled as Raycast
/// command-palette rows: app-icon tile + name + date, with a reveal-in-Finder
/// affordance per row. Collapses entirely when there's no history so the
/// first-run screen stays clean.
struct RecentConversions: View {
    @ObservedObject var history: ConversionHistory
    var vm: ConverterViewModel
    @State private var selected: ConversionRecord?

    var body: some View {
        if !history.records.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack {
                    Text("Recently converted")
                        .font(Theme.Font.caption())
                        .foregroundStyle(Theme.Colors.mute)
                }

                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(history.records.prefix(5)) { row($0) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
            .sheet(item: $selected) { rec in
                // A removal that ends late must not close another record's sheet.
                HistoryDetailSheet(record: rec, vm: vm, history: history) {
                    if selected?.id == rec.id { selected = nil }
                }
            }
        }
    }

    private func row(_ rec: ConversionRecord) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
        return HStack(spacing: Theme.Space.sm) {
            HistoryIcon(iconData: rec.iconData,
                        monogram: rec.name.first.map(String.init)?.uppercased() ?? "?")
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 0) {
                Text(rec.name)
                    .font(Theme.Font.body())
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1).truncationMode(.middle)
                Text(rec.date.formatted(date: .abbreviated, time: .shortened))
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.Colors.stone)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.Colors.primary)
        }
        .padding(.horizontal, Theme.Space.sm)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .fill(hovered == rec.id ? Theme.Colors.surfaceElevated : .clear))
        .contentShape(shape)
        .onHover { hovered = $0 ? rec.id : (hovered == rec.id ? nil : hovered) }
        .onTapGesture { selected = rec }
    }

    @State private var hovered: UUID?
}

/// Detail sheet for one past conversion: big icon + name + when, the source
/// path, and the three things you'd actually want — re-open in Safari, convert
/// it again, reveal in Finder — plus a destructive remove.
struct HistoryDetailSheet: View {
    let record: ConversionRecord
    let vm: ConverterViewModel
    @ObservedObject var history: ConversionHistory
    let dismiss: () -> Void
    /// Remove is waiting on the uninstall, which for Firefox takes a moment.
    @State private var removing = false
    @State private var removalFailure: RemovalFailure?

    private var sourceExists: Bool {
        FileManager.default.fileExists(atPath: record.sourcePath)
    }

    var body: some View {
        VStack(spacing: Theme.Space.lg) {
            VStack(spacing: Theme.Space.sm) {
                ExtensionIcon(image: record.iconData.flatMap(NSImage.init(data:)))
                    .glowRing(Theme.Colors.accentBlue, diameter: 80)
                Text(record.name)
                    .font(Theme.Font.headingMD())
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1).truncationMode(.middle)
                Text("Converted \(record.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.Colors.mute)
            }

            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.primary)
                Text(record.sourcePath)
                    .font(Theme.Font.caption())
                    .foregroundStyle(sourceExists ? Theme.Colors.body : Theme.Colors.accentRed)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.clear.liquidGlass(radius: Theme.Radius.sm))

            VStack(spacing: Theme.Space.sm) {
                if record.installedPath != nil {
                    Button {
                        if let p = record.installedPath { vm.reveal(path: p) }
                        dismiss()
                    } label: {
                        Label("Reveal in Finder", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.raycastPrimary)
                }
                Button {
                    vm.reconvert(record)
                    dismiss()
                } label: {
                    Label("Convert again", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.raycastTertiary)
                // Converting it again while it's being removed would lose the source.
                .disabled(!sourceExists || removing)
                .help(sourceExists ? "" : "The original file has moved or been deleted")

                HStack {
                    Button {
                        remove()
                    } label: {
                        HStack(spacing: 6) {
                            if removing { ProgressView().controlSize(.small) }
                            Text("Remove")
                        }
                    }
                    .buttonStyle(.raycastGhost)
                    .disabled(removing)
                    Button("Report a Problem") {
                        NSWorkspace.shared.open(IssueReport.convertedButBroken(
                            extensionName: record.name, version: record.version, storeId: record.storeId))
                    }
                    .buttonStyle(.raycastGhost)
                    .help("It installed but doesn't work right in Safari")
                    Spacer()
                    Button("Close") { dismiss() }
                        .buttonStyle(.raycastGhost)
                        .keyboardShortcut(.cancelAction)
                        // The removal's outcome, a failure or the Restart Firefox
                        // offer, shows in this sheet, so it stays up until then.
                        .disabled(removing)
                }
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 340)
        .background(AmbientBackground())
        .interactiveDismissDisabled(removing)
        .removalFailureAlert($removalFailure) { _ in remove(restartingFirefox: true) }
    }

    private func remove(restartingFirefox: Bool = false) {
        removing = true
        Task {
            do {
                try await history.remove(record, restartFirefox: restartingFirefox)
                dismiss()
            } catch {
                removalFailure = RemovalFailure(record: record, error: error)
            }
            removing = false
        }
    }
}

/// A Remove that didn't go through, as its alert shows it.
struct RemovalFailure {
    let record: ConversionRecord
    /// Firefox has the add-on's profile open and only lets go of it by
    /// restarting, which waits for the user to agree.
    let needsFirefoxRestart: Bool
    let message: String

    init(record: ConversionRecord, error: Error) {
        self.record = record
        needsFirefoxRestart = (error as? PersistError)?.needsFirefoxRestart ?? false
        // Persist's message for this names a profile path and a command-line
        // flag, so the alert shows the restart notice instead.
        message = needsFirefoxRestart ? "Firefox will restart once. Your tabs come back." : error.localizedDescription
    }

    var title: String { "Couldn't remove \(record.name)" }
}

extension View {
    /// The alert for a Remove that didn't go through. When Firefox has to
    /// restart to let the add-on go, it offers Restart Firefox, and `restart`
    /// tries again with the restart allowed.
    func removalFailureAlert(_ failure: Binding<RemovalFailure?>,
                             restart: @escaping (ConversionRecord) -> Void) -> some View {
        alert(failure.wrappedValue?.title ?? "",
              isPresented: Binding(get: { failure.wrappedValue != nil },
                                   set: { if !$0 { failure.wrappedValue = nil } }),
              presenting: failure.wrappedValue) { shown in
            if shown.needsFirefoxRestart {
                Button("Restart Firefox") { restart(shown.record) }
                Button("Not Now", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { shown in
            Text(shown.message)
        }
    }
}

/// Small history-row tile showing the extension's own icon. Falls back to a
/// monogram of the name when an icon wasn't captured (e.g. older records or
/// extensions with no manifest icon).
struct HistoryIcon: View {
    let iconData: Data?
    var monogram: String = "?"

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous)
        Group {
            if let data = iconData, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable().interpolation(.high)
                    .scaledToFit()
                    .padding(3)
            } else {
                Text(monogram)
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.Colors.body)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear.liquidGlass(radius: Theme.Radius.xs))
        .clipShape(shape)
    }
}

/// Rounded-glass icon tile. Shows the extension icon, or — in `placeholder`
/// mode — a dashed "select an extension" slot.
struct ExtensionIcon: View {
    var image: NSImage?
    var placeholder: Bool = false

    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.clear
                .liquidGlass(radius: 16)
                .overlay(border)

            if let image {
                Image(nsImage: image)
                    .resizable().interpolation(.high)
                    .scaledToFit()
                    .padding(8)
            } else {
                Image(systemName: placeholder ? "plus" : "puzzlepiece.extension.fill")
                    .font(.system(size: placeholder ? 24 : 26,
                                  weight: placeholder ? .semibold : .regular))
                    .foregroundStyle(placeholder ? AnyShapeStyle(Theme.Colors.mute)
                                                 : AnyShapeStyle(Theme.Colors.primary))
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .frame(width: 60, height: 60)
        .scaleEffect(hovering && placeholder ? 1.06 : 1)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.22, dampingFraction: 0.75), value: hovering)
    }

    @ViewBuilder
    private var border: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        if placeholder {
            shape.strokeBorder(
                (hovering ? Theme.Colors.primary : Theme.Colors.hairlineStrong),
                style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        } else {
            shape.strokeBorder(Theme.Colors.hairline, lineWidth: 1)
        }
    }
}

/// The success label for a finished conversion. Solid green pill + white text so
/// it stays legible on the neutral glass card in both light and dark themes.
struct DoneBadge: View {
    var body: some View {
        Label("Installed in Safari", systemImage: "checkmark.circle.fill")
            .font(Theme.Font.caption())
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Space.sm).padding(.vertical, 3)
            .background(Capsule().fill(Theme.Colors.accentGreen))
    }
}

/// One-time popup pointing at the app's second install path: the bundled
/// Safari extension that puts an Add to Safari button on Chrome Web Store
/// pages. Safari ships it off and nothing else in the app says it exists.
struct StoreButtonPrompt: View {
    /// Called on any explicit dismissal, so the popup never shows again.
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Theme.Colors.canvas.ignoresSafeArea()


            VStack(spacing: Theme.Space.lg) {
                Image(systemName: "safari")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(Theme.Colors.primary)
                    .padding(.bottom, Theme.Space.xs)

                Text("Install straight from the Chrome Web Store")
                    .font(Theme.Font.headingMD())
                    .foregroundStyle(Theme.Colors.ink)
                    .multilineTextAlignment(.center)

                Text("Viaduct adds an Add to Safari button to Chrome Web Store pages. Turn it on once in Safari, and extensions install with one click.")
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.Colors.mute)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)

                Button {
                    StoreButton.openSafariSettings()
                } label: {
                    Text("Turn On in Safari")
                        .frame(maxWidth: 360)
                }
                .buttonStyle(.raycastPrimary)

                Button("Not Now", action: dismiss)
                    .buttonStyle(.raycastGhost)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(Theme.Space.xxl)
        }
        .frame(width: 460)
    }
}


