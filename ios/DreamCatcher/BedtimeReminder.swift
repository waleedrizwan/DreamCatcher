import Foundation
import Observation
import UserNotifications

/// Nightly "start me" notification. iOS won't let the app launch itself or
/// turn the mic on from the background, so the reminder brings the app to the
/// foreground and a tap starts the session from there.
///
/// Scheduled as one-shot requests for the next `horizon` nights instead of a
/// repeating trigger, so a night that is already being recorded can be left
/// out. The queue is refilled whenever the app becomes active.
@Observable
final class BedtimeReminder: NSObject, UNUserNotificationCenterDelegate {
    static let enabledKey = "bedtimeReminderEnabled"
    /// Minutes after midnight; 60 = 1:00 AM.
    static let minutesKey = "bedtimeReminderMinutes"
    static let defaultMinutes = 60

    private static let idPrefix = "bedtime-"
    private static let categoryId = "BEDTIME"
    private static let startActionId = "START_SESSION"
    private static let horizon = 14

    /// Set when the user taps the notification; HomeView consumes it.
    var startRequested = false

    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
        let start = UNNotificationAction(identifier: Self.startActionId,
                                         title: "Start Sleep Session",
                                         options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryId, actions: [start],
                                   intentIdentifiers: [])
        ])
    }

    /// Asks for notification permission; false if the user declined.
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Replaces every pending reminder with the next `horizon` nights. While a
    /// session is recording, nights starting within 12 h are skipped — no
    /// "start me" in the middle of a night that has already started.
    func reschedule(isRecording: Bool, now: Date = Date()) async {
        let pending = await center.pendingNotificationRequests()
            .map(\.identifier).filter { $0.hasPrefix(Self.idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)

        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.enabledKey) else { return }
        let minutes = defaults.object(forKey: Self.minutesKey) as? Int ?? Self.defaultMinutes

        let content = UNMutableNotificationContent()
        content.title = "Time to start Dream Catcher"
        content.body = "Tap to start tonight's sleep session."
        content.sound = .default
        content.categoryIdentifier = Self.categoryId

        let calendar = Calendar.current
        let match = DateComponents(hour: minutes / 60, minute: minutes % 60)
        let skipUntil = isRecording ? now.addingTimeInterval(12 * 3600) : now
        var cursor = now
        var added = 0
        while added < Self.horizon,
              let next = calendar.nextDate(after: cursor, matching: match,
                                           matchingPolicy: .nextTime) {
            cursor = next
            if next <= skipUntil { continue }
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: next)
            let id = "\(Self.idPrefix)\(parts.year!)-\(parts.month!)-\(parts.day!)"
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: id, content: content,
                                                        trigger: trigger))
            added += 1
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        guard response.notification.request.identifier.hasPrefix(Self.idPrefix),
              response.actionIdentifier != UNNotificationDismissActionIdentifier
        else { return }
        await MainActor.run { startRequested = true }
    }

    /// Show the banner even if the app happens to be open at bedtime.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
