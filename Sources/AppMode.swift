import Foundation

enum AppMode: String, CaseIterable, Identifiable {
    case user, developer
    var id: String { rawValue }
    var label: String {
        switch self {
        case .user: return "User"
        case .developer: return "Developer"
        }
    }
    var blurb: String {
        switch self {
        case .user: return "Drop an extension, get it in Safari."
        case .developer: return "Every CLI flag, the signing options, and the live build log."
        }
    }
}

/// High-level phases the user-mode UI animates through, derived by parsing CLI output.
enum ConvertPhase: Int, CaseIterable, Identifiable {
    case idle, extracting, reading, staging, packaging, building, installing, finishing, done, failed

    var id: Int { rawValue }

    /// Phases that make up the running progress track (excludes idle/done/failed).
    static var track: [ConvertPhase] { [.extracting, .reading, .staging, .packaging, .building, .installing] }

    /// True while the progress bar is racing the last stretch to 100% after the
    /// CLI has already exited successfully.
    var isFinishing: Bool { self == .finishing }

    var title: String {
        switch self {
        case .idle:       return "Ready"
        case .extracting: return "Unpacking extension"
        case .reading:    return "Reading manifest"
        case .staging:    return "Preparing assets"
        case .packaging:  return "Generating Safari project"
        case .building:   return "Building & signing"
        case .installing: return "Installing to Safari"
        case .finishing:  return "Finishing up"
        case .done:       return "Installed"
        case .failed:     return "Conversion failed"
        }
    }

    var subtitle: String {
        switch self {
        case .idle:       return ""
        case .extracting: return "Opening the package"
        case .reading:    return "Checking what Safari supports"
        case .staging:    return "Patching Chrome APIs for Safari"
        case .packaging:  return "Building the Xcode project"
        case .building:   return "The slow step. A minute or two is normal"
        case .installing: return "Registering with Safari"
        case .finishing:  return "Almost there"
        case .done:       return "Turn it on in Safari → Settings → Extensions"
        case .failed:     return "Switch to Developer mode for the full log"
        }
    }

    var symbol: String {
        switch self {
        case .idle:       return "sparkles"
        case .extracting: return "shippingbox"
        case .reading:    return "doc.text.magnifyingglass"
        case .staging:    return "wand.and.stars"
        case .packaging:  return "hammer"
        case .building:   return "gearshape.2"
        case .installing: return "arrow.down.app"
        case .finishing:  return "sparkles"
        case .done:       return "checkmark.seal.fill"
        case .failed:     return "exclamationmark.triangle.fill"
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
    static func detect(from line: String) -> ConvertPhase? {
        if line.contains("Extracting ") { return .extracting }
        if line.contains("Loaded \"") { return .reading }
        if line.contains("Staging clean") { return .staging }
        if line.contains("safari-web-extension-packager") { return .packaging }
        if line.contains("Building (") { return .building }
        if line.contains("Installed →") || line.contains("Installed:") { return .installing }
        return nil
    }
}
