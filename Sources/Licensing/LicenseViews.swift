import AppKit
import SwiftUI

extension Entitlements {
    /// The License page's first line: what's unlimited on this Mac, and how
    /// many free conversions the other browser has left.
    func summary(freeLeft: Int, quota: Int) -> String {
        let unlimited = Browser.allCases.filter(unlimited).map(\.displayName)
        let limited = Browser.allCases.filter { !self.unlimited($0) }.map(\.displayName)
        let freeLine = "\(freeLeft) of \(quota) free conversions left."
        if unlimited.isEmpty {
            return "\(freeLine) On the free plan, Viaduct removes what you convert after 7 days."
        }
        if limited.isEmpty {
            return "\(unlimited.joined(separator: " and ")) are unlimited on this Mac."
        }
        return "\(unlimited.joined(separator: " and ")) is unlimited on this Mac. "
            + "\(limited.joined(separator: " and ")) has \(freeLine)"
    }
}

/// What's typed into a license key field, and why the last try failed. Each
/// field has its own, so an error only shows under the field its key was
/// typed into.
@MainActor
final class KeyEntry: ObservableObject {
    @Published var text = ""
    @Published private(set) var error: LicenseError?

    var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Adds the typed key. Success empties the field. A failure leaves the key
    /// in it, so it can be fixed instead of pasted again.
    func submit(to license: LicenseManager) async {
        guard hasText, !license.isAddingKey else { return }
        error = nil
        do {
            try await license.addKey(text)
            text = ""
        } catch {
            self.error = (error as? LicenseError) ?? .unreachable
        }
    }
}

/// The last key's error, in red. A key that's out of activations also gets a
/// button to Polar's customer portal, where an old Mac's activation can go.
/// The views go straight into the parent's stack, so they line up with the
/// rest of it.
struct KeyErrorText: View {
    let error: LicenseError?

    var body: some View {
        if let error {
            Text(error.errorDescription ?? "")
                .tracked()
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.Colors.accentRed)
                .fixedSize(horizontal: false, vertical: true)
            if case .activationLimitReached = error, let portal = PolarConfig.portalURL {
                Button("Manage Activations") { NSWorkspace.shared.open(portal) }
                    .buttonStyle(.raycastTertiary)
            }
        }
    }
}

/// One license: the browsers it unlocks, its name, and its price with a Buy
/// button, or ACTIVE in place of both when a key on this Mac already covers it.
struct TierRow: View {
    let tier: LicenseTier
    /// Teal edge and a primary Buy, for the tiers that unlock the browser
    /// that ran out of free conversions.
    let highlighted: Bool
    let owned: Bool
    /// The tier's checkout. Buy is disabled without one.
    let buyURL: URL?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
        HStack(spacing: Theme.Space.md) {
            TierIcon(tier: tier)
            Text(tier.displayName)
                .font(Theme.Font.bodyStrong())
                .foregroundStyle(Theme.Colors.ink)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if owned {
                StatusBadge(text: "ACTIVE", color: Theme.Colors.accentGreen)
                    .padding(.trailing, Theme.Space.xs)
            } else {
                Text(tier.priceLabel)
                    .font(Theme.Font.body().monospacedDigit())
                    .foregroundStyle(Theme.Colors.mute)
                buyButton
            }
        }
        .padding(.vertical, Theme.Space.sm)
        .padding(.leading, Theme.Space.md)
        .padding(.trailing, Theme.Space.sm)
        // As tall as a row with a Buy button, so an ACTIVE row doesn't shrink.
        .frame(minHeight: 52)
        .background(shape.fill(Theme.Colors.surfaceElevated))
        .overlay(shape.strokeBorder(highlighted ? Theme.Colors.primary : Theme.Colors.hairline,
                                    lineWidth: highlighted ? 1.5 : 1))
    }

    @ViewBuilder
    private var buyButton: some View {
        let buy = Button {
            if let buyURL { NSWorkspace.shared.open(buyURL) }
        } label: {
            // With the style's padding that's 64pt, so primary and tertiary
            // Buy buttons come out the same width.
            Text("Buy").frame(minWidth: 32)
        }
        .disabled(buyURL == nil)
        // Every row's button says Buy, so VoiceOver needs the tier too.
        .accessibilityLabel("Buy \(tier.displayName)")
        if highlighted {
            buy.buttonStyle(.raycastPrimary)
        } else {
            buy.buttonStyle(.raycastTertiary)
        }
    }
}

/// The browsers a tier unlocks, as their own app icons. Mixed shows Safari's
/// with Firefox's over its corner.
struct TierIcon: View {
    let tier: LicenseTier

    var body: some View {
        let browsers = Browser.allCases.filter(tier.entitlements.unlimited)
        ZStack {
            if browsers.count == 1 {
                BrowserAppIcon(browser: browsers[0], size: 24)
            } else {
                ForEach(browsers) { browser in
                    BrowserAppIcon(browser: browser, size: 20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: browser == browsers.first ? .topLeading : .bottomTrailing)
                }
            }
        }
        .frame(width: 28, height: 28)
        // The tier's name sits right beside it.
        .accessibilityHidden(true)
    }
}

/// A browser's icon, from the copy installed on this Mac, so Viaduct never
/// ships another company's logo. A browser that isn't installed gets a
/// symbol on a plain disc.
private struct BrowserAppIcon: View {
    let browser: Browser
    let size: CGFloat

    var body: some View {
        if let icon = Self.installedIcon(of: browser) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: symbol)
                .font(.system(size: size * 0.6, weight: .medium))
                .foregroundStyle(Theme.Colors.primary)
                .frame(width: size, height: size)
                .background(Circle().fill(Theme.Colors.surface))
                .overlay(Circle().strokeBorder(Theme.Colors.hairline, lineWidth: 1))
        }
    }

    private var symbol: String {
        switch browser {
        case .safari: return "safari"
        case .firefox: return "globe"
        }
    }

    /// Icons found so far. A browser that wasn't found is looked for again
    /// next time, in case it's been installed since.
    @MainActor private static var found: [Browser: NSImage] = [:]

    @MainActor private static func installedIcon(of browser: Browser) -> NSImage? {
        if let icon = found[browser] { return icon }
        let bundleID: String
        switch browser {
        case .safari: bundleID = "com.apple.Safari"
        case .firefox: bundleID = "org.mozilla.firefox"
        }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        found[browser] = icon
        return icon
    }
}
