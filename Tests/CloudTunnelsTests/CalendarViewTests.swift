import XCTest
@testable import CloudTunnels

/// Covers the Tools-registry wiring for the Calendar tool and the
/// pure formatting helpers on `UpcomingMeetingBanner` and
/// `CalendarView`. The visual panels themselves are SwiftUI views
/// exercised manually; these tests just lock in the string-building
/// logic so a regression shows up in `swift test`.
final class CalendarViewTests: XCTestCase {

    // MARK: - Registry

    func testCalendarToolRegistered() {
        let tool = ToolRegistry.tool(id: "calendar")
        XCTAssertNotNil(tool)
        XCTAssertEqual(tool?.name, "Calendar")
        XCTAssertEqual(tool?.category, .productivity)
    }

    func testCalendarShowsUnderProductivity() {
        let productivityTools = ToolRegistry.byCategory
            .first { $0.0 == .productivity }?.1
        XCTAssertNotNil(productivityTools)
        XCTAssertTrue(
            productivityTools?.contains { $0.id == "calendar" } == true,
            "Calendar tool missing from Productivity category"
        )
    }

    // MARK: - UpcomingMeetingBanner.countdownText

    func testCountdownNowWhenStartIsPast() {
        let now = Date()
        let past = now.addingTimeInterval(-10)
        XCTAssertEqual(UpcomingMeetingBanner.countdownText(from: now, to: past), "now")
    }

    func testCountdownNowWhenStartIsExactlyNow() {
        let now = Date()
        XCTAssertEqual(UpcomingMeetingBanner.countdownText(from: now, to: now), "now")
    }

    func testCountdownSubMinuteReportsSeconds() {
        let now = Date()
        let soon = now.addingTimeInterval(30)
        let text = UpcomingMeetingBanner.countdownText(from: now, to: soon)
        // Floating-point drift means 29 or 30 are both acceptable.
        XCTAssertTrue(text == "in 30 sec" || text == "in 29 sec", "got: \(text)")
    }

    func testCountdownMinutes() {
        let now = Date()
        let fourMinOut = now.addingTimeInterval(4 * 60 + 30)
        // 4:30 rounds down to 4 minutes integer-divided.
        XCTAssertEqual(
            UpcomingMeetingBanner.countdownText(from: now, to: fourMinOut),
            "in 4 min"
        )
    }

    func testCountdownOneHour() {
        let now = Date()
        let oneHour = now.addingTimeInterval(60 * 60)
        XCTAssertEqual(
            UpcomingMeetingBanner.countdownText(from: now, to: oneHour),
            "in 1 hour"
        )
    }

    func testCountdownMultipleHours() {
        let now = Date()
        let fourHours = now.addingTimeInterval(4 * 60 * 60)
        XCTAssertEqual(
            UpcomingMeetingBanner.countdownText(from: now, to: fourHours),
            "in 4 hours"
        )
    }

    func testCountdownOneDay() {
        let now = Date()
        let oneDay = now.addingTimeInterval(24 * 60 * 60)
        XCTAssertEqual(
            UpcomingMeetingBanner.countdownText(from: now, to: oneDay),
            "in 1 day"
        )
    }

    func testCountdownMultipleDays() {
        let now = Date()
        let threeDays = now.addingTimeInterval(3 * 24 * 60 * 60)
        XCTAssertEqual(
            UpcomingMeetingBanner.countdownText(from: now, to: threeDays),
            "in 3 days"
        )
    }

    // MARK: - CalendarView.durationText

    func testDurationZero() {
        let d = Date()
        XCTAssertEqual(CalendarView.durationText(start: d, end: d), "0 min")
    }

    func testDurationMinutesOnly() {
        let start = Date()
        let end = start.addingTimeInterval(30 * 60)
        XCTAssertEqual(CalendarView.durationText(start: start, end: end), "30 min")
    }

    func testDurationExactHour() {
        let start = Date()
        let end = start.addingTimeInterval(60 * 60)
        XCTAssertEqual(CalendarView.durationText(start: start, end: end), "1h")
    }

    func testDurationHoursAndMinutes() {
        let start = Date()
        let end = start.addingTimeInterval(90 * 60)
        XCTAssertEqual(CalendarView.durationText(start: start, end: end), "1h 30m")
    }
}
