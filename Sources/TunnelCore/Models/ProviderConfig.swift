import Foundation

// MARK: - Provider discriminator

public enum TunnelProvider: String, Codable, Hashable, CaseIterable, Sendable {
    case gcpIAP
    case awsSSM
    case cloudSQLProxy
    case ssh

    public var displayName: String {
        switch self {
        case .gcpIAP: return "GCP IAP"
        case .awsSSM: return "AWS SSM"
        case .cloudSQLProxy: return "Cloud SQL Proxy"
        case .ssh: return "SSH"
        }
    }

    public var shortTag: String {
        switch self {
        case .gcpIAP: return "IAP"
        case .awsSSM: return "SSM"
        case .cloudSQLProxy: return "CSQL"
        case .ssh: return "SSH"
        }
    }
}

// MARK: - GCP IAP config

public struct GCPIAPConfig: Codable, Hashable, Sendable {
    public var instance: String
    public var instancePort: Int
    public var zone: String
    public var project: String
    public var account: String?

    enum CodingKeys: String, CodingKey {
        case instance
        case instancePort = "instance_port"
        case zone
        case project
        case account
    }

    public init(
        instance: String,
        instancePort: Int,
        zone: String,
        project: String,
        account: String? = nil
    ) {
        self.instance = instance
        self.instancePort = instancePort
        self.zone = zone
        self.project = project
        self.account = account
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.instance = try c.decode(String.self, forKey: .instance)
        self.instancePort = try Self.decodeInt(c, .instancePort)
        self.zone = try c.decode(String.self, forKey: .zone)
        self.project = try c.decode(String.self, forKey: .project)
        if let s = try? c.decode(String.self, forKey: .account), !s.isEmpty {
            self.account = s
        } else {
            self.account = nil
        }
    }

    private static func decodeInt(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> Int {
        if let i = try? c.decode(Int.self, forKey: key) { return i }
        if let s = try? c.decode(String.self, forKey: key), let i = Int(s) { return i }
        throw DecodingError.dataCorruptedError(
            forKey: key, in: c, debugDescription: "Expected Int or numeric String for \(key.rawValue)"
        )
    }
}

// MARK: - Local HTTPS reverse-proxy add-on

/// Per-tunnel sidecar configuration that asks the privileged proxy helper to
/// terminate TLS for a hostname locally and reverse-proxy plaintext traffic
/// into the tunnel's local port. Lets users hit MWAA / VPCE-style HTTPS
/// endpoints in a normal browser without disabling cert checks.
public struct LocalHTTPSProxy: Codable, Hashable, Sendable {
    /// Fully-qualified hostname the local listener should answer for.
    /// Becomes the cert SAN and (optionally) an /etc/hosts → 127.0.0.1 entry.
    public var hostname: String
    /// When true, the helper writes a marker-tagged `127.0.0.1 <hostname>`
    /// line to /etc/hosts on connect and removes it on disconnect.
    public var manageHosts: Bool
    /// When true, the upstream HTTPS request to 127.0.0.1:<localPort> skips
    /// cert verification. Required for VPCE endpoints whose cert is for the
    /// public hostname, not the loopback address.
    public var insecureUpstream: Bool

    enum CodingKeys: String, CodingKey {
        case hostname
        case manageHosts = "manage_hosts"
        case insecureUpstream = "insecure_upstream"
    }

    public init(
        hostname: String,
        manageHosts: Bool = true,
        insecureUpstream: Bool = true
    ) {
        self.hostname = hostname
        self.manageHosts = manageHosts
        self.insecureUpstream = insecureUpstream
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.hostname = try c.decode(String.self, forKey: .hostname)
        self.manageHosts = (try? c.decode(Bool.self, forKey: .manageHosts)) ?? true
        self.insecureUpstream = (try? c.decode(Bool.self, forKey: .insecureUpstream)) ?? true
    }
}

// MARK: - AWS SSM config

public struct AWSSSMConfig: Codable, Hashable, Sendable {
    /// EC2 instance ID (e.g. "i-0abc123"). Passed as --target to aws ssm.
    public var target: String
    /// If nil/empty, uses AWS-StartPortForwardingSession (direct-to-EC2).
    /// If set, uses AWS-StartPortForwardingSessionToRemoteHost (bastion→host).
    public var remoteHost: String?
    /// Port on the target (direct mode) or on the remote host (bastion mode).
    public var remotePort: Int
    /// AWS CLI profile name. nil/empty = use default.
    public var profile: String?
    /// AWS region override. nil/empty = use profile's configured region.
    public var region: String?
    /// Optional local HTTPS reverse-proxy sidecar. nil = disabled.
    public var localProxy: LocalHTTPSProxy?

    enum CodingKeys: String, CodingKey {
        case target
        case remoteHost = "remote_host"
        case remotePort = "remote_port"
        case profile
        case region
        case localProxy = "local_proxy"
    }

    public init(
        target: String,
        remoteHost: String? = nil,
        remotePort: Int,
        profile: String? = nil,
        region: String? = nil,
        localProxy: LocalHTTPSProxy? = nil
    ) {
        self.target = target
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.profile = profile
        self.region = region
        self.localProxy = localProxy
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.target = try c.decode(String.self, forKey: .target)
        if let s = try? c.decode(String.self, forKey: .remoteHost), !s.isEmpty {
            self.remoteHost = s
        } else {
            self.remoteHost = nil
        }
        self.remotePort = try Self.decodeInt(c, .remotePort)
        if let s = try? c.decode(String.self, forKey: .profile), !s.isEmpty {
            self.profile = s
        } else {
            self.profile = nil
        }
        if let s = try? c.decode(String.self, forKey: .region), !s.isEmpty {
            self.region = s
        } else {
            self.region = nil
        }
        if let proxy = try? c.decode(LocalHTTPSProxy.self, forKey: .localProxy),
           !proxy.hostname.isEmpty {
            self.localProxy = proxy
        } else {
            self.localProxy = nil
        }
    }

    private static func decodeInt(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> Int {
        if let i = try? c.decode(Int.self, forKey: key) { return i }
        if let s = try? c.decode(String.self, forKey: key), let i = Int(s) { return i }
        throw DecodingError.dataCorruptedError(
            forKey: key, in: c, debugDescription: "Expected Int or numeric String for \(key.rawValue)"
        )
    }
}

// MARK: - Cloud SQL Auth Proxy config

public struct CloudSQLProxyConfig: Codable, Hashable, Sendable {
    /// Instance connection name in the form `project:region:instance`.
    public var instanceConnectionName: String
    /// gcloud account email to select ADC via `CLOUDSDK_CORE_ACCOUNT`. nil = gcloud default.
    public var account: String?
    /// Connect via the instance's private IP instead of public. Passes `--private-ip`.
    public var privateIP: Bool
    /// Use IAM database authentication. Passes `--auto-iam-authn`.
    public var autoIAMAuthn: Bool
    /// Service account email to impersonate. Passes `--impersonate-service-account`. nil = off.
    public var impersonateServiceAccount: String?

    enum CodingKeys: String, CodingKey {
        case instanceConnectionName = "instance_connection_name"
        case account
        case privateIP = "private_ip"
        case autoIAMAuthn = "auto_iam_authn"
        case impersonateServiceAccount = "impersonate_service_account"
    }

    public init(
        instanceConnectionName: String,
        account: String? = nil,
        privateIP: Bool = false,
        autoIAMAuthn: Bool = false,
        impersonateServiceAccount: String? = nil
    ) {
        self.instanceConnectionName = instanceConnectionName
        self.account = account
        self.privateIP = privateIP
        self.autoIAMAuthn = autoIAMAuthn
        self.impersonateServiceAccount = impersonateServiceAccount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.instanceConnectionName = try c.decode(String.self, forKey: .instanceConnectionName)
        if let s = try? c.decode(String.self, forKey: .account), !s.isEmpty {
            self.account = s
        } else {
            self.account = nil
        }
        self.privateIP = (try? c.decode(Bool.self, forKey: .privateIP)) ?? false
        self.autoIAMAuthn = (try? c.decode(Bool.self, forKey: .autoIAMAuthn)) ?? false
        if let s = try? c.decode(String.self, forKey: .impersonateServiceAccount), !s.isEmpty {
            self.impersonateServiceAccount = s
        } else {
            self.impersonateServiceAccount = nil
        }
    }
}

// MARK: - SSH config

/// How the SSH connection reaches its destination host.
public enum SSHUpstream: Codable, Hashable, Sendable {
    /// Plain `ssh <alias>` — inherits ProxyJump / IdentityFile / User from ~/.ssh/config.
    case sshConfigAlias(String)
    /// `gcloud compute ssh <instance> --tunnel-through-iap -- <ssh args>` — one-shot IAP+SSH.
    case gcloudIAP(instance: String, zone: String, project: String, account: String?)

    enum CodingKeys: String, CodingKey {
        case type
        case alias
        case instance
        case zone
        case project
        case account
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sshConfigAlias(let alias):
            try c.encode("sshConfigAlias", forKey: .type)
            try c.encode(alias, forKey: .alias)
        case .gcloudIAP(let instance, let zone, let project, let account):
            try c.encode("gcloudIAP", forKey: .type)
            try c.encode(instance, forKey: .instance)
            try c.encode(zone, forKey: .zone)
            try c.encode(project, forKey: .project)
            if let account, !account.isEmpty {
                try c.encode(account, forKey: .account)
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "sshConfigAlias":
            self = .sshConfigAlias(try c.decode(String.self, forKey: .alias))
        case "gcloudIAP":
            let instance = try c.decode(String.self, forKey: .instance)
            let zone = try c.decode(String.self, forKey: .zone)
            let project = try c.decode(String.self, forKey: .project)
            let account: String? = {
                if let s = try? c.decode(String.self, forKey: .account), !s.isEmpty { return s }
                return nil
            }()
            self = .gcloudIAP(instance: instance, zone: zone, project: project, account: account)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "Unknown SSHUpstream type: \(type)"
            )
        }
    }

    /// Short display string for UI row subtitles.
    public var shortLabel: String {
        switch self {
        case .sshConfigAlias(let alias): return alias
        case .gcloudIAP(let instance, let zone, _, _): return "\(instance) (\(zone))"
        }
    }
}

public struct SSHLocalForward: Codable, Hashable, Sendable {
    public var localPort: Int
    public var remoteHost: String
    public var remotePort: Int

    enum CodingKeys: String, CodingKey {
        case localPort = "local_port"
        case remoteHost = "remote_host"
        case remotePort = "remote_port"
    }

    public init(localPort: Int, remoteHost: String, remotePort: Int) {
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }
}

public struct KubeconfigPatch: Codable, Hashable, Sendable {
    /// `kubectl config set-cluster <clusterName>` target.
    public var clusterName: String
    /// Pass `--insecure-skip-tls-verify=true` when patching. Matches loft-connect.sh.
    public var insecureSkipTLSVerify: Bool
    /// Override path. nil = default ($KUBECONFIG or ~/.kube/config).
    public var kubeconfigPath: String?

    enum CodingKeys: String, CodingKey {
        case clusterName = "cluster_name"
        case insecureSkipTLSVerify = "insecure_skip_tls_verify"
        case kubeconfigPath = "kubeconfig_path"
    }

    public init(
        clusterName: String,
        insecureSkipTLSVerify: Bool = true,
        kubeconfigPath: String? = nil
    ) {
        self.clusterName = clusterName
        self.insecureSkipTLSVerify = insecureSkipTLSVerify
        self.kubeconfigPath = kubeconfigPath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.clusterName = try c.decode(String.self, forKey: .clusterName)
        self.insecureSkipTLSVerify = (try? c.decode(Bool.self, forKey: .insecureSkipTLSVerify)) ?? true
        if let s = try? c.decode(String.self, forKey: .kubeconfigPath), !s.isEmpty {
            self.kubeconfigPath = s
        } else {
            self.kubeconfigPath = nil
        }
    }
}

public struct SSHConfig: Codable, Hashable, Sendable {
    public var upstream: SSHUpstream
    /// -D port. nil = no SOCKS5 forward.
    public var socksPort: Int?
    /// -L forwards. Empty = none.
    public var localForwards: [SSHLocalForward]
    /// Optional kubeconfig patch applied on connect, restored on disconnect.
    public var kubeconfigPatch: KubeconfigPatch?

    enum CodingKeys: String, CodingKey {
        case upstream
        case socksPort = "socks_port"
        case localForwards = "local_forwards"
        case kubeconfigPatch = "kubeconfig_patch"
    }

    public init(
        upstream: SSHUpstream,
        socksPort: Int? = nil,
        localForwards: [SSHLocalForward] = [],
        kubeconfigPatch: KubeconfigPatch? = nil
    ) {
        self.upstream = upstream
        self.socksPort = socksPort
        self.localForwards = localForwards
        self.kubeconfigPatch = kubeconfigPatch
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.upstream = try c.decode(SSHUpstream.self, forKey: .upstream)
        self.socksPort = try? c.decode(Int.self, forKey: .socksPort)
        self.localForwards = (try? c.decode([SSHLocalForward].self, forKey: .localForwards)) ?? []
        self.kubeconfigPatch = try? c.decode(KubeconfigPatch.self, forKey: .kubeconfigPatch)
    }
}

// MARK: - Tagged union

public enum ProviderConfig: Codable, Hashable, Sendable {
    case gcpIAP(GCPIAPConfig)
    case awsSSM(AWSSSMConfig)
    case cloudSQLProxy(CloudSQLProxyConfig)
    case ssh(SSHConfig)

    public var kind: TunnelProvider {
        switch self {
        case .gcpIAP: return .gcpIAP
        case .awsSSM: return .awsSSM
        case .cloudSQLProxy: return .cloudSQLProxy
        case .ssh: return .ssh
        }
    }

    /// Short display descriptor for the tunnel row subtitle.
    public var targetDescription: String {
        switch self {
        case .gcpIAP(let c):
            return "\(c.instance):\(c.instancePort)"
        case .awsSSM(let c):
            if let host = c.remoteHost, !host.isEmpty {
                return "\(c.target) → \(host):\(c.remotePort)"
            }
            return "\(c.target):\(c.remotePort)"
        case .cloudSQLProxy(let c):
            // "project:region:instance" → show last segment
            let parts = c.instanceConnectionName.split(separator: ":")
            return parts.last.map(String.init) ?? c.instanceConnectionName
        case .ssh(let c):
            var parts: [String] = [c.upstream.shortLabel]
            if let sp = c.socksPort { parts.append("SOCKS:\(sp)") }
            if !c.localForwards.isEmpty { parts.append("\(c.localForwards.count) fwd") }
            return parts.joined(separator: " · ")
        }
    }

    /// Account/profile short name shown as a tag in the UI, if any.
    public var accountTag: String? {
        switch self {
        case .gcpIAP(let c):
            guard let email = c.account, !email.isEmpty else { return nil }
            if let at = email.firstIndex(of: "@") { return String(email[..<at]) }
            return email
        case .awsSSM(let c):
            return c.profile?.isEmpty == false ? c.profile : nil
        case .cloudSQLProxy(let c):
            guard let email = c.account, !email.isEmpty else { return nil }
            if let at = email.firstIndex(of: "@") { return String(email[..<at]) }
            return email
        case .ssh(let c):
            if case .gcloudIAP(_, _, _, let account) = c.upstream,
               let email = account, !email.isEmpty {
                if let at = email.firstIndex(of: "@") { return String(email[..<at]) }
                return email
            }
            return nil
        }
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case type
        case data
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .gcpIAP(let cfg):
            try c.encode(TunnelProvider.gcpIAP.rawValue, forKey: .type)
            try c.encode(cfg, forKey: .data)
        case .awsSSM(let cfg):
            try c.encode(TunnelProvider.awsSSM.rawValue, forKey: .type)
            try c.encode(cfg, forKey: .data)
        case .cloudSQLProxy(let cfg):
            try c.encode(TunnelProvider.cloudSQLProxy.rawValue, forKey: .type)
            try c.encode(cfg, forKey: .data)
        case .ssh(let cfg):
            try c.encode(TunnelProvider.ssh.rawValue, forKey: .type)
            try c.encode(cfg, forKey: .data)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case TunnelProvider.gcpIAP.rawValue:
            self = .gcpIAP(try c.decode(GCPIAPConfig.self, forKey: .data))
        case TunnelProvider.awsSSM.rawValue:
            self = .awsSSM(try c.decode(AWSSSMConfig.self, forKey: .data))
        case TunnelProvider.cloudSQLProxy.rawValue:
            self = .cloudSQLProxy(try c.decode(CloudSQLProxyConfig.self, forKey: .data))
        case TunnelProvider.ssh.rawValue:
            self = .ssh(try c.decode(SSHConfig.self, forKey: .data))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "Unknown provider type: \(type)"
            )
        }
    }
}
