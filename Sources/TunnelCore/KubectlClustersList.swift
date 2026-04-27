import Foundation

/// Fetches the list of cluster names from the user's kubeconfig by running
/// `kubectl config get-clusters`. Returns an empty list if kubectl is missing
/// or the command fails — never throws.
public enum KubectlClustersList {
    public static func fetch(kubeconfigPath: String? = nil) -> [String] {
        guard let kubectl = try? KubectlLocator.find() else { return [] }
        let proc = Process()
        proc.executableURL = kubectl
        var args: [String] = []
        if let path = kubeconfigPath, !path.isEmpty {
            args.append("--kubeconfig=\(path)")
        }
        args.append(contentsOf: ["config", "get-clusters"])
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return []
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        // First line is the `NAME` header.
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "NAME" }
            .sorted()
    }
}
