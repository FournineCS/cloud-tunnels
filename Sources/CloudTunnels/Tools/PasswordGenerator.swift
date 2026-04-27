import Foundation

/// Pure password / random-string generator. The view is a thin shell
/// around `generate(_:)` — all the logic lives here so it's
/// unit-testable without spinning up SwiftUI.
public enum PasswordGenerator {

    public struct Options: Equatable {
        public var length: Int
        public var lowercase: Bool
        public var uppercase: Bool
        public var digits: Bool
        public var symbols: Bool
        /// Strip visually-ambiguous characters (0/O/o/1/l/I/|) from
        /// the candidate set. Useful for passwords that get read aloud
        /// or written down.
        public var excludeAmbiguous: Bool

        public init(
            length: Int = 24,
            lowercase: Bool = true,
            uppercase: Bool = true,
            digits: Bool = true,
            symbols: Bool = true,
            excludeAmbiguous: Bool = false
        ) {
            self.length = length
            self.lowercase = lowercase
            self.uppercase = uppercase
            self.digits = digits
            self.symbols = symbols
            self.excludeAmbiguous = excludeAmbiguous
        }
    }

    public enum GenerationError: LocalizedError, Equatable {
        case noCharsetsSelected
        case lengthOutOfRange(Int)

        public var errorDescription: String? {
            switch self {
            case .noCharsetsSelected:
                return "Pick at least one character set."
            case .lengthOutOfRange(let n):
                return "Length \(n) is out of range (8–128)."
            }
        }
    }

    public static let minLength = 8
    public static let maxLength = 128

    /// Lowercase a-z. Excludes l (looks like 1) when ambiguous filter on.
    public static let lowercaseChars = "abcdefghijklmnopqrstuvwxyz"
    /// Uppercase A-Z. Excludes I and O (look like 1 and 0) when ambiguous filter on.
    public static let uppercaseChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    /// Digits 0-9. Excludes 0 and 1 when ambiguous filter on.
    public static let digitChars = "0123456789"
    /// Common symbols sufficient to push past most password-policy
    /// "must contain a special character" rules. Excludes those that
    /// are routinely escaped by shells (`, $, ", ', \) to make the
    /// output safer to copy-paste into config files and CLI commands.
    public static let symbolChars = "!@#%^&*()-_=+[]{}<>?/"

    /// Characters removed from the pool when `excludeAmbiguous` is on.
    /// Conservative list — only the genuinely confusable pairs.
    public static let ambiguousChars: Set<Character> = ["0", "O", "o", "1", "l", "I", "|"]

    /// Build the candidate character pool from the option toggles.
    /// Exposed for tests + for the entropy calculator in the view.
    public static func candidatePool(_ options: Options) -> [Character] {
        var pool: [Character] = []
        if options.lowercase { pool.append(contentsOf: lowercaseChars) }
        if options.uppercase { pool.append(contentsOf: uppercaseChars) }
        if options.digits    { pool.append(contentsOf: digitChars) }
        if options.symbols   { pool.append(contentsOf: symbolChars) }
        if options.excludeAmbiguous {
            pool.removeAll(where: { ambiguousChars.contains($0) })
        }
        return pool
    }

    /// Generate a password that respects the options. Throws if the
    /// length is out of range or no charsets are selected.
    public static func generate(_ options: Options) throws -> String {
        guard options.length >= minLength, options.length <= maxLength else {
            throw GenerationError.lengthOutOfRange(options.length)
        }
        let pool = candidatePool(options)
        guard !pool.isEmpty else { throw GenerationError.noCharsetsSelected }

        var rng = SystemRandomNumberGenerator()
        var result = String()
        result.reserveCapacity(options.length)
        for _ in 0..<options.length {
            // randomElement(using:) draws uniformly from the pool.
            // SystemRandomNumberGenerator is cryptographically secure
            // on Apple platforms (backed by SecRandomCopyBytes).
            let ch = pool.randomElement(using: &rng)!
            result.append(ch)
        }
        return result
    }

    /// Shannon entropy of a password of the given length drawn from
    /// the given options' pool. Used to display a strength estimate
    /// in the view. Returns 0 if the pool is empty.
    public static func entropyBits(_ options: Options) -> Double {
        let poolSize = candidatePool(options).count
        guard poolSize > 0 else { return 0 }
        return Double(options.length) * log2(Double(poolSize))
    }
}
