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

    private var dropCard: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
        return ZStack {
            Color.clear.liquidGlass(radius: Theme.Radius.xl)

            cardContent
                .padding(Theme.Space.xl)
        }
        .frame(height: 230)
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

    // Empty: invite to drop / browse. The icon gently floats + the glyph nudges
    // down on a slow loop so the first-run screen feels inviting, not inert.
    private var emptyCard: some View {
        VStack(spacing: Theme.Space.md) {
            ArchDropGlyph(active: isTargeted)

            VStack(spacing: Theme.Space.xxs) {
                Text(isTargeted ? "Release to add" : "Drop extension here")
                    .font(Theme.Font.headingSM())
                    .foregroundStyle(Theme.Colors.ink)
                Text("or click to browse  ·  .zip, .crx, or folder")
                    .tracked()
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.Colors.mute)
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
                } else if let version = info.version, !version.isEmpty {
                    Text("Version \(version)")
                        .font(Theme.Font.caption())
                        .foregroundStyle(Theme.Colors.mute)
                }
            }
            .transition(.scale(scale: 0.92).combined(with: .opacity))
        }
    }

    // Converting / finishing: live phase glyph + title + subtitle + step dots
    // + glass progress bar. Each phase visibly advances the glyph and dots so
    // the wait reads as motion, not a frozen spinner.
    private var convertingCard: some View {
        VStack(spacing: Theme.Space.md) {
            PhaseGlyph(phase: vm.phase)

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

            StepDots(phase: vm.phase)

            GlassProgressBar(fraction: vm.phase.fraction,
                             finishing: vm.phase.isFinishing,
                             onComplete: { vm.completeFinishing() },
                             onCancel: { vm.cancel(); vm.resetUserFlow() })
                .frame(width: 220)
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
                .lineLimit(3)
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
            case .notSelected:     return "macOS isn't pointed at Xcode yet"
            case .setupIncomplete: return "Xcode setup isn't finished"
            default:               return "Xcode is required to sign extensions"
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
                Text("Convert & Install")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.raycastPrimary)
            .disabled(vm.inspecting)

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
                        Label("Point macOS at Xcode", systemImage: "wrench.and.screwdriver")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.raycastPrimary)
                    Button("Install a different Xcode") { vm.openXcodeInstall() }
                        .buttonStyle(.raycastGhost)
                case .setupIncomplete:
                    Button {
                        Feedback.haptic(.generic)
                        vm.finishXcodeSetup()
                    } label: {
                        Label("Finish Xcode setup", systemImage: "wrench.and.screwdriver")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.raycastPrimary)
                    Button("Open Xcode") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Xcode.app"))
                    }
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
                    Button("I installed it — try again") { vm.recheckXcode() }
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
            // Converting: cancel lives on the progress bar (hover + click).
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
                    Spacer()
                    Button("Clear") { history.clear() }
                        .buttonStyle(.raycastGhost)
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

/// The animated phase glyph at the top of the converting card. Shows the
/// current phase's SF Symbol inside a glass tile, with a soft pulsing glow ring
/// and a symbol-swap transition between phases so each step visibly advances.
struct PhaseGlyph: View {
    let phase: ConvertPhase
    @State private var pulse = false

    var body: some View {
        ZStack {
            // Breathing glow behind the tile — slow, subtle, never distracting.
            Circle()
                .fill(Theme.Colors.accentGreen.opacity(0.18))
                .frame(width: 64, height: 64)
                .blur(radius: 12)
                .scaleEffect(pulse ? 1.15 : 0.9)
                .opacity(pulse ? 0.9 : 0.5)

            Color.clear
                .liquidGlass(radius: Theme.Radius.lg)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .strokeBorder(Theme.Colors.hairline, lineWidth: 1))
                .frame(width: 60, height: 60)

            glyph
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Theme.Colors.ink)
                .symbolRenderingMode(.hierarchical)
                .id("glyph\(phase.rawValue)")
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
        .frame(width: 64, height: 64)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    @ViewBuilder
    private var glyph: some View {
        let image = Image(systemName: phase.symbol)
        if #available(macOS 14.0, *) {
            // Gentle continuous motion on the active glyph (pulses the symbol).
            image.symbolEffect(.pulse, options: .repeating)
        } else {
            image
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

/// A row of step dots — one per track phase — that fill as the conversion
/// advances. Gives the wait a sense of journey beyond the progress bar.
struct StepDots: View {
    let phase: ConvertPhase

    private var currentIndex: Int {
        ConvertPhase.track.firstIndex(of: phase)
            ?? (phase.fraction >= 1 ? ConvertPhase.track.count : 0)
    }

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            ForEach(Array(ConvertPhase.track.enumerated()), id: \.offset) { idx, _ in
                let done = idx < currentIndex
                let active = idx == currentIndex
                Capsule()
                    .fill(done || active
                          ? AnyShapeStyle(Theme.Colors.accentGreen)
                          : AnyShapeStyle(Theme.Colors.stone))
                    .frame(width: active ? 16 : 6, height: 6)
                    .overlay(active ? Capsule().fill(.white.opacity(0.25))
                        .frame(width: 16, height: 6) : nil)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: currentIndex)
    }
}
