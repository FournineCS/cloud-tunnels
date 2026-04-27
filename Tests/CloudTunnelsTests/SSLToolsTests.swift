import XCTest
@testable import CloudTunnels
@testable import CloudTunnelsProxyHelper

/// Covers the 4 SSL/TLS helper tools. Pure logic only — no network
/// calls to real hosts, no PKCS#12 round-trips. For SSLChecker we
/// only test the parseHostPort pure helper; the network path is
/// smoke-tested manually because it depends on an external host.
final class SSLToolsTests: XCTestCase {

    // MARK: - SSLCheckerView.parseHostPort

    func testParseHostWithoutPort() {
        let (h, p) = SSLCheckerView.parseHostPort("example.com")
        XCTAssertEqual(h, "example.com")
        XCTAssertEqual(p, 443)
    }

    func testParseHostWithPort() {
        let (h, p) = SSLCheckerView.parseHostPort("example.com:8443")
        XCTAssertEqual(h, "example.com")
        XCTAssertEqual(p, 8443)
    }

    func testParseHostStripsHttpsScheme() {
        let (h, p) = SSLCheckerView.parseHostPort("https://example.com:8443")
        XCTAssertEqual(h, "example.com")
        XCTAssertEqual(p, 8443)
    }

    func testParseHostStripsPath() {
        let (h, p) = SSLCheckerView.parseHostPort("https://example.com:8443/some/path")
        XCTAssertEqual(h, "example.com")
        XCTAssertEqual(p, 8443)
    }

    func testParseHostIPv6Literal() {
        let (h, p) = SSLCheckerView.parseHostPort("[::1]:8443")
        XCTAssertEqual(h, "::1")
        XCTAssertEqual(p, 8443)
    }

    func testParseHostIPv6LiteralWithoutPort() {
        let (h, p) = SSLCheckerView.parseHostPort("[2001:db8::1]")
        XCTAssertEqual(h, "2001:db8::1")
        XCTAssertEqual(p, 443)
    }

    // MARK: - CSRInspector (pure helpers + error paths)

    func testCSRInspectorRejectsNonPEM() {
        XCTAssertThrowsError(try CSRInspector.inspect(pem: "not a csr")) { error in
            guard case CSRInspector.InspectError.noPEMBlock = error else {
                return XCTFail("expected noPEMBlock, got \(error)")
            }
        }
    }

    func testCSRInspectorRejectsCertificateBlockAsCSR() {
        // A CERTIFICATE block is not a CERTIFICATE REQUEST — the
        // inspector should refuse to parse it.
        let certBlock = """
        -----BEGIN CERTIFICATE-----
        MIIB
        -----END CERTIFICATE-----
        """
        XCTAssertThrowsError(try CSRInspector.inspect(pem: certBlock)) { error in
            guard case CSRInspector.InspectError.noPEMBlock = error else {
                return XCTFail("expected noPEMBlock (wrong label), got \(error)")
            }
        }
    }

    func testCSRInspectorRejectsCorruptedCSR() {
        let bogus = """
        -----BEGIN CERTIFICATE REQUEST-----
        AAAAAAAAAAAA
        -----END CERTIFICATE REQUEST-----
        """
        XCTAssertThrowsError(try CSRInspector.inspect(pem: bogus)) { error in
            guard case CSRInspector.InspectError.parseFailed = error else {
                return XCTFail("expected parseFailed, got \(error)")
            }
        }
    }

    // MARK: - KeyMatcher (end-to-end with a real LocalCA-minted cert)

    func testKeyMatcherHappyPath() async throws {
        // Generate a real cert + key pair from LocalCA, then
        // verify the matcher reports .match.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("key-matcher-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let ca = try LocalCA.loadOrCreate(in: tmp)
        let leaf = try await ca.issueLeaf(for: "match-test.example.com")

        let result = try KeyMatcher.check(
            certPEM: leaf.certificatePEM,
            keyPEM: leaf.privateKeyPEM
        )
        guard case .match = result else {
            return XCTFail("expected .match, got \(result)")
        }
    }

    func testKeyMatcherDetectsMismatch() async throws {
        // Mint two separate leaves. Their cert and key crossed
        // over should be a clear mismatch.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("key-matcher-mismatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let ca = try LocalCA.loadOrCreate(in: tmp)
        let a = try await ca.issueLeaf(for: "a.example.com")
        let b = try await ca.issueLeaf(for: "b.example.com")

        let result = try KeyMatcher.check(
            certPEM: a.certificatePEM,
            keyPEM: b.privateKeyPEM
        )
        guard case .mismatch = result else {
            return XCTFail("expected .mismatch, got \(result)")
        }
    }

    func testKeyMatcherRejectsMissingCertBlock() {
        XCTAssertThrowsError(
            try KeyMatcher.check(certPEM: "nothing here", keyPEM: "-----BEGIN PRIVATE KEY-----")
        ) { error in
            guard case KeyMatcher.MatchError.certPEMMissing = error else {
                return XCTFail("expected certPEMMissing, got \(error)")
            }
        }
    }

    func testKeyMatcherRejectsMissingKeyBlock() {
        let cert = "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----"
        XCTAssertThrowsError(
            try KeyMatcher.check(certPEM: cert, keyPEM: "nothing here")
        ) { error in
            guard case KeyMatcher.MatchError.keyPEMMissing = error else {
                return XCTFail("expected keyPEMMissing, got \(error)")
            }
        }
    }

    // MARK: - SSLConverter

    func testPemToDerAndBackRoundTrip() throws {
        // Make up a tiny DER payload, PEM-wrap it, strip back to
        // DER, verify byte-for-byte.
        let originalDer = Data([0x30, 0x82, 0x01, 0x02, 0x03, 0x04, 0x05])
        let pem = SSLConverter.derToPem(originalDer, label: .certificate)
        XCTAssertTrue(pem.contains("-----BEGIN CERTIFICATE-----"))
        XCTAssertTrue(pem.contains("-----END CERTIFICATE-----"))

        let roundTripped = try SSLConverter.pemToDer(pem)
        XCTAssertEqual(roundTripped, originalDer)
    }

    func testPemToDerRejectsEmptyInput() {
        XCTAssertThrowsError(try SSLConverter.pemToDer("")) { error in
            guard case SSLConverter.ConvertError.emptyInput = error else {
                return XCTFail("expected emptyInput, got \(error)")
            }
        }
    }

    func testPemToDerRejectsMissingBanner() {
        XCTAssertThrowsError(try SSLConverter.pemToDer("just some base64 like: aGVsbG8=")) { error in
            guard case SSLConverter.ConvertError.notPEM = error else {
                return XCTFail("expected notPEM, got \(error)")
            }
        }
    }

    func testPemToDerIgnoresLabelMismatchIntentionally() throws {
        // The tool accepts any label — we don't enforce
        // "-----BEGIN CERTIFICATE-----" specifically. This lets
        // users convert keys, CSRs, anything ad-hoc.
        let pem = """
        -----BEGIN FOO-----
        aGVsbG8=
        -----END FOO-----
        """
        let der = try SSLConverter.pemToDer(pem)
        XCTAssertEqual(der, Data("hello".utf8))
    }

    func testDerToPemWrapsAt64Chars() {
        let der = Data(repeating: 0x41, count: 120) // 120 bytes of 'A'
        let pem = SSLConverter.derToPem(der, label: .certificate)
        let contentLines = pem.split(whereSeparator: { $0.isNewline })
            .filter { !$0.contains("-----") }
        // Every line except possibly the last should be exactly 64 chars
        for (i, line) in contentLines.enumerated() where i < contentLines.count - 1 {
            XCTAssertEqual(line.count, 64, "line \(i) has \(line.count) chars, expected 64")
        }
    }

    func testParseDerInputAcceptsHexPairs() throws {
        let hex = "30 82 00 01 AB CD"
        let data = try SSLConverter.parseDerInput(hex)
        XCTAssertEqual(data, Data([0x30, 0x82, 0x00, 0x01, 0xAB, 0xCD]))
    }

    func testParseDerInputAcceptsHexWithColons() throws {
        let hex = "30:82:00:01:AB:CD"
        let data = try SSLConverter.parseDerInput(hex)
        XCTAssertEqual(data, Data([0x30, 0x82, 0x00, 0x01, 0xAB, 0xCD]))
    }

    func testParseDerInputAcceptsBase64() throws {
        let b64 = Data([0x30, 0x82, 0x00, 0x01]).base64EncodedString()
        let data = try SSLConverter.parseDerInput(b64)
        XCTAssertEqual(data, Data([0x30, 0x82, 0x00, 0x01]))
    }

    func testParseDerInputRejectsGibberish() {
        XCTAssertThrowsError(try SSLConverter.parseDerInput("!!!!")) { error in
            guard case SSLConverter.ConvertError.invalidBase64 = error else {
                return XCTFail("expected invalidBase64, got \(error)")
            }
        }
    }

    func testFormatDerAsHex16PerLine() {
        let data = Data(repeating: 0xAB, count: 40)
        let hex = SSLConverter.formatDerAsHex(data)
        let lines = hex.split(whereSeparator: { $0.isNewline })
        // 40 bytes / 16 per line = 3 lines (16 + 16 + 8)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].split(separator: ":").count, 16)
        XCTAssertEqual(lines[2].split(separator: ":").count, 8)
    }
}
