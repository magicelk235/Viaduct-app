import Foundation

/// Where a Firefox conversion writes its output and how the engine is called.
enum FirefoxConversion {
    /// The first engine release that understands `--browser firefox`.
    static let minimumEngine = "2.0.0"

    /// ~/Library/Caches/Viaduct/firefox
    static var cachesRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Viaduct/firefox", isDirectory: true)
    }

    /// One folder per extension name, made safe to use as a single path component.
    static func outputDir(appName: String, root: URL = cachesRoot) -> URL {
        let cleaned = appName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "extension" : cleaned
        return root.appendingPathComponent(folder, isDirectory: true)
    }

    static func convertArgs(input: String, outputDir: URL) -> [String] {
        [input, "--browser", "firefox", "-o", outputDir.path, "--native-hosts", "--force"]
    }

    /// The converted extension, or nil when the run didn't leave a manifest behind.
    static func stagedExtension(in outputDir: URL) -> URL? {
        let staged = outputDir.appendingPathComponent("staged_extension", isDirectory: true)
        let manifest = staged.appendingPathComponent("manifest.json")
        return FileManager.default.fileExists(atPath: manifest.path) ? staged : nil
    }

    /// Clears a previous run's output so a stale manifest can't pass for a new one.
    static func clearOutput(_ outputDir: URL) {
        try? FileManager.default.removeItem(at: outputDir)
    }

    /// What a run does with the compatibility check before converting.
    /// Firefox always converts with --force, so the check is the only thing
    /// that stops an extension Firefox won't load.
    enum CheckStep: Equatable {
        /// The check found mistakes Firefox won't accept.
        case stop(CompatibilityVerdict)
        case convert
        /// No answer that counts yet, mostly because the engine can't analyze
        /// for Firefox until the run updates it. The check runs after
        /// converting, before anything goes into Firefox.
        case convertThenCheck
    }

    /// `checked` is whether the check gave an answer that counts: no verdict
    /// from an engine that couldn't analyze for Firefox proves nothing.
    static func checkStep(verdict: CompatibilityVerdict?, checked: Bool) -> CheckStep {
        if let verdict { return .stop(verdict) }
        return checked ? .convert : .convertThenCheck
    }
}
