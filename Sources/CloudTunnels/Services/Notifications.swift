import AppKit
import Foundation
import UserNotifications
import os

enum Notifications {
    private static let log = Logger(subsystem: "com.fourninecloud.cloud-tunnels", category: "notifications")

    /// Category id + action id for meeting reminders. Registered
    /// once at launch so `postMeeting(...)` can attach the Join
    /// action via its category identifier.
    static let meetingCategoryID = "CloudTunnels.meetingReminder"
    static let meetingJoinActionID = "CloudTunnels.meetingReminder.join"

    /// Delegate kept alive for the lifetime of the process so the
    /// notification center can route action taps to it.
    private static let delegate = MeetingActionDelegate()

    static func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        registerMeetingCategory()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                log.error("notification auth error: \(error.localizedDescription, privacy: .public)")
            } else {
                log.info("notification auth granted=\(granted, privacy: .public)")
            }
        }
    }

    /// Install the meeting-reminder category with a Join action.
    /// Idempotent — setNotificationCategories replaces the set.
    private static func registerMeetingCategory() {
        let join = UNNotificationAction(
            identifier: meetingJoinActionID,
            title: "Join",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: meetingCategoryID,
            actions: [join],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                log.error("notification post failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Post a meeting reminder. If `joinURL` is non-nil, the banner
    /// carries a "Join" action button that opens the URL in the
    /// user's default browser on tap. `identifier` is used so
    /// re-posting with the same id replaces the prior notification
    /// (dedupe belt + suspenders alongside `firedAlerts` in
    /// CalendarManager).
    static func postMeeting(
        title: String,
        body: String,
        joinURL: URL?,
        identifier: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = meetingCategoryID
        if let url = joinURL {
            content.userInfo = ["joinURL": url.absoluteString]
        }
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                log.error("meeting notification post failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// Routes meeting-reminder action taps back to the right URL. Also
/// forces banners to render while the app is frontmost — the
/// default for `.banner` while foreground is to suppress.
private final class MeetingActionDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let log = Logger(subsystem: "com.fourninecloud.cloud-tunnels", category: "notifications")

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banners + play sound even when the app is
        // foreground, which it is when the popover is open.
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard response.actionIdentifier == Notifications.meetingJoinActionID
                || response.actionIdentifier == UNNotificationDefaultActionIdentifier
        else { return }
        let info = response.notification.request.content.userInfo
        if let urlString = info["joinURL"] as? String,
           let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
            log.info("opened meeting join URL from notification")
        }
    }
}
