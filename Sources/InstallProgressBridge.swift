import AppKit

/// Answers progress polls from the Safari extension so the Chrome Web Store
/// page can render the install bar itself — the app window never comes forward.
///
/// The .appex is sandboxed and lives only for the duration of one
/// `beginRequest`, so it can't read our files or hold a connection. Instead it
/// posts a request notification per poll and we reply with a JSON snapshot on
/// the distributed notification center (unsandboxed sender may attach the
/// `object` string; the sandboxed appex may receive it).
///
/// Each poll names the page's extension and browser (an `InstalledQuery`
/// object) and only gets progress when that's the store install the app is
/// running, so a page never shows another extension's or another browser's
/// install. The reply echoes the object as `forId` so the poller can tell its
/// answer from replies to other tabs.
///
/// SECURITY: DistributedNotificationCenter is a system-wide, unauthenticated
/// bus — any local process can post `ProgressBus.request` and read the
/// `ProgressBus.state` reply. There is no way to authenticate the appex over
/// it, so the snapshot (see `ViaductApp.progressSnapshot`) MUST carry only
/// non-sensitive progress state: no filesystem paths, no license/trial
/// specifics, no secrets.
final class InstallProgressBridge {
    static let shared = InstallProgressBridge()

    /// The store-page install the app took on last. Left in place after the
    /// run ends, since the page only stops polling once it has seen the end;
    /// `isCurrent` tells whether the app is still on it.
    struct StoreInstall: Equatable {
        enum Stage: Equatable {
            /// Waiting on the official-version question; the flow isn't reset yet.
            case asking
            /// Downloading the CRX; the flow was reset and has no input.
            case downloading
            /// Converting the downloaded CRX at this path.
            case converting(inputPath: String)
        }

        let storeId: String
        let browser: Browser
        var stage: Stage

        /// Whether the converter flow still belongs to this install. Once the
        /// window or a batch starts something else, its progress isn't ours.
        func isCurrent(inputPath: String, browser flowBrowser: Browser, asking: Bool) -> Bool {
            switch stage {
            case .asking: return asking
            case .downloading: return inputPath.isEmpty
            case .converting(let path): return path == inputPath && browser == flowBrowser
            }
        }
    }

    /// What a progress poll gets to see.
    enum Answer: Equatable {
        /// The app's progress snapshot: the poll is for the install it's running.
        case snapshot
        /// Nothing is running for this page.
        case idle
        /// This page's install was turned away because another was running.
        case refused
    }

    /// `query` is the poll's `InstalledQuery` object. A page script from
    /// before polls were scoped sends none and gets the snapshot it always got.
    static func answer(to query: String?, current: StoreInstall?, refused: Set<String>) -> Answer {
        guard let query else { return .snapshot }
        let asked = InstalledQuery.parse(query)
        if let current, current.storeId == asked.storeId, current.browser == asked.browser {
            return .snapshot
        }
        return refused.contains(query) ? .refused : .idle
    }

    /// True while the CRX is downloading from the store (before the CLI runs,
    /// while `vm.phase` is still `.idle`).
    var downloading = false

    private(set) var install: StoreInstall?

    /// `InstalledQuery` objects of store installs turned away because another
    /// install was running. Kept until that install is asked for again and
    /// taken on, so the page's card can end instead of waiting.
    private(set) var refused: Set<String> = []

    /// A store page's install the app has taken on. Polls for every other
    /// page and browser see idle from now on.
    func begin(storeId: String, browser: Browser) {
        install = StoreInstall(storeId: storeId, browser: browser, stage: .asking)
        refused.remove(InstalledQuery.busObject(storeId: storeId, browser: browser))
    }

    func advance(to stage: StoreInstall.Stage) {
        install?.stage = stage
    }

    func refuse(storeId: String, browser: Browser) {
        refused.insert(InstalledQuery.busObject(storeId: storeId, browser: browser))
    }

    /// Set by the app at launch; returns the JSON-serializable state dict for a
    /// poll. `queryId` is the poll's `InstalledQuery` object (nil from a page
    /// script that predates scoped polls); the app adds `forId`/`installed`
    /// when it's present.
    /// Runs on the main actor (the observer hops there before calling).
    var snapshot: (String?) -> [String: Any] = { _ in ["state": "idle"] }

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        DistributedNotificationCenter.default().addObserver(
            forName: ProgressBus.request, object: nil, queue: nil
        ) { [weak self] note in
            let queryId = note.object as? String
            Task { @MainActor in self?.reply(queryId: queryId) }
        }
    }

    @MainActor
    private func reply(queryId: String?) {
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot(queryId)),
              let json = String(data: data, encoding: .utf8) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            ProgressBus.state, object: json, userInfo: nil, deliverImmediately: true)
    }
}
