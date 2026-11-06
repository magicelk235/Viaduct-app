import AppKit

/// The Add to Firefox button: an add-on persist keeps like any other, plus
/// the native messaging manifest that lets it reach ViaductHelper. It has no
/// history record, so it never counts against the free plan and the free
/// plan never removes it.
@MainActor
final class FirefoxStoreButton: ObservableObject {
    static let shared = FirefoxStoreButton()

    struct Files {
        /// The built add-on.
        var addon: URL
        /// Where Firefox looks for the native host the button talks to.
        var hostManifest: URL
        /// The helper Firefox starts for each message.
        var helper: URL

        static var live: Files {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return Files(
                addon: Bundle.main.resourceURL!.appendingPathComponent("firefox/store-button", isDirectory: true),
                hostManifest: home.appendingPathComponent(
                    "Library/Application Support/Mozilla/NativeMessagingHosts/\(NativeHostProtocol.hostName).json"),
                // The path the helper sees for itself, symlinks resolved.
                helper: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ViaductHelper").resolvingSymlinksInPath()
            )
        }
    }

    enum State: Equatable { case checking, needsFirefox, off, installing, on, removing, failed(String) }
    enum Prompt: Equatable { case disclosure, restart }

    /// `.checking` until the first refresh.
    @Published private(set) var state: State = .checking
    /// The last install only arrives the next time Firefox starts.
    @Published private(set) var arrivesLater = false
    @Published var prompt: Prompt?

    private let addons: FirefoxAddons
    private let files: Files
    private let defaults: UserDefaults
    private let locate: () -> FirefoxLocator.Install?
    /// The install waiting on the restart question.
    private var awaitingRestart: (firefox: FirefoxLocator.Install, target: FirefoxTarget)?

    init(addons: FirefoxAddons, files: Files = .live, defaults: UserDefaults = .standard,
         locate: @escaping () -> FirefoxLocator.Install? = { FirefoxLocator.find() }) {
        self.addons = addons
        self.files = files
        self.defaults = defaults
        self.locate = locate
    }

    /// For the app's own add-ons. Not a `= .shared` default: default
    /// arguments are evaluated off the main actor.
    convenience init() {
        self.init(addons: .shared)
    }

    // MARK: - State

    func refresh() async {
        guard let firefox = locate() else { state = .needsFirefox; return }
        let profilePath = try? await addons.target(firefox: firefox).profilePath
        do {
            state = Self.isOn(kept: try await addons.persist.list(), profilePath: profilePath) ? .on : .off
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Installing

    func requestInstall() async {
        prompt = nil
        guard let firefox = locate() else { state = .needsFirefox; return }
        guard FirefoxDisclosure.isAccepted(defaults) else { prompt = .disclosure; return }
        let target: FirefoxTarget
        do {
            target = try await addons.target(firefox: firefox)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        if target.askRestart {
            awaitingRestart = (firefox, target)
            prompt = .restart
            return
        }
        await install(firefox: firefox, target: target, restartNow: false)
    }

    func answerDisclosure(accepted: Bool) async {
        prompt = nil
        guard accepted else { return }
        FirefoxDisclosure.accept(defaults)
        await requestInstall()
    }

    func answerRestart(restartNow: Bool) async {
        prompt = nil
        guard let (firefox, target) = awaitingRestart else { return }
        awaitingRestart = nil
        await install(firefox: firefox, target: target, restartNow: restartNow)
    }

    private func install(firefox: FirefoxLocator.Install, target: FirefoxTarget, restartNow: Bool) async {
        state = .installing
        do {
            // In place first, so the button reaches the app the moment it loads.
            try writeHostManifest()
            // Persist only restarts a Firefox it may start again, so a restart
            // the user agreed to comes with launch. Otherwise Firefox is left alone.
            let result = try await addons.install(staged: files.addon, profile: target.profilePath,
                                                  firefox: firefox.appURL.path, restart: restartNow, launch: restartNow)
            arrivesLater = result.pending
            state = .on
        } catch {
            state = .failed(error.localizedDescription)
            if let kept = try? await addons.persist.list(), !kept.contains(where: { $0.id == NativeHostProtocol.storeButtonId }) {
                deleteHostManifest()
            }
        }
    }

    // MARK: - Removing

    func remove() async {
        state = .removing
        var profilePath: String?
        if let firefox = locate() {
            profilePath = try? await addons.target(firefox: firefox).profilePath
        }
        if profilePath == nil {
            profilePath = (try? await addons.persist.list())?.first { $0.id == NativeHostProtocol.storeButtonId }?.profilePath
        }
        do {
            if let profilePath {
                try await addons.uninstall(id: NativeHostProtocol.storeButtonId, profile: profilePath, restart: false)
            }
        } catch let error as PersistError where error.needsFirefoxRestart {
            // Persist's own words name a command-line flag.
            state = .failed("Quit Firefox, then try again.")
            return
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        if let kept = try? await addons.persist.list(), !kept.contains(where: { $0.id == NativeHostProtocol.storeButtonId }) {
            deleteHostManifest()
        }
        await refresh()
    }

    // MARK: - Launch

    /// Brings kept copies up to the bundled build and points the host manifest
    /// at this copy of the app. Runs in the background, so it never asks
    /// anything, never shows a failure and never starts or restarts Firefox.
    func syncAfterLaunch() async {
        guard let kept = try? await addons.persist.list() else { return }
        let buttons = kept.filter { $0.id == NativeHostProtocol.storeButtonId }
        guard !buttons.isEmpty else { deleteHostManifest(); return }
        // The app may have moved since the manifest was written.
        try? writeHostManifest()
        guard let bundled = Self.bundledVersion(addon: files.addon) else { return }
        for profilePath in Self.profilesNeedingRefresh(kept: kept, bundledVersion: bundled) {
            guard let copy = buttons.first(where: { $0.profilePath == profilePath }) else { continue }
            _ = try? await addons.install(staged: files.addon, profile: profilePath, firefox: copy.firefox,
                                          restart: false, launch: false)
        }
    }

    /// Opens the Chrome Web Store in Firefox, where the button is.
    func openWebStore() {
        let store = URL(string: "https://chromewebstore.google.com/")!
        guard let firefox = locate() else {
            NSWorkspace.shared.open(store)
            return
        }
        NSWorkspace.shared.open([store], withApplicationAt: firefox.appURL,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Pure rules

    /// Kept in the chosen profile, or in any profile when there's none yet.
    static func isOn(kept: [PersistAddon], profilePath: String?) -> Bool {
        kept.contains { $0.id == NativeHostProtocol.storeButtonId && (profilePath == nil || $0.profilePath == profilePath) }
    }

    /// The profiles whose copy of the button isn't the bundled build.
    static func profilesNeedingRefresh(kept: [PersistAddon], bundledVersion: String) -> [String] {
        kept.filter { $0.id == NativeHostProtocol.storeButtonId && $0.version != bundledVersion }.map(\.profilePath)
    }

    /// Firefox's native messaging manifest. Only the button may start the helper.
    static func hostManifest(helperPath: String) -> Data {
        let manifest: [String: Any] = [
            "name": NativeHostProtocol.hostName,
            "description": "Viaduct",
            "path": helperPath,
            "type": "stdio",
            "allowed_extensions": [NativeHostProtocol.storeButtonId],
        ]
        // Only fails for values JSON can't hold, and these are all strings.
        return try! JSONSerialization.data(withJSONObject: manifest,
                                           options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// The version in the built add-on's manifest.json.
    static func bundledVersion(addon: URL) -> String? {
        guard let data = try? Data(contentsOf: addon.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return manifest["version"] as? String
    }

    // MARK: - Host manifest

    /// Leaves a manifest that already says the same alone.
    private func writeHostManifest() throws {
        let data = Self.hostManifest(helperPath: files.helper.path)
        guard (try? Data(contentsOf: files.hostManifest)) != data else { return }
        try FileManager.default.createDirectory(at: files.hostManifest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: files.hostManifest, options: .atomic)
    }

    private func deleteHostManifest() {
        try? FileManager.default.removeItem(at: files.hostManifest)
    }
}
