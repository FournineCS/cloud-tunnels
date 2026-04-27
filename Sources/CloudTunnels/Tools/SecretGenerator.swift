import CryptoKit
import Foundation

/// Pure cryptographic-secret generator. Used by the JWT/HMAC Secret
/// view to produce signing keys in the format the user picks.
public enum SecretGenerator {

    public enum Format: String, CaseIterable, Identifiable {
        case hex
        case base64
        case base64url
        case base32

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .hex: return "Hex"
            case .base64: return "Base64"
            case .base64url: return "Base64 URL"
            case .base32: return "Base32 (TOTP)"
            }
        }

        public var subtitle: String {
            switch self {
            case .hex: return "0-9 a-f"
            case .base64: return "Standard base64 padding"
            case .base64url: return "URL-safe base64, no padding"
            case .base32: return "RFC 4648, TOTP-compatible"
            }
        }
    }

    /// Recommended byte lengths for common HMAC algorithms.
    public enum ByteLength: Int, CaseIterable, Identifiable {
        case sixteen = 16
        case thirtyTwo = 32
        case sixtyFour = 64

        public var id: Int { rawValue }

        public var displayName: String { "\(rawValue) bytes" }

        public var hint: String {
            switch self {
            case .sixteen: return "Minimum for low-stakes HMAC"
            case .thirtyTwo: return "Recommended for HS256 / Vault tokens"
            case .sixtyFour: return "Recommended for HS512"
            }
        }
    }

    /// Generate `byteLength` cryptographically random bytes and
    /// encode them in the requested format. Uses CryptoKit's
    /// `SymmetricKey(size:)` which draws from `SecRandomCopyBytes`.
    public static func generate(byteLength: ByteLength, format: Format) -> String {
        let key = SymmetricKey(size: SymmetricKeySize(bitCount: byteLength.rawValue * 8))
        let bytes = key.withUnsafeBytes { Data($0) }
        return encode(bytes, format: format)
    }

    /// Encode raw bytes in the requested format. Pure helper, exposed
    /// for testing.
    public static func encode(_ data: Data, format: Format) -> String {
        switch format {
        case .hex:
            return data.map { String(format: "%02x", $0) }.joined()
        case .base64:
            return data.base64EncodedString()
        case .base64url:
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        case .base32:
            return base32Encode(data)
        }
    }

    /// RFC 4648 base32 encoding with `=` padding. Pure Swift, no
    /// dependency. Used for TOTP shared secrets which are typically
    /// expressed in base32.
    static func base32Encode(_ data: Data) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var result = ""
        result.reserveCapacity((data.count + 4) / 5 * 8)
        var buffer: UInt64 = 0
        var bitsLeft: Int = 0
        for byte in data {
            buffer = (buffer << 8) | UInt64(byte)
            bitsLeft += 8
            while bitsLeft >= 5 {
                bitsLeft -= 5
                let index = Int((buffer >> UInt64(bitsLeft)) & 0x1f)
                result.append(alphabet[index])
            }
        }
        if bitsLeft > 0 {
            let index = Int((buffer << UInt64(5 - bitsLeft)) & 0x1f)
            result.append(alphabet[index])
        }
        // Pad to a multiple of 8 characters per RFC 4648.
        while result.count % 8 != 0 { result.append("=") }
        return result
    }
}
