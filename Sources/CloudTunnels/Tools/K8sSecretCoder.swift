import Foundation

/// Base64 encode / decode specialized for Kubernetes Secret YAML.
/// Small wrapper on top of Foundation's base64 that also produces
/// (and consumes) the `kind: Secret` YAML snippet users paste into
/// their manifests. No YAML parser dependency — we do a narrow
/// line-scan of the `data:` block.
public enum K8sSecretCoder {

    /// Encode a plain-text value as base64 and emit a complete,
    /// ready-to-paste Secret YAML snippet. The generated snippet
    /// is minimal — no metadata.labels, no immutable, no type
    /// override — so users can layer those in themselves.
    public static func encodeAsSecretYAML(value: String, name: String, key: String) -> String {
        let base64 = Data(value.utf8).base64EncodedString()
        let sanitizedName = name.isEmpty ? "my-secret" : name
        let sanitizedKey = key.isEmpty ? "key" : key
        return """
        apiVersion: v1
        kind: Secret
        metadata:
          name: \(sanitizedName)
        type: Opaque
        data:
          \(sanitizedKey): \(base64)
        """
    }

    /// Parsed decoded entry from a Secret YAML snippet.
    public struct DecodedEntry: Equatable, Identifiable {
        public var id: String { key }
        public var key: String
        /// UTF-8 decoded value if the bytes are valid UTF-8,
        /// otherwise nil and `rawBase64` is what we received.
        public var value: String?
        public var rawBase64: String
    }

    /// Decode every key/value pair inside the `data:` block of a
    /// k8s Secret YAML. Returns nil if the input has no `data:`
    /// section at all; returns an empty array if `data:` is
    /// present but empty. Ignores `stringData:` deliberately —
    /// that block isn't base64-encoded by definition, so there's
    /// nothing to decode.
    public static func decodeSecretYAML(_ yaml: String) -> [DecodedEntry]? {
        let lines = yaml.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
            .map(String.init)

        // Find the `data:` line at any indentation level (not
        // inside a `stringData:` or `metadata:` section).
        var dataLineIdx: Int? = nil
        var dataIndent = 0
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "data:" {
                dataLineIdx = i
                dataIndent = leadingSpaces(line)
                break
            }
        }
        guard let startIdx = dataLineIdx else { return nil }

        // Walk subsequent lines with indentation greater than
        // `dataIndent` and parse them as `key: base64` pairs.
        // Stop at the first line whose indentation is <= dataIndent
        // and is non-empty (that's the next top-level field).
        var entries: [DecodedEntry] = []
        var i = startIdx + 1
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = leadingSpaces(line)
            if trimmed.isEmpty {
                i += 1
                continue
            }
            if trimmed.hasPrefix("#") {
                i += 1
                continue
            }
            if indent <= dataIndent {
                break // out of the data: block
            }
            if let entry = parseDataLine(trimmed) {
                entries.append(entry)
            }
            i += 1
        }
        return entries
    }

    // MARK: - Pure line parsing

    /// Count the leading space (0x20) characters in a line. Tabs
    /// are treated as 1 each — users shouldn't use tabs in YAML,
    /// but we don't want to crash if they do.
    static func leadingSpaces(_ line: String) -> Int {
        var count = 0
        for ch in line {
            if ch == " " || ch == "\t" {
                count += 1
            } else {
                break
            }
        }
        return count
    }

    /// Parse a single `key: base64` line from a Secret `data:`
    /// block. Rejects lines with no colon or empty keys. Values
    /// are stripped of surrounding quotes because yaml allows
    /// (but doesn't require) them on base64 strings.
    static func parseDataLine(_ line: String) -> DecodedEntry? {
        guard let colonIdx = line.firstIndex(of: ":") else { return nil }
        let rawKey = line[..<colonIdx].trimmingCharacters(in: .whitespaces)
        guard !rawKey.isEmpty else { return nil }
        var rawValue = line[line.index(after: colonIdx)...]
            .trimmingCharacters(in: .whitespaces)
        // Strip YAML's optional single/double quotes around the
        // value. YAML allows `key: "base64"` and `key: 'base64'`
        // as well as the bare form.
        if (rawValue.hasPrefix("\"") && rawValue.hasSuffix("\"")) ||
           (rawValue.hasPrefix("'") && rawValue.hasSuffix("'")) {
            rawValue = String(rawValue.dropFirst().dropLast())
        }
        // base64 decode; if it fails, surface the raw so the UI
        // can still show something useful.
        if let data = Data(base64Encoded: rawValue) {
            let decoded = String(data: data, encoding: .utf8)
            return DecodedEntry(key: rawKey, value: decoded, rawBase64: rawValue)
        }
        return DecodedEntry(key: rawKey, value: nil, rawBase64: rawValue)
    }
}
