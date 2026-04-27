import Foundation
import os

public enum KubeconfigPatcherError: LocalizedError {
    case commandFailed(String)
    case kubectlMissing

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let msg): return "kubeconfig patch failed: \(msg)"
        case .kubectlMissing: return "kubectl not found on PATH"
        }
    }
}

public struct KubeconfigPatcher: Sendable {
    private let log = Logger(subsystem: "com.fourninecloud.cloud-tunnels", category: "kubeconfig")

    public init() {}

    /// Patch a cluster entry to route through the given SOCKS port. Idempotent.
    public func apply(patch: KubeconfigPatch, socksPort: Int) throws {
        let kubectl = try KubectlLocator.find()
        let args = Self.buildSetClusterArgs(patch: patch, socksPort: socksPort)
        try run(kubectl: kubectl, args: args)
        log.info("patched kubeconfig cluster \(patch.clusterName, privacy: .public) → socks5://127.0.0.1:\(socksPort)")
    }

    /// Restore a cluster entry by unsetting proxy-url and insecure-skip-tls-verify.
    /// Errors are swallowed — we never want disconnect to fail because of cleanup.
    public func restore(patch: KubeconfigPatch) {
        do {
            let kubectl = try KubectlLocator.find()
            for args in Self.buildUnsetArgs(patch: patch) {
                try? run(kubectl: kubectl, args: args)
            }
            log.info("restored kubeconfig cluster \(patch.clusterName, privacy: .public)")
        } catch {
            log.error("kubeconfig restore skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Pure argv builders (unit-testable)

    static func buildSetClusterArgs(patch: KubeconfigPatch, socksPort: Int) -> [String] {
        var args: [String] = []
        if let path = patch.kubeconfigPath, !path.isEmpty {
            args.append("--kubeconfig=\(path)")
        }
        args.append(contentsOf: [
            "config", "set-cluster", patch.clusterName,
            "--proxy-url=socks5://127.0.0.1:\(socksPort)",
        ])
        if patch.insecureSkipTLSVerify {
            args.append("--insecure-skip-tls-verify=true")
        }
        return args
    }

    static func buildUnsetArgs(patch: KubeconfigPatch) -> [[String]] {
        let base: [String] = {
            if let path = patch.kubeconfigPath, !path.isEmpty {
                return ["--kubeconfig=\(path)"]
            }
            return []
        }()
        return [
            base + ["config", "unset", "clusters.\(patch.clusterName).proxy-url"],
            base + ["config", "unset", "clusters.\(patch.clusterName).insecure-skip-tls-verify"],
        ]
    }

    // MARK: - Runner

    private func run(kubectl: URL, args: [String]) throws {
        let proc = Process()
        proc.executableURL = kubectl
        proc.arguments = args
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        do {
            try proc.run()
        } catch {
            throw KubeconfigPatcherError.commandFailed("launch failed: \(error.localizedDescription)")
        }
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(proc.terminationStatus)"
            throw KubeconfigPatcherError.commandFailed(msg)
        }
    }
}
