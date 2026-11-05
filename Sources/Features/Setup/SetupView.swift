import SwiftUI
import AppKit

/// The first-launch setup screen: every step as a row in one glass card, the
/// current one open with its explanation, and the step's fix as the one
/// full-width primary underneath. Past the last step it becomes the welcome
/// screen.
struct SetupView: View {
    @ObservedObject var vm: ConverterViewModel
    @ObservedObject var flow: SetupFlow
    @ObservedObject private var license = LicenseManager.shared

    /// The step on screen and whether it's done, as last seen. A step that
    /// turns done while it's open moves setup on; picking a row that's
    /// already done doesn't.
    @State private var seen = Seen(step: .xcode, done: false)
    @StateObject private var keyEntry = KeyEntry()
    @FocusState private var keyFocused: Bool

    private var storeButtonOn: Bool { vm.storeButtonEnabled == true }
    private var current: Seen { Seen(step: flow.step, done: flow.isDone(flow.step)) }

    var body: some View {
        ZStack {
            AmbientBackground()
            Group {
                if flow.showingWelcome {
                    SetupWelcome(flow: flow, storeButtonOn: storeButtonOn)
                        .transition(.opacity)
                } else {
                    checklist
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: 440)
            .padding(Theme.Space.xl)
        }
        .frame(minWidth: 540, minHeight: 600)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: flow.step)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: current.done)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: flow.showingWelcome)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: flow.preparing)
        // Every fix happens in another app (App Store, Xcode, System Settings,
        // Safari), so coming back is when to look again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            flow.refresh()
        }
        .onChange(of: vm.xcodeFixing) { fixing in if !fixing { flow.refresh() } }
        .onAppear { seen = current }
        .onChange(of: current) { now in
            if now.done, !seen.done, now.step == seen.step, !flow.preparing { flow.stepCompleted() }
            seen = now
        }
    }

    // MARK: - Checklist

    private var checklist: some View {
        VStack(spacing: Theme.Space.lg) {
            Text("Set up Viaduct")
                .heading()
                .font(Theme.Font.headingMD())
                .foregroundStyle(Theme.Colors.ink)
            VStack(spacing: 0) {
                ForEach(flow.steps) { step in
                    if step != flow.steps.first {
                        Rectangle().fill(Theme.Colors.hairline).frame(height: 1)
                    }
                    row(step)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
            .background(Color.clear.liquidGlass(radius: Theme.Radius.xl))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
                .strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 1))
            VStack(spacing: Theme.Space.sm) {
                primary
                // Skipping is a real button under the primary, the same pair
                // the welcome screen ends on.
                if !flow.preparing, !flow.isDone(flow.step) {
                    Button { flow.next() } label: {
                        Text("Later").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.raycastTertiary)
                }
            }
        }
    }

    private func row(_ step: SetupFlow.Step) -> some View {
        let open = step == flow.step && !flow.preparing
        let done = flow.isDone(step)
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(alignment: .top, spacing: Theme.Space.md) {
                // The header is a real button so rows are reachable by
                // keyboard and VoiceOver.
                Button { flow.select(step) } label: {
                    HStack(alignment: .top, spacing: Theme.Space.md) {
                        StepGlyph(symbol: Self.symbol(step), open: open,
                                  waiting: !open && !done)
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            Text(title(step))
                                .font(open ? Theme.Font.bodyStrong() : Theme.Font.body())
                                .foregroundStyle(open || done ? Theme.Colors.ink : Theme.Colors.mute)
                            if open, let explanation = explanation(step) {
                                Text(explanation)
                                    .font(Theme.Font.body())
                                    .foregroundStyle(Theme.Colors.body)
                                    .lineSpacing(2)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .transition(.opacity)
                            }
                        }
                        .padding(.top, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(open ? .isSelected : [])
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white, Theme.Colors.accentGreen)
                        .padding(.top, 7)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                        .accessibilityLabel("Done")
                }
            }
            // Ready to type in as soon as setup reaches this step. It sits
            // outside the header button so it can take focus, and lines up
            // under the title.
            if open, step == .license, !done {
                keyField
                    .padding(.leading, 32 + Theme.Space.md)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.md)
        .background(open ? Theme.Colors.primary.opacity(0.06) : .clear)
    }

    // MARK: - License

    private var keyField: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            TextField("License key", text: $keyEntry.text)
                .textFieldStyle(.glass)
                .focused($keyFocused)
                .disabled(license.isAddingKey)
                .onSubmit(activate)
                .accessibilityLabel("License key")
                .onAppear { keyFocused = true }
            KeyErrorText(error: keyEntry.error)
        }
    }

    private func activate() {
        Task { await keyEntry.submit(to: license) }
    }

    // MARK: - Primary

    /// One full-width primary, the way User mode does it: the open step's fix
    /// until it's done, then Continue.
    @ViewBuilder
    private var primary: some View {
        if flow.preparing || checking {
            Button {} label: {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.raycastPrimary)
            .disabled(true)
        } else if flow.isDone(flow.step) {
            wide("Continue") { flow.next() }
                .keyboardShortcut(.defaultAction)
        } else {
            switch flow.step {
            case .xcode:
                xcodeAction
            case .appleAccount:
                wide("Open Xcode") { openXcode() }
                    .disabled(flow.xcode != .ready)
            case .diskAccess:
                if flow.blockedBrowsers == nil {
                    wide("Allow Access") { flow.checkDiskAccess() }
                } else {
                    wide("Open Full Disk Access") {
                        NSWorkspace.shared.open(BrowserProfiles.privacySettingsURL)
                    }
                }
            case .storeButton:
                wide("Turn On in Safari") { StoreButton.openSafariSettings() }
            case .license:
                if license.isAddingKey {
                    Button {} label: {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Activating")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.raycastPrimary)
                    .disabled(true)
                } else {
                    wide("Activate", action: activate)
                        .disabled(!keyEntry.hasText)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    @ViewBuilder
    private var xcodeAction: some View {
        switch flow.xcode {
        case let status? where status != .ready:
            switch status {
            case .notSelected:
                wide(vm.xcodeFixing ? "Switching" : "Point macOS at Xcode") {
                    vm.xcodeStatus = status
                    vm.fixXcodeSelection()
                }
                .disabled(vm.xcodeFixing)
            case .setupIncomplete:
                wide(vm.xcodeFixing ? "Finishing setup" : "Finish Xcode Setup") {
                    vm.xcodeStatus = status
                    vm.finishXcodeSetup()
                }
                .disabled(vm.xcodeFixing)
            case .installIncomplete:
                wide("Reinstall Xcode") { vm.openXcodeInstall() }
            default:
                wide("Get Xcode") { vm.openXcodeInstall() }
            }
        default:
            EmptyView()
        }
    }

    // MARK: - Copy

    /// Only the open step shows a spinner, and only before its first answer.
    private var checking: Bool {
        switch flow.step {
        case .xcode:        return flow.xcode == nil
        case .appleAccount: return flow.account == nil
        case .diskAccess:   return flow.checkingDiskAccess
        case .storeButton, .license: return false
        }
    }

    /// Says where things stand, not what the step is called: "Xcode is ready"
    /// once it is, never "Install Xcode" beside a done mark.
    private func title(_ step: SetupFlow.Step) -> String {
        switch step {
        case .xcode:
            switch flow.xcode {
            case .ready?:             return "Xcode is ready"
            case .notSelected?:       return "Point macOS at Xcode"
            case .setupIncomplete?:   return "Finish setting up Xcode"
            case .installIncomplete?: return "Xcode needs reinstalling"
            default:                  return "Install Xcode"
            }
        case .appleAccount:
            switch flow.account {
            case .signedIn?:         return "Signed in to Xcode"
            case .needsCertificate?: return "Make a signing certificate"
            default:                 return "Sign in to Xcode"
            }
        case .diskAccess:
            return flow.isDone(.diskAccess) ? "Viaduct can read your browsers" : "Let Viaduct read your browsers"
        case .storeButton:
            return storeButtonOn ? "Add to Safari is on" : "Add to Safari button"
        case .license:
            return license.unlimited(.safari) ? "Safari is unlimited" : "Activate a license"
        }
    }

    /// Nil when the title says enough, like Activate a license over its key field.
    private func explanation(_ step: SetupFlow.Step) -> String? {
        switch step {
        case .xcode:
            switch flow.xcode {
            case .ready?:
                return "Viaduct uses it to build and sign each extension."
            case .notSelected?:
                return "Xcode is installed, but macOS is still using the Command Line Tools. Viaduct can switch it over with your password."
            case .setupIncomplete?:
                return "Viaduct can accept the license and install what's missing. It takes a few minutes and asks for your password."
            case .installIncomplete?:
                return "This copy is missing the parts that build Safari extensions."
            default:
                return "Safari only runs extensions that Xcode has built and signed. It's free, and a big download, so you can carry on and come back to this."
            }
        case .appleAccount:
            if flow.xcode != .ready, flow.account != .signedIn {
                return "Once Xcode is installed, sign in with your Apple ID so Safari keeps extensions on after it quits."
            }
            switch flow.account {
            case .signedIn?:
                return "Your extensions stay on when Safari quits."
            case .needsCertificate?:
                return "In Xcode, open Settings, then Accounts. Pick your Apple ID, click Manage Certificates, then + and Apple Development."
            default:
                return "In Xcode, open Settings, then Accounts, and add your Apple ID. A free one works."
            }
        case .diskAccess:
            switch flow.blockedBrowsers {
            case nil:
                return "To list the extensions in Chrome and your other browsers, and bring their settings along. macOS will ask you once."
            case let blocked? where blocked.isEmpty:
                return "Your extensions and their settings can come over to Safari."
            case let blocked?:
                return "macOS is still keeping Viaduct out of \(ListFormatter.localizedString(byJoining: blocked.map(\.name))). Turn Viaduct on under Full Disk Access, then come back."
            }
        case .storeButton:
            return storeButtonOn
                ? "Chrome Web Store pages show the button."
                : "Puts a button on Chrome Web Store pages, so extensions install straight from the store."
        case .license:
            return license.unlimited(.safari)
                ? "No conversion limit, and your extensions stay on this Mac."
                : nil
        }
    }

    // MARK: - Helpers

    private func openXcode() {
        guard let app = CLIRunner.installedXcodeApp() else { return }
        NSWorkspace.shared.open(app)
    }

    static func symbol(_ step: SetupFlow.Step) -> String {
        switch step {
        case .xcode:        return "hammer.fill"
        case .appleAccount: return "person.crop.circle.fill"
        case .diskAccess:   return "lock.open.fill"
        case .storeButton:  return "safari.fill"
        case .license:      return "key.fill"
        }
    }

    struct Seen: Equatable {
        let step: SetupFlow.Step
        let done: Bool
    }
}

/// The full-width primary every User-mode CTA uses. The style sizes to its
/// label, so the label is what has to stretch.
private func wide(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(title).frame(maxWidth: .infinity)
    }
    .buttonStyle(.raycastPrimary)
}

/// A row's glyph: a small glass tile, teal-edged on the open row, dimmed on
/// rows still waiting their turn.
private struct StepGlyph: View {
    let symbol: String
    let open: Bool
    let waiting: Bool

    var body: some View {
        ZStack {
            Color.clear.liquidGlass(radius: Theme.Radius.md)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .strokeBorder(open ? Theme.Colors.primary.opacity(0.55) : Theme.Colors.hairline,
                                  lineWidth: 1))
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(waiting ? Theme.Colors.mute : Theme.Colors.primary)
                .symbolRenderingMode(.hierarchical)
        }
        .frame(width: 32, height: 32)
    }
}

/// The screen that ends setup: the arch mark, then the ways extensions get in
/// on this Mac, then Import from Chrome when there's anything to import.
private struct SetupWelcome: View {
    let flow: SetupFlow
    let storeButtonOn: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false

    private static let mark = Bundle.main.url(forResource: "icon", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }

    private struct Way: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    /// Only the ways that work here: the store button once it's on, the
    /// import once there's a browser to read.
    private var ways: [Way] {
        var ways = [Way(symbol: "tray.and.arrow.down.fill",
                        title: "Drop one on the window",
                        detail: "A .zip, .crx or an unpacked folder.")]
        if storeButtonOn {
            ways.append(Way(symbol: "safari.fill",
                            title: "Add to Safari on the Chrome Web Store",
                            detail: "The button sits on every extension's page."))
        }
        if flow.canImport {
            ways.append(Way(symbol: "square.and.arrow.down.on.square.fill",
                            title: "Import the ones already in Chrome",
                            detail: "Pick the ones you use."))
        }
        return ways
    }

    private var lead: String {
        switch ways.count {
        case 1:  return "Drop an extension on the window to start."
        case 2:  return "Extensions come in two ways."
        default: return "Extensions come in three ways."
        }
    }

    var body: some View {
        VStack(spacing: Theme.Space.lg) {
            if let mark = Self.mark {
                Image(nsImage: mark)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 88, height: 88)
                    .glowRing(Theme.Colors.primary, diameter: 120, opacity: 0.22)
                    .scaleEffect(settled ? 1 : 0.85)
                    .opacity(settled ? 1 : 0)
                    .accessibilityHidden(true)
                    .padding(.bottom, Theme.Space.xs)
            }
            VStack(spacing: Theme.Space.sm) {
                Text("Welcome to Viaduct")
                    .font(Theme.Font.displayLG())
                    .foregroundStyle(Theme.Colors.ink)
                Text(lead)
                    .font(Theme.Font.body())
                    .foregroundStyle(Theme.Colors.body)
            }
            if ways.count > 1 {
                VStack(spacing: 0) {
                    ForEach(ways) { way in
                        if way.id != ways.first?.id {
                            Rectangle().fill(Theme.Colors.hairline).frame(height: 1)
                        }
                        HStack(alignment: .top, spacing: Theme.Space.md) {
                            StepGlyph(symbol: way.symbol, open: false, waiting: false)
                            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                                Text(way.title)
                                    .font(Theme.Font.bodyStrong())
                                    .foregroundStyle(Theme.Colors.ink)
                                Text(way.detail)
                                    .font(Theme.Font.body())
                                    .foregroundStyle(Theme.Colors.body)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, Theme.Space.lg)
                        .padding(.vertical, Theme.Space.md)
                        .accessibilityElement(children: .combine)
                    }
                }
                .background(Color.clear.liquidGlass(radius: Theme.Radius.xl))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
                    .strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 1))
            }
            VStack(spacing: Theme.Space.sm) {
                if flow.canImport {
                    wide("Import from Chrome") { flow.finish(openImport: true) }
                        .keyboardShortcut(.defaultAction)
                    Button { flow.finish(openImport: false) } label: {
                        Text("Later").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.raycastTertiary)
                } else {
                    wide("Start using Viaduct") { flow.finish(openImport: false) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, Theme.Space.xs)
        }
        .onAppear {
            if reduceMotion {
                settled = true
            } else {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { settled = true }
            }
        }
    }
}
