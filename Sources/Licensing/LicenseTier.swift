import Foundation

/// What a license key buys. The raw values are stored in licenses.json, so
/// they never change.
enum LicenseTier: String, Codable, CaseIterable, Identifiable {
    case firefox, safari, mixed

    var id: Self { self }

    var displayName: String {
        switch self {
        case .firefox: return "Firefox"
        case .safari: return "Safari"
        case .mixed: return "Mixed"
        }
    }

    var priceLabel: String {
        switch self {
        case .firefox, .safari: return "$19"
        case .mixed: return "$29"
        }
    }

    var entitlements: Entitlements {
        switch self {
        case .firefox: return Entitlements(safari: false, firefox: true)
        case .safari: return Entitlements(safari: true, firefox: false)
        case .mixed: return .mixed
        }
    }

    /// The tier that unlocks just this browser.
    static func single(for browser: Browser) -> LicenseTier {
        switch browser {
        case .firefox: return .firefox
        case .safari: return .safari
        }
    }

    /// Matches a Polar benefit ID to its tier. Keys from any other benefit
    /// (another product on the same organization) give nil.
    init?(benefitId: String, in benefitIds: [LicenseTier: String]) {
        guard let tier = benefitIds.first(where: { $0.value == benefitId })?.key else { return nil }
        self = tier
    }

    /// The tiers the paywall points at when `blocked` ran out of free
    /// conversions. Mixed drops out when they already own the other browser,
    /// since it would charge them for that browser again.
    static func highlighted(for blocked: Browser?, owned: Entitlements) -> Set<LicenseTier> {
        guard let blocked else { return [] }
        let ownsOther = Browser.allCases.contains { $0 != blocked && owned.unlimited($0) }
        return ownsOther ? [single(for: blocked)] : [single(for: blocked), .mixed]
    }

    /// The tiers worth offering on top of what they own: each one adds a
    /// browser they don't have yet. Mixed only makes sense from nothing.
    static func upgrades(from owned: Entitlements) -> [LicenseTier] {
        let ownsAny = Browser.allCases.contains { owned.unlimited($0) }
        return allCases.filter { tier in
            if tier == .mixed && ownsAny { return false }
            return !owned.covers(tier)
        }
    }
}

/// Which browsers convert without the free-plan limits.
struct Entitlements: Equatable {
    var safari: Bool
    var firefox: Bool

    static let none = Entitlements(safari: false, firefox: false)
    static let mixed = Entitlements(safari: true, firefox: true)

    init(safari: Bool, firefox: Bool) {
        self.safari = safari
        self.firefox = firefox
    }

    /// Everything the tiers give between them.
    init(tiers: [LicenseTier]) {
        let all = tiers.map(\.entitlements)
        self.init(safari: all.contains { $0.safari }, firefox: all.contains { $0.firefox })
    }

    func unlimited(_ browser: Browser) -> Bool {
        switch browser {
        case .safari: return safari
        case .firefox: return firefox
        }
    }

    /// True when the tier would add nothing they don't already have.
    func covers(_ tier: LicenseTier) -> Bool {
        Browser.allCases.allSatisfy { !tier.entitlements.unlimited($0) || unlimited($0) }
    }
}

/// One key in licenses.json, with the tier it unlocks and when it last
/// checked out with its store.
struct StoredKey: Codable, Equatable, Identifiable {
    enum Provider: String, Codable { case polar, gumroad }

    var provider: Provider
    var key: String
    /// Polar's activation for this Mac. Gumroad keys don't have one.
    var activationId: String?
    var tier: LicenseTier
    var lastValidated: Date

    var id: String { key }

    /// How long a key keeps working without reaching its store.
    static let offlineGrace: TimeInterval = 14 * 86_400

    func isUsable(at now: Date) -> Bool {
        now.timeIntervalSince(lastValidated) < Self.offlineGrace
    }

    /// Enough of the key to tell it apart in Settings.
    var maskedKey: String {
        "••••" + key.suffix(6)
    }
}
