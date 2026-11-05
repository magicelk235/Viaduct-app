import Foundation

/// A browser Viaduct converts extensions for. The raw values are stored in
/// conversion history and in viaduct:// links, so they never change.
enum Browser: String, Codable, CaseIterable, Identifiable {
    case safari
    case firefox

    var id: Self { self }

    var displayName: String {
        switch self {
        case .safari: return "Safari"
        case .firefox: return "Firefox"
        }
    }
}
