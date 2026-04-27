import Foundation
import SwiftASN1
import X509

/// Decodes a PEM-encoded Certificate Signing Request (CSR). Parallel
/// to `CertInspector` but for the request side of the issuing flow.
/// Users typically need this when they're preparing to get a cert
/// issued by an internal CA or a public CA and want to sanity-check
/// the CSR matches what they intended before submitting.
public enum CSRInspector {

    public struct Inspected: Equatable {
        public var subjectCN: String?
        public var subjectFull: String
        public var publicKeyAlgorithm: String
        public var sanDNS: [String]
        public var sanIP: [String]
        /// SHA-256 fingerprint of the CSR itself (the full DER
        /// encoding). Useful when comparing what you just pasted
        /// against what you emailed to a CA.
        public var sha256Fingerprint: String
    }

    public enum InspectError: LocalizedError {
        case noPEMBlock
        case parseFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noPEMBlock:
                return "No `CERTIFICATE REQUEST` PEM block found in the input."
            case .parseFailed(let detail):
                return "Failed to parse CSR: \(detail)"
            }
        }
    }

    public static func inspect(pem: String) throws -> Inspected {
        guard pem.contains("-----BEGIN CERTIFICATE REQUEST-----") else {
            throw InspectError.noPEMBlock
        }
        let csr: CertificateSigningRequest
        do {
            csr = try CertificateSigningRequest(pemEncoded: pem)
        } catch {
            throw InspectError.parseFailed(error.localizedDescription)
        }
        return try summarize(csr, originalPEM: pem)
    }

    /// Pure summarizer — takes a parsed CSR (and the original PEM
    /// for fingerprint computation) and produces the display struct.
    static func summarize(_ csr: CertificateSigningRequest, originalPEM: String) throws -> Inspected {
        let (dns, ips) = extractSANs(csr)
        let der = derBytes(of: csr)
        let fp = CertInspector.sha256Fingerprint(of: der)

        return Inspected(
            subjectCN: CertInspector.extractCN(from: csr.subject),
            subjectFull: csr.subject.description,
            publicKeyAlgorithm: CertInspector.describePublicKey(csr.publicKey),
            sanDNS: dns,
            sanIP: ips,
            sha256Fingerprint: fp
        )
    }

    /// Walk the CSR's `extensionRequest` attribute (if present) to
    /// pull out the SubjectAlternativeNames the requester is asking
    /// the CA to issue the cert with. If the CSR has no SAN request
    /// at all, returns empty arrays.
    static func extractSANs(_ csr: CertificateSigningRequest) -> (dns: [String], ip: [String]) {
        var dns: [String] = []
        var ips: [String] = []
        // csr.attributes.extensionRequest is a throwing property
        // returning ExtensionRequest? wrapping Certificate.Extensions.
        // Both layers throw on decode failure; we use try? to
        // collapse all failure modes into "no SANs available".
        guard let extReq = (try? csr.attributes.extensionRequest) ?? nil else {
            return ([], [])
        }
        guard let sanExt = try? extReq.extensions.subjectAlternativeNames else {
            return ([], [])
        }
        for entry in sanExt {
            switch entry {
            case .dnsName(let name):
                dns.append(name)
            case .ipAddress(let octetString):
                if let s = CertInspector.ipString(from: octetString.bytes) {
                    ips.append(s)
                }
            default:
                break
            }
        }
        return (dns, ips)
    }

    /// Serialize a CSR back to DER bytes so we can fingerprint it.
    /// swift-certificates doesn't expose a direct `.derBytes` on
    /// CertificateSigningRequest, but the `DERSerializable`
    /// conformance lets us feed it through a DER.Serializer.
    static func derBytes(of csr: CertificateSigningRequest) -> [UInt8] {
        var serializer = DER.Serializer()
        do {
            try csr.serialize(into: &serializer)
        } catch {
            return []
        }
        return serializer.serializedBytes
    }
}
