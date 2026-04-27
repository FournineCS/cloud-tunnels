import Foundation

/// Probes every context in the user's kubeconfig for reachability,
/// surfaces server version when the API responds. Directly
/// validates the SSH-tunnel-to-cluster flow CloudTunnels' own
/// kubeconfig patches enable — the user can run this after
/// connecting an SSH tunnel to confirm kubectl actually has
/// access to the patched cluster.
public enum ClusterHealthChecker {

    public struct ContextHealth: Equatable, Identifiable, Sendable {
        public var id: String { context }
        public var context: String
        public var cluster: String
        public var serverVersion: String?
        public var reachable: Bool
        public var errorSummary: String?

        public init(
            context: String,
            cluster: String,
            serverVersion: String? = nil,
            reachable: Bool,
            errorSummary: String? = nil
        ) {
            self.context = context
            self.cluster = cluster
            self.serverVersion = serverVersion
            self.reachable = reachable
            self.errorSummary = errorSummary
        }
    }

    /// Canned result of a kubectl probe. Extracted so tests can
    /// feed synthetic stdout/stderr without shelling out.
    public typealias Runner = (_ context: String, _ timeout: TimeInterval) -> Kubectl.Result

    /// Default runner: invokes the real kubectl binary with a
    /// --request-timeout hint and -o json output. Separated from
    /// `probe(...)` so tests can swap in a mock runner.
    public static let defaultRunner: Runner = { context, timeout in
        let kubectlTimeout = "\(Int(timeout))s"
        return Kubectl.runSync(
            ["version", "--context=\(context)", "--request-timeout=\(kubectlTimeout)", "-o", "json"],
            // Give the subprocess a bit more wall-clock than its
            // internal kubectl request-timeout so we don't spuriously
            // terminate it before kubectl itself errors out.
            timeout: timeout + 2
        )
    }

    // MARK: - Public API

    /// Probe every context in the user's active kubeconfig in
    /// bounded concurrency. Contexts are returned in the order
    /// kubectl lists them (same order as `kubectl config
    /// get-contexts`). If kubectl isn't installed or has no
    /// contexts, returns an empty array.
    public static func probeAll(
        maxConcurrent: Int = 4,
        requestTimeout: TimeInterval = 2,
        runner: @escaping Runner = defaultRunner
    ) async -> [ContextHealth] {
        let contextsAndClusters = listContextsWithClusters()
        guard !contextsAndClusters.isEmpty else { return [] }

        // Bound concurrency with a TaskGroup + counting semaphore.
        // The user can have dozens of contexts across many
        // clusters; we don't want to spawn 30 kubectl processes
        // simultaneously (both for resource reasons and because
        // multiple contexts may share the same SOCKS tunnel and
        // we don't want to thundering-herd the proxy).
        return await withTaskGroup(of: (Int, ContextHealth).self) { group in
            var results = Array(
                repeating: ContextHealth(context: "", cluster: "", reachable: false),
                count: contextsAndClusters.count
            )
            var next = 0
            var inFlight = 0
            for (idx, entry) in contextsAndClusters.enumerated() {
                if inFlight >= maxConcurrent {
                    if let finished = await group.next() {
                        results[finished.0] = finished.1
                        inFlight -= 1
                    }
                }
                group.addTask {
                    let health = probe(
                        context: entry.context,
                        cluster: entry.cluster,
                        requestTimeout: requestTimeout,
                        runner: runner
                    )
                    return (idx, health)
                }
                inFlight += 1
                next = idx + 1
            }
            while let finished = await group.next() {
                results[finished.0] = finished.1
            }
            _ = next
            return results
        }
    }

    /// Probe a single context. Exposed for direct use + unit
    /// testing with an injected runner.
    public static func probe(
        context: String,
        cluster: String,
        requestTimeout: TimeInterval = 2,
        runner: Runner = defaultRunner
    ) -> ContextHealth {
        let result = runner(context, requestTimeout)
        if result.ok {
            let version = parseServerVersion(from: result.stdout)
            return ContextHealth(
                context: context,
                cluster: cluster,
                serverVersion: version,
                reachable: true,
                errorSummary: nil
            )
        } else {
            return ContextHealth(
                context: context,
                cluster: cluster,
                serverVersion: nil,
                reachable: false,
                errorSummary: summarizeError(stderr: result.stderr, exitCode: result.exitCode)
            )
        }
    }

    // MARK: - Pure helpers (unit-testable)

    /// Extract `serverVersion.gitVersion` from `kubectl version -o
    /// json` output. Returns nil if the field is missing.
    public static func parseServerVersion(from jsonOutput: String) -> String? {
        guard let data = jsonOutput.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let server = obj["serverVersion"] as? [String: Any] else { return nil }
        return server["gitVersion"] as? String
    }

    /// Collapse a multi-line kubectl stderr into a single
    /// user-friendly error sentence. Recognizes common failure
    /// modes (connection refused, timeout, unauthorized, context
    /// not found) and falls back to the first non-empty line.
    public static func summarizeError(stderr: String, exitCode: Int32) -> String {
        if exitCode == 124 {
            return "Timed out — server did not respond"
        }
        let trimmed = stderr
            .split(whereSeparator: { $0.isNewline })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let joined = trimmed.joined(separator: " ")
        let lower = joined.lowercased()
        if lower.contains("connection refused") {
            return "Connection refused — API server unreachable"
        }
        if lower.contains("no route to host") {
            return "No route to host — likely no tunnel or VPN active"
        }
        if lower.contains("i/o timeout") || lower.contains("timeout") {
            return "Request timed out"
        }
        if lower.contains("unauthorized") {
            return "Unauthorized — credentials expired or invalid"
        }
        if lower.contains("forbidden") {
            return "Forbidden — credentials valid but lack permissions"
        }
        if lower.contains("context") && lower.contains("does not exist") {
            return "Context does not exist in kubeconfig"
        }
        if lower.contains("unable to connect") {
            return "Unable to connect to the server"
        }
        return trimmed.first ?? "Probe failed (exit \(exitCode))"
    }

    /// Query the live kubeconfig for its (context, cluster) pairs.
    /// Uses the same jsonpath pattern the existing kubectl Context
    /// tool relies on, so it handles the edge case of contexts
    /// without an explicit cluster. Returns empty array on failure.
    static func listContextsWithClusters() -> [(context: String, cluster: String)] {
        let jsonpath = #"{range .contexts[*]}{.name}{"\t"}{.context.cluster}{"\n"}{end}"#
        let raw = Kubectl.run(["config", "view", "-o", "jsonpath=\(jsonpath)"])
        return raw
            .split(whereSeparator: { $0.isNewline })
            .compactMap { line -> (String, String)? in
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }
                let ctx = parts[0].trimmingCharacters(in: .whitespaces)
                let cluster = parts[1].trimmingCharacters(in: .whitespaces)
                guard !ctx.isEmpty else { return nil }
                return (ctx, cluster)
            }
    }
}
