import SwiftUI

/// Paywall. A sheet on the main window that lists the three licenses, with
/// the ones that unlock the browser that ran out of free conversions
/// highlighted, and takes a key that was bought already.
struct ActivationView: View {
    @ObservedObject var license: LicenseManager
    /// The browser that ran out of free conversions. Nil when the paywall was
    /// opened some other way, and then no row is highlighted.
    let blockedBrowser: Browser?
    /// Converted extensions, reported with the purchase.
    let extensionCount: Int
    /// When set, Not Now (and Esc) closes the paywall without a key.
    var onClose: (() -> Void)? = nil
    @StateObject private var entry = KeyEntry()

    /// The menu bar's Upgrade can open the paywall before the quota runs out,
    /// so the title only talks about the quota once it's spent.
    static func title(freeLeft: Int, quota: Int) -> String {
        freeLeft > 0 ? "Choose a license" : "You've used your \(quota) free conversions"
    }

    var body: some View {
        let highlighted = LicenseTier.highlighted(for: blockedBrowser, owned: license.entitlements)
        VStack(spacing: Theme.Space.lg) {
            Image(systemName: "key.fill")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(Theme.Colors.primary)
                .padding(.bottom, Theme.Space.xs)

            Text(Self.title(freeLeft: license.freeConversionsRemaining, quota: license.freeQuota))
                .heading()
                .font(Theme.Font.headingMD())
                .foregroundStyle(Theme.Colors.ink)
                .multilineTextAlignment(.center)

            Text("A license makes its browser unlimited and keeps what you convert there. You pay once, with no subscription.")
                .tracked()
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.Colors.mute)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            VStack(spacing: Theme.Space.sm) {
                ForEach(LicenseTier.allCases) { tier in
                    TierRow(tier: tier, highlighted: highlighted.contains(tier),
                            owned: license.entitlements.covers(tier),
                            buyURL: license.checkoutURL(for: tier, source: .paywall, extensionCount: extensionCount))
                }
            }

            Text("Bought one already? Paste the key from your purchase email.")
                .tracked()
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.Colors.mute)
                .multilineTextAlignment(.center)

            TextField("XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX", text: $entry.text)
                .textFieldStyle(.glass)
                .disabled(license.isAddingKey)
                .accessibilityLabel("License key")

            KeyErrorText(error: entry.error)
                .multilineTextAlignment(.center)

            VStack(spacing: Theme.Space.sm) {
                Button {
                    Task { await entry.submit(to: license) }
                } label: {
                    HStack(spacing: 6) {
                        if license.isAddingKey { ProgressView().controlSize(.small) }
                        Text(license.isAddingKey ? "Activating…" : "Activate")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.raycastPrimary)
                .disabled(!entry.hasText || license.isAddingKey)
                // Return in the field lands here.
                .keyboardShortcut(entry.hasText ? .defaultAction : nil)

                if let onClose {
                    Button(action: onClose) {
                        Text("Not Now").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.raycastTertiary)
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(Theme.Space.xxl)
        .frame(width: 460)
        .background(Theme.Colors.canvas)
    }
}
