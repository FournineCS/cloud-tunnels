import Foundation

/// Stdout/stderr helpers. Use `out` for human-readable results,
/// `err` for diagnostics that should not be parsed by callers.
enum Output {
    static func out(_ s: String) {
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
    }

    static func err(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }

    /// Pads `s` to width `w` with trailing spaces (no truncation).
    static func pad(_ s: String, _ w: Int) -> String {
        if s.count >= w { return s }
        return s + String(repeating: " ", count: w - s.count)
    }
}
