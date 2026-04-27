import CryptoKit
import Foundation
import SwiftASN1
import X509

/// Parses an X.509 PEM certificate into a flat, display-friendly
/// struct. Pure logic — no SwiftUI, no I/O. Used by `CertInspectorView`.
public enum CertInspector {

    public struct Inspected: Equatable {
        public var subjectCN: String?
        public var subjectFull: String
        public var issuerCN: String?
        public var issuerFull: String
        public var notValidBefore: Date
        public var notValidAfter: Date
        public var serialNumberHex: String
        public var signatureAlgorithm: String
        public var publicKeyAlgorithm: String
        public var sanDNS: [String]
        public var sanIP: [String]
        public var sha256Fingerprint: String
        public var isExpired: Bool
        public var daysUntilExpiry: Int
        public var keyUsages: [String]
        public var extendedKeyUsages: [String]
        public var basicConstraints: String?
        public var pem: String?
    }

    public enum InspectError: LocalizedError {
        case noPEMBlock
        case parseFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noPEMBlock:
                return "No PEM CERTIFICATE block found in the input."
            case .parseFailed(let detail):
                return "Failed to parse certificate: \(detail)"
            }
        }
    }

    /// Inspect a PEM-encoded certificate. The input may contain
    /// multiple PEM blocks (a chain) — we parse the first
    /// CERTIFICATE block and ignore the rest.
    public static func inspect(pem: String) throws -> Inspected {
        guard pem.contains("-----BEGIN CERTIFICATE-----") else {
            throw InspectError.noPEMBlock
        }
        let cert: Certificate
        do {
            cert = try Certificate(pemEncoded: pem)
        } catch {
            throw InspectError.parseFailed(error.localizedDescription)
        }
        return summarize(cert)
    }

    /// Pure summarizer: takes a parsed Certificate and produces
    /// the flat struct. Split out so tests can build a Certificate
    /// in-memory (via LocalCA) and exercise this without going
    /// through PEM round-tripping.
    public static func summarize(_ cert: Certificate) -> Inspected {
        let now = Date()
        let notBefore = cert.notValidBefore
        let notAfter = cert.notValidAfter

        let (sanDNS, sanIP) = extractSANs(cert)
        let derBytes = serializeToDER(cert) ?? []
        let fp = sha256Fingerprint(of: derBytes)

        let secondsUntil = notAfter.timeIntervalSince(now)
        let days = Int(secondsUntil / 86400)

        return Inspected(
            subjectCN: extractCN(from: cert.subject),
            subjectFull: cert.subject.description,
            issuerCN: extractCN(from: cert.issuer),
            issuerFull: cert.issuer.description,
            notValidBefore: notBefore,
            notValidAfter: notAfter,
            serialNumberHex: serialHex(cert.serialNumber),
            signatureAlgorithm: String(describing: cert.signatureAlgorithm),
            publicKeyAlgorithm: describePublicKey(cert.publicKey),
            sanDNS: sanDNS,
            sanIP: sanIP,
            sha256Fingerprint: fp,
            isExpired: now > notAfter,
            daysUntilExpiry: days,
            keyUsages: extractKeyUsages(cert),
            extendedKeyUsages: extractExtendedKeyUsages(cert),
            basicConstraints: extractBasicConstraints(cert),
            pem: serializeToPEM(cert)
        )
    }

    /// Extract enabled KeyUsage flags as display-friendly strings
    /// that roughly match `openssl x509 -noout -text` output. Order
    /// is fixed so tests are deterministic.
    static func extractKeyUsages(_ cert: Certificate) -> [String] {
        guard let ku = try? cert.extensions.keyUsage else { return [] }
        var out: [String] = []
        if ku.digitalSignature { out.append("Digital Signature") }
        if ku.nonRepudiation { out.append("Non Repudiation") }
        if ku.keyEncipherment { out.append("Key Encipherment") }
        if ku.dataEncipherment { out.append("Data Encipherment") }
        if ku.keyAgreement { out.append("Key Agreement") }
        if ku.keyCertSign { out.append("Certificate Sign") }
        if ku.cRLSign { out.append("CRL Sign") }
        if ku.encipherOnly { out.append("Encipher Only") }
        if ku.decipherOnly { out.append("Decipher Only") }
        return out
    }

    /// Extract ExtendedKeyUsage entries as human-readable strings
    /// (e.g. "serverAuth", "clientAuth"). Uses the built-in
    /// `CustomStringConvertible` on `ExtendedKeyUsage.Usage`.
    static func extractExtendedKeyUsages(_ cert: Certificate) -> [String] {
        guard let eku = try? cert.extensions.extendedKeyUsage else { return [] }
        return eku.map { String(describing: $0) }
    }

    /// Surface the BasicConstraints extension as a flat string.
    /// Returns nil when the extension isn't present on the cert.
    static func extractBasicConstraints(_ cert: Certificate) -> String? {
        guard let bc = try? cert.extensions.basicConstraints else { return nil }
        return String(describing: bc)
    }

    /// Serialize the certificate to PEM text. Returns nil on
    /// serialization failure (extremely unlikely for a
    /// successfully-parsed cert).
    static func serializeToPEM(_ cert: Certificate) -> String? {
        (try? cert.serializeAsPEM().pemString)
    }

    // MARK: - Helpers (pure, testable)

    /// Extract the CN component from a DistinguishedName by string
    /// matching its description. swift-certificates doesn't expose
    /// a direct CN getter; the description always emits "CN=…" if
    /// the CN is set.
    static func extractCN(from name: DistinguishedName) -> String? {
        let desc = name.description
        // Match "CN=foo" or "CN=foo," or "CN=foo bar baz,..."
        guard let cnRange = desc.range(of: "CN=") else { return nil }
        let after = desc[cnRange.upperBound...]
        if let comma = after.firstIndex(of: ",") {
            return String(after[..<comma]).trimmingCharacters(in: .whitespaces)
        }
        return String(after).trimmingCharacters(in: .whitespaces)
    }

    /// Iterate the SubjectAlternativeNames extension and split the
    /// entries into DNS names and IP literals. Returns empty arrays
    /// if the cert has no SAN extension or only contains other types
    /// (URI, email, etc. — not used for TLS host matching).
    static func extractSANs(_ cert: Certificate) -> (dns: [String], ip: [String]) {
        var dns: [String] = []
        var ips: [String] = []
        guard let sanExt = try? cert.extensions.subjectAlternativeNames else {
            return ([], [])
        }
        for entry in sanExt {
            switch entry {
            case .dnsName(let name):
                dns.append(name)
            case .ipAddress(let octetString):
                if let s = ipString(from: octetString.bytes) {
                    ips.append(s)
                }
            default:
                break
            }
        }
        return (dns, ips)
    }

    /// Format a SAN IP-address byte slice (4 bytes for v4, 16 for v6).
    static func ipString(from bytes: ArraySlice<UInt8>) -> String? {
        if bytes.count == 4 {
            return bytes.map { String($0) }.joined(separator: ".")
        }
        if bytes.count == 16 {
            // Compact-ish IPv6 representation. Not full RFC 5952
            // canonicalization (zero-run compression), but readable.
            var groups: [String] = []
            for i in stride(from: bytes.startIndex, to: bytes.endIndex, by: 2) {
                let hi = UInt16(bytes[i]) << 8
                let lo = UInt16(bytes[i + 1])
                groups.append(String(hi | lo, radix: 16))
            }
            return groups.joined(separator: ":")
        }
        return nil
    }

    /// Serial numbers are typically displayed as colon-separated
    /// uppercase hex pairs, e.g. `01:23:AB:CD`. Same format `openssl
    /// x509 -serial` uses.
    static func serialHex(_ serial: Certificate.SerialNumber) -> String {
        serial.bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// SHA-256 fingerprint of the DER-encoded cert, formatted like
    /// `openssl x509 -fingerprint -sha256` output.
    static func sha256Fingerprint(of derBytes: [UInt8]) -> String {
        guard !derBytes.isEmpty else { return "" }
        let digest = SHA256.hash(data: Data(derBytes))
        return digest.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// Best-effort description of the cert's public key algorithm
    /// and key size. swift-certificates' Certificate.PublicKey is
    /// an enum-ish wrapper around several backing types; we string-
    /// describe and pull out the key parts.
    static func describePublicKey(_ key: Certificate.PublicKey) -> String {
        let desc = String(describing: key)
        // Common forms: "P256.Signing.PublicKey(...)", "RSA.PublicKey(...)"
        // Trim noise to keep the display short.
        if desc.contains("P256") { return "ECDSA P-256" }
        if desc.contains("P384") { return "ECDSA P-384" }
        if desc.contains("P521") { return "ECDSA P-521" }
        if desc.contains("RSA") { return "RSA" }
        if desc.contains("Ed25519") { return "Ed25519" }
        return desc
    }

    /// Serialize the certificate to DER bytes for fingerprinting.
    /// Returns nil on serialization failure (extremely unlikely for
    /// a successfully-parsed cert).
    static func serializeToDER(_ cert: Certificate) -> [UInt8]? {
        var serializer = DER.Serializer()
        do {
            try cert.serialize(into: &serializer)
        } catch {
            return nil
        }
        return serializer.serializedBytes
    }
}
