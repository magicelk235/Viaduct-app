import CryptoKit
import XCTest
@testable import Viaduct

/// Serves canned registry documents and tarballs to the updater's session.
private final class StubRegistry: URLProtocol {
    static var responses: [String: (status: Int, body: Data)] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let (status, body) = Self.responses[url.absoluteString] ?? (404, Data())
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class LogBox { var lines: [String] = [] }

final class CLIUpdaterTests: XCTestCase {
    private var root: URL!
    private var updater: CLIUpdater!
    private var cli: URL { root.appendingPathComponent("Viaduct/cli", isDirectory: true) }
    private let floors = ["@magicelk235/aqueduct": "^1.18.2", "@magicelk235/lavaduct": "^0.1.3"]

    override func setUp() {
        root = TempDir.make()
        StubRegistry.responses = [:]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubRegistry.self]
        updater = CLIUpdater(cliDir: cli, session: URLSession(configuration: config))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        StubRegistry.responses = [:]
    }

    // MARK: - Range resolution

    func testCaretRangeFollowsNpm() throws {
        let one = try XCTUnwrap(CLIUpdater.CaretRange("^1.18.2"))
        XCTAssertTrue(one.contains("1.18.2"))
        XCTAssertTrue(one.contains("1.18.10"))
        XCTAssertTrue(one.contains("1.99.0"))
        XCTAssertFalse(one.contains("1.18.1"))
        XCTAssertFalse(one.contains("1.17.9"))
        XCTAssertFalse(one.contains("2.0.0"))
        XCTAssertFalse(one.contains("1.19.0-beta.1"))

        let zero = try XCTUnwrap(CLIUpdater.CaretRange("^0.1.3"))
        XCTAssertTrue(zero.contains("0.1.3"))
        XCTAssertTrue(zero.contains("0.1.9"))
        XCTAssertFalse(zero.contains("0.1.2"))
        XCTAssertFalse(zero.contains("0.2.0"))
        XCTAssertFalse(zero.contains("1.0.0"))

        let exact = try XCTUnwrap(CLIUpdater.CaretRange("^0.0.3"))
        XCTAssertTrue(exact.contains("0.0.3"))
        XCTAssertFalse(exact.contains("0.0.4"))
    }

    func testOnlyCaretRangesParse() {
        for range in ["~1.18.2", ">=1.18.2", "1.18.2", "^1.18", "^1.18.2-beta", "^v1.18.2", "*", "latest", ""] {
            XCTAssertNil(CLIUpdater.CaretRange(range), range)
        }
    }

    func testNewestTakesLatestWhenTheRangeAllowsIt() throws {
        let range = try XCTUnwrap(CLIUpdater.CaretRange("^1.18.2"))
        // 1.18.4 waits on `next`; latest is the publisher's pick.
        XCTAssertEqual(CLIUpdater.newest(in: range, latest: "1.18.3",
                                         versions: ["1.18.2", "1.18.3", "1.18.4"]), "1.18.3")
        // A major moved latest past the range: highest in-range release, no prereleases.
        XCTAssertEqual(CLIUpdater.newest(in: range, latest: "2.0.0",
                                         versions: ["1.18.2", "1.18.10", "1.19.0-rc.1", "1.9.0", "2.0.0", "0.0.0-stage"]),
                       "1.18.10")
        XCTAssertNil(CLIUpdater.newest(in: range, latest: "2.0.0", versions: ["1.17.0", "2.0.0"]))
    }

    // MARK: - Install, swap and fallback

    func testFirstInstallAddsANewerEngineAndKeepsTheBundledOneOtherwise() async throws {
        try publish("@magicelk235/viaduct", latest: "2.0.0", ["2.0.0": viaduct("2.0.0")])
        try publish("@magicelk235/aqueduct", latest: "1.18.3",
                    ["1.18.2": engine("aqueduct", "1.18.2"), "1.18.3": engine("aqueduct", "1.18.3")])
        try publish("@magicelk235/lavaduct", latest: "0.1.3", ["0.1.3": engine("lavaduct", "0.1.3")])

        let log = try await update()

        XCTAssertEqual(updater.installedVersion, "2.0.0")
        XCTAssertEqual(updater.engineVersion("aqueduct"), "1.18.3")
        XCTAssertEqual(updater.engineVersion("lavaduct"), "0.1.3")
        XCTAssertTrue(exists(CLIUpdater.engineDir("aqueduct", in: cli).appendingPathComponent("dist/cli.js")))
        XCTAssertFalse(exists(CLIUpdater.engineDir("lavaduct", in: cli)), "the bundled lavaduct is already newest")
        XCTAssertTrue(log.contains("Installed 2.0.0."))
        XCTAssertTrue(log.contains("Updated aqueduct to 1.18.3."))
        XCTAssertFalse(log.contains { $0.contains("lavaduct to") })
        XCTAssertFalse(exists(stagingDir))
    }

    func testAnEngineRegistryFailureStillInstallsTheCLI() async throws {
        try publish("@magicelk235/viaduct", latest: "2.0.0", ["2.0.0": viaduct("2.0.0")])
        StubRegistry.responses["https://registry.npmjs.org/@magicelk235%2Faqueduct"] = (500, Data())

        let log = try await update()

        XCTAssertEqual(updater.installedVersion, "2.0.0")
        XCTAssertEqual(updater.engineVersion("aqueduct"), "1.18.2")
        XCTAssertEqual(updater.engineVersion("lavaduct"), "0.1.3")
        XCTAssertFalse(exists(cli.appendingPathComponent("node_modules")))
        XCTAssertTrue(log.contains { $0.hasPrefix("Couldn't check aqueduct for updates") })
    }

    func testATamperedEngineTarballIsSkipped() async throws {
        try publish("@magicelk235/viaduct", latest: "2.0.0", ["2.0.0": viaduct("2.0.0")])
        try publish("@magicelk235/aqueduct", latest: "1.18.3", ["1.18.3": engine("aqueduct", "1.18.3")],
                    corrupt: ["1.18.3"])

        let log = try await update()

        XCTAssertEqual(updater.installedVersion, "2.0.0")
        XCTAssertEqual(updater.engineVersion("aqueduct"), "1.18.2")
        XCTAssertFalse(exists(CLIUpdater.engineDir("aqueduct", in: cli)))
        XCTAssertTrue(log.contains { $0.hasPrefix("Couldn't update aqueduct to 1.18.3") })
    }

    func testATarballOfTheWrongVersionIsSkipped() async throws {
        try publish("@magicelk235/viaduct", latest: "2.0.0", ["2.0.0": viaduct("2.0.0")])
        try publish("@magicelk235/aqueduct", latest: "1.18.3", ["1.18.3": engine("aqueduct", "1.18.9")])

        _ = try await update()

        XCTAssertEqual(updater.engineVersion("aqueduct"), "1.18.2")
        XCTAssertFalse(exists(CLIUpdater.engineDir("aqueduct", in: cli)))
    }

    func testOnlyTheEngineMovesWhenTheCLIIsCurrent() async throws {
        try publish("@magicelk235/viaduct", latest: "2.0.0", ["2.0.0": viaduct("2.0.0")])
        try publish("@magicelk235/aqueduct", latest: "1.18.2", ["1.18.2": engine("aqueduct", "1.18.2")])
        try publish("@magicelk235/lavaduct", latest: "0.1.3", ["0.1.3": engine("lavaduct", "0.1.3")])
        _ = try await update()
        let available = try await updater.updateAvailable()
        XCTAssertFalse(available)
        // Proves the swap kept the installed CLI rather than re-downloading it.
        let marker = cli.appendingPathComponent("dist/marker")
        try Data().write(to: marker)

        try publish("@magicelk235/aqueduct", latest: "1.18.4",
                    ["1.18.2": engine("aqueduct", "1.18.2"), "1.18.4": engine("aqueduct", "1.18.4")])
        let nowAvailable = try await updater.updateAvailable()
        XCTAssertTrue(nowAvailable)
        let log = try await update()

        XCTAssertEqual(updater.installedVersion, "2.0.0")
        XCTAssertEqual(updater.engineVersion("aqueduct"), "1.18.4")
        XCTAssertEqual(updater.engineVersion("lavaduct"), "0.1.3")
        XCTAssertTrue(exists(marker))
        XCTAssertTrue(log.contains("Updated aqueduct to 1.18.4."))
        XCTAssertFalse(log.contains { $0.hasPrefix("Updated to") || $0.hasPrefix("Installed") })
        XCTAssertFalse(exists(stagingDir))
        let after = try await updater.updateAvailable()
        XCTAssertFalse(after)
    }

    func testNothingNewLeavesTheInstallAlone() async throws {
        try publish("@magicelk235/viaduct", latest: "2.0.0", ["2.0.0": viaduct("2.0.0")])
        try publish("@magicelk235/aqueduct", latest: "1.18.3", ["1.18.3": engine("aqueduct", "1.18.3")])
        _ = try await update()
        let marker = cli.appendingPathComponent("dist/marker")
        try Data().write(to: marker)

        let log = try await update()

        XCTAssertTrue(log.contains("Already up to date (2.0.0)."))
        XCTAssertTrue(exists(marker))
        XCTAssertEqual(updater.engineVersion("aqueduct"), "1.18.3")
        XCTAssertFalse(exists(stagingDir))
    }

    func testAFailedEngineDownloadWithACurrentCLIChangesNothing() async throws {
        try publish("@magicelk235/viaduct", latest: "2.0.0", ["2.0.0": viaduct("2.0.0")])
        try publish("@magicelk235/aqueduct", latest: "1.18.3", ["1.18.3": engine("aqueduct", "1.18.3")])
        _ = try await update()

        try publish("@magicelk235/aqueduct", latest: "1.18.4", ["1.18.4": engine("aqueduct", "1.18.4")],
                    corrupt: ["1.18.4"])
        _ = try await update()

        XCTAssertEqual(updater.engineVersion("aqueduct"), "1.18.3")
        XCTAssertFalse(exists(stagingDir))
    }

    func testACLIUpdateKeepsTheInstalledEngineWhenItsFetchFails() async throws {
        try publish("@magicelk235/viaduct", latest: "2.0.0", ["2.0.0": viaduct("2.0.0")])
        try publish("@magicelk235/aqueduct", latest: "1.18.3", ["1.18.3": engine("aqueduct", "1.18.3")])
        _ = try await update()

        try publish("@magicelk235/viaduct", latest: "2.0.1", ["2.0.1": viaduct("2.0.1")])
        StubRegistry.responses["https://registry.npmjs.org/@magicelk235%2Faqueduct"] = (503, Data())
        let log = try await update()

        XCTAssertEqual(updater.installedVersion, "2.0.1")
        XCTAssertEqual(updater.engineVersion("aqueduct"), "1.18.3")
        XCTAssertTrue(log.contains("Updated to 2.0.1."))
    }

    func testACLIUpdateDropsAnEngineItsRangeNoLongerAllows() async throws {
        try publish("@magicelk235/viaduct", latest: "2.0.0", ["2.0.0": viaduct("2.0.0")])
        try publish("@magicelk235/aqueduct", latest: "1.18.3", ["1.18.3": engine("aqueduct", "1.18.3")])
        _ = try await update()
        XCTAssertEqual(updater.engineVersion("aqueduct"), "1.18.3")

        var ranges = floors
        ranges["@magicelk235/aqueduct"] = "^2.0.0"
        try publish("@magicelk235/viaduct", latest: "3.0.0",
                    ["3.0.0": viaduct("3.0.0", aqueduct: "2.0.0", ranges: ranges)])
        _ = try await update()

        XCTAssertEqual(updater.installedVersion, "3.0.0")
        XCTAssertEqual(updater.engineVersion("aqueduct"), "2.0.0")
        XCTAssertFalse(exists(CLIUpdater.engineDir("aqueduct", in: cli)))
    }

    func testAnUnparseableRangeLeavesTheBundledEngine() async throws {
        var ranges = floors
        ranges["@magicelk235/aqueduct"] = "~1.18.2"
        try publish("@magicelk235/viaduct", latest: "2.0.0", ["2.0.0": viaduct("2.0.0", ranges: ranges)])
        try publish("@magicelk235/aqueduct", latest: "1.18.3", ["1.18.3": engine("aqueduct", "1.18.3")])

        _ = try await update()

        XCTAssertEqual(updater.installedVersion, "2.0.0")
        XCTAssertEqual(updater.engineVersion("aqueduct"), "1.18.2")
        XCTAssertFalse(exists(CLIUpdater.engineDir("aqueduct", in: cli)))
    }

    func testACLIWithoutEngineRangesUpdatesAsBefore() async throws {
        try publish("@magicelk235/viaduct", latest: "1.11.9", ["1.11.9": tarball([
            "package.json": #"{"name":"@magicelk235/viaduct","version":"1.11.9"}"#,
            "dist/cli.js": "",
        ])])

        let log = try await update()

        XCTAssertEqual(updater.installedVersion, "1.11.9")
        XCTAssertNil(updater.engineVersion("aqueduct"))
        XCTAssertTrue(log.contains("Installed 1.11.9."))
    }

    // MARK: - engineVersion

    func testEngineVersionFollowsTheCLIsOwnPick() async throws {
        XCTAssertNil(updater.engineVersion("aqueduct"))
        try publish("@magicelk235/viaduct", latest: "2.0.0", ["2.0.0": viaduct("2.0.0")])
        _ = try await update()
        let copy = CLIUpdater.engineDir("aqueduct", in: cli)

        // Out of range: the CLI runs its bundled copy.
        try write(copy, ["package.json": #"{"version":"2.0.0"}"#, "dist/cli.js": ""])
        XCTAssertEqual(updater.engineVersion("aqueduct"), "1.18.2")
        // In range but incomplete: same.
        try FileManager.default.removeItem(at: copy)
        try write(copy, ["package.json": #"{"version":"1.18.5"}"#])
        XCTAssertEqual(updater.engineVersion("aqueduct"), "1.18.2")
        // In range and complete: that one.
        try write(copy, ["dist/cli.js": ""])
        XCTAssertEqual(updater.engineVersion("aqueduct"), "1.18.5")
    }

    // MARK: - Fixtures

    private var stagingDir: URL { cli.deletingLastPathComponent().appendingPathComponent("cli.new") }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Runs an update and returns its log lines once they've all reached main.
    private func update() async throws -> [String] {
        let box = LogBox()
        try await updater.update(rawLog: { box.lines.append($0) })
        await MainActor.run {}
        return box.lines
    }

    private func write(_ dir: URL, _ files: [String: String]) throws {
        for (path, contents) in files {
            let file = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: file)
        }
    }

    /// An npm-style tarball: `files` under a top-level `package/`.
    private func tarball(_ files: [String: String]) throws -> Data {
        let dir = TempDir.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(dir.appendingPathComponent("package"), files)
        let out = dir.appendingPathComponent("pkg.tgz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["czf", out.path, "-C", dir.path, "package"]
        try tar.run()
        tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0)
        return try Data(contentsOf: out)
    }

    private func viaduct(_ version: String, aqueduct: String = "1.18.2", lavaduct: String = "0.1.3",
                         ranges: [String: String]? = nil) throws -> Data {
        let manifest: [String: Any] = ["name": "@magicelk235/viaduct", "version": version,
                                       "optionalDependencies": ranges ?? floors]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: manifest), as: UTF8.self)
        return try tarball([
            "package.json": json,
            "dist/cli.js": "",
            "dist/engines/aqueduct/package.json": #"{"version":"\#(aqueduct)"}"#,
            "dist/engines/aqueduct/dist/cli.js": "",
            "dist/engines/lavaduct/package.json": #"{"version":"\#(lavaduct)"}"#,
            "dist/engines/lavaduct/dist/cli.js": "",
        ])
    }

    private func engine(_ name: String, _ version: String) throws -> Data {
        try tarball([
            "package.json": #"{"name":"@magicelk235/\#(name)","version":"\#(version)"}"#,
            "dist/cli.js": "",
        ])
    }

    /// Puts `name` on the stub registry with these versions' tarballs. A
    /// version in `corrupt` gets an integrity that doesn't match its tarball.
    private func publish(_ name: String, latest: String, _ versions: [String: Data],
                         corrupt: Set<String> = []) throws {
        var records: [String: Any] = [:]
        for (version, tgz) in versions {
            let url = "https://registry.test/\(name)/-/\(version).tgz"
            StubRegistry.responses[url] = (200, tgz)
            let hashed = corrupt.contains(version) ? Data("tampered".utf8) : tgz
            records[version] = ["dist": ["tarball": url,
                                         "integrity": "sha512-" + Data(SHA512.hash(data: hashed)).base64EncodedString()]]
        }
        let doc: [String: Any] = ["dist-tags": ["latest": latest], "versions": records]
        let encoded = name.replacingOccurrences(of: "/", with: "%2F")
        StubRegistry.responses["https://registry.npmjs.org/\(encoded)"] =
            (200, try JSONSerialization.data(withJSONObject: doc))
    }
}
