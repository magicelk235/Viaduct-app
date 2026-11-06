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
    nonisolated static var archiveDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Viaduct/sources", isDirectory: true)
    }

    /// Copy `path` into the archive, keyed by browser and app name. Returns the
    /// archived path (or nil on failure — caller then keeps the original path).
    static func archiveSource(_ path: String, appName: String, browser: Browser, root: URL = archiveDir) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path), !appName.isEmpty else { return nil }
        do {
            // Safari's copies stay at the top, where records from before
            // Firefox point. Firefox gets a folder so the same name can't clash.
            let dir = browser == .safari ? root : root.appendingPathComponent("firefox", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let source = URL(fileURLWithPath: path)
            let ext = source.pathExtension
            // One slot per app name; re-convert overwrites it. Dirs (unpacked)
            // and archives both handled by copyItem.
            let dest = dir.appendingPathComponent(appName)
                .appendingPathExtension(ext.isEmpty ? "src" : ext)
            // Convert Again converts the archived copy itself. Deleting the
            // destination first would leave nothing to copy.
            if source.standardizedFileURL.path == dest.standardizedFileURL.path { return dest.path }
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: source, to: dest)
            return dest.path
        } catch { return nil }
    }

    /// Whether a license turns the weekly store update on. Any license does;
    /// which records it then looks after depends on the browsers it covers.
    nonisolated static func isUnlocked(by entitlements: Entitlements) -> Bool {
        entitlements != .none
    }

    /// Whether the weekly store update looks after this record: a store
    /// install, under a license that covers the browser it went into.
    nonisolated static func covers(_ rec: ConversionRecord, entitlements: Entitlements) -> Bool {
        rec.storeId != nil && entitlements.unlimited(rec.browser)
    }

    /// Store installs due for a weekly CWS version poll: covered by the license
    /// and not checked in the last week. Local-source-only records have no
    /// upstream to poll, so they're excluded.
    private func dueForUpdateCheck() -> [ConversionRecord] {
        let now = Date()
        let entitlements = LicenseManager.shared.entitlements
        return history.records.filter { rec in
            Self.covers(rec, entitlements: entitlements)
            && UpdatePolicy.dueForUpdateCheck(lastCheck: rec.lastUpdateCheck, now: now)
        }
    }

    /// Poll the CWS for newer versions of store installs and rebuild any that
    /// changed. Silent, best-effort. The per-record weekly gate means this is a
    /// no-op most days even though it's called on the daily tick. Auto-update
    /// enablement is checked by the caller (ConverterViewModel).
    func updateIfNeeded() {
        guard !running, !runner.isRunning, CLIRunner.resolveCLIScript() != nil else { return }
        running = true
        Task { @MainActor in
            defer { running = false }
            await history.pruneDeleted()
            for rec in dueForUpdateCheck() { await update(rec) }
        }
    }

    private func update(_ rec: ConversionRecord) async {
        guard let sid = rec.storeId else { return }
        // A Firefox add-on needs Firefox to build into. Without it, try again
        // next week rather than report a failure.
        var firefox: FirefoxLocator.Install?
        if rec.browser == .firefox {
            firefox = FirefoxLocator.find()
            guard firefox != nil else {
                history.stampUpdateCheck(id: rec.id)
                return
            }
        }
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
        let sourcePath = Self.archiveSource(crx.path, appName: rec.resolvedAppName, browser: rec.browser) ?? crx.path
        history.updateSource(id: rec.id, path: sourcePath)
        if let firefox {
            do {
                _ = try await FirefoxConversion.run(input: sourcePath, appName: rec.resolvedAppName, firefox: firefox,
                                                    profile: rec.profilePath, addons: .shared)
                // Persist keeps the add-on itself: there's no .app, and nothing signed ad-hoc.
                history.markUpdated(id: rec.id, version: latest, installedPath: nil,
                                    build: SigningAccount.Build(adHoc: false))
            } catch {
                updateFailed(rec)
            }
            return
        }
        let code = await rebuild(sourcePath: sourcePath, appName: rec.resolvedAppName)
        if code == 0 {
            history.markUpdated(id: rec.id, version: latest,
                                installedPath: rec.installedPath,
                                build: SigningAccount.inspectBuild(installedAppPath: rec.installedPath))
        } else {
            updateFailed(rec)
        }
    }

    /// The rebuild failed: stamp the poll so we don't hammer it, and surface it.
    private func updateFailed(_ rec: ConversionRecord) {
        history.stampUpdateCheck(id: rec.id)
        history.markUpdateFailed(id: rec.id)
        notifyFailure(rec)
    }

    /// Run a full convert+install from source via the CLI, signing with the same
    /// Apple team a conversion would use. Returns the CLI exit code.
    private func rebuild(sourcePath: String, appName: String) async -> Int32 {
        var opts = ConvertOptions()
        opts.inputPath = sourcePath
        opts.appName = appName
        opts.useTeam(SigningAccount.signingTeam()?.id)
        opts.force = true          // never block a rebuild on advisory issues
        return await Self.runCLI(opts.conversionArgs())
    }

    /// Run the CLI with `args` and return its exit code, or -1 when it can't
    /// start. A conversion the user started holds the CLI; wait for it instead
    /// of logging a failed update that never ran.
    static func runCLI(_ args: [String]) async -> Int32 {
        let runner = CLIRunner.shared
        while runner.isRunning {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return await withCheckedContinuation { cont in
            do {
                try runner.run(args: args, onLine: { _ in }) { c in
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
