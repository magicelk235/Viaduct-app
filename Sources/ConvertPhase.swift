import Foundation

/// High-level phases the user-mode UI animates through, derived by parsing CLI output.
enum ConvertPhase: Int, CaseIterable, Identifiable {
    case idle, extracting, reading, staging, packaging, building, installing, finishing, done, failed

    var id: Int { rawValue }

    /// Phases that make up the running progress track (excludes idle/done/failed).
    static var track: [ConvertPhase] { [.extracting, .reading, .staging, .packaging, .building, .installing] }

    /// True while the progress bar is racing the last stretch to 100% after the
    /// CLI has already exited successfully.
    var isFinishing: Bool { self == .finishing }

    func title(for browser: Browser) -> String {
        switch (self, browser) {
        case (.idle, _):              return "Ready"
        case (.extracting, _):        return "Unpacking extension"
        case (.reading, .safari):     return "Reading manifest"
        case (.staging, .safari):     return "Preparing assets"
        case (.packaging, .safari):   return "Generating Safari project"
        case (.building, .safari):    return "Building & signing"
        case (.reading, .firefox), (.staging, .firefox),
             (.packaging, .firefox), (.building, .firefox):
            return "Converting for Firefox"
        case (.installing, .safari):  return "Installing to Safari"
        case (.installing, .firefox): return "Adding to Firefox"
        case (.finishing, _):         return "Finishing up"
        case (.done, _):              return "Installed"
        case (.failed, _):            return "Conversion failed"
        }
    }

    func subtitle(for browser: Browser) -> String {
        switch (self, browser) {
        case (.idle, _):              return ""
        case (.extracting, _):        return "Opening the package"
        case (.reading, .safari):     return "Checking what Safari supports"
        case (.staging, .safari):     return "Patching Chrome APIs for Safari"
        case (.packaging, .safari):   return "Building the Xcode project"
        case (.building, .safari):    return "The slow step. A minute or two is normal"
        case (.reading, .firefox), (.staging, .firefox),
             (.packaging, .firefox), (.building, .firefox):
            return "Patching Chrome APIs for Firefox"
        case (.installing, .safari):  return "Registering with Safari"
        case (.installing, .firefox): return "Firefox keeps it from now on"
        case (.finishing, _):         return "Almost there"
        case (.done, .safari):        return "Turn it on in Safari → Settings → Extensions"
        case (.done, .firefox):       return "It's on in Firefox"
        case (.failed, _):            return "Copy the log to see what went wrong"
        }
    }

    /// Fractional progress for the ring (0…1).
    var fraction: Double {
        switch self {
        case .idle:      return 0
        case .finishing: return 1
        case .done:      return 1
        case .failed:    return 1
        default:
            guard let idx = ConvertPhase.track.firstIndex(of: self) else { return 0 }
            return Double(idx + 1) / Double(ConvertPhase.track.count + 1)
        }
    }

    /// Detect a phase from a stripped CLI output line. nil = no transition.
    /// A Firefox run only prints unpacking and staging lines; the app moves it
    /// to installing itself when it hands the result to persist.
    static func detect(from line: String, browser: Browser) -> ConvertPhase? {
        switch browser {
        case .safari:
            if line.contains("Extracting ") { return .extracting }
            if line.contains("Loaded \"") { return .reading }
            if line.contains("Staging clean") { return .staging }
            if line.contains("safari-web-extension-packager") { return .packaging }
            if line.contains("Building (") { return .building }
            if line.contains("Installed →") || line.contains("Installed:") { return .installing }
        case .firefox:
            if line.contains("Extracting ") { return .extracting }
            if line.contains("Loaded \"") || line.contains("Staging clean") { return .staging }
        }
        return nil
    }
}
