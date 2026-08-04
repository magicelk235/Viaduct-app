import SwiftUI

struct ContentView: View {
    @ObservedObject var vm: ConverterViewModel
    @Binding var mode: AppMode

    var body: some View {
        ZStack {
            Theme.Colors.canvas.ignoresSafeArea()

            HSplitView {
                formPane
                    .frame(minWidth: 400, idealWidth: 440)
                logPane
                    .frame(minWidth: 380)
            }
        }
        .toolbar { toolbarContent }
        .toolbarBackground(Theme.Colors.canvas, for: .windowToolbar)
    }

    // MARK: - Form

    private var formPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                section("Input & Output", systemImage: "tray.and.arrow.down") {
                    pathRow("Extension", text: $vm.options.inputPath, action: vm.pickInput,
                            placeholder: ".zip, .crx, or folder")
                    pathRow("Output dir", text: $vm.options.outputDir, action: vm.pickOutputDir,
                            placeholder: "default: ./<AppName>_Safari")
                    labeledField("App name", $vm.options.appName, placeholder: "extension name")
                    labeledField("Bundle ID", $vm.options.bundleId,
                                 placeholder: "com.viaduct.<app>")
                    labeledField("Min Safari", $vm.options.minSafari,
                                 placeholder: "15.4  (18.4 for world:MAIN)")
                    HStack {
                        Text("Platforms")
                            .font(Theme.Font.body())
                            .foregroundStyle(Theme.Colors.mute)
                            .frame(width: 96, alignment: .leading)
                        PillTabPicker(options: Platforms.allCases.map { $0 },
                                      label: { $0.label },
                                      selection: $vm.options.platforms)
                        Spacer(minLength: 0)
                    }
                }

                section("Build", systemImage: "hammer") {
                    glassToggle("Build Xcode project (off = generate only)",
                                isOn: Binding(get: { !vm.options.noBuild },
                                              set: { vm.options.noBuild = !$0 }))
                    glassToggle("Open Xcode when finished", isOn: $vm.options.openXcode)
                    glassToggle("Clean output directory first", isOn: $vm.options.clean)
                    glassToggle("Generate distributable .zip", isOn: $vm.options.zip)
                    glassToggle("CI mode (clean-copy resources, TestFlight-safe)", isOn: $vm.options.ci)
                    glassToggle("Temp-load only (Safari 18 “Add Temporary Extension…”)",
                                isOn: $vm.options.tempLoad)
                    glassToggle("Keep background.type:\"module\"", isOn: $vm.options.keepModule)
                    glassToggle("Skip compatibility shim", isOn: $vm.options.noShim)
                    glassToggle("Disable Safari OAuth bridge", isOn: $vm.options.noOAuthBridge)
                    glassToggle("Strict (treat warnings as blocking)", isOn: $vm.options.strict)
                    glassToggle("Force (convert despite blocking errors)", isOn: $vm.options.force)
                }

                section("Signing", systemImage: "signature") {
                    VStack(spacing: Theme.Space.xs) {
                        ForEach(SigningMode.allCases) { signingRow($0) }
                    }
                    if vm.options.signing == .customTeam {
                        labeledField("Team ID", $vm.options.customTeamId, placeholder: "ABCDE12345")
                    }
                }

                section("Install", systemImage: "arrow.down.app") {
                    glassToggle("Install to Applications + register with Safari",
                                isOn: $vm.options.install)
                    if vm.options.install {
                        pathRow("Install dir", text: $vm.options.installDir,
                                action: vm.pickInstallDir, placeholder: "~/Applications")
                        glassToggle("Don't quit/relaunch Safari", isOn: $vm.options.noSafariRestart)
                    }
                }

                section("Output detail", systemImage: "text.alignleft") {
                    glassToggle("Verbose", isOn: $vm.options.verbose)
                }
            }
            .padding(Theme.Space.xl)
        }
        .disabled(vm.isRunning)
        .background(Theme.Colors.canvas)
    }

    // MARK: - Log

    private var logPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "terminal")
                    .foregroundStyle(Theme.Colors.primary)
                Text("Output")
                    .heading()
                    .font(Theme.Font.headingSM())
                    .foregroundStyle(Theme.Colors.ink)
                Spacer()
                if let code = vm.lastExitCode {
                    statusPill(success: code == 0)
                }
                Button("Clear") { vm.clearLog() }
                    .buttonStyle(.raycastGhost)
                    .disabled(vm.logLines.isEmpty)
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.vertical, Theme.Space.md)

            Rectangle().fill(Theme.Colors.hairline).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    if vm.logLines.isEmpty {
                        logEmptyState
                    } else {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(vm.logLines.enumerated()), id: \.offset) { idx, line in
                                Text(line.isEmpty ? " " : line)
                                    .font(Theme.Font.mono())
                                    .foregroundStyle(logColor(line))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(idx)
                            }
                        }
                        .padding(Theme.Space.md)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.Colors.surface)
                .onChange(of: vm.logLines.count) { _ in
                    if let last = vm.logLines.indices.last {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
        }
        .background(Theme.Colors.canvas)
    }

    /// Intentional empty state for the log pane before the first run — Raycast
    /// never shows a blank void. Centered glyph + hint at what runs here.
    private var logEmptyState: some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: "terminal")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Theme.Colors.primary)
            Text("No output yet")
                .font(Theme.Font.body())
                .foregroundStyle(Theme.Colors.mute)
            Text("Run Convert, Analyze, or Doctor to see live progress.")
                .tracked()
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.Colors.ash)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 80)
    }

    private func statusPill(success: Bool) -> some View {
        // Solid color fill + white text: a same-color tint on translucent glass
        // washed out to green-on-white and read as invisible. A filled capsule
        // guarantees contrast in both light and dark.
        Label(success ? "Success" : "Failed",
              systemImage: success ? "checkmark.circle.fill" : "xmark.octagon.fill")
            .font(Theme.Font.caption())
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Space.sm).padding(.vertical, 3)
            .background(Capsule().fill(success ? Theme.Colors.accentGreen : Theme.Colors.accentRed))
    }

    private func logColor(_ line: String) -> Color {
        if line.hasPrefix("✗") || line.contains("error") || line.contains("Error") {
            return Theme.Colors.accentRed
        }
        if line.hasPrefix("✓") { return Theme.Colors.accentGreen }
        if line.hasPrefix("$") { return Theme.Colors.accentBlue }
        if line.hasPrefix("⚠") { return Theme.Colors.accentYellow }
        return Theme.Colors.body
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if vm.isRunning {
                Button(role: .cancel) { vm.cancel() } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
                .buttonStyle(.raycastTertiary)
            } else {
                Button { mode = .user } label: {
                    Label("User Mode", systemImage: "person.crop.circle")
                }
                .buttonStyle(.raycastGhost)
                .help("Switch to the simple User interface")

                Menu {
                    Button("CLI \(vm.installedVersion)") {}.disabled(true)
                    Divider()
                    Button("Check for Updates") { vm.checkForUpdates() }
                        .disabled(vm.updateChecking)
                    Button("Update Now") { vm.updateCLI() }
                        .disabled(vm.updateChecking || vm.isRunning)
                } label: {
                    if vm.updateChecking {
                        ProgressView().controlSize(.mini)
                    } else {
                        Label(vm.updateAvailable ? "Update available" : "CLI \(vm.installedVersion)",
                              systemImage: vm.updateAvailable
                                ? "arrow.down.circle.fill" : "shippingbox")
                    }
                }
                .buttonStyle(.raycastGhost)

                Button { vm.runDoctor() } label: {
                    Label("Doctor", systemImage: "stethoscope")
                }
                .buttonStyle(.raycastGhost)
                Button { vm.runAnalyze() } label: {
                    Label("Analyze", systemImage: "magnifyingglass")
                }
                .buttonStyle(.raycastGhost)
                Button { vm.runConversion() } label: {
                    Label("Convert", systemImage: "play.fill")
                }
                .buttonStyle(.raycastPrimary)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    // MARK: - Builders

    private func section<Content: View>(_ title: String, systemImage: String,
                                        @ViewBuilder _ content: @escaping () -> Content) -> some View {
        RaycastCard(glass: true) {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Colors.primary)
                    Text(title)
                        .heading()
                        .font(Theme.Font.headingSM())
                        .foregroundStyle(Theme.Colors.ink)
                }
                content()
            }
        }
    }

    /// A selectable signing option as a Raycast command-palette-row: radio glyph
    /// + label, the selected row lifts one surface notch onto glass.
    private func signingRow(_ mode: SigningMode) -> some View {
        let active = vm.options.signing == mode
        return HStack(spacing: Theme.Space.sm) {
            Image(systemName: active ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(active ? Theme.Colors.accentGreen : Theme.Colors.ash)
            Text(mode.label)
                .font(Theme.Font.body())
                .foregroundStyle(active ? Theme.Colors.ink : Theme.Colors.body)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.sm)
        .frame(height: 30)
        .background {
            if active {
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .fill(Theme.Colors.surfaceCard)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                vm.options.signing = mode
            }
        }
    }

    private func glassToggle(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(label, isOn: isOn)
            .toggleStyle(.glass)
    }

    private func labeledField(_ label: String, _ text: Binding<String>,
                              placeholder: String) -> some View {
        HStack {
            Text(label)
                .font(Theme.Font.body())
                .foregroundStyle(Theme.Colors.mute)
                .frame(width: 96, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.glass)
        }
    }

    private func pathRow(_ label: String, text: Binding<String>,
                         action: @escaping () -> Void, placeholder: String) -> some View {
        HStack {
            Text(label)
                .font(Theme.Font.body())
                .foregroundStyle(Theme.Colors.mute)
                .frame(width: 96, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.glass)
            Button("Choose…", action: action)
                .buttonStyle(.raycastTertiary)
        }
    }
}
