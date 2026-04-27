import XCTest
@testable import TunnelCore

/// Covers Codable round-trip and migration shapes for
/// CalendarPreferences and its host Preferences struct.
final class CalendarPreferencesTests: XCTestCase {

    // MARK: - Defaults

    func testDefaultPreferences() {
        let p = CalendarPreferences.default
        XCTAssertTrue(p.enabled)
        XCTAssertEqual(p.lookaheadDays, 2)
        XCTAssertEqual(p.refreshIntervalMinutes, 5)
        XCTAssertEqual(p.reminderLeadMinutes, [30, 10, 1])
        XCTAssertTrue(p.enabledCalendarIdentifiers.isEmpty)
        XCTAssertFalse(p.showAllDayEvents)
    }

    // MARK: - Codable round-trip

    func testRoundTripWithDefaults() throws {
        let original = CalendarPreferences.default
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CalendarPreferences.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testRoundTripWithCustomValues() throws {
        let original = CalendarPreferences(
            enabled: false,
            lookaheadDays: 7,
            refreshIntervalMinutes: 10,
            reminderLeadMinutes: [15, 5, 1],
            enabledCalendarIdentifiers: ["ABC-123", "DEF-456"],
            showAllDayEvents: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CalendarPreferences.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    // MARK: - Normalization

    func testLeadMinutesSortedDescAndDeduped() {
        let p = CalendarPreferences(reminderLeadMinutes: [1, 5, 1, 10, 5])
        XCTAssertEqual(p.reminderLeadMinutes, [10, 5, 1])
    }

    func testNonPositiveLeadMinutesDropped() {
        let p = CalendarPreferences(reminderLeadMinutes: [5, 0, -1, 1])
        XCTAssertEqual(p.reminderLeadMinutes, [5, 1])
    }

    func testEmptyLeadsAllowed() {
        // Empty leads array disables reminders entirely — legitimate
        // user choice (they just want the top banner).
        let p = CalendarPreferences(reminderLeadMinutes: [])
        XCTAssertEqual(p.reminderLeadMinutes, [])
    }

    // MARK: - Back-compat in Preferences

    func testOldPreferencesJSONWithoutCalendarKey() throws {
        // An existing config.json from before this feature shipped.
        // The decode path must default `calendar` to `.default`.
        let oldJSON = """
        {
            "auto_reconnect": true,
            "auth_check_interval_min": 30,
            "terminal_app": "terminal",
            "http_client": "system_browser"
        }
        """.data(using: .utf8)!

        // Preferences's CodingKeys uses camelCase-to-snake_case via
        // the explicit map, but TerminalApp / HTTPClient use their
        // raw values. Be explicit about what the test expects.
        let decoded = try JSONDecoder().decode(Preferences.self, from: oldJSON)
        XCTAssertEqual(decoded.calendar, .default)
        XCTAssertTrue(decoded.autoReconnect)
    }

    func testPreferencesJSONWithCalendarKey() throws {
        let json = """
        {
            "auto_reconnect": true,
            "auth_check_interval_min": 30,
            "terminal_app": "terminal",
            "http_client": "system_browser",
            "calendar": {
                "enabled": false,
                "lookahead_days": 7,
                "refresh_interval_minutes": 15,
                "reminder_lead_minutes": [30, 10],
                "enabled_calendar_identifiers": [],
                "show_all_day_events": true
            }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(Preferences.self, from: json)
        XCTAssertFalse(decoded.calendar.enabled)
        XCTAssertEqual(decoded.calendar.lookaheadDays, 7)
        XCTAssertEqual(decoded.calendar.refreshIntervalMinutes, 15)
        XCTAssertEqual(decoded.calendar.reminderLeadMinutes, [30, 10])
        XCTAssertTrue(decoded.calendar.showAllDayEvents)
    }
}
