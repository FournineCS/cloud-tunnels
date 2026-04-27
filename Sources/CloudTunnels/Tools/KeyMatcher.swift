import Foundation
import X509

/// Verifies that a certificate and a private key belong to the same
/// keypair. Useful during cert rotation, when importing a
/// cert+key bundle from another system, or when debugging "does
/// this key actually go with this cert" questions.
///
/// Implementation: parse both inputs (cert PEM, key PEM), derive the
/// key's public key, and compare it to the cert's public key. The
/// comparison uses swift-certificates' `Certificate.PublicKey`
/// Equatable conformance, which compares the underlying ECDSA /
/// RSA / Ed25519 key material — not a string-level comparison.
public enum KeyMatcher {

    public enum MatchResult: Equatable {
        case match(algorithm: String)
        case mismatch(certKey: String, privateKey: String)
    }

    public enum MatchError: LocalizedError, Equatable {
        case certPEMMissing
        case keyPEMMissing
        case certParseFailed(String)
        case keyParseFailed(String)

        public var errorDescription: String? {
            switch self {
            case .certPEMMissing:
                return "Paste a `-----BEGIN CERTIFICATE-----` block in the certificate field."
            case .keyPEMMissing:
                return "Paste a private key PEM block in the key field."
            case .certParseFailed(let m):
                return "Failed to parse certificate: \(m)"
            case .keyParseFailed(let m):
                return "Failed to parse private key: \(m)"
            }
        }
    }

    /// Check whether the cert's public key matches the private
    /// key's derived public key. Throws on parse failures so the
    /// view can distinguish "mismatch" from "couldn't even parse".
    public static func check(certPEM: String, keyPEM: String) throws -> MatchResult {
        guard certPEM.contains("-----BEGIN CERTIFICATE-----") else {
            throw MatchError.certPEMMissing
        }
        guard keyPEM.contains("-----BEGIN") && keyPEM.contains("PRIVATE KEY-----") else {
            throw MatchError.keyPEMMissing
        }

        let cert: Certificate
        do {
            cert = try Certificate(pemEncoded: certPEM)
        } catch {
            throw MatchError.certParseFailed(error.localizedDescription)
        }

        let privateKey: Certificate.PrivateKey
        do {
            privateKey = try Certificate.PrivateKey(pemEncoded: keyPEM)
        } catch {
            throw MatchError.keyParseFailed(error.localizedDescription)
        }

        if cert.publicKey == privateKey.publicKey {
            return .match(algorithm: CertInspector.describePublicKey(cert.publicKey))
        } else {
            return .mismatch(
                certKey: CertInspector.describePublicKey(cert.publicKey),
                privateKey: CertInspector.describePublicKey(privateKey.publicKey)
            )
        }
    }
}
