import Foundation

/// Routes a meeting reminder to the right channel based on whether
/// the menu-bar popover is currently visible.
///
///   - **Popover open** → in-popover `ToastManager` banner so the
///     alert lands next to what the user is already looking at.
///   - **Popover closed** → macOS system notification via
///     `Notifications.postMeeting(...)` so it surfaces in the
///     notification center even if the user is in a different app.
///
/// Thin shim by design — the dedupe / due-window logic lives in
/// `CalendarManager.dueAlerts(...)` so it's independently testable
/// without any `@MainActor` or notification-center mocking.
@MainActor
enum MeetingAlerter {
    static func fire(
        event: CalendarManager.Upcoming,
        minutesBefore: Int,
        popoverOpen: Bool,
        toasts: ToastManager
    ) {
        let title = titleText(for: event, minutesBefore: minutesBefore)
        let body = bodyText(for: event)
        if popoverOpen {
            toasts.show(
                title: title,
                body: body,
                level: minutesBefore <= 1 ? .warning : .info,
                duration: 10
            )
        } else {
            Notifications.postMeeting(
                title: title,
                body: body,
                joinURL: event.joinURL,
                identifier: "calendar:\(event.id):\(minutesBefore)"
            )
        }
    }

    /// "Standup in 5 min" / "Standup starting now" — shared between
    /// toast and system notification so the two channels read the
    /// same way. Exposed for tests. `nonisolated` so test code can
    /// call it without bouncing through the main actor.
    nonisolated static func titleText(
        for event: CalendarManager.Upcoming,
        minutesBefore: Int
    ) -> String {
        if minutesBefore <= 1 {
            return "\(event.title) starting now"
        }
        return "\(event.title) in \(minutesBefore) min"
    }

    /// Secondary line: calendar title + duration, or calendar title
    /// alone if we don't want to clutter. Keeps things short.
    nonisolated static func bodyText(for event: CalendarManager.Upcoming) -> String {
        event.calendarTitle
    }
}
