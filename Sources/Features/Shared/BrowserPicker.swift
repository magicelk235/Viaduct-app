import SwiftUI

/// The Safari | Firefox switch for the browser a conversion goes to.
struct BrowserPicker: View {
    @Binding var selection: Browser

    /// Builds made without the private persist checkout have no persist.mjs,
    /// so they can't keep add-ons in Firefox. Read once: the bundle doesn't
    /// change under a running app.
    static let firefoxAvailable = PersistClient.scriptURL != nil

    /// The browser a stored choice comes back as. A value this version doesn't
    /// know is Safari, and so is Firefox in a build that can't install there.
    static func storedBrowser(_ raw: String?, firefoxAvailable: Bool) -> Browser {
        guard let browser = raw.flatMap(Browser.init(rawValue:)),
              browser != .firefox || firefoxAvailable
        else { return .safari }
        return browser
    }

    var body: some View {
        Picker("Browser", selection: $selection) {
            ForEach(Browser.allCases) { browser in
                segment(browser).tag(browser)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        // macOS 13 can't turn off a single segment, so there the whole switch
        // goes off instead, which leaves Safari, the one choice anyway.
        .disabled(!Self.firefoxAvailable && !Self.canTurnOffOneSegment)
    }

    /// Firefox stays in view in a build without it, but can't be picked.
    @ViewBuilder private func segment(_ browser: Browser) -> some View {
        let label = Text(browser.displayName)
        if browser == .firefox && !Self.firefoxAvailable {
            if #available(macOS 14, *) {
                label.selectionDisabled().help(Self.firefoxMissing)
            } else {
                label.help(Self.firefoxMissing)
            }
        } else {
            label
        }
    }

    private static let firefoxMissing = "This build doesn't include Firefox support."

    private static var canTurnOffOneSegment: Bool {
        if #available(macOS 14, *) { return true }
        return false
    }
}
