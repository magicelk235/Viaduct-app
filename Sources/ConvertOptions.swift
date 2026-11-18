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

    /// Sign with the best team this Mac has. The id is named only when the app
    /// overrides the CLI's own pick: on a Mac holding a personal team and a paid
    /// one, the CLI left alone takes whichever Xcode cached first. Every other
    /// time it's "auto" — the CLI lands on the same team, and an auto-detected
    /// team that turns out unable to sign (no Xcode account, a revoked
    /// certificate) is rebuilt ad-hoc instead of failing the run. A named team
    /// gets no such fallback (aqueduct 1.18.3, Viaduct-CLI issue #19).
    mutating func useTeam(from teams: [SigningAccount.Team]) {
        if let chosen = SigningAccount.signingTeam(from: teams), chosen != teams.first {
            team = chosen.id
        } else {
            team = "auto"
        }
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
