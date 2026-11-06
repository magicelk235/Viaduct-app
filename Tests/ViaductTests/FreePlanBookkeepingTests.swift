@testable import Viaduct
import XCTest

@MainActor
final class FreePlanBookkeepingTests: XCTestCase {
    private let now = LicenseFixtures.now

    func testKeepingFreeExtensionsTouchesOnlyMatchingRecords() {
        let history = ConversionHistory(defaults: TestDefaults.make())
        for name in ["Kept", "Swept"] {
            history.add(browser: .safari, name: name, sourcePath: "/tmp/\(name)", appName: name, installedPath: nil,
                        adHoc: false, iconData: nil,
                        freeRemovesAt: now.addingTimeInterval(7 * 86_400))
        }
        history.keepFreeExtensions(where: { $0.name == "Kept" })
        XCTAssertNil(history.records.first { $0.name == "Kept" }?.freeRemovesAt)
        XCTAssertNotNil(history.records.first { $0.name == "Swept" }?.freeRemovesAt)
    }

    func testLoginItemFollowsUpdatableRecordsAndPendingRemovals() {
        let store = ConversionRecord(name: "Store", sourcePath: "/tmp/s", date: now, storeId: "abcdefghijklmnopabcdefghijklmnop")
        let local = ConversionRecord(name: "Local", sourcePath: "/tmp/l", date: now)
        let pending = ConversionRecord(name: "Free", sourcePath: "/tmp/f", date: now, freeRemovesAt: now)
        XCTAssertTrue(ConverterViewModel.wantsLoginItem(autoUpdate: true, records: [store], entitlements: LicenseTier.safari.entitlements))
        XCTAssertFalse(ConverterViewModel.wantsLoginItem(autoUpdate: true, records: [store], entitlements: LicenseTier.firefox.entitlements))
        XCTAssertFalse(ConverterViewModel.wantsLoginItem(autoUpdate: false, records: [store], entitlements: .mixed))
        XCTAssertFalse(ConverterViewModel.wantsLoginItem(autoUpdate: true, records: [local], entitlements: .mixed))
        XCTAssertTrue(ConverterViewModel.wantsLoginItem(autoUpdate: false, records: [pending], entitlements: .none))
    }

    func testWeeklyUpdatesUnlockWithAnyLicense() {
        XCTAssertTrue(ExtensionUpdater.isUnlocked(by: .mixed))
        XCTAssertTrue(ExtensionUpdater.isUnlocked(by: LicenseTier.safari.entitlements))
        XCTAssertTrue(ExtensionUpdater.isUnlocked(by: LicenseTier.firefox.entitlements))
        XCTAssertFalse(ExtensionUpdater.isUnlocked(by: .none))
    }

    func testSafariLicenseLeavesFirefoxStoreInstallsAlone() {
        var rec = ConversionRecord(name: "Store", sourcePath: "/tmp/s", date: now, storeId: "abcdefghijklmnopabcdefghijklmnop")
        XCTAssertTrue(ExtensionUpdater.covers(rec, entitlements: LicenseTier.safari.entitlements))
        rec.browser = .firefox
        XCTAssertFalse(ExtensionUpdater.covers(rec, entitlements: LicenseTier.safari.entitlements))
    }
}
