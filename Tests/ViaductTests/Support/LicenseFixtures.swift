@testable import Viaduct
import XCTest

/// Keys, a clock and a LicenseManager that never reach a real store.
enum LicenseFixtures {
    static let now = Date(timeIntervalSince1970: 1_793_664_000)   // 2026-11-03
    static let benefitIds: [LicenseTier: String] = [.firefox: "benefit-firefox", .safari: "benefit-safari", .mixed: "benefit-mixed"]

    /// A key nobody else has. Polar keys come with an activation for this Mac.
    static func key(_ tier: LicenseTier, provider: StoredKey.Provider = .polar, validated: Date = now) -> StoredKey {
        let id = UUID().uuidString
        return StoredKey(provider: provider, key: "TEST-\(id)", activationId: provider == .polar ? "activation-\(id)" : nil,
                         tier: tier, lastValidated: validated)
    }

    /// A manager over `keys`, after its launch check. With the default fakes
    /// no check connects, so every key keeps its stored tier.
    @MainActor static func manager(keys: [StoredKey] = [], freeUsed: Int = 0, now: Date = now,
                                   polar: FakePolar = FakePolar(), gumroad: FakeGumroad = FakeGumroad(),
                                   name: String = #function, file: String = #fileID) async -> LicenseManager {
        let defaults = TestDefaults.make(name, file: file)
        defaults.set(freeUsed, forKey: "freeConversionsUsed")
        let store = LicenseStore(file: TempDir.make().appendingPathComponent("licenses.json"), defaults: defaults,
                                 legacyKeychainKey: { nil })
        store.save(keys)
        let manager = LicenseManager(store: store, polar: polar, gumroad: gumroad, benefitIds: benefitIds,
                                     defaults: defaults, now: { now }, macName: { "Test Mac" })
        await manager.validateStoredKeys()
        return manager
    }
}

/// Polar, answering from the results set on it. Main-actor bound, so the
/// launch check's parallel calls can't race on what it records.
@MainActor
final class FakePolar: PolarLicensing {
    var activateResult: Result<PolarActivation, LicenseError> = .failure(.unreachable)
    /// Keyed by license key; a key without an entry is unreachable.
    var validateResults: [String: Result<String, LicenseError>] = [:]
    var deactivateResult: Result<Void, LicenseError> = .success(())
    /// Keys whose validation answers only after every other key's has.
    var slowKeys: Set<String> = []
    private(set) var activatedLabels: [String] = []
    private(set) var deactivatedActivationIds: [String] = []

    /// Nonisolated so it can be a default argument.
    nonisolated init() {}

    func activate(key: String, label: String) async throws -> PolarActivation {
        activatedLabels.append(label)
        return try activateResult.get()
    }

    func validate(key: String, activationId: String?) async throws -> String {
        if slowKeys.contains(key) { try? await Task.sleep(nanoseconds: 200_000_000) }
        return try validateResults[key, default: .failure(.unreachable)].get()
    }

    func deactivate(key: String, activationId: String) async throws {
        deactivatedActivationIds.append(activationId)
        try deactivateResult.get()
    }
}

/// Gumroad, answering from `results`. Main-actor bound like `FakePolar`.
@MainActor
final class FakeGumroad: GumroadLicensing {
    /// Keyed by license key; a key without an entry is unreachable.
    var results: [String: Result<Void, LicenseError>] = [:]
    private(set) var verifiedKeys: [String] = []

    nonisolated init() {}

    func verify(key: String) async throws {
        verifiedKeys.append(key)
        try results[key, default: .failure(.unreachable)].get()
    }
}

/// Fails unless `body` throws exactly `expected`.
func assertThrows(_ expected: LicenseError, file: StaticString = #filePath, line: UInt = #line,
                  _ body: () async throws -> Void) async {
    do {
        try await body()
        XCTFail("Expected \(expected), nothing was thrown", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? LicenseError, expected, file: file, line: line)
    }
}
