import XCTest
@testable import CloudTunnels
@testable import CloudTunnelsProxyHelper

final class CertInspectorTests: XCTestCase {

    // MARK: - Pure helpers (no LocalCA needed)

    func testIPStringIPv4() {
        let bytes: ArraySlice<UInt8> = [10, 0, 0, 1][...]
        XCTAssertEqual(CertInspector.ipString(from: bytes), "10.0.0.1")
    }

    func testIPStringIPv6() {
        let bytes: ArraySlice<UInt8> = [
            0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        ][...]
        let s = CertInspector.ipString(from: bytes)
        XCTAssertEqual(s, "2001:db8:0:0:0:0:0:1")
    }

    func testIPStringRejectsWeirdLength() {
        let bytes: ArraySlice<UInt8> = [1, 2, 3][...]
        XCTAssertNil(CertInspector.ipString(from: bytes))
    }

    func testSha256FingerprintFormat() {
        let bytes: [UInt8] = [0x00, 0xff, 0xab, 0xcd]
        let fp = CertInspector.sha256Fingerprint(of: bytes)
        // SHA-256 produces 32 bytes = 32 colon-separated pairs
        XCTAssertEqual(fp.split(separator: ":").count, 32)
        // Each pair is 2 uppercase hex digits
        for pair in fp.split(separator: ":") {
            XCTAssertEqual(pair.count, 2)
            for ch in pair {
                XCTAssertTrue("0123456789ABCDEF".contains(ch), "non-hex char: \(ch)")
            }
        }
    }

    func testSha256FingerprintEmpty() {
        XCTAssertEqual(CertInspector.sha256Fingerprint(of: []), "")
    }

    func testInspectRejectsNonPEM() {
        XCTAssertThrowsError(try CertInspector.inspect(pem: "not a pem")) { error in
            guard case CertInspector.InspectError.noPEMBlock = error else {
                return XCTFail("expected noPEMBlock, got \(error)")
            }
        }
    }

    func testInspectRejectsCorruptedPEM() {
        let bogus = """
        -----BEGIN CERTIFICATE-----
        AAAAAAAAAAAA
        -----END CERTIFICATE-----
        """
        XCTAssertThrowsError(try CertInspector.inspect(pem: bogus)) { error in
            guard case CertInspector.InspectError.parseFailed = error else {
                return XCTFail("expected parseFailed, got \(error)")
            }
        }
    }

    // MARK: - End-to-end with a real cert from LocalCA

    /// LocalCA (from the helper module) is the same actor we use in
    /// production to mint per-host leaves. We use it here to generate
    /// a real, valid X.509 cert into a tmpdir, then read its PEM and
    /// feed it to the inspector. Verifies the full parse path against
    /// real-world bytes, not synthetic fixtures.
    func testInspectRealLeafCertFromLocalCA() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cert-inspector-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let ca = try LocalCA.loadOrCreate(in: tmp)
        let leaf = try await ca.issueLeaf(for: "vpce-host.example.com")

        let inspected = try CertInspector.inspect(pem: leaf.certificatePEM)

        XCTAssertEqual(inspected.subjectCN, "vpce-host.example.com")
        XCTAssertTrue(inspected.sanDNS.contains("vpce-host.example.com"),
                      "SAN missing the leaf hostname; got \(inspected.sanDNS)")
        XCTAssertEqual(inspected.issuerCN, LocalCA.commonName)
        XCTAssertFalse(inspected.isExpired)
        XCTAssertGreaterThan(inspected.daysUntilExpiry, 300, "fresh leaf should be valid for ~365 days")
        XCTAssertFalse(inspected.sha256Fingerprint.isEmpty)
        XCTAssertEqual(inspected.sha256Fingerprint.split(separator: ":").count, 32)
    }

    func testInspectRealRootCAFromLocalCA() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cert-inspector-root-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let ca = try LocalCA.loadOrCreate(in: tmp)
        let rootPEM = await ca.rootCertificatePEM()

        let inspected = try CertInspector.inspect(pem: rootPEM)

        // Root is self-signed, so subject CN == issuer CN
        XCTAssertEqual(inspected.subjectCN, LocalCA.commonName)
        XCTAssertEqual(inspected.issuerCN, LocalCA.commonName)
        XCTAssertFalse(inspected.isExpired)
        XCTAssertGreaterThan(inspected.daysUntilExpiry, 365 * 5, "10-year root should have years left")
    }

    // MARK: - Extensions: KeyUsage / ExtendedKeyUsage / BasicConstraints / PEM

    /// LocalCA mints leaf certs with digitalSignature+keyEncipherment
    /// key usage and serverAuth EKU (see LocalCA.generateLeaf). The
    /// CertInspector extensions should surface all three.
    func testInspectLeafExtensions() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cert-inspector-exts-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let ca = try LocalCA.loadOrCreate(in: tmp)
        let leaf = try await ca.issueLeaf(for: "exts-test.example.com")

        let inspected = try CertInspector.inspect(pem: leaf.certificatePEM)

        XCTAssertTrue(inspected.keyUsages.contains("Digital Signature"),
                      "leaf KU should include digitalSignature; got \(inspected.keyUsages)")
        XCTAssertTrue(inspected.keyUsages.contains("Key Encipherment"),
                      "leaf KU should include keyEncipherment; got \(inspected.keyUsages)")
        XCTAssertFalse(inspected.keyUsages.contains("Certificate Sign"),
                       "leaf should not have keyCertSign")

        XCTAssertTrue(inspected.extendedKeyUsages.contains("serverAuth"),
                      "leaf EKU should include serverAuth; got \(inspected.extendedKeyUsages)")

        XCTAssertEqual(inspected.basicConstraints, "CA=FALSE")
    }

    /// Root CA has CA=TRUE with maxPathLength=1 plus keyCertSign /
    /// cRLSign key usage (see LocalCA.generateRoot).
    func testInspectRootExtensions() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cert-inspector-root-exts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let ca = try LocalCA.loadOrCreate(in: tmp)
        let rootPEM = await ca.rootCertificatePEM()

        let inspected = try CertInspector.inspect(pem: rootPEM)

        XCTAssertTrue(inspected.keyUsages.contains("Certificate Sign"),
                      "root KU should include keyCertSign; got \(inspected.keyUsages)")
        XCTAssertTrue(inspected.keyUsages.contains("CRL Sign"),
                      "root KU should include cRLSign; got \(inspected.keyUsages)")

        XCTAssertEqual(inspected.basicConstraints, "CA=TRUE, maxPathLength=1")
        // Root has no EKU extension.
        XCTAssertTrue(inspected.extendedKeyUsages.isEmpty,
                      "root should have no EKU; got \(inspected.extendedKeyUsages)")
    }

    /// The PEM round-trips: inspect() reads the LocalCA leaf PEM
    /// and surfaces a non-nil `pem` field that, when re-inspected,
    /// parses back to the same subject/issuer/serial. This proves
    /// both the serializeAsPEM path and that the stored PEM is
    /// self-consistent.
    func testInspectLeafPEMRoundTrips() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cert-inspector-pem-roundtrip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let ca = try LocalCA.loadOrCreate(in: tmp)
        let leaf = try await ca.issueLeaf(for: "roundtrip.example.com")

        let first = try CertInspector.inspect(pem: leaf.certificatePEM)
        guard let surfaced = first.pem else {
            return XCTFail("expected non-nil pem on inspected cert")
        }
        XCTAssertTrue(surfaced.contains("-----BEGIN CERTIFICATE-----"))
        XCTAssertTrue(surfaced.contains("-----END CERTIFICATE-----"))

        let second = try CertInspector.inspect(pem: surfaced)
        XCTAssertEqual(first.subjectCN, second.subjectCN)
        XCTAssertEqual(first.issuerCN, second.issuerCN)
        XCTAssertEqual(first.serialNumberHex, second.serialNumberHex)
        XCTAssertEqual(first.sha256Fingerprint, second.sha256Fingerprint)
    }
}
