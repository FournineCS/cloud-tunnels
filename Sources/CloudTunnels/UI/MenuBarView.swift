import AppKit
import SwiftUI
import TunnelCore

private struct TunnelGroup: Identifiable, Equatable {
    let key: String
    let tunnels: [Tunnel]
    var id: String { key }
}

enum MenuBarTab: Hashable {
    case provider(TunnelProvider)
    case tools
}

struct MenuBarView: View {
    @ObservedObject var manager: TunnelManager
    @ObservedObject var auth: AuthManager
    @ObservedObject var awsAuth: AWSAuthManager
    @EnvironmentObject var toasts: ToastManager
    @EnvironmentObject var calendar: CalendarManager

    var onOpenAddEdit: (Tunnel?, TunnelProvider) -> Void
    var onOpenPreferences: () -> Void
    var onOpenHelp: () -> Void
    var onOpenLogs: () -> Void
    var onAddGCPAccount: () -> Void
    var onRevokeGCPAccount: (String) -> Void
    var onAWSSsoLogin: (String) -> Void
    var onQuickAction: (Tunnel) -> Void
    var onActivateK8sContext: (Tunnel) -> Void
    var onQuit: () -> Void

    @State private var selectedTab: MenuBarTab = .provider(.gcpIAP)
    @State private var collapsedGroups: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            brandHeader
            UpcomingMeetingBanner(calendar: calendar)
            if needsProxyHelperSetup {
                proxyHelperBanner
            }
            tabBar
            Divider().opacity(0.5)
            tabContent
            ToastBanner(manager: toasts)
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 420)
        .background(
            VisualEffect(material: .popover, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
        .onAppear { manager.proxyInstaller.refreshStatus() }
    }

    /// Show the install banner only when the user has opted into the local
    /// proxy on at least one tunnel AND the helper is not yet ready. Keeps
    /// the popover unchanged for users who never enable the feature.
    private var needsProxyHelperSetup: Bool {
        let hasProxyTunnel = manager.tunnels.contains { tunnel in
            if case .awsSSM(let cfg) = tunnel.provider {
                return cfg.localProxy != nil
            }
            return false
        }
        return hasProxyTunnel && !manager.proxyInstaller.status.isEnabled
    }

    private var proxyHelperBanner: some View {
        Button(action: onOpenPreferences) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Local HTTPS proxy needs setup")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                    Text("Open Preferences → Local HTTPS proxy → Manage to install the helper.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Brand header

    private var brandHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            BrandImages.brandHeaderLogo
                .foregroundStyle(.primary)
            Text("CLOUD TUNNELS")
                .font(.system(size: 13, weight: .heavy))
                .tracking(1.4)
                .foregroundStyle(.primary)
            Spacer()
            Button(action: onOpenHelp) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Help")
            Button(action: onOpenPreferences) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Preferences")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 2) {
            tabButton(
                tab: .provider(.gcpIAP),
                label: "GCP",
                icon: "cloud.fill",
                accent: .blue,
                count: tunnels(for: .gcpIAP).count
            )
            tabButton(
                tab: .provider(.awsSSM),
                label: "AWS",
                icon: "cloud.fill",
                accent: .orange,
                count: tunnels(for: .awsSSM).count
            )
            tabButton(
                tab: .provider(.cloudSQLProxy),
                label: "SQL",
                icon: "cylinder.split.1x2.fill",
                accent: .green,
                count: tunnels(for: .cloudSQLProxy).count
            )
            tabButton(
                tab: .provider(.ssh),
                label: "SSH",
                icon: "terminal.fill",
                accent: .indigo,
                count: tunnels(for: .ssh).count
            )
            Spacer(minLength: 4)
            tabButton(
                tab: .tools,
                label: "Tools",
                icon: "hammer.fill",
                accent: .purple,
                count: 0
            )
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func tabButton(tab: MenuBarTab, label: String, icon: String, accent: Color, count: Int) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white : accent)
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .fixedSize()
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(isSelected ? Color.white.opacity(0.25) : accent.opacity(0.18))
                        )
                        .foregroundStyle(isSelected ? Color.white : accent)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? accent : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        ZStack {
            switch selectedTab {
            case .provider(let provider):
                providerTabContent(provider)
            case .tools:
                ToolsRootView()
            }
        }
        .frame(height: 360)
    }

    @ViewBuilder
    private func providerTabContent(_ provider: TunnelProvider) -> some View {
        let providerTunnels = tunnels(for: provider)
        if providerTunnels.isEmpty {
            emptyProviderState(provider)
        } else {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(grouped(providerTunnels)) { group in
                        TunnelGroupSection(
                            groupKey: group.key,
                            provider: provider,
                            tunnels: group.tunnels,
                            statuses: manager.statuses,
                            isValid: validity(for: group.key, provider: provider),
                            isCollapsed: collapsedGroups.contains(scopedKey(group.key, provider: provider)),
                            onToggleCollapse: {
                                let sk = scopedKey(group.key, provider: provider)
                                if collapsedGroups.contains(sk) {
                                    collapsedGroups.remove(sk)
                                } else {
                                    collapsedGroups.insert(sk)
                                }
                            },
                            onConnect: { manager.connect(id: $0) },
                            onDisconnect: { manager.disconnect(id: $0) },
                            onEdit: { onOpenAddEdit($0, provider) },
                            onDelete: { manager.delete(id: $0) },
                            onQuickAction: onQuickAction,
                            onActivateK8sContext: onActivateK8sContext,
                            onLoginGroup: {
                                switch provider {
                                case .gcpIAP, .cloudSQLProxy:
                                    onAddGCPAccount()
                                case .awsSSM:
                                    onAWSSsoLogin(group.key)
                                case .ssh:
                                    break
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private func emptyProviderState(_ provider: TunnelProvider) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.secondary)
            Text("No \(provider.displayName) tunnels yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Button {
                onOpenAddEdit(nil, provider)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                    Text("Add a tunnel")
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 0) {
            switch selectedTab {
            case .provider(let provider):
                MenuItemButton(
                    icon: "plus.circle",
                    title: "Add \(provider.displayName) tunnel…",
                    action: { onOpenAddEdit(nil, provider) }
                )
                switch provider {
                case .gcpIAP, .cloudSQLProxy:
                    MenuItemButton(
                        icon: "person.crop.circle.badge.plus",
                        title: "GCP login (gcloud auth login)",
                        action: onAddGCPAccount
                    )
                case .awsSSM:
                    MenuItemButton(
                        icon: "key.horizontal",
                        title: "AWS SSO login (default profile)",
                        action: { onAWSSsoLogin("") }
                    )
                case .ssh:
                    EmptyView()
                }
            case .tools:
                EmptyView()
            }
            MenuItemButton(
                icon: "doc.text.magnifyingglass",
                title: "View Logs…",
                shortcut: "⌘L",
                action: onOpenLogs
            )
            .keyboardShortcut("l")
            MenuItemButton(icon: "power", title: "Quit CloudTunnels", shortcut: "⌘Q", action: onQuit)
                .keyboardShortcut("q")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
    }

    // MARK: - Filtering / grouping

    private func tunnels(for provider: TunnelProvider) -> [Tunnel] {
        manager.tunnels.filter { $0.provider.kind == provider }
    }

    private func grouped(_ tunnels: [Tunnel]) -> [TunnelGroup] {
        let groupedDict = Dictionary(grouping: tunnels, by: { $0.accountKey })
        return groupedDict
            .map { TunnelGroup(key: $0.key, tunnels: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.key < $1.key }
    }

    private func scopedKey(_ groupKey: String, provider: TunnelProvider) -> String {
        "\(provider.rawValue):\(groupKey)"
    }

    private func validity(for groupKey: String, provider: TunnelProvider) -> Bool? {
        switch provider {
        case .gcpIAP, .cloudSQLProxy:
            return auth.accounts.first { $0.email == groupKey }?.isValid
        case .awsSSM:
            return awsAuth.profileStates[groupKey]?.isValid
        case .ssh:
            return nil
        }
    }
}

// MARK: - TunnelGroupSection

private struct TunnelGroupSection: View {
    let groupKey: String
    let provider: TunnelProvider
    let tunnels: [Tunnel]
    let statuses: [UUID: TunnelStatus]
    let isValid: Bool?
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void
    let onConnect: (UUID) -> Void
    let onDisconnect: (UUID) -> Void
    let onEdit: (Tunnel) -> Void
    let onDelete: (UUID) -> Void
    let onQuickAction: (Tunnel) -> Void
    let onActivateK8sContext: (Tunnel) -> Void
    let onLoginGroup: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggleCollapse) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .frame(width: 10)

                    statusDot

                    Text(displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text("\(tunnels.count)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 4)

                    if isValid == false {
                        Button(action: onLoginGroup) {
                            Text("Sign in")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .foregroundStyle(Color.orange)
                                .background(Capsule().fill(Color.orange.opacity(0.15)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? Color.primary.opacity(0.06) : Color.primary.opacity(0.03))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            if !isCollapsed {
                VStack(spacing: 1) {
                    ForEach(tunnels) { tunnel in
                        TunnelRow(
                            tunnel: tunnel,
                            status: statuses[tunnel.id] ?? .disconnected,
                            onToggle: {
                                let s = statuses[tunnel.id] ?? .disconnected
                                if s.isActive {
                                    onDisconnect(tunnel.id)
                                } else {
                                    onConnect(tunnel.id)
                                }
                            },
                            onEdit: { onEdit(tunnel) },
                            onDelete: { onDelete(tunnel.id) },
                            onQuickAction: { onQuickAction(tunnel) },
                            onActivateK8sContext: { onActivateK8sContext(tunnel) }
                        )
                    }
                }
                .padding(.leading, 14)
                .padding(.top, 2)
            }
        }
    }

    private var displayName: String {
        groupKey
    }

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 7, height: 7)
            .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
    }

    private var dotColor: Color {
        switch isValid {
        case .some(true): return .green
        case .some(false): return .orange
        case .none: return .gray
        }
    }
}

// MARK: - TunnelRow

private struct TunnelRow: View {
    let tunnel: Tunnel
    let status: TunnelStatus
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onQuickAction: () -> Void
    let onActivateK8sContext: (() -> Void)?

    @State private var hovering = false

    /// True if this row is an SSH tunnel with a kubeconfig patch
    /// configured AND is currently connected. We only show the
    /// "activate kubectl context" button when both are true —
    /// activating a context for a cluster whose proxy isn't actually
    /// running would just leave the user with a broken kubectl.
    private var canActivateK8sContext: Bool {
        guard onActivateK8sContext != nil else { return false }
        guard case .ssh(let cfg) = tunnel.provider else { return false }
        guard cfg.kubeconfigPatch != nil else { return false }
        return status.isActive
    }

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(status: status)
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(tunnel.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(tunnel.kind.displayName)
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.4)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.primary.opacity(0.08))
                        )
                        .foregroundStyle(.secondary)
                }
                Text("localhost:\(tunnel.localPort)  →  \(tunnel.provider.targetDescription)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            if hovering {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Edit")
                .transition(.opacity)

                if canActivateK8sContext, let action = onActivateK8sContext {
                    Button(action: action) {
                        Image(systemName: "cube.fill")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.purple)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.purple.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                    .help("Activate kubectl context for this cluster")
                    .transition(.opacity)
                }

                Button(action: onQuickAction) {
                    Image(systemName: tunnel.kind.symbolName)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.accentColor.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help(tunnel.kind.actionLabel)
                .transition(.opacity)
            }

            ToggleButton(status: status, action: onToggle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.05) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button(tunnel.kind.actionLabel, action: onQuickAction)
            Button("Copy localhost:\(tunnel.localPort)") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("localhost:\(tunnel.localPort)", forType: .string)
            }
            if canActivateK8sContext, let action = onActivateK8sContext {
                Divider()
                Button("Activate kubectl context", action: action)
            }
            Divider()
            Button("Edit…", action: onEdit)
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}

// MARK: - StatusDot

private struct StatusDot: View {
    let status: TunnelStatus
    @State private var pulse: Bool = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.2))
            Circle()
                .stroke(color.opacity(0.55), lineWidth: 1)
            if case .connected = status {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            } else if case .connecting = status {
                Circle()
                    .fill(color)
                    .frame(width: 4, height: 4)
                    .opacity(pulse ? 0.4 : 1.0)
                    .onAppear { pulse.toggle() }
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            } else if case .error = status {
                Image(systemName: "exclamationmark")
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundStyle(color)
            }
        }
    }

    private var color: Color {
        switch status {
        case .disconnected: return .gray
        case .connecting: return .yellow
        case .connected: return .green
        case .error: return .red
        }
    }
}

// MARK: - ToggleButton

private struct ToggleButton: View {
    let status: TunnelStatus
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: iconName)
                    .font(.system(size: 8, weight: .bold))
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(foreground)
            .background(Capsule().fill(background))
            .overlay(Capsule().stroke(foreground.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var iconName: String { status.isActive ? "stop.fill" : "play.fill" }
    private var label: String { status.isActive ? "Stop" : "Start" }
    private var foreground: Color { status.isActive ? .red : .green }
    private var background: Color {
        (status.isActive ? Color.red : Color.green).opacity(hovering ? 0.22 : 0.14)
    }
}

// MARK: - MenuItemButton

private struct MenuItemButton: View {
    let icon: String
    let title: String
    var shortcut: String? = nil
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(hovering ? Color.white : Color.primary)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(hovering ? Color.white : Color.primary)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 10))
                        .foregroundStyle(hovering ? Color.white.opacity(0.8) : Color.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hovering ? Color.accentColor : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - VisualEffect background

private struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}
