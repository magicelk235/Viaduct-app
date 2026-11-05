@testable import Viaduct
import XCTest

@MainActor
final class LicenseManagerTests: XCTestCase {
    private let now = LicenseFixtures.now
    private let day: TimeInterval = 86_400

    func testGumroadKeyAloneIsMixed() async {
        let m = await LicenseFixtures.manager(keys: [LicenseFixtures.key(.mixed, provider: .gumroad)])
        XCTAssertEqual(m.entitlements, .mixed)
    }

    func testSafariAndFirefoxKeysMakeMixed() async {
        let m = await LicenseFixtures.manager(keys: [LicenseFixtures.key(.safari), LicenseFixtures.key(.firefox)])
        XCTAssertEqual(m.entitlements, .mixed)
    }

    func testFreeQuotaIsSharedAcrossBrowsers() async {
        let m = await LicenseFixtures.manager()
        m.recordFreeConversion(.safari)
        XCTAssertEqual(m.freeConversionsRemaining, 1)
        XCTAssertTrue(m.canConvert(.firefox))
        m.recordFreeConversion(.firefox)
        XCTAssertFalse(m.canConvert(.safari))
        XCTAssertFalse(m.canConvert(.firefox))
    }

    func testSafariKeyLeavesFirefoxOnTheFreePlan() async {
        let m = await LicenseFixtures.manager(keys: [LicenseFixtures.key(.safari)], freeUsed: 2)
        XCTAssertTrue(m.canConvert(.safari))
        XCTAssertFalse(m.canConvert(.firefox))
        m.recordFreeConversion(.safari)
        XCTAssertEqual(m.freeConversionsUsed, 2, "an unlimited browser spends nothing")
        XCTAssertNil(FreePlan.removalDate(unlimited: m.unlimited(.safari), now: now))
        XCTAssertEqual(FreePlan.removalDate(unlimited: m.unlimited(.firefox), now: now), now.addingTimeInterval(7 * day))
    }

    func testFirefoxKeyLeavesSafariOnTheFreePlan() async {
        let m = await LicenseFixtures.manager(keys: [LicenseFixtures.key(.firefox)], freeUsed: 1)
        m.recordFreeConversion(.firefox)
        XCTAssertEqual(m.freeConversionsRemaining, 1)
        m.recordFreeConversion(.safari)
        XCTAssertFalse(m.canConvert(.safari))
        XCTAssertTrue(m.canConvert(.firefox))
    }

    func testOfflineLaunchKeepsKeysForFourteenDays() async {
        let fresh = LicenseFixtures.key(.safari, validated: now.addingTimeInterval(-13 * day))
        let stale = LicenseFixtures.key(.firefox, validated: now.addingTimeInterval(-15 * day))
        let m = await LicenseFixtures.manager(keys: [fresh, stale])   // no check can connect
        XCTAssertTrue(m.hasLaunchAnswer)
        XCTAssertEqual(m.entitlements, LicenseTier.safari.entitlements)
        XCTAssertEqual(m.keys.map(\.key), [fresh.key, stale.key], "nothing is deleted while offline")
        XCTAssertEqual(m.problem, "Couldn't check your license key for 14 days. Viaduct checks again the next time it opens with an internet connection.")
    }

    func testRejectedKeyIsDroppedAndTheRestStay() async {
        let safari = LicenseFixtures.key(.safari)
        let legacy = LicenseFixtures.key(.mixed, provider: .gumroad)
        let polar = FakePolar()
        polar.validateResults[safari.key] = .failure(.rejected("License key is no longer active."))
        let gumroad = FakeGumroad()
        gumroad.results[legacy.key] = .success(())
        let m = await LicenseFixtures.manager(keys: [safari, legacy], polar: polar, gumroad: gumroad)
        XCTAssertEqual(m.keys.map(\.key), [legacy.key])
        XCTAssertEqual(m.entitlements, .mixed)
        XCTAssertEqual(m.problem, "Your Safari license key no longer works on this Mac. License key is no longer active.")
    }

    func testTheFirstFailingKeyInTheListIsTheProblemShown() async {
        let first = LicenseFixtures.key(.safari)
        let second = LicenseFixtures.key(.firefox)
        let polar = FakePolar()
        polar.validateResults[first.key] = .failure(.rejected("License key is no longer active."))
        polar.validateResults[second.key] = .failure(.unknownKey)
        polar.slowKeys = [first.key]
        let m = await LicenseFixtures.manager(keys: [first, second], polar: polar)
        XCTAssertEqual(m.problem, "Your Safari license key no longer works on this Mac. License key is no longer active.")
    }

    func testGoodCheckRestartsTheGraceAndIsSaved() async {
        let key = LicenseFixtures.key(.safari, validated: now.addingTimeInterval(-10 * day))
        let defaults = TestDefaults.make()
        let store = LicenseStore(file: TempDir.make().appendingPathComponent("licenses.json"), defaults: defaults,
                                 legacyKeychainKey: { nil })
        store.save([key])
        let polar = FakePolar()
        polar.validateResults[key.key] = .success(LicenseFixtures.benefitIds[.safari]!)
        let t = now
        let m = LicenseManager(store: store, polar: polar, gumroad: FakeGumroad(), benefitIds: LicenseFixtures.benefitIds,
                               defaults: defaults, now: { t }, macName: { "Test Mac" })
        await m.validateStoredKeys()
        XCTAssertEqual(store.load().first?.lastValidated, now)
    }

    func testAddingAPolarKeyActivatesThisMac() async throws {
        let polar = FakePolar()
        polar.activateResult = .success(PolarActivation(activationId: "act-9", benefitId: LicenseFixtures.benefitIds[.firefox]!))
        let m = await LicenseFixtures.manager(polar: polar)
        try await m.addKey("  NEW-KEY\n")
        XCTAssertEqual(polar.activatedLabels, ["Test Mac"])
        XCTAssertEqual(m.keys, [StoredKey(provider: .polar, key: "NEW-KEY", activationId: "act-9", tier: .firefox, lastValidated: now)])
        XCTAssertEqual(m.entitlements, LicenseTier.firefox.entitlements)
    }

    func testKeyForAnotherProductGivesItsActivationBack() async {
        let polar = FakePolar()
        polar.activateResult = .success(PolarActivation(activationId: "act-x", benefitId: "another-apps-benefit"))
        let m = await LicenseFixtures.manager(polar: polar)
        await assertThrows(.notForViaduct) { try await m.addKey("OTHER-APP-KEY") }
        XCTAssertEqual(polar.deactivatedActivationIds, ["act-x"])
        XCTAssertTrue(m.keys.isEmpty)
    }

    func testGumroadKeyStillAddsAsMixed() async throws {
        let polar = FakePolar()
        polar.activateResult = .failure(.unknownKey)
        let gumroad = FakeGumroad()
        gumroad.results["ABCD1234-EF567890-12345678-9ABCDEF0"] = .success(())
        let m = await LicenseFixtures.manager(polar: polar, gumroad: gumroad)
        try await m.addKey("ABCD1234-EF567890-12345678-9ABCDEF0")
        XCTAssertEqual(m.keys, [StoredKey(provider: .gumroad, key: "ABCD1234-EF567890-12345678-9ABCDEF0",
                                          activationId: nil, tier: .mixed, lastValidated: now)])
    }

    func testKeyNobodyKnowsIsReportedAsNotFound() async {
        let polar = FakePolar()
        polar.activateResult = .failure(.unknownKey)
        let gumroad = FakeGumroad()
        gumroad.results["TYPO"] = .failure(.rejected("That license does not exist for the provided product."))
        let m = await LicenseFixtures.manager(polar: polar, gumroad: gumroad)
        await assertThrows(.unknownKey) { try await m.addKey("TYPO") }
    }

    func testActivationLimitStopsWithPolarsMessage() async {
        let polar = FakePolar()
        polar.activateResult = .failure(.activationLimitReached("License key activation limit already reached"))
        let gumroad = FakeGumroad()
        let m = await LicenseFixtures.manager(polar: polar, gumroad: gumroad)
        await assertThrows(.activationLimitReached("License key activation limit already reached")) {
            try await m.addKey("FULL-KEY")
        }
        XCTAssertTrue(gumroad.verifiedKeys.isEmpty)
        XCTAssertTrue(m.keys.isEmpty)
    }

    func testSameKeyTwiceUsesNoSecondActivation() async {
        let key = LicenseFixtures.key(.safari)
        let polar = FakePolar()
        let m = await LicenseFixtures.manager(keys: [key], polar: polar)
        await assertThrows(.alreadyAdded) { try await m.addKey(key.key) }
        XCTAssertTrue(polar.activatedLabels.isEmpty)
    }

    func testRemovingAKeyFreesItsActivationEvenOffline() async {
        let key = LicenseFixtures.key(.safari)
        let polar = FakePolar()
        polar.deactivateResult = .failure(.unreachable)
        let m = await LicenseFixtures.manager(keys: [key], polar: polar)
        await m.removeKey(key)
        XCTAssertEqual(polar.deactivatedActivationIds, [key.activationId!])
        XCTAssertTrue(m.keys.isEmpty)
        XCTAssertEqual(m.entitlements, .none)
    }

    func testRemovingAGumroadKeyCallsNoServer() async {
        let key = LicenseFixtures.key(.mixed, provider: .gumroad)
        let polar = FakePolar()
        let m = await LicenseFixtures.manager(keys: [key], polar: polar)
        await m.removeKey(key)
        XCTAssertTrue(polar.deactivatedActivationIds.isEmpty)
        XCTAssertEqual(m.entitlements, .none)
    }
}
