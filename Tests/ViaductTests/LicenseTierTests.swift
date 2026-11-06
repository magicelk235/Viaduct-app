@testable import Viaduct
import XCTest

final class LicenseTierTests: XCTestCase {
    func testKeysAddUp() {
        XCTAssertEqual(Entitlements(tiers: [.safari, .firefox]), .mixed)
        XCTAssertEqual(Entitlements(tiers: [.mixed]), .mixed)
        XCTAssertEqual(Entitlements(tiers: [.safari, .safari]), Entitlements(safari: true, firefox: false))
        XCTAssertEqual(Entitlements(tiers: []), .none)
    }

    func testEachTierUnlocksItsOwnBrowser() {
        XCTAssertTrue(LicenseTier.safari.entitlements.unlimited(.safari))
        XCTAssertFalse(LicenseTier.safari.entitlements.unlimited(.firefox))
        XCTAssertTrue(LicenseTier.firefox.entitlements.unlimited(.firefox))
        XCTAssertFalse(LicenseTier.firefox.entitlements.unlimited(.safari))
        XCTAssertEqual(LicenseTier.single(for: .firefox), .firefox)
    }

    func testBenefitIdPicksTheTier() {
        let ids: [LicenseTier: String] = [.firefox: "b-ff", .safari: "b-sa", .mixed: "b-mx"]
        XCTAssertEqual(LicenseTier(benefitId: "b-sa", in: ids), .safari)
        XCTAssertEqual(LicenseTier(benefitId: "b-mx", in: ids), .mixed)
        XCTAssertNil(LicenseTier(benefitId: "another-apps-benefit", in: ids))
    }

    func testPaywallHighlightsWhatUnlocksTheBlockedBrowser() {
        XCTAssertEqual(LicenseTier.highlighted(for: .firefox, owned: .none), [.firefox, .mixed])
        XCTAssertEqual(LicenseTier.highlighted(for: .safari, owned: .none), [.safari, .mixed])
        // They own Safari already, so Mixed would charge them for Safari a second time.
        XCTAssertEqual(LicenseTier.highlighted(for: .firefox, owned: LicenseTier.safari.entitlements), [.firefox])
        XCTAssertEqual(LicenseTier.highlighted(for: nil, owned: .none), [])
    }

    func testSettingsOffersOnlyWhatAddsABrowser() {
        XCTAssertEqual(LicenseTier.upgrades(from: .none), [.firefox, .safari, .mixed])
        XCTAssertEqual(LicenseTier.upgrades(from: LicenseTier.safari.entitlements), [.firefox])
        XCTAssertEqual(LicenseTier.upgrades(from: LicenseTier.firefox.entitlements), [.safari])
        XCTAssertEqual(LicenseTier.upgrades(from: .mixed), [])
    }

    func testOfflineGraceEndsAtFourteenDays() {
        let checked = Date(timeIntervalSince1970: 1_793_664_000)
        let key = StoredKey(provider: .polar, key: "K", activationId: "a", tier: .safari, lastValidated: checked)
        XCTAssertTrue(key.isUsable(at: checked.addingTimeInterval(14 * 86_400 - 60)))
        XCTAssertFalse(key.isUsable(at: checked.addingTimeInterval(14 * 86_400)))
    }
}
