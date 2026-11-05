import XCTest
@testable import Viaduct

final class FirefoxConversionTests: XCTestCase {
    func testConvertArgumentsFollowTheSpec() {
        let out = URL(fileURLWithPath: "/Users/me/Library/Caches/Viaduct/firefox/Dark Reader")
        XCTAssertEqual(FirefoxConversion.convertArgs(input: "/Users/me/Downloads/Dark Reader.crx", outputDir: out),
                       ["/Users/me/Downloads/Dark Reader.crx", "--browser", "firefox", "-o", out.path, "--native-hosts", "--force"])
    }

    func testOutputDirIsOneSafeFolderPerName() {
        let root = TempDir.make()
        XCTAssertEqual(FirefoxConversion.outputDir(appName: "Dark Reader", root: root).path, root.appendingPathComponent("Dark Reader").path)
        XCTAssertEqual(FirefoxConversion.outputDir(appName: "Save/Share: Pro", root: root).lastPathComponent, "Save-Share- Pro")
        XCTAssertEqual(FirefoxConversion.outputDir(appName: "..", root: root).lastPathComponent, "extension")
        XCTAssertEqual(FirefoxConversion.outputDir(appName: "  ", root: root).lastPathComponent, "extension")
        XCTAssertTrue(FirefoxConversion.cachesRoot.path.hasSuffix("Library/Caches/Viaduct/firefox"))
    }

    func testOnlyAFreshManifestCountsAsStagedOutput() throws {
        let out = TempDir.make()
        XCTAssertNil(FirefoxConversion.stagedExtension(in: out))
        let staged = out.appendingPathComponent("staged_extension")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: staged.appendingPathComponent("manifest.json"))
        XCTAssertEqual(FirefoxConversion.stagedExtension(in: out)?.path, staged.path)
        FirefoxConversion.clearOutput(out)   // what a new run does first
        XCTAssertNil(FirefoxConversion.stagedExtension(in: out))
    }

    func testLocatorPrefersReleaseThenDeveloperEditionThenNightly() {
        let apps = ["org.mozilla.firefoxdeveloperedition": URL(fileURLWithPath: "/Applications/Firefox Developer Edition.app"),
                    "org.mozilla.nightly": URL(fileURLWithPath: "/Applications/Firefox Nightly.app")]
        XCTAssertEqual(FirefoxLocator.find(lookup: { apps[$0] })?.bundleID, "org.mozilla.firefoxdeveloperedition")
        XCTAssertEqual(FirefoxLocator.find(lookup: { $0 == "org.mozilla.firefox" ? URL(fileURLWithPath: "/Applications/Firefox.app") : apps[$0] })?.displayName, "Firefox")
        XCTAssertNil(FirefoxLocator.find(lookup: { _ in nil }))
    }
}
