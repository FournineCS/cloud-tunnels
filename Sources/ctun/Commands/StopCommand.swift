import ArgumentParser
import Foundation
import TunnelCore

struct StopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop a detached tunnel by name."
    )

    @Argument(help: "Tunnel name (case-insensitive; substring match if unique).")
    var name: String

    @Flag(name: .long, help: "Force-kill (SIGKILL) instead of SIGTERM.")
    var force: Bool = false

    func run() throws {
        let config = ConfigStore.shared.load()
        guard let tunnel = TunnelLookup.find(name: name, in: config.tunnels) else {
            Output.err(TunnelLookup.errorMessage(name: name, tunnels: config.tunnels))
            throw ExitCode(1)
        }

        // Path 1: ctun-detached tunnel — PID file present.
        if let entry = PidFile.read(for: tunnel.name) {
            if !PidFile.isAlive(pid: entry.pid) {
                PidFile.remove(for: tunnel.name)
                Output.err("Tunnel '\(tunnel.name)' is not running. Removed stale PID file.")
                return
            }
            try terminate(pids: [entry.pid], force: force)
            PidFile.remove(for: tunnel.name)
            Output.out("✓ stopped '\(tunnel.name)' (was pid \(entry.pid))")
            return
        }

        // Path 2: tunnel started by the GUI app or another shell.
        // Bail early if nothing is on the port.
        guard !PortUtil.holders(ofPort: tunnel.localPort).isEmpty else {
            Output.err("Tunnel '\(tunnel.name)' is not running (nothing on port \(tunnel.localPort)).")
            throw ExitCode(1)
        }

        // Ask any running GUI instance to disconnect cleanly first. This
        // suppresses TunnelManager's auto-reconnect, which would otherwise
        // race ctun and re-bind the same port within ~10s.
        IPCNotifications.postStopRequest(tunnelID: tunnel.id)

        // Poll up to 3s for the GUI to release the port.
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            if PortUtil.holders(ofPort: tunnel.localPort).isEmpty {
                Output.out("✓ stopped '\(tunnel.name)' on port \(tunnel.localPort) (handled by GUI)")
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        // GUI not running, not listening, or non-cooperative — direct kill.
        let stillHolding = PortUtil.holders(ofPort: tunnel.localPort).map { pid_t($0) }
        guard !stillHolding.isEmpty else {
            Output.out("✓ stopped '\(tunnel.name)'")
            return
        }
        try terminate(pids: stillHolding, force: force)
        let pidList = stillHolding.map(String.init).joined(separator: ", ")
        Output.out("✓ stopped '\(tunnel.name)' on port \(tunnel.localPort) (forced; pid \(pidList))")
    }

    /// Sends SIGTERM (or SIGKILL with --force) to each pid, then escalates
    /// to SIGKILL after a 3s grace period for any survivors.
    private func terminate(pids: [pid_t], force: Bool) throws {
        let sig: Int32 = force ? SIGKILL : SIGTERM
        var anySent = false
        for pid in pids {
            if kill(pid, sig) == 0 {
                anySent = true
            } else {
                Output.err("Failed to send signal \(sig) to pid \(pid).")
            }
        }
        guard anySent else { throw ExitCode(2) }

        if force { return }

        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline && pids.contains(where: { PidFile.isAlive(pid: $0) }) {
            Thread.sleep(forTimeInterval: 0.1)
        }
        for pid in pids where PidFile.isAlive(pid: pid) {
            Output.err("pid \(pid) did not exit after SIGTERM; sending SIGKILL.")
            _ = kill(pid, SIGKILL)
        }
    }
}
