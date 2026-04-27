import SwiftUI

enum ToolCategory: String, CaseIterable, Hashable {
    case network
    case encoding
    case identifiers
    case generation
    case tls
    case cloud
    case productivity

    var displayName: String {
        switch self {
        case .network: return "Network"
        case .encoding: return "Encoding"
        case .identifiers: return "Identifiers"
        case .generation: return "Generation"
        case .tls: return "TLS / SSL"
        case .cloud: return "Cloud"
        case .productivity: return "Productivity"
        }
    }

    var sortOrder: Int {
        switch self {
        case .network: return 0
        case .encoding: return 1
        case .identifiers: return 2
        case .generation: return 3
        case .tls: return 4
        case .cloud: return 5
        case .productivity: return 6
        }
    }
}

struct ToolDefinition: Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String
    let category: ToolCategory
    let symbolName: String
    let accentColor: Color

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: ToolDefinition, rhs: ToolDefinition) -> Bool { lhs.id == rhs.id }
}

enum ToolRegistry {
    static let all: [ToolDefinition] = [
        ToolDefinition(
            id: "port-inspector",
            name: "Port Inspector",
            subtitle: "Find and kill processes by port",
            category: .network,
            symbolName: "network",
            accentColor: .blue
        ),
        ToolDefinition(
            id: "public-ip",
            name: "Public IP",
            subtitle: "Your current external IP",
            category: .network,
            symbolName: "globe",
            accentColor: .blue
        ),
        ToolDefinition(
            id: "json-formatter",
            name: "JSON Formatter",
            subtitle: "Pretty-print or minify JSON",
            category: .encoding,
            symbolName: "curlybraces",
            accentColor: .orange
        ),
        ToolDefinition(
            id: "base64",
            name: "Base64",
            subtitle: "Encode and decode base64",
            category: .encoding,
            symbolName: "arrow.left.arrow.right.square",
            accentColor: .orange
        ),
        ToolDefinition(
            id: "jwt-decoder",
            name: "JWT Decoder",
            subtitle: "Inspect JSON Web Tokens",
            category: .encoding,
            symbolName: "key.horizontal",
            accentColor: .orange
        ),
        ToolDefinition(
            id: "hash-generator",
            name: "Hash Generator",
            subtitle: "MD5 / SHA-1 / SHA-256 / SHA-512",
            category: .encoding,
            symbolName: "number.square",
            accentColor: .orange
        ),
        ToolDefinition(
            id: "ssl-checker",
            name: "SSL Checker",
            subtitle: "Fetch a live cert from host:port",
            category: .tls,
            symbolName: "network.badge.shield.half.filled",
            accentColor: .blue
        ),
        ToolDefinition(
            id: "cert-inspector",
            name: "Certificate Decoder",
            subtitle: "Decode PEM certs and check expiry",
            category: .tls,
            symbolName: "lock.doc.fill",
            accentColor: .blue
        ),
        ToolDefinition(
            id: "csr-inspector",
            name: "CSR Decoder",
            subtitle: "Inspect Certificate Signing Requests",
            category: .tls,
            symbolName: "doc.plaintext.fill",
            accentColor: .blue
        ),
        ToolDefinition(
            id: "key-matcher",
            name: "Certificate Key Matcher",
            subtitle: "Verify cert and key belong together",
            category: .tls,
            symbolName: "checkmark.shield.fill",
            accentColor: .blue
        ),
        ToolDefinition(
            id: "ssl-converter",
            name: "SSL Converter",
            subtitle: "PEM ↔ DER conversion",
            category: .tls,
            symbolName: "arrow.left.arrow.right.circle.fill",
            accentColor: .blue
        ),
        ToolDefinition(
            id: "uuid-generator",
            name: "UUID Generator",
            subtitle: "Generate UUIDv4 in bulk",
            category: .identifiers,
            symbolName: "barcode",
            accentColor: .purple
        ),
        ToolDefinition(
            id: "timestamp",
            name: "Timestamp",
            subtitle: "Unix epoch ↔ ISO 8601",
            category: .identifiers,
            symbolName: "clock.arrow.2.circlepath",
            accentColor: .purple
        ),
        ToolDefinition(
            id: "password-generator",
            name: "Password Generator",
            subtitle: "Strong random passwords",
            category: .generation,
            symbolName: "key.fill",
            accentColor: .pink
        ),
        ToolDefinition(
            id: "secret-generator",
            name: "JWT / HMAC Secret",
            subtitle: "Cryptographic signing keys",
            category: .generation,
            symbolName: "lock.shield.fill",
            accentColor: .indigo
        ),
        ToolDefinition(
            id: "ots-share",
            name: "Share Secret",
            subtitle: "One-time link via onetimesecret.com",
            category: .generation,
            symbolName: "link.badge.plus",
            accentColor: .teal
        ),
        ToolDefinition(
            id: "kubectl-context",
            name: "kubectl Context",
            subtitle: "Switch active Kubernetes context",
            category: .cloud,
            symbolName: "helm",
            accentColor: .green
        ),
        ToolDefinition(
            id: "kubeconfig-inspector",
            name: "Kubeconfig Inspector",
            subtitle: "Clusters, contexts, users at a glance",
            category: .cloud,
            symbolName: "doc.badge.gearshape",
            accentColor: .green
        ),
        ToolDefinition(
            id: "cluster-health",
            name: "Cluster Health",
            subtitle: "Probe every context for reachability",
            category: .cloud,
            symbolName: "network.badge.shield.half.filled",
            accentColor: .green
        ),
        ToolDefinition(
            id: "k8s-secret",
            name: "K8s Secret Coder",
            subtitle: "Encode / decode Secret YAML",
            category: .cloud,
            symbolName: "lock.square.stack.fill",
            accentColor: .green
        ),
        ToolDefinition(
            id: "cron-parser",
            name: "Cron Expression",
            subtitle: "Decode and preview next fire times",
            category: .cloud,
            symbolName: "clock.badge.checkmark.fill",
            accentColor: .green
        ),
        ToolDefinition(
            id: "scratchpad",
            name: "Scratchpad",
            subtitle: "Persistent quick notes",
            category: .productivity,
            symbolName: "note.text",
            accentColor: .pink
        ),
        ToolDefinition(
            id: "calendar",
            name: "Calendar",
            subtitle: "Upcoming meetings from Calendar.app",
            category: .productivity,
            symbolName: "calendar.badge.clock",
            accentColor: .orange
        ),
    ]

    static func tool(id: String) -> ToolDefinition? {
        all.first { $0.id == id }
    }

    static var byCategory: [(ToolCategory, [ToolDefinition])] {
        let grouped = Dictionary(grouping: all, by: { $0.category })
        return ToolCategory.allCases
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap { cat in
                guard let tools = grouped[cat], !tools.isEmpty else { return nil }
                return (cat, tools)
            }
    }
}
