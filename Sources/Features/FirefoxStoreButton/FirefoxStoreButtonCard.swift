import SwiftUI
import AppKit

/// Settings → Extensions card for the Add to Firefox button: its state and
/// the one thing to do about it, the way the Chrome Web Store card does it.
struct FirefoxStoreButtonCard: View {
    @ObservedObject var button: FirefoxStoreButton

    var body: some View {
        SettingsSection(title: "Firefox store button", symbol: "puzzlepiece.extension") {
            if button.state == .on {
                StatusBadge(text: "ON", color: Theme.Colors.accentGreen)
            }
        } content: {
            content
        }
        .task { await button.refresh() }
        .firefoxStoreButtonPrompts(button)
    }

    @ViewBuilder
    private var content: some View {
        switch button.state {
        case .checking:
            ProgressView().controlSize(.small)
        case .needsFirefox:
            Text("Firefox isn't installed.")
                .font(Theme.Font.body())
                .foregroundStyle(Theme.Colors.body)
            Button("Get Firefox") { NSWorkspace.shared.open(FirefoxLocator.downloadURL) }
                .buttonStyle(.raycastTertiary)
        case .off:
            Button("Install") { Task { await button.requestInstall() } }
                .buttonStyle(.raycastPrimary)
        case .installing:
            working("Installing…")
        case .removing:
            working("Removing…")
        case .on:
            if button.arrivesLater {
                Text("It arrives the next time you open Firefox.")
                    .font(Theme.Font.body())
                    .foregroundStyle(Theme.Colors.body)
            }
            HStack(spacing: Theme.Space.sm) {
                Button("Open the Chrome Web Store") { button.openWebStore() }
                    .buttonStyle(.raycastTertiary)
                Button("Remove") { Task { await button.remove() } }
                    .buttonStyle(.raycastTertiary)
            }
        case .failed(let message):
            Text(message)
                .font(Theme.Font.body())
                .foregroundStyle(Theme.Colors.accentRed)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again") { Task { await button.requestInstall() } }
                .buttonStyle(.raycastPrimary)
        }
    }

    private func working(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(Theme.Font.body())
                .foregroundStyle(Theme.Colors.body)
        }
    }
}

extension View {
    /// The disclosure and the restart question an install of the button can
    /// stop on. Firefox only restarts once the user picks Restart Firefox.
    func firefoxStoreButtonPrompts(_ button: FirefoxStoreButton) -> some View {
        modifier(FirefoxStoreButtonPrompts(button: button))
    }
}

private struct FirefoxStoreButtonPrompts: ViewModifier {
    @ObservedObject var button: FirefoxStoreButton

    func body(content: Content) -> some View {
        content
            .firefoxDisclosureAlert(isPresented: shows(.disclosure),
                                    onContinue: { Task { await button.answerDisclosure(accepted: true) } },
                                    onCancel: { Task { await button.answerDisclosure(accepted: false) } })
            .firefoxRestartAlert(isPresented: shows(.restart),
                                 onAnswer: { restartNow in Task { await button.answerRestart(restartNow: restartNow) } })
    }

    /// Dismissing clears the prompt, unless the answer has already moved it
    /// on to the next question.
    private func shows(_ prompt: FirefoxStoreButton.Prompt) -> Binding<Bool> {
        Binding(get: { button.prompt == prompt },
                set: { if !$0, button.prompt == prompt { button.prompt = nil } })
    }
}
