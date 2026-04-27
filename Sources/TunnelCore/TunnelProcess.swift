import Foundation
import os

public enum TunnelEvent: Equatable, Sendable {
    case connecting
    case connected
    case authExpired(String)
    case failed(String)
    case stopped
}

/// Wraps a single tunnel subprocess. Provider-specific behavior lives in a
/// `TunnelLauncher` implementation; this class owns the Process lifecycle,
/// stderr parsing, and event emission.
public final class TunnelProcess: @unchecked Sendable {
    public let tunnel: Tunnel
    public let launcher: any TunnelLauncher

    private var process: Process?
    private var stderrBuffer: [String] = []
    private let log = Logger(subsystem: "com.fourninecloud.cloud-tunnels", category: "tunnel")
    private var intentionallyStopped = false

    public init(tunnel: Tunnel, launcher: any TunnelLauncher) {
        self.tunnel = tunnel
        self.launcher = launcher
    }

    /// Launches the subprocess and returns an AsyncStream of events.
    public func start() -> AsyncStream<TunnelEvent> {
        AsyncStream { continuation in
            PortUtil.killHolders(ofPort: tunnel.localPort)

            let executableURL: URL
            let args: [String]
            do {
                executableURL = try launcher.executableURL(for: tunnel)
                args = try launcher.arguments(for: tunnel)
            } catch {
                continuation.yield(.failed(error.localizedDescription))
                continuation.finish()
                return
            }

            let proc = Process()
            proc.executableURL = executableURL
            proc.arguments = args
            // Always build an explicit environment so tool processes (gcloud, aws, etc.)
            // get a full PATH. macOS app bundles start with a minimal PATH
            // (/usr/bin:/bin:/usr/sbin:/sbin) which causes tools to pick up the wrong
            // Python/runtime and miss Homebrew/SDK binaries entirely.
            var env = ProcessInfo.processInfo.environment
            let toolPaths = [
                "/usr/local/bin",
                "/opt/homebrew/bin",
                "/opt/homebrew/sbin",
                (NSHomeDirectory() as NSString).appendingPathComponent("google-cloud-sdk/bin"),
                (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin"),
            ]
            let existing = Set((env["PATH"] ?? "").split(separator: ":").map(String.init))
            let missing = toolPaths.filter { !existing.contains($0) }
            if !missing.isEmpty {
                let base = env["PATH"] ?? ""
                env["PATH"] = (missing + [base]).filter { !$0.isEmpty }.joined(separator: ":")
            }
            if let extra = launcher.environment(for: tunnel) {
                for (k, v) in extra { env[k] = v }
            }
            proc.environment = env
            let stderrPipe = Pipe()
            proc.standardOutput = Pipe()
            proc.standardError = stderrPipe

            do {
                try proc.run()
            } catch {
                continuation.yield(.failed("launch failed: \(error.localizedDescription)"))
                continuation.finish()
                return
            }

            self.process = proc
            continuation.yield(.connecting)
            log.info("tunnel \(self.tunnel.name, privacy: .public) started via \(self.launcher.providerName, privacy: .public)")

            // Fallback: promote to connected after N seconds if still running
            let fallbackWorkItem = DispatchWorkItem { [weak self] in
                guard let self, let p = self.process, p.isRunning else { return }
                continuation.yield(.connected)
                self.log.info("tunnel \(self.tunnel.name, privacy: .public) connected via fallback timer")
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + launcher.fallbackConnectedSeconds,
                execute: fallbackWorkItem
            )

            // Drain stderr on a background queue
            DispatchQueue.global().async { [weak self] in
                guard let self else { return }
                let handle = stderrPipe.fileHandleForReading
                var pending = Data()
                while proc.isRunning {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    pending.append(chunk)
                    while let nl = pending.firstIndex(of: 0x0a) {
                        let lineData = pending.subdata(in: 0..<nl)
                        pending.removeSubrange(0...nl)
                        if let line = String(data: lineData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                            self.handleStderrLine(line, continuation: continuation)
                        }
                    }
                }
                let rest = handle.readDataToEndOfFile()
                if !rest.isEmpty, let s = String(data: rest, encoding: .utf8) {
                    for line in s.split(whereSeparator: \.isNewline) {
                        self.handleStderrLine(String(line), continuation: continuation)
                    }
                }

                proc.waitUntilExit()
                fallbackWorkItem.cancel()
                self.handleExit(exitCode: proc.terminationStatus, continuation: continuation)
                continuation.finish()
            }
        }
    }

    public func stop() {
        intentionallyStopped = true
        guard let proc = process, proc.isRunning else { return }
        proc.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
        }
    }

    private func handleStderrLine(_ line: String, continuation: AsyncStream<TunnelEvent>.Continuation) {
        stderrBuffer.append(line)
        if stderrBuffer.count > 50 { stderrBuffer.removeFirst(stderrBuffer.count - 50) }
        if launcher.isListening(line) {
            continuation.yield(.connected)
            log.info("tunnel \(self.tunnel.name, privacy: .public) connected (stderr marker)")
        }
    }

    private func handleExit(exitCode: Int32, continuation: AsyncStream<TunnelEvent>.Continuation) {
        if intentionallyStopped {
            continuation.yield(.stopped)
            return
        }
        let tail = stderrBuffer.suffix(5).joined(separator: "\n")
        let error = tail.isEmpty ? "Exit code: \(exitCode)" : tail
        if launcher.isAuthExpired(error) {
            continuation.yield(.authExpired(error))
        } else {
            continuation.yield(.failed(error))
        }
    }
}
