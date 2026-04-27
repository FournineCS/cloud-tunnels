import Foundation
import TunnelCore

/// Per-tunnel PID files for `--detach` mode. Lives next to config.json so
/// CLI and GUI agree on the directory layout.
///
///   ~/Library/Application Support/CloudTunnels/run/<safe-name>.pid
///
/// File format: one line, "<pid>\t<localPort>\t<original tunnel name>\n"
enum PidFile {
    static func directoryURL(store: ConfigStore = .shared) -> URL {
        store.configDirectoryURL.appendingPathComponent("run", isDirectory: true)
    }

    static func url(for tunnelName: String, store: ConfigStore = .shared) -> URL {
        directoryURL(store: store).appendingPathComponent("\(safeName(tunnelName)).pid")
    }

    static func write(pid: Int32, port: Int, tunnelName: String, store: ConfigStore = .shared) throws {
        let dir = directoryURL(store: store)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = "\(pid)\t\(port)\t\(tunnelName)\n"
        try line.write(to: url(for: tunnelName, store: store), atomically: true, encoding: .utf8)
    }

    struct Entry {
        let pid: pid_t
        let port: Int
        let tunnelName: String
    }

    static func read(for tunnelName: String, store: ConfigStore = .shared) -> Entry? {
        let path = url(for: tunnelName, store: store)
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t")
        guard parts.count >= 3, let pid = Int32(parts[0]), let port = Int(parts[1]) else { return nil }
        let name = parts[2...].joined(separator: "\t")
        return Entry(pid: pid, port: port, tunnelName: name)
    }

    static func remove(for tunnelName: String, store: ConfigStore = .shared) {
        try? FileManager.default.removeItem(at: url(for: tunnelName, store: store))
    }

    /// True iff the recorded pid is currently alive.
    static func isAlive(pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    private static func safeName(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }
}
