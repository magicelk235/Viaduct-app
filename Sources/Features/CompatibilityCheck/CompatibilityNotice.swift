import SwiftUI

/// The verdict on the ready card, in place of the version line: what's wrong
/// in a sentence, never the analyzer's own wording.
struct CompatibilityNotice: View {
    let verdict: CompatibilityVerdict

    var body: some View {
        VStack(spacing: Theme.Space.xxs) {
            Text(verdict.title)
                .font(Theme.Font.body())
                .foregroundStyle(Theme.Colors.accentRed)
            Text(verdict.message)
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.Colors.mute)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
    }
}
