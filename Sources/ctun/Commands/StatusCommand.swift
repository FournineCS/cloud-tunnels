import ArgumentParser
import Foundation
import TunnelCore

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show status of one or all tunnels."
    )

    @Argument(help: "Tunnel name (case-insensitive). Omit to list all.")
    var name: String?

    func run() throws {
        let config = ConfigStore.shared.load()
        let targets: [Tunnel]
        if let name {
            guard let tunnel = TunnelLookup.find(name: name, in: config.tunnels) else {
                Output.err(TunnelLookup.errorMessage(name: name, tunnels: config.tunnels))
                throw ExitCode(1)
            }
            targets = [tunnel]
        } else {
            targets = config.tunnels.sorted { $0.name.lowercased() < $1.name.lowercased() }
        }

        if targets.isEmpty {
            Output.err("No tunnels configured.")
            return
        }

        let nameW = max(4, (targets.map(\.name.count).max() ?? 4) + 2)
        let stateW = 12
        let pidW = 8
        Output.out(
            Output.pad("NAME", nameW)
            + Output.pad("STATE", stateW)
            + Output.pad("PID", pidW)
            + "PORT"
        )
        for t in targets {
            let entry = PidFile.read(for: t.name)
            let state: String
            let pidStr: String
            if let entry, PidFile.isAlive(pid: entry.pid) {
                state = "running"
                pidStr = String(entry.pid)
            } else if entry != nil {
                state = "stale"
                pidStr = "-"
            } else if !PortUtil.holders(ofPort: t.localPort).isEmpty {
                state = "port-in-use"
                pidStr = "-"
            } else {
                state = "stopped"
                pidStr = "-"
            }
            Output.out(
                Output.pad(t.name, nameW)
                + Output.pad(state, stateW)
                + Output.pad(pidStr, pidW)
                + String(t.localPort)
            )
        }
    }
}
