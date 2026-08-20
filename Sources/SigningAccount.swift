import Foundation

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

    // MARK: - Which account this Mac has

    /// The account class this Mac would sign with, or nil when Xcode has no team
    /// cached yet. A nil answer means "assume free": re-signing a year-long
    /// signature after a week only costs a rebuild, while assuming a year on a
    /// free account means Safari drops the extension with nothing scheduled to
    /// bring it back.
    ///
    /// Read out of Xcode's own team cache — the same four domain/key
    /// combinations `xcodeTeamPresent()` scans, in the order the CLI collects
    /// them, because the answer has to describe the team that will actually
    /// sign: `detectXcodeTeam()` takes the first team in this dump.
    static func detect() -> SigningAccount? {
        for domain in ["com.apple.dt.Xcode", "com.apple.dt.xcodebuild"] {
            for key in ["IDEProvisioningTeamByIdentifier", "IDEProvisioningTeams"] {
                guard let out = shellOutput("/usr/bin/defaults", ["read", domain, key]),
                      let kind = classify(teamDump: out) else { continue }
                return kind
            }
        }
        return nil
    }

    /// Entry pattern in a `defaults read` dump of Xcode's team cache. Xcode
    /// stores Apple's own verdict next to the id, so free-vs-paid is a lookup
    /// rather than a guess. Both keys sit in one pattern so a Mac holding a
    /// personal team AND a paid one is classified by the team that signs instead
    /// of by whichever flag happens to appear first; `defaults` prints an
    /// entry's keys alphabetically, which puts the flag ahead of its own id.
    ///
    /// Built once. The pattern is a literal, so it cannot actually fail to
    /// compile, but `try?` keeps a crash out of a purely diagnostic path.
    private static let teamEntry = try? NSRegularExpression(
        pattern: #"isFreeProvisioningTeam\s*=\s*([01])\s*;\s*teamID\s*=\s*"?[A-Z0-9]{10}(?![A-Z0-9])"?"#)

    /// Classify the first team in a team-cache dump, or nil when the dump names
    /// no team (or an Xcode old enough not to record the flag).
    static func classify(teamDump dump: String) -> SigningAccount? {
        guard let regex = teamEntry,
              let match = regex.firstMatch(in: dump,
                                           range: NSRange(dump.startIndex..., in: dump)),
              let flag = Range(match.range(at: 1), in: dump) else { return nil }
        return dump[flag] == "0" ? .paid : .free
    }

    // MARK: - When a build's signature lapses

    /// When a build signed just now stops being trusted. A provisioning profile
    /// embedded in the build carries Apple's own expiry date, so it wins when
    /// it's there; otherwise the date is the account's lifetime counted from the
    /// signing. Being a day or two out doesn't matter — renewal looks two days
    /// ahead of expiry and caps itself at one rebuild a week.
    static func signatureExpiry(installedAppPath: String?, signedAt: Date,
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

    /// ExpirationDate out of a `.provisionprofile`. The file is a CMS blob with
    /// its payload plist sitting inside as plain XML, so the plist is sliced out
    /// and parsed here instead of spawning `security cms -D` per file. The bytes
    /// are read as ISO-8859-1 because the CMS wrapper is binary and a UTF-8
    /// decode of it fails outright; the plist itself is ASCII either way.
    static func profileExpiry(at url: URL) -> Date? {
        guard let bytes = try? Data(contentsOf: url),
              let blob = String(data: bytes, encoding: .isoLatin1),
              let start = blob.range(of: "<?xml"),
              let end = blob.range(of: "</plist>", range: start.upperBound..<blob.endIndex),
              let xml = String(blob[start.lowerBound..<end.upperBound]).data(using: .utf8),
              let plist = try? PropertyListSerialization
                  .propertyList(from: xml, format: nil) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }

    // MARK: - Can this Mac team-sign at all

    /// True when the machine can team-sign. This has to agree with the CLI's own
    /// detectXcodeTeam() (`src/build/packager.ts`, as of 1.10.3): the app only
    /// decides whether to warn, the CLI decides how it actually signs, and when
    /// they disagree the user gets a silently ad-hoc build with no warning at
    /// all — or, the way it drifted this time, a warning on a machine the CLI
    /// would have team-signed on. They did drift once before too: a checked-in
    /// copy of the CLI sat at 1.0.0, which had no keychain fallback, which is
    /// why the engine is now fetched from npm instead of shipped in the app.
    ///
    /// Three source groups, in the CLI's order, cheapest first: the team ids
    /// Xcode caches in its preferences, any provisioning profile already on
    /// disk, then a signing certificate in the keychain. None of the earlier
    /// ones is authoritative — the preference cache is written asynchronously
    /// and stays empty on setups where the account is signed in but no team has
    /// been fetched yet — so a miss has to fall through rather than decide.
    static func xcodeTeamPresent() -> Bool {
        teamInPreferences() || teamInProvisioningProfiles() || teamInKeychain()
    }

    /// Team ids Xcode caches once an account is added. Two keys across two
    /// domains: current Xcode writes IDEProvisioningTeamByIdentifier, older
    /// versions and xcodebuild itself write IDEProvisioningTeams, and the
    /// xcodebuild domain is sometimes populated when the Xcode one is not.
    /// Which combination exists varies by Xcode version, and all four are cheap
    /// `defaults` reads.
    private static func teamInPreferences() -> Bool {
        for domain in ["com.apple.dt.Xcode", "com.apple.dt.xcodebuild"] {
            for key in ["IDEProvisioningTeamByIdentifier", "IDEProvisioningTeams"] {
                guard let out = shellOutput("/usr/bin/defaults", ["read", domain, key]) else {
                    continue
                }
                // Boundary after the 10 chars so a longer token isn't truncated
                // into a wrong-but-plausible id; a real team id is exactly 10.
                if out.range(of: #"teamID\s*=\s*"?[A-Z0-9]{10}(?![A-Z0-9])"?"#,
                             options: .regularExpression) != nil {
                    return true
                }
            }
        }
        return false
    }

    /// Where Xcode downloads provisioning profiles: Xcode 16+ first, then the
    /// location older versions used.
    private static let provisioningProfileDirs = [
        "Library/Developer/Xcode/UserData/Provisioning Profiles",
        "Library/MobileDevice/Provisioning Profiles",
    ]

    /// True when a provisioning profile on disk names a team. Profiles are
    /// CMS-signed, but the payload plist sits in the blob as plain XML, so
    /// scanning the bytes beats shelling out to `security cms -D` once per file.
    /// They're decoded as ISO-8859-1 because the CMS wrapper is binary and a
    /// UTF-8 decode of it fails outright; the plist itself is ASCII either way.
    private static func teamInProvisioningProfiles() -> Bool {
        // TeamIdentifier is the modern key. Profiles cut before Xcode 6 carry
        // only ApplicationIdentifierPrefix, whose single element is the team id.
        let pattern = #"<key>(TeamIdentifier|ApplicationIdentifierPrefix|com\.apple\.developer\.team-identifier)</key>\s*(<array>\s*)?<string>[A-Z0-9]{10}(?![A-Z0-9])</string>"#
        let home = FileManager.default.homeDirectoryForCurrentUser
        for dir in provisioningProfileDirs {
            let dirURL = home.appendingPathComponent(dir)
            guard let names = try? FileManager.default
                .contentsOfDirectory(atPath: dirURL.path) else { continue }
            for name in names
            where name.hasSuffix(".provisionprofile") || name.hasSuffix(".mobileprovision") {
                guard let bytes = try? Data(contentsOf: dirURL.appendingPathComponent(name)),
                      let blob = String(data: bytes, encoding: .isoLatin1) else { continue }
                if blob.range(of: pattern, options: .regularExpression) != nil { return true }
            }
        }
        return false
    }

    /// True when the keychain holds an Apple certificate that carries a team id.
    /// Development certs are the ones the build asks for, but Developer ID and
    /// App Store certs count too: the build runs `xcodebuild
    /// -allowProvisioningUpdates`, so the team id is the only thing missing and
    /// Xcode mints the development certificate itself. Apple puts the same team
    /// id in every cert's subject OU, and a Developer ID cert is the only Apple
    /// certificate on the machine of anyone who has shipped a notarized app and
    /// nothing else — those users can team-sign, so don't warn them.
    private static func teamInKeychain() -> Bool {
        guard let identities = shellOutput("/usr/bin/security",
                                           ["find-identity", "-v", "-p", "codesigning"]) else {
            return false
        }
        // Lines look like:  1) <sha1> "Apple Development: me@example.com (XXXXXXXXXX)"
        return identities.range(
            of: #""(Apple Development|Mac Developer|Apple Distribution|iPhone Developer|Developer ID Application|3rd Party Mac Developer Application):"#,
            options: .regularExpression) != nil
    }

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
