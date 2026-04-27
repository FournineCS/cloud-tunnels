import Foundation

public struct ActionConfig: Codable, Hashable, Sendable {
    public var username: String?  // ssh, rdp
    public var path: String?       // http, https
    public var database: String?   // postgres, mysql, mongodb

    public static let empty = ActionConfig(username: nil, path: nil, database: nil)

    public init(username: String? = nil, path: String? = nil, database: String? = nil) {
        self.username = username
        self.path = path
        self.database = database
    }

    enum CodingKeys: String, CodingKey {
        case username, path, database
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .username), !s.isEmpty {
            self.username = s
        } else {
            self.username = nil
        }
        if let s = try? c.decode(String.self, forKey: .path), !s.isEmpty {
            self.path = s
        } else {
            self.path = nil
        }
        if let s = try? c.decode(String.self, forKey: .database), !s.isEmpty {
            self.database = s
        } else {
            self.database = nil
        }
    }
}

public struct Tunnel: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var localPort: Int
    public var autoConnect: Bool
    public var provider: ProviderConfig
    public var kind: TunnelKind
    public var actionConfig: ActionConfig

    public init(
        id: UUID = UUID(),
        name: String,
        localPort: Int,
        autoConnect: Bool = false,
        provider: ProviderConfig,
        kind: TunnelKind = .tcp,
        actionConfig: ActionConfig = .empty
    ) {
        self.id = id
        self.name = name
        self.localPort = localPort
        self.autoConnect = autoConnect
        self.provider = provider
        self.kind = kind
        self.actionConfig = actionConfig
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case localPort = "local_port"
        case autoConnect = "auto_connect"
        case provider
        case kind
        case actionConfig = "action_config"

        // Legacy flat GCP fields (pre-provider schema)
        case instance
        case instancePort = "instance_port"
        case zone
        case project
        case account
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(localPort, forKey: .localPort)
        try c.encode(autoConnect, forKey: .autoConnect)
        try c.encode(provider, forKey: .provider)
        try c.encode(kind, forKey: .kind)
        try c.encode(actionConfig, forKey: .actionConfig)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.name = try c.decode(String.self, forKey: .name)
        self.autoConnect = (try? c.decode(Bool.self, forKey: .autoConnect)) ?? false

        // Backwards-compat: tunnels saved before the kind/actionConfig fields
        // existed default to TCP with empty action config.
        self.kind = (try? c.decode(TunnelKind.self, forKey: .kind)) ?? .tcp
        self.actionConfig = (try? c.decode(ActionConfig.self, forKey: .actionConfig)) ?? .empty

        // New schema first
        if let provider = try? c.decode(ProviderConfig.self, forKey: .provider) {
            self.provider = provider
            self.localPort = try Self.decodeInt(c, .localPort)
            return
        }

        // Legacy flat GCP schema → wrap as .gcpIAP
        let instance = try c.decode(String.self, forKey: .instance)
        let instancePort = try Self.decodeInt(c, .instancePort)
        let zone = try c.decode(String.self, forKey: .zone)
        let project = try c.decode(String.self, forKey: .project)
        let account: String? = {
            if let s = try? c.decode(String.self, forKey: .account), !s.isEmpty { return s }
            return nil
        }()
        self.provider = .gcpIAP(GCPIAPConfig(
            instance: instance,
            instancePort: instancePort,
            zone: zone,
            project: project,
            account: account
        ))
        self.localPort = try Self.decodeInt(c, .localPort)
    }

    private static func decodeInt(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> Int {
        if let i = try? c.decode(Int.self, forKey: key) { return i }
        if let s = try? c.decode(String.self, forKey: key), let i = Int(s) { return i }
        throw DecodingError.dataCorruptedError(
            forKey: key, in: c, debugDescription: "Expected Int or numeric String for \(key.rawValue)"
        )
    }
}

extension Tunnel {
    /// Sort/group key by account or profile within a provider tab. Stable
    /// across renders so SwiftUI ForEach diffs cleanly.
    public var accountKey: String {
        switch provider {
        case .gcpIAP(let c):
            return (c.account?.isEmpty == false ? c.account! : "(default account)")
        case .awsSSM(let c):
            return (c.profile?.isEmpty == false ? c.profile! : "(default profile)")
        case .cloudSQLProxy(let c):
            return (c.account?.isEmpty == false ? c.account! : "(default account)")
        case .ssh(let c):
            return c.upstream.shortLabel
        }
    }

    /// All local TCP ports this tunnel will bind when running. Used for port
    /// conflict detection across tunnels. Most providers bind a single
    /// `localPort`; SSH tunnels may bind a SOCKS port plus zero or more
    /// local-forward ports.
    public func allLocalPorts() -> [Int] {
        switch provider {
        case .ssh(let c):
            var ports: [Int] = []
            if let sp = c.socksPort { ports.append(sp) }
            ports.append(contentsOf: c.localForwards.map(\.localPort))
            return ports
        default:
            return [localPort]
        }
    }
}

extension Tunnel {
    public enum ValidationError: LocalizedError {
        case missingField(String)
        case portOutOfRange(Int, String)
        case portConflict(Int, String)

        public var errorDescription: String? {
            switch self {
            case .missingField(let f): return "Missing required field: \(f)"
            case .portOutOfRange(let p, let which): return "\(which) port \(p) out of range (1-65535)"
            case .portConflict(let p, let name): return "Local port \(p) already used by '\(name)'"
            }
        }
    }

    public func validate(against existing: [Tunnel], excluding excludedID: UUID? = nil) throws {
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ValidationError.missingField("name")
        }
        // All bound ports must be in range.
        for p in allLocalPorts() {
            guard (1...65535).contains(p) else {
                throw ValidationError.portOutOfRange(p, "Local")
            }
        }
        switch provider {
        case .gcpIAP(let c):
            if c.instance.trimmingCharacters(in: .whitespaces).isEmpty {
                throw ValidationError.missingField("instance")
            }
            if c.zone.trimmingCharacters(in: .whitespaces).isEmpty {
                throw ValidationError.missingField("zone")
            }
            if c.project.trimmingCharacters(in: .whitespaces).isEmpty {
                throw ValidationError.missingField("project")
            }
            guard (1...65535).contains(c.instancePort) else {
                throw ValidationError.portOutOfRange(c.instancePort, "Instance")
            }
        case .awsSSM(let c):
            if c.target.trimmingCharacters(in: .whitespaces).isEmpty {
                throw ValidationError.missingField("target")
            }
            guard (1...65535).contains(c.remotePort) else {
                throw ValidationError.portOutOfRange(c.remotePort, "Remote")
            }
        case .cloudSQLProxy(let c):
            let name = c.instanceConnectionName.trimmingCharacters(in: .whitespaces)
            if name.isEmpty {
                throw ValidationError.missingField("instance connection name")
            }
            let parts = name.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else {
                throw ValidationError.missingField("instance connection name (expected project:region:instance)")
            }
        case .ssh(let c):
            switch c.upstream {
            case .sshConfigAlias(let alias):
                if alias.trimmingCharacters(in: .whitespaces).isEmpty {
                    throw ValidationError.missingField("SSH host")
                }
            case .gcloudIAP(let instance, let zone, let project, _):
                if instance.trimmingCharacters(in: .whitespaces).isEmpty {
                    throw ValidationError.missingField("instance")
                }
                if zone.trimmingCharacters(in: .whitespaces).isEmpty {
                    throw ValidationError.missingField("zone")
                }
                if project.trimmingCharacters(in: .whitespaces).isEmpty {
                    throw ValidationError.missingField("project")
                }
            }
            // At least one forward must be configured, otherwise the tunnel does nothing.
            if c.socksPort == nil && c.localForwards.isEmpty {
                throw ValidationError.missingField("SOCKS port or at least one local forward")
            }
            for f in c.localForwards {
                if f.remoteHost.trimmingCharacters(in: .whitespaces).isEmpty {
                    throw ValidationError.missingField("forward remote host")
                }
                guard (1...65535).contains(f.remotePort) else {
                    throw ValidationError.portOutOfRange(f.remotePort, "Forward remote")
                }
            }
            if let patch = c.kubeconfigPatch {
                if patch.clusterName.trimmingCharacters(in: .whitespaces).isEmpty {
                    throw ValidationError.missingField("kubeconfig cluster name")
                }
                if c.socksPort == nil {
                    throw ValidationError.missingField("SOCKS port (required when patching kubeconfig)")
                }
            }
        }
        // Port-conflict detection across all tunnels and all of this tunnel's ports.
        let myPorts = Set(allLocalPorts())
        // Ports within the same tunnel must not collide.
        if myPorts.count != allLocalPorts().count {
            throw ValidationError.portConflict(allLocalPorts().first ?? localPort, name)
        }
        for t in existing where t.id != excludedID && t.id != id {
            let theirs = Set(t.allLocalPorts())
            if let clash = myPorts.intersection(theirs).first {
                throw ValidationError.portConflict(clash, t.name)
            }
        }
    }
}
