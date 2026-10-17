import Foundation
import UserNotifications

/// Downloading .crx packages from the Chrome Web Store — shared by the
/// store-page install flow and auto-update.
enum ChromeStore {
    struct DownloadError: LocalizedError {
        let status: Int
        var errorDescription: String? {
            "Couldn't download that extension from the Chrome Web Store (status \(status)). It may be delisted, region-blocked, or restricted to managed installs."
        }
    }

    /// The endpoint gates on prodversion: an extension whose minimum_chrome_version
    /// is newer than the version we claim comes back 204 with an empty body rather
    /// than an error (this is what broke Enhancer for YouTube on the old hardcoded
    /// 120.0.0.0). Chrome majors move every few weeks, so ask as current-ish stable
    /// first, then as a version nothing can gate past.
    private static let prodVersions = ["138.0", "9999.0"]

    /// Fetch the .crx for a store extension id into Caches. Verifies the "Cr24"
    /// magic bytes: a failed lookup follows the redirect to a 404 HTML page, so
    /// status alone isn't enough.
    static func downloadCRX(id: String) async throws -> URL {
        let fm = FileManager.default
        var lastStatus = 0
        for prodVersion in prodVersions {
            let urlStr = "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=\(prodVersion)&acceptformat=crx2,crx3&x=id%3D\(id)%26installsource%3Dondemand%26uc"
            guard let url = URL(string: urlStr) else { throw URLError(.badURL) }
            let (tempURL, response) = try await URLSession.shared.download(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            let isCRX = (try? FileHandle(forReadingFrom: tempURL))
                .map { fh in defer { try? fh.close() }; return fh.readData(ofLength: 4) == Data("Cr24".utf8) } ?? false
            guard status == 200, isCRX else {
                lastStatus = status
                try? fm.removeItem(at: tempURL)
                continue
            }
            let dest = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("\(id).crx")
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: tempURL, to: dest)
            return dest
        }
        throw DownloadError(status: lastStatus)
    }
}

/// Keeps Chrome Web Store installs current: polls the store weekly and, when an
/// extension ships a new version, rebuilds it from the fresh package through
/// the same CLI path a conversion uses.
@MainActor
final class ExtensionUpdater {
    private let history: ConversionHistory
    private let runner = CLIRunner.shared
    private var running = false
    var isRunning: Bool { running }

    init(history: ConversionHistory) { self.history = history }

    /// Durable copy of converted sources, so a move to another Mac (and a
    /// rebuild) survives the user moving the original file or macOS purging
    /// the Caches-dir store download.
    static var archiveDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Viaduct/sources", isDirectory: true)
    }

    /// Copy `path` into the archive, keyed by app name. Returns the archived path
    /// (or nil on failure — caller then keeps the original path).
    static func archiveSource(_ path: String, appName: String) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path), !appName.isEmpty else { return nil }
        do {
            try fm.createDirectory(at: archiveDir, withIntermediateDirectories: true)
            let ext = URL(fileURLWithPath: path).pathExtension
            // One slot per app name; re-convert overwrites it. Dirs (unpacked)
            // and archives both handled by copyItem.
            let dest = archiveDir.appendingPathComponent(appName)
                .appendingPathExtension(ext.isEmpty ? "src" : ext)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: URL(fileURLWithPath: path), to: dest)
            return dest.path
        } catch { return nil }
    }

    /// Store installs due for a weekly CWS version poll: has a storeId and hasn't
    /// been checked in the last week. Local-source-only records have no upstream
    /// to poll, so they're excluded.
    private func dueForUpdateCheck() -> [ConversionRecord] {
        let now = Date()
        return history.records.filter { rec in
            rec.storeId != nil
            && UpdatePolicy.dueForUpdateCheck(lastCheck: rec.lastUpdateCheck, now: now)
        }
    }

    /// Poll the CWS for newer versions of store installs and rebuild any that
    /// changed. Silent, best-effort. The per-record weekly gate means this is a
    /// no-op most days even though it's called on the daily tick. Auto-update
    /// enablement is checked by the caller (ConverterViewModel).
    func updateIfNeeded() {
        guard !running, !runner.isRunning, CLIRunner.resolveCLIScript() != nil else { return }
        history.pruneDeleted()
        let due = dueForUpdateCheck()
        guard !due.isEmpty else { return }
        running = true
        Task { @MainActor in
            defer { running = false }
            for rec in due { await update(rec) }
        }
    }

    private func update(_ rec: ConversionRecord) async {
        guard let sid = rec.storeId else { return }
        // Poll the CWS. Any failure: stamp the check (don't retry until next week)
        // and move on — a transient store hiccup shouldn't spin.
        guard let crx = try? await ChromeStore.downloadCRX(id: sid) else {
            history.stampUpdateCheck(id: rec.id)
            return
        }
        let latest = ExtensionInspector.inspectSync(path: crx.path)?.version
        // Couldn't read a version, or it's unchanged: just record the poll.
        guard let latest, UpdatePolicy.versionChanged(stored: rec.version, latest: latest) else {
            history.stampUpdateCheck(id: rec.id)
            return
        }
        // New version — archive the fresh source and rebuild from it.
        let sourcePath = Self.archiveSource(crx.path, appName: rec.resolvedAppName) ?? crx.path
        history.updateSource(id: rec.id, path: sourcePath)
        let code = await rebuild(sourcePath: sourcePath, appName: rec.resolvedAppName)
        if code == 0 {
            history.markUpdated(id: rec.id, version: latest,
                                installedPath: rec.installedPath,
                                build: SigningAccount.inspectBuild(installedAppPath: rec.installedPath))
        } else {
            // Build failed: stamp the poll so we don't hammer it, and surface it.
            history.stampUpdateCheck(id: rec.id)
            history.markUpdateFailed(id: rec.id)
            notifyFailure(rec)
        }
    }

    /// Run a full convert+install from source via the CLI, signing with the same
    /// Apple team a conversion would use. Returns the CLI exit code.
    private func rebuild(sourcePath: String, appName: String) async -> Int32 {
        var opts = ConvertOptions()
        opts.inputPath = sourcePath
        opts.appName = appName
        opts.useTeam(SigningAccount.signingTeam()?.id)
        opts.force = true          // never block a rebuild on advisory issues

        // A conversion the user started holds the CLI; wait for it instead of
        // logging a failed update that never ran.
        while runner.isRunning {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return await withCheckedContinuation { cont in
            do {
                try runner.run(args: opts.conversionArgs(), onLine: { _ in }) { c in
                    cont.resume(returning: c)
                }
            } catch {
                cont.resume(returning: -1)
            }
        }
    }

    /// Tell the user an update didn't go through; the installed version keeps
    /// working, so this is a heads-up rather than an alarm.
    private func notifyFailure(_ rec: ConversionRecord) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Couldn't update \(rec.resolvedAppName)"
            content.body = "The Chrome Web Store has a new version, but Viaduct couldn't convert it. The version you have still works."
            content.sound = .default
            // Nil trigger = deliver now. No identifier reuse needed; one per failure.
            center.add(UNNotificationRequest(identifier: rec.id.uuidString,
                                             content: content, trigger: nil))
        }
    }
}
