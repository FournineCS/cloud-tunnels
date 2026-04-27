import ArgumentParser
import Foundation
import TunnelCore

struct StartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start a tunnel by name. Foreground by default; ⌃C to stop."
    )

    @Argument(help: "Tunnel name (case-insensitive; substring match if unique).")
    var name: String

    @Flag(name: [.short, .long], help: "Run in the background and write a PID file.")
    var detach: Bool = false

    func run() throws {
        let config = ConfigStore.shared.load()
        guard let tunnel = TunnelLookup.find(name: name, in: config.tunnels) else {
            Output.err(TunnelLookup.errorMessage(name: name, tunnels: config.tunnels))
            throw ExitCode(1)
        }

        if let existing = PidFile.read(for: tunnel.name), PidFile.isAlive(pid: existing.pid) {
            Output.err("Tunnel '\(tunnel.name)' is already running (pid \(existing.pid)). Use `ctun stop \(tunnel.name)`.")
            throw ExitCode(1)
        }

        // Local HTTPS proxy is opt-in per tunnel and lives in the GUI's
        // privileged helper. The CLI doesn't drive the helper in v1, so
        // warn the user that they're getting the SSM tunnel only — no
        // 443 listener, no /etc/hosts management.
        if case .awsSSM(let cfg) = tunnel.provider, cfg.localProxy != nil {
            Output.err("warning: Tunnel '\(tunnel.name)' has a Local HTTPS proxy configured, but `ctun` does not activate it. Use the menu-bar app to get the proxy listener and /etc/hosts entries.")
        }

        if detach {
            try runDetached(tunnel: tunnel)
            return
        }

        let runner = CLIRunner(tunnel: tunnel)
        let exit = waitForRunner(runner)
        if exit != 0 {
            throw ExitCode(exit)
        }
    }

    /// Re-execs the current binary with `--__detached` so the child runs the
    /// foreground loop while the parent returns immediately. The child writes
    /// the PID file once it gets `connected`.
    private func runDetached(tunnel: Tunnel) throws {
        let exec = URL(fileURLWithPath: CommandLine.arguments[0])
        let resolved = exec.path.hasPrefix("/")
            ? exec
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(exec.path)

        let proc = Process()
        proc.executableURL = resolved
        proc.arguments = ["__run-detached", tunnel.name]

        let logDir = ConfigStore.shared.configDirectoryURL.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logURL = logDir.appendingPathComponent("\(safeName(tunnel.name)).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        proc.standardOutput = logHandle
        proc.standardError = logHandle

        try proc.run()

        // Give the child a moment to write its PID file before we return.
        let deadline = Date().addingTimeInterval(2.0)
        var entry: PidFile.Entry?
        while Date() < deadline {
            if let e = PidFile.read(for: tunnel.name) {
                entry = e
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        if let entry {
            Output.out("→ tunnel '\(tunnel.name)' started in background (pid \(entry.pid), log \(logURL.path))")
        } else {
            Output.out("→ tunnel '\(tunnel.name)' launched (pid \(proc.processIdentifier), log \(logURL.path))")
        }
    }

    private func waitForRunner(_ runner: CLIRunner) -> Int32 {
        let sem = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0
        Task.detached {
            exitCode = await runner.runForeground()
            sem.signal()
        }
        sem.wait()
        return exitCode
    }

    private func safeName(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }
}

/// Internal subcommand used by --detach. Hidden from --help.
struct RunDetachedCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__run-detached",
        abstract: "Internal: run a tunnel as a detached child.",
        shouldDisplay: false
    )

    @Argument var name: String

    func run() throws {
        let config = ConfigStore.shared.load()
        guard let tunnel = TunnelLookup.find(name: name, in: config.tunnels) else {
            throw ExitCode(1)
        }
        try? PidFile.write(
            pid: ProcessInfo.processInfo.processIdentifier,
            port: tunnel.localPort,
            tunnelName: tunnel.name
        )
        let runner = CLIRunner(tunnel: tunnel)
        let sem = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0
        Task.detached {
            exitCode = await runner.runForeground()
            sem.signal()
        }
        sem.wait()
        PidFile.remove(for: tunnel.name)
        if exitCode != 0 {
            throw ExitCode(exitCode)
        }
    }
}
