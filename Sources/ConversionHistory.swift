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
    /// Nil for conversions a license covers, and for anything converted before
    /// the free plan had this limit, so those stay. Adding a license clears it
    /// on every record the license covers.
    var freeRemovesAt: Date?

    /// The browser it was converted for. Records from before Firefox have no
    /// such key, and every one of them went to Safari.
    var browser: Browser = .safari
    /// The add-on id persist keeps it under. Firefox only.
    var addonId: String?
    /// The Firefox profile it went into. Firefox only.
    var profilePath: String?

    /// Effective app name for rebuilds.
    var resolvedAppName: String { appName ?? name }
}

// Decoding lives in an extension so the struct keeps its memberwise initializer.
extension ConversionRecord {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        sourcePath = try container.decode(String.self, forKey: .sourcePath)
        appName = try container.decodeIfPresent(String.self, forKey: .appName)
        installedPath = try container.decodeIfPresent(String.self, forKey: .installedPath)
        date = try container.decode(Date.self, forKey: .date)
        adHoc = try container.decodeIfPresent(Bool.self, forKey: .adHoc)
        lastUpdateFailed = try container.decodeIfPresent(Bool.self, forKey: .lastUpdateFailed)
        iconData = try container.decodeIfPresent(Data.self, forKey: .iconData)
        storeId = try container.decodeIfPresent(String.self, forKey: .storeId)
        chromeId = try container.decodeIfPresent(String.self, forKey: .chromeId)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        lastUpdateCheck = try container.decodeIfPresent(Date.self, forKey: .lastUpdateCheck)
        freeRemovesAt = try container.decodeIfPresent(Date.self, forKey: .freeRemovesAt)
        browser = try container.decodeIfPresent(Browser.self, forKey: .browser) ?? .safari
        addonId = try container.decodeIfPresent(String.self, forKey: .addonId)
        profilePath = try container.decodeIfPresent(String.self, forKey: .profilePath)
    }
}

/// Append-only history of converted extensions, backed by UserDefaults.
/// UserDefaults JSON, fine for a list of conversions; move to a file/db only if it grows huge.
@MainActor
final class ConversionHistory: ObservableObject {
    @Published private(set) var records: [ConversionRecord] = []

    private let key = "conversionHistory"
    private let defaults: UserDefaults
    /// Installs and removes the Firefox records' add-ons.
    private let firefox: FirefoxAddons

    init(defaults: UserDefaults = .standard, firefox: FirefoxAddons) {
        self.defaults = defaults
        self.firefox = firefox
        load()
    }

    /// For the app's own Firefox add-ons. Not a `= .shared` default: default
    /// arguments are evaluated off the main actor.
    convenience init(defaults: UserDefaults = .standard) {
        self.init(defaults: defaults, firefox: .shared)
    }

    func add(browser: Browser, name: String, sourcePath: String, appName: String, installedPath: String?,
             adHoc: Bool?, iconData: Data?, storeId: String? = nil, chromeId: String? = nil, version: String? = nil,
             freeRemovesAt: Date? = nil, addonId: String? = nil, profilePath: String? = nil) {
        let now = Date()
        var record = ConversionRecord(name: name, sourcePath: sourcePath,
                                      appName: appName, installedPath: installedPath,
                                      date: now, adHoc: adHoc,
                                      iconData: iconData,
                                      storeId: storeId, chromeId: chromeId ?? storeId,
                                      version: version)
        record.browser = browser
        record.addonId = addonId
        record.profilePath = profilePath
        record.freeRemovesAt = freeRemovesAt
        // Re-converting the same app replaces its record instead of stacking
        // duplicates. Each browser keeps its own, and so does each Firefox
        // profile: dropping one profile's record would orphan its add-on.
        records.removeAll {
            $0.browser == browser && $0.resolvedAppName == appName && $0.profilePath == profilePath
        }
        records.insert(record, at: 0)
        if records.count > 200 { records.removeLast(records.count - 200) }
        save()
    }

    /// Free-plan extensions still waiting to be removed.
    var pendingFreeRemovals: [ConversionRecord] {
        records.filter { $0.freeRemovesAt != nil }
    }

    /// A license keeps what it covers: forget the free-plan removal date on
    /// the records `covered` matches.
    func keepFreeExtensions(where covered: (ConversionRecord) -> Bool) {
        var kept = records
        var changed = false
        for i in kept.indices where kept[i].freeRemovesAt != nil && covered(kept[i]) {
            kept[i].freeRemovesAt = nil
            changed = true
        }
        guard changed else { return }
        records = kept
        save()
    }

    /// Remove the free-plan extensions whose time is up, and return the ones
    /// that went. A removal that fails, such as an add-on Firefox only lets go
    /// of by restarting, keeps its record and date so the next sweep retries it.
    func removeExpiredFreeExtensions(now: Date) async -> [ConversionRecord] {
        let due = records.filter { ($0.freeRemovesAt ?? .distantFuture) <= now }.map(\.id)
        var removed: [ConversionRecord] = []
        for id in due {
            // Each removal can wait on Firefox. Meanwhile a license can keep
            // the rest, or the user can remove one, so go by the record as it is now.
            guard let rec = records.first(where: { $0.id == id }),
                  (rec.freeRemovesAt ?? .distantFuture) <= now else { continue }
            do {
                try await remove(rec)
                removed.append(rec)
            } catch {}
        }
        return removed
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

    /// Drop records whose install is gone, and clean their archived sources,
    /// so auto-update won't rebuild them: a Safari .app the user deleted in
    /// Finder, or a Firefox add-on persist no longer keeps.
    func pruneDeleted() async {
        let fm = FileManager.default
        drop(records.filter { rec in
            guard rec.browser == .safari, let p = rec.installedPath else { return false }
            return !fm.fileExists(atPath: p)
        })

        // A record added while persist answers can be newer than its list, so
        // only older ones are judged. A list that fails says nothing.
        let asked = Date()
        guard let kept = try? await firefox.persist.list() else { return }
        drop(records.filter { rec in
            rec.browser == .firefox && rec.date < asked
                && !kept.contains { $0.id == rec.addonId && $0.profilePath == rec.profilePath }
        })
    }

    /// Remove an extension for good: uninstall a Firefox add-on through
    /// persist or delete a Safari .app, then drop the record and its archived
    /// source, so auto-update can't rebuild it. When persist can't uninstall,
    /// this throws and keeps the record. Firefox restarts for this only with
    /// `restartFirefox`, which callers pass after the user saw the restart notice.
    func remove(_ record: ConversionRecord, restartFirefox: Bool = false) async throws {
        if record.browser == .firefox, let id = record.addonId {
            try await firefox.uninstall(id: id, profile: record.profilePath, restart: restartFirefox)
        }
        // Best-effort: a stale .app left on disk is harmless.
        if let p = record.installedPath { try? FileManager.default.removeItem(atPath: p) }
        drop([record])
    }

    /// Drop records and delete their archived sources, except a source another
    /// record still uses: an add-on kept in two Firefox profiles has one.
    private func drop(_ gone: [ConversionRecord]) {
        guard !gone.isEmpty else { return }
        let ids = Set(gone.map(\.id))
        records.removeAll { ids.contains($0.id) }
        let inUse = Set(records.map(\.sourcePath))
        for path in Set(gone.map(\.sourcePath)) where !inUse.contains(path) {
            try? FileManager.default.removeItem(atPath: path)
        }
        save()
    }

    /// Whether a record's install is still there. A Safari one needs its .app
    /// on disk. A Firefox add-on lives with persist, so it counts until
    /// pruning finds persist dropped it.
    func isPresent(_ rec: ConversionRecord) -> Bool {
        switch rec.browser {
        case .safari: return rec.installedPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
        case .firefox: return true
        }
    }

    /// True if a store extension (by CWS id) is installed in `browser`.
    /// Drives the store page's Remove-vs-Add button.
    func isInstalled(storeId: String, browser: Browser) -> Bool {
        records.contains { rec in
            rec.storeId == storeId && rec.browser == browser && isPresent(rec)
        }
    }

    /// Same check keyed on the Chrome id, for sources that didn't come from
    /// the store (Edge/Opera profiles, unpacked folders).
    func isInstalled(chromeId: String, browser: Browser) -> Bool {
        records.contains { rec in
            (rec.chromeId ?? rec.storeId) == chromeId && rec.browser == browser && isPresent(rec)
        }
    }

    /// Remove every install of a CWS store id in `browser` (the store-page
    /// Remove). One that doesn't go through stays, and the page keeps showing
    /// it as installed.
    @discardableResult
    func removeByStoreId(_ storeId: String, browser: Browser) async -> Bool {
        let matches = records.filter { $0.storeId == storeId && $0.browser == browser }
        for rec in matches { try? await remove(rec) }
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
