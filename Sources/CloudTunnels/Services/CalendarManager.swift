import AppKit
import EventKit
import Foundation
import SwiftUI
import TunnelCore
import os

/// Owns the EventKit authorization state, the cached list of upcoming
/// events, and the polling loop that keeps them fresh. Exposed as an
/// `ObservableObject` so the top-banner and the Calendar tool view
/// both re-render when events change.
///
/// **Why an ObservableObject and not an actor:** the views need
/// `@Published` updates, which SwiftUI only picks up from
/// `ObservableObject`s. All mutations happen on the main actor, so
/// there's no concurrency hazard.
///
/// **EventKit access path:** macOS 13 uses the deprecated
/// `requestAccess(to: .event)`; macOS 14+ adds
/// `requestFullAccessToEvents()`. We branch at runtime so we compile
/// cleanly on the macOS 13 SDK while still granting `.fullAccess`
/// when run on 14+ (EK requires it there for read operations).
@MainActor
final class CalendarManager: ObservableObject {

    /// Normalized auth state, collapsing EventKit's legacy + new
    /// enum cases (`.authorized`, `.fullAccess`, `.writeOnly`) into
    /// one `granted` case. Views only need to distinguish "can read
    /// events" from "cannot".
    enum AuthState: Equatable {
        case unknown
        case notDetermined
        case denied
        case restricted
        case granted
    }

    /// Flat, display-friendly event DTO. Deliberately uninvolved with
    /// `EKEvent` types so the tests that exercise reminder-dispatch
    /// and view-formatter logic don't need a running `EKEventStore`.
    struct Upcoming: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let calendarTitle: String
        let calendarColorRGB: (red: Double, green: Double, blue: Double)
        let location: String?
        let notes: String?
        let joinURL: URL?
        let organizer: String?

        /// The calendar color as a SwiftUI Color for view rendering.
        /// Split out so `Upcoming` itself stays free of SwiftUI in
        /// places that don't need it.
        var calendarColor: Color {
            Color(red: calendarColorRGB.red, green: calendarColorRGB.green, blue: calendarColorRGB.blue)
        }

        /// SwiftUI `Equatable` uses the synthesized implementation,
        /// but tuples need manual equality.
        static func == (lhs: Upcoming, rhs: Upcoming) -> Bool {
            lhs.id == rhs.id
                && lhs.title == rhs.title
                && lhs.start == rhs.start
                && lhs.end == rhs.end
                && lhs.isAllDay == rhs.isAllDay
                && lhs.calendarTitle == rhs.calendarTitle
                && lhs.calendarColorRGB == rhs.calendarColorRGB
                && lhs.location == rhs.location
                && lhs.notes == rhs.notes
                && lhs.joinURL == rhs.joinURL
                && lhs.organizer == rhs.organizer
        }
    }

    @Published private(set) var authState: AuthState = .unknown
    @Published private(set) var upcoming: [Upcoming] = []
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var lastError: String?

    /// Snapshot of the preferences we were started with. Refreshed
    /// every time `start(with:)` is called, so changes to lookahead
    /// / refresh interval / enabled flag take effect on restart.
    private(set) var preferences: CalendarPreferences = .default

    private let store = EKEventStore()
    private var pollTask: Task<Void, Never>?
    private var reminderTickTask: Task<Void, Never>?

    /// Dedupe set for fired alerts. Keyed by "<eventID>:<minutesBefore>"
    /// so the same event can fire a 5-min and a 1-min alert but not
    /// the 5-min alert twice. Cleared nightly in `refresh()` to
    /// avoid unbounded growth.
    private var firedAlerts: Set<String> = []

    /// Optional hook used by `MeetingAlerter` so the manager can fire
    /// alerts without having a hard dependency on the alerter. Set by
    /// `CloudTunnelsApp` once `ToastManager` is available.
    var onReminderDue: ((Upcoming, Int) -> Void)?

    private let log = Logger(subsystem: "com.fourninecloud.cloud-tunnels", category: "calendar")

    // MARK: - Authorization

    /// Prompt for calendar access. Bridges the macOS 13 vs 14 API
    /// split. Idempotent — safe to call on every app launch.
    func requestAccessIfNeeded() async {
        // Resolve current status first so we don't fire a prompt
        // unnecessarily on re-launch.
        let current = currentAuthStatus()
        if current != .notDetermined {
            self.authState = normalize(current)
            if self.authState != .granted {
                log.warning("calendar access not granted: state=\(String(describing: self.authState), privacy: .public)")
            }
            return
        }

        do {
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = try await store.requestFullAccessToEvents()
            } else {
                granted = try await withCheckedThrowingContinuation { cont in
                    store.requestAccess(to: .event) { ok, err in
                        if let err { cont.resume(throwing: err) }
                        else { cont.resume(returning: ok) }
                    }
                }
            }
            self.authState = granted ? .granted : .denied
            log.info("calendar access request completed: granted=\(granted, privacy: .public)")
        } catch {
            self.lastError = "Calendar access request failed: \(error.localizedDescription)"
            self.authState = .denied
            log.error("calendar access request errored: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Query EventKit for the current authorization status without
    /// prompting. Converts the new `.fullAccess` / `.writeOnly`
    /// cases (macOS 14+) into the legacy-compatible enum.
    private func currentAuthStatus() -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    private func normalize(_ status: EKAuthorizationStatus) -> AuthState {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .authorized:
            return .granted
        @unknown default:
            // macOS 14+ adds `.fullAccess` and `.writeOnly` which
            // fall through here when building against the 13 SDK.
            // We still accept them at runtime because the raw value
            // is `>= 3`.
            if status.rawValue >= 3 {
                return .granted
            }
            return .unknown
        }
    }

    // MARK: - Polling lifecycle

    /// Start the polling loop using the given preferences. Safe to
    /// call repeatedly — each call cancels the previous loops before
    /// spawning new ones.
    func start(with preferences: CalendarPreferences) {
        stop()
        self.preferences = preferences
        guard preferences.enabled else {
            log.info("calendar polling skipped: disabled in preferences")
            return
        }
        guard authState == .granted else {
            log.info("calendar polling skipped: auth not granted")
            return
        }

        // Main refresh loop — re-queries EventKit every
        // `refreshIntervalMinutes` (floored at 1 min).
        let interval = max(1, preferences.refreshIntervalMinutes)
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refresh()
                let seconds = UInt64(interval * 60)
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }

        // Separate 60-second tick for reminder checks. Kept isolated
        // from the refresh loop so a slow EventKit call can't delay
        // a reminder firing.
        reminderTickTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.tickReminders()
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        }

        log.info("calendar polling started: interval=\(interval, privacy: .public)min")
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        reminderTickTask?.cancel()
        reminderTickTask = nil
    }

    // MARK: - Refresh

    /// Re-query EventKit for events in
    /// `[now, now + lookaheadDays]` and rebuild `upcoming`.
    func refresh() async {
        guard authState == .granted else {
            log.debug("refresh skipped: auth not granted")
            return
        }

        let now = Date()
        let windowEnd = Calendar.current.date(
            byAdding: .day,
            value: max(1, preferences.lookaheadDays),
            to: now
        ) ?? now.addingTimeInterval(2 * 24 * 3600)

        let calendars: [EKCalendar]?
        if preferences.enabledCalendarIdentifiers.isEmpty {
            calendars = nil  // nil = all visible calendars
        } else {
            let all = store.calendars(for: .event)
            calendars = all.filter { preferences.enabledCalendarIdentifiers.contains($0.calendarIdentifier) }
        }

        let predicate = store.predicateForEvents(
            withStart: now,
            end: windowEnd,
            calendars: calendars
        )
        let events = store.events(matching: predicate)

        // Convert EKEvents to flat DTOs. Filter all-day events if the
        // user opted out, and drop events that already ended (an
        // EventKit predicate window of [now, end] still includes
        // events that started before `now` but haven't ended yet).
        var out: [Upcoming] = []
        for ev in events {
            if ev.isAllDay && !preferences.showAllDayEvents {
                continue
            }
            if ev.endDate <= now {
                continue
            }
            out.append(convert(ev))
        }

        // Sort by start time so the "next meeting" banner can just
        // take `upcoming.first`.
        out.sort { $0.start < $1.start }

        self.upcoming = out
        self.lastRefresh = now
        self.lastError = nil

        // Prune the fired-alerts dedupe set: drop entries for events
        // that are no longer upcoming (user deleted them, they ended,
        // etc.). Prevents unbounded growth and un-fires reminders if
        // a user re-schedules a meeting with the same ID.
        let liveIDs = Set(out.map(\.id))
        firedAlerts = firedAlerts.filter { key in
            let eventID = key.split(separator: ":").first.map(String.init) ?? ""
            return liveIDs.contains(eventID)
        }

        log.debug("calendar refresh: \(out.count, privacy: .public) upcoming events")
    }

    /// Convert an EKEvent to an `Upcoming` DTO. Looks up the join
    /// URL via `JoinLinkExtractor`.
    private func convert(_ ev: EKEvent) -> Upcoming {
        let join = JoinLinkExtractor.extract(
            location: ev.location,
            notes: ev.notes,
            url: ev.url
        )

        // Calendar color: EKCalendar.cgColor is NSColor-backed.
        // Convert to sRGB components for stable archiving as a tuple.
        let rgb = Self.rgbComponents(of: ev.calendar.cgColor)

        return Upcoming(
            id: ev.eventIdentifier ?? UUID().uuidString,
            title: ev.title ?? "(untitled)",
            start: ev.startDate,
            end: ev.endDate,
            isAllDay: ev.isAllDay,
            calendarTitle: ev.calendar.title,
            calendarColorRGB: rgb,
            location: ev.location?.isEmpty == true ? nil : ev.location,
            notes: ev.notes?.isEmpty == true ? nil : ev.notes,
            joinURL: join,
            organizer: ev.organizer?.name
        )
    }

    /// Pull sRGB components out of a CGColor, falling back to a mid
    /// gray for unknown color spaces. Used so a test can build an
    /// `Upcoming` with a fixed color without any AppKit roundtrip.
    nonisolated static func rgbComponents(of cgColor: CGColor?) -> (red: Double, green: Double, blue: Double) {
        guard let cgColor else {
            return (0.5, 0.5, 0.5)
        }
        let nsColor = NSColor(cgColor: cgColor) ?? .systemGray
        if let rgb = nsColor.usingColorSpace(.sRGB) {
            return (Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent))
        }
        return (0.5, 0.5, 0.5)
    }

    // MARK: - Reminder dispatch

    /// One tick of the reminder loop. Walks `upcoming`, computes the
    /// per-event dispatcher outcome via the pure helper, and fires
    /// the `onReminderDue` hook for anything new.
    func tickReminders() async {
        guard preferences.enabled, !preferences.reminderLeadMinutes.isEmpty else {
            return
        }
        let now = Date()
        let due = Self.dueAlerts(
            events: upcoming,
            now: now,
            leadMinutes: preferences.reminderLeadMinutes,
            alreadyFired: firedAlerts
        )
        for (event, lead) in due {
            let key = "\(event.id):\(lead)"
            firedAlerts.insert(key)
            onReminderDue?(event, lead)
            log.info("reminder fired: event=\(event.title, privacy: .public) lead=\(lead, privacy: .public)min")
        }
    }

    /// Pure dispatch logic — split out of `tickReminders` so tests
    /// can exercise it with fabricated events. No `@MainActor`, no
    /// EventKit, no ToastManager.
    ///
    /// An alert "is due" if:
    ///   - `event` is not all-day,
    ///   - `event.start > now` (the meeting hasn't started yet),
    ///   - there exists a `lead` in `leadMinutes` such that the gap
    ///     between `now` and `event.start` is <= `lead` minutes and
    ///     > `(lead - 1)` minutes (so a 5-min lead fires in the
    ///     [4, 5) minute window, once per tick),
    ///   - AND `"<event.id>:<lead>"` is not already in `alreadyFired`.
    ///
    /// Returns one (event, lead) pair per firing so the caller can
    /// log and dedupe in one place.
    nonisolated static func dueAlerts(
        events: [Upcoming],
        now: Date,
        leadMinutes: [Int],
        alreadyFired: Set<String>
    ) -> [(Upcoming, Int)] {
        var out: [(Upcoming, Int)] = []
        // Sort leads largest-first so we test "is this the 5-min
        // window" before "is this the 1-min window"; otherwise a
        // 1-min alert at T-4:30 could shadow a 5-min alert at the
        // same tick.
        let leads = leadMinutes.sorted(by: >)
        for event in events {
            if event.isAllDay { continue }
            if event.start <= now { continue }
            let secondsUntilStart = event.start.timeIntervalSince(now)
            let minutesUntilStart = secondsUntilStart / 60.0
            for lead in leads {
                let key = "\(event.id):\(lead)"
                if alreadyFired.contains(key) { continue }
                let upper = Double(lead)
                let lower = Double(lead - 1)
                if minutesUntilStart <= upper && minutesUntilStart > lower {
                    out.append((event, lead))
                    break  // Don't fire a second lead for the same event in one tick
                }
            }
        }
        return out
    }
}
