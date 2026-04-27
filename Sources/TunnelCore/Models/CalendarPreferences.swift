import Foundation

/// User preferences for the calendar integration. Lives in TunnelCore
/// so both the menu-bar app and the CLI see the same shape, though
/// only the app consumes them today.
///
/// Persisted alongside the rest of `Preferences` inside the main
/// `config.json`. Old config files that predate this struct decode
/// with all fields at their defaults — see `Preferences.init(from:)`.
public struct CalendarPreferences: Codable, Equatable, Sendable {
    /// Master switch. When false, the polling loop doesn't start and
    /// the menu-bar banner is hidden even if access is granted.
    public var enabled: Bool

    /// How many days ahead to fetch. 2 is usually right — surfaces
    /// "tomorrow first thing" without cluttering with next week.
    public var lookaheadDays: Int

    /// How often to re-query EventKit for changes. 5 minutes is a
    /// sensible floor for a calendar that updates every few hours
    /// in practice; `CalendarManager.start` clamps to >= 1 min.
    public var refreshIntervalMinutes: Int

    /// Minutes-before-start at which to fire a reminder. Defaults to
    /// [30, 10, 1] — a "heads up" nudge, a "wrap up" nudge, and a
    /// "you're on" nudge. An empty array disables reminders entirely
    /// (the top banner still shows upcoming meetings).
    public var reminderLeadMinutes: [Int]

    /// EKCalendar identifiers to include. Empty means "all visible
    /// calendars" — the common case. Reserved for a future filter UI.
    public var enabledCalendarIdentifiers: [String]

    /// All-day events clutter the upcoming list (birthdays, OOO).
    /// Off by default; user can opt in from Preferences later.
    public var showAllDayEvents: Bool

    public static let `default` = CalendarPreferences(
        enabled: true,
        lookaheadDays: 2,
        refreshIntervalMinutes: 5,
        reminderLeadMinutes: [30, 10, 1],
        enabledCalendarIdentifiers: [],
        showAllDayEvents: false
    )

    enum CodingKeys: String, CodingKey {
        case enabled
        case lookaheadDays = "lookahead_days"
        case refreshIntervalMinutes = "refresh_interval_minutes"
        case reminderLeadMinutes = "reminder_lead_minutes"
        case enabledCalendarIdentifiers = "enabled_calendar_identifiers"
        case showAllDayEvents = "show_all_day_events"
    }

    public init(
        enabled: Bool = true,
        lookaheadDays: Int = 2,
        refreshIntervalMinutes: Int = 5,
        reminderLeadMinutes: [Int] = [30, 10, 1],
        enabledCalendarIdentifiers: [String] = [],
        showAllDayEvents: Bool = false
    ) {
        self.enabled = enabled
        self.lookaheadDays = lookaheadDays
        self.refreshIntervalMinutes = refreshIntervalMinutes
        // Normalize: sorted descending (we want to fire the earliest
        // lead first in the check loop), dedup, drop non-positive.
        let normalizedLeads = Array(Set(reminderLeadMinutes.filter { $0 > 0 })).sorted(by: >)
        self.reminderLeadMinutes = normalizedLeads
        self.enabledCalendarIdentifiers = enabledCalendarIdentifiers
        self.showAllDayEvents = showAllDayEvents
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        let lookahead = (try? c.decode(Int.self, forKey: .lookaheadDays)) ?? 2
        let interval = (try? c.decode(Int.self, forKey: .refreshIntervalMinutes)) ?? 5
        let leads = (try? c.decode([Int].self, forKey: .reminderLeadMinutes)) ?? [30, 10, 1]
        let ids = (try? c.decode([String].self, forKey: .enabledCalendarIdentifiers)) ?? []
        let allDay = (try? c.decode(Bool.self, forKey: .showAllDayEvents)) ?? false
        self.init(
            enabled: enabled,
            lookaheadDays: lookahead,
            refreshIntervalMinutes: interval,
            reminderLeadMinutes: leads,
            enabledCalendarIdentifiers: ids,
            showAllDayEvents: allDay
        )
    }
}
