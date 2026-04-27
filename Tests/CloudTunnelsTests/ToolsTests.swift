import XCTest
import CryptoKit
@testable import CloudTunnels

final class JWTParserTests: XCTestCase {
    // Standard sample JWT from jwt.io
    private let sampleJWT = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"

    func testParsesStandardJWT() throws {
        let parsed = try JWTParser.parse(sampleJWT)
        XCTAssertTrue(parsed.headerJSON.contains("\"alg\""))
        XCTAssertTrue(parsed.headerJSON.contains("HS256"))
        XCTAssertTrue(parsed.payloadJSON.contains("John Doe"))
        XCTAssertTrue(parsed.payloadJSON.contains("1234567890"))
        XCTAssertNotNil(parsed.issuedAt)
        XCTAssertNil(parsed.expiry)
        XCTAssertFalse(parsed.isExpired)
    }

    func testWrongSegmentCountThrows() {
        XCTAssertThrowsError(try JWTParser.parse("only.two"))
        XCTAssertThrowsError(try JWTParser.parse("garbage"))
    }

    func testExpiredTokenIsFlagged() throws {
        // Build a JWT with exp in the past
        let header = #"{"alg":"none","typ":"JWT"}"#
        let payload = #"{"sub":"x","exp":100}"#
        let token = base64url(header) + "." + base64url(payload) + ".sig"
        let parsed = try JWTParser.parse(token)
        XCTAssertNotNil(parsed.expiry)
        XCTAssertTrue(parsed.isExpired)
    }

    private func base64url(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

final class HashGeneratorTests: XCTestCase {
    // Standard known vectors for "abc"
    func testKnownVectorsForABC() {
        let data = Data("abc".utf8)
        XCTAssertEqual(
            Insecure.MD5.hash(data: data).hex,
            "900150983cd24fb0d6963f7d28e17f72"
        )
        XCTAssertEqual(
            Insecure.SHA1.hash(data: data).hex,
            "a9993e364706816aba3e25717850c26c9cd0d89d"
        )
        XCTAssertEqual(
            SHA256.hash(data: data).hex,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            SHA512.hash(data: data).hex,
            "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"
        )
    }
}

final class Base64Tests: XCTestCase {
    func testRoundTrip() {
        let plain = "Hello, World!"
        let encoded = Data(plain.utf8).base64EncodedString()
        XCTAssertEqual(encoded, "SGVsbG8sIFdvcmxkIQ==")
        let decoded = String(data: Data(base64Encoded: encoded)!, encoding: .utf8)
        XCTAssertEqual(decoded, plain)
    }
}

final class PortLookupParserTests: XCTestCase {
    func testParseSingleListener() {
        // Sample lsof -F pcLn output
        let sample = """
        p12345
        cnginx
        Lroot
        n*:8080
        """
        let parsed = PortLookup.parseLsofF(sample)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].pid, 12345)
        XCTAssertEqual(parsed[0].processName, "nginx")
        XCTAssertEqual(parsed[0].user, "root")
    }

    func testParseMultipleAndDedups() {
        let sample = """
        p100
        cssh
        Luser1
        n*:22
        p100
        cssh
        Luser1
        n[::1]:22
        p200
        cnode
        Luser2
        n127.0.0.1:3000
        """
        let parsed = PortLookup.parseLsofF(sample)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed.map(\.pid).sorted(), [100, 200])
    }

    func testEmptyOutput() {
        XCTAssertTrue(PortLookup.parseLsofF("").isEmpty)
    }
}

final class KubectlContextParserTests: XCTestCase {
    func testParsesNamesFromOutput() {
        let output = """
        prod-cluster
        staging-cluster
        dev-cluster

        """
        let names = KubectlContext.parseContextNames(output)
        XCTAssertEqual(names, ["prod-cluster", "staging-cluster", "dev-cluster"])
    }

    func testEmptyOutput() {
        XCTAssertTrue(KubectlContext.parseContextNames("").isEmpty)
    }

    // MARK: - parseContextClusterRows

    func testParsesContextsForExactClusterMatch() {
        let raw = """
        prod-admin\tgke_my-project_us-central1_prod-cluster
        staging-admin\tgke_my-project_us-central1_staging-cluster
        prod-readonly\tgke_my-project_us-central1_prod-cluster
        """
        let matches = KubectlContext.parseContextClusterRows(
            raw,
            matching: "gke_my-project_us-central1_prod-cluster"
        )
        XCTAssertEqual(matches, ["prod-admin", "prod-readonly"])
    }

    func testReturnsEmptyWhenClusterNotReferenced() {
        let raw = """
        prod-admin\tgke_proj_us_prod
        staging-admin\tgke_proj_us_staging
        """
        let matches = KubectlContext.parseContextClusterRows(raw, matching: "no-such-cluster")
        XCTAssertEqual(matches, [])
    }

    func testHandlesMalformedRowsGracefully() {
        // Lines without a tab separator should be silently skipped
        // rather than crashing or returning garbage.
        let raw = """
        prod-admin\tgke_proj_us_prod
        not-a-real-row
        \t
        staging-admin\tgke_proj_us_staging
        """
        let matches = KubectlContext.parseContextClusterRows(raw, matching: "gke_proj_us_prod")
        XCTAssertEqual(matches, ["prod-admin"])
    }

    func testTrimsWhitespaceFromColumnValues() {
        // jsonpath output sometimes has trailing whitespace; the
        // parser should match anyway.
        let raw = "  prod-admin  \t  gke_proj_us_prod  "
        let matches = KubectlContext.parseContextClusterRows(raw, matching: "gke_proj_us_prod")
        XCTAssertEqual(matches, ["prod-admin"])
    }
}

final class TimestampConversionTests: XCTestCase {
    func testEpochZeroIsUnixEpoch() {
        let date = Date(timeIntervalSince1970: 0)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        XCTAssertEqual(formatter.string(from: date), "1970-01-01T00:00:00Z")
    }

    func testKnownEpoch() {
        let date = Date(timeIntervalSince1970: 1700000000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        XCTAssertEqual(formatter.string(from: date), "2023-11-14T22:13:20Z")
    }
}
