import Foundation

/// Locates node + the bundled/updated viaduct CLI and runs it,
/// streaming combined stdout/stderr line-by-line.
final class CLIRunner {
    static let shared = CLIRunner()

    private var process: Process?

    var isRunning: Bool { process?.isRunning ?? false }

    // MARK: - Paths

    /// Where autoupdate writes the freshly-built CLI.
    static var supportCLIDir: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Viaduct", isDirectory: true)
            .appendingPathComponent("cli", isDirectory: true)
        return base
    }

    /// dist shipped inside the .app bundle.
    static var bundledCLIDir: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("cli", isDirectory: true)
    }

    /// Version marker written next to a CLI copy by the npm sync / autoupdate.
    static func cliVersion(at dir: URL) -> String? {
        guard let s = try? String(contentsOf: dir.appendingPathComponent("version.txt"),
                                  encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// The CLI copy to run: the npm-updated one in Application Support, unless the
    /// app bundle ships something newer. An app update can carry a CLI newer than
    /// whatever npm last handed us, and always preferring Application Support
    /// would keep running the older copy — which is how a machine keeps signing
    /// ad-hoc long after the fix shipped. A copy with no version marker counts as
    /// the oldest, so it only wins when nothing else is usable.
    static func resolveCLIDir() -> URL? {
        let usable = [supportCLIDir, bundledCLIDir].compactMap { $0 }.filter {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("dist/cli.js").path)
        }
        guard var best = usable.first else { return nil }
        for candidate in usable.dropFirst() {
            switch (cliVersion(at: best), cliVersion(at: candidate)) {
            case (nil, .some): best = candidate
            case let (.some(have), .some(other)) where CLIUpdater.semverLess(have, other):
                best = candidate
            default: break
            }
        }
        return best
    }

    /// Resolve cli.js inside whichever copy wins.
    static func resolveCLIScript() -> URL? {
        resolveCLIDir()?.appendingPathComponent("dist/cli.js")
    }

    /// The self-contained node shipped inside the .app (Resources/bin/node).
    /// Present in release builds; absent only if a dev build skipped fetch-node.sh.
    static var bundledNode: URL? {
        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("bin/node", isDirectory: false) else { return nil }
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Find a usable node binary. Prefers the node bundled inside the app so the
    /// user needs nothing installed; falls back to a system node only if the
    /// bundled one is missing (e.g. an unfetched dev build).
    static func resolveNode() -> URL? {
        if let bundled = bundledNode { return bundled }
        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        // Fall back to `which node` via a login shell (picks up nvm/fnm).
        if let path = whichViaShell("node") { return URL(fileURLWithPath: path) }
        return nil
    }

    static func resolveNpm() -> URL? {
        let candidates = ["/opt/homebrew/bin/npm", "/usr/local/bin/npm", "/usr/bin/npm"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        if let path = whichViaShell("npm") { return URL(fileURLWithPath: path) }
        return nil
    }

    // MARK: - Xcode availability

    /// Whether the build/sign pipeline can run. The hard requirement is a FULL
    /// Xcode install: `safari-web-extension-packager` and the `xcodebuild` signing
    /// of an App-Sandbox .appex ship only with Xcode, not the Command Line Tools.
    /// Apple gives us no lighter path — so we detect it and tell the user plainly
    /// rather than letting the conversion die deep inside xcodebuild.
    static func xcodeReady() -> Bool {
        // `xcrun --find` resolves against the active developer dir. With only CLT
        // selected (or no Xcode at all), the packager is not found → not ready.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["--find", "safari-web-extension-packager"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Why the build/sign pipeline can — or can't — run. This splits apart the
    /// two very different failure modes that `xcodeReady()` alone collapses into
    /// one: a genuinely missing Xcode, vs. an Xcode that IS installed but macOS
    /// still isn't pointed at. The second is the notorious "I installed Xcode and
    /// it STILL says install Xcode" trap — after an App Store install,
    /// `xcode-select` can stay on the Command Line Tools, so `xcrun --find` fails
    /// exactly as if Xcode weren't there. We detect that and fix it in one click.
    enum XcodeStatus: Equatable {
        case ready
        case notInstalled                       // no Xcode.app anywhere on disk
        case notSelected(developerDir: String)  // Xcode on disk, CLT/none active
        case setupIncomplete                    // selected, first-launch pending
    }

    static func xcodeStatus() -> XcodeStatus {
        if xcodeReady() { return .ready }
        guard let dev = installedXcodeDeveloperDir() else { return .notInstalled }
        if activeDeveloperDir() != dev { return .notSelected(developerDir: dev) }
        return .setupIncomplete
    }

    /// Active developer dir (`xcode-select -p`), or nil if unset.
    static func activeDeveloperDir() -> String? {
        let out = runCapturing("/usr/bin/xcode-select", ["-p"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (out?.isEmpty ?? true) ? nil : out
    }

    /// Developer dir of a full Xcode installed on disk (never the Command Line
    /// Tools), or nil if none is found. Prefers /Applications/Xcode.app, then
    /// asks Spotlight for any Xcode bundle wherever the user put it.
    static func installedXcodeDeveloperDir() -> String? {
        let standard = "/Applications/Xcode.app/Contents/Developer"
        if FileManager.default.fileExists(atPath: standard) { return standard }
        guard let hit = runCapturing("/usr/bin/mdfind",
                ["kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'"])?
            .split(separator: "\n").first.map(String.init) else { return nil }
        let dev = hit + "/Contents/Developer"
        return FileManager.default.fileExists(atPath: dev) ? dev : nil
    }

    /// Point the active developer dir at `developerDir` via `xcode-select -s`,
    /// shown to the user as the standard macOS admin-auth prompt. Returns true
    /// once the selection actually resolves the Safari packager.
    @discardableResult
    static func selectXcode(developerDir: String) -> Bool {
        _ = runAdmin("/usr/bin/xcode-select -s \(shellQuote(developerDir))")
        return xcodeReady()
    }

    /// Accept the Xcode license and run its first-launch component install —
    /// both need admin rights and otherwise block xcrun/xcodebuild.
    @discardableResult
    static func finishXcodeFirstLaunch() -> Bool {
        _ = runAdmin("/usr/bin/xcodebuild -license accept; /usr/bin/xcodebuild -runFirstLaunch")
        return xcodeReady()
    }

    /// Run a shell command with administrator privileges via the OS auth prompt.
    @discardableResult
    private static func runAdmin(_ command: String) -> Bool {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        var err: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&err)
        return result != nil && err == nil
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Run a tool and capture stdout, or nil if it can't be launched.
    private static func runCapturing(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    static func whichViaShell(_ tool: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v \(tool)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? nil : out
    }

    // MARK: - Run

    enum RunError: LocalizedError {
        case nodeNotFound
        case cliNotFound
        case alreadyRunning

        var errorDescription: String? {
            switch self {
            case .nodeNotFound:
                return "Node.js not found. Install Node 18+ (e.g. `brew install node`)."
            case .cliNotFound:
                return "Bundled CLI not found. Try “Update CLI”."
            case .alreadyRunning:
                return "A task is already running."
            }
        }
    }

    /// Run the CLI with the given args. `onLine` fires on the main queue per output line.
    /// `onExit` fires on the main queue with the exit code.
    func run(args: [String],
             onLine: @escaping (String) -> Void,
             onExit: @escaping (Int32) -> Void) throws {
        guard !isRunning else { throw RunError.alreadyRunning }
        guard let node = Self.resolveNode() else { throw RunError.nodeNotFound }
        guard let cli = Self.resolveCLIScript() else { throw RunError.cliNotFound }

        let p = Process()
        p.executableURL = node
        p.arguments = [cli.path] + args
        // Run from the CLI dir so relative template paths resolve.
        p.currentDirectoryURL = cli.deletingLastPathComponent().deletingLastPathComponent()

        // Ensure node/xcrun tooling is on PATH for child Xcode invocations.
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = extra + ":" + (env["PATH"] ?? "")
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        let handle = pipe.fileHandleForReading
        var buffer = Data()
        handle.readabilityHandler = { fh in
            let chunk = fh.availableData
            if chunk.isEmpty { return }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                let line = String(data: lineData, encoding: .utf8) ?? ""
                DispatchQueue.main.async { onLine(line) }
            }
        }

        p.terminationHandler = { proc in
            handle.readabilityHandler = nil
            // Flush any trailing partial line.
            if !buffer.isEmpty {
                let line = String(data: buffer, encoding: .utf8) ?? ""
                DispatchQueue.main.async { onLine(line) }
            }
            DispatchQueue.main.async {
                self.process = nil
                onExit(proc.terminationStatus)
            }
        }

        self.process = p
        try p.run()
    }

    func cancel() {
        process?.terminate()
    }
}
