import Crypto
import Foundation
import X509
import XCTest
@testable import CloudTunnelsProxyHelper

/// Exercises the in-process CA replacement for mkcert: generate a root,
/// issue per-hostname leaves, persist + reload from disk, verify chain
/// metadata. Anything that requires the System Keychain or root privileges
/// is out of scope here — those live in the manual verification steps.
final class LocalCATests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LocalCATests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - Root creation + persistence

    func testLoadOrCreateGeneratesRootOnFirstRun() async throws {
        let ca = try LocalCA.loadOrCreate(in: workDir)
        let pem = await ca.rootCertificatePEM()
        XCTAssertTrue(pem.contains("BEGIN CERTIFICATE"))
        XCTAssertTrue(pem.contains("END CERTIFICATE"))

        let certPath = workDir.appendingPathComponent("ca/ca.pem")
        let keyPath = workDir.appendingPathComponent("ca/ca.key")
        XCTAssertTrue(FileManager.default.fileExists(atPath: certPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keyPath.path))
    }

    func testLoadOrCreateReusesExistingRootOnSecondCall() async throws {
        let first = try LocalCA.loadOrCreate(in: workDir)
        let firstPEM = await first.rootCertificatePEM()

        let second = try LocalCA.loadOrCreate(in: workDir)
        let secondPEM = await second.rootCertificatePEM()

        XCTAssertEqual(firstPEM, secondPEM, "Reload from disk must yield the same root cert")
    }

    func testRootCertificateMetadata() async throws {
        let ca = try LocalCA.loadOrCreate(in: workDir)
        let cert = await ca.rootCertificate()

        // CN check via string round-trip (the swift-certificates DN type
        // doesn't expose component lookups directly).
        XCTAssertTrue(String(describing: cert.subject).contains(LocalCA.commonName))
        XCTAssertEqual(cert.subject, cert.issuer, "Root cert is self-signed")
        XCTAssertGreaterThan(cert.notValidAfter, Date().addingTimeInterval(60 * 60 * 24 * 365 * 5),
                             "Root validity should comfortably exceed 5 years")
    }

    func testRootKeyFilePermissionsAreRootOnly() async throws {
        _ = try LocalCA.loadOrCreate(in: workDir)
        let keyPath = workDir.appendingPathComponent("ca/ca.key").path
        let attrs = try FileManager.default.attributesOfItem(atPath: keyPath)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(mode & 0o777, 0o600, "ca.key must be 0600 — never world-readable")
    }

    // MARK: - Leaf issuance

    func testIssueLeafCreatesPersistedFiles() async throws {
        let ca = try LocalCA.loadOrCreate(in: workDir)
        _ = try await ca.issueLeaf(for: "vpce.example.com")

        let certPath = workDir.appendingPathComponent("leaves/vpce.example.com.pem")
        let keyPath = workDir.appendingPathComponent("leaves/vpce.example.com.key")
        XCTAssertTrue(FileManager.default.fileExists(atPath: certPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keyPath.path))
    }

    func testLeafCertSubjectAndIssuer() async throws {
        let ca = try LocalCA.loadOrCreate(in: workDir)
        let leaf = try await ca.issueLeaf(for: "vpce.example.com")
        let root = await ca.rootCertificate()

        XCTAssertTrue(String(describing: leaf.certificate.subject).contains("vpce.example.com"),
                      "Leaf subject CN must be the hostname")
        XCTAssertEqual(leaf.certificate.issuer, root.subject,
                       "Leaf issuer DN must equal root subject DN")
    }

    func testLeafCertContainsHostnameSAN() async throws {
        let ca = try LocalCA.loadOrCreate(in: workDir)
        let leaf = try await ca.issueLeaf(for: "vpce.example.com")
        let extString = String(describing: leaf.certificate.extensions)
        XCTAssertTrue(
            extString.contains("vpce.example.com"),
            "SubjectAlternativeNames extension should expose the hostname"
        )
    }

    func testLeafIssuanceIsCachedForSameHostname() async throws {
        let ca = try LocalCA.loadOrCreate(in: workDir)
        let first = try await ca.issueLeaf(for: "vpce.example.com")
        let second = try await ca.issueLeaf(for: "vpce.example.com")
        XCTAssertEqual(first.certificatePEM, second.certificatePEM,
                       "Issuing the same hostname twice should hit the cache")
    }

    func testLeafIssuanceIsCaseInsensitive() async throws {
        let ca = try LocalCA.loadOrCreate(in: workDir)
        let lower = try await ca.issueLeaf(for: "vpce.example.com")
        let mixed = try await ca.issueLeaf(for: "VpCe.ExAmPlE.cOm")
        XCTAssertEqual(lower.certificatePEM, mixed.certificatePEM,
                       "Hostnames are case-insensitive — reuse the cached cert")
    }

    func testDifferentHostnamesGetDifferentLeaves() async throws {
        let ca = try LocalCA.loadOrCreate(in: workDir)
        let a = try await ca.issueLeaf(for: "a.example.com")
        let b = try await ca.issueLeaf(for: "b.example.com")
        XCTAssertNotEqual(a.certificatePEM, b.certificatePEM)
        XCTAssertNotEqual(a.privateKeyPEM, b.privateKeyPEM)
    }

    func testLeafKeyFilePermissionsAreRootOnly() async throws {
        let ca = try LocalCA.loadOrCreate(in: workDir)
        _ = try await ca.issueLeaf(for: "vpce.example.com")
        let keyPath = workDir.appendingPathComponent("leaves/vpce.example.com.key").path
        let attrs = try FileManager.default.attributesOfItem(atPath: keyPath)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(mode & 0o777, 0o600)
    }

    func testLeafValidityWindowIsAboutOneYear() async throws {
        let ca = try LocalCA.loadOrCreate(in: workDir)
        let leaf = try await ca.issueLeaf(for: "vpce.example.com")
        let span = leaf.certificate.notValidAfter.timeIntervalSince(leaf.certificate.notValidBefore)
        let days = span / (60 * 60 * 24)
        // Allow some slack for the -60s notValidBefore offset and clock drift.
        XCTAssertGreaterThan(days, 360)
        XCTAssertLessThan(days, 370)
    }
}
