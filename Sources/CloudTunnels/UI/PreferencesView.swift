import SwiftUI
import TunnelCore

struct PreferencesView: View {
    @ObservedObject var manager: TunnelManager
    let onClose: () -> Void

    @State private var autoReconnect: Bool = true
    @State private var authCheckInterval: Int = 30
    @State private var terminalApp: TerminalApp = .terminal
    @State private var httpClient: HTTPClient = .systemBrowser
    @State private var showProxySetup: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            body_
            Divider().opacity(0.4)
            footer
        }
        .frame(width: 420)
        .background(
            PrefVisualEffect(material: .windowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
        .onAppear {
            autoReconnect = manager.preferences.autoReconnect
            authCheckInterval = manager.preferences.authCheckIntervalMin
            terminalApp = manager.preferences.terminalApp
            httpClient = manager.preferences.httpClient
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 38, height: 38)
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Preferences").font(.system(size: 14, weight: .semibold))
                Text("Global behavior and monitoring settings")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var body_: some View {
        VStack(alignment: .leading, spacing: 16) {
            PrefRow(
                icon: "arrow.clockwise.circle",
                title: "Auto-reconnect on failure",
                subtitle: "Retry up to 3 times with 10s delay if a tunnel drops (except on auth failures)"
            ) {
                Toggle("", isOn: $autoReconnect)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            Divider().opacity(0.3)

            PrefRow(
                icon: "clock.badge.checkmark",
                title: "Auth check interval",
                subtitle: "How often to verify that gcloud auth is still valid"
            ) {
                HStack(spacing: 6) {
                    Stepper("", value: $authCheckInterval, in: 5...240, step: 5)
                        .labelsHidden()
                    Text("\(authCheckInterval) min")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .frame(width: 48, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
            }

            Divider().opacity(0.3)

            PrefRow(
                icon: "terminal",
                title: "Terminal app",
                subtitle: "Used by SSH and Redis quick actions to open a terminal session"
            ) {
                Picker("", selection: $terminalApp) {
                    ForEach(TerminalApp.allCases, id: \.self) { app in
                        Text(app.displayName).tag(app)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 110)
            }

            Divider().opacity(0.3)

            PrefRow(
                icon: "safari",
                title: "HTTP client",
                subtitle: "Used by HTTP / HTTPS quick actions. Bruno opens the app and copies the URL to your clipboard."
            ) {
                Picker("", selection: $httpClient) {
                    ForEach(HTTPClient.allCases, id: \.self) { client in
                        Text(client.displayName).tag(client)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 140)
            }

            Divider().opacity(0.3)

            PrefRow(
                icon: "lock.shield",
                title: "Local HTTPS proxy",
                subtitle: proxyStatusSubtitle
            ) {
                Button("Manage…") { showProxySetup = true }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .sheet(isPresented: $showProxySetup) {
            LocalProxySetupView(
                installer: manager.proxyInstaller,
                proxyClient: ProxyClient()
            ) {
                showProxySetup = false
            }
        }
    }

    private var proxyStatusSubtitle: String {
        switch manager.proxyInstaller.status {
        case .enabled:
            return "Helper installed and reachable. Browse https://<vpce-host>/ for proxy-enabled tunnels."
        case .requiresApproval:
            return "Awaiting approval in System Settings → Login Items."
        case .notRegistered:
            return "Not installed — required only for tunnels with a Local HTTPS proxy enabled."
        case .notFound:
            return "Helper bundle not found — rebuild via make app."
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onClose)
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func save() {
        manager.setPreferences(Preferences(
            autoReconnect: autoReconnect,
            authCheckIntervalMin: authCheckInterval,
            terminalApp: terminalApp,
            httpClient: httpClient
        ))
        onClose()
    }
}

private struct PrefRow<Trailing: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22, height: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            trailing()
        }
    }
}

private struct PrefVisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}
