import Foundation

public struct SSHConfigHost: Hashable, Sendable, Identifiable {
    public let alias: String
    public let hostName: String?
    public let proxyJump: String?
    public let user: String?

    public var id: String { alias }

    public init(alias: String, hostName: String? = nil, proxyJump: String? = nil, user: String? = nil) {
        self.alias = alias
        self.hostName = hostName
        self.proxyJump = proxyJump
        self.user = user
    }
}

/// Minimal `~/.ssh/config` parser. Returns the list of named Host blocks,
/// skipping wildcard entries. Supports `Include` directives with tilde
/// expansion. Keyword matching is case-insensitive. Missing or unreadable
/// files return an empty list — never throws.
public enum SSHConfigParser {
    public static func hosts(at path: URL = defaultPath()) -> [SSHConfigHost] {
        var seen = Set<String>()
        var visited = Set<String>()
        var out: [SSHConfigHost] = []
        parse(path: path, visited: &visited, seen: &seen, out: &out)
        return out.sorted { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
    }

    public static func defaultPath() -> URL {
        let home = NSHomeDirectory() as NSString
        return URL(fileURLWithPath: home.appendingPathComponent(".ssh/config"))
    }

    private static func parse(
        path: URL,
        visited: inout Set<String>,
        seen: inout Set<String>,
        out: inout [SSHConfigHost]
    ) {
        let resolved = path.resolvingSymlinksInPath().standardizedFileURL.path
        if visited.contains(resolved) { return }
        visited.insert(resolved)

        guard let data = try? Data(contentsOf: path),
              let text = String(data: data, encoding: .utf8) else {
            return
        }

        var currentAliases: [String] = []
        var hostName: String?
        var proxyJump: String?
        var user: String?

        func flushCurrent() {
            for alias in currentAliases where !alias.isEmpty && !isWildcard(alias) {
                if seen.insert(alias).inserted {
                    out.append(SSHConfigHost(
                        alias: alias,
                        hostName: hostName,
                        proxyJump: proxyJump,
                        user: user
                    ))
                }
            }
            currentAliases = []
            hostName = nil
            proxyJump = nil
            user = nil
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            // Split on whitespace or `=`.
            let parts = splitKeyValue(line)
            guard parts.count >= 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1]

            switch key {
            case "host":
                flushCurrent()
                currentAliases = value
                    .components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
            case "hostname":
                hostName = value
            case "proxyjump":
                proxyJump = value
            case "user":
                user = value
            case "include":
                // Flush whatever was in progress before recursing.
                flushCurrent()
                for includePath in expandIncludePaths(value) {
                    parse(path: includePath, visited: &visited, seen: &seen, out: &out)
                }
            default:
                break
            }
        }
        flushCurrent()
    }

    /// Splits a config line into a 2-element [key, value]. OpenSSH accepts
    /// either whitespace or `=` as the separator, with optional surrounding
    /// whitespace.
    private static func splitKeyValue(_ line: String) -> [String] {
        if let eqIdx = line.firstIndex(of: "=") {
            let key = String(line[..<eqIdx]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty && !key.contains(" ") {
                return [key, value]
            }
        }
        if let spaceIdx = line.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            let key = String(line[..<spaceIdx])
            let value = String(line[line.index(after: spaceIdx)...]).trimmingCharacters(in: .whitespaces)
            return [key, value]
        }
        return [line]
    }

    private static func isWildcard(_ alias: String) -> Bool {
        alias.contains("*") || alias.contains("?") || alias.contains("!")
    }

    /// Resolves an `Include` value into concrete file URLs. Supports tilde
    /// expansion and space-separated multiple paths. Does not expand globs —
    /// globs are rare in hand-written configs and add complexity.
    private static func expandIncludePaths(_ raw: String) -> [URL] {
        let home = NSHomeDirectory()
        let pieces = raw.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        return pieces.map { piece -> URL in
            let expanded: String
            if piece.hasPrefix("~/") {
                expanded = home + String(piece.dropFirst(1))
            } else if piece.hasPrefix("/") {
                expanded = piece
            } else {
                // Relative to ~/.ssh per ssh_config(5).
                expanded = home + "/.ssh/" + piece
            }
            return URL(fileURLWithPath: expanded)
        }
    }
}
