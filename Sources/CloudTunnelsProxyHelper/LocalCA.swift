import Crypto
import Foundation
import SwiftASN1
import X509

/// Owns the local Certificate Authority used to mint per-hostname leaf certs
/// for the NIO proxy listener. All cryptography happens in-process via
/// `swift-certificates` and `swift-crypto` — no `mkcert`, no `openssl`, no
/// external binaries.
///
/// Persistence layout (under the directory passed to `init`):
/// ```
/// ca/
///   ca.pem           # root cert, world-readable
///   ca.key           # root private key, mode 0600 root-only
/// leaves/
///   <hostname>.pem   # leaf cert, world-readable
///   <hostname>.key   # leaf private key, mode 0600 root-only
/// ```
///
/// The root is generated lazily on first `loadOrCreate(in:)` call and reused
/// across helper restarts. Leaves are issued on demand and cached on disk;
/// reissue happens automatically if the cached leaf expires within 30 days.
public actor LocalCA {

    public struct PersistedCert: Sendable {
        public let certificate: Certificate
        public let privateKey: P256.Signing.PrivateKey
        public let certificatePEM: String
        public let privateKeyPEM: String
    }

    public static let commonName = "CloudTunnels Local CA"
    public static let rootValidityYears = 10
    public static let leafValidityDays = 365
    public static let leafReissueThresholdDays = 30

    private let directory: URL
    private let caDirectory: URL
    private let leavesDirectory: URL

    private var root: PersistedCert
    private var leafCache: [String: PersistedCert] = [:]

    // MARK: - Initialization

    /// Loads the root cert from disk if present, otherwise generates a new
    /// one and persists it. Throws on any cryptographic or I/O failure.
    public static func loadOrCreate(in directory: URL) throws -> LocalCA {
        let caDir = directory.appendingPathComponent("ca", isDirectory: true)
        let leavesDir = directory.appendingPathComponent("leaves", isDirectory: true)
        try ensureDirectory(at: caDir)
        try ensureDirectory(at: leavesDir)

        let certURL = caDir.appendingPathComponent("ca.pem")
        let keyURL = caDir.appendingPathComponent("ca.key")

        if FileManager.default.fileExists(atPath: certURL.path),
           FileManager.default.fileExists(atPath: keyURL.path) {
            let cert = try loadCertificate(at: certURL)
            let key = try loadPrivateKey(at: keyURL)
            let persisted = PersistedCert(
                certificate: cert,
                privateKey: key,
                certificatePEM: try cert.serializeAsPEM().pemString,
                privateKeyPEM: key.pemRepresentation
            )
            return LocalCA(
                directory: directory,
                caDirectory: caDir,
                leavesDirectory: leavesDir,
                root: persisted
            )
        }

        let fresh = try generateRoot()
        try writePEM(fresh.certificatePEM, to: certURL, mode: 0o644)
        try writePEM(fresh.privateKeyPEM, to: keyURL, mode: 0o600)
        return LocalCA(
            directory: directory,
            caDirectory: caDir,
            leavesDirectory: leavesDir,
            root: fresh
        )
    }

    private init(
        directory: URL,
        caDirectory: URL,
        leavesDirectory: URL,
        root: PersistedCert
    ) {
        self.directory = directory
        self.caDirectory = caDirectory
        self.leavesDirectory = leavesDirectory
        self.root = root
    }

    // MARK: - Public surface

    public func rootCertificatePEM() -> String {
        root.certificatePEM
    }

    public func rootCertificate() -> Certificate {
        root.certificate
    }

    /// Returns a leaf cert + key pair valid for the given hostname. Reuses
    /// a cached entry if one exists and isn't near expiry; otherwise mints
    /// a new pair and persists it.
    public func issueLeaf(for hostname: String) throws -> PersistedCert {
        let normalized = hostname.lowercased()
        if let cached = leafCache[normalized], !leafIsNearExpiry(cached) {
            return cached
        }

        let certURL = leavesDirectory.appendingPathComponent("\(normalized).pem")
        let keyURL = leavesDirectory.appendingPathComponent("\(normalized).key")

        if leafCache[normalized] == nil,
           FileManager.default.fileExists(atPath: certURL.path),
           FileManager.default.fileExists(atPath: keyURL.path) {
            let cert = try Self.loadCertificate(at: certURL)
            let key = try Self.loadPrivateKey(at: keyURL)
            let persisted = PersistedCert(
                certificate: cert,
                privateKey: key,
                certificatePEM: try cert.serializeAsPEM().pemString,
                privateKeyPEM: key.pemRepresentation
            )
            if !leafIsNearExpiry(persisted) {
                leafCache[normalized] = persisted
                return persisted
            }
        }

        let fresh = try generateLeaf(for: normalized)
        try Self.writePEM(fresh.certificatePEM, to: certURL, mode: 0o644)
        try Self.writePEM(fresh.privateKeyPEM, to: keyURL, mode: 0o600)
        leafCache[normalized] = fresh
        return fresh
    }

    // MARK: - Generation

    private static func generateRoot() throws -> PersistedCert {
        let key = P256.Signing.PrivateKey()
        let certKey = Certificate.PrivateKey(key)
        let publicKey = Certificate.PublicKey(key.publicKey)
        let now = Date()
        let notValidBefore = now.addingTimeInterval(-60)
        let notValidAfter = Calendar(identifier: .gregorian)
            .date(byAdding: .year, value: rootValidityYears, to: now)
            ?? now.addingTimeInterval(60 * 60 * 24 * 365 * Double(rootValidityYears))

        let name = try DistinguishedName {
            CommonName(commonName)
        }

        let extensions = try Certificate.Extensions {
            Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 1))
            Critical(KeyUsage(keyCertSign: true, cRLSign: true))
            SubjectKeyIdentifier(keyIdentifier: ArraySlice(SHA256.hash(data: Array(publicKey.subjectPublicKeyInfoBytes))))
        }

        let cert = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: publicKey,
            notValidBefore: notValidBefore,
            notValidAfter: notValidAfter,
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: certKey
        )

        return PersistedCert(
            certificate: cert,
            privateKey: key,
            certificatePEM: try cert.serializeAsPEM().pemString,
            privateKeyPEM: key.pemRepresentation
        )
    }

    private func generateLeaf(for hostname: String) throws -> PersistedCert {
        let key = P256.Signing.PrivateKey()
        let certKey = Certificate.PrivateKey(key)
        let publicKey = Certificate.PublicKey(key.publicKey)
        let issuerKey = Certificate.PrivateKey(root.privateKey)

        let now = Date()
        let notValidBefore = now.addingTimeInterval(-60)
        let notValidAfter = now.addingTimeInterval(
            60 * 60 * 24 * Double(Self.leafValidityDays)
        )

        let subject = try DistinguishedName {
            CommonName(hostname)
        }

        let extensions = try Certificate.Extensions {
            Critical(BasicConstraints.notCertificateAuthority)
            Critical(KeyUsage(digitalSignature: true, keyEncipherment: true))
            try ExtendedKeyUsage([.serverAuth])
            SubjectAlternativeNames([.dnsName(hostname)])
            SubjectKeyIdentifier(keyIdentifier: ArraySlice(SHA256.hash(data: Array(publicKey.subjectPublicKeyInfoBytes))))
        }

        let cert = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: publicKey,
            notValidBefore: notValidBefore,
            notValidAfter: notValidAfter,
            issuer: root.certificate.subject,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: issuerKey
        )
        _ = certKey  // silence warning; we hold the leaf key separately for TLS use

        return PersistedCert(
            certificate: cert,
            privateKey: key,
            certificatePEM: try cert.serializeAsPEM().pemString,
            privateKeyPEM: key.pemRepresentation
        )
    }

    private func leafIsNearExpiry(_ cert: PersistedCert) -> Bool {
        let threshold = Date().addingTimeInterval(
            60 * 60 * 24 * Double(Self.leafReissueThresholdDays)
        )
        return cert.certificate.notValidAfter <= threshold
    }

    // MARK: - Persistence helpers

    private static func ensureDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o755))]
        )
    }

    private static func loadCertificate(at url: URL) throws -> Certificate {
        let pem = try String(contentsOf: url, encoding: .utf8)
        return try Certificate(pemEncoded: pem)
    }

    private static func loadPrivateKey(at url: URL) throws -> P256.Signing.PrivateKey {
        let pem = try String(contentsOf: url, encoding: .utf8)
        return try P256.Signing.PrivateKey(pemRepresentation: pem)
    }

    private static func writePEM(_ pem: String, to url: URL, mode: Int16) throws {
        try Data(pem.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: mode)],
            ofItemAtPath: url.path
        )
    }
}
