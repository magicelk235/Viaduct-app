import SwiftUI
import AppKit

/// Shown on the ready card when the picked extension's maker already ships it
/// for Safari. Doesn't block converting; just makes sure the user knows.
struct OfficialVersionBanner: View {
    let path: String
    let storeId: String?
    @State private var alternative: SafariAlternative?

    var body: some View {
        Group {
            if let alternative {
                Button { NSWorkspace.shared.open(alternative.url) } label: {
                    Label("\(alternative.name) has an official Safari version", systemImage: "safari")
                        .font(Theme.Font.caption())
                        .foregroundStyle(Theme.Colors.accentBlue)
                }
                .buttonStyle(.plain)
                .help("Open \(alternative.url.absoluteString)")
            }
        }
        .task(id: path) {
            let known = storeId
            alternative = await Task.detached(priority: .utility) {
                (known ?? ExtensionIdentity.chromeId(forSource: path)).flatMap { SafariAlternatives.lookup(chromeId: $0) }
            }.value
        }
    }
}

/// The store-page flow converts without the window ever coming forward, so
/// the notice there has to be a question asked before the download starts.
@MainActor
final class OfficialVersionPrompt: ObservableObject {
    static let shared = OfficialVersionPrompt()

    struct Question: Identifiable {
        let id = UUID()
        let alternative: SafariAlternative
        let convert: () -> Void
    }

    @Published var question: Question?

    /// Calls `convert` straight away unless there's an official version to
    /// mention first.
    func checkBeforeStoreInstall(chromeId: String, convert: @escaping () -> Void) {
        guard let alt = SafariAlternatives.lookup(chromeId: chromeId) else {
            convert()
            return
        }
        // The question is an alert on the main window, which is usually closed
        // when a store click arrives.
        MainWindow.show()
        question = Question(alternative: alt, convert: convert)
    }
}

extension View {
    /// Hosts the store-install question on the main window.
    func officialVersionPrompt() -> some View {
        modifier(OfficialVersionPromptHost())
    }
}

private struct OfficialVersionPromptHost: ViewModifier {
    @ObservedObject private var prompt = OfficialVersionPrompt.shared

    func body(content: Content) -> some View {
        content.alert(item: $prompt.question) { q in
            Alert(title: Text("\(q.alternative.name) is already made for Safari"),
                  message: Text("Its developer publishes an official Safari version, which updates itself and is supported by them. You can still convert the Chrome one."),
                  primaryButton: .default(Text("Get the Safari Version")) {
                      NSWorkspace.shared.open(q.alternative.url)
                  },
                  secondaryButton: .cancel(Text("Convert Anyway")) { q.convert() })
        }
    }
}
