import Foundation

/// Pure /etc/hosts parser and mutator. The actual file IO is split out into
/// `HostsFileWriter` below so this type can be exhaustively unit-tested
/// against in-memory strings — no privileged file access in tests.
///
/// Every line CloudTunnels writes ends with a trailing tag comment of the
/// shape `# CloudTunnels:<uuid>`. Any line without that marker is foreign
/// (user-authored, another tool, system defaults) and is *never* touched.
public struct HostsFile: Sendable {
    /// Marker prefix appended to every managed line. The full marker is
    /// `# CloudTunnels:<lowercase-uuid>`.
    public static let markerPrefix = "# CloudTunnels:"

    public var content: String

    public init(content: String) {
        self.content = content
    }

    // MARK: - Pure mutations

    /// Append a managed line for `(tunnelID, hostname)`. Idempotent: any
    /// existing CloudTunnels-tagged line for the same hostname is removed
    /// first so reconnecting (possibly with a different tunnel UUID after a
    /// crash) self-heals into a single canonical entry. Foreign lines for
    /// the same hostname are left in place — we do not touch what we don't
    /// own.
    public func appending(tunnelID: UUID, hostname: String) -> HostsFile {
        let withoutOurs = removingManagedLines(matchingHostname: hostname)
        let line = Self.formatLine(tunnelID: tunnelID, hostname: hostname)
        var next = withoutOurs.content
        if !next.isEmpty && !next.hasSuffix("\n") {
            next.append("\n")
        }
        next.append(line)
        next.append("\n")
        return HostsFile(content: next)
    }

    /// Remove every line tagged with the given tunnel UUID. Foreign lines
    /// are untouched.
    public func removingLines(taggedWith tunnelID: UUID) -> HostsFile {
        let needle = Self.markerPrefix + tunnelID.uuidString.lowercased()
        let kept = lines().filter { line in
            !line.lowercased().contains(needle.lowercased())
        }
        return HostsFile(content: kept.joined(separator: "\n").appendingTrailingNewlineIfNeeded())
    }

    /// Remove every CloudTunnels-tagged line, regardless of UUID. Used by
    /// `uninstall` to leave /etc/hosts pristine.
    public func removingAllManagedLines() -> HostsFile {
        let kept = lines().filter { line in
            !line.contains(Self.markerPrefix)
        }
        return HostsFile(content: kept.joined(separator: "\n").appendingTrailingNewlineIfNeeded())
    }

    // MARK: - Queries

    /// Returns true if a CloudTunnels-tagged line exists for `hostname`,
    /// regardless of which tunnel UUID owns it.
    public func containsManagedHost(_ hostname: String) -> Bool {
        let host = hostname.lowercased()
        return lines().contains { line in
            line.contains(Self.markerPrefix) && tokens(of: line).contains(host)
        }
    }

    /// Returns the set of `(tunnelID, hostname)` pairs currently managed.
    /// Used by tests and diagnostics.
    public func managedEntries() -> [(tunnelID: UUID, hostname: String)] {
        var out: [(UUID, String)] = []
        for line in lines() where line.contains(Self.markerPrefix) {
            guard
                let id = Self.parseTunnelID(from: line),
                let host = Self.parseHostname(from: line)
            else { continue }
            out.append((id, host))
        }
        return out
    }

    // MARK: - Formatting

    /// Canonical line shape, used by `appending` and asserted in tests.
    public static func formatLine(tunnelID: UUID, hostname: String) -> String {
        "127.0.0.1\t\(hostname)\t\(markerPrefix)\(tunnelID.uuidString.lowercased())"
    }

    // MARK: - Internals

    private func removingManagedLines(matchingHostname hostname: String) -> HostsFile {
        let host = hostname.lowercased()
        let kept = lines().filter { line in
            if !line.contains(Self.markerPrefix) { return true }
            return !tokens(of: line).contains(host)
        }
        return HostsFile(content: kept.joined(separator: "\n").appendingTrailingNewlineIfNeeded())
    }

    private func lines() -> [String] {
        // Splitting with `omittingEmptySubsequences: false` preserves blank
        // lines so we don't collapse the user's formatting on every write.
        content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private func tokens(of line: String) -> [String] {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { $0.lowercased() }
    }

    private static func parseTunnelID(from line: String) -> UUID? {
        guard let range = line.range(of: markerPrefix) else { return nil }
        let tail = line[range.upperBound...]
        let id = tail.prefix { ch in
            ch.isHexDigit || ch == "-"
        }
        return UUID(uuidString: String(id))
    }

    private static func parseHostname(from line: String) -> String? {
        // Format: `127.0.0.1<ws>hostname<ws># CloudTunnels:<uuid>`.
        // Splitting on whitespace yields ["127.0.0.1", "<host>", "#", "CloudTunnels:<uuid>"].
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 2 else { return nil }
        return String(parts[1])
    }
}

private extension String {
    /// Adds a single trailing `\n` unless the string is empty or already
    /// ends with one. Keeps /etc/hosts well-formed across mutations.
    func appendingTrailingNewlineIfNeeded() -> String {
        if isEmpty { return self }
        if hasSuffix("\n") { return self }
        return self + "\n"
    }
}

// MARK: - Side-effecting writer

/// Reads /etc/hosts, applies a pure `HostsFile` mutation, and atomically
/// writes the result back. Atomic = write to a temp file in /etc, then
/// rename(2) over the original so concurrent readers never see partial
/// content. Only the helper daemon (running as root) can use this.
public struct HostsFileWriter: Sendable {
    public static let path = "/etc/hosts"

    public init() {}

    public func appending(tunnelID: UUID, hostname: String) throws {
        try mutate { $0.appending(tunnelID: tunnelID, hostname: hostname) }
    }

    public func removingLines(taggedWith tunnelID: UUID) throws {
        try mutate { $0.removingLines(taggedWith: tunnelID) }
    }

    public func removingAllManagedLines() throws {
        try mutate { $0.removingAllManagedLines() }
    }

    public func read() throws -> HostsFile {
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.path))
        return HostsFile(content: String(decoding: data, as: UTF8.self))
    }

    private func mutate(_ transform: (HostsFile) -> HostsFile) throws {
        let current = try read()
        let next = transform(current)
        if next.content == current.content { return }
        try write(next.content)
    }

    private func write(_ content: String) throws {
        let dir = (Self.path as NSString).deletingLastPathComponent
        let tempName = ".hosts.cloudtunnels.\(UUID().uuidString)"
        let tempPath = (dir as NSString).appendingPathComponent(tempName)
        let tempURL = URL(fileURLWithPath: tempPath)
        try Data(content.utf8).write(to: tempURL, options: .atomic)

        // Mirror /etc/hosts's permissions (0644 root:wheel) so the rename
        // doesn't surprise any tools that re-read the file by stat.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o644))],
            ofItemAtPath: tempPath
        )

        // rename(2) is atomic on the same filesystem, which /etc/hosts
        // and our temp file always share.
        let renameResult = rename(tempPath, Self.path)
        if renameResult != 0 {
            let err = errno
            try? FileManager.default.removeItem(atPath: tempPath)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(err),
                userInfo: [NSLocalizedDescriptionKey: "rename(\(tempPath) → \(Self.path)) failed: \(String(cString: strerror(err)))"]
            )
        }
    }
}
