import SwiftUI
import TunnelCore

struct AddEditTunnelView: View {
    @ObservedObject var manager: TunnelManager
    @ObservedObject var auth: AuthManager
    @ObservedObject var awsAuth: AWSAuthManager
    let editing: Tunnel?
    let defaultProvider: TunnelProvider
    let onClose: () -> Void

    // Common fields
    @State private var provider: TunnelProvider
    @State private var kind: TunnelKind
    @State private var name: String
    @State private var localPort: String
    @State private var autoConnect: Bool

    // Type-specific extras
    @State private var actionUsername: String
    @State private var actionPath: String
    @State private var actionDatabase: String

    // GCP fields
    @State private var instance: String
    @State private var instancePort: String
    @State private var zone: String
    @State private var project: String
    @State private var account: String

    // AWS fields
    @State private var awsTarget: String
    @State private var awsRemoteHost: String
    @State private var awsRemotePort: String
    @State private var awsProfile: String
    @State private var awsRegion: String
    // AWS local HTTPS proxy sidecar
    @State private var awsProxyEnabled: Bool
    @State private var awsProxyHostname: String
    @State private var awsProxyManageHosts: Bool
    @State private var awsProxyInsecureUpstream: Bool

    // Cloud SQL Proxy fields
    @State private var csqlInstance: String
    @State private var csqlAccount: String
    @State private var csqlPrivateIP: Bool
    @State private var csqlAutoIAMAuthn: Bool
    @State private var csqlImpersonate: String

    // SSH fields
    enum SSHUpstreamMode: Hashable { case sshConfig, gcloudIAP }

    struct LocalForwardDraft: Identifiable, Hashable {
        let id = UUID()
        var localPort: String
        var remoteHost: String
        var remotePort: String
    }

    @State private var sshUpstreamMode: SSHUpstreamMode
    @State private var sshHosts: [SSHConfigHost] = []
    @State private var kubectlClusters: [String] = []
    @State private var sshHostAlias: String
    @State private var sshGcloudInstance: String
    @State private var sshGcloudZone: String
    @State private var sshGcloudProject: String
    @State private var sshGcloudAccount: String
    @State private var sshSocksEnabled: Bool
    @State private var sshSocksPort: String
    @State private var sshLocalForwards: [LocalForwardDraft]
    @State private var sshKubeconfigEnabled: Bool
    @State private var sshKubeconfigCluster: String
    @State private var sshKubeconfigInsecure: Bool
    @State private var sshKubeconfigPath: String

    @State private var errorMessage: String?
    @FocusState private var focus: Field?
    private enum Field { case name }

    init(
        manager: TunnelManager,
        auth: AuthManager,
        awsAuth: AWSAuthManager,
        editing: Tunnel?,
        defaultProvider: TunnelProvider = .gcpIAP,
        onClose: @escaping () -> Void
    ) {
        self.manager = manager
        self.auth = auth
        self.awsAuth = awsAuth
        self.editing = editing
        self.defaultProvider = defaultProvider
        self.onClose = onClose

        let initialProvider: TunnelProvider = editing?.provider.kind ?? defaultProvider
        let initialKind: TunnelKind = editing?.kind ?? .tcp
        _provider = State(initialValue: initialProvider)
        _kind = State(initialValue: initialKind)
        _name = State(initialValue: editing?.name ?? "")
        _localPort = State(initialValue: editing.map { String($0.localPort) } ?? String(initialKind.defaultLocalPort))
        _autoConnect = State(initialValue: editing?.autoConnect ?? false)
        _actionUsername = State(initialValue: editing?.actionConfig.username ?? "")
        _actionPath = State(initialValue: editing?.actionConfig.path ?? "")
        _actionDatabase = State(initialValue: editing?.actionConfig.database ?? "")

        // GCP defaults
        if case .gcpIAP(let cfg) = editing?.provider {
            _instance = State(initialValue: cfg.instance)
            _instancePort = State(initialValue: String(cfg.instancePort))
            _zone = State(initialValue: cfg.zone)
            _project = State(initialValue: cfg.project)
            _account = State(initialValue: cfg.account ?? "")
        } else {
            _instance = State(initialValue: "")
            _instancePort = State(initialValue: "22")
            _zone = State(initialValue: "")
            _project = State(initialValue: "")
            _account = State(initialValue: "")
        }

        // AWS defaults
        if case .awsSSM(let cfg) = editing?.provider {
            _awsTarget = State(initialValue: cfg.target)
            _awsRemoteHost = State(initialValue: cfg.remoteHost ?? "")
            _awsRemotePort = State(initialValue: String(cfg.remotePort))
            _awsProfile = State(initialValue: cfg.profile ?? "")
            _awsRegion = State(initialValue: cfg.region ?? "")
            _awsProxyEnabled = State(initialValue: cfg.localProxy != nil)
            _awsProxyHostname = State(initialValue: cfg.localProxy?.hostname ?? "")
            _awsProxyManageHosts = State(initialValue: cfg.localProxy?.manageHosts ?? true)
            _awsProxyInsecureUpstream = State(initialValue: cfg.localProxy?.insecureUpstream ?? true)
        } else {
            _awsTarget = State(initialValue: "")
            _awsRemoteHost = State(initialValue: "")
            _awsRemotePort = State(initialValue: "5432")
            _awsProfile = State(initialValue: "")
            _awsRegion = State(initialValue: "")
            _awsProxyEnabled = State(initialValue: false)
            _awsProxyHostname = State(initialValue: "")
            _awsProxyManageHosts = State(initialValue: true)
            _awsProxyInsecureUpstream = State(initialValue: true)
        }

        // Cloud SQL Proxy defaults
        if case .cloudSQLProxy(let cfg) = editing?.provider {
            _csqlInstance = State(initialValue: cfg.instanceConnectionName)
            _csqlAccount = State(initialValue: cfg.account ?? "")
            _csqlPrivateIP = State(initialValue: cfg.privateIP)
            _csqlAutoIAMAuthn = State(initialValue: cfg.autoIAMAuthn)
            _csqlImpersonate = State(initialValue: cfg.impersonateServiceAccount ?? "")
        } else {
            _csqlInstance = State(initialValue: "")
            _csqlAccount = State(initialValue: "")
            _csqlPrivateIP = State(initialValue: false)
            _csqlAutoIAMAuthn = State(initialValue: false)
            _csqlImpersonate = State(initialValue: "")
        }

        // SSH defaults
        if case .ssh(let cfg) = editing?.provider {
            switch cfg.upstream {
            case .sshConfigAlias(let alias):
                _sshUpstreamMode = State(initialValue: .sshConfig)
                _sshHostAlias = State(initialValue: alias)
                _sshGcloudInstance = State(initialValue: "")
                _sshGcloudZone = State(initialValue: "")
                _sshGcloudProject = State(initialValue: "")
                _sshGcloudAccount = State(initialValue: "")
            case .gcloudIAP(let instance, let zone, let project, let account):
                _sshUpstreamMode = State(initialValue: .gcloudIAP)
                _sshHostAlias = State(initialValue: "")
                _sshGcloudInstance = State(initialValue: instance)
                _sshGcloudZone = State(initialValue: zone)
                _sshGcloudProject = State(initialValue: project)
                _sshGcloudAccount = State(initialValue: account ?? "")
            }
            _sshSocksEnabled = State(initialValue: cfg.socksPort != nil)
            _sshSocksPort = State(initialValue: cfg.socksPort.map(String.init) ?? "1080")
            _sshLocalForwards = State(initialValue: cfg.localForwards.map {
                LocalForwardDraft(
                    localPort: String($0.localPort),
                    remoteHost: $0.remoteHost,
                    remotePort: String($0.remotePort)
                )
            })
            _sshKubeconfigEnabled = State(initialValue: cfg.kubeconfigPatch != nil)
            _sshKubeconfigCluster = State(initialValue: cfg.kubeconfigPatch?.clusterName ?? "")
            _sshKubeconfigInsecure = State(initialValue: cfg.kubeconfigPatch?.insecureSkipTLSVerify ?? true)
            _sshKubeconfigPath = State(initialValue: cfg.kubeconfigPatch?.kubeconfigPath ?? "")
        } else {
            _sshUpstreamMode = State(initialValue: .sshConfig)
            _sshHostAlias = State(initialValue: "")
            _sshGcloudInstance = State(initialValue: "")
            _sshGcloudZone = State(initialValue: "")
            _sshGcloudProject = State(initialValue: "")
            _sshGcloudAccount = State(initialValue: "")
            _sshSocksEnabled = State(initialValue: true)
            _sshSocksPort = State(initialValue: "1080")
            _sshLocalForwards = State(initialValue: [])
            _sshKubeconfigEnabled = State(initialValue: false)
            _sshKubeconfigCluster = State(initialValue: "")
            _sshKubeconfigInsecure = State(initialValue: true)
            _sshKubeconfigPath = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            form
            Divider().opacity(0.4)
            footer
        }
        .frame(width: 480)
        .background(
            VisualEffect(material: .windowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
        .onAppear {
            focus = .name
            if sshHosts.isEmpty {
                sshHosts = SSHConfigParser.hosts()
            }
            if kubectlClusters.isEmpty {
                kubectlClusters = KubectlClustersList.fetch()
            }
            // For new tunnels, swap any "default" static port hint with the
            // first free local port not already claimed by another saved
            // tunnel or currently bound on 127.0.0.1. Only applies when the
            // user hasn't typed anything custom yet (i.e. the field still
            // holds a recognizable kind default).
            if editing == nil {
                // Generic single-port providers (GCP / AWS / Cloud SQL Proxy)
                if let cur = Int(localPort),
                   TunnelKind.allCases.contains(where: { $0.defaultLocalPort == cur }) {
                    localPort = String(freeLocalPort(startingAt: kind.defaultLocalPort))
                }
                // SSH SOCKS port default
                if sshSocksPort == "1080" {
                    sshSocksPort = String(freeLocalPort(startingAt: 1080))
                }
            }
        }
    }

    /// Finds a free local port starting at `base`, skipping ports already
    /// claimed by other saved tunnels and any port currently bound on
    /// 127.0.0.1. Excludes the tunnel under edit (if any) so its own ports
    /// don't shadow themselves.
    private func freeLocalPort(startingAt base: Int) -> Int {
        let editingID = editing?.id
        let claimed = Set(manager.tunnels.flatMap { t -> [Int] in
            if t.id == editingID { return [] }
            return t.allLocalPorts()
        })
        return PortUtil.firstFreeLocalPort(startingAt: base, excluding: claimed)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 38, height: 38)
                Image(systemName: editing == nil ? "plus.circle.fill" : "pencil.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(editing == nil ? "New Tunnel" : "Edit Tunnel")
                    .font(.system(size: 14, weight: .semibold))
                Text(editing == nil
                     ? "Configure a new port-forwarding tunnel"
                     : "Update the configuration for this tunnel")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Form

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                providerPicker
                kindPicker

                FormField(label: "Name", systemImage: "tag") {
                    TextField("e.g. prod-db", text: $name)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .name)
                }

                if provider != .ssh {
                    FormField(label: "Local port", systemImage: "laptopcomputer") {
                        TextField(String(kind.defaultLocalPort), text: $localPort)
                            .textFieldStyle(.plain)
                    }
                }

                kindExtras

                switch provider {
                case .gcpIAP: gcpFields
                case .awsSSM: awsFields
                case .cloudSQLProxy: cloudSQLProxyFields
                case .ssh: sshFields
                }

                Toggle(isOn: $autoConnect) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Auto-connect on launch").font(.system(size: 12, weight: .medium))
                        Text("Start this tunnel automatically when the app opens")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.top, 4)

                if let errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(errorMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.red.opacity(0.08))
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(maxHeight: 500)
    }

    // MARK: - Provider picker

    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "cloud")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("PROVIDER")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
            }
            Picker("", selection: $provider) {
                ForEach(TunnelProvider.allCases, id: \.self) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // MARK: - Type picker

    private var kindPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "tag.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("TYPE")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
            }
            Menu {
                ForEach(TunnelKind.allCases, id: \.self) { k in
                    Button {
                        kind = k
                        // If user hasn't typed a custom local port yet
                        // (matches some other kind's default), nudge it to a
                        // free port starting at the new kind's default.
                        if let current = Int(localPort), TunnelKind.allCases.contains(where: { $0.defaultLocalPort == current }) {
                            localPort = String(freeLocalPort(startingAt: k.defaultLocalPort))
                        }
                    } label: {
                        HStack {
                            Image(systemName: k.symbolName)
                            Text(k.displayName)
                            if kind == k { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: kind.symbolName)
                        .foregroundStyle(Color.accentColor)
                    Text(kind.displayName)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
    }

    // MARK: - Kind extras

    @ViewBuilder
    private var kindExtras: some View {
        if kind.supportsUsername {
            FormField(label: "Username (optional)", systemImage: "person") {
                TextField(NSUserName(), text: $actionUsername)
                    .textFieldStyle(.plain)
            }
        }
        if kind.supportsPath {
            FormField(label: "Path (optional)", systemImage: "link") {
                TextField("/", text: $actionPath)
                    .textFieldStyle(.plain)
            }
        }
        if kind.supportsDatabase {
            FormField(label: "Database (optional)", systemImage: "tray") {
                TextField("database name", text: $actionDatabase)
                    .textFieldStyle(.plain)
            }
        }
    }

    // MARK: - GCP fields

    @ViewBuilder
    private var gcpFields: some View {
        FormField(label: "Instance", systemImage: "server.rack") {
            TextField("e.g. prometheus-monitor-01", text: $instance)
                .textFieldStyle(.plain)
        }
        HStack(spacing: 12) {
            FormField(label: "Instance port", systemImage: "arrow.down.to.line") {
                TextField("22", text: $instancePort)
                    .textFieldStyle(.plain)
            }
            FormField(label: "Zone", systemImage: "globe") {
                TextField("us-central1-a", text: $zone)
                    .textFieldStyle(.plain)
            }
        }
        FormField(label: "Project", systemImage: "folder") {
            TextField("my-project", text: $project)
                .textFieldStyle(.plain)
        }
        FormField(label: "gcloud account", systemImage: "person.crop.circle") {
            Menu {
                Button { account = "" } label: {
                    HStack { Text("Use gcloud default"); if account.isEmpty { Image(systemName: "checkmark") } }
                }
                if !auth.accounts.isEmpty { Divider() }
                ForEach(auth.accounts) { a in
                    Button { account = a.email } label: {
                        HStack {
                            Text(a.email + (a.isActive ? " (default)" : ""))
                            if account == a.email { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                HStack {
                    Text(account.isEmpty ? "gcloud default account" : account)
                        .foregroundStyle(account.isEmpty ? .secondary : .primary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
    }

    // MARK: - AWS fields

    @ViewBuilder
    private var awsFields: some View {
        FormField(label: "Target (EC2 instance ID)", systemImage: "server.rack") {
            TextField("i-0123456789abcdef0", text: $awsTarget)
                .textFieldStyle(.plain)
        }
        FormField(label: "Remote host (optional)", systemImage: "arrow.triangle.branch") {
            TextField("db.prod.internal (leave empty for direct-to-instance)", text: $awsRemoteHost)
                .textFieldStyle(.plain)
        }
        HStack(spacing: 12) {
            FormField(label: "Remote port", systemImage: "arrow.down.to.line") {
                TextField("5432", text: $awsRemotePort)
                    .textFieldStyle(.plain)
            }
            FormField(label: "Region (optional)", systemImage: "globe") {
                TextField("us-west-2", text: $awsRegion)
                    .textFieldStyle(.plain)
            }
        }
        FormField(label: "AWS profile", systemImage: "person.crop.circle") {
            Menu {
                Button { awsProfile = "" } label: {
                    HStack { Text("Use default profile"); if awsProfile.isEmpty { Image(systemName: "checkmark") } }
                }
                if !awsAuth.allProfileNames.isEmpty { Divider() }
                ForEach(awsAuth.allProfileNames, id: \.self) { name in
                    Button { awsProfile = name } label: {
                        HStack {
                            Text(name)
                            if awsProfile == name { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                HStack {
                    Text(awsProfile.isEmpty ? "default" : awsProfile)
                        .foregroundStyle(awsProfile.isEmpty ? .secondary : .primary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }

        // Local HTTPS proxy sidecar — opt-in per tunnel. Off by default so
        // existing AWS SSM tunnels behave exactly as before.
        DisclosureGroup(isExpanded: $awsProxyEnabled) {
            VStack(alignment: .leading, spacing: 8) {
                FormField(label: "Hostname to serve locally", systemImage: "globe.badge.chevron.backward") {
                    TextField("vpce.example.com", text: $awsProxyHostname)
                        .textFieldStyle(.plain)
                }
                Text("CloudTunnels will bind https://\(awsProxyHostname.isEmpty ? "<hostname>" : awsProxyHostname)/ on port 443 and reverse-proxy to your local SSM port. Requires the helper installed once via Preferences → Local Proxy.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Toggle(isOn: $awsProxyManageHosts) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Manage /etc/hosts entry").font(.system(size: 12, weight: .medium))
                        Text("Add 127.0.0.1 → \(awsProxyHostname.isEmpty ? "<hostname>" : awsProxyHostname) on connect, remove on disconnect.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                Toggle(isOn: $awsProxyInsecureUpstream) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Skip upstream cert verification").font(.system(size: 12, weight: .medium))
                        Text("Required for VPCE endpoints whose cert is for the public hostname.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                Text("Local HTTPS proxy")
                    .font(.system(size: 12, weight: .medium))
            }
        }
    }

    // MARK: - Cloud SQL Proxy fields

    @ViewBuilder
    private var cloudSQLProxyFields: some View {
        FormField(label: "Instance connection name", systemImage: "externaldrive.connected.to.line.below") {
            TextField("project:region:instance", text: $csqlInstance)
                .textFieldStyle(.plain)
        }
        Toggle(isOn: $csqlPrivateIP) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Use private IP").font(.system(size: 12, weight: .medium))
                Text("Connect via the instance's private IP (--private-ip)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        Toggle(isOn: $csqlAutoIAMAuthn) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Auto IAM authentication").font(.system(size: 12, weight: .medium))
                Text("Use IAM DB authentication (--auto-iam-authn)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        FormField(label: "Impersonate service account (optional)", systemImage: "person.badge.key") {
            TextField("sa-name@project.iam.gserviceaccount.com", text: $csqlImpersonate)
                .textFieldStyle(.plain)
        }
        FormField(label: "gcloud account", systemImage: "person.crop.circle") {
            Menu {
                Button { csqlAccount = "" } label: {
                    HStack { Text("Use gcloud default"); if csqlAccount.isEmpty { Image(systemName: "checkmark") } }
                }
                if !auth.accounts.isEmpty { Divider() }
                ForEach(auth.accounts) { a in
                    Button { csqlAccount = a.email } label: {
                        HStack {
                            Text(a.email + (a.isActive ? " (default)" : ""))
                            if csqlAccount == a.email { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                HStack {
                    Text(csqlAccount.isEmpty ? "gcloud default account" : csqlAccount)
                        .foregroundStyle(csqlAccount.isEmpty ? .secondary : .primary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
    }

    // MARK: - SSH fields

    @ViewBuilder
    private var sshFields: some View {
        // Upstream mode picker
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("UPSTREAM")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
            }
            Picker("", selection: $sshUpstreamMode) {
                Text("~/.ssh/config alias").tag(SSHUpstreamMode.sshConfig)
                Text("gcloud IAP bastion").tag(SSHUpstreamMode.gcloudIAP)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        if sshUpstreamMode == .sshConfig {
            FormField(label: "SSH host", systemImage: "terminal") {
                Menu {
                    if sshHosts.isEmpty {
                        Text("No hosts in ~/.ssh/config").foregroundStyle(.secondary)
                    }
                    ForEach(sshHosts) { h in
                        Button {
                            sshHostAlias = h.alias
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(h.alias)
                                    if let via = h.proxyJump {
                                        Text("via \(via)")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if sshHostAlias == h.alias { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(sshHostAlias.isEmpty ? "Pick a host from ~/.ssh/config" : sshHostAlias)
                            .foregroundStyle(sshHostAlias.isEmpty ? .secondary : .primary)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }
        } else {
            FormField(label: "Instance", systemImage: "server.rack") {
                TextField("bastion-03", text: $sshGcloudInstance)
                    .textFieldStyle(.plain)
            }
            HStack(spacing: 12) {
                FormField(label: "Zone", systemImage: "globe") {
                    TextField("us-central1-a", text: $sshGcloudZone)
                        .textFieldStyle(.plain)
                }
                FormField(label: "Project", systemImage: "folder") {
                    TextField("my-gcp-project", text: $sshGcloudProject)
                        .textFieldStyle(.plain)
                }
            }
            FormField(label: "gcloud account", systemImage: "person.crop.circle") {
                Menu {
                    Button { sshGcloudAccount = "" } label: {
                        HStack { Text("Use gcloud default"); if sshGcloudAccount.isEmpty { Image(systemName: "checkmark") } }
                    }
                    if !auth.accounts.isEmpty { Divider() }
                    ForEach(auth.accounts) { a in
                        Button { sshGcloudAccount = a.email } label: {
                            HStack {
                                Text(a.email + (a.isActive ? " (default)" : ""))
                                if sshGcloudAccount == a.email { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(sshGcloudAccount.isEmpty ? "gcloud default account" : sshGcloudAccount)
                            .foregroundStyle(sshGcloudAccount.isEmpty ? .secondary : .primary)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }
        }

        // SOCKS5 toggle + port
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $sshSocksEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("SOCKS5 dynamic forward").font(.system(size: 12, weight: .medium))
                    Text("ssh -D <port> — for kubectl via HTTPS_PROXY or kubeconfig proxy-url")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            if sshSocksEnabled {
                FormField(label: "SOCKS port", systemImage: "network") {
                    TextField("1080", text: $sshSocksPort)
                        .textFieldStyle(.plain)
                }
            }
        }

        // Local forwards
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("LOCAL FORWARDS (-L)")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    // Pre-fill with a free port so repeated Add forward clicks
                    // don't all default to the same value.
                    let claimedByDrafts = Set(sshLocalForwards.compactMap { Int($0.localPort) })
                    let socksClaim: Set<Int> = Int(sshSocksPort).map { [$0] } ?? []
                    let base = 9440
                    let claimed = claimedByDrafts
                        .union(socksClaim)
                        .union(manager.tunnels.flatMap { t in editing?.id == t.id ? [] : t.allLocalPorts() })
                    let picked = PortUtil.firstFreeLocalPort(startingAt: base, excluding: claimed)
                    sshLocalForwards.append(LocalForwardDraft(
                        localPort: String(picked),
                        remoteHost: "",
                        remotePort: ""
                    ))
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus")
                        Text("Add forward")
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
            if sshLocalForwards.isEmpty {
                Text("No local forwards. Click Add forward to create one.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            ForEach($sshLocalForwards) { $fwd in
                HStack(spacing: 6) {
                    TextField("local", text: $fwd.localPort)
                        .textFieldStyle(.plain)
                        .frame(width: 56)
                        .font(.system(size: 11))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )
                    Text("→")
                        .foregroundStyle(.secondary)
                    TextField("remote host", text: $fwd.remoteHost)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )
                    Text(":")
                        .foregroundStyle(.secondary)
                    TextField("port", text: $fwd.remotePort)
                        .textFieldStyle(.plain)
                        .frame(width: 52)
                        .font(.system(size: 11))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )
                    Button {
                        sshLocalForwards.removeAll { $0.id == fwd.id }
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        // Kubeconfig patch
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $sshKubeconfigEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto-patch kubeconfig on connect").font(.system(size: 12, weight: .medium))
                    Text("Runs `kubectl config set-cluster --proxy-url=socks5://…` and restores on disconnect")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            if sshKubeconfigEnabled {
                FormField(label: "Cluster name", systemImage: "circle.hexagongrid") {
                    HStack(spacing: 4) {
                        TextField("gke_project_region_cluster", text: $sshKubeconfigCluster)
                            .textFieldStyle(.plain)
                        if !kubectlClusters.isEmpty {
                            Menu {
                                ForEach(kubectlClusters, id: \.self) { c in
                                    Button {
                                        sshKubeconfigCluster = c
                                    } label: {
                                        HStack {
                                            Text(c)
                                            if sshKubeconfigCluster == c { Image(systemName: "checkmark") }
                                        }
                                    }
                                }
                            } label: {
                                Image(systemName: "chevron.down.circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("Pick from kubectl config get-clusters")
                        }
                    }
                }
                if !kubectlClusters.isEmpty {
                    Text("\(kubectlClusters.count) cluster(s) from `kubectl config get-clusters` — use the dropdown to pick the exact name.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Toggle(isOn: $sshKubeconfigInsecure) {
                    Text("Skip TLS verify").font(.system(size: 11))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                FormField(label: "Kubeconfig path (optional)", systemImage: "doc.text") {
                    TextField("~/.kube/config (default)", text: $sshKubeconfigPath)
                        .textFieldStyle(.plain)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if editing != nil {
                Button(role: .destructive) {
                    if let t = editing {
                        manager.delete(id: t.id)
                        onClose()
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }
            Spacer()
            Button("Cancel", action: onClose)
                .keyboardShortcut(.cancelAction)
            Button(editing == nil ? "Add Tunnel" : "Save") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Save

    private func save() {
        errorMessage = nil
        // SSH tunnels compute their own primary port from SOCKS / first forward.
        // Other providers read it from the Local port field.
        let lport: Int
        if provider == .ssh {
            lport = 0  // overridden below after assembling SSHConfig
        } else {
            guard let parsed = Int(localPort.trimmingCharacters(in: .whitespaces)) else {
                errorMessage = "Local port must be a number"; return
            }
            lport = parsed
        }

        let providerConfig: ProviderConfig
        switch provider {
        case .gcpIAP:
            guard let iport = Int(instancePort.trimmingCharacters(in: .whitespaces)) else {
                errorMessage = "Instance port must be a number"; return
            }
            providerConfig = .gcpIAP(GCPIAPConfig(
                instance: instance.trimmingCharacters(in: .whitespaces),
                instancePort: iport,
                zone: zone.trimmingCharacters(in: .whitespaces),
                project: project.trimmingCharacters(in: .whitespaces),
                account: account.trimmingCharacters(in: .whitespaces).isEmpty ? nil : account
            ))
        case .awsSSM:
            guard let rport = Int(awsRemotePort.trimmingCharacters(in: .whitespaces)) else {
                errorMessage = "Remote port must be a number"; return
            }
            let proxy: LocalHTTPSProxy?
            if awsProxyEnabled {
                let trimmedHost = awsProxyHostname.trimmingCharacters(in: .whitespaces)
                if trimmedHost.isEmpty {
                    errorMessage = "Local HTTPS proxy hostname is required when the proxy is enabled."
                    return
                }
                proxy = LocalHTTPSProxy(
                    hostname: trimmedHost,
                    manageHosts: awsProxyManageHosts,
                    insecureUpstream: awsProxyInsecureUpstream
                )
            } else {
                proxy = nil
            }
            providerConfig = .awsSSM(AWSSSMConfig(
                target: awsTarget.trimmingCharacters(in: .whitespaces),
                remoteHost: awsRemoteHost.trimmingCharacters(in: .whitespaces).isEmpty ? nil : awsRemoteHost,
                remotePort: rport,
                profile: awsProfile.trimmingCharacters(in: .whitespaces).isEmpty ? nil : awsProfile,
                region: awsRegion.trimmingCharacters(in: .whitespaces).isEmpty ? nil : awsRegion,
                localProxy: proxy
            ))
        case .cloudSQLProxy:
            let trimmedImpersonate = csqlImpersonate.trimmingCharacters(in: .whitespaces)
            let trimmedAccount = csqlAccount.trimmingCharacters(in: .whitespaces)
            providerConfig = .cloudSQLProxy(CloudSQLProxyConfig(
                instanceConnectionName: csqlInstance.trimmingCharacters(in: .whitespaces),
                account: trimmedAccount.isEmpty ? nil : trimmedAccount,
                privateIP: csqlPrivateIP,
                autoIAMAuthn: csqlAutoIAMAuthn,
                impersonateServiceAccount: trimmedImpersonate.isEmpty ? nil : trimmedImpersonate
            ))
        case .ssh:
            // Assemble upstream
            let upstream: SSHUpstream
            switch sshUpstreamMode {
            case .sshConfig:
                let alias = sshHostAlias.trimmingCharacters(in: .whitespaces)
                if alias.isEmpty {
                    errorMessage = "Pick an SSH host from ~/.ssh/config"; return
                }
                upstream = .sshConfigAlias(alias)
            case .gcloudIAP:
                let instance = sshGcloudInstance.trimmingCharacters(in: .whitespaces)
                let zone = sshGcloudZone.trimmingCharacters(in: .whitespaces)
                let project = sshGcloudProject.trimmingCharacters(in: .whitespaces)
                if instance.isEmpty || zone.isEmpty || project.isEmpty {
                    errorMessage = "Instance, zone, and project are required"; return
                }
                let accountTrim = sshGcloudAccount.trimmingCharacters(in: .whitespaces)
                upstream = .gcloudIAP(
                    instance: instance,
                    zone: zone,
                    project: project,
                    account: accountTrim.isEmpty ? nil : accountTrim
                )
            }

            // SOCKS port
            var socksPort: Int? = nil
            if sshSocksEnabled {
                guard let sp = Int(sshSocksPort.trimmingCharacters(in: .whitespaces)), (1...65535).contains(sp) else {
                    errorMessage = "SOCKS port must be a number 1–65535"; return
                }
                socksPort = sp
            }

            // Local forwards
            var forwards: [SSHLocalForward] = []
            for draft in sshLocalForwards {
                let localStr = draft.localPort.trimmingCharacters(in: .whitespaces)
                let remoteHost = draft.remoteHost.trimmingCharacters(in: .whitespaces)
                let remoteStr = draft.remotePort.trimmingCharacters(in: .whitespaces)
                if localStr.isEmpty && remoteHost.isEmpty && remoteStr.isEmpty {
                    continue  // blank row, skip
                }
                guard let lp = Int(localStr), (1...65535).contains(lp) else {
                    errorMessage = "Forward local port must be a number 1–65535"; return
                }
                guard let rp = Int(remoteStr), (1...65535).contains(rp) else {
                    errorMessage = "Forward remote port must be a number 1–65535"; return
                }
                if remoteHost.isEmpty {
                    errorMessage = "Forward remote host is required"; return
                }
                forwards.append(SSHLocalForward(localPort: lp, remoteHost: remoteHost, remotePort: rp))
            }

            if socksPort == nil && forwards.isEmpty {
                errorMessage = "Enable SOCKS or add at least one local forward"; return
            }

            // Kubeconfig patch
            var patch: KubeconfigPatch? = nil
            if sshKubeconfigEnabled {
                let clusterName = sshKubeconfigCluster.trimmingCharacters(in: .whitespaces)
                if clusterName.isEmpty {
                    errorMessage = "Kubeconfig cluster name is required"; return
                }
                if socksPort == nil {
                    errorMessage = "Kubeconfig patching requires SOCKS port"; return
                }
                let pathTrim = sshKubeconfigPath.trimmingCharacters(in: .whitespaces)
                patch = KubeconfigPatch(
                    clusterName: clusterName,
                    insecureSkipTLSVerify: sshKubeconfigInsecure,
                    kubeconfigPath: pathTrim.isEmpty ? nil : pathTrim
                )
            }

            providerConfig = .ssh(SSHConfig(
                upstream: upstream,
                socksPort: socksPort,
                localForwards: forwards,
                kubeconfigPatch: patch
            ))
        }

        // For SSH, derive the "primary" local port from SOCKS (preferred) or first forward.
        let effectiveLocalPort: Int = {
            if case .ssh(let cfg) = providerConfig {
                return cfg.socksPort ?? cfg.localForwards.first?.localPort ?? 0
            }
            return lport
        }()

        let tunnel = Tunnel(
            id: editing?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            localPort: effectiveLocalPort,
            autoConnect: autoConnect,
            provider: providerConfig,
            kind: kind,
            actionConfig: ActionConfig(
                username: actionUsername.trimmingCharacters(in: .whitespaces).isEmpty ? nil : actionUsername.trimmingCharacters(in: .whitespaces),
                path: actionPath.trimmingCharacters(in: .whitespaces).isEmpty ? nil : actionPath.trimmingCharacters(in: .whitespaces),
                database: actionDatabase.trimmingCharacters(in: .whitespaces).isEmpty ? nil : actionDatabase.trimmingCharacters(in: .whitespaces)
            )
        )
        do {
            if editing == nil {
                try manager.add(tunnel)
            } else {
                try manager.update(tunnel)
            }
            onClose()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - FormField

private struct FormField<Content: View>: View {
    let label: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
            }
            content()
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
        }
    }
}

// MARK: - VisualEffect

private struct VisualEffect: NSViewRepresentable {
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
