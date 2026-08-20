import Foundation

/// One converted extension, persisted across launches.
struct ConversionRecord: Codable, Identifiable {
    var id = UUID()
    var name: String
    var sourcePath: String
    /// The --app-name used, so auto-renew rebuilds to the exact same .app.
    /// Optional so old records still decode; falls back to `name` when absent.
    var appName: String?
    var installedPath: String?
    var date: Date
    /// When this build's signature was last refreshed. Used by auto-renew to find
    /// builds nearing expiry. Old records fall back to `date`.
    var lastSigned: Date?
    /// When that signature lapses, resolved at signing time from the Apple
    /// account that signed it (a free Apple ID gets a week, a paid Developer
    /// Program membership a year) or from a provisioning profile the build
    /// embedded. Optional so records written before the two were told apart
    /// still decode — those keep the free-account week they were scheduled on,
    /// and get a real date at their next renew.
    var signatureExpiry: Date?
    /// Last time auto-renew tried this record, and whether it failed. Surfaced in
    /// Settings so the user sees a silent failure before Safari drops the extension.
    var lastRenewAttempt: Date?
    var lastRenewFailed: Bool?
    /// PNG of the extension's own icon, captured at conversion time. Optional
    /// so old records (and icon-less extensions) still decode.
    var iconData: Data?
    /// Chrome Web Store id for store-flow installs. Lets auto-renew re-download
    /// the .crx if the archived source vanishes (cache purge, failed archive).
    var storeId: String?

    /// Upstream extension version (manifest "version") at build time. Auto-update
    /// compares the latest CWS manifest against this to decide whether to rebuild.
    /// Optional so old records still decode (nil → "unknown", adopt live version).
    var version: String?

    /// Last time auto-update polled the CWS for this record. Gates the weekly
    /// cadence: skip records checked within the last 7 days. Optional so old
    /// records decode (nil → check on next pass).
    var lastUpdateCheck: Date?

    /// Effective app name for rebuilds.
    var resolvedAppName: String { appName ?? name }
    /// When this build's signature is assumed to lapse.
    var expiresAt: Date {
        signatureExpiry
            ?? (lastSigned ?? date).addingTimeInterval(RenewalPolicy.freeSignatureLifetime)
    }
    /// Last time this build was (re)signed — the once-a-week renew cap keys off this.
    var lastBuild: Date { lastSigned ?? date }
}

/// Append-only history of converted extensions, backed by UserDefaults.
/// UserDefaults JSON, fine for a list of conversions; move to a file/db only if it grows huge.
@MainActor
final class ConversionHistory: ObservableObject {
    @Published private(set) var records: [ConversionRecord] = []

    private let key = "conversionHistory"
    private let defaults = UserDefaults.standard

    init() { load() }

    func add(name: String, sourcePath: String, appName: String,
             installedPath: String?, signatureExpiry: Date?, iconData: Data?,
             storeId: String? = nil, version: String? = nil) {
        let now = Date()
        let record = ConversionRecord(name: name, sourcePath: sourcePath,
                                      appName: appName, installedPath: installedPath,
                                      date: now, lastSigned: now,
                                      signatureExpiry: signatureExpiry, iconData: iconData,
                                      storeId: storeId, version: version)
        // Re-converting the same app replaces its record instead of stacking duplicates.
        records.removeAll { $0.resolvedAppName == appName }
        records.insert(record, at: 0)
        if records.count > 200 { records.removeLast(records.count - 200) }
        save()
    }

    /// Stamp a record as freshly re-signed (called after a successful auto-renew).
    /// The new expiry comes from the caller because the account can have changed
    /// since the last build — someone who joined the Developer Program in the
    /// meantime should stop being renewed weekly.
    func markRenewed(id: ConversionRecord.ID, installedPath: String?, signatureExpiry: Date?) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        let now = Date()
        records[i].lastSigned = now
        records[i].signatureExpiry = signatureExpiry
        records[i].lastRenewAttempt = now
        records[i].lastRenewFailed = false
        if let p = installedPath { records[i].installedPath = p }
        save()
    }

    /// Stamp a record after a successful auto-update: new upstream version built.
    /// An update is also a fresh sign, so lastSigned and the expiry advance too
    /// (which resets the once-a-week renew cap). Also stamps the update-check
    /// timestamp.
    func markUpdated(id: ConversionRecord.ID, version: String, installedPath: String?,
                     signatureExpiry: Date?) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        let now = Date()
        records[i].version = version
        records[i].lastSigned = now
        records[i].signatureExpiry = signatureExpiry
        records[i].lastUpdateCheck = now
        records[i].lastRenewAttempt = now
        records[i].lastRenewFailed = false
        if let p = installedPath { records[i].installedPath = p }
        save()
    }

    /// Record that we polled the CWS for this extension (whether or not the
    /// version changed). Drives the weekly poll cadence.
    func stampUpdateCheck(id: ConversionRecord.ID) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].lastUpdateCheck = Date()
        save()
    }

    /// Stamp a failed auto-renew attempt (lastSigned stays put — still on the old expiry).
    func markRenewFailed(id: ConversionRecord.ID) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].lastRenewAttempt = Date()
        records[i].lastRenewFailed = true
        save()
    }

    /// Point a record at a fresh source copy (renew re-downloaded/re-archived it).
    func updateSource(id: ConversionRecord.ID, path: String) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].sourcePath = path
        save()
    }

    func clear() { records.removeAll(); save() }

    /// Drop records whose installed .app the user deleted from Finder, and clean
    /// their archived source — so auto-renew won't rebuild an app they removed.
    func pruneDeleted() {
        let fm = FileManager.default
        let gone = records.filter { rec in
            guard let p = rec.installedPath else { return false }
            return !fm.fileExists(atPath: p)
        }
        guard !gone.isEmpty else { return }
        for rec in gone { try? fm.removeItem(atPath: rec.sourcePath) }
        let goneIDs = Set(gone.map(\.id))
        records.removeAll { goneIDs.contains($0.id) }
        save()
    }

    /// Drop a record AND delete its archived source + installed .app, so auto-renew
    /// can never rebuild it (renew skips records whose source is gone). Best-effort
    /// on the file deletes — a stale .app left on disk is harmless.
    func remove(_ record: ConversionRecord) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: record.sourcePath)
        if let p = record.installedPath { try? fm.removeItem(atPath: p) }
        records.removeAll { $0.id == record.id }
        save()
    }

    /// True if a store extension (by CWS id) is installed — a record exists and
    /// its .app is still on disk. Drives the store page's Remove-vs-Add button.
    func isInstalled(storeId: String) -> Bool {
        records.contains { rec in
            rec.storeId == storeId
                && (rec.installedPath.map { FileManager.default.fileExists(atPath: $0) } ?? false)
        }
    }

    /// Remove every install for a CWS store id (the store-page uninstall path):
    /// deletes each build's .app + archived source and drops the record.
    @discardableResult
    func removeByStoreId(_ storeId: String) -> Bool {
        let matches = records.filter { $0.storeId == storeId }
        matches.forEach { remove($0) }
        return !matches.isEmpty
    }

    private func load() {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ConversionRecord].self, from: data)
        else { return }
        records = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: key)
        }
    }
}
