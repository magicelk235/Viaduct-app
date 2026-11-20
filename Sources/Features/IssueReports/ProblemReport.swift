import Foundation

/// A problem report as the report sheet sends it: what Viaduct already knows
/// about the problem, plus whatever the user writes. The relay turns it into a
/// public GitHub issue; the user never sees GitHub unless the relay is down.
struct ProblemReport: Identifiable {
    enum Kind: String, Encodable {
        case conversionFailure = "conversion-failure"
        case convertedButBroken = "converted-but-broken"
        case general
    }

    struct Section: Equatable, Encodable {
        let heading: String
        let text: String
        var code = false
    }

    let id = UUID()
    let kind: Kind
    /// nil for a general report, whose title is the first line the user writes.
    let title: String?
    let sections: [Section]
    let log: [String]

    // The relay's limits; anything past them is cut here rather than rejected there.
    static let maxTitle = 200
    static let maxDescription = 5_000
    static let maxSectionText = 4_000
    static let maxLogLine = 1_000
    static let logBudget = 40_000

    init(kind: Kind, title: String?, sections: [Section], log: [String] = []) {
        self.kind = kind
        self.title = title.map { Self.clip(Self.scrub($0), Self.maxTitle) }
        self.sections = sections.map {
            Section(heading: $0.heading, text: Self.clip(Self.scrub($0.text), Self.maxSectionText), code: $0.code)
        }
        self.log = Self.fit(log.map { Self.clip(Self.scrub($0), Self.maxLogLine) }, budget: Self.logBudget)
    }

    private static let newIssue = "https://github.com/magicelk235/viaduct-app/issues/new"
    /// GitHub turns away URLs much past 8 KB, and the log is what gives.
    static let urlBudget = 7_500

    /// A new GitHub issue with the title and body filled in, for when the
    /// relay can't be reached.
    func fallbackURL(description: String) -> URL {
        let lead = ([description.isEmpty ? nil : "### What happened\n\n\(Self.scrub(description))"]
            + sections.map { "### \($0.heading)\n\n\($0.text)" }).compactMap { $0 }.joined(separator: "\n\n")
        // The newest lines carry the failure; drop older ones until it fits.
        var tail = Array(log.suffix(80))
        while true {
            let body = tail.isEmpty ? lead : lead + "\n\n### Log\n\n```\n" + tail.joined(separator: "\n") + "\n```"
            var c = URLComponents(string: Self.newIssue)!
            c.queryItems = [.init(name: "title", value: title(describing: description)), .init(name: "body", value: body)]
            // URLComponents leaves "+" alone, but GitHub reads it as a space,
            // so "C++" would arrive as "C  ".
            c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            if c.url!.absoluteString.count <= Self.urlBudget || tail.isEmpty { return c.url! }
            tail.removeFirst(max(1, tail.count / 5))
        }
    }

    func title(describing description: String) -> String {
        if let title { return title }
        let firstLine = description.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Problem report" : String(trimmed.prefix(80))
    }

    /// The text the relay posts, as the sheet's preview shows it.
    var preview: String {
        var parts = sections.map { "\($0.heading)\n\($0.text)" }
        if !log.isEmpty { parts.append("Log\n" + log.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }

    /// At most `limit` UTF-16 units, the way the relay's JavaScript counts,
    /// without splitting a character.
    static func clip(_ text: String, _ limit: Int) -> String {
        guard text.utf16.count > limit else { return text }
        var count = 0
        var end = text.startIndex
        for index in text.indices {
            count += text[index].utf16.count
            if count > limit { break }
            end = text.index(after: index)
        }
        return String(text[..<end])
    }

    /// Reports are public, so the user's home folder, which names them, comes
    /// out of every path.
    static func scrub(_ text: String, home: String = NSHomeDirectory()) -> String {
        var out = home.count > 1 ? text.replacingOccurrences(of: home, with: "~") : text
        out = out.replacingOccurrences(of: #"/Users/(?!Shared/)[^/\s"']+"#, with: "/Users/<user>",
                                       options: .regularExpression)
        return out
    }

    /// The newest lines that fit, since the failure is at the end.
    static func fit(_ lines: [String], budget: Int) -> [String] {
        var size = 0
        var start = lines.endIndex
        while start > lines.startIndex {
            size += lines[start - 1].utf8.count + 1
            if size > budget { break }
            start -= 1
        }
        return Array(lines[start...])
    }
}
