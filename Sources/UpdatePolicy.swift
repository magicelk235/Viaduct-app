import Foundation

/// Pure scheduling decisions for Chrome Web Store auto-update, factored out of
/// `ExtensionUpdater` so they can be checked without the @MainActor / CLI /
/// filesystem machinery. No side effects — just dates and versions in,
/// booleans out.
///
/// Self-check lives in `dmg/update-policy-selfcheck.swift` (run standalone,
/// matching this repo's loose-script convention). It can't live here: a
/// top-level expression is illegal in a multi-file app-target module.
enum UpdatePolicy {
    /// How often each store install is polled for a new version.
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
}

