import AppKit
import SwiftUI

/// Calendar — shows upcoming meetings from the user's macOS
/// calendars (EventKit-backed). Grouped by Today / Tomorrow /
/// Later. Each row has a [Join] button when we can extract a Zoom /
/// Meet / Teams / Webex link from the event.
///
/// State lives in the app-level `CalendarManager` environment
/// object, so the panel re-renders for free when the polling loop
/// refreshes events in the background.
struct CalendarView: View {
    @EnvironmentObject var calendar: CalendarManager
    @State private var isRefreshing: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                Divider().opacity(0.4)
                content
            }
            .padding(14)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Upcoming meetings")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            if let last = calendar.lastRefresh {
                Text("Updated \(Self.relativeFormatter.localizedString(for: last, relativeTo: Date()))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Button {
                Task {
                    isRefreshing = true
                    await calendar.refresh()
                    isRefreshing = false
                }
            } label: {
                if isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Refresh")
            .disabled(isRefreshing || calendar.authState != .granted)
        }
    }

    // MARK: - Content switch

    @ViewBuilder
    private var content: some View {
        switch calendar.authState {
        case .granted:
            grantedContent
        case .notDetermined, .unknown:
            pendingPermission
        case .denied, .restricted:
            deniedPermission
        }
    }

    // MARK: - Granted

    @ViewBuilder
    private var grantedContent: some View {
        if calendar.upcoming.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(groupedEvents, id: \.label) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.label.uppercased())
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.4)
                            .foregroundStyle(.secondary)
                        VStack(spacing: 6) {
                            ForEach(group.events) { event in
                                eventRow(event)
                            }
                        }
                    }
                }
                if let err = calendar.lastError {
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func eventRow(_ event: CalendarManager.Upcoming) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(event.calendarColor)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Self.timeFormatter.string(from: event.start))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(event.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    if let url = event.joinURL {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "video.fill")
                                    .font(.system(size: 9))
                                Text("Join")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(.accentColor)
                        .help(url.absoluteString)
                    }
                }
                HStack(spacing: 6) {
                    Text(event.calendarTitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(Self.durationText(start: event.start, end: event.end))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.05))
        )
    }

    // MARK: - Empty / permission states

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "calendar")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("No upcoming meetings in the next \(calendar.preferences.lookaheadDays) days")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var pendingPermission: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("CloudTunnels needs access to your calendars.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await calendar.requestAccessIfNeeded() }
            } label: {
                Text("Grant Access")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var deniedPermission: some View {
        VStack(spacing: 6) {
            Image(systemName: "lock.slash.fill")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.orange)
            Text("Calendar access is denied or restricted.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("Open System Settings → Privacy & Security → Calendars to grant CloudTunnels access.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
                NSWorkspace.shared.open(url)
            } label: {
                Text("Open System Settings")
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Grouping helper

    /// Flat list → [(label, [events])], bucketed by Today / Tomorrow
    /// / Later based on the user's current calendar day. Exposed as
    /// a computed property so it re-runs when `upcoming` changes.
    private var groupedEvents: [(label: String, events: [CalendarManager.Upcoming])] {
        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        let tomorrowStart = cal.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart
        let dayAfterTomorrowStart = cal.date(byAdding: .day, value: 2, to: todayStart) ?? todayStart

        var today: [CalendarManager.Upcoming] = []
        var tomorrow: [CalendarManager.Upcoming] = []
        var later: [CalendarManager.Upcoming] = []

        for event in calendar.upcoming {
            if event.start < tomorrowStart {
                today.append(event)
            } else if event.start < dayAfterTomorrowStart {
                tomorrow.append(event)
            } else {
                later.append(event)
            }
        }

        var out: [(label: String, events: [CalendarManager.Upcoming])] = []
        if !today.isEmpty { out.append(("Today", today)) }
        if !tomorrow.isEmpty { out.append(("Tomorrow", tomorrow)) }
        if !later.isEmpty { out.append(("Later", later)) }
        return out
    }

    // MARK: - Formatters

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    /// Compact duration string like "30 min" or "1h 30m".
    static func durationText(start: Date, end: Date) -> String {
        let minutes = max(0, Int(end.timeIntervalSince(start) / 60))
        if minutes == 0 { return "0 min" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rem = minutes % 60
        if rem == 0 { return "\(hours)h" }
        return "\(hours)h \(rem)m"
    }
}
