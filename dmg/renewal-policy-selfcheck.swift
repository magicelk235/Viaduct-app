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

    struct Team: Equatable {
        let id: String
        let account: SigningAccount?
    }

    static let teamCacheField = try? NSRegularExpression(
        pattern: #"isFreeProvisioningTeam\s*=\s*([01])|teamID\s*=\s*"?([A-Z0-9]{10})(?![A-Z0-9])"?"#)

    static func teams(inTeamDump dump: String) -> [Team] {
        guard let regex = teamCacheField else { return [] }
        var found: [Team] = []
        var pending: SigningAccount?
        regex.enumerateMatches(in: dump, range: NSRange(dump.startIndex..., in: dump)) { m, _, _ in
            guard let m else { return }
            if let flag = Range(m.range(at: 1), in: dump) {
                pending = dump[flag] == "0" ? .paid : .free
                return
            }
            guard let id = Range(m.range(at: 2), in: dump) else { return }
            let team = Team(id: String(dump[id]), account: pending)
            pending = nil
            if !found.contains(where: { $0.id == team.id }) { found.append(team) }
        }
        return found
    }

    static func pick(cached: [Team],
                     certs: @autoclosure () -> [Team],
                     provisioned: @autoclosure () -> [Team]) -> Team? {
        if let cached = cached.first { return cached }
        let certs = certs()
        guard !certs.isEmpty else { return nil }
        if let profiled = provisioned().first(where: { p in certs.contains { $0.id == p.id } }) {
            return Team(id: profiled.id,
                        account: profiled.account ?? certs.first { $0.id == profiled.id }?.account)
        }
        return certs[0]
    }

    static func merge(cached: [Team], certs: [Team], provisioned: [Team]) -> [Team] {
        var ordered: [Team] = []
        if let best = pick(cached: cached, certs: certs, provisioned: provisioned) {
            ordered.append(best)
        }
        for team in cached + certs where !ordered.contains(where: { $0.id == team.id }) {
            ordered.append(team)
        }
        let known = cached + certs + provisioned
        return ordered.map { team in
            Team(id: team.id,
                 account: team.account
                     ?? known.first { $0.id == team.id && $0.account != nil }?.account)
        }
    }

    static func signingTeam(from teams: [Team], pinned: String) -> Team? {
        teams.first { $0.id == pinned }
            ?? teams.first { $0.account == .paid }
            ?? teams.first
    }

    static func account(profileSpan span: TimeInterval) -> SigningAccount {
        span >= 30 * 24 * 3600 ? .paid : .free
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

// teams(inTeamDump:) — Xcode's team cache, where isFreeProvisioningTeam is
// Apple's own verdict and the first team listed is the one the CLI signs with.
let paidDump = """
{
    "702A3917-2C31-4D48-A04D-B35ACA593376" =     (
                {
            isFreeProvisioningTeam = 0;
            isMemberOfProgram = 1;
            teamID = V8K8L3ZSD5;
            teamName = "Some Developer";
            teamType = Individual;
        }
    );
}
"""
let freeDump = paidDump
    .replacingOccurrences(of: "isFreeProvisioningTeam = 0", with: "isFreeProvisioningTeam = 1")
    .replacingOccurrences(of: "V8K8L3ZSD5", with: "AB12CD34EF")
assert(SigningAccount.teams(inTeamDump: paidDump)
        == [.init(id: "V8K8L3ZSD5", account: .paid)],
       "isFreeProvisioningTeam = 0 → paid membership, whatever keys sit between the flag and the id")
assert(SigningAccount.teams(inTeamDump: freeDump)
        == [.init(id: "AB12CD34EF", account: .free)],
       "isFreeProvisioningTeam = 1 → free Apple ID")
assert(SigningAccount.teams(inTeamDump: "{\n}").isEmpty,
       "no team in the cache → nothing to sign with, the CLI falls back to ad-hoc")
assert(SigningAccount.teams(inTeamDump: "{\n    teamID = V8K8L3ZSD5;\n}")
        == [.init(id: "V8K8L3ZSD5", account: nil)],
       "an Xcode too old to record the flag names a team with no verdict → assume free")
// A Mac holding both teams signs with the first one listed, and each keeps its
// own verdict: one flag must not smear across every id after it.
assert(SigningAccount.teams(inTeamDump: freeDump + paidDump)
        == [.init(id: "AB12CD34EF", account: .free),
            .init(id: "V8K8L3ZSD5", account: .paid)],
       "free team listed first → signs free, and the paid team below keeps its own verdict")

// account(profileSpan:) — a provisioning profile dates itself, and Apple gives a
// personal team a week where a membership gets a year.
assert(SigningAccount.account(profileSpan: 7 * day) == .free,
       "seven-day profile → free personal team")
assert(SigningAccount.account(profileSpan: 365 * day) == .paid,
       "year-long profile → paid membership")
assert(SigningAccount.account(profileSpan: 18 * 365 * day) == .paid,
       "long-lived Mac Team profile → paid membership")

// pick(cached:certs:provisioned:) — which team the CLI signs with. Mirrors
// viaduct's detectXcodeTeam() (src/build/packager.ts, 1.11.4): Xcode's accounts
// and the keychain nominate a team, provisioning profiles only choose between
// them. Get this wrong and the app either warns a Mac that signs perfectly well
// or stays quiet while every build comes out ad-hoc.
let cachedFree = SigningAccount.Team(id: "AB12CD34EF", account: .free)
let certDev = SigningAccount.Team(id: "CD34EF56GH", account: nil)
let certPaid = SigningAccount.Team(id: "EF56GH78IJ", account: .paid)
let vendorProfile = SigningAccount.Team(id: "ZZ99YY88XX", account: .paid)
var laterSourcesRead = 0
func counted(_ teams: [SigningAccount.Team]) -> [SigningAccount.Team] {
    laterSourcesRead += 1
    return teams
}
assert(SigningAccount.pick(cached: [cachedFree, certPaid],
                           certs: counted([certPaid]),
                           provisioned: counted([vendorProfile])) == cachedFree,
       "Xcode's account cache decides, and its first team is the one that signs")
assert(laterSourcesRead == 0,
       "cache answered → no keychain scan and no profiles parsed")
assert(SigningAccount.pick(cached: [], certs: [], provisioned: [vendorProfile]) == nil,
       "profiles alone never nominate a team (issue #15: a vendor's profile, no account) → ad-hoc")
assert(SigningAccount.pick(cached: [], certs: [certDev, certPaid], provisioned: []) == certDev,
       "no profile to choose with → the best certificate class wins")
assert(SigningAccount.pick(cached: [], certs: [certDev, certPaid],
                           provisioned: [certPaid]) == certPaid,
       "the newest profile picks among the teams a certificate can sign for")
assert(SigningAccount.pick(cached: [], certs: [certDev, certPaid],
                           provisioned: [vendorProfile, certDev])
        == SigningAccount.Team(id: certDev.id, account: nil),
       "an unsignable profile is skipped, and an undated one leaves the class to the certificate")
assert(SigningAccount.pick(cached: [], certs: [certDev],
                           provisioned: [SigningAccount.Team(id: certDev.id, account: .paid)])
        == SigningAccount.Team(id: certDev.id, account: .paid),
       "an Apple Development cert says nothing about the tier; the profile's own span does")

// merge(cached:certs:provisioned:) — every team the user can be offered, best
// first. A profile-only team is never offered: it's a team this Mac may hold no
// account for, and picking it would produce an ad-hoc build.
assert(SigningAccount.merge(cached: [cachedFree], certs: [certPaid], provisioned: [vendorProfile])
        == [cachedFree, certPaid],
       "the team that would sign leads, and the other signable team follows")
assert(SigningAccount.merge(cached: [], certs: [], provisioned: [vendorProfile]).isEmpty,
       "a profile alone is not a team this Mac can sign with, so it isn't offered")
assert(SigningAccount.merge(cached: [cachedFree, cachedFree], certs: [cachedFree],
                            provisioned: []) == [cachedFree],
       "the same team named by several sources is offered once")
assert(SigningAccount.merge(cached: [], certs: [certDev],
                            provisioned: [SigningAccount.Team(id: certDev.id, account: .paid)])
        == [SigningAccount.Team(id: certDev.id, account: .paid)],
       "a team no nominating source can classify takes the verdict the profile carries")

// signingTeam(from:pinned:) — which of those actually signs. Preferring paid is
// the whole point: a Mac with both used to sign with whichever team Xcode
// cached first, handing a paying developer a seven-day signature.
assert(SigningAccount.signingTeam(from: [cachedFree, certPaid], pinned: "") == certPaid,
       "no pin → the paid membership signs, even though the personal team is listed first")
assert(SigningAccount.signingTeam(from: [cachedFree, certPaid], pinned: cachedFree.id) == cachedFree,
       "a pinned team wins, including a deliberate pin to the personal one")
assert(SigningAccount.signingTeam(from: [cachedFree, certPaid], pinned: "ZZ99YY88XX") == certPaid,
       "a pin to a team this Mac no longer has falls back to the best one it does")
assert(SigningAccount.signingTeam(from: [certDev], pinned: "") == certDev,
       "nothing classified → the only team there is")
assert(SigningAccount.signingTeam(from: [], pinned: "") == nil,
       "no team at all → ad-hoc, and no picker to show")

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
