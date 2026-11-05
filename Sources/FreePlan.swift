import SwiftUI
@preconcurrency import UserNotifications

/// On the free plan Viaduct keeps a converted extension for a week, then
/// removes it. A license for its browser keeps it. This owns that clock: the
/// removal, the warnings before it, and a note once it's gone.
@MainActor
final class FreePlan {
    static let keepFor: TimeInterval = 7 * 24 * 3600
    /// Days before the removal that a free user gets warned. Few on purpose:
    /// a notification every day trains people to switch them off, and then
    /// the one that matters doesn't arrive.
    private static let warnDaysLeft = [3, 1]
    /// Every notification this class posts starts with this, which is also how
    /// a click on one is told apart from the app's other notifications.
    nonisolated static let notificationPrefix = "free-plan-"
    private nonisolated static let reminderPrefix = notificationPrefix + "removal-"

    private let history: ConversionHistory
    private let license: LicenseManager
    private var timer: Timer?
    /// Told about every extension this removes, so the window can say so.
    var onRemoved: ([ConversionRecord]) -> Void = { _ in }

    init(history: ConversionHistory, license: LicenseManager) {
        self.history = history
        self.license = license
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
    /// to call as often as anything changes. Does nothing until the license
    /// check has an answer, so a paying user is never swept while it's running.
    func sync() {
        guard license.hasLaunchAnswer else { return }
        history.keepFreeExtensions(where: { _ in license.unlimited(.safari) })
        let removed = history.removeExpiredFreeExtensions()
        removed.forEach(notifyRemoved)
        if !removed.isEmpty { onRemoved(removed) }
        reconcileReminders()
        scheduleNextSweep()
    }

    // MARK: - Timing

    /// Wake for the next removal due. Re-armed on every sync.
    private func scheduleNextSweep() {
        timer?.invalidate()
        timer = nil
        guard let next = history.pendingFreeRemovals.compactMap(\.freeRemovesAt).min() else { return }
        timer = Timer.scheduledTimer(withTimeInterval: max(1, next.timeIntervalSinceNow + 1),
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
        let now = Date()
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
        let center = UNUserNotificationCenter.current()
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
                        timeInterval: max(60, warning.fireAt.timeIntervalSinceNow), repeats: false)
                    center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
                }
            }
        }
    }

    private func notifyRemoved(_ rec: ConversionRecord) {
        let center = UNUserNotificationCenter.current()
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
        DispatchQueue.main.async {
            MainWindow.show()
            if warning, !LicenseManager.shared.unlimited(.safari) {
                ConverterViewModel.shared.presentPaywall(for: .safari)
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
        content.alert(Self.title(for: vm.removedOnFreePlan), isPresented: showing) {
            Button("Upgrade") {
                vm.removedOnFreePlan = []
                // One modal at a time per window: let the alert leave first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { vm.presentPaywall(for: .safari) }
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
