import SwiftUI
@preconcurrency import UserNotifications

/// On the free plan Viaduct keeps a converted extension for a week, then
/// removes it. A license for its browser keeps it. This owns that clock: the
/// removal, the warnings before it, and a note once it's gone.
@MainActor
final class FreePlan {
    static let keepFor: TimeInterval = 7 * 24 * 3600
    /// How long a removal that didn't go through waits for its next try.
    /// Firefox can hold on to an add-on until it quits, so trying again at
    /// once would only fail again.
    static let retryAfterFailure: TimeInterval = 3600
    /// Days before the removal that a free user gets warned. Few on purpose:
    /// a notification every day trains people to switch them off, and then
    /// the one that matters doesn't arrive.
    private static let warnDaysLeft = [3, 1]
    /// Every notification this class posts starts with this, which is also how
    /// a click on one is told apart from the app's other notifications.
    nonisolated static let notificationPrefix = "free-plan-"
    private nonisolated static let reminderPrefix = notificationPrefix + "removal-"

    /// The time removals go by. A debug build adds the `freePlanClockOffset`
    /// default, in seconds, so a removal can be tried without waiting a week.
    nonisolated static var clock: () -> Date {
        #if DEBUG
        return { Date().addingTimeInterval(UserDefaults.standard.double(forKey: "freePlanClockOffset")) }
        #else
        return { Date() }
        #endif
    }

    private let history: ConversionHistory
    private let license: LicenseManager
    private let now: () -> Date
    /// Nil posts nothing, which keeps tests quiet.
    private let notifications: UNUserNotificationCenter?
    private var timer: Timer?
    private var sweeping = false
    /// Another sync came in while a sweep was running.
    private var sweepAgain = false
    /// Told about every extension this removes, so the window can say so.
    var onRemoved: ([ConversionRecord]) -> Void = { _ in }

    init(history: ConversionHistory, license: LicenseManager, now: @escaping () -> Date = FreePlan.clock,
         notifications: UNUserNotificationCenter? = .current()) {
        self.history = history
        self.license = license
        self.now = now
        self.notifications = notifications
    }

    /// For the app's own license. Not a `= .shared` default: default
    /// arguments are evaluated off the main actor.
    convenience init(history: ConversionHistory) {
        self.init(history: history, license: .shared)
    }

    /// When a conversion made right now gets removed, or nil if it's kept.
    static func removalDate(unlimited: Bool, now: Date = Date()) -> Date? {
        unlimited ? nil : now.addingTimeInterval(keepFor)
    }

    /// Bring removals, reminders and the timer in line with the license. Safe
    /// to call as often as anything changes.
    func sync() {
        Task { await runSync() }
    }

    /// What `sync` runs, returning the extensions it removed. Does nothing
    /// until the license check has an answer, so a paying user is never swept
    /// while it's running. A call while a sweep runs makes that sweep go once
    /// more instead of starting a second one.
    @discardableResult
    func runSync() async -> [ConversionRecord] {
        guard license.hasLaunchAnswer else { return [] }
        guard !sweeping else {
            sweepAgain = true
            return []
        }
        sweeping = true
        var removed: [ConversionRecord] = []
        repeat {
            sweepAgain = false
            history.keepFreeExtensions(where: { license.unlimited($0.browser) })
            removed += await history.removeExpiredFreeExtensions(now: now())
        } while sweepAgain
        sweeping = false
        removed.forEach(notifyRemoved)
        if !removed.isEmpty { onRemoved(removed) }
        reconcileReminders()
        scheduleNextSweep()
        return removed
    }

    // MARK: - Timing

    /// When the next sweep is due: the first removal still ahead, or a retry
    /// for one whose time came but that didn't go through.
    static func nextSweepDate(removalDates: [Date], now: Date) -> Date? {
        removalDates.map { $0 > now ? $0 : now.addingTimeInterval(retryAfterFailure) }.min()
    }

    /// The record a reminder warns about, read from its identifier.
    nonisolated static func recordID(inReminder identifier: String) -> UUID? {
        guard identifier.hasPrefix(reminderPrefix) else { return nil }
        // <prefix><uuid>-<days>: the UUID has dashes of its own, so cut at the last one.
        let rest = identifier.dropFirst(reminderPrefix.count)
        guard let dash = rest.lastIndex(of: "-") else { return nil }
        return UUID(uuidString: String(rest[..<dash]))
    }

    /// Wake for the next sweep due. Re-armed on every sync.
    private func scheduleNextSweep() {
        timer?.invalidate()
        timer = nil
        let now = self.now()
        guard let next = Self.nextSweepDate(removalDates: history.pendingFreeRemovals.compactMap(\.freeRemovesAt),
                                            now: now) else { return }
        timer = Timer.scheduledTimer(withTimeInterval: max(1, next.timeIntervalSince(now) + 1),
                                     repeats: false) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
    }

    // MARK: - Notifications

    /// The warnings for every pending removal, scheduled with the system so they
    /// show even if Viaduct isn't open. Stale ones (kept, removed, reconverted)
    /// go. A warning whose time has already passed is skipped rather than sent
    /// late, so a sync never fires a burst of them at once.
    private func reconcileReminders() {
        guard let center = notifications else { return }
        let now = self.now()
        var wanted: [String: (name: String, daysLeft: Int, fireAt: Date)] = [:]
        for rec in history.pendingFreeRemovals {
            guard let removesAt = rec.freeRemovesAt else { continue }
            for days in Self.warnDaysLeft {
                let fireAt = removesAt.addingTimeInterval(-Double(days) * 24 * 3600)
                guard fireAt.timeIntervalSince(now) > 60 else { continue }
                wanted[Self.reminderPrefix + rec.id.uuidString + "-\(days)"] =
                    (rec.name, days, fireAt)
            }
        }
        center.getPendingNotificationRequests { requests in
            let scheduled = Set(requests.map(\.identifier))
            let stale = scheduled.filter { $0.hasPrefix(Self.reminderPrefix) && wanted[$0] == nil }
            if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: Array(stale)) }
            let missing = wanted.filter { !scheduled.contains($0.key) }
            guard !missing.isEmpty else { return }
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                guard granted else { return }
                for (id, warning) in missing {
                    let content = UNMutableNotificationContent()
                    content.title = warning.daysLeft == 1
                        ? "\(warning.name) will be removed tomorrow"
                        : "\(warning.name) will be removed in \(warning.daysLeft) days"
                    content.body = "Upgrade to keep it."
                    content.sound = .default
                    let trigger = UNTimeIntervalNotificationTrigger(
                        timeInterval: max(60, warning.fireAt.timeIntervalSince(now)), repeats: false)
                    center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
                }
            }
        }
    }

    private func notifyRemoved(_ rec: ConversionRecord) {
        guard let center = notifications else { return }
        let name = rec.name
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Removed \(name)"
            content.body = "Upgrade to keep the ones you convert."
            content.sound = .default
            center.add(UNNotificationRequest(identifier: Self.notificationPrefix + "removed-\(rec.id.uuidString)",
                                             content: content, trigger: nil))
        }
    }
}

extension FreePlan {
    /// An extension the free plan removed, kept until the window has said
    /// so. Its browser picks the licenses Upgrade points at.
    struct RemovedExtension: Codable, Equatable {
        let name: String
        let browser: Browser

        private static let key = "freePlanRemoved"

        /// Names saved before Firefox are plain strings, and every one of
        /// them was a Safari extension.
        static func saved(in defaults: UserDefaults) -> [RemovedExtension] {
            if let data = defaults.data(forKey: key) {
                return (try? JSONDecoder().decode([RemovedExtension].self, from: data)) ?? []
            }
            return defaults.stringArray(forKey: key)?.map { RemovedExtension(name: $0, browser: .safari) } ?? []
        }

        static func save(_ removed: [RemovedExtension], in defaults: UserDefaults) {
            defaults.set(try? JSONEncoder().encode(removed), forKey: key)
        }

        /// The browser they all went from, or nil when they're mixed.
        static func browser(of removed: [RemovedExtension]) -> Browser? {
            let browsers = Set(removed.map(\.browser))
            return browsers.count == 1 ? browsers.first : nil
        }
    }
}

/// Shows Viaduct's notifications while it's the frontmost app (macOS hides an
/// app's own notifications then unless it asks), and routes clicks: a warning
/// opens the paywall; anything else opens the window, which is where the
/// "was removed" message waits.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        let warning = id.hasPrefix(FreePlan.notificationPrefix + "removal-")
        let warnedAbout = FreePlan.recordID(inReminder: id)
        DispatchQueue.main.async {
            MainWindow.show()
            if warning {
                let vm = ConverterViewModel.shared
                let license = LicenseManager.shared
                // The record can be gone by now (removed, or converted again
                // under a new id), and then the paywall offers every license.
                if let browser = vm.history.records.first(where: { $0.id == warnedAbout })?.browser {
                    if !license.unlimited(browser) { vm.presentPaywall(for: browser) }
                } else if !Browser.allCases.allSatisfy({ license.unlimited($0) }) {
                    vm.presentPaywall(for: nil)
                }
            }
            completionHandler()
        }
    }
}

extension View {
    /// The "was removed, upgrade" message on the main window, shown once for
    /// whatever the free plan removed since the user last saw it.
    func freePlanRemovedNotice(vm: ConverterViewModel, blocked: Bool) -> some View {
        modifier(FreePlanRemovedNotice(vm: vm, blocked: blocked))
    }
}

private struct FreePlanRemovedNotice: ViewModifier {
    @ObservedObject var vm: ConverterViewModel
    /// Another sheet owns the window right now (batch queue, setup); the
    /// message waits for it instead of fighting it.
    let blocked: Bool

    private var showing: Binding<Bool> {
        Binding(get: { !vm.removedOnFreePlan.isEmpty && !vm.showPaywall && !blocked },
                set: { if !$0 { vm.removedOnFreePlan = [] } })
    }

    func body(content: Content) -> some View {
        content.alert(Self.title(for: vm.removedOnFreePlan.map(\.name)), isPresented: showing) {
            Button("Upgrade") {
                let browser = FreePlan.RemovedExtension.browser(of: vm.removedOnFreePlan)
                vm.removedOnFreePlan = []
                // One modal at a time per window: let the alert leave first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { vm.presentPaywall(for: browser) }
            }
            Button("Not Now", role: .cancel) { vm.removedOnFreePlan = [] }
        } message: {
            Text("Upgrade to keep the ones you convert.")
        }
    }

    static func title(for names: [String]) -> String {
        switch names.count {
        case 0, 1: return "\(names.first ?? "An extension") was removed"
        case 2:    return "\(names[0]) and \(names[1]) were removed"
        default:   return "\(names[0]) and \(names.count - 1) others were removed"
        }
    }
}
