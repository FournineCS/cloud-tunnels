import XCTest
@testable import CloudTunnels

final class PasswordGeneratorTests: XCTestCase {

    // MARK: - candidatePool

    func testPoolIncludesAllSetsByDefault() {
        let pool = PasswordGenerator.candidatePool(.init())
        XCTAssertTrue(pool.contains("a"))
        XCTAssertTrue(pool.contains("Z"))
        XCTAssertTrue(pool.contains("5"))
        XCTAssertTrue(pool.contains("!"))
    }

    func testExcludeAmbiguousRemovesConfusables() {
        let pool = PasswordGenerator.candidatePool(.init(excludeAmbiguous: true))
        XCTAssertFalse(pool.contains("0"))
        XCTAssertFalse(pool.contains("O"))
        XCTAssertFalse(pool.contains("o"))
        XCTAssertFalse(pool.contains("1"))
        XCTAssertFalse(pool.contains("l"))
        XCTAssertFalse(pool.contains("I"))
        XCTAssertFalse(pool.contains("|"))
        // Non-ambiguous chars must still be there
        XCTAssertTrue(pool.contains("a"))
        XCTAssertTrue(pool.contains("5"))
    }

    func testNoCharsetsSelectedYieldsEmptyPool() {
        let opts = PasswordGenerator.Options(
            lowercase: false, uppercase: false, digits: false, symbols: false
        )
        XCTAssertTrue(PasswordGenerator.candidatePool(opts).isEmpty)
    }

    func testOnlyLowercasePool() {
        let opts = PasswordGenerator.Options(
            lowercase: true, uppercase: false, digits: false, symbols: false
        )
        let pool = PasswordGenerator.candidatePool(opts)
        XCTAssertEqual(pool.count, 26)
        for ch in pool { XCTAssertTrue(ch.isLowercase) }
    }

    // MARK: - generate

    func testGeneratedLengthMatchesOption() throws {
        let opts = PasswordGenerator.Options(length: 32)
        let result = try PasswordGenerator.generate(opts)
        XCTAssertEqual(result.count, 32)
    }

    func testGeneratedOnlyContainsSelectedCharsets() throws {
        let opts = PasswordGenerator.Options(
            length: 64,
            lowercase: false,
            uppercase: false,
            digits: true,
            symbols: false
        )
        let result = try PasswordGenerator.generate(opts)
        for ch in result {
            XCTAssertTrue(ch.isNumber, "unexpected char in digits-only password: \(ch)")
        }
    }

    func testGeneratedRespectsExcludeAmbiguous() throws {
        let opts = PasswordGenerator.Options(
            length: 128,
            lowercase: true,
            uppercase: true,
            digits: true,
            symbols: false,
            excludeAmbiguous: true
        )
        let result = try PasswordGenerator.generate(opts)
        for ch in result {
            XCTAssertFalse(
                PasswordGenerator.ambiguousChars.contains(ch),
                "found ambiguous char \(ch) in result"
            )
        }
    }

    func testGenerateThrowsWhenNoCharsetsSelected() {
        let opts = PasswordGenerator.Options(
            lowercase: false, uppercase: false, digits: false, symbols: false
        )
        XCTAssertThrowsError(try PasswordGenerator.generate(opts)) { error in
            guard case PasswordGenerator.GenerationError.noCharsetsSelected = error else {
                return XCTFail("expected noCharsetsSelected, got \(error)")
            }
        }
    }

    func testGenerateThrowsBelowMinLength() {
        let opts = PasswordGenerator.Options(length: 4)
        XCTAssertThrowsError(try PasswordGenerator.generate(opts)) { error in
            guard case PasswordGenerator.GenerationError.lengthOutOfRange = error else {
                return XCTFail("expected lengthOutOfRange, got \(error)")
            }
        }
    }

    func testGenerateThrowsAboveMaxLength() {
        let opts = PasswordGenerator.Options(length: 256)
        XCTAssertThrowsError(try PasswordGenerator.generate(opts)) { error in
            guard case PasswordGenerator.GenerationError.lengthOutOfRange = error else {
                return XCTFail("expected lengthOutOfRange, got \(error)")
            }
        }
    }

    func testTwoConsecutiveGenerationsAlmostNeverMatch() throws {
        // Statistically: 2 random 24-char passwords from a 78-char
        // pool collide with probability ~10^-46. If this fails, the
        // RNG isn't actually random.
        let opts = PasswordGenerator.Options(length: 24)
        let a = try PasswordGenerator.generate(opts)
        let b = try PasswordGenerator.generate(opts)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - entropy

    func testEntropyMatchesFormulaForDefaultPool() {
        let opts = PasswordGenerator.Options(length: 24)
        let pool = PasswordGenerator.candidatePool(opts)
        let expected = 24.0 * log2(Double(pool.count))
        XCTAssertEqual(
            PasswordGenerator.entropyBits(opts),
            expected,
            accuracy: 0.01
        )
    }

    func testEntropyZeroWhenNoCharsetsSelected() {
        let opts = PasswordGenerator.Options(
            lowercase: false, uppercase: false, digits: false, symbols: false
        )
        XCTAssertEqual(PasswordGenerator.entropyBits(opts), 0)
    }
}
