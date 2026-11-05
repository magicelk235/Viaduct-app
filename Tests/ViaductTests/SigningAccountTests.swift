@testable import Viaduct
import XCTest

final class SigningAccountTests: XCTestCase {
    private typealias Team = SigningAccount.Team

    private let day: TimeInterval = 24 * 3600
    private let cachedFree = Team(id: "AB12CD34EF", account: .free)
    private let certDev = Team(id: "CD34EF56GH", account: nil)
    private let certPaid = Team(id: "EF56GH78IJ", account: .paid)
    private let vendorProfile = Team(id: "ZZ99YY88XX", account: .paid)

    // Xcode's team cache, where isFreeProvisioningTeam is Apple's own verdict
    // and the first team listed is the one the CLI signs with.
    func testTeamsInTeamDump() {
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

        XCTAssertEqual(SigningAccount.teams(inTeamDump: paidDump),
                       [Team(id: "V8K8L3ZSD5", account: .paid)],
                       "isFreeProvisioningTeam = 0 → paid membership, whatever keys sit between the flag and the id")
        XCTAssertEqual(SigningAccount.teams(inTeamDump: freeDump),
                       [Team(id: "AB12CD34EF", account: .free)],
                       "isFreeProvisioningTeam = 1 → free Apple ID")
        XCTAssertTrue(SigningAccount.teams(inTeamDump: "{\n}").isEmpty,
                      "no team in the cache → nothing to sign with, the CLI falls back to ad-hoc")
        XCTAssertEqual(SigningAccount.teams(inTeamDump: "{\n    teamID = V8K8L3ZSD5;\n}"),
                       [Team(id: "V8K8L3ZSD5", account: nil)],
                       "an Xcode too old to record the flag names a team with no verdict → assume free")
        // A Mac holding both teams signs with the first one listed, and each keeps
        // its own verdict: one flag must not smear across every id after it.
        XCTAssertEqual(SigningAccount.teams(inTeamDump: freeDump + paidDump),
                       [Team(id: "AB12CD34EF", account: .free),
                        Team(id: "V8K8L3ZSD5", account: .paid)],
                       "free team listed first → signs free, and the paid team below keeps its own verdict")
    }

    // A provisioning profile dates itself, and Apple gives a personal team a
    // week where a membership gets a year.
    func testAccountFromProfileSpan() {
        XCTAssertEqual(SigningAccount.account(profileSpan: 7 * day), .free,
                       "seven-day profile → free personal team")
        XCTAssertEqual(SigningAccount.account(profileSpan: 365 * day), .paid,
                       "year-long profile → paid membership")
        XCTAssertEqual(SigningAccount.account(profileSpan: 18 * 365 * day), .paid,
                       "long-lived Mac Team profile → paid membership")
    }

    // Which team the CLI signs with. Mirrors viaduct's detectXcodeTeam()
    // (src/build/packager.ts, 1.11.4): Xcode's accounts and the keychain
    // nominate a team, provisioning profiles only choose between them. Get this
    // wrong and the app either warns a Mac that signs perfectly well or stays
    // quiet while every build comes out ad-hoc.
    func testPick() {
        var laterSourcesRead = 0
        func counted(_ teams: [Team]) -> [Team] {
            laterSourcesRead += 1
            return teams
        }

        XCTAssertEqual(SigningAccount.pick(cached: [cachedFree, certPaid],
                                           certs: counted([certPaid]),
                                           provisioned: counted([vendorProfile])),
                       cachedFree,
                       "Xcode's account cache decides, and its first team is the one that signs")
        XCTAssertEqual(laterSourcesRead, 0,
                       "cache answered → no keychain scan and no profiles parsed")
        XCTAssertNil(SigningAccount.pick(cached: [], certs: [], provisioned: [vendorProfile]),
                     "profiles alone never nominate a team (issue #15: a vendor's profile, no account) → ad-hoc")
        XCTAssertEqual(SigningAccount.pick(cached: [], certs: [certDev, certPaid], provisioned: []),
                       certDev,
                       "no profile to choose with → the best certificate class wins")
        XCTAssertEqual(SigningAccount.pick(cached: [], certs: [certDev, certPaid],
                                           provisioned: [certPaid]),
                       certPaid,
                       "the newest profile picks among the teams a certificate can sign for")
        XCTAssertEqual(SigningAccount.pick(cached: [], certs: [certDev, certPaid],
                                           provisioned: [vendorProfile, certDev]),
                       Team(id: certDev.id, account: nil),
                       "an unsignable profile is skipped, and an undated one leaves the class to the certificate")
        XCTAssertEqual(SigningAccount.pick(cached: [], certs: [certDev],
                                           provisioned: [Team(id: certDev.id, account: .paid)]),
                       Team(id: certDev.id, account: .paid),
                       "an Apple Development cert says nothing about the tier; the profile's own span does")
    }

    // Every team the user can be offered, best first. A profile-only team is
    // never offered: it's a team this Mac may hold no account for, and picking
    // it would produce an ad-hoc build.
    func testMerge() {
        XCTAssertEqual(SigningAccount.merge(cached: [cachedFree], certs: [certPaid], provisioned: [vendorProfile]),
                       [cachedFree, certPaid],
                       "the team that would sign leads, and the other signable team follows")
        XCTAssertTrue(SigningAccount.merge(cached: [], certs: [], provisioned: [vendorProfile]).isEmpty,
                      "a profile alone is not a team this Mac can sign with, so it isn't offered")
        XCTAssertEqual(SigningAccount.merge(cached: [cachedFree, cachedFree], certs: [cachedFree],
                                            provisioned: []),
                       [cachedFree],
                       "the same team named by several sources is offered once")
        XCTAssertEqual(SigningAccount.merge(cached: [], certs: [certDev],
                                            provisioned: [Team(id: certDev.id, account: .paid)]),
                       [Team(id: certDev.id, account: .paid)],
                       "a team no nominating source can classify takes the verdict the profile carries")
    }

    // Which of those actually signs: the paid membership ahead of a personal
    // team, so a Mac holding both doesn't sign with whichever team Xcode
    // happened to cache first.
    func testSigningTeam() {
        XCTAssertEqual(SigningAccount.signingTeam(from: [cachedFree, certPaid]), certPaid,
                       "the paid membership signs, even though the personal team is listed first")
        XCTAssertEqual(SigningAccount.signingTeam(from: [certDev]), certDev,
                       "nothing classified → the only team there is")
        XCTAssertNil(SigningAccount.signingTeam(from: []),
                     "no team at all → ad-hoc")
    }
}
