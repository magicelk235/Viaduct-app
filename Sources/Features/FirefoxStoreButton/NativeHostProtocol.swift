import Foundation

/// What the Add to Firefox add-on and ViaductHelper say to each other over
/// Firefox native messaging. Firefox starts the helper for each message the
/// add-on sends, writes the message to its stdin and reads one reply from its
/// stdout, each a length header followed by JSON. Compiled into ViaductHelper,
/// which answers the add-on, and into the app, which installs it.
enum NativeHostProtocol {
    static let hostName = "com.magicelk235.viaduct"
    static let storeButtonId = "store-button@viaduct.magicelklabs.com"
    /// Firefox caps host-to-browser messages at 1 MB; the same cap applies to input.
    static let maxMessageBytes = 1_048_576

    /// UInt32 length in little-endian (native order on arm64 and x86_64), then the JSON bytes.
    static func frame(_ json: Data) -> Data {
        withUnsafeBytes(of: UInt32(json.count).littleEndian) { Data($0) } + json
    }

    /// nil unless the header is exactly 4 bytes and the length is 1...maxMessageBytes.
    static func messageLength(header: Data) -> Int? {
        guard header.count == 4 else { return nil }
        // Little-endian, so the last byte is the most significant.
        let length = header.reversed().reduce(0) { $0 << 8 | Int($1) }
        return (1...maxMessageBytes).contains(length) ? length : nil
    }

    /// Firefox on macOS starts the host as `<host>.json <extension id>`: true when there are at least two
    /// arguments, the first ends in "/com.magicelk235.viaduct.json" and the second is storeButtonId.
    static func isLaunchedByFirefox(arguments: [String]) -> Bool {
        arguments.count >= 2
            && arguments[0].hasSuffix("/\(hostName).json")
            && arguments[1] == storeButtonId
    }

    /// …/Viaduct.app/Contents/Helpers/ViaductHelper → …/Viaduct.app
    static func appBundle(helperExecutable: URL) -> URL {
        helperExecutable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    enum Action: Equatable {
        /// Hand this viaduct:// link to the app.
        case open(URL)
        /// Pass on the app's progress snapshot.
        case progress
        /// Ask the app whether the extension is installed, with this object on the progress bus.
        case installed(busObject: String)
        /// Turn the message away with this error.
        case reject(String)
    }

    /// What to do with one message from the add-on: `{type:"install", id, name?}`,
    /// `{type:"remove", id}`, `{type:"progress"}` or `{type:"installed", id}`.
    static func action(for message: [String: Any]) -> Action {
        switch message["type"] as? String {
        case "install":
            // The name goes through exactly as the store page gave it.
            return withStoreId(in: message) {
                .open(StoreRequest(action: .install(name: message["name"] as? String), storeId: $0, browser: .firefox).url)
            }
        case "remove":
            return withStoreId(in: message) {
                .open(StoreRequest(action: .remove, storeId: $0, browser: .firefox).url)
            }
        case "installed":
            return withStoreId(in: message) {
                .installed(busObject: InstalledQuery.busObject(storeId: $0, browser: .firefox))
            }
        case "progress":
            return .progress
        case let type:
            return .reject("Unknown request type: \(type ?? "none")")
        }
    }

    /// The reply for an installed query, or nil when the bus reply answers someone else.
    static func installedReply(from state: [String: Any], busObject: String) -> [String: Any]? {
        guard state["forId"] as? String == busObject else { return nil }
        return ["installed": state["installed"] as? Bool ?? false]
    }

    /// The id ends up in a viaduct:// link or on the progress bus, so anything
    /// but a Chrome Web Store id is turned away.
    private static func withStoreId(in message: [String: Any], _ action: (String) -> Action) -> Action {
        guard let id = message["id"] as? String, ExtensionIdentity.isChromeId(id) else {
            return .reject("Not a Chrome Web Store extension id")
        }
        return action(id)
    }
}
