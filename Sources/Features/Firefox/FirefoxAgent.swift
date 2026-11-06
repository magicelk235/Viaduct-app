import ServiceManagement

/// The Firefox agent behind a protocol, so tests can stand in a fake.
protocol FirefoxAgentControlling {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

/// The launch agent that keeps Firefox add-ons loading: launchd runs
/// `Contents/Helpers/ViaductHelper agent` from the plist in
/// `Contents/Library/LaunchAgents`. It's its own item in Login Items, separate
/// from the `SMAppService.mainApp` login item the app registers for itself.
struct FirefoxAgent: FirefoxAgentControlling {
    static let plistName = "com.magicelk235.viaduct.firefox-agent.plist"

    private let service = SMAppService.agent(plistName: Self.plistName)

    var status: SMAppService.Status { service.status }

    func register() throws { try service.register() }

    func unregister() throws { try service.unregister() }
}
