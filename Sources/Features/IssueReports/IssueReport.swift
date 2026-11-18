import Foundation

/// Builds the reports the app sends: the extension, the browser, every version
/// that matters and the log, so the reporter only adds a sentence. Each one
/// also carries a GitHub issue-form link with the same fields filled in, for
/// when the relay can't be reached. Issue forms take each field's `id` as a
/// query parameter.
enum IssueReport {
    private static let repo = "https://github.com/magicelk235/Viaduct-CLI/issues/new"
    /// GitHub turns away URLs much past 8 KB, and the log is what gives.
    private static let urlBudget = 7_500

    /// A conversion that failed, or that the won't-work check stopped. Matches
    /// the CLI's `conversion-failure.yml` form.
    static func conversionFailure(extensionName: String, version: String?, storeId: String?, summary: String?,
                                  log: [String], cliVersion: String, browser: Browser, persistVersion: String?) -> ProblemReport {
        let versions = engines(cliVersion: cliVersion, browser: browser, persistVersion: persistVersion, separator: " · ")
        let header = [
            summary.map { "Viaduct said: \($0)" },
            "Viaduct \(appVersion) · \(versions) · \(browser.displayName)",
        ].compactMap { $0 }.joined(separator: "\n")
        let ext = describe(extensionName, version: version, storeId: storeId)
        let os = systemLine(for: browser)
        let title = "Conversion failed: \(extensionName)"

        // Most recent lines carry the failure; the link drops older ones until it fits.
        let linkLog = log.suffix(80).map { ProblemReport.scrub($0) }
        return ProblemReport(
            kind: .conversionFailure, title: title,
            sections: [.init(heading: "Extension", text: ext),
                       .init(heading: "Browser", text: browser.displayName),
                       .init(heading: "Versions", text: header),
                       .init(heading: "OS & Xcode/Firefox version", text: os)],
            log: log) { description in
            let lead = ProblemReport.scrub(description.isEmpty ? header : "What happened: \(description)\n\(header)")
            var tail = linkLog
            while true {
                let error = lead + "\n\n" + tail.joined(separator: "\n")
                let url = build(template: "conversion-failure.yml", title: title,
                                fields: ["extension": ext, "browser": browser.displayName, "error": error, "os": os])
                if url.absoluteString.count <= urlBudget || tail.isEmpty { return url }
                tail.removeFirst(max(1, tail.count / 5))
            }
        }
    }

    /// An extension that installed but misbehaves. Matches the CLI's
    /// `converted-but-broken.yml` form.
    static func convertedButBroken(extensionName: String, version: String?, storeId: String?,
                                   browser: Browser, cliVersion: String, persistVersion: String?) -> ProblemReport {
        let turnedOn: String
        let browserLine: String
        switch browser {
        case .safari:
            turnedOn = "Turned it on in Safari"
            browserLine = "Safari \(safariVersion), macOS \(osVersion)"
        case .firefox:
            turnedOn = "Opened it in Firefox"
            browserLine = "Firefox \(firefoxVersion), macOS \(osVersion)"
        }
        let versions = engines(cliVersion: cliVersion, browser: browser, persistVersion: persistVersion, separator: ", ")
        let ext = describe(extensionName, version: version, storeId: storeId)
        let steps = "1. Converted it with the Viaduct app \(appVersion) (\(versions))\n2. \(turnedOn)"
        let title = "\(extensionName) doesn't work in \(browser.displayName)"
        return ProblemReport(
            kind: .convertedButBroken, title: title,
            sections: [.init(heading: "Extension", text: ext),
                       .init(heading: "Browser", text: browser.displayName),
                       .init(heading: "Steps to reproduce", text: steps),
                       .init(heading: "Browser & OS version", text: browserLine)]) { description in
            build(template: "converted-but-broken.yml", title: title,
                  fields: ["extension": ext, "browser": browser.displayName, "actual": description,
                           "steps": steps + "\n3. ",
                           // The form's id predates Firefox; it holds whichever browser's version.
                           "safari-version": browserLine])
        }
    }

    /// Anything else, from Settings: the browser the user picks, the versions
    /// that matter for it, and the last error, if any.
    static func general(browser: Browser, cliVersion: String, persistVersion: String?, lastError: String?) -> ProblemReport {
        let versions = engines(cliVersion: cliVersion, browser: browser, persistVersion: persistVersion, separator: " · ")
        let browserLine: String
        switch browser {
        case .safari: browserLine = "Safari \(safariVersion)"
        case .firefox: browserLine = "Firefox \(firefoxVersion)"
        }
        var sections = [ProblemReport.Section(heading: "Browser", text: browser.displayName),
                        .init(heading: "Versions", text: "Viaduct \(appVersion) · \(versions)\nmacOS \(osVersion), \(browserLine)")]
        if let lastError { sections.append(.init(heading: "Last error", text: lastError)) }
        return ProblemReport(kind: .general, title: nil, sections: sections) { description in
            var body = description.isEmpty ? "" : description + "\n\n"
            body += sections.map { "**\($0.heading):**\n\(ProblemReport.scrub($0.text))" }.joined(separator: "\n\n")
            var c = URLComponents(string: repo)!
            c.queryItems = [.init(name: "body", value: body)]
            return encodePlus(c).url!
        }
    }

    private static func describe(_ name: String, version: String?, storeId: String?) -> String {
        var ext = name
        if let version, !version.isEmpty { ext += " \(version)" }
        if let storeId { ext += " / https://chromewebstore.google.com/detail/\(storeId)" }
        return ext
    }

    /// "CLI 2.0.0", plus persist's version for Firefox, which installs through it.
    private static func engines(cliVersion: String, browser: Browser, persistVersion: String?, separator: String) -> String {
        switch browser {
        case .safari: return "CLI \(cliVersion)"
        case .firefox: return "CLI \(cliVersion)\(separator)persist \(persistVersion ?? "?")"
        }
    }

    private static func build(template: String, title: String, fields: [String: String]) -> URL {
        var c = URLComponents(string: repo)!
        c.queryItems = [.init(name: "template", value: template), .init(name: "title", value: title)]
            + fields.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
        return encodePlus(c).url!
    }

    /// URLComponents leaves "+" alone, but GitHub reads it as a space, so
    /// "C++" would arrive as "C  ".
    private static func encodePlus(_ components: URLComponents) -> URLComponents {
        var c = components
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c
    }

    // MARK: - Versions

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    }

    /// Xcode builds Safari extensions; Firefox ones never touch it.
    private static func systemLine(for browser: Browser) -> String {
        switch browser {
        case .safari: return "macOS \(osVersion), \(xcodeVersion.map { "Xcode \($0)" } ?? "no Xcode found")"
        case .firefox: return "macOS \(osVersion), Firefox \(firefoxVersion)"
        }
    }

    private static var xcodeVersion: String? {
        CLIRunner.installedXcodeApp().flatMap { shortVersion(ofApp: $0) }
    }

    private static var safariVersion: String {
        shortVersion(ofApp: URL(fileURLWithPath: "/Applications/Safari.app")) ?? "?"
    }

    private static var firefoxVersion: String {
        FirefoxLocator.find()?.version ?? "?"
    }

    private static func shortVersion(ofApp app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }
}
