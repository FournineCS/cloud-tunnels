import Foundation

/// Parses a kubeconfig (active or pasted) into a flat display
/// struct. Avoids needing a YAML parser by shelling out to
/// `kubectl config view --flatten -o json` which emits a fully
/// structured JSON document with resolved embedded data.
///
/// Key insight for the user's workflow: cluster rows surface any
/// `proxy-url` set on them, which is how our SSH tunnel
/// kubeconfigPatch flow exposes private GKE/EKS clusters to
/// kubectl. Seeing the proxy URL highlighted makes it immediately
/// obvious which clusters are reachable through an active tunnel.
public enum KubeconfigInspector {

    public struct Inspected: Equatable {
        public var clusters: [Cluster]
        public var contexts: [Context]
        public var users: [User]
        public var currentContext: String

        public struct Cluster: Equatable, Identifiable {
            public var id: String { name }
            public var name: String
            public var server: String
            /// Set by `kubectl config set-cluster ... --proxy-url=...`
            /// — our tunnel kubeconfigPatch flow writes this.
            public var proxyURL: String?
            public var insecureSkipTLSVerify: Bool
            public var hasCAData: Bool
        }

        public struct Context: Equatable, Identifiable {
            public var id: String { name }
            public var name: String
            public var cluster: String
            public var user: String
            public var namespace: String?
            public var isCurrent: Bool
        }

        public struct User: Equatable, Identifiable {
            public var id: String { name }
            public var name: String
            public var authMethod: String
        }
    }

    public enum InspectError: LocalizedError {
        case kubectlMissing
        case kubectlFailed(String)
        case decodeFailed(String)
        case emptyConfig

        public var errorDescription: String? {
            switch self {
            case .kubectlMissing:
                return "kubectl not found on PATH. Install via `brew install kubernetes-cli`."
            case .kubectlFailed(let msg):
                return "kubectl config view failed: \(msg)"
            case .decodeFailed(let msg):
                return "Couldn't parse kubeconfig JSON: \(msg)"
            case .emptyConfig:
                return "Kubeconfig has no clusters or contexts defined."
            }
        }
    }

    // MARK: - Public entry points

    /// Load the user's currently-active kubeconfig (the one kubectl
    /// would use if you ran a command right now). Obeys the
    /// standard $KUBECONFIG merging rules because we shell out to
    /// kubectl itself to do the view.
    public static func loadCurrent() throws -> Inspected {
        guard Kubectl.findBinary() != nil else {
            throw InspectError.kubectlMissing
        }
        let result = Kubectl.runSync(
            ["config", "view", "--flatten", "-o", "json"],
            timeout: 5
        )
        guard result.ok else {
            throw InspectError.kubectlFailed(
                result.stderr.isEmpty ? "exit code \(result.exitCode)" : result.stderr
            )
        }
        return try decode(jsonString: result.stdout)
    }

    /// Parse a kubeconfig that the user pasted into the text
    /// editor. We write it to a temp file, re-run
    /// `kubectl config view` against that file, and decode the
    /// JSON output. This supports both YAML (the normal format)
    /// and JSON input — kubectl accepts either.
    public static func inspect(pastedConfig: String) throws -> Inspected {
        guard Kubectl.findBinary() != nil else {
            throw InspectError.kubectlMissing
        }
        let trimmed = pastedConfig.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw InspectError.emptyConfig }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudtunnels-kubeconfig-\(UUID().uuidString).yaml")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try trimmed.write(to: tmp, atomically: true, encoding: .utf8)

        let result = Kubectl.runSync(
            ["--kubeconfig", tmp.path, "config", "view", "--flatten", "-o", "json"],
            timeout: 5
        )
        guard result.ok else {
            throw InspectError.kubectlFailed(
                result.stderr.isEmpty ? "exit code \(result.exitCode)" : result.stderr
            )
        }
        return try decode(jsonString: result.stdout)
    }

    // MARK: - JSON decoding (pure, unit-testable)

    /// Decode the JSON output of `kubectl config view -o json`
    /// into the flat Inspected struct. Exposed for testing with
    /// fixture strings — no kubectl invocation needed.
    public static func decode(jsonString: String) throws -> Inspected {
        guard let data = jsonString.data(using: .utf8) else {
            throw InspectError.decodeFailed("input is not valid UTF-8")
        }
        let dto: KubeconfigDTO
        do {
            dto = try JSONDecoder().decode(KubeconfigDTO.self, from: data)
        } catch {
            throw InspectError.decodeFailed(error.localizedDescription)
        }
        return flatten(dto)
    }

    /// Transform the raw kubeconfig JSON DTO into the flat display
    /// struct. Exposed for direct testing with synthetic DTOs.
    public static func flatten(_ dto: KubeconfigDTO) -> Inspected {
        let currentCtx = dto.currentContext ?? ""
        let clusters: [Inspected.Cluster] = (dto.clusters ?? []).map { entry in
            Inspected.Cluster(
                name: entry.name,
                server: entry.cluster.server ?? "",
                proxyURL: entry.cluster.proxyUrl,
                insecureSkipTLSVerify: entry.cluster.insecureSkipTlsVerify ?? false,
                hasCAData: (entry.cluster.certificateAuthorityData ?? "").isEmpty == false ||
                           (entry.cluster.certificateAuthority ?? "").isEmpty == false
            )
        }
        let contexts: [Inspected.Context] = (dto.contexts ?? []).map { entry in
            Inspected.Context(
                name: entry.name,
                cluster: entry.context.cluster ?? "",
                user: entry.context.user ?? "",
                namespace: entry.context.namespace,
                isCurrent: entry.name == currentCtx
            )
        }
        let users: [Inspected.User] = (dto.users ?? []).map { entry in
            Inspected.User(
                name: entry.name,
                authMethod: classifyAuthMethod(entry.user)
            )
        }
        return Inspected(
            clusters: clusters,
            contexts: contexts,
            users: users,
            currentContext: currentCtx
        )
    }

    /// Heuristic classification of a user's auth method based on
    /// which fields are populated in the kubeconfig user entry.
    /// Exposed for testing.
    public static func classifyAuthMethod(_ user: KubeconfigDTO.UserDetails) -> String {
        if user.token != nil { return "token" }
        if user.clientCertificateData != nil || user.clientCertificate != nil {
            return "client certificate"
        }
        if user.exec != nil { return "exec (plugin)" }
        if user.authProvider != nil {
            let name = user.authProvider?.name ?? "auth-provider"
            return "auth-provider: \(name)"
        }
        if user.username != nil { return "basic (username/password)" }
        return "unknown"
    }

    // MARK: - Raw DTOs (match kubectl's JSON schema)

    public struct KubeconfigDTO: Decodable, Equatable {
        public var kind: String?
        public var apiVersion: String?
        public var currentContext: String?
        public var clusters: [ClusterEntry]?
        public var contexts: [ContextEntry]?
        public var users: [UserEntry]?

        enum CodingKeys: String, CodingKey {
            case kind
            case apiVersion
            case currentContext = "current-context"
            case clusters
            case contexts
            case users
        }

        public struct ClusterEntry: Decodable, Equatable {
            public var name: String
            public var cluster: ClusterDetails
        }
        public struct ClusterDetails: Decodable, Equatable {
            public var server: String?
            public var proxyUrl: String?
            public var insecureSkipTlsVerify: Bool?
            public var certificateAuthority: String?
            public var certificateAuthorityData: String?

            enum CodingKeys: String, CodingKey {
                case server
                case proxyUrl = "proxy-url"
                case insecureSkipTlsVerify = "insecure-skip-tls-verify"
                case certificateAuthority = "certificate-authority"
                case certificateAuthorityData = "certificate-authority-data"
            }
        }

        public struct ContextEntry: Decodable, Equatable {
            public var name: String
            public var context: ContextDetails
        }
        public struct ContextDetails: Decodable, Equatable {
            public var cluster: String?
            public var user: String?
            public var namespace: String?
        }

        public struct UserEntry: Decodable, Equatable {
            public var name: String
            public var user: UserDetails
        }
        public struct UserDetails: Decodable, Equatable {
            public var token: String?
            public var username: String?
            public var password: String?
            public var clientCertificate: String?
            public var clientCertificateData: String?
            public var clientKey: String?
            public var clientKeyData: String?
            public var authProvider: AuthProvider?
            public var exec: ExecProvider?

            enum CodingKeys: String, CodingKey {
                case token, username, password
                case clientCertificate = "client-certificate"
                case clientCertificateData = "client-certificate-data"
                case clientKey = "client-key"
                case clientKeyData = "client-key-data"
                case authProvider = "auth-provider"
                case exec
            }
        }
        public struct AuthProvider: Decodable, Equatable {
            public var name: String
        }
        public struct ExecProvider: Decodable, Equatable {
            public var command: String?
            public var apiVersion: String?
        }
    }
}
