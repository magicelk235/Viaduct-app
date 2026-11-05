import SwiftUI
import AppKit
import Combine
import SafariServices

/// One extension waiting in a batch.
struct QueueItem: Identifiable {
    enum Status: Equatable {
        case pending, preparing, converting
        /// Parked on the signing alert in the main window.
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
        case cancelled
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
        isRunning = true
        isPresented = true
        vm.batchActive = true
        vm.signingWarningAnsweredForBatch = false
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
        if vm.showAdhocWarning {
            items[index].status = .waiting
            watchSigningAnswer(index: index)
            return
        }
        expectingEnd = false
        if vm.showPaywall {
            // The paywall is a sheet on the main window and can't open over the
            // queue's own sheet; the queue offers the upgrade instead.
            let browser = vm.paywallBrowser ?? .safari
            vm.showPaywall = false
            items[index].status = .pending
            finish(reason: .needsUpgrade(browser))
        } else if vm.needsXcode {
            items[index].status = .failed(vm.failureSummary ?? "Xcode is required.")
            finish(reason: .needsXcode)
        } else {
            items[index].status = .failed(vm.failureSummary ?? "The conversion didn't start.")
            runNext()
        }
    }

    /// The signing alert is up. "Convert Anyway" starts the run (and runEnded
    /// follows); either other button lands the flow in .failed, which stops
    /// the batch the same way Cancel would.
    private func watchSigningAnswer(index: Int) {
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
                    self.finish(reason: .needsUpgrade(browser))
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
        } else {
            items[index].status = .failed(vm.failureSummary ?? "Conversion failed.")
        }
        // Let the run's own bookkeeping (history, the CLI update it may have
        // queued) finish on this turn before the next one resets the flow.
        DispatchQueue.main.async { [weak self] in self?.runNext() }
    }

    private func finish(reason: StopReason?) {
        phaseWatch = nil
        currentIndex = nil
        stopReason = reason
        let leftover: String
        switch reason {
        case .needsUpgrade(let browser): leftover = "Needs a \(browser.displayName) license"
        case .needsXcode:                leftover = "Needs Xcode"
        case .cancelled:                 leftover = "Cancelled"
        case nil:                        leftover = ""
        }
        for i in items.indices where !items[i].status.isFinished {
            items[i].status = .skipped(leftover)
        }
        isRunning = false
        if let vm {
            vm.batchActive = false
            vm.signingWarningAnsweredForBatch = false
            vm.userRunEnded = nil
            // Stopped while the signing question was up: answering it now
            // would act on a batch that's gone.
            vm.showAdhocWarning = false
            // The Xcode gate has to stay on screen; anything else goes back to
            // the empty card so the last item doesn't look like a single run.
            if reason != .needsXcode, !vm.isRunning { vm.resetUserFlow() }
        }
    }

    // MARK: - After the batch

    /// Safari keeps converted extensions off until they're ticked in its
    /// settings, so the batch ends there instead of launching every host app.
    func openSafariExtensionSettings() {
        let last = items.last { $0.status == .done && $0.installedPath != nil }
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
