import Foundation

struct KubeContext: Identifiable, Equatable {
    let name: String
    let isCurrent: Bool
    var id: String { name }
}

enum KubectlContext {
    static func list() -> [KubeContext] {
        guard Kubectl.findBinary() != nil else { return [] }
        let names = Kubectl.run(["config", "get-contexts", "-o", "name"])
            .split(whereSeparator: { $0.isNewline })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let current = Kubectl.run(["config", "current-context"])
        return names.map { KubeContext(name: $0, isCurrent: $0 == current) }
    }

    @discardableResult
    static func use(context name: String) -> Bool {
        Kubectl.runSync(["config", "use-context", name]).ok
    }

    /// Returns the names of every kubeconfig context whose `cluster`
    /// field equals the given cluster name. A cluster can be referenced
    /// by zero, one, or many contexts depending on how the user has
    /// their kubeconfig laid out (one cluster + multiple namespaces +
    /// multiple users is common in shared GKE setups).
    static func contexts(forCluster cluster: String) -> [String] {
        guard Kubectl.findBinary() != nil else { return [] }
        let jsonpath = #"{range .contexts[*]}{.name}{"\t"}{.context.cluster}{"\n"}{end}"#
        let raw = Kubectl.run(["config", "view", "-o", "jsonpath=\(jsonpath)"])
        return parseContextClusterRows(raw, matching: cluster)
    }

    /// Pure parser split out for unit tests. Each row is
    /// "<context>\t<cluster>"; we return contexts whose cluster
    /// column matches the target.
    static func parseContextClusterRows(_ raw: String, matching cluster: String) -> [String] {
        raw.split(whereSeparator: { $0.isNewline }).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let clusterName = parts[1].trimmingCharacters(in: .whitespaces)
            return clusterName == cluster ? name : nil
        }
    }

    /// Convenience: switch the active kubectl context to one that
    /// references the given cluster. Returns the result so the caller
    /// can show a meaningful notification.
    ///
    /// - Returns:
    ///   - `.switched(name)`: success, current-context is now `name`
    ///   - `.ambiguous([names])`: multiple contexts match; we don't
    ///      pick one without the user telling us which
    ///   - `.notFound`: no context references the given cluster
    ///   - `.kubectlMissing`: kubectl isn't on PATH
    ///   - `.failed(message)`: kubectl errored
    enum SwitchResult: Equatable {
        case switched(String)
        case ambiguous([String])
        case notFound
        case kubectlMissing
        case failed(String)
    }

    static func switchToContextForCluster(_ cluster: String) -> SwitchResult {
        guard Kubectl.findBinary() != nil else { return .kubectlMissing }
        let matches = contexts(forCluster: cluster)
        switch matches.count {
        case 0: return .notFound
        case 1:
            let name = matches[0]
            return use(context: name) ? .switched(name) : .failed("kubectl use-context exited non-zero")
        default:
            return .ambiguous(matches)
        }
    }

    /// Parses the output of `kubectl config get-contexts -o name`.
    static func parseContextNames(_ output: String) -> [String] {
        output
            .split(whereSeparator: { $0.isNewline })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
