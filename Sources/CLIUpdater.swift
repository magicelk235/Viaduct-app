import Foundation
import CryptoKit

/// Installs and keeps the viaduct CLI current by pulling the published npm
/// package. npm ships a prebuilt `dist/`, so both the first install and every
/// later update are download + extract + atomic swap into Application Support
/// (where `CLIRunner` runs it from) — no build step.
///
/// The CLI declares a caret range for each engine (aqueduct, lavaduct) in its
/// `optionalDependencies` and bundles the bottom of that range in
/// `dist/engines/`. Next to the CLI this installs the newest in-range engine
/// into `cli/node_modules/@magicelk235/<engine>`, which the CLI runs ahead of
/// its bundled copy (viaduct-cli `src/engine.js`). That lets an engine fix reach
/// users without a viaduct release. Engines go through the same staged swap as
/// the CLI, and an engine that can't be fetched costs only itself: the bundled
/// copy keeps running.
final class CLIUpdater {
    static let shared = CLIUpdater()

    private let pkg = "@magicelk235/viaduct"
    private static let engineScope = "@magicelk235/"

    /// Where the CLI is installed: `CLIRunner.cliDir`, except in tests.
    let cliDir: URL
    private let session: URLSession

    init(cliDir: URL = CLIRunner.cliDir, session: URLSession = .shared) {
        self.cliDir = cliDir
        self.session = session
    }

    enum UpdateError: LocalizedError {
        case registry(String)
        case download(String)
        case extract(String)
        var errorDescription: String? {
            switch self {
            case .registry(let m): return "Registry error: \(m)"
            case .download(let m): return "Download failed: \(m)"
            case .extract(let m): return "Extract failed: \(m)"
            }
        }
    }

    /// Version of the installed CLI (the `version.txt` marker this writes), or
    /// nil when it hasn't been installed yet.
    var installedVersion: String? {
        guard let s = try? String(contentsOf: cliDir.appendingPathComponent("version.txt"),
                                  encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Whether the CLI is on disk at all. False on a fresh install until the
    /// first fetch lands.
    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: cliDir.appendingPathComponent("dist/cli.js").path)
    }

    private struct DistTags: Decodable { let latest: String }
    private struct VersionDist: Decodable { let tarball: String; let integrity: String }
    private struct PackageDoc: Decodable {
        let distTags: DistTags
        let versions: [String: VersionRecord]
        enum CodingKeys: String, CodingKey { case distTags = "dist-tags", versions }
    }
    private struct VersionRecord: Decodable { let dist: VersionDist }

    /// Fetch the npm package document for `name`.
    private func fetchPackageDoc(_ name: String) async throws -> PackageDoc {
        // Scoped names need the "/" percent-encoded for the registry path.
        let encoded = name.replacingOccurrences(of: "/", with: "%2F")
        let url = URL(string: "https://registry.npmjs.org/\(encoded)")!
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("ViaductApp", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.registry("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        do { return try JSONDecoder().decode(PackageDoc.self, from: data) }
        catch { throw UpdateError.registry("bad JSON: \(error.localizedDescription)") }
    }

    /// Latest published CLI version string.
    func latestVersion() async throws -> String {
        try await fetchPackageDoc(pkg).distTags.latest
    }

    /// True if a newer CLI, or a newer in-range engine, is available
    /// (semver-aware). A failed engine check counts as nothing new; the next
    /// launch asks again.
    func updateAvailable() async throws -> Bool {
        let latest = try await latestVersion()
        guard let have = installedVersion else { return true }
        if Self.semverLess(have, latest) { return true }
        for (engine, range) in Self.engineRanges(in: cliDir).sorted(by: { $0.key < $1.key }) {
            let current = Self.engineVersion(engine, in: cliDir)
            if (try? await engineUpgrade(engine, range: range, over: current)) != nil { return true }
        }
        return false
    }

    /// Download + extract the latest npm tarball into Application Support, which
    /// is both the first install and every later update, together with the
    /// newest in-range engines. With the CLI already current, only engines that
    /// moved are fetched. `log` streams progress and is always invoked on the
    /// main thread so callers can mutate `@Published` state safely.
    func update(rawLog: @escaping (String) -> Void) async throws {
        // Hop every log call to main here so the inline calls below and
        // runProcess's handler share one main-thread guarantee.
        let log: (String) -> Void = { line in DispatchQueue.main.async { rawLog(line) } }
        let doc = try await fetchPackageDoc(pkg)
        let latest = doc.distTags.latest
        log("Latest published: \(latest)")
        let firstInstall = !isInstalled
        let have = firstInstall ? nil : installedVersion
        let cliCurrent = have.map { !Self.semverLess($0, latest) } ?? false

        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("c2s-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // The tree that replaces cli/ in one swap. Gone after the swap; this
        // only clears it when something below threw.
        try fm.createDirectory(at: cliDir.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        let staging = cliDir.deletingLastPathComponent()
            .appendingPathComponent("cli.new", isDirectory: true)
        if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
        defer { try? fm.removeItem(at: staging) }

        var engines: [EngineRelease] = []
        if cliCurrent, let have {
            // Only engines can move. Look before copying anything.
            let upgrades = await engineUpgrades(for: cliDir, log: log)
            guard !upgrades.isEmpty else {
                log("Already up to date (\(have)).")
                return
            }
            try fm.copyItem(at: cliDir, to: staging)
            engines = await install(upgrades, into: staging, work: work, log: log)
            guard !engines.isEmpty else { return }
        } else {
            guard let rec = doc.versions[latest] else {
                throw UpdateError.registry("version \(latest) not in document")
            }
            let pkgDir = try await fetchTarball(rec.dist, into: work.appendingPathComponent("viaduct"), log: log)
            let builtDist = pkgDir.appendingPathComponent("dist")
            guard fm.fileExists(atPath: builtDist.appendingPathComponent("cli.js").path) else {
                throw UpdateError.extract("package/dist/cli.js missing in tarball")
            }
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try fm.copyItem(at: builtDist, to: staging.appendingPathComponent("dist"))
            let pkgJSON = pkgDir.appendingPathComponent("package.json")
            if fm.fileExists(atPath: pkgJSON.path) {
                try fm.copyItem(at: pkgJSON, to: staging.appendingPathComponent("package.json"))
            }
            try latest.write(to: staging.appendingPathComponent("version.txt"),
                             atomically: true, encoding: .utf8)
            // The new CLI starts on its bundled engines. Keep any engine the old
            // install already had that the new range still allows, so a failed
            // fetch below never moves an engine backwards, then look for newer.
            carryOverEngines(into: staging)
            let upgrades = await engineUpgrades(for: staging, log: log)
            engines = await install(upgrades, into: staging, work: work, log: log)
        }

        // Atomically swap into Application Support.
        log(firstInstall ? "Installing…" : "Installing update…")
        if fm.fileExists(atPath: cliDir.path) { try fm.removeItem(at: cliDir) }
        try fm.moveItem(at: staging, to: cliDir)

        if !cliCurrent { log(firstInstall ? "Installed \(latest)." : "Updated to \(latest).") }
        for e in engines { log("Updated \(e.engine) to \(e.version).") }
    }

    /// Download `dist.tarball` into `work`, check it against the registry's
    /// integrity and unpack it. Returns the tarball's `package/` folder.
    private func fetchTarball(_ dist: VersionDist, into work: URL,
                              log: @escaping (String) -> Void) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        log("Downloading \(dist.tarball)…")
        guard let tarURL = URL(string: dist.tarball) else {
            throw UpdateError.download("bad tarball URL")
        }
        let (tmpFile, resp) = try await session.download(from: tarURL)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.download("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let tarball = work.appendingPathComponent("pkg.tgz")
        try fm.moveItem(at: tmpFile, to: tarball)

        // Verify the tarball against the registry's `integrity` (sha512-<base64>)
        // before touching it. npm serves package docs and tarballs from separate
        // paths; matching the hash closes tarball-swap / cache-poisoning where the
        // JSON doc is authentic but the .tgz is not. (Full-response MITM that also
        // rewrites `integrity` is out of scope — TLS is the defense there.)
        try Self.verifyIntegrity(fileAt: tarball, expected: dist.integrity)

        // npm tarballs unpack under a top-level `package/` dir.
        log("Extracting…")
        try runProcess("/usr/bin/tar", ["xzf", tarball.path, "-C", work.path], log: log)
        return work.appendingPathComponent("package")
    }

    // MARK: - Engines

    /// An engine release newer than the one a CLI tree runs.
    private struct EngineRelease {
        let engine: String
        let version: String
        let dist: VersionDist
    }

    private struct Manifest: Decodable {
        let version: String?
        let optionalDependencies: [String: String]?
    }

    private static func manifest(in dir: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("package.json")) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    /// Version of `engine` ("aqueduct", "lavaduct") the installed CLI runs: its
    /// `node_modules` copy when the CLI would pick it, otherwise the copy bundled
    /// in `dist/engines/`. Nil before the CLI is installed, or for a CLI that
    /// doesn't use that engine. Gates on engine behaviour go through this;
    /// gates on the CLI's own flags stay on `installedVersion`.
    func engineVersion(_ engine: String) -> String? {
        Self.engineVersion(engine, in: cliDir)
    }

    private static func engineVersion(_ engine: String, in dir: URL) -> String? {
        usableEngine(at: engineDir(engine, in: dir), range: engineRanges(in: dir)[engine])
            ?? manifest(in: dir.appendingPathComponent("dist/engines/\(engine)", isDirectory: true))?.version
    }

    /// Where the CLI in `dir` looks for its updated `engine`.
    static func engineDir(_ engine: String, in dir: URL) -> URL {
        dir.appendingPathComponent("node_modules/@magicelk235/\(engine)", isDirectory: true)
    }

    /// Engine name → caret range, from the `@magicelk235/*` entries of the CLI's
    /// `optionalDependencies`. Empty for CLIs older than the engine split.
    static func engineRanges(in dir: URL) -> [String: String] {
        var ranges: [String: String] = [:]
        for (name, range) in manifest(in: dir)?.optionalDependencies ?? [:] where name.hasPrefix(engineScope) {
            ranges[String(name.dropFirst(engineScope.count))] = range
        }
        return ranges
    }

    /// The version of the engine copy at `root` if the CLI would run it: the
    /// version is inside `range` and `dist/cli.js` exists. The CLI's own rule.
    private static func usableEngine(at root: URL, range: String?) -> String? {
        guard let range = range.flatMap(CaretRange.init),
              let version = manifest(in: root)?.version, range.contains(version),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("dist/cli.js").path)
        else { return nil }
        return version
    }

    /// The newest in-range release of `engine` if it beats `current`. Nil for a
    /// range this doesn't parse (the bundled copy runs) or nothing newer.
    private func engineUpgrade(_ engine: String, range: String,
                               over current: String?) async throws -> EngineRelease? {
        guard let caret = CaretRange(range) else { return nil }
        let doc = try await fetchPackageDoc(Self.engineScope + engine)
        guard let best = Self.newest(in: caret, latest: doc.distTags.latest, versions: Array(doc.versions.keys)),
              current.map({ Self.semverLess($0, best) }) ?? true,
              let rec = doc.versions[best] else { return nil }
        return EngineRelease(engine: engine, version: best, dist: rec.dist)
    }

    /// Every engine of the CLI tree in `dir` that has a newer in-range release.
    /// An engine whose check fails is logged and left where it is.
    private func engineUpgrades(for dir: URL, log: @escaping (String) -> Void) async -> [EngineRelease] {
        var upgrades: [EngineRelease] = []
        for (engine, range) in Self.engineRanges(in: dir).sorted(by: { $0.key < $1.key }) {
            let current = Self.engineVersion(engine, in: dir)
            do {
                if let up = try await engineUpgrade(engine, range: range, over: current) { upgrades.append(up) }
            } catch {
                log("Couldn't check \(engine) for updates (\(error.localizedDescription)); keeping \(current ?? "the bundled copy").")
            }
        }
        return upgrades
    }

    /// Put each release into `staging`'s `node_modules`. One that fails to
    /// download or doesn't look like the engine is logged and skipped, leaving
    /// whatever copy `staging` already runs. Returns the ones that landed.
    private func install(_ upgrades: [EngineRelease], into staging: URL, work: URL,
                         log: @escaping (String) -> Void) async -> [EngineRelease] {
        let fm = FileManager.default
        var installed: [EngineRelease] = []
        for up in upgrades {
            do {
                let pkgDir = try await fetchTarball(up.dist, into: work.appendingPathComponent(up.engine), log: log)
                guard Self.manifest(in: pkgDir)?.version == up.version,
                      fm.fileExists(atPath: pkgDir.appendingPathComponent("dist/cli.js").path) else {
                    throw UpdateError.extract("\(up.engine) \(up.version) tarball has no package.json for that version or no dist/cli.js")
                }
                let target = Self.engineDir(up.engine, in: staging)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.moveItem(at: pkgDir, to: target)
                installed.append(up)
            } catch {
                log("Couldn't update \(up.engine) to \(up.version) (\(error.localizedDescription)); keeping \(Self.engineVersion(up.engine, in: staging) ?? "the bundled copy").")
            }
        }
        return installed
    }

    /// Copy the installed CLI's engines into a freshly staged CLI where the new
    /// CLI's range still allows them and they're newer than its bundled copy.
    private func carryOverEngines(into staging: URL) {
        let fm = FileManager.default
        for (engine, range) in Self.engineRanges(in: staging) {
            let old = Self.engineDir(engine, in: cliDir)
            guard let version = Self.usableEngine(at: old, range: range),
                  Self.engineVersion(engine, in: staging).map({ Self.semverLess($0, version) }) ?? true
            else { continue }
            let target = Self.engineDir(engine, in: staging)
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: old, to: target)
        }
    }

    /// npm's caret rule, without prereleases, matching viaduct-cli's
    /// `src/engine.js`: ^1.2.3 is >=1.2.3 <2.0.0, ^0.1.3 is >=0.1.3 <0.2.0 and
    /// ^0.0.3 is only 0.0.3. Any other range syntax doesn't parse.
    struct CaretRange: Equatable {
        let major: Int
        let minor: Int
        let patch: Int

        init?(_ range: String) {
            guard range.hasPrefix("^"), let v = Self.release(String(range.dropFirst())) else { return nil }
            major = v.0
            minor = v.1
            patch = v.2
        }

        func contains(_ version: String) -> Bool {
            guard let (a, b, c) = Self.release(version) else { return false }
            if major > 0 { return a == major && (b, c) >= (minor, patch) }
            if minor > 0 { return a == 0 && b == minor && c >= patch }
            return a == 0 && b == 0 && c == patch
        }

        /// "X.Y.Z" in plain digits. Prereleases and build metadata are nil.
        static func release(_ version: String) -> (Int, Int, Int)? {
            let parts = version.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3,
                  parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } })
            else { return nil }
            let n = parts.compactMap { Int($0) }
            guard n.count == 3 else { return nil }
            return (n[0], n[1], n[2])
        }
    }

    /// The release to install for `range`: `latest` when the range allows it,
    /// so a version waiting on `next` is never picked over it; otherwise (an
    /// engine major moved `latest` past the range) the highest in-range release.
    static func newest(in range: CaretRange, latest: String?, versions: [String]) -> String? {
        if let latest, range.contains(latest) { return latest }
        return versions.filter(range.contains).max(by: semverLess)
    }

    // MARK: - Integrity check

    /// Throw unless the SHA-512 of `fileAt` matches npm's `sha512-<base64>` string.
    static func verifyIntegrity(fileAt url: URL, expected: String) throws {
        guard let b64 = expected.split(separator: "-", maxSplits: 1).last.map(String.init),
              expected.hasPrefix("sha512-"),
              let expectedDigest = Data(base64Encoded: b64) else {
            throw UpdateError.download("unrecognized integrity: \(expected)")
        }
        let data = try Data(contentsOf: url)   // tarball is a few hundred KB
        let actual = Data(SHA512.hash(data: data))
        guard actual == expectedDigest else {
            throw UpdateError.download("tarball integrity mismatch, refusing to install")
        }
    }

    // MARK: - Semver compare (a < b)

    static func semverLess(_ a: String, _ b: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: "-")[0]          // drop prerelease
                .split(separator: ".")
                .map { Int($0) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    // MARK: - Process helper (synchronous, streams lines)

    private func runProcess(_ launchPath: String,
                            _ args: [String],
                            cwd: URL? = nil,
                            log: @escaping (String) -> Void) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { fh in
            let d = fh.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
                let t = String(line)
                if !t.isEmpty { log(t) }
            }
        }
        try p.run()
        p.waitUntilExit()
        handle.readabilityHandler = nil
        if p.terminationStatus != 0 {
            throw UpdateError.extract("`\(launchPath)` exited \(p.terminationStatus)")
        }
    }
}
