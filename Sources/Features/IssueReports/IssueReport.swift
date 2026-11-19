import Foundation

/// Builds the reports the app sends: the extension, the browser, every version
/// that matters and the log, so the reporter only adds a sentence.
enum IssueReport {
    /// A conversion that failed, or that the won't-work check stopped.
    static func conversionFailure(extensionName: String, version: String?, storeId: String?, summary: String?,
                                  log: [String], cliVersion: String, engineVersion: String?,
                                  browser: Browser, persistVersion: String?) -> ProblemReport {
        let versions = engines(cliVersion: cliVersion, engineVersion: engineVersion, browser: browser,
                               persistVersion: persistVersion, separator: " · ")
        let ext = describe(extensionName, version: version, storeId: storeId)
        let os = systemLine(for: browser)
        let title = "Conversion failed: \(extensionName)"

        var sections: [ProblemReport.Section] = [.init(heading: "Extension", text: ext),
                                                 .init(heading: "Browser", text: browser.displayName)]
        if let summary { sections.append(.init(heading: "Viaduct said", text: summary)) }
        sections += [.init(heading: "Versions", text: "Viaduct \(appVersion) · \(versions) · \(browser.displayName)"),
                     .init(heading: "OS & Xcode/Firefox version", text: os)]
        return ProblemReport(kind: .conversionFailure, title: title, sections: sections, log: log)
    }

    /// What a report calls the extension: its manifest name, else the name the
    /// app was given (a store install that failed before anything downloaded
    /// has only that), else the file's name.
    static func extensionName(manifestName: String?, appName: String, inputPath: String) -> String {
        if let manifestName, !manifestName.isEmpty { return manifestName }
        if !appName.isEmpty { return appName }
        if !inputPath.isEmpty { return URL(fileURLWithPath: inputPath).deletingPathExtension().lastPathComponent }
        return "Unknown extension"
    }

    /// An extension that installed but misbehaves.
    static func convertedButBroken(extensionName: String, version: String?, storeId: String?,
                                   browser: Browser, cliVersion: String, engineVersion: String?,
                                   persistVersion: String?) -> ProblemReport {
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
        let versions = engines(cliVersion: cliVersion, engineVersion: engineVersion, browser: browser,
                               persistVersion: persistVersion, separator: ", ")
        let ext = describe(extensionName, version: version, storeId: storeId)
        let steps = "1. Converted it with the Viaduct app \(appVersion) (\(versions))\n2. \(turnedOn)"
        let title = "\(extensionName) doesn't work in \(browser.displayName)"
        return ProblemReport(
            kind: .convertedButBroken, title: title,
            sections: [.init(heading: "Extension", text: ext),
                       .init(heading: "Browser", text: browser.displayName),
                       .init(heading: "Steps to reproduce", text: steps),
                       .init(heading: "Browser & OS version", text: browserLine)])
    }

    /// Anything else, from Settings: the browser the user picks, the versions
    /// that matter for it, and the last error, if any.
    static func general(browser: Browser, cliVersion: String, engineVersion: String?, persistVersion: String?,
                        lastError: String?) -> ProblemReport {
        let versions = engines(cliVersion: cliVersion, engineVersion: engineVersion, browser: browser,
                               persistVersion: persistVersion, separator: " · ")
        let browserLine: String
        switch browser {
        case .safari: browserLine = "Safari \(safariVersion)"
        case .firefox: browserLine = "Firefox \(firefoxVersion)"
        }
        var sections = [ProblemReport.Section(heading: "Browser", text: browser.displayName),
                        .init(heading: "Versions", text: "Viaduct \(appVersion) · \(versions)\nmacOS \(osVersion), \(browserLine)")]
        if let lastError { sections.append(.init(heading: "Last error", text: lastError)) }
        return ProblemReport(kind: .general, title: nil, sections: sections)
    }

    private static func describe(_ name: String, version: String?, storeId: String?) -> String {
        var ext = name
        if let version, !version.isEmpty { ext += " \(version)" }
        if let storeId { ext += " / https://chromewebstore.google.com/detail/\(storeId)" }
        return ext
    }

    /// "CLI 2.0.0 · aqueduct 1.18.3": the CLI and the engine it converted
    /// with, plus persist's version for Firefox, which installs through it.
    private static func engines(cliVersion: String, engineVersion: String?, browser: Browser,
                                persistVersion: String?, separator: String) -> String {
        let converter = "CLI \(cliVersion)\(separator)\(browser.engine) \(engineVersion ?? "?")"
        switch browser {
        case .safari: return converter
        case .firefox: return "\(converter)\(separator)persist \(persistVersion ?? "?")"
        }
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
