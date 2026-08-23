//
//  SafariWebExtensionHandler.swift
//  Viaduct Install Extension
//
//  Created by Yehonatan Cohen on 23/6/26.
//

import SafariServices

@objc(SafariWebExtensionHandler)
public class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    // Mirrors InstallProgressBridge in the main app. The appex is sandboxed and
    // request-scoped, so a distributed-notification round-trip is the channel:
    // post a request, wait briefly for the app's JSON state reply.
    private static let requestNote = Notification.Name("com.magicelk235.viaduct.progress.request")
    private static let stateNote = Notification.Name("com.magicelk235.viaduct.progress.state")

    public func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem
        let message = request?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        let type = message?["type"] as? String

        // Heartbeat from background.js, sent every time Safari starts the
        // extension's worker — i.e. while the extension is enabled. Relayed to
        // the app (same bus as the progress bridge; name duplicated in
        // StoreButton.swift) so it stops offering a switch already flipped.
        if type == "hello" {
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("com.magicelk235.viaduct.storebutton.alive"),
                object: nil, userInfo: nil, deliverImmediately: true)
            respond(context, ["ok": true])
            return
        }

        guard type == "progress" || type == "installed" else {
            respond(context, ["state": "unknown"])
            return
        }

        // An installed-check carries the queried CWS id as the notification
        // object; a progress poll carries none. The app replies on stateNote
        // with a JSON snapshot; installed-check replies echo `forId`, so we
        // accept only the reply for our own id (the bus is shared/broadcast).
        let queryId = type == "installed" ? (message?["id"] as? String) : nil
        let timeoutPayload: [String: Any] = type == "installed"
            ? ["installed": false, "state": "unreachable"]
            : ["state": "unreachable"]

        let center = DistributedNotificationCenter.default()
        let lock = NSLock()
        var finished = false
        var observer: NSObjectProtocol?
        let finish: ([String: Any]) -> Void = { [weak self] payload in
            lock.lock()
            let first = !finished
            finished = true
            lock.unlock()
            guard first else { return }
            if let observer { center.removeObserver(observer) }
            self?.respond(context, payload)
        }

        observer = center.addObserver(forName: Self.stateNote, object: nil, queue: nil) { note in
            guard let json = note.object as? String,
                  let data = json.data(using: .utf8),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return }
            if let queryId {
                // Ignore progress replies (and other ids) racing on the bus.
                guard dict["forId"] as? String == queryId else { return }
                finish(["installed": dict["installed"] as? Bool ?? false])
            } else {
                finish(dict)
            }
        }
        center.postNotificationName(Self.requestNote, object: queryId, userInfo: nil,
                                    deliverImmediately: true)
        // App not running / not listening → tell the page instead of hanging.
        // 2s, not 1s: the appex is spawned cold per request, and the
        // notification round trip can straggle past a tight budget.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            finish(timeoutPayload)
        }
    }

    private func respond(_ context: NSExtensionContext, _ payload: [String: Any]) {
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: payload]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
