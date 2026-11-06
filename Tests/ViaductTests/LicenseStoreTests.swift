@testable import Viaduct
import XCTest

final class LicenseStoreTests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!
    private var file: URL { dir.appendingPathComponent("licenses.json") }
    private var legacyFile: URL { dir.appendingPathComponent("license") }
    private let stamp = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() {
        dir = TempDir.make()
        defaults = TestDefaults.make(name)
    }

    private func store(keychain: String? = nil) -> LicenseStore {
        LicenseStore(file: file, defaults: defaults, legacyKeychainKey: { keychain })
    }

    func testOldKeyFileBecomesAMixedGumroadKey() throws {
        try "ABCD1234-EF567890-12345678-9ABCDEF0\n".write(to: legacyFile, atomically: true, encoding: .utf8)
        defaults.set(stamp.timeIntervalSince1970, forKey: "license-last-valid")
        XCTAssertEqual(store().load(), [StoredKey(provider: .gumroad, key: "ABCD1234-EF567890-12345678-9ABCDEF0",
                                                  activationId: nil, tier: .mixed, lastValidated: stamp)])
    }

    func testOldFileIsNeverTouched() throws {
        try "OLD-KEY".write(to: legacyFile, atomically: true, encoding: .utf8)
        defaults.set(stamp.timeIntervalSince1970, forKey: "license-last-valid")
        let migrated = store().load()
        store().save(migrated)
        XCTAssertEqual(store().load(), migrated)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).hasPrefix("["))
        XCTAssertEqual(try String(contentsOf: legacyFile, encoding: .utf8), "OLD-KEY", "1.4.0 still finds its key")
        XCTAssertEqual(defaults.double(forKey: "license-last-valid"), stamp.timeIntervalSince1970)
    }

    func testRemovedKeysStayRemoved() throws {
        try "OLD-KEY".write(to: legacyFile, atomically: true, encoding: .utf8)
        store().save([])
        XCTAssertEqual(store().load(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyFile.path))
    }

    func testKeychainKeyMigratesWhenThereIsNoFile() {
        XCTAssertEqual(store(keychain: "KEYCHAIN-KEY").load(),
                       [StoredKey(provider: .gumroad, key: "KEYCHAIN-KEY", activationId: nil, tier: .mixed,
                                  lastValidated: Date(timeIntervalSince1970: 0))])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "loading never writes")
    }

    func testPolarKeysRoundTrip() {
        let keys = [StoredKey(provider: .polar, key: "S", activationId: "act-1", tier: .safari, lastValidated: stamp),
                    StoredKey(provider: .polar, key: "F", activationId: "act-2", tier: .firefox, lastValidated: stamp)]
        store().save(keys)
        XCTAssertEqual(store().load(), keys)
    }

    func testUnreadableKeyListIsLeftAlone() throws {
        let broken = #"[{"provider":"polar","key":"#
        try broken.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(store().load(), [])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), broken)
    }

    func testSavingOverAnUnreadableKeyListMovesItAsideFirst() throws {
        let broken = #"[{"provider":"polar","key":"#
        try broken.write(to: file, atomically: true, encoding: .utf8)
        let key = StoredKey(provider: .polar, key: "S", activationId: "act-1", tier: .safari, lastValidated: stamp)
        store().save([key])
        XCTAssertEqual(store().load(), [key])
        let aside = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("licenses.json.unreadable-") }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(aside[0]), encoding: .utf8), broken)
    }

    func testUnreadableKeyListStaysWhenItCantBeMovedAside() throws {
        let broken = #"[{"provider":"polar","key":"#
        try broken.write(to: file, atomically: true, encoding: .utf8)
        // Every name the move could pick over the next minute is taken.
        let second = Int(Date().timeIntervalSince1970)
        for t in second...(second + 60) {
            try Data().write(to: dir.appendingPathComponent("licenses.json.unreadable-\(t)"))
        }
        store().save([StoredKey(provider: .polar, key: "S", activationId: "act-1", tier: .safari, lastValidated: stamp)])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), broken)
    }

    func testNewKeysDontNeedTheOldFile() {
        let key = StoredKey(provider: .polar, key: "S", activationId: "act-1", tier: .safari, lastValidated: stamp)
        store().save([key])
        XCTAssertEqual(store().load(), [key])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile.path))
    }
}
