import AppKit

/// Host mode, for the Add to Firefox add-on. Firefox starts the helper as
/// `ViaductHelper <host manifest> <add-on id>` for each message the add-on
/// sends, writes the message to stdin and reads one framed reply from stdout.
/// stdout carries that reply and nothing else; diagnostics belong on stderr,
/// which Firefox shows in its browser console.
enum NativeHost {
    static func run() -> Never {
        guard let message = readMessage() else {
            send(rejection("Malformed request"))
            exit(1)
        }
        switch NativeHostProtocol.action(for: message) {
        case .open(let url):
            send(open(url))
        case .progress:
            send(ask(busObject: nil) { $0 } ?? ["state": "unreachable"])
        case .installed(let busObject):
            send(ask(busObject: busObject) { NativeHostProtocol.installedReply(from: $0, busObject: busObject) }
                 ?? ["installed": false, "state": "unreachable"])
        case .reject(let error):
            send(rejection(error))
        }
        exit(0)
    }

    /// The request on stdin: a length header, then that much JSON holding an
    /// object. Nil when stdin ends early or holds anything else.
    private static func readMessage() -> [String: Any]? {
        guard let header = readExactly(4),
              let length = NativeHostProtocol.messageLength(header: header),
              let body = readExactly(length) else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    /// `count` bytes from stdin, which a pipe can hand over in pieces. Nil if
    /// stdin ends first.
    private static func readExactly(_ count: Int) -> Data? {
        var data = Data()
        while data.count < count {
            guard let chunk = try? FileHandle.standardInput.read(upToCount: count - data.count),
                  !chunk.isEmpty else { return nil }
            data.append(chunk)
        }
        return data
    }

    private static func send(_ reply: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: reply) else { return }
        try? FileHandle.standardOutput.write(contentsOf: NativeHostProtocol.frame(json))
    }

    private static func rejection(_ error: String) -> [String: Any] {
        ["state": "unknown", "error": error]
    }

    /// Hands the link to the app this helper sits in, never another copy
    /// LaunchServices might pick, and leaves Firefox in front.
    private static func open(_ url: URL) -> [String: Any] {
        let app = NativeHostProtocol.appBundle(helperExecutable: HelperAgent.executableURL)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let pending = PendingReply()
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { _, error in
            let reply: [String: Any] = error.map { ["ok": false, "error": $0.localizedDescription] } ?? ["ok": true]
            DispatchQueue.main.async { pending.reply = reply }
        }
        return pending.wait(seconds: 5) ?? ["ok": false, "error": "Viaduct didn't open in time"]
    }

    /// Asks the app on the progress bus, the way Safari's extension does, and
    /// waits up to 2 s. `reply` turns a snapshot from the bus into the answer,
    /// or nil when the snapshot answers someone else's question.
    private static func ask(busObject: String?,
                            reply: @escaping ([String: Any]) -> [String: Any]?) -> [String: Any]? {
        let center = DistributedNotificationCenter.default()
        let pending = PendingReply()
        let observer = center.addObserver(forName: ProgressBus.state, object: nil, queue: .main) { note in
            guard pending.reply == nil,
                  let json = note.object as? String,
                  let state = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
            else { return }
            pending.reply = reply(state)
        }
        defer { center.removeObserver(observer) }
        center.postNotificationName(ProgressBus.request, object: busObject, userInfo: nil,
                                    deliverImmediately: true)
        return pending.wait(seconds: 2)
    }
}

/// A reply that arrives on the main thread while `wait` runs the main run
/// loop, which is what delivers bus notifications and main-queue blocks.
private final class PendingReply {
    var reply: [String: Any]?

    func wait(seconds: TimeInterval) -> [String: Any]? {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while reply == nil, Date() < deadline {
            RunLoop.main.run(mode: .default, before: deadline)
        }
        return reply
    }
}
