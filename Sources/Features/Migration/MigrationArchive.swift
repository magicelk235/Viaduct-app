import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Moves a set of converted extensions to another Mac. Signatures and installed
/// apps are tied to the Mac that built them, so what travels is the source of
/// each extension plus enough to rebuild it under the same name; the new Mac
/// converts them again through the batch queue.
enum MigrationArchive {
    private static let manifestName = "viaduct-extensions.json"

    struct Entry: Codable {
        var name: String
        var appName: String
        var storeId: String?
        var version: String?
        /// Path inside the archive, nil when the source was gone at export time
        /// (store installs re-download by id instead).
        var source: String?
        var iconPNG: Data?
    }

    struct Manifest: Codable {
        var format = 1
        var exported: Date
        var extensions: [Entry]
    }

    enum Failure: LocalizedError {
        case nothingToExport, notAnArchive, zip(String)
        var errorDescription: String? {
            switch self {
            case .nothingToExport: return "There are no converted extensions to export."
            case .notAnArchive:    return "That file isn't a Viaduct extensions export."
            case let .zip(why):    return why
            }
        }
    }

    /// Write every record whose source or store id survives into a zip at `to`.
    /// Returns how many extensions went in.
    @discardableResult
    static func export(_ records: [ConversionRecord], to destination: URL) throws -> Int {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("viaduct-export-\(UUID().uuidString)")
        let root = work.appendingPathComponent("Viaduct extensions", isDirectory: true)
        let sources = root.appendingPathComponent("sources", isDirectory: true)
        try fm.createDirectory(at: sources, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        var entries: [Entry] = []
        for (i, rec) in records.enumerated() {
            var entry = Entry(name: rec.name, appName: rec.resolvedAppName, storeId: rec.storeId,
                              version: rec.version, source: nil, iconPNG: rec.iconData)
            let src = URL(fileURLWithPath: rec.sourcePath)
            if fm.fileExists(atPath: src.path) {
                let ext = src.pathExtension
                let rel = "sources/\(i)" + (ext.isEmpty ? "" : ".\(ext)")
                try fm.copyItem(at: src, to: root.appendingPathComponent(rel))
                entry.source = rel
            } else if rec.storeId == nil {
                continue   // nothing on either side to rebuild from
            }
            entries.append(entry)
        }
        guard !entries.isEmpty else { throw Failure.nothingToExport }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Manifest(exported: Date(), extensions: entries))
            .write(to: root.appendingPathComponent(manifestName))

        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try ditto(["-c", "-k", "--norsrc", "--noextattr", "--keepParent", root.path, destination.path])
        return entries.count
    }

    /// What an import unpacked: the queue items plus the folder their sources
    /// sit in, which has to stay until the queue is done with them.
    struct Unpacked {
        var items: [QueueItem]
        var folder: URL
    }

    /// Where imports unpack. Only a staging area: a conversion archives its own
    /// copy of the source, so nothing here is needed once the batch is over.
    private static var extractionRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Viaduct/migration", isDirectory: true)
    }

    /// Unpack an export and turn it into queue items. Slow on a big export, so
    /// keep it off the main thread.
    static func unpack(_ archive: URL) throws -> Unpacked {
        let fm = FileManager.default
        let dest = extractionRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        do {
            return Unpacked(items: try queueItems(extractedTo: dest, from: archive), folder: dest)
        } catch {
            try? fm.removeItem(at: dest)
            throw error
        }
    }

    private static func queueItems(extractedTo dest: URL, from archive: URL) throws -> [QueueItem] {
        let fm = FileManager.default
        try ditto(["-x", "-k", archive.path, dest.path])

        guard let manifestURL = fm.enumerator(at: dest, includingPropertiesForKeys: nil)?
                .compactMap({ $0 as? URL })
                .first(where: { $0.lastPathComponent == manifestName }) else {
            throw Failure.notAnArchive
        }
        let root = manifestURL.deletingLastPathComponent()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(Manifest.self, from: Data(contentsOf: manifestURL)) else {
            throw Failure.notAnArchive
        }

        return manifest.extensions.map { entry in
            let local = entry.source.map { root.appendingPathComponent($0) }
            var item = QueueItem(name: entry.appName, iconPNG: entry.iconPNG,
                                 storeId: entry.storeId, chromeId: entry.storeId) {
                if let local, FileManager.default.fileExists(atPath: local.path) { return local }
                guard let id = entry.storeId else { throw Failure.notAnArchive }
                return try await ChromeStore.downloadCRX(id: id)
            }
            if local == nil { item.note = "Downloads from the Chrome Web Store" }
            return item
        }
    }

    /// Delete unpacked imports: `folder` alone, or every one when it's nil.
    /// One that a history record still points into stays, which only happens
    /// when archiving that record's source failed and the record kept this path.
    static func removeExtracted(_ folder: URL? = nil, keeping sourcePaths: [String]) {
        let fm = FileManager.default
        let folders = folder.map { [$0] }
            ?? (try? fm.contentsOfDirectory(at: extractionRoot, includingPropertiesForKeys: nil)) ?? []
        for dir in folders {
            let prefix = dir.standardizedFileURL.path + "/"
            guard !sourcePaths.contains(where: { $0.hasPrefix(prefix) }) else { continue }
            try? fm.removeItem(at: dir)
        }
    }

    private static func ditto(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Failure.zip(msg.isEmpty ? "ditto exited with \(p.terminationStatus)." : msg)
        }
    }
}

/// Whether an export or import is being written or unpacked. Lives outside the
/// view so closing and reopening Settings mid-way can't start a second one.
@MainActor
private final class MigrationWork: ObservableObject {
    static let shared = MigrationWork()
    @Published var isBusy = false
}

/// Settings card with the two halves of a move.
struct MigrationSection: View {
    @ObservedObject var vm: ConverterViewModel
    @ObservedObject var history: ConversionHistory
    @ObservedObject private var queue = ConversionQueue.shared
    @ObservedObject private var work = MigrationWork.shared
    @State private var status: String?

    var body: some View {
        SettingsSection(title: "Move to another Mac", symbol: "shippingbox.and.arrow.backward") {
            HStack {
                Button("Export") { exportAll() }
                    .buttonStyle(.raycastTertiary)
                    .disabled(work.isBusy || !history.records.contains { $0.browser == .safari })
                Button("Import") { importArchive() }
                    .buttonStyle(.raycastTertiary)
                    .disabled(work.isBusy || vm.isRunning || queue.isRunning)
                Spacer()
            }
            if let status {
                Text(status)
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.Colors.mute)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func exportAll() {
        guard !work.isBusy else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Viaduct extensions.zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // The archive has no browser field, so a Firefox record would come
        // back on the other Mac as a Safari conversion.
        let records = history.records.filter { $0.browser == .safari }
        work.isBusy = true
        status = "Exporting…"
        Task { @MainActor in
            // Copying every source and zipping them takes a while on a long history.
            let result = await Task.detached(priority: .userInitiated) {
                Result { try MigrationArchive.export(records, to: url) }
            }.value
            work.isBusy = false
            switch result {
            case let .success(n):
                status = "Exported \(n) extension\(n == 1 ? "" : "s")."
                NSWorkspace.shared.activateFileViewerSelecting([url])
            case let .failure(error):
                status = error.localizedDescription
            }
        }
    }

    private func importArchive() {
        guard !work.isBusy, !queue.isRunning else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Viaduct extensions export."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let kept = history.records.map(\.sourcePath)
        work.isBusy = true
        status = "Unpacking…"
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                Result { () throws -> MigrationArchive.Unpacked in
                    // No batch is running, so nothing an earlier import
                    // unpacked is still waiting to be converted.
                    MigrationArchive.removeExtracted(keeping: kept)
                    return try MigrationArchive.unpack(url)
                }
            }.value
            work.isBusy = false
            let unpacked: MigrationArchive.Unpacked
            switch result {
            case let .success(value):
                unpacked = value
            case let .failure(error):
                status = error.localizedDescription
                return
            }

            // Something else may have started a batch while this was unpacking.
            guard !unpacked.items.isEmpty, !queue.isRunning else {
                status = unpacked.items.isEmpty ? "That export has no extensions in it."
                                                : "Another batch is already converting. Try again when it's done."
                MigrationArchive.removeExtracted(unpacked.folder, keeping: [])
                return
            }
            status = nil
            // The queue's sheet lives on the main window.
            MainWindow.show()
            queue.start(unpacked.items, vm: vm)

            // Items only read their source when their turn comes, so the
            // unpacked folder has to outlive the whole batch.
            for await running in queue.$isRunning.values where !running { break }
            let stillUsed = history.records.map(\.sourcePath)
            let folder = unpacked.folder
            await Task.detached(priority: .utility) {
                MigrationArchive.removeExtracted(folder, keeping: stillUsed)
            }.value
        }
    }
}
