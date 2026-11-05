import Foundation

/// The Polar values from Info.plist, filled in through project.yml. None of
/// them is a secret. Empty values are left out, so a dev build without them
/// simply has no tiers to sell.
enum PolarConfig {
    static let organizationId: String = string("PolarOrganizationID") ?? ""

    static let benefitIds: [LicenseTier: String] = perTier { string("PolarBenefit\($0)") }

    static let checkoutURLs: [LicenseTier: URL] = perTier { url("PolarCheckout\($0)") }

    static let portalURL: URL? = url("PolarPortalURL")

    private static func string(_ key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func url(_ key: String) -> URL? {
        string(key).flatMap(URL.init(string:))
    }

    /// Reads one value per tier, with the key suffix spelled like the
    /// tier's name ("Firefox", "Safari", "Mixed").
    private static func perTier<Value>(_ read: (String) -> Value?) -> [LicenseTier: Value] {
        var values: [LicenseTier: Value] = [:]
        for tier in LicenseTier.allCases {
            values[tier] = read(tier.displayName)
        }
        return values
    }
}

struct PolarActivation: Equatable {
    let activationId: String
    let benefitId: String
}

protocol PolarLicensing {
    func activate(key: String, label: String) async throws -> PolarActivation
    /// Returns the key's benefit ID.
    func validate(key: String, activationId: String?) async throws -> String
    func deactivate(key: String, activationId: String) async throws
}

/// Polar's customer-portal license-key endpoints. They need no access token,
/// just the organization ID. No Polar-Version header either: Polar retires a
/// pinned version after about nine months and then answers 404 to everything.
struct PolarClient: PolarLicensing {
    let organizationId: String
    var session: URLSession = .shared

    static let live = PolarClient(organizationId: PolarConfig.organizationId)

    private static let baseURL = URL(string: "https://api.polar.sh/v1/customer-portal/license-keys/")!

    func activate(key: String, label: String) async throws -> PolarActivation {
        let body = try await post("activate", ["key": key, "organization_id": organizationId, "label": label], expecting: 200)
        return try Self.activation(from: body)
    }

    func validate(key: String, activationId: String?) async throws -> String {
        var fields = ["key": key, "organization_id": organizationId]
        fields["activation_id"] = activationId
        let body = try await post("validate", fields, expecting: 200)
        return try Self.benefitId(from: body)
    }

    func deactivate(key: String, activationId: String) async throws {
        _ = try await post("deactivate", ["key": key, "organization_id": organizationId, "activation_id": activationId],
                           expecting: 204)
    }

    private func post(_ endpoint: String, _ fields: [String: String], expecting success: Int) async throws -> Data {
        // A dev build before the owner fills in project.yml.
        guard !organizationId.isEmpty else { throw LicenseError.unreachable }

        var request = URLRequest(url: Self.baseURL.appendingPathComponent(endpoint))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: fields)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LicenseError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw LicenseError.unreachable }
        guard http.statusCode == success else { throw Self.error(status: http.statusCode, body: data) }
        return data
    }

    static func activation(from body: Data) throws -> PolarActivation {
        guard let json = object(body),
              let id = json["id"] as? String,
              let key = json["license_key"] as? [String: Any],
              let benefitId = key["benefit_id"] as? String
        else { throw LicenseError.unreachable }
        return PolarActivation(activationId: id, benefitId: benefitId)
    }

    static func benefitId(from body: Data) throws -> String {
        guard let benefitId = object(body)?["benefit_id"] as? String else { throw LicenseError.unreachable }
        return benefitId
    }

    /// Only Polar's own error bodies count as a no. Anything else (an outage,
    /// a proxy's HTML page, a request Polar couldn't parse) keeps the key.
    static func error(status: Int, body: Data) -> LicenseError {
        guard let json = object(body),
              let kind = json["error"] as? String,
              let detail = json["detail"] as? String
        else { return .unreachable }

        switch (status, kind) {
        case (403, "NotPermitted"):
            return detail.localizedCaseInsensitiveContains("limit") ? .activationLimitReached(detail) : .rejected(detail)
        case (404, "ResourceNotFound"):
            // Polar's stock 404 detail, meaning there's no such key.
            return detail == "Not found" ? .unknownKey : .rejected(detail)
        default:
            return .unreachable
        }
    }

    private static func object(_ body: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}
