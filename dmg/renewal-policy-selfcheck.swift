// Standalone self-check for RenewalPolicy's scheduling decisions and the
// free-vs-paid Apple account classification they key off.
// Run: swift dmg/renewal-policy-selfcheck.swift
//
// The pure functions are duplicated here (not imported) because the app has no
// test target and these are dependency-free date math and string matching. If
// Sources/RenewalPolicy.swift or Sources/SigningAccount.swift changes, mirror
// the change here. Kept as a loose script per this repo's convention (see the
// other dmg/*.swift tools).
import Foundation

enum RenewalPolicy {
    static let freeSignatureLifetime: TimeInterval = 7 * 24 * 3600
    static let paidSignatureLifetime: TimeInterval = 365 * 24 * 3600
    static let renewWindow: TimeInterval = 2 * 24 * 3600
    static let weeklyGap: TimeInterval = 7 * 24 * 3600

    static func versionChanged(stored: String?, latest: String) -> Bool {
        stored != latest
    }
    static func dueForUpdateCheck(lastCheck: Date?, now: Date,
                                  gap: TimeInterval = weeklyGap) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= gap
    }
    static func dueForRenewal(expiresAt: Date, lastBuild: Date, now: Date,
                              window: TimeInterval = renewWindow,
                              minGap: TimeInterval = weeklyGap) -> Bool {
        let nearExpiry = expiresAt <= now.addingTimeInterval(window)
        let rebuiltThisWeek = now.timeIntervalSince(lastBuild) < minGap
        return nearExpiry && !rebuiltThisWeek
    }
}

enum SigningAccount: String {
    case free
    case paid

    var signatureLifetime: TimeInterval {
        switch self {
        case .free: return RenewalPolicy.freeSignatureLifetime
        case .paid: return RenewalPolicy.paidSignatureLifetime
        }
    }

    static let teamEntry = try? NSRegularExpression(
        pattern: #"isFreeProvisioningTeam\s*=\s*([01])\s*;\s*teamID\s*=\s*"?[A-Z0-9]{10}(?![A-Z0-9])"?"#)

    static func classify(teamDump dump: String) -> SigningAccount? {
        guard let regex = teamEntry,
              let match = regex.firstMatch(in: dump,
                                           range: NSRange(dump.startIndex..., in: dump)),
              let flag = Range(match.range(at: 1), in: dump) else { return nil }
        return dump[flag] == "0" ? .paid : .free
    }
}

let now = Date()
let day: TimeInterval = 24 * 3600

// versionChanged
assert(RenewalPolicy.versionChanged(stored: "1.2.0", latest: "1.3.0") == true)
assert(RenewalPolicy.versionChanged(stored: "1.2.0", latest: "1.2.0") == false)
assert(RenewalPolicy.versionChanged(stored: nil, latest: "1.0.0") == true,
       "nil stored → unknown → treat as changed")

// dueForUpdateCheck (weekly gate)
assert(RenewalPolicy.dueForUpdateCheck(lastCheck: nil, now: now) == true,
       "never checked → due")
assert(RenewalPolicy.dueForUpdateCheck(lastCheck: now.addingTimeInterval(-3 * day), now: now) == false,
       "checked 3 days ago → not due (weekly)")
assert(RenewalPolicy.dueForUpdateCheck(lastCheck: now.addingTimeInterval(-8 * day), now: now) == true,
       "checked 8 days ago → due")

// dueForRenewal (near expiry AND not rebuilt this week / once-a-week cap)
assert(RenewalPolicy.dueForRenewal(expiresAt: now.addingTimeInterval(1 * day),
                                   lastBuild: now.addingTimeInterval(-8 * day), now: now) == true,
       "near expiry, not rebuilt this week → due")
assert(RenewalPolicy.dueForRenewal(expiresAt: now.addingTimeInterval(5 * day),
                                   lastBuild: now.addingTimeInterval(-8 * day), now: now) == false,
       "not near expiry → not due")
assert(RenewalPolicy.dueForRenewal(expiresAt: now.addingTimeInterval(1 * day),
                                   lastBuild: now.addingTimeInterval(-2 * day), now: now) == false,
       "rebuilt 2 days ago → once-a-week cap skips it")

// classify (Xcode's team cache: isFreeProvisioningTeam is Apple's own verdict)
let paidDump = """
{
    "702A3917-2C31-4D48-A04D-B35ACA593376" =     (
                {
            isFreeProvisioningTeam = 0;
            teamID = V8K8L3ZSD5;
            teamName = "Some Developer";
            teamType = Individual;
        }
    );
}
"""
let freeDump = paidDump.replacingOccurrences(of: "isFreeProvisioningTeam = 0",
                                             with: "isFreeProvisioningTeam = 1")
assert(SigningAccount.classify(teamDump: paidDump) == .paid,
       "isFreeProvisioningTeam = 0 → paid membership")
assert(SigningAccount.classify(teamDump: freeDump) == .free,
       "isFreeProvisioningTeam = 1 → free Apple ID")
assert(SigningAccount.classify(teamDump: "{\n}") == nil,
       "no team in the cache → unknown, caller assumes free")
// A Mac holding both teams is classified by the one that signs, which is the
// first entry in the dump (what the CLI's detectXcodeTeam() picks).
let bothDump = freeDump + paidDump
assert(SigningAccount.classify(teamDump: bothDump) == .free,
       "free team listed first → classified free, not by the paid team further down")

// A paid signature outlives the renew window by a year, so nothing is due; the
// same build on a free account is due two days before its week is up.
let paidSigned = now.addingTimeInterval(-8 * day)
assert(RenewalPolicy.dueForRenewal(
    expiresAt: paidSigned.addingTimeInterval(SigningAccount.paid.signatureLifetime),
    lastBuild: paidSigned, now: now) == false,
       "paid account signed 8 days ago → nowhere near its year → not due")
assert(RenewalPolicy.dueForRenewal(
    expiresAt: paidSigned.addingTimeInterval(SigningAccount.free.signatureLifetime),
    lastBuild: paidSigned, now: now) == true,
       "free account signed 8 days ago → past its week → due")

print("RenewalPolicy self-check: all assertions passed ✓")
