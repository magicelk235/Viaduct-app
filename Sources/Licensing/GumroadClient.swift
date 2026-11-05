import Foundation

protocol GumroadLicensing {
    func verify(key: String) async throws
}

/// Checks the Pro keys sold on Gumroad before the tiers. They count as Mixed.
///
/// Gumroad license API: https://docs.gumroad.com/#verify-a-license
/// POST https://api.gumroad.com/v2/licenses/verify
///   product_id=<id>&license_key=<key>&increment_uses_count=false
/// Returns: { success, uses, purchase:{ refunded, disputed, chargebacked, ... } }
struct GumroadClient: GumroadLicensing {
    /// Stable even if the product's URL slug is renamed. From the product's
    /// Settings/Advanced page.
    static let productID = "-7WMe9QfKNdzB5rmGZjMdw=="
    var session: URLSession = .shared

    private static let verifyURL = URL(string: "https://api.gumroad.com/v2/licenses/verify")!

    func verify(key: String) async throws {
        let body = "product_id=\(Self.encode(Self.productID))"
            + "&license_key=\(Self.encode(key))"
            + "&increment_uses_count=false"

        var request = URLRequest(url: Self.verifyURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(body.utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LicenseError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw LicenseError.unreachable }
        if let problem = Self.outcome(status: http.statusCode, body: data) { throw problem }
    }

    /// nil when the key is good. Only a 404 or a 2xx without success means
    /// Gumroad said no; a rate limit or an outage must never drop a paid key.
    static func outcome(status: Int, body: Data) -> LicenseError? {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return .unreachable
        }

        guard json["success"] as? Bool == true else {
            if status == 404 || (200..<300).contains(status) {
                return .rejected(json["message"] as? String ?? "Invalid license key.")
            }
            return .unreachable
        }

        // Refunded, disputed or chargebacked purchases lose access.
        if let purchase = json["purchase"] as? [String: Any] {
            for flag in ["refunded", "disputed", "chargebacked"] where purchase[flag] as? Bool == true {
                return .rejected("This purchase was \(flag); the license is no longer valid.")
            }
            if let ended = purchase["subscription_ended_at"] as? String, !ended.isEmpty {
                return .rejected("This subscription has ended.")
            }
        }
        return nil
    }

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
}
