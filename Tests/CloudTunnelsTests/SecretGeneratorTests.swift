import XCTest
@testable import CloudTunnels

final class SecretGeneratorTests: XCTestCase {

    // MARK: - encode (pure)

    func testHexEncoding() {
        let data = Data([0x00, 0xff, 0xab, 0xcd])
        XCTAssertEqual(SecretGenerator.encode(data, format: .hex), "00ffabcd")
    }

    func testBase64Encoding() {
        let data = Data("hello".utf8)
        XCTAssertEqual(SecretGenerator.encode(data, format: .base64), "aGVsbG8=")
    }

    func testBase64URLEncodingStripsPaddingAndReplacesChars() {
        // Bytes chosen so standard base64 produces +, /, and =.
        let data = Data([0xfb, 0xff, 0xbf])  // -> "+/+/" in base64 with padding
        let standard = data.base64EncodedString()
        let urlSafe = SecretGenerator.encode(data, format: .base64url)
        // No padding
        XCTAssertFalse(urlSafe.contains("="))
        // No + or /
        XCTAssertFalse(urlSafe.contains("+"))
        XCTAssertFalse(urlSafe.contains("/"))
        // Length matches stripped standard
        let strippedLength = standard.replacingOccurrences(of: "=", with: "").count
        XCTAssertEqual(urlSafe.count, strippedLength)
    }

    func testBase32EncodingMatchesRFC4648Vectors() {
        // Test vectors straight from RFC 4648 §10
        XCTAssertEqual(SecretGenerator.encode(Data("".utf8), format: .base32), "")
        XCTAssertEqual(SecretGenerator.encode(Data("f".utf8), format: .base32), "MY======")
        XCTAssertEqual(SecretGenerator.encode(Data("fo".utf8), format: .base32), "MZXQ====")
        XCTAssertEqual(SecretGenerator.encode(Data("foo".utf8), format: .base32), "MZXW6===")
        XCTAssertEqual(SecretGenerator.encode(Data("foob".utf8), format: .base32), "MZXW6YQ=")
        XCTAssertEqual(SecretGenerator.encode(Data("fooba".utf8), format: .base32), "MZXW6YTB")
        XCTAssertEqual(SecretGenerator.encode(Data("foobar".utf8), format: .base32), "MZXW6YTBOI======")
    }

    func testBase32OutputUsesOnlyValidAlphabet() {
        let data = Data((0..<64).map { UInt8($0) })
        let encoded = SecretGenerator.encode(data, format: .base32)
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567=")
        for ch in encoded {
            XCTAssertTrue(allowed.contains(ch), "base32 contains invalid char: \(ch)")
        }
    }

    // MARK: - generate

    func testHexLengthFor16Bytes() {
        let s = SecretGenerator.generate(byteLength: .sixteen, format: .hex)
        XCTAssertEqual(s.count, 32)  // 16 bytes * 2 hex chars
    }

    func testHexLengthFor32Bytes() {
        let s = SecretGenerator.generate(byteLength: .thirtyTwo, format: .hex)
        XCTAssertEqual(s.count, 64)
    }

    func testHexLengthFor64Bytes() {
        let s = SecretGenerator.generate(byteLength: .sixtyFour, format: .hex)
        XCTAssertEqual(s.count, 128)
    }

    func testHexOutputUsesOnlyHexChars() {
        let s = SecretGenerator.generate(byteLength: .thirtyTwo, format: .hex)
        let allowed = Set("0123456789abcdef")
        for ch in s {
            XCTAssertTrue(allowed.contains(ch), "hex contains invalid char: \(ch)")
        }
    }

    func testTwoConsecutiveGenerationsDiffer() {
        // 32-byte secrets collide with probability ~10^-77.
        let a = SecretGenerator.generate(byteLength: .thirtyTwo, format: .hex)
        let b = SecretGenerator.generate(byteLength: .thirtyTwo, format: .hex)
        XCTAssertNotEqual(a, b)
    }

    func testFormatDisplayNamesAreNonEmpty() {
        for f in SecretGenerator.Format.allCases {
            XCTAssertFalse(f.displayName.isEmpty)
            XCTAssertFalse(f.subtitle.isEmpty)
        }
    }

    func testByteLengthHintsAreNonEmpty() {
        for l in SecretGenerator.ByteLength.allCases {
            XCTAssertFalse(l.displayName.isEmpty)
            XCTAssertFalse(l.hint.isEmpty)
        }
    }
}
