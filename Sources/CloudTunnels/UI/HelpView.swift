import SwiftUI

struct HelpView: View {
    let onClose: () -> Void

    @State private var selection: HelpSection = .overview

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.4)
            detail
        }
        .frame(width: 760, height: 600)
        .background(
            HelpVisualEffect(material: .windowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Help").font(.system(size: 13, weight: .semibold))
                    Text("CloudTunnels guide")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider().opacity(0.3)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(HelpSection.allCases) { section in
                        sidebarItem(section)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }

            Divider().opacity(0.3)

            Button(action: onClose) {
                HStack {
                    Image(systemName: "xmark.circle")
                    Text("Close")
                    Spacer()
                    Text("⌘W").foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("w")
        }
        .frame(width: 220)
    }

    private func sidebarItem(_ section: HelpSection) -> some View {
        let isSelected = selection == section
        return Button {
            selection = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : section.accent)
                    .frame(width: 16)
                Text(section.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? section.accent : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: selection.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(selection.accent)
                    Text(selection.title)
                        .font(.system(size: 20, weight: .bold))
                    Spacer()
                }
                .padding(.bottom, 4)

                ForEach(Array(selection.blocks.enumerated()), id: \.offset) { _, block in
                    HelpBlockView(block: block)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Sections

enum HelpSection: String, CaseIterable, Identifiable {
    case overview
    case gcp
    case aws
    case cloudSQL
    case ssh
    case localProxy
    case tools
    case preferences
    case cli
    case troubleshooting

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .gcp: return "GCP IAP"
        case .aws: return "AWS SSM"
        case .cloudSQL: return "Cloud SQL Proxy"
        case .ssh: return "SSH"
        case .localProxy: return "Local HTTPS proxy"
        case .tools: return "Tools"
        case .preferences: return "Preferences"
        case .cli: return "CLI (ctun)"
        case .troubleshooting: return "Troubleshooting"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "sparkles"
        case .gcp: return "cloud.fill"
        case .aws: return "cloud.fill"
        case .cloudSQL: return "cylinder.split.1x2.fill"
        case .ssh: return "terminal.fill"
        case .localProxy: return "lock.shield"
        case .tools: return "hammer.fill"
        case .preferences: return "gearshape.fill"
        case .cli: return "chevron.left.forwardslash.chevron.right"
        case .troubleshooting: return "stethoscope"
        }
    }

    var accent: Color {
        switch self {
        case .overview: return .accentColor
        case .gcp: return .blue
        case .aws: return .orange
        case .cloudSQL: return .green
        case .ssh: return .indigo
        case .localProxy: return .pink
        case .tools: return .purple
        case .preferences: return .gray
        case .cli: return .teal
        case .troubleshooting: return .red
        }
    }

    var blocks: [HelpBlock] {
        switch self {
        case .overview: return overviewBlocks
        case .gcp: return gcpBlocks
        case .aws: return awsBlocks
        case .cloudSQL: return cloudSQLBlocks
        case .ssh: return sshBlocks
        case .localProxy: return localProxyBlocks
        case .tools: return toolsBlocks
        case .preferences: return preferencesBlocks
        case .cli: return cliBlocks
        case .troubleshooting: return troubleshootingBlocks
        }
    }
}

// MARK: - Block model

enum HelpBlock {
    case paragraph(String)
    case heading(String)
    case bullets([String])
    case fields([HelpField])
    case code(String)
    case note(String)
}

struct HelpField: Identifiable {
    let id = UUID()
    let name: String
    let description: String
}

// MARK: - Block view

private struct HelpBlockView: View {
    let block: HelpBlock

    var body: some View {
        switch block {
        case .paragraph(let text):
            Text(markdown(text))
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let text):
            Text(text)
                .font(.system(size: 14, weight: .semibold))
                .padding(.top, 6)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                        Text(markdown(item))
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .fields(let fields):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(fields) { field in
                    HStack(alignment: .top, spacing: 10) {
                        Text(field.name)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 140, alignment: .leading)
                        Text(markdown(field.description))
                            .font(.system(size: 11))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
        case .code(let text):
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .textSelection(.enabled)
        case .note(let text):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.yellow)
                    .padding(.top, 1)
                Text(markdown(text))
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.yellow.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.yellow.opacity(0.35), lineWidth: 0.5)
            )
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

// MARK: - Content

private let overviewBlocks: [HelpBlock] = [
    .paragraph("**CloudTunnels** is a native macOS menu-bar app for managing port-forwarding tunnels to cloud resources. It launches real CLI processes (`gcloud`, `aws`, `cloud-sql-proxy`, `ssh`), watches their stderr for listening markers, and exposes a clean start/stop UI plus quick actions (open in browser, copy `localhost:PORT`, open a psql/redis terminal)."),
    .heading("What it supports"),
    .bullets([
        "**GCP IAP** — TCP tunnels to Compute Engine VMs through Identity-Aware Proxy",
        "**AWS SSM** — Session Manager port-forwarding to EC2 instances",
        "**Cloud SQL Auth Proxy** — secure connections to Cloud SQL without public IPs",
        "**SSH** — local forwards, SOCKS proxies, and optional `gcloud compute ssh` wrapping with automatic **kubeconfig patching** for private GKE / Loft vCluster access"
    ]),
    .heading("How it works"),
    .bullets([
        "The menu-bar popover shows four provider tabs plus a Tools tab",
        "Each tunnel is a row with a Start/Stop toggle and a quick-action button",
        "Config lives at `~/Library/Application Support/CloudTunnels/config.json` and is shared with the `ctun` CLI",
        "The same config powers auto-start on launch, auto-reconnect on failure, and periodic auth validity checks"
    ]),
    .note("CloudTunnels never stores credentials. Authentication is delegated to the vendor CLIs (`gcloud`, `aws`) you already use.")
]

private let gcpBlocks: [HelpBlock] = [
    .paragraph("The **GCP IAP** provider wraps `gcloud compute start-iap-tunnel`, exposing a chosen Compute Engine VM port on a local port. Useful for SSH, databases, web UIs, or any TCP service behind IAP."),
    .heading("Prerequisites"),
    .bullets([
        "`gcloud` installed (Homebrew: `brew install --cask google-cloud-sdk`)",
        "Logged in: `gcloud auth login` (or use the **GCP login** item in the menu-bar footer)",
        "IAM: `roles/iap.tunnelResourceAccessor` on the project or VM",
        "The target VM's firewall must allow IAP source range `35.235.240.0/20` on the target port"
    ]),
    .heading("Fields"),
    .fields([
        HelpField(name: "Name", description: "Friendly label shown in the menu-bar row"),
        HelpField(name: "Instance", description: "Compute Engine VM name (e.g., `bastion-prod-us-central1`)"),
        HelpField(name: "Zone", description: "GCE zone (e.g., `us-central1-a`)"),
        HelpField(name: "Project", description: "GCP project ID hosting the VM"),
        HelpField(name: "Remote port", description: "Port on the VM to forward (e.g., `22` for SSH, `5432` for Postgres)"),
        HelpField(name: "Local port", description: "Port on your Mac to bind to. Defaults to the first free port from 8000+ to avoid collisions"),
        HelpField(name: "Account", description: "Which gcloud account to use. Leave blank to use the active one"),
        HelpField(name: "Impersonate SA", description: "Optional service account to impersonate via `--impersonate-service-account`")
    ]),
    .heading("Example"),
    .code("Instance:   prod-bastion-01\nZone:       us-central1-a\nProject:    acme-prod\nRemote port: 22\nLocal port: 8022\n→ ssh user@localhost -p 8022"),
    .note("If a tunnel reports *auth expired*, click **Sign in** on the account group header, or run `gcloud auth login` in a terminal. The app will reconnect automatically once your credentials refresh.")
]

private let awsBlocks: [HelpBlock] = [
    .paragraph("The **AWS SSM** provider wraps `aws ssm start-session` with the `AWS-StartPortForwardingSession` document to forward an EC2 instance port to a local port — no SSH keys or bastion required."),
    .heading("Prerequisites"),
    .bullets([
        "`aws` CLI v2 installed (`brew install awscli`)",
        "Session Manager plugin: `brew install --cask session-manager-plugin`",
        "An SSO profile configured in `~/.aws/config` with `sso_start_url`, `sso_region`, `sso_account_id`, `sso_role_name`",
        "Logged in: `aws sso login --profile <name>` (or use the **AWS SSO login** footer item)",
        "Target EC2 instance must have the SSM agent running and an IAM role including `AmazonSSMManagedInstanceCore`"
    ]),
    .heading("Fields"),
    .fields([
        HelpField(name: "Name", description: "Friendly label"),
        HelpField(name: "Instance ID", description: "EC2 instance ID (e.g., `i-0123456789abcdef0`)"),
        HelpField(name: "Region", description: "AWS region (e.g., `us-east-1`)"),
        HelpField(name: "Profile", description: "AWS CLI profile name — used for `--profile` and auth tracking"),
        HelpField(name: "Remote port", description: "Port on the EC2 instance"),
        HelpField(name: "Local port", description: "Port on your Mac")
    ]),
    .heading("Example"),
    .code("Instance ID: i-0abc123def456\nRegion:      us-east-1\nProfile:     prod-admin\nRemote port: 3306\nLocal port:  13306\n→ mysql -h 127.0.0.1 -P 13306 -u app -p"),
    .note("SSO sessions expire (typically 8–12h). The menu-bar group header turns orange with a **Sign in** button when the session is invalid.")
]

private let cloudSQLBlocks: [HelpBlock] = [
    .paragraph("The **Cloud SQL Auth Proxy** provider runs Google's `cloud-sql-proxy` binary, which authenticates to Cloud SQL with your gcloud credentials and exposes the database on a local port. Works for Postgres, MySQL, and SQL Server instances, including private-IP instances."),
    .heading("Prerequisites"),
    .bullets([
        "`cloud-sql-proxy` v2 on your `PATH` (`brew install cloud-sql-proxy`)",
        "`gcloud auth login` or `gcloud auth application-default login`",
        "IAM: `roles/cloudsql.client` on the instance (or `roles/cloudsql.instanceUser` if using IAM auth)"
    ]),
    .heading("Fields"),
    .fields([
        HelpField(name: "Name", description: "Friendly label"),
        HelpField(name: "Connection name", description: "Full instance connection name: `PROJECT:REGION:INSTANCE` (from the Cloud SQL instance overview page)"),
        HelpField(name: "Local port", description: "Port to bind. 5432 for Postgres, 3306 for MySQL, 1433 for SQL Server"),
        HelpField(name: "Account", description: "gcloud account to use. Passed as `CLOUDSDK_CORE_ACCOUNT` env var to cloud-sql-proxy"),
        HelpField(name: "Private IP", description: "Use the instance's private IP — required for private-only instances and VPC-peered setups"),
        HelpField(name: "IAM auth", description: "Use IAM DB auth instead of a password. Your gcloud account must have `roles/cloudsql.instanceUser`")
    ]),
    .heading("Example"),
    .code("Connection: acme-prod:us-central1:app-db-main\nLocal port: 5432\nPrivate IP: on\nIAM auth:   on\n→ psql \"host=127.0.0.1 port=5432 user=me@acme.com dbname=app\""),
    .note("The **quick action** on Cloud SQL tunnels opens `psql`/`mysql`/`sqlcmd` in your configured terminal app with the host and port pre-filled.")
]

private let sshBlocks: [HelpBlock] = [
    .paragraph("The **SSH** provider is the most flexible. It can run plain `ssh`, or wrap `gcloud compute ssh --tunnel-through-iap` so the IAP tunnel and SSH session share a single process. It supports multiple local forwards (`-L`), a SOCKS proxy (`-D`), and optional **kubeconfig patching** for private GKE and Loft vCluster workflows."),
    .heading("Prerequisites"),
    .bullets([
        "`ssh` (built into macOS) — always",
        "`gcloud` — only if you enable **Tunnel through IAP (gcloud)**",
        "`kubectl` — only if you enable **Kubeconfig patch**",
        "An entry in `~/.ssh/config` is not required but is used to populate the host dropdown"
    ]),
    .heading("Fields"),
    .fields([
        HelpField(name: "Name", description: "Friendly label"),
        HelpField(name: "Host", description: "SSH host alias or user@host. The dropdown lists hosts parsed from `~/.ssh/config`"),
        HelpField(name: "Extra args", description: "Raw args appended to the ssh command (e.g., `-o ServerAliveInterval=30`)"),
        HelpField(name: "Local forwards", description: "One or more `-L LOCAL:REMOTE_HOST:REMOTE_PORT` mappings. Each binds a local port on your Mac"),
        HelpField(name: "SOCKS port", description: "If set, adds `-D PORT` for a SOCKS5 proxy on localhost. Use this for kubeconfig patching"),
        HelpField(name: "Tunnel through IAP", description: "Switches the binary to `gcloud compute ssh` with `--tunnel-through-iap`. Requires GCP project/zone/instance fields"),
        HelpField(name: "Kubeconfig patch", description: "On connect, runs `kubectl config set-cluster <name> --proxy-url=socks5://127.0.0.1:<socksPort>`. On disconnect, unsets it. See GKE recipe below")
    ]),
    .heading("Private GKE / Loft vCluster recipe"),
    .paragraph("Reaching a private GKE control plane from your laptop requires four things — CloudTunnels only automates the last one:"),
    .bullets([
        "**(1) Fetch internal-IP credentials**: `gcloud container clusters get-credentials CLUSTER --region REGION --project PROJECT --internal-ip`",
        "**(2) Authorize the bastion**: the upstream VM must be on the cluster's **Control plane authorized networks** allow list",
        "**(3) Upstream in-VPC host**: the SSH target must be a VM inside the same VPC (or a peered VPC) as the GKE cluster",
        "**(4) Kubeconfig `proxy-url`**: CloudTunnels sets this automatically when the SSH tunnel connects, and clears it on disconnect"
    ]),
    .heading("Example — GKE private cluster via bastion"),
    .code("Host:          gke-bastion-prod\nSOCKS port:    1080\nKubeconfig patch:\n  Cluster:     gke_acme-prod_us-central1_app-cluster\n  Skip TLS:    on (if control plane uses an internal cert)\n→ kubectl get pods   # routes through SOCKS automatically"),
    .note("**Cluster name trap:** `kubectl config set-cluster` is an *upsert*. If you type a name that doesn't match exactly, it creates a stray empty entry and leaves the real one unpatched. The dropdown is populated from `kubectl config get-clusters` to prevent this — always pick from the list.")
]

private let toolsBlocks: [HelpBlock] = [
    .paragraph("The **Tools** tab is a collection of small utilities for day-to-day infra work. Everything runs locally — nothing leaves your Mac."),
    .fields([
        HelpField(name: "JWT Decoder", description: "Paste a JWT, see decoded header + payload with pretty-printed JSON and expiry detection"),
        HelpField(name: "JSON Formatter", description: "Pretty-print, minify, and validate JSON. Shows line/column of parse errors"),
        HelpField(name: "Port Inspector", description: "Lists processes holding a given local port (uses `lsof`). Handy before connecting a tunnel"),
        HelpField(name: "Public IP", description: "Shows your current public IP and basic geolocation via a public API"),
        HelpField(name: "Base64", description: "Encode / decode strings and files"),
        HelpField(name: "Hash Generator", description: "MD5, SHA-1, SHA-256, SHA-512 of a string"),
        HelpField(name: "UUID Generator", description: "Generate UUID v4 / v7 single or in bulk"),
        HelpField(name: "Timestamp Converter", description: "Unix epoch ↔ human date, with timezone picker"),
        HelpField(name: "kubectl Context", description: "Shows active context and lets you switch between clusters without leaving the app"),
        HelpField(name: "Scratchpad", description: "Persistent multi-tab text area for notes, curl commands, SQL snippets")
    ])
]

private let preferencesBlocks: [HelpBlock] = [
    .paragraph("Open **Preferences** from the gear icon in the menu-bar header."),
    .fields([
        HelpField(name: "Auto-reconnect", description: "On failure, retry up to 3 times with 10s delay. Skipped on auth-expired errors (those need interactive re-login)"),
        HelpField(name: "Auth check interval", description: "How often the app probes `gcloud auth list` and AWS SSO session validity in the background. 5–240 minutes"),
        HelpField(name: "Terminal app", description: "Which terminal the SSH and Redis quick actions launch (Terminal, iTerm2, Ghostty, Warp, etc.)"),
        HelpField(name: "HTTP client", description: "HTTP / HTTPS quick actions open this app. Bruno copies the URL to clipboard instead of launching")
    ]),
    .note("Preferences are stored alongside tunnel config at `~/Library/Application Support/CloudTunnels/config.json`.")
]

private let cliBlocks: [HelpBlock] = [
    .paragraph("`ctun` is a command-line companion that reads the same config file as the menu-bar app. Install with `make install-cli` (puts it at `/usr/local/bin/ctun`)."),
    .heading("Subcommands"),
    .fields([
        HelpField(name: "ctun list", description: "Show all configured tunnels, grouped by provider, with current status"),
        HelpField(name: "ctun start NAME", description: "Start a tunnel by name. Streams events to the terminal until you ^C"),
        HelpField(name: "ctun start NAME --detach", description: "Fork a background process and return immediately"),
        HelpField(name: "ctun stop NAME", description: "Stop a running tunnel. Works for both CLI- and GUI-started tunnels via a distributed notification"),
        HelpField(name: "ctun status", description: "Show currently running tunnels across both CLI and GUI"),
        HelpField(name: "ctun config path", description: "Print the config file path")
    ]),
    .note("The GUI and CLI share one config file, so a tunnel you added in the menu bar is immediately available to `ctun`, and vice versa.")
]

private let localProxyBlocks: [HelpBlock] = [
    .paragraph("CloudTunnels can terminate TLS for a real public hostname locally and reverse-proxy plaintext traffic into the matching tunnel. Useful for VPCE-style endpoints (e.g. **MWAA Airflow**) where the upstream cert is for the public name and your browser refuses to connect to `https://127.0.0.1:8443/` without warnings."),
    .heading("How it works"),
    .bullets([
        "A privileged launchd helper (`CloudTunnelsProxyHelper`) bound to port 443 routes by SNI to per-hostname leaf certs.",
        "Leaf certs are issued in-process by a local Certificate Authority generated on first install — no `mkcert`, no external binaries.",
        "The CA is added to `/Library/Keychains/System.keychain` once at install time, so Safari and Chrome trust the leaves without warnings.",
        "Per-tunnel `/etc/hosts` entries map the public hostname to `127.0.0.1` while the tunnel is connected.",
        "On disconnect, both the route and the `/etc/hosts` line are removed automatically."
    ]),
    .heading("First-time setup"),
    .bullets([
        "Open **Preferences → Local HTTPS proxy → Manage…**",
        "Click **Install Proxy Helper** — macOS prompts you in System Settings → Login Items.",
        "Toggle **CloudTunnelsProxyHelper** on. Status flips to *enabled*.",
        "Edit any AWS SSM tunnel and expand the **Local HTTPS proxy** section. Enter the FQDN you want to serve (e.g. `<uuid>-vpce.c6.airflow.us-west-2.on.aws`).",
        "Connect the tunnel. CloudTunnels generates the leaf cert, registers the route, and writes the `/etc/hosts` line. Open `https://<hostname>/` in Safari or Chrome."
    ]),
    .heading("Browser support"),
    .paragraph("Safari and Chrome (and any Chromium-based browser) trust the locally-installed CA transparently. **Firefox uses NSS instead of the System keychain** and will show a cert warning until you import the CA manually:"),
    .bullets([
        "Reveal the CA: **Preferences → Local HTTPS proxy → Reveal CA in Finder**.",
        "Firefox → Settings → Privacy & Security → Certificates → View Certificates → Authorities → Import → select `ca.pem` → trust for websites."
    ]),
    .heading("Troubleshooting"),
    .bullets([
        "**The banner says \"needs setup\":** at least one tunnel has the proxy enabled but the helper isn't installed/approved. Open Preferences → Local HTTPS proxy → Manage.",
        "**Browser still shows a cert warning in Safari/Chrome:** quit and relaunch the browser. Both keep their TLS trust cache for the lifetime of the process.",
        "**`curl: (7) Failed to connect to <host> port 443`:** the helper isn't running. Check `lsof -nP -iTCP:443 -sTCP:LISTEN` — you should see `CloudTunnelsProxyHelper`. If not, look at System Settings → Login Items.",
        "**Stale `/etc/hosts` line after a hard kill:** lines are tagged with the tunnel UUID — `grep CloudTunnels /etc/hosts` shows them. The next connect/disconnect cycle for that tunnel will clean it up, or use **Uninstall Helper** in Preferences to wipe everything."
    ]),
    .heading("Diagnostic logs"),
    .code("log stream --predicate 'subsystem == \"com.fourninecloud.cloud-tunnels.proxy-helper\"' --info"),
    .heading("File layout"),
    .code("/Library/Application Support/CloudTunnels/proxy/\n  ca/ca.pem        # local root cert (world-readable)\n  ca/ca.key        # local root key (root-only, 0600)\n  leaves/<host>.pem  # per-hostname leaf cert\n  leaves/<host>.key  # per-hostname leaf key\n/Library/Application Support/CloudTunnels/proxy/  ← writable by helper only\n/etc/hosts                                          ← tagged with # CloudTunnels:<uuid>"),
    .note("The helper is opt-in. If you never enable a Local HTTPS proxy on any tunnel, the helper is never installed and the rest of CloudTunnels behaves exactly as before.")
]

private let troubleshootingBlocks: [HelpBlock] = [
    .heading("Port already in use"),
    .paragraph("CloudTunnels picks the first free port starting at 8000+ when you open the Add form, but manually-entered ports can still collide. Use the **Port Inspector** tool to see which process holds the port, or change the local port in the Edit form."),
    .heading("Auth expired, won't reconnect"),
    .paragraph("Auto-reconnect is intentionally skipped on auth-expired errors — they require interactive re-login. Click **Sign in** on the orange group header, or run `gcloud auth login` / `aws sso login --profile NAME`."),
    .heading("kubectl works but tunnel is green"),
    .paragraph("Almost always the kubeconfig cluster name trap. Check for stray empty entries:"),
    .code("kubectl config view --raw -o jsonpath='{.clusters[?(@.cluster.server==\"\")].name}'"),
    .paragraph("Delete any strays with `kubectl config delete-cluster NAME` and re-create the tunnel picking the cluster from the dropdown."),
    .heading("Tunnel connects but traffic hangs (private GKE)"),
    .paragraph("The SSH tunnel and kubeconfig are only part of the picture. Verify: (a) you ran `get-credentials --internal-ip`, (b) the bastion VM is in the cluster's **Control plane authorized networks**, (c) the bastion is inside the cluster's VPC."),
    .heading("Build: permission denied on .build/apple"),
    .paragraph("XCBuild's CompilationCache can end up root-owned after a multi-arch release build. Fix:"),
    .code("sudo rm -rf .build/apple\n# or build into a separate path:\nswift build -c release --arch arm64 --arch x86_64 --build-path .build-universal")
]

// MARK: - Visual effect

private struct HelpVisualEffect: NSViewRepresentable {
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
