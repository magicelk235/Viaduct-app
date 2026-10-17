import Foundation

/// One converted extension, persisted across launches.
struct ConversionRecord: Codable, Identifiable {
    var id = UUID()
    var name: String
    var sourcePath: String
    /// The --app-name used, so a rebuild lands on the exact same .app.
    /// Optional so old records still decode; falls back to `name` when absent.
    var appName: String?
    var installedPath: String?
    var date: Date

    /// True when the build that produced this record came out ad-hoc signed —
    /// the CLI falls back to it when the team it detected can't sign, and Safari
    /// then disables the extension every time it quits. Optional so records
    /// written before the fallback existed still decode (nil → not known to be
    /// ad-hoc, which is what every team-signed record is).
    var adHoc: Bool?
    /// Whether the last Chrome Web Store update failed to rebuild. Shown in
    /// Settings; the installed version keeps working either way.
    var lastUpdateFailed: Bool?
    /// PNG of the extension's own icon, captured at conversion time. Optional
    /// so old records (and icon-less extensions) still decode.
    var iconData: Data?
    /// Chrome Web Store id for store-flow installs. Lets auto-update re-download
    /// the .crx when the store ships a new version.
    var storeId: String?
    /// Chrome extension id, whatever the source (store, a browser profile, a
    /// zip with a manifest key). `storeId` only covers store installs and also
    /// drives store auto-update, so it can't double as this. Lets Import from
    /// Chrome see an extension is already in Safari. Optional for old records.
    var chromeId: String?

    /// Upstream extension version (manifest "version") at build time. Auto-update
    /// compares the latest CWS manifest against this to decide whether to rebuild.
    /// Optional so old records still decode (nil → "unknown", adopt live version).
    var version: String?

    /// Last time auto-update polled the CWS for this record. Gates the weekly
    /// cadence: skip records checked within the last 7 days. Optional so old
    /// records decode (nil → check on next pass).
    var lastUpdateCheck: Date?

    /// When Viaduct removes this extension, for one converted on the free plan.
    /// Nil for Pro conversions, and for anything converted before the free plan
    /// had this limit, so those stay. Activating Pro clears it on every record.
    var freeRemovesAt: Date?

    /// Effective app name for rebuilds.
    var resolvedAppName: String { appName ?? name }
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
             installedPath: String?, build: SigningAccount.Build,
             iconData: Data?, storeId: String? = nil, chromeId: String? = nil,
             version: String? = nil, freeRemovesAt: Date? = nil) {
        let now = Date()
        var record = ConversionRecord(name: name, sourcePath: sourcePath,
                                      appName: appName, installedPath: installedPath,
                                      date: now, adHoc: build.adHoc,
                                      iconData: iconData,
                                      storeId: storeId, chromeId: chromeId ?? storeId,
                                      version: version)
        record.freeRemovesAt = freeRemovesAt
        // Re-converting the same app replaces its record instead of stacking duplicates.
        records.removeAll { $0.resolvedAppName == appName }
        records.insert(record, at: 0)
        if records.count > 200 { records.removeLast(records.count - 200) }
        save()
    }

    /// Free-plan extensions still waiting to be removed.
    var pendingFreeRemovals: [ConversionRecord] {
        records.filter { $0.freeRemovesAt != nil }
    }

    /// Pro keeps everything: forget every free-plan removal date.
    func keepAllFreeExtensions() {
        guard records.contains(where: { $0.freeRemovesAt != nil }) else { return }
        for i in records.indices { records[i].freeRemovesAt = nil }
        save()
    }

    /// Remove the free-plan extensions whose time is up. Returns what went.
    func removeExpiredFreeExtensions(now: Date = Date()) -> [ConversionRecord] {
        let due = records.filter { ($0.freeRemovesAt ?? .distantFuture) <= now }
        due.forEach { remove($0) }
        return due
    }

    /// Stamp a record after a successful auto-update: new upstream version built.
    /// Also stamps the update-check timestamp.
    func markUpdated(id: ConversionRecord.ID, version: String, installedPath: String?,
                     build: SigningAccount.Build) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].version = version
        records[i].adHoc = build.adHoc
        records[i].lastUpdateCheck = Date()
        records[i].lastUpdateFailed = false
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

    /// The store had a new version but rebuilding it failed.
    func markUpdateFailed(id: ConversionRecord.ID) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].lastUpdateFailed = true
        save()
    }

    /// Point a record at a fresh source copy (an update re-downloaded it).
    func updateSource(id: ConversionRecord.ID, path: String) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].sourcePath = path
        save()
    }

    func clear() { records.removeAll(); save() }

    /// Drop records whose installed .app the user deleted from Finder, and clean
    /// their archived source — so auto-update won't rebuild an app they removed.
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

    /// Drop a record AND delete its archived source + installed .app, so
    /// auto-update can never rebuild it. Best-effort
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

    /// Same check keyed on the Chrome id, for sources that didn't come from
    /// the store (Edge/Opera profiles, unpacked folders).
    func isInstalled(chromeId: String) -> Bool {
        records.contains { rec in
            (rec.chromeId ?? rec.storeId) == chromeId
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
