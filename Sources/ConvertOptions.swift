import Foundation

enum Platforms: String, CaseIterable, Identifiable {
    case macos, ios, all
    var id: String { rawValue }
    var label: String {
        switch self {
        case .macos: return "macOS"
        case .ios: return "iOS"
        case .all: return "macOS + iOS"
        }
    }
}

enum SigningMode: String, CaseIterable, Identifiable {
    case adhoc, autoTeam, customTeam
    var id: String { rawValue }
    var label: String {
        switch self {
        case .adhoc: return "Ad-hoc (unsigned)"
        case .autoTeam: return "Auto-detect Team"
        case .customTeam: return "Custom Team ID"
        }
    }
}

/// Mirrors the viaduct CLI flags.
struct ConvertOptions {
    var inputPath: String = ""
    var outputDir: String = ""
    var bundleId: String = ""
    var appName: String = ""
    var minSafari: String = ""           // --min-safari <ver>
    var platforms: Platforms = .macos

    var ci: Bool = false                 // --ci (clean-copy resources)
    var tempLoad: Bool = false           // --temp-load
    var zip: Bool = false                // --zip (distributable .zip)
    var clean: Bool = false              // --clean (wipe output first)
    var noBuild: Bool = false            // --no-build
    var openXcode: Bool = false          // --open-xcode
    var install: Bool = false            // --install
    var installDir: String = ""          // --install-dir
    var noSafariRestart: Bool = false    // --no-safari-restart

    var signing: SigningMode = .adhoc
    var customTeamId: String = ""        // --team <id>

    var noShim: Bool = false             // --no-shim
    var noOAuthBridge: Bool = false      // --no-oauth-bridge
    var keepModule: Bool = false         // --keep-module
    var force: Bool = false              // --force
    var strict: Bool = false             // --strict
    var verbose: Bool = false            // --verbose

    /// Build argv (excluding the leading cli.js path) for a normal conversion.
    func conversionArgs() -> [String] {
        var args: [String] = []
        args.append(inputPath)

        if !outputDir.isEmpty { args += ["--output", outputDir] }
        if !bundleId.isEmpty { args += ["--bundle-id", bundleId] }
        if !appName.isEmpty { args += ["--app-name", appName] }
        if !minSafari.isEmpty { args += ["--min-safari", minSafari] }
        args += ["--platforms", platforms.rawValue]

        if ci { args.append("--ci") }
        if tempLoad { args.append("--temp-load") }
        if zip { args.append("--zip") }
        if clean { args.append("--clean") }
        if noBuild { args.append("--no-build") }
        if openXcode { args.append("--open-xcode") }
        if install { args.append("--install") }
        if !installDir.isEmpty { args += ["--install-dir", installDir] }
        if noSafariRestart { args.append("--no-safari-restart") }

        switch signing {
        case .adhoc: break
        case .autoTeam: args += ["--team", "auto"]
        case .customTeam:
            if !customTeamId.isEmpty { args += ["--team", customTeamId] }
        }

        if noShim { args.append("--no-shim") }
        if noOAuthBridge { args.append("--no-oauth-bridge") }
        if keepModule { args.append("--keep-module") }
        if force { args.append("--force") }
        if strict { args.append("--strict") }
        if verbose { args.append("--verbose") }
        return args
    }

    /// Sign with a named Apple team, or let the CLI detect one when there is
    /// nothing to name. Naming it is what stops a Mac with two accounts from
    /// signing with whichever team Xcode cached first.
    mutating func useTeam(_ id: String?) {
        guard let id, !id.isEmpty else {
            signing = .autoTeam
            return
        }
        signing = .customTeam
        customTeamId = id
    }

    func analyzeArgs(json: Bool = false) -> [String] {
        var args = [inputPath, "--analyze"]
        if json { args.append("--json") }
        return args
    }
    static func doctorArgs() -> [String] { ["--doctor"] }
    func uninstallArgs(name: String) -> [String] { ["--uninstall", name] }

    /// Validation message, or nil if OK to run a conversion.
    func validationError() -> String? {
        if inputPath.isEmpty { return "Choose an input (.zip, .crx, or extension folder)." }
        if !FileManager.default.fileExists(atPath: inputPath) {
            return "Input path does not exist: \(inputPath)"
        }
        if install && (noBuild || tempLoad) {
            return "Install requires a build. Turn off “No build” and “Temp load”."
        }
        if signing == .customTeam && customTeamId.isEmpty {
            return "Enter a Team ID or pick a different signing mode."
        }
        return nil
    }
}
