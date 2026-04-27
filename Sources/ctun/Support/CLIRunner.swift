import Dispatch
import Foundation
import TunnelCore

/// Headless replacement for `TunnelManager`. Owns one `TunnelProcess`,
/// streams its events to stdout, and stops cleanly on SIGINT/SIGTERM.
final class CLIRunner: @unchecked Sendable {
    private let tunnel: Tunnel
    private let runner: TunnelProcess
    private let exitOnConnect: Bool

    init(tunnel: Tunnel, exitOnConnect: Bool = false) {
        self.tunnel = tunnel
        self.runner = TunnelProcess(tunnel: tunnel, launcher: LauncherFactory.launcher(for: tunnel))
        self.exitOnConnect = exitOnConnect
    }

    /// Foreground run. Blocks the caller until the subprocess exits or a
    /// stop signal arrives. Returns the exit code the CLI should propagate.
    func runForeground() async -> Int32 {
        Output.out("→ starting tunnel '\(tunnel.name)' (\(tunnel.provider.kind.shortTag)) on localhost:\(tunnel.localPort)")

        let stream = runner.start()
        let stopSource = installSignalHandlers()
        defer { stopSource.cancel() }

        var exitCode: Int32 = 0
        for await event in stream {
            switch event {
            case .connecting:
                Output.out("· connecting…")
            case .connected:
                Output.out("✓ connected   localhost:\(tunnel.localPort) → \(tunnel.provider.targetDescription)")
                if exitOnConnect {
                    return 0
                }
            case .authExpired(let msg):
                Output.err("✗ auth expired: \(msg)")
                exitCode = 2
            case .failed(let msg):
                Output.err("✗ failed: \(msg)")
                exitCode = 2
            case .stopped:
                Output.out("· stopped")
            }
        }
        return exitCode
    }

    private func installSignalHandlers() -> DispatchSourceSignal {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let intSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let termSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        let stop: () -> Void = { [weak self] in
            guard let self else { return }
            Output.err("\n· received stop signal, terminating…")
            self.runner.stop()
        }
        intSrc.setEventHandler(handler: stop)
        termSrc.setEventHandler(handler: stop)
        intSrc.resume()
        termSrc.resume()
        return intSrc
    }
}
