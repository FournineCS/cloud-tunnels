import Foundation

/// Shared helpers for locating and invoking the `kubectl` binary
/// from CloudTunnels' Tools layer. Extracted from KubectlContext.swift
/// so the new Kubernetes tools (Kubeconfig Inspector, Cluster Health
/// Checker, etc.) can reuse the binary-search logic and Process
/// wiring without copy-pasting it.
///
/// Everything here is a static function; there's no mutable state
/// and no lifecycle. Individual tool helpers own their own higher-
/// level logic on top of these primitives.
public enum Kubectl {

    /// Hardcoded preferred search paths. `/usr/local/bin/kubectl`
    /// comes first because Homebrew installs there on Intel, the
    /// arm64 path second, then the system default. `findBinary()`
    /// falls through to `/usr/bin/which kubectl` if none of these
    /// exist, which catches tools that put kubectl on a custom path
    /// via shell profile edits.
    public static let searchPaths: [String] = [
        "/usr/local/bin/kubectl",
        "/opt/homebrew/bin/kubectl",
        "/usr/bin/kubectl",
    ]

    /// Full result of running kubectl: stdout, stderr, and exit code.
    /// Used by callers that need to distinguish error modes —
    /// e.g. the Cluster Health Checker needs to tell "server
    /// unreachable" apart from "context does not exist".
    public struct Result {
        public let stdout: String
        public let stderr: String
        public let exitCode: Int32

        public var ok: Bool { exitCode == 0 }

        public init(stdout: String, stderr: String, exitCode: Int32) {
            self.stdout = stdout
            self.stderr = stderr
            self.exitCode = exitCode
        }
    }

    // MARK: - Binary discovery

    /// Resolve the kubectl binary. Preference order:
    ///   1. One of the `searchPaths` (first executable hit wins)
    ///   2. `/usr/bin/which kubectl` (catches custom install locations)
    /// Returns nil if kubectl can't be found anywhere.
    public static func findBinary() -> URL? {
        let fm = FileManager.default
        for path in searchPaths where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // Fallback: ask `which`. This picks up custom installs
        // like /nix/store/..., /Users/foo/bin/kubectl, etc.
        let proc = Process()
        proc.launchPath = "/usr/bin/which"
        proc.arguments = ["kubectl"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    // MARK: - Invocation

    /// Simple run: captures stdout only, returns it as a String
    /// (trimmed of trailing whitespace). Returns empty string on
    /// spawn failure or non-zero exit. Stderr is discarded.
    /// Use `runSync` when you need to distinguish failure modes.
    public static func run(_ args: [String]) -> String {
        guard let binary = findBinary() else { return "" }
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return "" }
        proc.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Full run: captures stdout, stderr, and exit code. Blocks
    /// until kubectl returns or `timeout` elapses; if the timeout
    /// hits, the child is SIGTERM'd and the result contains a
    /// synthetic exit code of 124 (matching `/usr/bin/timeout`'s
    /// convention) and a stderr hint.
    public static func runSync(_ args: [String], timeout: TimeInterval = 5) -> Result {
        guard let binary = findBinary() else {
            return Result(stdout: "", stderr: "kubectl not found", exitCode: 127)
        }
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do { try proc.run() } catch {
            return Result(stdout: "", stderr: "spawn failed: \(error.localizedDescription)", exitCode: 126)
        }

        // Enforce the timeout with a DispatchWorkItem. If the
        // child is still running when the work item fires, we
        // terminate it. Reading the pipes must happen AFTER
        // waitUntilExit to avoid partial reads, but that's fine
        // because we cap the wait via terminate().
        let deadline = DispatchTime.now() + timeout
        var timedOut = false
        let waitQueue = DispatchQueue.global(qos: .utility)
        let semaphore = DispatchSemaphore(value: 0)
        waitQueue.async {
            proc.waitUntilExit()
            semaphore.signal()
        }
        if semaphore.wait(timeout: deadline) == .timedOut {
            proc.terminate()
            _ = semaphore.wait(timeout: .now() + 1) // give it a sec to die
            timedOut = true
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderrText = String(data: errData, encoding: .utf8) ?? ""

        if timedOut {
            return Result(
                stdout: stdout,
                stderr: stderrText.isEmpty ? "kubectl timed out after \(Int(timeout))s" : stderrText,
                exitCode: 124
            )
        }
        return Result(stdout: stdout, stderr: stderrText, exitCode: proc.terminationStatus)
    }

    /// Run kubectl and decode its stdout as JSON. Returns nil on
    /// non-zero exit or decode failure. Convenience on top of
    /// `runSync` for the common "kubectl ... -o json" pattern.
    public static func runJSON<T: Decodable>(_ args: [String], as _: T.Type = T.self, timeout: TimeInterval = 5) -> T? {
        let result = runSync(args, timeout: timeout)
        guard result.ok else { return nil }
        guard let data = result.stdout.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
