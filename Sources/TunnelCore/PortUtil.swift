import Darwin
import Foundation

public enum PortUtil {
    /// Returns true if `port` can currently be bound on 127.0.0.1. Used by
    /// the Add-tunnel form to pick a default SOCKS/forward port that won't
    /// conflict with anything already listening locally.
    public static func isPortFree(_ port: Int) -> Bool {
        guard port > 0 && port < 65536 else { return false }
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        if sock < 0 { return false }
        defer { _ = close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        addr.sin_addr.s_addr = in_addr_t(0x7f000001).bigEndian  // 127.0.0.1
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return rc == 0
    }

    /// Walks upward from `base` looking for a port that is both (a) not in
    /// the `excluding` set and (b) not currently bound on 127.0.0.1. Falls
    /// back to `base` if nothing free is found in the search window.
    public static func firstFreeLocalPort(
        startingAt base: Int,
        excluding: Set<Int> = [],
        window: Int = 200
    ) -> Int {
        let upper = min(base + window, 65535)
        for p in base...upper where !excluding.contains(p) {
            if isPortFree(p) { return p }
        }
        return base
    }

    /// Kills any process holding the given local port. Mirrors tunnel_manager.py:_kill_port_holders.
    public static func killHolders(ofPort port: Int) {
        let proc = Process()
        proc.launchPath = "/usr/sbin/lsof"
        proc.arguments = ["-ti", ":\(port)"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch { return }
        let deadline = Date().addingTimeInterval(5)
        while proc.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if proc.isRunning { proc.terminate(); return }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        let pids = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .compactMap { Int($0) }
        let selfPid = Int(ProcessInfo.processInfo.processIdentifier)
        var killed = false
        for pid in pids where pid != selfPid {
            kill(pid_t(pid), SIGTERM)
            killed = true
        }
        if killed { Thread.sleep(forTimeInterval: 1) }
    }

    /// Returns the PIDs holding the given local port (excluding the current process).
    public static func holders(ofPort port: Int) -> [Int] {
        let proc = Process()
        proc.launchPath = "/usr/sbin/lsof"
        proc.arguments = ["-ti", ":\(port)"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return [] }
        let deadline = Date().addingTimeInterval(5)
        while proc.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if proc.isRunning { proc.terminate(); return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        let selfPid = Int(ProcessInfo.processInfo.processIdentifier)
        return text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .compactMap { Int($0) }
            .filter { $0 != selfPid }
    }
}
