import Foundation

/// Why a key couldn't be added or checked. Only `.unreachable` leaves a
/// stored key alone; the rest mean a store looked at the key and said no.
enum LicenseError: LocalizedError, Equatable {
    /// A server said no, in its own words.
    case rejected(String)
    /// Polar's words. The UI adds a Manage Activations button.
    case activationLimitReached(String)
    case unknownKey
    case notForViaduct
    case alreadyAdded
    /// No answer, or one Viaduct can't read.
    case unreachable

    var errorDescription: String? {
        switch self {
        case .rejected(let message), .activationLimitReached(let message):
            return message
        case .unknownKey:
            return "That key wasn't found. Copy it again from your purchase email."
        case .notForViaduct:
            return "That key is for a different app."
        case .alreadyAdded:
            return "That key is already on this Mac."
        case .unreachable:
            return "Couldn't reach the license server. Check your connection and try again."
        }
    }
}
