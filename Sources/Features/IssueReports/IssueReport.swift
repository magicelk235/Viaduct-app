import Foundation

/// GitHub issue-form links with the fields already filled in. Issue forms take
/// each field's `id` as a query parameter, so the reporter lands on a form that
/// only needs a sentence from them.
enum IssueReport {
    private static let repo = "https://github.com/magicelk235/Viaduct-CLI/issues/new"
    /// GitHub turns away URLs much past 8 KB, and the log is what gives.
    private static let urlBudget = 7_500

    /// The CLI's `conversion-failure.yml` form: extension, error output, OS & Xcode.
    static func conversionFailure(extensionName: String, version: String?, storeId: String?,
                                  summary: String?, log: [String], cliVersion: String) -> URL {
        var ext = extensionName
        if let version, !version.isEmpty { ext += " \(version)" }
        if let storeId { ext += " / https://chromewebstore.google.com/detail/\(storeId)" }

        let header = [
            summary.map { "Viaduct said: \($0)" },
            "Viaduct \(appVersion) · CLI \(cliVersion)",
        ].compactMap { $0 }.joined(separator: "\n")

        // Most recent lines carry the failure; drop older ones until it fits.
        var tail = Array(log.suffix(80))
        while true {
            let error = header + "\n\n" + tail.joined(separator: "\n")
            let url = build(template: "conversion-failure.yml",
                            title: "Conversion failed: \(extensionName)",
                            fields: ["extension": ext, "error": error, "os": systemLine])
            if url.absoluteString.count <= urlBudget || tail.isEmpty { return url }
            tail.removeFirst(max(1, tail.count / 5))
        }
    }

    /// The CLI's `converted-but-broken.yml` form, for an extension that
    /// installed but misbehaves.
    static func convertedButBroken(extensionName: String, version: String?, storeId: String?) -> URL {
        var ext = extensionName
        if let version, !version.isEmpty { ext += " \(version)" }
        if let storeId { ext += " / https://chromewebstore.google.com/detail/\(storeId)" }
        return build(template: "converted-but-broken.yml",
                     title: "\(extensionName) doesn't work in Safari",
                     fields: ["extension": ext,
                              "steps": "1. Converted it with the Viaduct app \(appVersion)\n2. Turned it on in Safari\n3. ",
                              "safari-version": "Safari \(safariVersion), macOS \(osVersion)"])
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

    private static var systemLine: String {
        "macOS \(osVersion), \(xcodeVersion.map { "Xcode \($0)" } ?? "no Xcode found")"
    }

    private static var xcodeVersion: String? {
        CLIRunner.installedXcodeApp().flatMap { shortVersion(ofApp: $0) }
    }

    private static var safariVersion: String {
        shortVersion(ofApp: URL(fileURLWithPath: "/Applications/Safari.app")) ?? "?"
    }

    private static func shortVersion(ofApp app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }
}
