import Foundation
import Security

/// Which kind of Apple account this Mac signs with, and therefore how long a
/// converted extension keeps working: Apple gives a free Apple ID a seven-day
/// signing window, while a paid Developer Program membership gets a year.
///
/// Treating every Mac as the free case rebuilt a paying developer's extensions
/// fifty-odd times a year for nothing, and told them their extension expires in
/// a week when it doesn't — so the account is classified once per build and each
/// history record carries the expiry that came out of it.
enum SigningAccount: String, Codable {
    /// A free Apple ID. Xcode calls it a personal team.
    case free
    /// A paid Apple Developer Program membership.
    case paid

    /// How long a fresh signature from this account holds.
    var signatureLifetime: TimeInterval {
        switch self {
        case .free: return RenewalPolicy.freeSignatureLifetime
        case .paid: return RenewalPolicy.paidSignatureLifetime
        }
    }

    /// The account as a settings row names it — short, since it sits in a value
    /// slot next to the lifetime.
    var label: String {
        switch self {
        case .free: return "Free Apple ID"
        case .paid: return "Developer"
        }
    }

    /// The same thing in a sentence.
    var article: String {
        switch self {
        case .free: return "a free Apple ID"
        case .paid: return "an Apple Developer account"
        }
    }

    /// That lifetime in the words the UI uses.
    var lifetimeText: String {
        switch self {
        case .free: return "7 days"
        case .paid: return "1 year"
        }
    }

    // MARK: - Which team signs, and what kind it is

    /// A team this Mac might sign with. `account` is nil when whatever named the
    /// team can't tell a free Apple ID from a paid membership — read everywhere
    /// as "assume free": re-signing a year-long signature after a week only
    /// costs a rebuild, while assuming a year on a free account means Safari
    /// drops the extension with nothing scheduled to bring it back.
    struct Team: Equatable {
        let id: String
        let account: SigningAccount?
    }

    /// The team the CLI will hand xcodebuild, or nil when the build will sign
    /// ad-hoc. This mirrors viaduct's own `detectXcodeTeam()`
    /// (`src/build/packager.ts`, as of 1.11.4): the app only decides whether to
    /// warn, the CLI decides how it actually signs, and when they disagree the
    /// user gets a silently ad-hoc build with no warning at all.
    ///
    /// A team id lying on disk is not proof this Mac can sign for it. Profiles
    /// outlive the account that installed them, and installers drop profiles for
    /// their own vendor's team, so the CLI stopped letting a profile nominate a
    /// team (its issue #15: every build died on "No Account for Team"). Xcode's
    /// account cache and the keychain nominate; profiles only pick between them.
    static func detectTeam() -> Team? {
        pick(cached: cachedTeams(), certs: certificateTeams(), provisioned: provisionedTeams())
    }

    /// The pick itself, kept free of IO so it can be asserted against the cases
    /// that matter (a profile-only Mac, a profile choosing among certificates).
    /// The two later sources are autoclosures: nothing touches the keychain or
    /// the profiles on disk when the account cache already answered.
    static func pick(cached: [Team],
                     certs: @autoclosure () -> [Team],
                     provisioned: @autoclosure () -> [Team]) -> Team? {
        // The account cache comes first, and it's the only source carrying
        // Apple's own free/paid verdict.
        if let cached = cached.first { return cached }
        let certs = certs()
        guard !certs.isEmpty else { return nil }
        // Newest profile first, so when the keychain holds several teams the
        // pick is the one most recently provisioned for.
        if let profiled = provisioned().first(where: { p in certs.contains { $0.id == p.id } }) {
            // Either source may be the one that knows the class: a profile knows
            // it from its own validity span, a certificate only from its class.
            return Team(id: profiled.id,
                        account: profiled.account ?? certs.first { $0.id == profiled.id }?.account)
        }
        return certs[0]
    }

    /// The account class this Mac would sign with, or nil when nothing can tell
    /// free from paid (including a Mac with no team at all, which signs ad-hoc).
    static func detect() -> SigningAccount? { detectTeam()?.account }

    /// True when the machine can team-sign — i.e. the CLI will find a team to
    /// hand xcodebuild instead of falling back to ad-hoc signing.
    static func xcodeTeamPresent() -> Bool { detectTeam() != nil }

    /// Teams Xcode caches once an account is added, in the order the CLI reads
    /// them. Two keys across two domains: current Xcode writes
    /// IDEProvisioningTeamByIdentifier, older versions and xcodebuild itself
    /// write IDEProvisioningTeams, and the xcodebuild domain is sometimes
    /// populated when the Xcode one is not. Which combination exists varies by
    /// Xcode version, and all four are cheap `defaults` reads.
    static func cachedTeams() -> [Team] {
        var found: [Team] = []
        for domain in ["com.apple.dt.Xcode", "com.apple.dt.xcodebuild"] {
            for key in ["IDEProvisioningTeamByIdentifier", "IDEProvisioningTeams"] {
                guard let dump = shellOutput("/usr/bin/defaults", ["read", domain, key]) else {
                    continue
                }
                for team in teams(inTeamDump: dump)
                where !found.contains(where: { $0.id == team.id }) {
                    found.append(team)
                }
            }
        }
        return found
    }

    /// Either half of a team-cache entry: Apple's free/paid verdict, or a team
    /// id. Matched in one pattern so the two can be paired as they appear —
    /// `defaults` prints an entry's keys alphabetically, which puts
    /// isFreeProvisioningTeam ahead of the teamID it describes, whatever other
    /// keys (isEnterprise, isMemberOfProgram…) Xcode writes between them.
    ///
    /// Built once. The pattern is a literal, so it cannot actually fail to
    /// compile, but `try?` keeps a crash out of a purely diagnostic path.
    private static let teamCacheField = try? NSRegularExpression(
        // The boundary after the 10 chars keeps a longer token from being
        // truncated into a wrong-but-plausible id; a real team id is exactly 10.
        pattern: #"isFreeProvisioningTeam\s*=\s*([01])|teamID\s*=\s*"?([A-Z0-9]{10})(?![A-Z0-9])"?"#)

    /// Teams in a `defaults read` dump of Xcode's team cache, in the order they
    /// appear — the CLI signs with the first, so that order is the pick. A
    /// verdict belongs to the next id only, so a Mac holding a personal team and
    /// a paid one classifies each correctly instead of smearing the first flag
    /// across both.
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

    /// Certificate classes that carry a team id in the subject OU, best first.
    /// The development ones lead because that's what the build asks for, but a
    /// paid account that only ever signed notarized releases has nothing but a
    /// Developer ID cert, and reading the team off that beats telling the user
    /// they have no Apple account.
    private static let signingCertClasses = [
        "Apple Development",
        "Mac Developer",
        "Apple Distribution",
        "iPhone Developer",
        "Developer ID Application",
        "3rd Party Mac Developer Application",
    ]

    /// Classes Apple issues only to a paid Developer Program membership. A
    /// personal team never gets one, so any of these settles the account class
    /// even when Xcode's cache is empty. "Apple Development" says nothing —
    /// free and paid accounts both get those.
    private static let paidOnlyCertClasses: Set<String> = [
        "Apple Distribution",
        "Developer ID Application",
        "3rd Party Mac Developer Application",
    ]

    /// Teams read off the signing certificates in the keychain, best cert class
    /// first. The certificate is the most authoritative source of "can this Mac
    /// sign at all": it's what codesign consumes, and Apple puts the team id in
    /// the subject's OU. Identities always carry a private key, and expired
    /// certificates are dropped, so every id here is one that can still sign.
    static func certificateTeams() -> [Team] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let identities = result as? [SecIdentity] else { return [] }

        // Rank per team, plus whether any of its certs is one only a paid
        // membership can hold: the same team can appear as both an Apple
        // Development cert (class unknown) and a Developer ID one (paid).
        var rank: [String: Int] = [:]
        var paid: Set<String> = []
        for identity in identities {
            var certRef: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certRef) == errSecSuccess,
                  let cert = certRef,
                  let name = SecCertificateCopySubjectSummary(cert) as String?,
                  let index = signingCertClasses.firstIndex(where: { name.hasPrefix($0) }),
                  !isExpired(cert),
                  let team = subjectOrganizationalUnit(cert) else { continue }
            if paidOnlyCertClasses.contains(signingCertClasses[index]) { paid.insert(team) }
            rank[team] = min(rank[team] ?? index, index)
        }
        return rank.sorted { ($0.value, $0.key) < ($1.value, $1.key) }
            .map { Team(id: $0.key, account: paid.contains($0.key) ? .paid : nil) }
    }

    /// The team id Apple writes into a signing certificate's subject OU.
    private static func subjectOrganizationalUnit(_ cert: SecCertificate) -> String? {
        guard let values = SecCertificateCopyValues(cert, [kSecOIDX509V1SubjectName] as CFArray, nil)
                as? [String: Any],
              let subject = values[kSecOIDX509V1SubjectName as String] as? [String: Any],
              let fields = subject["value"] as? [[String: Any]] else { return nil }
        let ou = kSecOIDOrganizationalUnitName as String
        return fields.first { $0["label"] as? String == ou }?["value"] as? String
    }

    /// True when the certificate's validity has run out. `SecCertificateCopyValues`
    /// hands the date back as seconds since the reference date.
    private static func isExpired(_ cert: SecCertificate) -> Bool {
        guard let values = SecCertificateCopyValues(cert, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil)
                as? [String: Any],
              let field = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
              let notAfter = field["value"] as? Double else { return false }
        return Date(timeIntervalSinceReferenceDate: notAfter) < Date()
    }

    /// Where Xcode downloads provisioning profiles: Xcode 16+ first, then the
    /// location older versions used.
    private static let provisioningProfileDirs = [
        "Library/Developer/Xcode/UserData/Provisioning Profiles",
        "Library/MobileDevice/Provisioning Profiles",
    ]

    /// Teams named by the provisioning profiles on disk, newest profile first —
    /// that order is what makes the most recently provisioned team win. Each
    /// profile also dates itself, which classifies its team without asking
    /// Xcode: Apple issues a personal team a seven-day profile.
    static func provisionedTeams() -> [Team] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var profiles: [(url: URL, modified: Date)] = []
        for dir in provisioningProfileDirs {
            let dirURL = home.appendingPathComponent(dir)
            guard let names = try? FileManager.default
                .contentsOfDirectory(atPath: dirURL.path) else { continue }
            for name in names
            where name.hasSuffix(".provisionprofile") || name.hasSuffix(".mobileprovision") {
                let url = dirURL.appendingPathComponent(name)
                let modified = (try? FileManager.default
                    .attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? nil
                profiles.append((url, modified ?? .distantPast))
            }
        }
        var found: [Team] = []
        for profile in profiles.sorted(by: { $0.modified > $1.modified }) {
            guard let plist = profilePlist(at: profile.url),
                  let id = profileTeamID(in: plist),
                  !found.contains(where: { $0.id == id }) else { continue }
            found.append(Team(id: id, account: profileAccount(in: plist)))
        }
        return found
    }

    /// The team a profile is issued to. TeamIdentifier is the modern key;
    /// profiles cut before Xcode 6 carry only ApplicationIdentifierPrefix, whose
    /// single element is the same id, and the entitlement spelling covers the
    /// rest.
    private static func profileTeamID(in plist: [String: Any]) -> String? {
        let entitlements = plist["Entitlements"] as? [String: Any]
        let candidates = [
            (plist["TeamIdentifier"] as? [String])?.first,
            (plist["ApplicationIdentifierPrefix"] as? [String])?.first,
            entitlements?["com.apple.developer.team-identifier"] as? String,
        ]
        return candidates.compactMap { $0 }
            .first { $0.count == 10 && $0.allSatisfy { $0.isUppercase || $0.isNumber } }
    }

    /// The account class behind a profile, from how long Apple made it valid.
    private static func profileAccount(in plist: [String: Any]) -> SigningAccount? {
        guard let created = plist["CreationDate"] as? Date,
              let expires = plist["ExpirationDate"] as? Date else { return nil }
        return account(profileSpan: expires.timeIntervalSince(created))
    }

    /// Classify a provisioning profile by its validity span. Apple gives a
    /// personal team seven days and a paid membership a year (a Mac Team profile
    /// runs far longer), so anything past a month is paid.
    static func account(profileSpan span: TimeInterval) -> SigningAccount {
        span >= 30 * 24 * 3600 ? .paid : .free
    }

    // MARK: - How a build actually came out

    /// The signature on a converted extension, read back off the bundle Safari
    /// loads rather than predicted from what the run asked for.
    struct ArtifactSignature: Equatable {
        /// Ad-hoc: Safari disables the extension every time it quits.
        let adHoc: Bool
        /// The team the bundle carries, when it carries one.
        let teamID: String?
    }

    /// What a finished build produced: when its signature stops being trusted,
    /// and whether Safari will drop the extension on every quit.
    struct Build: Equatable {
        let adHoc: Bool
        let expiry: Date
    }

    /// Inspect a build that just landed. The CLI (1.11.4 and up) finishes a run
    /// ad-hoc when the team it detected turns out to be unable to sign, instead
    /// of throwing the conversion away — so a successful run can leave an
    /// artifact with no Apple signature at all, and stamping a paid account's
    /// year on it would park the extension for twelve months while Safari drops
    /// it at the first quit. Read the artifact; fall back to the account only
    /// for what the artifact can't say.
    static func inspectBuild(installedAppPath: String?, signedAt: Date,
                             account: SigningAccount?) -> Build {
        let signature = installedAppPath.flatMap { installedSignature(appPath: $0) }
        guard signature?.adHoc != true else {
            // An ad-hoc signature has no Apple window to run out, so the date is
            // only a rebuild cadence: keep it on the weekly one, since a rebuild
            // is what picks up a team once the user has one.
            return Build(adHoc: true,
                         expiry: signedAt.addingTimeInterval(RenewalPolicy.freeSignatureLifetime))
        }
        return Build(adHoc: false,
                     expiry: signatureExpiry(installedAppPath: installedAppPath,
                                             signedAt: signedAt, account: account))
    }

    /// How the installed extension is signed, or nil when nothing readable is
    /// there. Reads the .appex Safari loads, not just its container app: the
    /// container is what the user double-clicks, but the extension is the bundle
    /// Safari refuses when the signature is wrong.
    static func installedSignature(appPath: String) -> ArtifactSignature? {
        let bundle = extensionBundle(inApp: appPath)
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return nil }
        var infoRef: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any] else { return nil }
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String
        guard let flags = info[kSecCodeInfoFlags as String] as? UInt32 else {
            // No CodeDirectory at all: unsigned, which Safari won't load either.
            return team == nil ? nil : ArtifactSignature(adHoc: false, teamID: team)
        }
        let adHoc = flags & SecCodeSignatureFlags.adhoc.rawValue != 0
        return ArtifactSignature(adHoc: adHoc, teamID: team)
    }

    /// The bundle Safari actually loads: the .appex inside the built app, or the
    /// app itself when there is none to find.
    private static func extensionBundle(inApp appPath: String) -> URL {
        let app = URL(fileURLWithPath: appPath)
        let plugIns = app.appendingPathComponent("Contents/PlugIns")
        let contents = (try? FileManager.default
            .contentsOfDirectory(atPath: plugIns.path)) ?? []
        guard let appex = contents.first(where: { $0.hasSuffix(".appex") }) else { return app }
        return plugIns.appendingPathComponent(appex)
    }

    // MARK: - When a build's signature lapses

    /// When a build signed just now stops being trusted. A provisioning profile
    /// embedded in the build carries Apple's own expiry date, so it wins when
    /// it's there; otherwise the date is the account's lifetime counted from the
    /// signing. Being a day or two out doesn't matter — renewal looks two days
    /// ahead of expiry and caps itself at one rebuild a week.
    private static func signatureExpiry(installedAppPath: String?, signedAt: Date,
                                        account: SigningAccount?) -> Date {
        if let installedAppPath, let embedded = embeddedProfileExpiry(inApp: installedAppPath) {
            return embedded
        }
        return signedAt.addingTimeInterval((account ?? .free).signatureLifetime)
    }

    /// Earliest expiry among the provisioning profiles embedded in a converted
    /// .app and its extension appexes — whichever lapses first is when Safari
    /// stops loading the extension. Nil when nothing embedded a profile, which
    /// is the common case for a Mac build (the App Sandbox entitlement doesn't
    /// require one).
    private static func embeddedProfileExpiry(inApp appPath: String) -> Date? {
        let app = URL(fileURLWithPath: appPath)
        var profiles = [app.appendingPathComponent("Contents/embedded.provisionprofile")]
        let plugIns = app.appendingPathComponent("Contents/PlugIns")
        let contents = (try? FileManager.default
            .contentsOfDirectory(atPath: plugIns.path)) ?? []
        profiles += contents.filter { $0.hasSuffix(".appex") }.map {
            plugIns.appendingPathComponent($0)
                .appendingPathComponent("Contents/embedded.provisionprofile")
        }
        return profiles.compactMap(profileExpiry(at:)).min()
    }

    /// ExpirationDate out of a `.provisionprofile`.
    static func profileExpiry(at url: URL) -> Date? {
        profilePlist(at: url)?["ExpirationDate"] as? Date
    }

    /// The payload plist inside a `.provisionprofile`. The file is a CMS blob
    /// with its plist sitting inside as plain XML, so the plist is sliced out and
    /// parsed here instead of spawning `security cms -D` per file. The bytes are
    /// read as ISO-8859-1 because the CMS wrapper is binary and a UTF-8 decode of
    /// it fails outright; the plist itself is ASCII either way.
    private static func profilePlist(at url: URL) -> [String: Any]? {
        guard let bytes = try? Data(contentsOf: url),
              let blob = String(data: bytes, encoding: .isoLatin1),
              let start = blob.range(of: "<?xml"),
              let end = blob.range(of: "</plist>", range: start.upperBound..<blob.endIndex),
              let xml = String(blob[start.lowerBound..<end.upperBound]).data(using: .utf8)
        else { return nil }
        return try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any]
    }

    // MARK: - Is an Apple ID signed in at all

    /// True when an Apple ID is registered in Xcode's Accounts pane. Xcode writes
    /// this list as soon as the account is added, well before it has a team or a
    /// certificate, so it separates "never signed in" from "signed in but Xcode
    /// hasn't issued a signing certificate yet" — two states that need opposite
    /// instructions.
    static func xcodeAccountPresent() -> Bool {
        guard let out = shellOutput("/usr/bin/defaults",
                                    ["read", "com.apple.dt.Xcode",
                                     "DVTDeveloperAccountManagerAppleIDLists"]) else {
            return false
        }
        return out.range(of: #"identifier\s*="#, options: .regularExpression) != nil
    }

    /// Run a tool and return stdout, or nil if it fails to launch or exits non-zero.
    private static func shellOutput(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        // Read before waiting: a full pipe buffer would deadlock the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
