import SwiftUI
import AppKit
import Combine
import SafariServices

/// One extension waiting in a batch.
struct QueueItem: Identifiable {
    enum Status: Equatable {
        case pending, preparing, converting
        /// Parked on the signing alert or the Firefox disclosure in the main window.
        case waiting
        case done
        case failed(String)
        case skipped(String)

        var isFinished: Bool {
            switch self {
            case .done, .failed, .skipped: return true
            default: return false
            }
        }
    }

    let id = UUID()
    var name: String
    var iconPNG: Data?
    /// Produces the file or folder to convert. Runs off the main thread, so it
    /// can download from the store or copy out of a browser profile.
    var prepare: () async throws -> URL
    /// Stamped on the history record so auto-update and the store page's
    /// Remove button work for the result.
    var storeId: String?
    /// Chrome extension id, when known. Lets settings come along.
    var chromeId: String?
    /// The browser profile to take settings from; nil searches every profile.
    var settingsProfile: BrowserProfile?
    /// The browser it gets converted for.
    var browser: Browser
    var status: Status = .pending
    var note: String?
    var installedPath: String?

    init(name: String, iconPNG: Data? = nil, storeId: String? = nil, chromeId: String? = nil,
         settingsProfile: BrowserProfile? = nil, browser: Browser = .safari,
         prepare: @escaping () async throws -> URL) {
        self.name = name
        self.iconPNG = iconPNG
        self.storeId = storeId
        self.chromeId = chromeId
        self.settingsProfile = settingsProfile
        self.browser = browser
        self.prepare = prepare
    }

    /// A file already on disk.
    static func file(_ url: URL, browser: Browser = .safari) -> QueueItem {
        let info = ExtensionInspector.inspectSync(path: url.path)
        return QueueItem(name: info?.name ?? url.deletingPathExtension().lastPathComponent,
                         iconPNG: info?.icon?.pngData(),
                         chromeId: ExtensionIdentity.chromeId(forSource: url.path),
                         browser: browser) { url }
    }
}

/// Runs a list of conversions one after another through the same one-tap flow
/// a single drop uses, so signing, the free quota and history all behave the
/// same. The CLI only runs one process at a time, so this is strictly serial.
@MainActor
final class ConversionQueue: ObservableObject {
    static let shared = ConversionQueue()

    enum StopReason: Equatable {
        case needsUpgrade(Browser)
        case needsXcode
        case needsFirefox(FirefoxGate)
        case cancelled

        /// The browser whose items it stops; nil stops every item.
        var browser: Browser? {
            switch self {
            case .needsUpgrade(let browser): return browser
            case .needsXcode: return .safari   // Firefox never uses Xcode
            case .needsFirefox: return .firefox
            case .cancelled: return nil
            }
        }

        /// What the items it skips say.
        var skippedNote: String {
            switch self {
            case .needsUpgrade(let browser): return "Needs a \(browser.displayName) license"
            case .needsXcode: return "Needs Xcode"
            case .needsFirefox(let gate): return gate.skippedNote
            case .cancelled: return "Cancelled"
            }
        }
    }

    @Published private(set) var items: [QueueItem] = []
    @Published private(set) var isRunning = false
    @Published private(set) var stopReason: StopReason?
    /// Shows the queue sheet. Kept here so any entry point (drop, import,
    /// Shortcuts) can start a batch without reaching into a view.
    @Published var isPresented = false

    private weak var vm: ConverterViewModel?
    private var currentIndex: Int?
    /// Set right before a conversion starts, cleared by whichever of the
    /// run-ended callback or the synchronous check after `userConvert()` sees
    /// the outcome first, so one run is never counted twice.
    private var expectingEnd = false
    private var phaseWatch: AnyCancellable?
    /// New per batch. The prepare step awaits (store downloads take seconds),
    /// so a task from a stopped batch can resume after the next one started;
    /// it checks this before touching `items`.
    private var batchID = UUID()
    /// The first per-browser stop the batch ran into. That browser's items
    /// after it are skipped, the other browser's keep going, and the batch
    /// ends on this reason.
    private var firstStop: StopReason?

    var doneCount: Int { items.filter { $0.status == .done }.count }
    var finishedCount: Int { items.filter { $0.status.isFinished }.count }
    var isFinished: Bool { !isRunning && !items.isEmpty }

    func start(_ newItems: [QueueItem], vm: ConverterViewModel) {
        guard !isRunning, !newItems.isEmpty else { return }
        if vm.isRunning { vm.cancel() }
        self.vm = vm
        items = newItems
        stopReason = nil
        batchID = UUID()
        firstStop = nil
        isRunning = true
        isPresented = true
        vm.batchActive = true
        vm.signingWarningAnsweredForBatch = false
        vm.firefoxRestartAnsweredForBatch = nil
        vm.userRunEnded = { [weak self] ok in self?.runEnded(ok) }
        runNext()
    }

    func cancel() {
        guard isRunning else { return }
        expectingEnd = false
        if let vm, vm.isRunning { vm.cancel() }
        finish(reason: .cancelled)
    }

    /// Close the sheet once the batch is over.
    func dismiss() {
        guard !isRunning else { return }
        isPresented = false
        items = []
        stopReason = nil
    }

    // MARK: - Running

    private func runNext() {
        guard isRunning, let vm else { return }
        guard let index = items.firstIndex(where: { $0.status == .pending }) else {
            finish(reason: nil)
            return
        }
        currentIndex = index
        items[index].status = .preparing
        let item = items[index]
        let batch = batchID
        Task {
            let prepared: (url: URL, note: String?)
            do {
                prepared = try await Self.prepare(item)
            } catch {
                guard isRunning, batchID == batch else { return }
                items[index].status = .failed(error.localizedDescription)
                runNext()
                return
            }
            guard isRunning, batchID == batch else { return }
            if let note = prepared.note { items[index].note = note; vm.appendLog("→ \(note)") }
            convert(index: index, path: prepared.url.path)
        }
    }

    /// Get the input on disk, then let settings ride along if that's on.
    private static func prepare(_ item: QueueItem) async throws -> (url: URL, note: String?) {
        let url = try await item.prepare()
        guard let chromeId = item.chromeId else { return (url, nil) }
        return await Task.detached(priority: .userInitiated) {
            let result = SettingsCarryOver.apply(to: url, chromeId: chromeId,
                                                 profile: item.settingsProfile, name: item.name)
            return (result.url, result.note)
        }.value
    }

    private func convert(index: Int, path: String) {
        guard let vm else { return }
        vm.resetUserFlow()
        // Each item converts for its own browser, whatever the window last used.
        vm.options.browser = items[index].browser
        vm.selectInput(path: path)
        // A folder copied out of a browser profile is named after the
        // extension id, which is no name for an app.
        vm.options.appName = items[index].name
        vm.pendingStoreId = items[index].storeId
        vm.pendingChromeId = items[index].chromeId
        items[index].status = .converting
        expectingEnd = true
        vm.userConvert()
        guard expectingEnd else { return }   // ended synchronously, already handled

        if vm.isRunning { return }           // running; runEnded() takes it from here
        if vm.showAdhocWarning || vm.showFirefoxDisclosure {
            items[index].status = .waiting
            watchAnswer(index: index)
            return
        }
        expectingEnd = false
        if vm.showPaywall {
            // The paywall is a sheet on the main window and can't open over the
            // queue's own sheet; the queue offers the upgrade instead.
            let browser = vm.paywallBrowser ?? .safari
            vm.showPaywall = false
            items[index].status = .pending
            stop(.needsUpgrade(browser))
            runNext()
        } else if vm.needsXcode {
            items[index].status = .failed(vm.failureSummary ?? "Xcode is required.")
            stop(.needsXcode)
            runNext()
        } else if let gate = vm.firefoxGate {
            items[index].status = .failed(vm.failureSummary ?? gate.headline)
            stop(.needsFirefox(gate))
            runNext()
        } else {
            items[index].status = .failed(vm.failureSummary ?? "The conversion didn't start.")
            runNext()
        }
    }

    /// The signing alert or the Firefox disclosure is up. Going ahead starts
    /// the run (and runEnded follows); backing out lands the flow in .failed,
    /// which stops the batch the same way Cancel would.
    private func watchAnswer(index: Int) {
        guard let vm else { return }
        phaseWatch = vm.$phase
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                guard let self, self.items.indices.contains(index),
                      self.items[index].status == .waiting else { return }
                if vm.isRunning {
                    self.items[index].status = .converting
                    self.phaseWatch = nil
                } else if vm.showPaywall {
                    // "Convert Anyway" ran into the free-quota wall. Same
                    // handling as hitting it without the signing question.
                    self.phaseWatch = nil
                    self.expectingEnd = false
                    let browser = vm.paywallBrowser ?? .safari
                    vm.showPaywall = false
                    self.items[index].status = .pending
                    self.stop(.needsUpgrade(browser))
                    self.runNext()
                } else if let gate = vm.firefoxGate {
                    self.phaseWatch = nil
                    self.expectingEnd = false
                    self.items[index].status = .failed(vm.failureSummary ?? gate.headline)
                    self.stop(.needsFirefox(gate))
                    self.runNext()
                } else if phase == .failed {
                    self.phaseWatch = nil
                    self.expectingEnd = false
                    self.items[index].status = .failed(vm.failureSummary ?? "Cancelled.")
                    self.finish(reason: .cancelled)
                }
            }
    }

    private func runEnded(_ ok: Bool) {
        guard expectingEnd, let index = currentIndex, let vm else { return }
        expectingEnd = false
        phaseWatch = nil
        if ok {
            items[index].status = .done
            items[index].installedPath = vm.installedAppPath
            if items[index].browser == .firefox, vm.firefoxInstallPending {
                items[index].note = "Arrives the next time you open Firefox"
            }
        } else if let gate = vm.firefoxGate {
            // No profile, or Viaduct off in Login Items, found once the run was
            // going. The Firefox items left would only stop on it again.
            items[index].status = .failed(vm.failureSummary ?? gate.headline)
            stop(.needsFirefox(gate))
        } else {
            items[index].status = .failed(vm.failureSummary ?? "Conversion failed.")
        }
        // Let the run's own bookkeeping (history, the CLI update it may have
        // queued) finish on this turn before the next one resets the flow.
        DispatchQueue.main.async { [weak self] in self?.runNext() }
    }

    /// The items `reason` leaves untried: only the waiting ones for the browser
    /// it's about, or, for a stop that isn't about one browser, all that
    /// haven't finished.
    static func skipped(by reason: StopReason, in items: [QueueItem]) -> [Int] {
        guard let browser = reason.browser else {
            return items.indices.filter { !items[$0].status.isFinished }
        }
        return items.indices.filter { items[$0].browser == browser && items[$0].status == .pending }
    }

    /// A stop that's about one browser: skip that browser's items and remember
    /// the first one for the end of the batch.
    private func stop(_ reason: StopReason) {
        if firstStop == nil { firstStop = reason }
        for i in Self.skipped(by: reason, in: items) { items[i].status = .skipped(reason.skippedNote) }
    }

    private func finish(reason: StopReason?) {
        let reason = reason ?? firstStop
        phaseWatch = nil
        currentIndex = nil
        stopReason = reason
        let leftover = reason?.skippedNote ?? ""
        for i in items.indices where !items[i].status.isFinished {
            items[i].status = .skipped(leftover)
        }
        isRunning = false
        if let vm {
            vm.batchActive = false
            vm.signingWarningAnsweredForBatch = false
            vm.firefoxRestartAnsweredForBatch = nil
            vm.userRunEnded = nil
            // Stopped while the signing question or the Firefox disclosure was
            // up: answering it now would act on a batch that's gone.
            vm.showAdhocWarning = false
            vm.showFirefoxDisclosure = false
            // The Xcode and Firefox gates have to stay on screen; anything else
            // goes back to the empty card so the last item doesn't look like a
            // single run.
            switch reason {
            case .needsXcode, .needsFirefox: break
            default: if !vm.isRunning { vm.resetUserFlow() }
            }
        }
    }

    // MARK: - After the batch

    /// The browsers at least one item went into, which decide how the sheet ends.
    static func doneBrowsers(_ items: [QueueItem]) -> Set<Browser> {
        Set(items.filter { $0.status == .done }.map(\.browser))
    }

    func openFirefox() {
        FirefoxLocator.find().map(FirefoxLocator.open)
    }

    /// Safari keeps converted extensions off until they're ticked in its
    /// settings, so the batch ends there instead of launching every host app.
    func openSafariExtensionSettings() {
        let last = items.last { $0.status == .done && $0.browser == .safari && $0.installedPath != nil }
        guard let path = last?.installedPath,
              let extensionId = Self.appexBundleId(inHostApp: path) else {
            StoreButton.openSafariSettings()
            return
        }
        SFSafariApplication.showPreferencesForExtension(withIdentifier: extensionId) { error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path),
                                                   configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }

    private static func appexBundleId(inHostApp path: String) -> String? {
        let plugins = URL(fileURLWithPath: path).appendingPathComponent("Contents/PlugIns")
        let appex = (try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil))?
            .first { $0.pathExtension == "appex" }
        return appex.flatMap { Bundle(url: $0)?.bundleIdentifier }
    }
}

extension FirefoxGate {
    /// Ends the batch sheet's summary, after the counts.
    var batchHint: String {
        switch self {
        case .notInstalled: return "install Firefox, then run the rest again"
        case .noProfile: return "open Firefox once, then run the rest again"
        case .loginItemOff: return "turn Viaduct on in Login Items, then run the rest again"
        }
    }

    /// What the items the batch never got to say.
    var skippedNote: String {
        switch self {
        case .notInstalled: return "Needs Firefox"
        case .noProfile: return "Needs a Firefox profile"
        case .loginItemOff: return "Needs Viaduct in Login Items"
        }
    }
}
