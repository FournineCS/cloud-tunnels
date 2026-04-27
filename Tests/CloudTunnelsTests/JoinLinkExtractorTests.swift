import XCTest
@testable import CloudTunnels

/// Covers the pure meeting-link scanner used by CalendarManager to
/// surface a [Join] button on upcoming events. Tests exercise the
/// real regex patterns against representative strings — no EventKit,
/// no network.
final class JoinLinkExtractorTests: XCTestCase {

    // MARK: - Positive matches by service

    func testExtractsZoomMeetingFromLocation() {
        let url = JoinLinkExtractor.extract(
            location: "https://zoom.us/j/1234567890",
            notes: nil,
            url: nil
        )
        XCTAssertEqual(url?.absoluteString, "https://zoom.us/j/1234567890")
    }

    func testExtractsVanityZoomFromLocation() {
        let url = JoinLinkExtractor.extract(
            location: "https://acme.zoom.us/j/987654321?pwd=AbCdEf.1_2",
            notes: nil,
            url: nil
        )
        XCTAssertEqual(url?.absoluteString, "https://acme.zoom.us/j/987654321?pwd=AbCdEf.1_2")
    }

    func testExtractsZoomPersonalRoomFromNotes() {
        let url = JoinLinkExtractor.extract(
            location: nil,
            notes: "Join me any time: https://acme.zoom.us/my/sampath",
            url: nil
        )
        XCTAssertEqual(url?.absoluteString, "https://acme.zoom.us/my/sampath")
    }

    func testExtractsGoogleMeetFromNotes() {
        let url = JoinLinkExtractor.extract(
            location: nil,
            notes: "Standup link: https://meet.google.com/abc-defg-hij please join 5 min early",
            url: nil
        )
        XCTAssertEqual(url?.absoluteString, "https://meet.google.com/abc-defg-hij")
    }

    func testExtractsTeamsLink() {
        let teams = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%22Tid%22%3a%22abc%22%7d"
        let url = JoinLinkExtractor.extract(
            location: teams,
            notes: nil,
            url: nil
        )
        XCTAssertEqual(url?.absoluteString, teams)
    }

    func testExtractsWebexLink() {
        let webex = "https://acme.webex.com/acme/j.php?MTID=abc123"
        let url = JoinLinkExtractor.extract(
            location: nil,
            notes: "Join: \(webex)",
            url: nil
        )
        XCTAssertEqual(url?.absoluteString, webex)
    }

    // MARK: - Event URL fallback

    func testFallsBackToEventURLWhenNoPatternMatches() {
        let fallback = URL(string: "https://example.com/event/42")!
        let url = JoinLinkExtractor.extract(
            location: "Conf Room B",
            notes: "Bring the design docs",
            url: fallback
        )
        XCTAssertEqual(url, fallback)
    }

    func testIgnoresNonHTTPSchemeEventURL() {
        // Some calendar servers stuff a `ms-outlook://` or `tel://`
        // scheme in event.url; we shouldn't surface those as a
        // browser-clickable Join button.
        let weird = URL(string: "tel:5551234567")!
        let url = JoinLinkExtractor.extract(
            location: "Conf Room B",
            notes: "Bring the design docs",
            url: weird
        )
        XCTAssertNil(url)
    }

    // MARK: - Priority ordering

    func testZoomInNotesBeatsTeamsInLocation() {
        let url = JoinLinkExtractor.extract(
            location: "https://teams.microsoft.com/l/meetup-join/foo",
            notes: "Actually let's use Zoom: https://zoom.us/j/5555555555",
            url: nil
        )
        // Zoom is higher priority than Teams, so even though Teams
        // is in the higher-priority field (location), Zoom wins.
        XCTAssertEqual(url?.absoluteString, "https://zoom.us/j/5555555555")
    }

    func testMeetInNotesBeatsTeamsInLocation() {
        let url = JoinLinkExtractor.extract(
            location: "https://teams.microsoft.com/l/meetup-join/foo",
            notes: "Or join via Meet: https://meet.google.com/aaa-bbbb-ccc",
            url: nil
        )
        XCTAssertEqual(url?.absoluteString, "https://meet.google.com/aaa-bbbb-ccc")
    }

    // MARK: - Negative cases

    func testNoMatchEverywhere() {
        let url = JoinLinkExtractor.extract(
            location: "Conference Room B",
            notes: "In-person only. No dial-in.",
            url: nil
        )
        XCTAssertNil(url)
    }

    func testEmptyStringsReturnNil() {
        let url = JoinLinkExtractor.extract(location: "", notes: "", url: nil)
        XCTAssertNil(url)
    }

    func testAllNilReturnsNil() {
        XCTAssertNil(JoinLinkExtractor.extract(location: nil, notes: nil, url: nil))
    }

    // MARK: - Direct pattern tests

    func testFirstMatchHelper() {
        let hit = JoinLinkExtractor.firstMatch(
            pattern: JoinLinkExtractor.zoomMeetingPattern,
            in: "blah https://zoom.us/j/42 blah"
        )
        XCTAssertEqual(hit, "https://zoom.us/j/42")
    }

    func testFirstMatchReturnsNilOnNoMatch() {
        let hit = JoinLinkExtractor.firstMatch(
            pattern: JoinLinkExtractor.meetPattern,
            in: "nothing meet-y here"
        )
        XCTAssertNil(hit)
    }
}
