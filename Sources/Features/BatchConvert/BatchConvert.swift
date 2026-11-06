import Foundation

/// Several files dropped or picked at once go through the queue instead of
/// the single-extension card.
enum BatchConvert {
    @MainActor
    static func start(_ urls: [URL], vm: ConverterViewModel) {
        // Read now: the picker could change while the manifests are read.
        let browser = vm.targetBrowser
        Task {
            // Reading each manifest (and unzipping archives to do it) is slow
            // enough to keep off the main thread.
            let items = await Task.detached(priority: .userInitiated) {
                urls.map { QueueItem.file($0, browser: browser) }
            }.value
            ConversionQueue.shared.start(items, vm: vm)
        }
    }

    /// Resolve dropped item providers to file URLs, in drop order.
    static func loadURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        var found = [URL?](repeating: nil, count: providers.count)
        let lock = NSLock()
        for (i, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                lock.lock(); found[i] = url; lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(found.compactMap { $0 }) }
    }
}
