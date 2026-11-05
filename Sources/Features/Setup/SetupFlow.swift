import SwiftUI
import AppKit

/// First-launch setup: gets a new install to the point where a conversion can
/// succeed (Xcode, an Apple account in it, read access to the browsers), offers
/// the store button, then ends on a welcome screen that hands over to Import
/// from Chrome.
@MainActor
final class SetupFlow: ObservableObject {
    static let shared = SetupFlow()

    enum Step: Int, CaseIterable, Identifiable {
        case xcode, appleAccount, diskAccess, storeButton, license
        var id: Int { rawValue }
    }

    enum AccountState: Equatable {
        case signedIn
        /// An Apple ID is in Xcode but it hasn't issued a signing certificate.
        case needsCertificate
        case signedOut
    }

    @Published private(set) var isActive = false
    @Published private(set) var step: Step = .xcode
    /// Past the last step: the welcome screen that closes setup.
    @Published private(set) var showingWelcome = false
    /// True from `start()` until the first checks land. Then setup opens the
    /// first step that still needs something, so a Mac that's already ready
    /// goes straight to the welcome screen.
    @Published private(set) var preparing = false

    /// What the last check found for each step. Nil until the first check lands.
    @Published private(set) var xcode: CLIRunner.XcodeStatus?
    @Published private(set) var account: AccountState?
    /// Browsers macOS won't let Viaduct read. Nil until the user has been
    /// asked, because the check itself is what raises the macOS prompt.
    @Published private(set) var blockedBrowsers: [ChromiumBrowser]?
    @Published private(set) var checkingDiskAccess = false

    private let doneKey = "setupDone"

    // MARK: - Showing it

    /// Fresh installs only: nothing converted and no free conversion spent.
    /// Anyone else is marked done the first time this runs, so an update never
    /// drops an existing user into setup.
    func startIfFreshInstall(history: ConversionHistory) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: doneKey) == nil else { return }
        let fresh = history.records.isEmpty && defaults.integer(forKey: "freeConversionsUsed") == 0
        guard fresh else {
            defaults.set(true, forKey: doneKey)
            return
        }
        start()
    }

    func start() {
        // Setup asks about the store button itself, so the one-time popup that
        // used to do it would be a second ask.
        UserDefaults.standard.set(true, forKey: "storeButtonPromptSeen")
        step = steps.first ?? .xcode
        showingWelcome = false
        preparing = true
        isActive = true
        refresh()
    }

    /// Ends setup. `openImport` goes straight on to the browser import list.
    func finish(openImport: Bool) {
        UserDefaults.standard.set(true, forKey: doneKey)
        isActive = false
        guard openImport else { return }
        // Let the main surface replace setup before a sheet goes over it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            ChromeImport.shared.isPresented = true
        }
    }

    // MARK: - Steps

    /// The steps this Mac needs. Disk access only makes sense with a Chromium
    /// browser installed.
    var steps: [Step] {
        Step.allCases.filter { $0 != .diskAccess || ChromeImport.hasBrowsers }
    }

    /// Whether the welcome screen offers Import from Chrome.
    var canImport: Bool { ChromeImport.hasBrowsers }

    /// Opens a step's row. Any row can be picked, done or not, which is how
    /// the user goes back to one.
    func select(_ step: Step) {
        guard step != self.step else { return }
        self.step = step
        refresh()
    }

    /// The next step that still needs something, or the welcome screen.
    func next() {
        guard let i = steps.firstIndex(of: step) else { return }
        if let later = steps[(i + 1)...].first(where: { !isDone($0) }) {
            step = later
            refresh()
        } else {
            showingWelcome = true
        }
    }

    /// The step on screen just finished. Move on after a beat, so the green
    /// check registers before its row closes.
    func stepCompleted() {
        let finished = step
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard self.isActive, !self.showingWelcome, self.step == finished,
                  self.isDone(finished) else { return }
            self.next()
        }
    }

    // MARK: - Checks

    /// Re-check what can be checked quietly: Xcode, the Apple account and the
    /// store button, so every row of the checklist is right from the start. Called on
    /// entering a step and whenever the app comes back to the front, since
    /// every fix happens in another app.
    func refresh() {
        // Each step keeps its last answer until the new one lands, so going
        // back to a done row doesn't flash a spinner or reopen it.
        Task.detached(priority: .userInitiated) {
            let status = CLIRunner.xcodeStatus()
            let state: AccountState = SigningAccount.xcodeTeamPresent() ? .signedIn
                : (SigningAccount.xcodeAccountPresent() ? .needsCertificate : .signedOut)
            await MainActor.run {
                self.xcode = status
                self.account = state
                if state == .signedIn { ConverterViewModel.shared.refreshSigningTeams() }
                if self.preparing {
                    self.preparing = false
                    if let first = self.steps.first(where: { !self.isDone($0) }) {
                        self.step = first
                        if first == .diskAccess, self.blockedBrowsers != nil { self.checkDiskAccess() }
                    } else {
                        self.showingWelcome = true
                    }
                }
            }
        }
        ConverterViewModel.shared.refreshStoreButton()
        // Disk access only once the user has been asked: checking is asking.
        if step == .diskAccess, blockedBrowsers != nil { checkDiskAccess() }
    }

    /// Reads each browser's folder. The first read is what makes macOS show its
    /// "access data from other apps" question, and it waits for the answer.
    func checkDiskAccess() {
        guard !checkingDiskAccess else { return }
        checkingDiskAccess = true
        Task.detached(priority: .userInitiated) {
            let blocked = BrowserProfiles.blocked()
            await MainActor.run {
                self.blockedBrowsers = blocked
                self.checkingDiskAccess = false
            }
        }
    }

    /// Whether a step needs nothing more from the user.
    func isDone(_ step: Step) -> Bool {
        switch step {
        case .xcode:        return xcode == .ready
        case .appleAccount: return account == .signedIn
        case .diskAccess:   return blockedBrowsers?.isEmpty == true
        case .storeButton:  return ConverterViewModel.shared.storeButtonEnabled == true
        case .license:      return LicenseManager.shared.unlimited(.safari)
        }
    }
}

/// Settings → General card for running setup again.
struct SetupAgainSection: View {
    let vm: ConverterViewModel

    var body: some View {
        SettingsSection(title: "Setup", symbol: "checklist") {
            Button("Run Setup Again") {
                SetupFlow.shared.start()
                MainWindow.show()
            }
            .buttonStyle(.raycastTertiary)
            .disabled(vm.isRunning || ConversionQueue.shared.isRunning)
        }
    }
}
