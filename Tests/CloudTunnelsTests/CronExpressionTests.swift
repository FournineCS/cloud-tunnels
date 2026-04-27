import XCTest
@testable import CloudTunnels

final class CronExpressionTests: XCTestCase {

    // MARK: - parseField (single-field, tight)

    func testParseFieldWildcard() throws {
        let f = try CronExpression.parseField("*", range: CronExpression.minuteRange)
        XCTAssertEqual(f, .any)
    }

    func testParseFieldLiteral() throws {
        let f = try CronExpression.parseField("5", range: CronExpression.minuteRange)
        XCTAssertEqual(f, .values([5]))
    }

    func testParseFieldRange() throws {
        let f = try CronExpression.parseField("1-5", range: CronExpression.dowRange)
        XCTAssertEqual(f, .values([1, 2, 3, 4, 5]))
    }

    func testParseFieldList() throws {
        let f = try CronExpression.parseField("1,3,5", range: CronExpression.minuteRange)
        XCTAssertEqual(f, .values([1, 3, 5]))
    }

    func testParseFieldStepOnWildcard() throws {
        let f = try CronExpression.parseField("*/15", range: CronExpression.minuteRange)
        XCTAssertEqual(f, .values([0, 15, 30, 45]))
    }

    func testParseFieldStepOnRange() throws {
        let f = try CronExpression.parseField("0-30/5", range: CronExpression.minuteRange)
        XCTAssertEqual(f, .values([0, 5, 10, 15, 20, 25, 30]))
    }

    func testParseFieldRejectsOutOfRangeLiteral() {
        XCTAssertThrowsError(
            try CronExpression.parseField("99", range: CronExpression.minuteRange)
        ) { error in
            guard case CronExpression.ParseError.badField = error else {
                return XCTFail("expected badField, got \(error)")
            }
        }
    }

    func testParseFieldRejectsBadChar() {
        XCTAssertThrowsError(
            try CronExpression.parseField("abc", range: CronExpression.minuteRange)
        ) { error in
            guard case CronExpression.ParseError.badField = error else {
                return XCTFail("expected badField, got \(error)")
            }
        }
    }

    func testParseFieldRejectsZeroStep() {
        XCTAssertThrowsError(
            try CronExpression.parseField("*/0", range: CronExpression.minuteRange)
        ) { error in
            guard case CronExpression.ParseError.badField = error else {
                return XCTFail("expected badField, got \(error)")
            }
        }
    }

    func testParseFieldRejectsReversedRange() {
        XCTAssertThrowsError(
            try CronExpression.parseField("10-5", range: CronExpression.minuteRange)
        ) { error in
            guard case CronExpression.ParseError.badField = error else {
                return XCTFail("expected badField, got \(error)")
            }
        }
    }

    // MARK: - parse (full expression)

    func testParseEveryMinute() throws {
        let p = try CronExpression.parse("* * * * *")
        XCTAssertEqual(p.minute, .any)
        XCTAssertEqual(p.hour, .any)
        XCTAssertEqual(p.dayOfMonth, .any)
        XCTAssertEqual(p.month, .any)
        XCTAssertEqual(p.dayOfWeek, .any)
    }

    func testParseEveryFifteenMinutes() throws {
        let p = try CronExpression.parse("*/15 * * * *")
        XCTAssertEqual(p.minute, .values([0, 15, 30, 45]))
        XCTAssertEqual(p.hour, .any)
    }

    func testParseWeekdaysAt9AM() throws {
        let p = try CronExpression.parse("0 9 * * 1-5")
        XCTAssertEqual(p.minute, .values([0]))
        XCTAssertEqual(p.hour, .values([9]))
        XCTAssertEqual(p.dayOfMonth, .any)
        XCTAssertEqual(p.month, .any)
        XCTAssertEqual(p.dayOfWeek, .values([1, 2, 3, 4, 5]))
    }

    func testParseRejectsWrongFieldCount() {
        XCTAssertThrowsError(try CronExpression.parse("* * *")) { error in
            guard case CronExpression.ParseError.wrongFieldCount(let n) = error else {
                return XCTFail("expected wrongFieldCount, got \(error)")
            }
            XCTAssertEqual(n, 3)
        }
    }

    func testParseRejectsEmpty() {
        XCTAssertThrowsError(try CronExpression.parse("")) { error in
            guard case CronExpression.ParseError.wrongFieldCount = error else {
                return XCTFail("expected wrongFieldCount, got \(error)")
            }
        }
    }

    // MARK: - Aliases

    func testExpandHourly() throws {
        XCTAssertEqual(try CronExpression.expandAlias("@hourly"), "0 * * * *")
    }

    func testExpandDaily() throws {
        XCTAssertEqual(try CronExpression.expandAlias("@daily"), "0 0 * * *")
        XCTAssertEqual(try CronExpression.expandAlias("@midnight"), "0 0 * * *")
    }

    func testExpandWeekly() throws {
        XCTAssertEqual(try CronExpression.expandAlias("@weekly"), "0 0 * * 0")
    }

    func testExpandMonthly() throws {
        XCTAssertEqual(try CronExpression.expandAlias("@monthly"), "0 0 1 * *")
    }

    func testExpandYearly() throws {
        XCTAssertEqual(try CronExpression.expandAlias("@yearly"), "0 0 1 1 *")
        XCTAssertEqual(try CronExpression.expandAlias("@annually"), "0 0 1 1 *")
    }

    func testExpandRejectsUnknownAlias() {
        XCTAssertThrowsError(try CronExpression.expandAlias("@never")) { error in
            guard case CronExpression.ParseError.unknownAlias = error else {
                return XCTFail("expected unknownAlias, got \(error)")
            }
        }
    }

    func testParseAliasEndToEnd() throws {
        let p = try CronExpression.parse("@daily")
        XCTAssertEqual(p.minute, .values([0]))
        XCTAssertEqual(p.hour, .values([0]))
        XCTAssertEqual(p.dayOfMonth, .any)
        XCTAssertEqual(p.month, .any)
        XCTAssertEqual(p.dayOfWeek, .any)
        XCTAssertEqual(p.raw, "@daily")
    }

    // MARK: - Description

    func testDescribeEveryMinute() throws {
        let p = try CronExpression.parse("* * * * *")
        let desc = CronExpression.describe(p)
        XCTAssertTrue(desc.contains("every minute"))
    }

    func testDescribeEveryFifteenMinutes() throws {
        let p = try CronExpression.parse("*/15 * * * *")
        let desc = CronExpression.describe(p)
        XCTAssertTrue(desc.contains("every 15 minutes"))
    }

    func testDescribeWeekdaysAtHour() throws {
        let p = try CronExpression.parse("0 9 * * 1-5")
        let desc = CronExpression.describe(p)
        XCTAssertTrue(desc.contains("9am"))
        XCTAssertTrue(desc.contains("weekdays"))
    }

    func testDescribeNoonAndMidnight() throws {
        let noon = try CronExpression.parse("0 12 * * *")
        XCTAssertTrue(CronExpression.describe(noon).contains("noon"))
        let midnight = try CronExpression.parse("0 0 * * *")
        XCTAssertTrue(CronExpression.describe(midnight).contains("midnight"))
    }

    // MARK: - Next fire times

    func testNextFiresForEveryMinute() throws {
        let p = try CronExpression.parse("* * * * *")
        // Start at 2026-01-01 00:00:30 UTC. First minute match is
        // 00:01:00, then 00:02:00, etc.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026, month: 1, day: 1, hour: 0, minute: 0, second: 30
        ))!
        let fires = CronExpression.nextFireTimes(p, after: start, count: 3, in: calendar.timeZone)
        XCTAssertEqual(fires.count, 3)
        // First fire should be at 00:01:00
        let comps0 = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fires[0])
        XCTAssertEqual(comps0.minute, 1)
        XCTAssertEqual(comps0.second, 0)
        // Third fire should be at 00:03:00
        let comps2 = calendar.dateComponents([.minute, .second], from: fires[2])
        XCTAssertEqual(comps2.minute, 3)
    }

    func testNextFiresForEveryFifteenMinutes() throws {
        let p = try CronExpression.parse("*/15 * * * *")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // Start at 10:07 — next match is 10:15.
        let start = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026, month: 6, day: 15, hour: 10, minute: 7, second: 0
        ))!
        let fires = CronExpression.nextFireTimes(p, after: start, count: 5, in: calendar.timeZone)
        let minutes = fires.map { calendar.component(.minute, from: $0) }
        XCTAssertEqual(minutes, [15, 30, 45, 0, 15])
    }

    func testNextFiresForDailyMidnight() throws {
        let p = try CronExpression.parse("@daily")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026, month: 3, day: 15, hour: 15, minute: 30, second: 0
        ))!
        let fires = CronExpression.nextFireTimes(p, after: start, count: 3, in: calendar.timeZone)
        XCTAssertEqual(fires.count, 3)
        for fire in fires {
            let comps = calendar.dateComponents([.hour, .minute], from: fire)
            XCTAssertEqual(comps.hour, 0)
            XCTAssertEqual(comps.minute, 0)
        }
        // Three consecutive days: 16, 17, 18
        let days = fires.map { calendar.component(.day, from: $0) }
        XCTAssertEqual(days, [16, 17, 18])
    }

    func testNextFiresForWeekdaysAt9AM() throws {
        let p = try CronExpression.parse("0 9 * * 1-5")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // Start Saturday 2026-03-14 at 08:00 UTC. Next fire
        // should be Monday 2026-03-16 at 09:00, then Tue, Wed…
        let start = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026, month: 3, day: 14, hour: 8, minute: 0, second: 0
        ))!
        let fires = CronExpression.nextFireTimes(p, after: start, count: 5, in: calendar.timeZone)
        XCTAssertEqual(fires.count, 5)
        for fire in fires {
            let weekday = calendar.component(.weekday, from: fire)
            // Calendar weekday: 1=Sun, 2=Mon, ..., 7=Sat.
            // Cron weekdays 1-5 maps to Mon-Fri.
            XCTAssertTrue((2...6).contains(weekday), "got weekday \(weekday) which is not Mon-Fri")
        }
    }

    func testNextFiresImpossibleExpressionEventuallyHitsCap() {
        // "Feb 30" never happens. We should get an empty array
        // back — our maxIterations cap prevents infinite loops.
        // (Not an error per se — the expression is syntactically
        // valid, just unreachable. View layer can surface this
        // as "no upcoming fire times".)
        let p = try! CronExpression.parseFiveFields("0 0 30 2 *", raw: "0 0 30 2 *")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026, month: 1, day: 1
        ))!
        let fires = CronExpression.nextFireTimes(p, after: start, count: 1, in: calendar.timeZone)
        XCTAssertEqual(fires.count, 0)
    }
}
