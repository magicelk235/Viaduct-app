import Foundation

/// Locates node + the installed viaduct CLI and runs it,
/// streaming combined stdout/stderr line-by-line.
final class CLIRunner {
    static let shared = CLIRunner()

    private var process: Process?

    var isRunning: Bool { process?.isRunning ?? false }

    // MARK: - Paths

    /// Where the CLI lives. Nothing ships inside the .app: the first launch
    /// downloads the published npm package here and every later launch keeps it
    /// current, so a fresh install can never run an engine older than the day it
    /// was fetched (a checked-in copy silently rotted at 1.0.0 once and every
    /// first conversion signed ad-hoc because of it).
    static var cliDir: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Viaduct", isDirectory: true)
            .appendingPathComponent("cli", isDirectory: true)
    }

    /// Version marker `CLIUpdater` writes next to the installed copy.
    static var cliVersion: String? {
        guard let s = try? String(contentsOf: cliDir.appendingPathComponent("version.txt"),
                                  encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// cli.js, or nil while the engine hasn't been installed yet.
    static func resolveCLIScript() -> URL? {
        let script = cliDir.appendingPathComponent("dist/cli.js")
        return FileManager.default.fileExists(atPath: script.path) ? script : nil
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

    /// Whether the build/sign pipeline can run. Two things have to hold, and they
    /// break in completely different ways:
    ///   1. a FULL Xcode is selected, so `safari-web-extension-packager` and the
    ///      xcodebuild signing of an App-Sandbox .appex resolve at all — the
    ///      Command Line Tools ship neither and Apple offers no lighter path;
    ///   2. Xcode has finished its own first launch, or the components the build
    ///      needs were never installed.
    static func xcodeReady() -> Bool {
        packagerResolvable() && firstLaunchComplete()
    }

    /// Can `xcrun` resolve the Safari packager against the active developer dir?
    /// Note this is NOT a pure path lookup: `xcrun` runs `xcodebuild -license
    /// check` first and passes its status straight through, so an unaccepted
    /// license fails here (69) with exactly the same silence as a packager that
    /// genuinely isn't in the bundle (72). Telling those two apart is what
    /// `xcodeStatus()` is for.
    static func packagerResolvable() -> Bool {
        exitStatus("/usr/bin/xcrun", ["--find", "safari-web-extension-packager"]) == 0
    }

    /// Xcode's own first-launch gate: license agreed AND the bundled packages
    /// installed. `xcodebuild` answers it directly, and it covers the package
    /// half that `xcrun`'s license check does not.
    static func firstLaunchComplete() -> Bool {
        exitStatus("/usr/bin/xcodebuild", ["-checkFirstLaunchStatus"]) == 0
    }

    /// Why the build/sign pipeline can — or can't — run. This splits apart the
    /// failure modes `xcodeReady()` collapses into one, so the card we show
    /// always offers a fix that can actually change the answer: no Xcode at all;
    /// an Xcode that IS installed but macOS isn't pointed at (the notorious "I
    /// installed Xcode and it STILL says install Xcode" trap, since an App Store
    /// install can leave `xcode-select` on the Command Line Tools); an Xcode
    /// waiting on its first launch; and an Xcode that is set up yet still doesn't
    /// contain the packager.
    enum XcodeStatus: Equatable {
        case ready
        case notInstalled                            // no Xcode.app anywhere on disk
        case notSelected(developerDir: String)       // Xcode on disk, CLT/none active
        case setupIncomplete(developerDir: String)   // selected, first launch pending
        case installIncomplete(developerDir: String) // set up, packager still not there
    }

    static func xcodeStatus() -> XcodeStatus {
        if xcodeReady() { return .ready }
        guard let dev = installedXcodeDeveloperDir() else { return .notInstalled }
        if activeDeveloperDir() != dev { return .notSelected(developerDir: dev) }
        // Order matters. A pending first launch makes the packager lookup fail
        // too, so it has to be ruled out before blaming the install: telling
        // someone to reinstall Xcode when they only need to accept the license
        // is the kind of advice that costs them an afternoon.
        if !firstLaunchComplete() { return .setupIncomplete(developerDir: dev) }
        return .installIncomplete(developerDir: dev)
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

    /// What a one-click privileged fix did. `cancelled` stays apart from `failed`
    /// so dismissing the password prompt is never reported as a broken Xcode, and
    /// `failed` carries what the command printed — without it a fix that can't
    /// work is indistinguishable from one the user backed out of.
    enum FixOutcome: Equatable {
        case fixed
        case cancelled
        case failed(String)
    }

    /// Point the active developer dir at `developerDir` via `xcode-select -s`,
    /// shown to the user as the standard macOS admin-auth prompt.
    @discardableResult
    static func selectXcode(developerDir: String) -> FixOutcome {
        outcome(of: runAdmin("/usr/bin/xcode-select -s \(shellQuote(developerDir)) 2>&1"))
    }

    /// Accept the Xcode license and run its first-launch component install — both
    /// need admin rights and otherwise block every xcodebuild. On a fresh Xcode
    /// this installs packages and runs for minutes, so never call it on the main
    /// thread.
    @discardableResult
    static func finishXcodeFirstLaunch() -> FixOutcome {
        outcome(of: runAdmin("/usr/bin/xcodebuild -license accept 2>&1; /usr/bin/xcodebuild -runFirstLaunch 2>&1"))
    }

    /// Judge a fix by the state it left behind, not by the script's exit status —
    /// a command can complain and still have done the job.
    private static func outcome(of result: AdminResult) -> FixOutcome {
        if xcodeReady() { return .fixed }
        if result.cancelled { return .cancelled }
        return .failed(result.message)
    }

    private struct AdminResult {
        let cancelled: Bool
        /// Combined output, or the AppleScript error text — whatever there is to
        /// show the user when the fix didn't take.
        let message: String
    }

    /// Run a shell command as root behind the standard macOS auth prompt, keeping
    /// what it printed. The timeout is raised well past AppleScript's two-minute
    /// default because `-runFirstLaunch` routinely runs longer than that.
    private static func runAdmin(_ command: String) -> AdminResult {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        with timeout of 3600 seconds
            do shell script "\(escaped)" with administrator privileges
        end timeout
        """
        var err: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let err {
            let code = err[NSAppleScript.errorNumber] as? Int ?? 0
            let text = err[NSAppleScript.errorMessage] as? String ?? "Unknown error \(code)."
            // -128 is the user dismissing the auth prompt.
            return AdminResult(cancelled: code == -128, message: text)
        }
        return AdminResult(cancelled: false, message: result?.stringValue ?? "")
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Run a tool with its output discarded and report the exit status, or nil if
    /// it couldn't be launched at all.
    private static func exitStatus(_ path: String, _ args: [String]) -> Int32? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        return p.terminationStatus
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
                return "The converter engine isn't installed yet. Check your internet connection and try again."
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
