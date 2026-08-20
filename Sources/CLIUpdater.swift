import Foundation
import CryptoKit

/// Keeps the viaduct CLI current by pulling the published npm package.
/// npm ships a prebuilt `dist/`, so updating is download + extract + atomic
/// swap into Application Support (which CLIRunner prefers) — no build step.
final class CLIUpdater {
    static let shared = CLIUpdater()

    private let pkg = "@magicelk235/viaduct"

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

    /// Version of the CLI copy that will actually run, so the update check
    /// compares against the copy `CLIRunner` resolves rather than assuming
    /// Application Support always wins.
    var installedVersion: String? {
        CLIRunner.resolveCLIDir().flatMap { CLIRunner.cliVersion(at: $0) }
    }

    private struct DistTags: Decodable { let latest: String }
    private struct VersionDist: Decodable { let tarball: String; let integrity: String }
    private struct PackageDoc: Decodable {
        let distTags: DistTags
        let versions: [String: VersionRecord]
        enum CodingKeys: String, CodingKey { case distTags = "dist-tags", versions }
    }
    private struct VersionRecord: Decodable { let dist: VersionDist }

    /// Fetch the npm package document.
    private func fetchPackageDoc() async throws -> PackageDoc {
        // Scoped names need the "/" percent-encoded for the registry path.
        let encoded = pkg.replacingOccurrences(of: "/", with: "%2F")
        let url = URL(string: "https://registry.npmjs.org/\(encoded)")!
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("ViaductApp", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.registry("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        do { return try JSONDecoder().decode(PackageDoc.self, from: data) }
        catch { throw UpdateError.registry("bad JSON: \(error.localizedDescription)") }
    }

    /// Latest published version string.
    func latestVersion() async throws -> String {
        try await fetchPackageDoc().distTags.latest
    }

    /// True if a newer CLI is available (semver-aware).
    func updateAvailable() async throws -> Bool {
        let latest = try await latestVersion()
        guard let have = installedVersion else { return true }
        return Self.semverLess(have, latest)
    }

    /// Download + extract the latest npm tarball into Application Support. `log` streams progress.
    /// `log` is always invoked on the main thread so callers can mutate `@Published` state safely.
    func update(rawLog: @escaping (String) -> Void) async throws {
        // Hop every log call to main here so the 6 inline calls below
        // and runProcess's handler share one main-thread guarantee.
        let log: (String) -> Void = { line in DispatchQueue.main.async { rawLog(line) } }
        let doc = try await fetchPackageDoc()
        let latest = doc.distTags.latest
        log("Latest published: \(latest)")
        if let have = installedVersion, !Self.semverLess(have, latest) {
            log("Already up to date (\(have)).")
            return
        }
        guard let rec = doc.versions[latest] else {
            throw UpdateError.registry("version \(latest) not in document")
        }

        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("c2s-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // 1. Download tarball.
        log("Downloading \(rec.dist.tarball)…")
        guard let tarURL = URL(string: rec.dist.tarball) else {
            throw UpdateError.download("bad tarball URL")
        }
        let (tmpFile, resp) = try await URLSession.shared.download(from: tarURL)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.download("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let tarball = work.appendingPathComponent("pkg.tgz")
        try fm.moveItem(at: tmpFile, to: tarball)

        // 1b. Verify the tarball against the registry's `integrity` (sha512-<base64>)
        // before touching it. npm serves package docs and tarballs from separate
        // paths; matching the hash closes tarball-swap / cache-poisoning where the
        // JSON doc is authentic but the .tgz is not. (Full-response MITM that also
        // rewrites `integrity` is out of scope — TLS is the defense there.)
        try Self.verifyIntegrity(fileAt: tarball, expected: rec.dist.integrity)

        // 2. Extract. npm tarballs unpack under a top-level `package/` dir.
        log("Extracting…")
        try runProcess("/usr/bin/tar", ["xzf", tarball.path, "-C", work.path], log: log)
        let pkgDir = work.appendingPathComponent("package")
        let builtDist = pkgDir.appendingPathComponent("dist")
        guard fm.fileExists(atPath: builtDist.appendingPathComponent("cli.js").path) else {
            throw UpdateError.extract("package/dist/cli.js missing in tarball")
        }

        // 3. Atomically swap into Application Support.
        log("Installing update…")
        let target = CLIRunner.supportCLIDir
        try fm.createDirectory(at: target.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent("cli.new", isDirectory: true)
        if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try fm.copyItem(at: builtDist, to: staging.appendingPathComponent("dist"))
        let pkgJSON = pkgDir.appendingPathComponent("package.json")
        if fm.fileExists(atPath: pkgJSON.path) {
            try fm.copyItem(at: pkgJSON, to: staging.appendingPathComponent("package.json"))
        }
        try latest.write(to: staging.appendingPathComponent("version.txt"),
                         atomically: true, encoding: .utf8)

        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: staging, to: target)

        log("Updated to \(latest).")
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
