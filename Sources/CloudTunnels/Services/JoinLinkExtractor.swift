import Foundation

/// Scans a calendar event's free-form fields (location, notes, url)
/// for a meeting join URL — Zoom, Google Meet, Microsoft Teams, or
/// Webex. Pure logic, no EventKit dependency, so it's trivially
/// unit-testable with fabricated strings.
///
/// **Priority order:** Zoom > Google Meet > Teams > Webex. This
/// matches how humans copy links into event notes — if there's a
/// real Zoom URL buried in the notes, it beats a generic Teams
/// fallback that the calendar server may have auto-added.
enum JoinLinkExtractor {

    /// Look through `location`, `notes`, and `url` (in that order)
    /// for the highest-priority meeting link. Returns the first
    /// match found, not all matches.
    ///
    /// The search is resilient: it matches anywhere inside the
    /// haystack strings, not just at the start, so a notes body
    /// like "Dial 555 or join https://zoom.us/j/123456789 from
    /// browser" still returns a clean URL.
    static func extract(location: String?, notes: String?, url: URL?) -> URL? {
        let haystacks = [location, notes, url?.absoluteString]
            .compactMap { $0 }
            .filter { !$0.isEmpty }

        guard !haystacks.isEmpty else { return nil }

        // Match each pattern across every haystack in priority order.
        // The first hit wins.
        for pattern in priorityPatterns {
            for haystack in haystacks {
                if let match = firstMatch(pattern: pattern, in: haystack),
                   let u = URL(string: match) {
                    return u
                }
            }
        }

        // No branded meeting service matched. As a last resort, if
        // `url` itself is a plausible https URL, hand it back — some
        // calendar servers (Google, Exchange) populate event.url
        // with the meeting link directly.
        if let u = url, u.scheme == "https" || u.scheme == "http" {
            return u
        }

        return nil
    }

    // MARK: - Patterns (exposed for unit testing)

    /// Covers standard Zoom meeting URLs (`zoom.us/j/<meeting-id>`)
    /// including vanity subdomains (`acme.zoom.us`) and the optional
    /// `?pwd=` query string.
    static let zoomMeetingPattern = #"https://[a-zA-Z0-9-]*\.?zoom\.us/j/[0-9]+(?:\?pwd=[a-zA-Z0-9._-]+)?"#

    /// Zoom personal meeting rooms use `/my/<handle>` instead of `/j/`.
    static let zoomPersonalPattern = #"https://[a-zA-Z0-9-]*\.?zoom\.us/my/[a-zA-Z0-9._-]+"#

    /// Google Meet links are `meet.google.com/xxx-yyyy-zzz`.
    static let meetPattern = #"https://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}"#

    /// Microsoft Teams join URLs. Opaque query string; we don't try
    /// to validate it, just capture until whitespace or a closing
    /// bracket.
    static let teamsPattern = #"https://teams\.microsoft\.com/l/meetup-join/[^\s<>"']+"#

    /// Webex meeting URLs. Similar shape to Teams — vanity subdomain
    /// plus an opaque path.
    static let webexPattern = #"https://[a-zA-Z0-9-]+\.webex\.com/[^\s<>"']+"#

    /// Priority order the extractor walks. Exposed so tests can
    /// assert the ordering if it's ever changed.
    static let priorityPatterns: [String] = [
        zoomMeetingPattern,
        zoomPersonalPattern,
        meetPattern,
        teamsPattern,
        webexPattern,
    ]

    // MARK: - Helpers

    /// Run a single NSRegularExpression pattern against a string and
    /// return the first full match. Returns nil on malformed regex
    /// (should not happen — our patterns are static) or no match.
    static func firstMatch(pattern: String, in haystack: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let range = NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
        guard let match = regex.firstMatch(in: haystack, options: [], range: range),
              let matchRange = Range(match.range, in: haystack) else {
            return nil
        }
        return String(haystack[matchRange])
    }
}
