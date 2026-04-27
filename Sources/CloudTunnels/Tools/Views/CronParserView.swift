import AppKit
import SwiftUI

/// Cron Expression Parser — decode a 5-field cron string (or
/// `@hourly`/`@daily`/etc.), show a plain-English breakdown, and
/// preview the next 5 fire times in both UTC and the user's local
/// timezone. Useful for k8s CronJobs, Airflow DAGs, and any other
/// cron-scheduled system.
struct CronParserView: View {
    @State private var input: String = ""
    @State private var parsed: CronExpression.Parsed?
    @State private var description: String = ""
    @State private var nextUTC: [Date] = []
    @State private var nextLocal: [Date] = []
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                inputRow
                Divider().opacity(0.4)
                output
            }
            .padding(14)
        }
    }

    // MARK: - Sections

    private var inputRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CRON EXPRESSION")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
            TextField("*/15 * * * *", text: $input)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14, design: .monospaced))
                .onChange(of: input) { _ in runParse() }
            HStack {
                Text("Supports 5-field POSIX cron and `@hourly`/`@daily`/`@weekly`/`@monthly`/`@yearly` shortcuts.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Menu("Examples") {
                    Button("*/15 * * * * — Every 15 minutes") { input = "*/15 * * * *"; runParse() }
                    Button("0 9 * * 1-5 — Weekdays at 9am") { input = "0 9 * * 1-5"; runParse() }
                    Button("0 */6 * * * — Every 6 hours") { input = "0 */6 * * *"; runParse() }
                    Button("@daily — Midnight daily") { input = "@daily"; runParse() }
                    Button("@hourly — Top of every hour") { input = "@hourly"; runParse() }
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var output: some View {
        if let _ = parsed {
            VStack(alignment: .leading, spacing: 14) {
                descriptionRow
                fireTimesSection
            }
        } else if let err = errorMessage {
            Text(err)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "clock.badge.checkmark.fill")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Enter a cron expression above")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    private var descriptionRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "text.bubble.fill")
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 13))
            Text(description.isEmpty ? "…" : description.capitalized(with: nil))
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.08))
        )
    }

    private var fireTimesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NEXT 5 FIRE TIMES")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 10) {
                fireTimesColumn(title: "UTC", dates: nextUTC, formatter: Self.utcFormatter)
                fireTimesColumn(title: "Local (\(TimeZone.current.abbreviation() ?? "local"))",
                                dates: nextLocal,
                                formatter: Self.localFormatter)
            }
        }
    }

    private func fireTimesColumn(
        title: String,
        dates: [Date],
        formatter: DateFormatter
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(dates.enumerated()), id: \.offset) { _, date in
                Text(formatter.string(from: date))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(0.04))
                    )
            }
        }
    }

    // MARK: - Actions

    private func runParse() {
        errorMessage = nil
        parsed = nil
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let p = try CronExpression.parse(trimmed)
            parsed = p
            description = CronExpression.describe(p)
            let now = Date()
            nextUTC = CronExpression.nextFireTimes(p, after: now, count: 5, in: TimeZone(identifier: "UTC") ?? .current)
            nextLocal = CronExpression.nextFireTimes(p, after: now, count: 5, in: .current)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static let utcFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        return f
    }()

    private static let localFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}
