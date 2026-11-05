import SwiftUI

/// The notice before an install that needs Firefox to restart. Firefox never
/// restarts without it, and a removal that needs the restart shows the same words.
enum FirefoxRestartPrompt {
    static let title = "Firefox will restart once"
    static let message = "Your tabs come back."
    static let restartButton = "Restart Firefox"
    static let laterButton = "Later"
}

// Each alert hangs off a clear view of its own: two alerts on one view can
// swallow each other.
extension View {
    /// Asks the user to accept `FirefoxDisclosure` before the first Firefox install.
    func firefoxDisclosureAlert(isPresented: Binding<Bool>,
                                onContinue: @escaping () -> Void,
                                onCancel: @escaping () -> Void) -> some View {
        background(Color.clear.alert(FirefoxDisclosure.title, isPresented: isPresented) {
            Button("Continue", action: onContinue)
            Button("Cancel", role: .cancel, action: onCancel)
        } message: {
            Text(FirefoxDisclosure.message)
        })
    }

    /// Asks before an install that would restart Firefox. Escape means Later.
    func firefoxRestartAlert(isPresented: Binding<Bool>,
                             onAnswer: @escaping (_ restartNow: Bool) -> Void) -> some View {
        background(Color.clear.alert(FirefoxRestartPrompt.title, isPresented: isPresented) {
            Button(FirefoxRestartPrompt.restartButton) { onAnswer(true) }
            Button(FirefoxRestartPrompt.laterButton, role: .cancel) { onAnswer(false) }
        } message: {
            Text(FirefoxRestartPrompt.message)
        })
    }

    /// Both Firefox questions a conversion can stop on, wired to the view model.
    func firefoxPrompts(vm: ConverterViewModel) -> some View {
        modifier(FirefoxPromptsHost(vm: vm))
    }
}

private struct FirefoxPromptsHost: ViewModifier {
    @ObservedObject var vm: ConverterViewModel

    func body(content: Content) -> some View {
        content
            .firefoxDisclosureAlert(isPresented: $vm.showFirefoxDisclosure,
                                    onContinue: { vm.acceptFirefoxDisclosure() },
                                    onCancel: { vm.declineFirefoxDisclosure() })
            .firefoxRestartAlert(isPresented: $vm.showFirefoxRestartPrompt,
                                 onAnswer: { vm.answerFirefoxRestart(restartNow: $0) })
    }
}
