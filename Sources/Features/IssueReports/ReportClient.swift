import Foundation

enum ReportError: LocalizedError, Equatable {
    /// No answer, or one we can't read: offer the GitHub link instead.
    case unreachable
    /// The relay said no and said why (bad input, rate limit, switched off).
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .unreachable: return "Couldn't send the report."
        case let .rejected(message): return message
        }
    }
}

/// Sends a report to the relay at report.magicelklabs.com, which opens the
/// GitHub issue and keeps the email out of it. Source: viaduct-report-relay.
struct ReportClient {
    static let endpoint = URL(string: "https://report.magicelklabs.com/report")!
    var session: URLSession = .shared

    private struct Payload: Encodable {
        let kind: ProblemReport.Kind
        let title: String
        let description: String
        let email: String
        let sections: [ProblemReport.Section]
        let log: [String]
    }

    /// The public issue's URL.
    func send(_ report: ProblemReport, description: String, email: String) async throws -> URL {
        let description = ProblemReport.clip(description.trimmingCharacters(in: .whitespacesAndNewlines),
                                             ProblemReport.maxDescription)
        let payload = Payload(kind: report.kind, title: report.title(describing: description),
                              description: description, email: email.trimmingCharacters(in: .whitespaces),
                              sections: report.sections, log: report.log)
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        request.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ReportError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw ReportError.unreachable }
        return try Self.outcome(status: http.statusCode, body: data)
    }

    /// 2xx with a URL is a filed issue. A 4xx or 503 with a message is the
    /// relay turning it away; anything else (502, a proxy's HTML page) counts
    /// as unreachable so the user still gets the GitHub link.
    static func outcome(status: Int, body: Data) throws -> URL {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        if (200..<300).contains(status), let link = (json?["url"] as? String).flatMap(URL.init(string:)) {
            return link
        }
        if (400..<500).contains(status) || status == 503, let message = json?["error"] as? String {
            throw ReportError.rejected(message)
        }
        throw ReportError.unreachable
    }

    static func isPlausibleEmail(_ email: String) -> Bool {
        email.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
    }
}
