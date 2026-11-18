import AppKit
import SwiftUI

/// Sends a problem report without leaving the app or needing a GitHub account:
/// one box for what happened, an optional email, and the details Viaduct adds.
/// A report that isn't about one conversion asks which browser it's about.
struct ReportSheet: View {
    let dismiss: () -> Void
    var client = ReportClient()
    /// Set when the user picks the browser; rebuilds the report for it.
    private let makeReport: ((Browser) -> ProblemReport)?
    @State private var report: ProblemReport
    @State private var browser: Browser

    init(report: ProblemReport, dismiss: @escaping () -> Void) {
        self.dismiss = dismiss
        makeReport = nil
        _report = State(initialValue: report)
        _browser = State(initialValue: .safari)
    }

    init(browser: Browser, makeReport: @escaping (Browser) -> ProblemReport, dismiss: @escaping () -> Void) {
        self.dismiss = dismiss
        self.makeReport = makeReport
        _report = State(initialValue: makeReport(browser))
        _browser = State(initialValue: browser)
    }

    private enum Phase: Equatable {
        case editing
        case sending
        case sent(URL)
        case failed(ReportError)
    }

    @State private var description = ""
    @State private var email = ""
    @State private var phase: Phase = .editing
    @State private var showsDetails = false

    private var trimmedDescription: String { description.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespaces) }
    private var emailIsValid: Bool { trimmedEmail.isEmpty || ReportClient.isPlausibleEmail(trimmedEmail) }
    private var canSend: Bool {
        phase != .sending && emailIsValid && (!report.needsDescription || !trimmedDescription.isEmpty)
    }

    var body: some View {
        Group {
            if case let .sent(link) = phase {
                sent(link)
            } else {
                form
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 420)
        .background(AmbientBackground())
        .interactiveDismissDisabled(phase == .sending)
    }

    // MARK: - Form

    private var form: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack {
                Text("Report a Problem")
                    .font(Theme.Font.headingMD())
                    .foregroundStyle(Theme.Colors.ink)
                Spacer()
                if let makeReport {
                    BrowserPicker(selection: $browser)
                        .disabled(phase == .sending)
                        .onChange(of: browser) { report = makeReport($0) }
                }
            }

            ZStack(alignment: .topLeading) {
                if description.isEmpty {
                    Text(report.needsDescription ? "What happened?" : "What happened? (optional)")
                        .font(Theme.Font.body())
                        .foregroundStyle(Theme.Colors.ash)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $description)
                    .font(Theme.Font.body())
                    .foregroundStyle(Theme.Colors.ink)
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel("What happened")
            }
            .frame(height: 110)
            .padding(Theme.Space.sm)
            .background(Color.clear.liquidGlass(radius: Theme.Radius.md))
            .disabled(phase == .sending)

            TextField("Email (optional, stays private)", text: $email)
                .textFieldStyle(.glass)
                .disabled(phase == .sending)
                .accessibilityLabel("Email")
            if !emailIsValid {
                Text("That email doesn't look right.")
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.Colors.accentRed)
            }

            DisclosureGroup("Details Viaduct adds", isExpanded: $showsDetails) {
                ScrollView {
                    Text(report.preview)
                        .font(Theme.Font.mono())
                        .foregroundStyle(Theme.Colors.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 96)
                .padding(Theme.Space.sm)
                .background(Color.clear.liquidGlass(radius: Theme.Radius.sm))
                .padding(.top, Theme.Space.xs)
            }
            .font(Theme.Font.caption())
            .foregroundStyle(Theme.Colors.mute)

            Text("Reports are posted publicly on GitHub. Your email isn't.")
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.Colors.mute)

            if case let .failed(error) = phase {
                failure(error)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.raycastGhost)
                    .keyboardShortcut(.cancelAction)
                    .disabled(phase == .sending)
                Spacer()
                Button(action: send) {
                    HStack(spacing: 6) {
                        if phase == .sending { ProgressView().controlSize(.small) }
                        Text(phase == .sending ? "Sending…" : "Send")
                    }
                }
                .buttonStyle(.raycastPrimary)
                .disabled(!canSend)
                .keyboardShortcut(canSend ? .defaultAction : nil)
            }
        }
    }

    @ViewBuilder
    private func failure(_ error: ReportError) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(error.localizedDescription)
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.Colors.accentRed)
            // A message from the relay (too long, too many) is fixable here;
            // no answer at all isn't, so GitHub takes it instead.
            if error == .unreachable {
                Button("Open on GitHub Instead") {
                    NSWorkspace.shared.open(report.fallbackURL(description: trimmedDescription))
                    dismiss()
                }
                .buttonStyle(.raycastTertiary)
            }
        }
    }

    private func send() {
        guard canSend else { return }
        phase = .sending
        Task {
            do {
                let link = try await client.send(report, description: trimmedDescription, email: trimmedEmail)
                Feedback.success()
                phase = .sent(link)
            } catch let error as ReportError {
                phase = .failed(error)
            } catch {
                phase = .failed(.unreachable)
            }
        }
    }

    // MARK: - Sent

    private func sent(_ link: URL) -> some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(Theme.Colors.accentGreen)
            Text("Thanks, it's sent")
                .font(Theme.Font.headingMD())
                .foregroundStyle(Theme.Colors.ink)
            if !trimmedEmail.isEmpty {
                Text("We'll email you if we need anything else.")
                    .font(Theme.Font.body())
                    .foregroundStyle(Theme.Colors.body)
                    .multilineTextAlignment(.center)
            }
            HStack {
                Button("View on GitHub") { NSWorkspace.shared.open(link) }
                    .buttonStyle(.raycastTertiary)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.raycastPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
