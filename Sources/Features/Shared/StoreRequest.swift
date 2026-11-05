import Foundation

/// A store-page request sent to the app as a viaduct:// link: install or
/// remove one Chrome Web Store extension in one browser. Safari's store
/// extension sends these without `browser=`, so a missing one means Safari.
/// Also built into ViaductHelper, which opens these links for Firefox.
struct StoreRequest: Equatable {
    enum Action: Equatable {
        case install(name: String?)
        case remove
    }

    var action: Action
    var storeId: String
    var browser: Browser

    init(action: Action, storeId: String, browser: Browser) {
        self.action = action
        self.storeId = storeId
        self.browser = browser
    }

    /// Nil when the link isn't viaduct://install or viaduct://remove, the id
    /// isn't a Chrome id, or `browser=` names something we don't convert for.
    init?(url: URL) {
        guard url.scheme == "viaduct",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let storeId = items.first(where: { $0.name == "id" })?.value,
              ExtensionIdentity.isChromeId(storeId) else { return nil }
        let browser: Browser
        if let raw = items.first(where: { $0.name == "browser" })?.value {
            guard let named = Browser(rawValue: raw) else { return nil }
            browser = named
        } else {
            browser = .safari
        }
        switch url.host {
        case "install": action = .install(name: items.first(where: { $0.name == "name" })?.value)
        case "remove": action = .remove
        default: return nil
        }
        self.storeId = storeId
        self.browser = browser
    }

    /// viaduct://<install|remove>?id=…[&name=…]&browser=<rawValue>
    var url: URL {
        var items = [("id", storeId)]
        var components = URLComponents()
        components.scheme = "viaduct"
        switch action {
        case .install(let name):
            components.host = "install"
            if let name { items.append(("name", name)) }
        case .remove:
            components.host = "remove"
        }
        items.append(("browser", browser.rawValue))
        // URLComponents leaves "+" alone, and anything reading the query as a
        // form would turn it into a space, so names get stricter escaping.
        components.percentEncodedQueryItems = items.map {
            URLQueryItem(name: $0.0, value: $0.1.addingPercentEncoding(withAllowedCharacters: Self.valueAllowed))
        }
        return components.url!
    }

    private static let valueAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#"))
}

/// The object the store-page extension posts with an installed-check on the
/// progress bus. Safari's shipped extension posts the bare id, so that stays
/// Safari; Firefox's queries are prefixed.
enum InstalledQuery {
    private static let firefoxPrefix = "firefox:"

    static func busObject(storeId: String, browser: Browser) -> String {
        switch browser {
        case .safari: return storeId
        case .firefox: return firefoxPrefix + storeId
        }
    }

    static func parse(_ object: String) -> (storeId: String, browser: Browser) {
        if object.hasPrefix(firefoxPrefix) {
            return (String(object.dropFirst(firefoxPrefix.count)), .firefox)
        }
        return (object, .safari)
    }
}

/// Distributed notification names the store-page extensions poll progress on.
/// The Safari appex can't see app files and keeps its own copies of these, so
/// they never change.
enum ProgressBus {
    static let request = Notification.Name("com.magicelk235.viaduct.progress.request")
    static let state = Notification.Name("com.magicelk235.viaduct.progress.state")
}
