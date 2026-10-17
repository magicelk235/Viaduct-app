import Foundation

/// One error the CLI refuses to convert over, as its analyzer reports it.
struct BlockingError: Equatable {
    let category: String
    let message: String

    /// A content blocker built on blocking `webRequest`. The CLI refuses it,
    /// but it isn't broken: it installs and its element hiding still runs,
    /// only the request blocking does nothing. So it gets converted and gets
    /// no warning.
    var isContentBlocker: Bool { category == "content-blocker" }
}

/// The one thing the CLI's analyzer can say for certain: this extension won't
/// work in Safari. Warnings are left out on purpose. They're pattern matches
/// that can't tell a broken feature from a harmless one, and a list of them
/// reads as "this won't work" to someone deciding whether to spend a free
/// conversion.
struct CompatibilityVerdict: Equatable {
    /// The analyzer's own wording. Too technical for the card; it goes into the
    /// issue report so a wrong verdict can be checked.
    let details: [String]

    var title: String { "This extension won't work in Safari" }
    var message: String {
        "It has mistakes Safari won't accept, like a missing file. They're in the extension itself, so converting can't fix them."
    }

    /// Nil unless something other than the content-blocker case is in there.
    init?(blockingErrors: [BlockingError]) {
        let broken = blockingErrors.filter { !$0.isContentBlocker }
        guard !broken.isEmpty else { return nil }
        details = broken.map(\.message)
    }
}

enum CompatibilityCheck {
    /// Analyze `path` with the installed CLI. Nil when it passes, when the
    /// engine isn't installed yet, when the analyzer can't read the input (the
    /// conversion reports those itself), or when the task was cancelled.
    /// Cancelling also stops the analyzer if it has started.
    static func run(path: String) async -> CompatibilityVerdict? {
        let process = Process()
        let result = await withTaskCancellationHandler {
            await Task.detached(priority: .utility) { () -> CompatibilityVerdict? in
                guard let node = CLIRunner.resolveNode(),
                      let cli = CLIRunner.resolveCLIScript() else { return nil }
                process.executableURL = node
                process.arguments = [cli.path, path, "--analyze", "--json"]
                // Same working dir as a conversion, so the CLI finds its templates.
                process.currentDirectoryURL = cli.deletingLastPathComponent().deletingLastPathComponent()
                let out = Pipe()
                process.standardOutput = out
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return nil }
                // Drain before waiting: a report bigger than the pipe buffer
                // would otherwise block the analyzer forever.
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return Self.verdict(fromReport: data)
            }.value
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        return Task.isCancelled ? nil : result
    }

    /// Read `--analyze --json` output. The CLI exits 1 when it finds blocking
    /// errors, so the exit code says nothing the report doesn't.
    static func verdict(fromReport data: Data) -> CompatibilityVerdict? {
        struct Report: Decodable {
            struct Issue: Decodable {
                let severity: String
                let category: String
                let message: String
                let autoFixed: Bool?
            }
            let issues: [Issue]
        }
        guard let report = try? JSONDecoder().decode(Report.self, from: data) else { return nil }
        let blocking = report.issues
            .filter { $0.severity == "error" && $0.autoFixed != true }
            .map { BlockingError(category: $0.category, message: $0.message) }
        return CompatibilityVerdict(blockingErrors: blocking)
    }

    /// The same verdict, read back from a conversion's log when the CLI refused
    /// to convert. Covers runs that start before the check could finish: store
    /// installs, batches, a quick click on Convert.
    static func verdict(fromLog lines: [String]) -> CompatibilityVerdict? {
        refusal(inLog: lines).flatMap(CompatibilityVerdict.init(blockingErrors:))
    }

    /// The errors the latest run in `lines` was refused over, or nil when it
    /// wasn't refused. Needs the CLI's refusal line, not just an ERROR block:
    /// that block can hold auto-fixed errors that didn't stop anything.
    static func refusal(inLog lines: [String]) -> [BlockingError]? {
        let start = lines.lastIndex { $0.hasPrefix("$ viaduct") }.map { $0 + 1 } ?? 0
        let run = lines[start...]
        guard run.contains(where: { $0.contains("blocking error(s)") }) else { return nil }

        var blocking: [BlockingError] = []
        var inErrors = false
        var pending: String?    // category of a bullet whose message is the next line
        for line in run {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let category = pending {
                blocking.append(BlockingError(category: category, message: trimmed))
                pending = nil
                continue
            }
            if !line.hasPrefix(" ") {
                inErrors = trimmed.hasPrefix("ERROR (")
                continue
            }
            // "  • [icons] manifest.json", "  • [api] a.js:3 [auto-fixed]"
            guard inErrors, trimmed.hasPrefix("• ["), !trimmed.contains("[auto-fixed]"),
                  let close = trimmed.firstIndex(of: "]") else { continue }
            pending = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 3)..<close])
        }
        return blocking
    }
}
