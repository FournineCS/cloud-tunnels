import AppKit
import SwiftUI

/// Compact "next meeting" strip rendered at the top of the menu-bar
/// popover, above the tab bar. Visible from every tab as long as
/// there's an upcoming event and calendar access is granted.
///
/// Uses a `TimelineView(.periodic)` to re-tick the countdown every
/// 30 seconds without the outer view having to own a timer.
struct UpcomingMeetingBanner: View {
    @ObservedObject var calendar: CalendarManager

    var body: some View {
        if calendar.authState == .granted,
           let event = calendar.upcoming.first {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                content(for: event, now: context.date)
            }
        }
    }

    @ViewBuilder
    private func content(for event: CalendarManager.Upcoming, now: Date) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(event.calendarColor)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))

            Text(event.title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)

            Text("·")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Text(Self.countdownText(from: now, to: event.start))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer(minLength: 4)

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

            Menu {
                Button("Open Calendar.app") {
                    NSWorkspace.shared.open(URL(string: "ical://")!)
                }
                Button("Refresh") {
                    Task { await calendar.refresh() }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            Rectangle().fill(event.calendarColor.opacity(0.08))
        )
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundStyle(Color.primary.opacity(0.08)),
            alignment: .bottom
        )
    }

    /// Friendly countdown: "now", "in 30 sec", "in 4 min",
    /// "in 1 hour", "in 2 hours", etc. Tests exercise the common
    /// boundaries directly via `CalendarViewTests`.
    static func countdownText(from now: Date, to start: Date) -> String {
        let seconds = start.timeIntervalSince(now)
        if seconds <= 0 { return "now" }
        if seconds < 60 { return "in \(Int(seconds)) sec" }
        let minutes = Int(seconds / 60)
        if minutes < 60 {
            return "in \(minutes) min"
        }
        let hours = minutes / 60
        if hours == 1 {
            return "in 1 hour"
        }
        if hours < 24 {
            return "in \(hours) hours"
        }
        let days = hours / 24
        return days == 1 ? "in 1 day" : "in \(days) days"
    }
}
