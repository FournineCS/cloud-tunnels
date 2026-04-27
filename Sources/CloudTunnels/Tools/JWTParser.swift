import Foundation

struct JWTSegments: Equatable {
    let headerJSON: String
    let payloadJSON: String
    let signatureBase64: String
    /// Decoded "exp" claim if present (seconds since epoch).
    let expiry: Date?
    /// Decoded "iat" claim.
    let issuedAt: Date?
    /// Decoded "nbf" claim.
    let notBefore: Date?

    var isExpired: Bool {
        guard let expiry else { return false }
        return Date() > expiry
    }
}

enum JWTParserError: LocalizedError {
    case wrongSegmentCount
    case base64DecodeFailed(String)
    case jsonDecodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .wrongSegmentCount:
            return "JWT must have three segments separated by '.'"
        case .base64DecodeFailed(let segment):
            return "Failed to base64-decode the \(segment) segment"
        case .jsonDecodeFailed(let segment):
            return "Failed to parse the \(segment) segment as JSON"
        }
    }
}

enum JWTParser {
    static func parse(_ raw: String) throws -> JWTSegments {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { throw JWTParserError.wrongSegmentCount }

        let headerJSON = try decodeSegment(parts[0], name: "header")
        let payloadJSON = try decodeSegment(parts[1], name: "payload")

        let payloadDict = try claimsDict(from: payloadJSON)
        return JWTSegments(
            headerJSON: prettyPrint(headerJSON),
            payloadJSON: prettyPrint(payloadJSON),
            signatureBase64: parts[2],
            expiry: dateClaim(payloadDict, key: "exp"),
            issuedAt: dateClaim(payloadDict, key: "iat"),
            notBefore: dateClaim(payloadDict, key: "nbf")
        )
    }

    private static func decodeSegment(_ segment: String, name: String) throws -> String {
        guard let data = base64URLDecode(segment) else {
            throw JWTParserError.base64DecodeFailed(name)
        }
        guard let s = String(data: data, encoding: .utf8) else {
            throw JWTParserError.jsonDecodeFailed(name)
        }
        return s
    }

    private static func claimsDict(from json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JWTParserError.jsonDecodeFailed("payload")
        }
        return dict
    }

    private static func dateClaim(_ dict: [String: Any], key: String) -> Date? {
        if let n = dict[key] as? Double { return Date(timeIntervalSince1970: n) }
        if let n = dict[key] as? Int { return Date(timeIntervalSince1970: TimeInterval(n)) }
        return nil
    }

    static func base64URLDecode(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = b64.count % 4
        if pad > 0 { b64.append(String(repeating: "=", count: 4 - pad)) }
        return Data(base64Encoded: b64)
    }

    private static func prettyPrint(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: obj,
                  options: [.prettyPrinted, .sortedKeys]
              ),
              let s = String(data: pretty, encoding: .utf8) else {
            return json
        }
        return s
    }
}
