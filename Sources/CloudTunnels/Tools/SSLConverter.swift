import Foundation

/// Convert a single certificate or private key between PEM and DER
/// encodings. PEM is base64-wrapped with `-----BEGIN/END X-----`
/// banner lines; DER is the raw ASN.1 bytes. The two are trivially
/// interconvertible — PEM is literally DER base64-encoded with a
/// line wrapper.
///
/// Scope note: PKCS#12 (.p12 / .pfx) conversion is NOT supported.
/// Creating a p12 requires a password-based KDF dance and a full
/// ASN.1 container, which is much heavier than PEM↔DER and needs
/// its own UI for the password. If someone needs p12 they can use
/// `openssl pkcs12 ...` from a terminal; this tool targets the
/// common "I have a cert in PEM and my tool wants DER" flow.
public enum SSLConverter {

    public enum Mode: String, CaseIterable, Identifiable {
        case pemToDer = "PEM → DER"
        case derToPem = "DER → PEM"

        public var id: String { rawValue }
    }

    public enum PEMLabel: String, CaseIterable, Identifiable {
        case certificate = "CERTIFICATE"
        case csr = "CERTIFICATE REQUEST"
        case privateKey = "PRIVATE KEY"
        case rsaPrivateKey = "RSA PRIVATE KEY"
        case ecPrivateKey = "EC PRIVATE KEY"
        case publicKey = "PUBLIC KEY"

        public var id: String { rawValue }
        public var displayName: String { rawValue.capitalized(with: nil) }
    }

    public enum ConvertError: LocalizedError, Equatable {
        case emptyInput
        case notPEM(String)
        case invalidBase64(String)
        case invalidHex(String)

        public var errorDescription: String? {
            switch self {
            case .emptyInput:
                return "Paste something to convert."
            case .notPEM(let detail):
                return "Not a valid PEM block: \(detail)"
            case .invalidBase64(let detail):
                return "Invalid base64: \(detail)"
            case .invalidHex(let detail):
                return "Invalid hex input: \(detail)"
            }
        }
    }

    /// Strip the PEM banner and line wrapping from a PEM document
    /// and return the raw DER bytes. The user can use any label —
    /// we don't enforce a specific `-----BEGIN X-----` tag because
    /// this tool is meant for ad-hoc conversion, not validation.
    public static func pemToDer(_ pem: String) throws -> Data {
        let trimmed = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ConvertError.emptyInput }
        guard trimmed.contains("-----BEGIN") && trimmed.contains("-----END") else {
            throw ConvertError.notPEM("missing BEGIN/END banner")
        }
        // Drop all lines that contain "-----" (the banners) and
        // join the rest. Whitespace is stripped because some PEMs
        // have indented content.
        let body = trimmed
            .split(whereSeparator: { $0.isNewline })
            .filter { !$0.contains("-----") }
            .joined()
            .filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: body) else {
            throw ConvertError.invalidBase64("could not decode PEM body")
        }
        return data
    }

    /// Wrap DER bytes into a PEM document with the given label.
    /// Lines are wrapped at 64 chars per the PEM spec.
    public static func derToPem(_ der: Data, label: PEMLabel) -> String {
        let base64 = der.base64EncodedString()
        var lines: [String] = []
        lines.append("-----BEGIN \(label.rawValue)-----")
        // Wrap at 64 chars. This is the standard PEM line width
        // — RFC 7468 permits any width but 64 is what openssl
        // produces and what every parser handles without complaint.
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<end]))
            index = end
        }
        lines.append("-----END \(label.rawValue)-----")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Accept DER bytes that the user has pasted as either a hex
    /// string (space- or colon-separated) or a base64 string.
    /// Returns the raw byte Data so the caller can re-encode it.
    public static func parseDerInput(_ raw: String) throws -> Data {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ConvertError.emptyInput }

        // Heuristic: if the input looks like hex (only hex chars
        // plus separators), decode as hex. Otherwise try base64.
        let compact = trimmed
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\t", with: "")
        let hexChars = Set("0123456789abcdefABCDEF")
        if !compact.isEmpty, compact.allSatisfy({ hexChars.contains($0) }), compact.count % 2 == 0 {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(compact.count / 2)
            var idx = compact.startIndex
            while idx < compact.endIndex {
                let next = compact.index(idx, offsetBy: 2)
                guard let byte = UInt8(compact[idx..<next], radix: 16) else {
                    throw ConvertError.invalidHex("bad hex pair at offset \(compact.distance(from: compact.startIndex, to: idx))")
                }
                bytes.append(byte)
                idx = next
            }
            return Data(bytes)
        }

        // Fall back to base64.
        guard let data = Data(base64Encoded: compact) else {
            throw ConvertError.invalidBase64("input is neither valid hex nor base64")
        }
        return data
    }

    /// Format DER bytes as hex for display (uppercase, colon-separated
    /// pairs, 16 bytes per line — the openssl -text default).
    public static func formatDerAsHex(_ data: Data) -> String {
        var lines: [String] = []
        let bytes = Array(data)
        var i = 0
        while i < bytes.count {
            let end = min(i + 16, bytes.count)
            let slice = bytes[i..<end]
            let hex = slice.map { String(format: "%02x", $0) }.joined(separator: ":")
            lines.append(hex)
            i = end
        }
        return lines.joined(separator: "\n")
    }
}
