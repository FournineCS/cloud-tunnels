import XCTest
@testable import CloudTunnels

/// Covers the pure meeting-reminder dispatch logic — which (event,
/// lead) pairs are "due" at a given `now`, and the text helpers on
/// `MeetingAlerter` that format the toast / notification strings.
/// No EventKit, no ToastManager, no notification center.
final class MeetingAlerterTests: XCTestCase {

    // MARK: - dueAlerts: firing windows

    func testFivesMinuteAlertFiresInFiveMinuteWindow() {
        // Event starts in 4:30 (270 sec). Should fire the 5-min
        // alert — minutesUntilStart = 4.5, which sits inside (4, 5].
        let event = makeEvent(id: "e1", startOffset: 270)
        let result = CalendarManager.dueAlerts(
            events: [event],
            now: Date(),
            leadMinutes: [5, 1],
            alreadyFired: []
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.0.id, "e1")
        XCTAssertEqual(result.first?.1, 5)
    }

    func testOneMinuteAlertFiresInOneMinuteWindow() {
        // Event in 30 sec (0.5 min). minutesUntilStart = 0.5,
        // which sits inside (0, 1]. Should fire the 1-min alert.
        let event = makeEvent(id: "e1", startOffset: 30)
        let result = CalendarManager.dueAlerts(
            events: [event],
            now: Date(),
            leadMinutes: [5, 1],
            alreadyFired: []
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.1, 1)
    }

    func testDoesNotFireBetweenWindows() {
        // Event in 3 min. minutesUntilStart = 3, sits in (2, 3]
        // which isn't any of the configured lead windows.
        let event = makeEvent(id: "e1", startOffset: 3 * 60)
        let result = CalendarManager.dueAlerts(
            events: [event],
            now: Date(),
            leadMinutes: [5, 1],
            alreadyFired: []
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testDoesNotFirePastEvent() {
        let event = makeEvent(id: "e1", startOffset: -60)
        let result = CalendarManager.dueAlerts(
            events: [event],
            now: Date(),
            leadMinutes: [5, 1],
            alreadyFired: []
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testDoesNotFireAllDayEvent() {
        let event = makeEvent(id: "e1", startOffset: 4.5 * 60, isAllDay: true)
        let result = CalendarManager.dueAlerts(
            events: [event],
            now: Date(),
            leadMinutes: [5, 1],
            alreadyFired: []
        )
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - dueAlerts: dedupe

    func testAlreadyFiredAlertIsSkipped() {
        let event = makeEvent(id: "e1", startOffset: 4.5 * 60)
        let result = CalendarManager.dueAlerts(
            events: [event],
            now: Date(),
            leadMinutes: [5, 1],
            alreadyFired: ["e1:5"]
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testOneEventFiresOnlyHighestLeadInASingleTick() {
        // A contrived event where both the 5-min and 1-min windows
        // could conceivably overlap (shouldn't happen with sane
        // leads). The implementation breaks after the first match
        // per event to avoid double-dispatch.
        // Use leads [2, 1] with a 1.5-min offset so (1, 2] catches
        // it but (0, 1] wouldn't — only one firing expected.
        let event = makeEvent(id: "e1", startOffset: 1.5 * 60)
        let result = CalendarManager.dueAlerts(
            events: [event],
            now: Date(),
            leadMinutes: [2, 1],
            alreadyFired: []
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.1, 2)
    }

    // MARK: - dueAlerts: multiple events

    func testMultipleEventsAllFireSeparately() {
        let e1 = makeEvent(id: "e1", startOffset: 4.5 * 60)
        let e2 = makeEvent(id: "e2", startOffset: 0.5 * 60)
        let result = CalendarManager.dueAlerts(
            events: [e1, e2],
            now: Date(),
            leadMinutes: [5, 1],
            alreadyFired: []
        )
        XCTAssertEqual(result.count, 2)
        let ids = Set(result.map { $0.0.id })
        XCTAssertEqual(ids, Set(["e1", "e2"]))
    }

    func testEmptyLeadsYieldsNothing() {
        let event = makeEvent(id: "e1", startOffset: 4.5 * 60)
        let result = CalendarManager.dueAlerts(
            events: [event],
            now: Date(),
            leadMinutes: [],
            alreadyFired: []
        )
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - MeetingAlerter text helpers

    func testTitleTextForFiveMinuteLead() {
        let event = makeEvent(id: "e1", startOffset: 4.5 * 60, title: "Standup")
        XCTAssertEqual(
            MeetingAlerter.titleText(for: event, minutesBefore: 5),
            "Standup in 5 min"
        )
    }

    func testTitleTextForOneMinuteLeadSaysStartingNow() {
        let event = makeEvent(id: "e1", startOffset: 30, title: "Demo")
        XCTAssertEqual(
            MeetingAlerter.titleText(for: event, minutesBefore: 1),
            "Demo starting now"
        )
    }

    func testBodyTextIsCalendarTitle() {
        let event = makeEvent(
            id: "e1",
            startOffset: 30,
            title: "Demo",
            calendarTitle: "Work — Sampath"
        )
        XCTAssertEqual(MeetingAlerter.bodyText(for: event), "Work — Sampath")
    }

    // MARK: - Helpers

    /// Build an `Upcoming` fixture at `now + startOffset` seconds.
    /// Calendar color is a fixed neutral gray.
    private func makeEvent(
        id: String,
        startOffset: TimeInterval,
        isAllDay: Bool = false,
        title: String = "Test Meeting",
        calendarTitle: String = "Test Calendar"
    ) -> CalendarManager.Upcoming {
        let start = Date().addingTimeInterval(startOffset)
        let end = start.addingTimeInterval(30 * 60)
        return CalendarManager.Upcoming(
            id: id,
            title: title,
            start: start,
            end: end,
            isAllDay: isAllDay,
            calendarTitle: calendarTitle,
            calendarColorRGB: (0.5, 0.5, 0.5),
            location: nil,
            notes: nil,
            joinURL: nil,
            organizer: nil
        )
    }
}
