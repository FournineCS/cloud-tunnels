import Foundation

/// Hand-rolled parser for 5-field POSIX cron expressions plus the
/// common `@hourly`/`@daily`/`@weekly`/`@monthly`/`@yearly` aliases.
/// No dependency — the logic is small enough that pulling in a cron
/// library would be net overhead.
///
/// Field order is the standard: minute / hour / day-of-month /
/// month / day-of-week. Day-of-week uses 0-6 where 0 = Sunday
/// (matching k8s CronJob convention via Go's robfig/cron).
///
/// Supported field syntax:
///   - Literal: `5`
///   - Wildcard: `*`
///   - Range: `1-5`
///   - List: `1,3,5`
///   - Step on wildcard: `*/15`
///   - Step on range: `0-30/5`
///
/// Not supported (deferred — rare in practice):
///   - Named months/days (`JAN`, `MON`)
///   - Seconds field (`* * * * * *`)
///   - Last-day-of-month (`L`)
///   - Nearest-weekday (`W`)
public enum CronExpression {

    /// Represents a single field's value set. `any` means the
    /// field matches every legal value in its range.
    public enum Field: Equatable {
        case any
        case values(Set<Int>)

        public func matches(_ value: Int) -> Bool {
            switch self {
            case .any:
                return true
            case .values(let set):
                return set.contains(value)
            }
        }
    }

    public struct Parsed: Equatable {
        public var minute: Field
        public var hour: Field
        public var dayOfMonth: Field
        public var month: Field
        public var dayOfWeek: Field
        public var raw: String
    }

    public enum ParseError: LocalizedError, Equatable {
        case wrongFieldCount(Int)
        case badField(field: String, value: String, reason: String)
        case unknownAlias(String)

        public var errorDescription: String? {
            switch self {
            case .wrongFieldCount(let n):
                return "Expected 5 fields, got \(n). Example: `*/15 * * * *`"
            case .badField(let field, let value, let reason):
                return "Bad \(field) field `\(value)`: \(reason)"
            case .unknownAlias(let s):
                return "Unknown shortcut `\(s)`. Supported: @hourly, @daily, @weekly, @monthly, @yearly"
            }
        }
    }

    // MARK: - Legal field ranges

    public struct Range {
        public let field: String
        public let lower: Int
        public let upper: Int
    }

    public static let minuteRange = Range(field: "minute", lower: 0, upper: 59)
    public static let hourRange = Range(field: "hour", lower: 0, upper: 23)
    public static let domRange = Range(field: "day-of-month", lower: 1, upper: 31)
    public static let monthRange = Range(field: "month", lower: 1, upper: 12)
    public static let dowRange = Range(field: "day-of-week", lower: 0, upper: 6)

    // MARK: - Parse

    /// Parse a cron expression or an alias. Throws ParseError on
    /// malformed input.
    public static func parse(_ raw: String) throws -> Parsed {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ParseError.wrongFieldCount(0)
        }

        // Alias expansion. Each alias becomes a regular 5-field
        // expression before we parse.
        if trimmed.hasPrefix("@") {
            let expanded = try expandAlias(trimmed)
            return try parseFiveFields(expanded, raw: trimmed)
        }

        return try parseFiveFields(trimmed, raw: trimmed)
    }

    /// Expand a `@alias` into the equivalent 5-field expression.
    /// Exposed for tests.
    public static func expandAlias(_ alias: String) throws -> String {
        switch alias {
        case "@hourly": return "0 * * * *"
        case "@daily", "@midnight": return "0 0 * * *"
        case "@weekly": return "0 0 * * 0"
        case "@monthly": return "0 0 1 * *"
        case "@yearly", "@annually": return "0 0 1 1 *"
        default: throw ParseError.unknownAlias(alias)
        }
    }

    /// Split and parse a 5-field expression. The `raw` parameter
    /// is stored in the result for display and doesn't affect
    /// parsing.
    public static func parseFiveFields(_ expression: String, raw: String) throws -> Parsed {
        let fields = expression
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard fields.count == 5 else {
            throw ParseError.wrongFieldCount(fields.count)
        }
        return Parsed(
            minute: try parseField(fields[0], range: minuteRange),
            hour: try parseField(fields[1], range: hourRange),
            dayOfMonth: try parseField(fields[2], range: domRange),
            month: try parseField(fields[3], range: monthRange),
            dayOfWeek: try parseField(fields[4], range: dowRange),
            raw: raw
        )
    }

    /// Parse a single field against its legal range. Handles
    /// lists (comma-separated), wildcards, ranges, and step
    /// values on both. Exposed for direct unit testing.
    public static func parseField(_ raw: String, range: Range) throws -> Field {
        // Lists recurse: "1,3-5,*/10" splits on comma and unions.
        if raw.contains(",") {
            var union: Set<Int> = []
            for piece in raw.split(separator: ",").map(String.init) {
                let field = try parseField(piece, range: range)
                switch field {
                case .any:
                    // Any element being wildcard means the whole
                    // list is wildcard.
                    return .any
                case .values(let v):
                    union.formUnion(v)
                }
            }
            if union.count == (range.upper - range.lower + 1) {
                return .any
            }
            return .values(union)
        }

        // Step values: "foo/N" where foo is either "*" or a range.
        if raw.contains("/") {
            let parts = raw.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, let step = Int(parts[1]), step > 0 else {
                throw ParseError.badField(
                    field: range.field, value: raw, reason: "step must be a positive integer")
            }
            let baseValues: [Int]
            if parts[0] == "*" {
                baseValues = Array(range.lower...range.upper)
            } else if parts[0].contains("-") {
                let rangeParts = parts[0].split(separator: "-").map(String.init)
                guard rangeParts.count == 2,
                      let lo = Int(rangeParts[0]),
                      let hi = Int(rangeParts[1])
                else {
                    throw ParseError.badField(
                        field: range.field, value: raw, reason: "invalid step base range")
                }
                try validate(value: lo, in: range, original: raw)
                try validate(value: hi, in: range, original: raw)
                guard lo <= hi else {
                    throw ParseError.badField(
                        field: range.field, value: raw,
                        reason: "step range lower > upper")
                }
                baseValues = Array(lo...hi)
            } else {
                throw ParseError.badField(
                    field: range.field, value: raw,
                    reason: "step base must be `*` or a range like `0-30`")
            }
            var picked: Set<Int> = []
            let start = baseValues.first ?? range.lower
            for v in baseValues where (v - start) % step == 0 {
                picked.insert(v)
            }
            if picked.count == (range.upper - range.lower + 1) {
                return .any
            }
            return .values(picked)
        }

        // Wildcard
        if raw == "*" { return .any }

        // Range: "1-5"
        if raw.contains("-") {
            let parts = raw.split(separator: "-").map(String.init)
            guard parts.count == 2,
                  let lo = Int(parts[0]),
                  let hi = Int(parts[1])
            else {
                throw ParseError.badField(
                    field: range.field, value: raw, reason: "expected `lo-hi`")
            }
            try validate(value: lo, in: range, original: raw)
            try validate(value: hi, in: range, original: raw)
            guard lo <= hi else {
                throw ParseError.badField(
                    field: range.field, value: raw, reason: "range lower > upper")
            }
            let values = Set(Array(lo...hi))
            if values.count == (range.upper - range.lower + 1) {
                return .any
            }
            return .values(values)
        }

        // Literal single value
        guard let v = Int(raw) else {
            throw ParseError.badField(
                field: range.field, value: raw, reason: "not a valid integer")
        }
        try validate(value: v, in: range, original: raw)
        return .values([v])
    }

    static func validate(value: Int, in range: Range, original: String) throws {
        if value < range.lower || value > range.upper {
            throw ParseError.badField(
                field: range.field, value: original,
                reason: "value \(value) outside \(range.lower)-\(range.upper)")
        }
    }

    // MARK: - Description

    /// English-prose description of a parsed cron expression.
    /// Used as the header line in the view.
    public static func describe(_ parsed: Parsed) -> String {
        let minuteDesc = describeField(parsed.minute, kind: .minute)
        let hourDesc = describeField(parsed.hour, kind: .hour)
        let domDesc = describeField(parsed.dayOfMonth, kind: .dom)
        let monthDesc = describeField(parsed.month, kind: .month)
        let dowDesc = describeField(parsed.dayOfWeek, kind: .dow)

        return [minuteDesc, hourDesc, domDesc, monthDesc, dowDesc]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    enum FieldKind { case minute, hour, dom, month, dow }

    static func describeField(_ field: Field, kind: FieldKind) -> String {
        switch (field, kind) {
        case (.any, .minute): return "every minute"
        case (.any, .hour): return "every hour"
        case (.any, .dom): return "every day"
        case (.any, .month): return "every month"
        case (.any, .dow): return "every day of the week"
        case (.values(let v), .minute):
            if v.count == 1, let only = v.first {
                return "at minute \(only)"
            }
            if isEvery(v, step: 15, max: 59) { return "every 15 minutes" }
            if isEvery(v, step: 10, max: 59) { return "every 10 minutes" }
            if isEvery(v, step: 5, max: 59) { return "every 5 minutes" }
            return "at \(formatList(v)) minutes"
        case (.values(let v), .hour):
            if v.count == 1, let only = v.first {
                return "at \(formatHour(only))"
            }
            if let lo = v.min(), let hi = v.max(), v == Set(lo...hi) {
                return "during \(formatHour(lo))–\(formatHour(hi))"
            }
            return "at hours \(formatList(v))"
        case (.values(let v), .dom):
            if v.count == 1, let only = v.first {
                return "on day \(only)"
            }
            return "on days \(formatList(v))"
        case (.values(let v), .month):
            let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                         "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            let sorted = v.sorted()
            let mapped = sorted.compactMap { i -> String? in
                guard (1...12).contains(i) else { return nil }
                return names[i - 1]
            }
            return "in \(mapped.joined(separator: "/"))"
        case (.values(let v), .dow):
            let sorted = Array(v).sorted()
            if sorted == [1, 2, 3, 4, 5] { return "on weekdays" }
            if sorted == [0, 6] { return "on weekends" }
            let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            let mapped = sorted.compactMap { i -> String? in
                guard (0...6).contains(i) else { return nil }
                return names[i]
            }
            return "on \(mapped.joined(separator: "/"))"
        }
    }

    static func isEvery(_ values: Set<Int>, step: Int, max: Int) -> Bool {
        let expected = Set(stride(from: 0, through: max, by: step))
        return values == expected
    }

    static func formatList(_ values: Set<Int>) -> String {
        values.sorted().map(String.init).joined(separator: ", ")
    }

    static func formatHour(_ h: Int) -> String {
        // 12-hour friendly: "9am", "5pm", "midnight", "noon"
        if h == 0 { return "midnight" }
        if h == 12 { return "noon" }
        if h < 12 { return "\(h)am" }
        return "\(h - 12)pm"
    }

    // MARK: - Next fire times

    /// Compute the next `count` fire times after the given
    /// reference date, in the given calendar/timezone. Uses a
    /// minute-by-minute walk with a sanity cap to prevent
    /// infinite loops on impossible expressions (e.g. Feb 30).
    public static func nextFireTimes(
        _ parsed: Parsed,
        after: Date,
        count: Int,
        in timeZone: TimeZone
    ) -> [Date] {
        var results: [Date] = []
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        // Start from the next minute boundary after `after`,
        // zeroing seconds and nanoseconds.
        var comps = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: after
        )
        guard let seed = calendar.date(from: comps) else { return [] }
        var cursor = seed.addingTimeInterval(60)

        // Sanity cap: walk at most 4 years of minutes before
        // giving up. A well-formed expression hits its first
        // match well within this bound.
        let maxIterations = 366 * 24 * 60 * 4
        var i = 0
        while results.count < count && i < maxIterations {
            i += 1
            comps = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .weekday],
                from: cursor
            )
            let minute = comps.minute ?? 0
            let hour = comps.hour ?? 0
            let dom = comps.day ?? 1
            let month = comps.month ?? 1
            // Calendar.weekday returns 1-7 (Sun=1). Cron uses 0-6
            // (Sun=0). Subtract 1.
            let dow = (comps.weekday ?? 1) - 1

            let minuteOK = parsed.minute.matches(minute)
            let hourOK = parsed.hour.matches(hour)
            let domOK = parsed.dayOfMonth.matches(dom)
            let monthOK = parsed.month.matches(month)
            let dowOK = parsed.dayOfWeek.matches(dow)

            // Cron's weird day-of-month + day-of-week OR rule:
            // if either field is not wildcard, the match is OR
            // instead of AND. If both are wildcard it's a plain
            // AND (which devolves to "every day" anyway).
            let domWild = parsed.dayOfMonth == .any
            let dowWild = parsed.dayOfWeek == .any
            let dayOK: Bool
            if domWild && dowWild {
                dayOK = true
            } else if domWild {
                dayOK = dowOK
            } else if dowWild {
                dayOK = domOK
            } else {
                dayOK = domOK || dowOK
            }

            if minuteOK && hourOK && monthOK && dayOK {
                results.append(cursor)
            }
            cursor = cursor.addingTimeInterval(60)
        }
        return results
    }
}
