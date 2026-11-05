import Foundation

/// The CLI flags a conversion passes. Every conversion builds, signs and
/// installs, so only what differs between runs lives here.
struct ConvertOptions {
    var inputPath: String = ""
    var appName: String = ""
    /// Apple team id to sign with, or "auto" to let the CLI detect one.
    var team: String = "auto"
    var force: Bool = false              // --force
    /// Which browser the conversion is for. `conversionArgs()` only builds
    /// Safari's; Firefox's come from `FirefoxConversion.convertArgs`.
    var browser: Browser = .safari

    /// Build argv (excluding the leading cli.js path) for a conversion.
    func conversionArgs() -> [String] {
        var args = [inputPath, "--install", "--team", team]
        if !appName.isEmpty { args += ["--app-name", appName] }
        if force { args.append("--force") }
        return args
    }

    /// Sign with a named Apple team, or let the CLI detect one when there is
    /// nothing to name. Naming it is what stops a Mac with two accounts from
    /// signing with whichever team Xcode cached first.
    mutating func useTeam(_ id: String?) {
        if let id, !id.isEmpty { team = id } else { team = "auto" }
    }

    /// Validation message, or nil if OK to run a conversion.
    func validationError() -> String? {
        if inputPath.isEmpty { return "Choose an input (.zip, .crx, or extension folder)." }
        if !FileManager.default.fileExists(atPath: inputPath) {
            return "Input path does not exist: \(inputPath)"
        }
        return nil
    }
}
