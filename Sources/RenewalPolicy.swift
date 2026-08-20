import Foundation

/// Pure scheduling decisions for auto-renew and auto-update, factored out of
/// `ExtensionRenewer` so they can be unit-checked without the @MainActor /
/// CLI / filesystem machinery. No side effects — just dates and versions in,
/// booleans out.
///
/// Self-check lives in `dmg/renewal-policy-selfcheck.swift` (run standalone,
/// matching this repo's loose-script convention). It can't live here: a
/// top-level expression is illegal in a multi-file app-target module.
enum RenewalPolicy {
    /// How long a build signed with a free Apple ID holds before Safari drops
    /// the extension — Apple's provisioning window for a personal team.
    static let freeSignatureLifetime: TimeInterval = 7 * 24 * 3600
    /// The same window for a paid Developer Program membership: a year, which is
    /// why the account has to be classified instead of assumed (see
    /// `SigningAccount`). Signing a paid build and then renewing it weekly buys
    /// nothing and rebuilds every extension fifty times over.
    static let paidSignatureLifetime: TimeInterval = 365 * 24 * 3600
    /// Renew this long before the signature lapses.
    static let renewWindow: TimeInterval = 2 * 24 * 3600
    /// Never rebuild the same extension more than once in this span — the hard
    /// once-a-week cap on renew, and the weekly poll cadence for update checks.
    static let weeklyGap: TimeInterval = 7 * 24 * 3600

    /// True when the upstream version differs from what we last built. Exact
    /// string inequality, not semver: store versions are monotonic, and a
    /// publisher's scheme may not parse as semver. A nil stored version (old
    /// record) counts as "unknown" → adopt whatever's live now.
    static func versionChanged(stored: String?, latest: String) -> Bool {
        stored != latest
    }

    /// True when this record is due for a CWS version poll: never checked, or
    /// last checked at least a week ago. Gates the weekly update cadence.
    static func dueForUpdateCheck(lastCheck: Date?, now: Date,
                                  gap: TimeInterval = weeklyGap) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= gap
    }

    /// True when a build should be renewed now: it's within the renew window of
    /// its signature expiry AND it hasn't already been rebuilt within the last
    /// week (the hard once-per-week cap — stops a relaunch or manual trigger
    /// from rebuilding the same extension twice in a window).
    static func dueForRenewal(expiresAt: Date, lastBuild: Date, now: Date,
                              window: TimeInterval = renewWindow,
                              minGap: TimeInterval = weeklyGap) -> Bool {
        let nearExpiry = expiresAt <= now.addingTimeInterval(window)
        let rebuiltThisWeek = now.timeIntervalSince(lastBuild) < minGap
        return nearExpiry && !rebuiltThisWeek
    }
}

