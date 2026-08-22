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
    @Binding var mode: AppMode

    @State private var isTargeted = false
    @State private var copiedLog = false

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
        .onDrop(of: [.fileURL], isTargeted: $isTargeted.animation(.easeInOut(duration: 0.15)),
                perform: handleDrop)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: vm.phase)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: vm.options.inputPath)
        .onChange(of: vm.phase) { _ in copiedLog = false }
    }

    // MARK: - Header

    private var header: some View {
        BrandLockup(subtitle: "Run Chrome extensions in Safari.")
    }

    // MARK: - Free-uses badge

    /// Tells unlicensed users how many free conversions remain, so the paywall
    /// isn't a surprise. Hidden entirely for licensed users and mid-convert.
    @ViewBuilder
    private var freeUsesBadge: some View {
        if !license.isLicensed && showsHistory {
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
                        Text("This one is signed ad-hoc, so Safari only loads it while Allow Unsigned Extensions is on in the Develop menu. Safari forgets that every time it quits.")
                            .font(Theme.Font.caption())
                            .foregroundStyle(Theme.Colors.accentYellow)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if let version = info.version, !version.isEmpty {
                    Text("Version \(version)")
                        .font(Theme.Font.caption())
                        .foregroundStyle(Theme.Colors.mute)
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
    // Recovery actions (Try again / Developer mode) live in the CTA block below.
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
            Button("Choose extension") { vm.pickInput() }
                .buttonStyle(.raycastPrimary)
                .frame(maxWidth: .infinity)

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
                    Button("I installed it, try again") { vm.recheckXcode() }
                        .buttonStyle(.raycastGhost)
                }
            }

        case .failed:
            VStack(spacing: Theme.Space.sm) {
                HStack(spacing: Theme.Space.md) {
                    Button("Try again") { vm.resetUserFlow() }
                        .buttonStyle(.raycastTertiary)
                    Button("Developer mode") { mode = .developer }
                        .buttonStyle(.raycastPrimary)
                }
                Button("Report this issue") {
                    NSWorkspace.shared.open(URL(string:
                        "https://github.com/magicelk235/Viaduct-CLI/issues/new?template=conversion-failure.yml")!)
                }
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
        vm.pickInput()
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
            : URL(fileURLWithPath: "/Applications/Xcode.app")
        NSWorkspace.shared.open(target)
    }

    private func displayName(_ info: ExtensionInfo) -> String {
        if info.name.hasPrefix("__MSG_") {
            return URL(fileURLWithPath: vm.options.inputPath)
                .deletingPathExtension().lastPathComponent
        }
        return info.name
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard vm.phase == .idle || vm.phase == .done || vm.phase == .failed else { return false }
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
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
                HistoryDetailSheet(record: rec, vm: vm, history: history) { selected = nil }
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
                .disabled(!sourceExists)
                .help(sourceExists ? "" : "The original file has moved or been deleted")

                HStack {
                    Button("Remove") {
                        history.remove(record)
                        dismiss()
                    }
                    .buttonStyle(.raycastGhost)
                    Spacer()
                    Button("Close") { dismiss() }
                        .buttonStyle(.raycastGhost)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 340)
        .background(AmbientBackground())
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

