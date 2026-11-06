import Foundation

/// GitHub issue-form links with the fields already filled in. Issue forms take
/// each field's `id` as a query parameter, so the reporter lands on a form that
/// only needs a sentence from them.
enum IssueReport {
    private static let repo = "https://github.com/magicelk235/Viaduct-CLI/issues/new"
    /// GitHub turns away URLs much past 8 KB, and the log is what gives.
    private static let urlBudget = 7_500

    /// The CLI's `conversion-failure.yml` form: extension, browser, error output,
    /// and the OS with Xcode for Safari or with Firefox for Firefox.
    static func conversionFailure(extensionName: String, version: String?, storeId: String?, summary: String?,
                                  log: [String], cliVersion: String, browser: Browser, persistVersion: String?) -> URL {
        let versions = engines(cliVersion: cliVersion, browser: browser, persistVersion: persistVersion, separator: " · ")
        let header = [
            summary.map { "Viaduct said: \($0)" },
            "Viaduct \(appVersion) · \(versions) · \(browser.displayName)",
        ].compactMap { $0 }.joined(separator: "\n")

        // Most recent lines carry the failure; drop older ones until it fits.
        var tail = Array(log.suffix(80))
        while true {
            let error = header + "\n\n" + tail.joined(separator: "\n")
            let url = build(template: "conversion-failure.yml",
                            title: "Conversion failed: \(extensionName)",
                            fields: ["extension": describe(extensionName, version: version, storeId: storeId),
                                     "browser": browser.displayName, "error": error, "os": systemLine(for: browser)])
            if url.absoluteString.count <= urlBudget || tail.isEmpty { return url }
            tail.removeFirst(max(1, tail.count / 5))
        }
    }

    /// The CLI's `converted-but-broken.yml` form, for an extension that
    /// installed but misbehaves.
    static func convertedButBroken(extensionName: String, version: String?, storeId: String?,
                                   browser: Browser, cliVersion: String, persistVersion: String?) -> URL {
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
        return build(template: "converted-but-broken.yml",
                     title: "\(extensionName) doesn't work in \(browser.displayName)",
                     fields: ["extension": describe(extensionName, version: version, storeId: storeId),
                              "browser": browser.displayName,
                              "steps": "1. Converted it with the Viaduct app \(appVersion) (\(versions))\n2. \(turnedOn)\n3. ",
                              // The form's id predates Firefox; it holds whichever browser's version.
                              "safari-version": browserLine])
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
        // URLComponents leaves "+" alone, but GitHub reads it as a space, so
        // "C++" would arrive as "C  ".
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
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
