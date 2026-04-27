import XCTest
@testable import CloudTunnels

final class OneTimeSecretTests: XCTestCase {

    // MARK: - encodeFormBody

    func testEncodeFormBodyBasic() {
        let body = OneTimeSecret.encodeFormBody(secret: "hunter2", ttlSeconds: 3600)
        let str = String(data: body, encoding: .utf8)
        XCTAssertEqual(str, "secret=hunter2&ttl=3600")
    }

    func testEncodeFormBodyEscapesSpecialCharacters() {
        // & = + / # space all need to be percent-encoded so the
        // upstream form parser doesn't split the secret across
        // fields or strip characters.
        let body = OneTimeSecret.encodeFormBody(
            secret: "a&b=c+d/e#f g",
            ttlSeconds: 86400
        )
        let str = String(data: body, encoding: .utf8) ?? ""
        XCTAssertTrue(str.hasPrefix("secret="))
        XCTAssertTrue(str.hasSuffix("&ttl=86400"))
        // The secret portion should not contain any literal special
        // chars from the original input — they should all be %XX.
        let secretPortion = str.dropFirst("secret=".count)
            .prefix(while: { $0 != "&" })
        XCTAssertFalse(secretPortion.contains("&"))
        XCTAssertFalse(secretPortion.contains("="))
        XCTAssertFalse(secretPortion.contains("+"))
        XCTAssertFalse(secretPortion.contains("/"))
        XCTAssertFalse(secretPortion.contains("#"))
        XCTAssertFalse(secretPortion.contains(" "))
    }

    func testEncodeFormBodyHandlesUnicode() {
        let body = OneTimeSecret.encodeFormBody(secret: "p🔑word", ttlSeconds: 300)
        let str = String(data: body, encoding: .utf8) ?? ""
        // Emoji must be percent-encoded as multi-byte UTF-8 (%F0%9F%94%91)
        XCTAssertTrue(str.contains("%F0%9F%94%91"), "emoji should be percent-encoded; got: \(str)")
    }

    // MARK: - parseSecretKey

    func testParseSecretKeyHappyPath() throws {
        let json = #"""
        {
            "custid": "anon",
            "metadata_key": "abc123metadata",
            "secret_key": "abc123secret",
            "ttl": 3600,
            "passphrase_required": false
        }
        """#
        let key = try OneTimeSecret.parseSecretKey(from: Data(json.utf8))
        XCTAssertEqual(key, "abc123secret")
    }

    func testParseSecretKeyMissingFieldThrows() {
        let json = #"{"custid":"anon","metadata_key":"meta"}"#
        XCTAssertThrowsError(
            try OneTimeSecret.parseSecretKey(from: Data(json.utf8))
        ) { error in
            guard case OneTimeSecret.ShareError.malformed(let detail) = error else {
                return XCTFail("expected .malformed, got \(error)")
            }
            XCTAssertTrue(detail.contains("secret_key"))
        }
    }

    func testParseSecretKeyEmptyFieldThrows() {
        let json = #"{"secret_key":""}"#
        XCTAssertThrowsError(
            try OneTimeSecret.parseSecretKey(from: Data(json.utf8))
        ) { error in
            guard case OneTimeSecret.ShareError.malformed = error else {
                return XCTFail("expected .malformed, got \(error)")
            }
        }
    }

    func testParseSecretKeyNonJSONThrows() {
        let body = "not json at all"
        XCTAssertThrowsError(
            try OneTimeSecret.parseSecretKey(from: Data(body.utf8))
        ) { error in
            guard case OneTimeSecret.ShareError.malformed = error else {
                return XCTFail("expected .malformed, got \(error)")
            }
        }
    }

    func testParseSecretKeyArrayResponseThrows() {
        // Some APIs degrade to returning an array when something is
        // wrong; our parser should reject this cleanly rather than
        // crashing with a force-unwrap.
        let json = "[]"
        XCTAssertThrowsError(
            try OneTimeSecret.parseSecretKey(from: Data(json.utf8))
        ) { error in
            guard case OneTimeSecret.ShareError.malformed = error else {
                return XCTFail("expected .malformed, got \(error)")
            }
        }
    }

    // MARK: - buildShareURL

    func testBuildShareURLProducesExpectedFormat() throws {
        let url = try OneTimeSecret.buildShareURL(secretKey: "abc123XYZ")
        XCTAssertEqual(url.absoluteString, "https://onetimesecret.com/secret/abc123XYZ")
    }

    // MARK: - share() empty-secret guard

    func testShareEmptySecretThrowsBeforeNetworkCall() async {
        // Critical: we must catch this client-side, not let it hit
        // the network and surface a confusing upstream error.
        do {
            _ = try await OneTimeSecret.share("", ttl: .oneHour)
            XCTFail("expected emptySecret to throw")
        } catch OneTimeSecret.ShareError.emptySecret {
            // expected
        } catch {
            XCTFail("expected .emptySecret, got \(error)")
        }
    }

    // MARK: - TTL enum

    func testTTLDisplayNamesAreNonEmpty() {
        for ttl in OneTimeSecret.TTL.allCases {
            XCTAssertFalse(ttl.displayName.isEmpty, "TTL \(ttl) has empty display name")
        }
    }

    func testTTLValuesMatchExpectedSeconds() {
        XCTAssertEqual(OneTimeSecret.TTL.fiveMinutes.rawValue, 300)
        XCTAssertEqual(OneTimeSecret.TTL.oneHour.rawValue, 3600)
        XCTAssertEqual(OneTimeSecret.TTL.oneDay.rawValue, 86400)
        XCTAssertEqual(OneTimeSecret.TTL.oneWeek.rawValue, 604800)
    }
}
