import Foundation

struct PortListener: Identifiable, Equatable {
    let pid: Int
    let processName: String
    let user: String
    var id: Int { pid }
}

enum PortLookup {
    /// Returns processes listening on the given TCP port. Empty if none.
    static func listeners(onPort port: Int) -> [PortListener] {
        let proc = Process()
        proc.launchPath = "/usr/sbin/lsof"
        proc.arguments = [
            "-iTCP:\(port)",
            "-sTCP:LISTEN",
            "-P", "-n",
            "-F", "pcLn",   // pid, command, login, name (one field per line, prefixed)
        ]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return [] }
        proc.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return parseLsofF(text)
    }

    /// Sends SIGTERM (then SIGKILL after 1s) to the given pid.
    static func kill(pid: Int) {
        Foundation.kill(pid_t(pid), SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            // best-effort follow-up
            Foundation.kill(pid_t(pid), SIGKILL)
        }
    }

    /// Parses `lsof -F pcLn` output. Each record is a series of lines starting
    /// with a field-type letter: p=pid, c=command, L=login, n=name.
    static func parseLsofF(_ text: String) -> [PortListener] {
        var result: [PortListener] = []
        var pid: Int?
        var command: String?
        var user: String?
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            guard let prefix = line.first else { continue }
            let value = String(line.dropFirst())
            switch prefix {
            case "p":
                if let oldPid = pid {
                    result.append(PortListener(
                        pid: oldPid,
                        processName: command ?? "(unknown)",
                        user: user ?? "(unknown)"
                    ))
                }
                pid = Int(value)
                command = nil
                user = nil
            case "c":
                command = value
            case "L":
                user = value
            default:
                break
            }
        }
        if let pid {
            result.append(PortListener(
                pid: pid,
                processName: command ?? "(unknown)",
                user: user ?? "(unknown)"
            ))
        }
        // Dedup by pid (lsof can repeat the same pid for IPv4+IPv6)
        var seen: Set<Int> = []
        return result.filter { seen.insert($0.pid).inserted }
    }
}
