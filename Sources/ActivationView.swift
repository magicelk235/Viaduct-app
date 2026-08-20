import SwiftUI

/// Paywall. Shown as a sheet once an unlicensed user spends their free
/// conversions; dismisses when a valid Gumroad key activates.
struct ActivationView: View {
    @ObservedObject var license: LicenseManager
    /// When set, a close affordance (button + Esc) dismisses without activating.
    /// Used by the paywall sheet; omit for a non-dismissible launch wall.
    var onClose: (() -> Void)? = nil
    @State private var key = ""

    private var checking: Bool { license.state == .checking }

    var body: some View {
        ZStack {
            Theme.Colors.canvas.ignoresSafeArea()

            if let onClose {
                VStack {
                    HStack {
                        Spacer()
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.Colors.mute)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                    }
                    Spacer()
                }
                .padding(Theme.Space.md)
            }

            VStack(spacing: Theme.Space.lg) {
                Image(systemName: "key.fill")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(Theme.Colors.accentBlue)
                    .padding(.bottom, Theme.Space.xs)

                Text("You've used your \(license.freeQuota) free conversions")
                    .font(Theme.Font.headingMD())
                    .foregroundStyle(Theme.Colors.ink)
                    .multilineTextAlignment(.center)

                Text("Paste the key from your purchase email. You pay once, there's no subscription, and the key also turns on auto-renew.")
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.Colors.mute)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)

                TextField("XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX", text: $key)
                    .textFieldStyle(.glass)
                    .frame(maxWidth: 360)
                    .disabled(checking)
                    .onSubmit(activate)

                if let err = license.lastError {
                    Text(err)
                        .font(Theme.Font.caption())
                        .foregroundStyle(Theme.Colors.accentRed)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }

                Button(action: activate) {
                    HStack(spacing: 6) {
                        if checking { ProgressView().controlSize(.small) }
                        Text(checking ? "Activating…" : "Activate")
                    }
                    .frame(maxWidth: 360)
                }
                .buttonStyle(.raycastPrimary)
                .disabled(checking || key.trimmingCharacters(in: .whitespaces).isEmpty)

                Link("Buy a license", destination: URL(string: "https://magicelk235.gumroad.com/l/viaduct")!)
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.Colors.accentBlue)
                    .padding(.top, Theme.Space.xs)
            }
            .padding(Theme.Space.xxl)
        }
        .frame(width: 460)
    }

    private func activate() { license.activate(key: key) }
}
