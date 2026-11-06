import AppKit
import SwiftUI

// App only: Browser.swift is also compiled into the helper, which has no UI.
extension Browser {
    /// The browser's app on this Mac. Firefox is whichever of release,
    /// Developer Edition and Nightly FirefoxLocator finds first.
    var appURL: URL? {
        switch self {
        case .safari: return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
        case .firefox: return FirefoxLocator.find()?.appURL
        }
    }

    /// The browser's own app icon at 16 pt, cached per browser. Falls back to
    /// SF Symbol "globe" when the app isn't on this Mac. Taken from the
    /// installed copy, so Viaduct never ships another company's logo.
    @MainActor var appIcon: NSImage {
        if let icon = Self.foundIcons[self] { return icon }
        // The browser's own icon is only cached once found, so one installed
        // later shows up next time.
        guard let app = appURL else { return Self.globe }
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: 16, height: 16)
        Self.foundIcons[self] = icon
        return icon
    }

    @MainActor private static var foundIcons: [Browser: NSImage] = [:]

    @MainActor private static let globe: NSImage = {
        let image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil) ?? NSImage()
        image.size = NSSize(width: 16, height: 16)
        return image
    }()
}

/// A small browser icon that says which browser an extension is in.
struct BrowserGlyph: View {
    let browser: Browser
    var size: CGFloat = 12

    var body: some View {
        Image(nsImage: browser.appIcon)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(Theme.Colors.primary)
            .frame(width: size, height: size)
            .accessibilityLabel(browser.displayName)
    }
}
