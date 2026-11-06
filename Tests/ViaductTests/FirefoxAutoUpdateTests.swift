import XCTest
@testable import Viaduct

@MainActor
final class FirefoxAutoUpdateTests: XCTestCase {
    private let P1 = "/tmp/p/default-release"
    private let storeId = "abcdefghijklmnopabcdefghijklmnop"
    private let appName = "ViaductTests-\(UUID())"
    private let firefox = FirefoxFixtures.install()
    /// Stands in for ~/Library/Caches/Viaduct/firefox.
    private let root = TempDir.make()
    private lazy var defaults = TestDefaults.make(name)
    private lazy var persist = FakePersist()
    private lazy var addons = FirefoxAddons(persist: persist, agent: FakeAgent(status: .enabled), defaults: defaults)
    private lazy var history = ConversionHistory(defaults: defaults, firefox: addons)

    private var output: URL { FirefoxConversion.outputDir(appName: appName, root: root) }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// A record as history keeps it, looked up by its app name.
    private func record(_ browser: Browser, name: String, storeId: String?) -> ConversionRecord {
        history.add(browser: browser, name: name, sourcePath: "/tmp/\(name).crx", appName: name, installedPath: nil,
                    adHoc: false, iconData: nil, storeId: storeId,
                    addonId: browser == .firefox ? "\(name)@viaduct" : nil,
                    profilePath: browser == .firefox ? P1 : nil)
        return history.records.first { $0.resolvedAppName == name }!
    }

    private var firefoxStoreRec: ConversionRecord { record(.firefox, name: "Firefox Store", storeId: storeId) }
    private var firefoxLocalRec: ConversionRecord { record(.firefox, name: "Firefox Local", storeId: nil) }
    private var safariStoreRec: ConversionRecord { record(.safari, name: "Safari Store", storeId: storeId) }

    /// What a good conversion leaves: staged_extension/manifest.json with a gecko id.
    private func writeStagedManifest(in dir: URL) {
        let staged = dir.appendingPathComponent("staged_extension", isDirectory: true)
        try! FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let manifest = #"{"manifest_version": 2, "browser_specific_settings": {"gecko": {"id": "dr@lavaduct"}}}"#
        try! Data(manifest.utf8).write(to: staged.appendingPathComponent("manifest.json"))
    }

    func test_coversFollowsEachRecordsBrowser() {
        let ff = Entitlements(tiers: [.firefox]), sf = Entitlements(tiers: [.safari])
        let firefoxStore = firefoxStoreRec, firefoxLocal = firefoxLocalRec, safariStore = safariStoreRec
        XCTAssertTrue(ExtensionUpdater.covers(firefoxStore, entitlements: ff))
        XCTAssertFalse(ExtensionUpdater.covers(safariStore, entitlements: ff))
        XCTAssertTrue(ExtensionUpdater.covers(safariStore, entitlements: sf))
        XCTAssertFalse(ExtensionUpdater.covers(firefoxStore, entitlements: sf))
        XCTAssertTrue(ExtensionUpdater.covers(firefoxStore, entitlements: .mixed))
        XCTAssertFalse(ExtensionUpdater.covers(firefoxLocal, entitlements: .mixed))
    }

    func test_anyLicenseUnlocksTheToggle() {
        XCTAssertFalse(ExtensionUpdater.isUnlocked(by: .none))
        XCTAssertTrue(ExtensionUpdater.isUnlocked(by: Entitlements(tiers: [.firefox])))
        XCTAssertTrue(ExtensionUpdater.isUnlocked(by: Entitlements(tiers: [.safari])))
        XCTAssertTrue(ExtensionUpdater.isUnlocked(by: .mixed))
    }

    func test_loginItemStaysForEntitledFirefoxStoreInstalls() {
        let rec = firefoxStoreRec
        XCTAssertTrue(ConverterViewModel.wantsLoginItem(autoUpdate: true, records: [rec], entitlements: Entitlements(tiers: [.firefox])))
        XCTAssertFalse(ConverterViewModel.wantsLoginItem(autoUpdate: true, records: [rec], entitlements: Entitlements(tiers: [.safari])))
    }

    func test_firefoxRebuildNeverStartsOrRestartsFirefox() async throws {
        persist.installResult = .success(FirefoxFixtures.result(id: "dr@lavaduct", profilePath: P1, pending: false))
        var ran: [[String]] = []
        let result = try await FirefoxConversion.run(input: "/tmp/x.crx", appName: appName, firefox: firefox, profile: P1,
                                                     addons: addons, root: root) { args in
            ran.append(args)
            self.writeStagedManifest(in: self.output)
            return 0
        }
        XCTAssertEqual(result.id, "dr@lavaduct")
        XCTAssertEqual(ran, [FirefoxConversion.convertArgs(input: "/tmp/x.crx", outputDir: output)])
        let call = try XCTUnwrap(persist.installs.last)
        XCTAssertEqual(persist.installs.count, 1)
        XCTAssertEqual(call.staged.path, output.appendingPathComponent("staged_extension").path)
        XCTAssertEqual(call.profile, P1)
        XCTAssertEqual(call.firefox, "/Applications/Firefox.app")
        XCTAssertFalse(call.restart)
        XCTAssertFalse(call.launch)
    }

    func test_firefoxRebuildNeedsAStagedManifest() async {
        writeStagedManifest(in: output)   // left over from an earlier run
        // The CLI "succeeds" but stages nothing.
        await XCTAssertThrowsErrorAsync(
            try await FirefoxConversion.run(input: "/tmp/x.crx", appName: appName, firefox: firefox, profile: P1,
                                            addons: addons, root: root) { _ in 0 }
        ) { error in
            XCTAssertEqual(error as? FirefoxConversionError, .nothingStaged)
        }
        XCTAssertTrue(persist.installs.isEmpty)
        XCTAssertNil(FirefoxConversion.stagedExtension(in: output))
    }

    func test_firefoxRebuildStopsOnCLIError() async {
        await XCTAssertThrowsErrorAsync(
            try await FirefoxConversion.run(input: "/tmp/x.crx", appName: appName, firefox: firefox, profile: P1,
                                            addons: addons, root: root) { _ in
                self.writeStagedManifest(in: self.output)   // whatever it left, the exit code decides
                return 1
            }
        ) { error in
            XCTAssertEqual(error as? FirefoxConversionError, .cliFailed(1))
        }
        XCTAssertTrue(persist.installs.isEmpty)
    }
}
