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
/// SECURITY: DistributedNotificationCenter is a system-wide, unauthenticated
/// bus — any local process can post `ProgressBus.request` and read the
/// `ProgressBus.state` reply. There is no way to authenticate the appex over
/// it, so the snapshot (see `ViaductApp.progressSnapshot`) MUST carry only
/// non-sensitive progress state: no filesystem paths, no license/trial
/// specifics, no secrets.
final class InstallProgressBridge {
    static let shared = InstallProgressBridge()

    /// True while the CRX is downloading from the store (before the CLI runs,
    /// while `vm.phase` is still `.idle`).
    var downloading = false

    /// Set by the app at launch; returns the JSON-serializable state dict for a
    /// poll. `queryId` is the installed-check's `InstalledQuery` object (nil
    /// for a plain progress poll); the app adds `forId`/`installed` when it's
    /// present.
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
