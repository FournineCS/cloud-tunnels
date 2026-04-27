import SwiftUI

struct ToolsRootView: View {
    @State private var path: [ToolDefinition] = []

    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(ToolRegistry.byCategory, id: \.0) { category, tools in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(category.displayName.uppercased())
                                .font(.system(size: 9, weight: .semibold))
                                .tracking(0.6)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                            LazyVGrid(columns: columns, spacing: 8) {
                                ForEach(tools) { tool in
                                    ToolTile(tool: tool) {
                                        path.append(tool)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            .navigationDestination(for: ToolDefinition.self) { tool in
                toolView(for: tool)
                    .navigationTitle(tool.name)
            }
        }
    }

    @ViewBuilder
    private func toolView(for tool: ToolDefinition) -> some View {
        switch tool.id {
        case "port-inspector":     PortInspectorView()
        case "public-ip":          PublicIPView()
        case "json-formatter":     JSONFormatterView()
        case "base64":             Base64View()
        case "jwt-decoder":        JWTDecoderView()
        case "hash-generator":     HashGeneratorView()
        case "ssl-checker":        SSLCheckerView()
        case "cert-inspector":     CertInspectorView()
        case "csr-inspector":      CSRInspectorView()
        case "key-matcher":        KeyMatcherView()
        case "ssl-converter":      SSLConverterView()
        case "uuid-generator":     UUIDGeneratorView()
        case "timestamp":          TimestampConverterView()
        case "password-generator": PasswordGeneratorView()
        case "secret-generator":   SecretGeneratorView()
        case "ots-share":          OneTimeSecretView()
        case "kubectl-context":    KubectlContextView()
        case "kubeconfig-inspector": KubeconfigInspectorView()
        case "cluster-health":     ClusterHealthView()
        case "k8s-secret":         K8sSecretCoderView()
        case "cron-parser":        CronParserView()
        case "scratchpad":         ScratchpadView()
        case "calendar":           CalendarView()
        default:                   Text("Unknown tool: \(tool.id)")
        }
    }
}
