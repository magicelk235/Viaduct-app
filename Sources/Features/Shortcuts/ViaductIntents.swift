import AppIntents
import Foundation

/// Shortcuts actions.
struct ShortcutsError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: message) }

    static let notReady = ShortcutsError(message: "Viaduct isn't ready yet. Open it once, then run the shortcut again.")
}

struct ConvertExtensionIntent: AppIntent {
    static var title: LocalizedStringResource = "Convert Chrome Extension"
    static var description = IntentDescription("Converts a Chrome extension (.zip or .crx) and installs it in Safari or Firefox. Waits until it's done.")
    static var openAppWhenRun = true

    @Parameter(title: "Extension", supportedTypeIdentifiers: ["public.zip-archive", "public.data", "public.folder"])
    var file: IntentFile

    @Parameter(title: "Browser", default: .safari)
    var browser: Browser

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$file) for \(\.$browser)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let vm = ConverterViewModel.shared
        let queue = ConversionQueue.shared
        guard !queue.isRunning, !vm.isRunning else {
            throw ShortcutsError(message: "Viaduct is busy converting something else.")
        }
        let url = try localCopy(of: file)
        // The queue sheet and the signing question live on the main window,
        // which is closed if the app is sitting in the menu bar.
        MainWindow.show()
        queue.start([QueueItem.file(url, browser: browser)], vm: vm)
        // The batch drives the window; wait it out so the shortcut can act on
        // the result.
        while queue.isRunning {
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        guard let item = queue.items.first else { throw ShortcutsError.notReady }
        switch item.status {
        case .done:
            return .result(value: item.installedPath ?? item.name)
        case let .failed(why), let .skipped(why):
            throw ShortcutsError(message: why.isEmpty ? "The conversion didn't finish." : why)
        default:
            throw ShortcutsError(message: "The conversion didn't finish.")
        }
    }

    /// Shortcuts may hand over bytes rather than a path (a file from another
    /// action); give those a real file with the original name.
    private func localCopy(of file: IntentFile) throws -> URL {
        if let url = file.fileURL, FileManager.default.fileExists(atPath: url.path) { return url }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("viaduct-shortcut-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(file.filename.isEmpty ? "extension.zip" : file.filename)
        try file.data.write(to: dest)
        return dest
    }
}

struct ListConvertedExtensionsIntent: AppIntent {
    static var title: LocalizedStringResource = "List Converted Extensions"
    static var description = IntentDescription("Returns the extensions Viaduct has installed and the browser each one is in.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[ConvertedExtension]> {
        .result(value: Self.entries(in: ConverterViewModel.shared.history))
    }

    /// The extensions still installed, in history order. A Safari one whose app
    /// was deleted is left out.
    @MainActor
    static func entries(in history: ConversionHistory) -> [ConvertedExtension] {
        history.records.filter { history.isPresent($0) }.map(ConvertedExtension.init(record:))
    }
}

/// The browser picker in Shortcuts. Declared here so the helper, which shares
/// Browser.swift, never has to link App Intents.
extension Browser: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Browser"
    static var caseDisplayRepresentations: [Browser: DisplayRepresentation] = [
        .safari: "Safari",
        .firefox: "Firefox",
    ]
}

/// One installed extension as Shortcuts sees it. It reads as its name, so
/// shortcuts that used the old list of names as text still get them.
struct ConvertedExtension: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Converted Extension"
    static var defaultQuery = ConvertedExtensionQuery()

    /// The conversion record's id.
    let id: UUID

    @Property(title: "Name")
    var name: String

    @Property(title: "Browser")
    var browser: Browser

    init(record: ConversionRecord) {
        id = record.id
        name = record.name
        browser = record.browser
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(browser.displayName)")
    }
}

struct ConvertedExtensionQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [ConvertedExtension] {
        ConverterViewModel.shared.history.records
            .filter { identifiers.contains($0.id) }
            .map(ConvertedExtension.init(record:))
    }

    @MainActor
    func suggestedEntities() async throws -> [ConvertedExtension] {
        ListConvertedExtensionsIntent.entries(in: ConverterViewModel.shared.history)
    }
}

struct ViaductShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ListConvertedExtensionsIntent(),
                    phrases: ["List my \(.applicationName) extensions"])
    }
}
