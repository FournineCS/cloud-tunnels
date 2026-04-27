import Foundation

public enum TunnelKind: String, Codable, CaseIterable, Hashable, Sendable {
    case tcp
    case ssh
    case http
    case https
    case k8s
    case rdp
    case vnc
    case postgres
    case mysql
    case mongodb
    case redis
    case vault
    case elasticsearch
    case kafka

    public var displayName: String {
        switch self {
        case .tcp: return "TCP"
        case .ssh: return "SSH"
        case .http: return "HTTP"
        case .https: return "HTTPS"
        case .k8s: return "Kubernetes"
        case .rdp: return "RDP"
        case .vnc: return "VNC"
        case .postgres: return "Postgres"
        case .mysql: return "MySQL"
        case .mongodb: return "MongoDB"
        case .redis: return "Redis"
        case .vault: return "Vault"
        case .elasticsearch: return "Elasticsearch"
        case .kafka: return "Kafka"
        }
    }

    /// SF Symbol shown in the row's quick-action button and in the form picker.
    public var symbolName: String {
        switch self {
        case .tcp: return "doc.on.doc"
        case .ssh: return "terminal"
        case .http: return "safari"
        case .https: return "lock.shield"
        case .k8s: return "circle.hexagongrid.fill"
        case .rdp: return "display"
        case .vnc: return "rectangle.connected.to.line.below"
        case .postgres: return "cylinder.split.1x2"
        case .mysql: return "cylinder"
        case .mongodb: return "leaf"
        case .redis: return "square.stack.3d.up"
        case .vault: return "key.viewfinder"
        case .elasticsearch: return "magnifyingglass.circle.fill"
        case .kafka: return "antenna.radiowaves.left.and.right"
        }
    }

    /// Short, hover-tooltip-friendly action label.
    public var actionLabel: String {
        switch self {
        case .tcp: return "Copy localhost address"
        case .ssh: return "Open in Terminal (ssh)"
        case .http: return "Open in browser"
        case .https: return "Open in browser"
        case .k8s: return "Open k9s / kubectl in Terminal"
        case .rdp: return "Open Microsoft Remote Desktop"
        case .vnc: return "Open Screen Sharing"
        case .postgres: return "Open Postgres client"
        case .mysql: return "Open MySQL client"
        case .mongodb: return "Open MongoDB Compass"
        case .redis: return "Open redis-cli in Terminal"
        case .vault: return "Open Vault UI in browser"
        case .elasticsearch: return "Open Elasticsearch in browser"
        case .kafka: return "Copy Kafka bootstrap address"
        }
    }

    public var supportsUsername: Bool {
        switch self { case .ssh, .rdp: return true; default: return false }
    }

    public var supportsPath: Bool {
        switch self {
        case .http, .https, .vault, .elasticsearch: return true
        default: return false
        }
    }

    public var supportsDatabase: Bool {
        switch self { case .postgres, .mysql, .mongodb: return true; default: return false }
    }

    /// Sensible default local port shown as a placeholder in the Add form
    /// when this kind is selected. Just a hint, not enforced.
    public var defaultLocalPort: Int {
        switch self {
        case .tcp: return 2222
        case .ssh: return 2222
        case .http: return 8080
        case .https: return 8443
        case .k8s: return 6443           // kube-apiserver default
        case .rdp: return 3389
        case .vnc: return 5900
        case .postgres: return 15432
        case .mysql: return 13306
        case .mongodb: return 27017
        case .redis: return 16379
        case .vault: return 8200         // Vault HTTP/HTTPS API + UI
        case .elasticsearch: return 9200 // Elasticsearch / OpenSearch HTTP API
        case .kafka: return 9092         // Kafka broker
        }
    }
}
