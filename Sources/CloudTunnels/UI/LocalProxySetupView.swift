import AppKit
import CryptoKit
import ProxyHelperShared
import SwiftUI

/// Setup pane for the privileged proxy helper. Shows the SMAppService
/// install state, lets the user trigger registration, displays the local
/// CA fingerprint once it's available, and offers a Reveal-in-Finder for
/// the on-disk CA bundle.
struct LocalProxySetupView: View {
    @ObservedObject var installer: ProxyHelperInstaller
    let proxyClient: ProxyClient
    let onClose: () -> Void

    @State private var caPEM: String = ""
    @State private var caFingerprint: String = ""
    @State private var loadingCA = false
    @State private var lastError: String?
    @State private var refreshTimer: Timer?

    /// Latest liveness snapshot from the helper. `nil` means the helper
    /// is unreachable right now — that includes "not installed" and
    /// "crashed / stuck / not yet approved". Distinct from `installer.status`,
    /// which reports what SMAppService *thinks* about the daemon
    /// registration — not whether the process is actually responsive.
    @State private var helperStatus: HelperStatus?
    @State private var statusFetchedAt: Date?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            content
            Divider().opacity(0.4)
            footer
        }
        .frame(width: 480)
        .background(
            VisualEffect(material: .windowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
        .onAppear {
            installer.refreshStatus()
            startPolling()
            if installer.status.isEnabled {
                Task { await loadCAIfNeeded() }
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(statusColor.opacity(0.18))
                    .frame(width: 38, height: 38)
                Image(systemName: statusIcon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Local HTTPS proxy").font(.system(size: 14, weight: .semibold))
                Text(statusSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch installer.status {
            case .notRegistered, .notFound:
                installRow
            case .requiresApproval:
                approvalRow
            case .enabled:
                enabledRows
            }

            if let err = lastError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var installRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CloudTunnels needs a one-time setup to bind port 443 and manage TLS for your tunnels. The privileged helper runs only when you have at least one proxy-enabled tunnel.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Install Proxy Helper") {
                    do {
                        try installer.register()
                        installer.openSystemSettingsLoginItems()
                    } catch {
                        lastError = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
        }
    }

    private var approvalRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Almost there — open System Settings → Login Items and toggle CloudTunnelsProxyHelper on.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open System Settings") {
                    installer.openSystemSettingsLoginItems()
                }
                .buttonStyle(.borderedProminent)
                Button("Refresh") { installer.refreshStatus() }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var enabledRows: some View {
        healthPanel

        if !caFingerprint.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Local CA fingerprint (SHA-256)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(caFingerprint)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
            }
        } else if loadingCA {
            Text("Loading CA fingerprint…").font(.system(size: 10)).foregroundStyle(.secondary)
        }

        HStack {
            Button("Reveal CA in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([
                    URL(fileURLWithPath: "/Library/Application Support/CloudTunnels/proxy/ca/ca.pem")
                ])
            }
            Button("Uninstall Helper") { uninstall() }
                .foregroundStyle(.red)
            Spacer()
        }
    }

    /// The live helper health panel. Queries the helper every 2s via XPC
    /// so the user can see the actual running state — not just what
    /// SMAppService thinks the daemon registration is.
    @ViewBuilder
    private var healthPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let status = helperStatus {
                healthRow(
                    ok: true,
                    icon: "bolt.horizontal.circle.fill",
                    title: "Helper process is responding",
                    detail: "PID \(status.helperPID) · up \(Self.formatUptime(status.uptime))"
                )
                healthRow(
                    ok: status.listenerBound,
                    icon: status.listenerBound ? "network.badge.shield.half.filled" : "network.slash",
                    title: status.listenerBound
                        ? "Listening on :\(status.listenPort)"
                        : "Not listening on :\(status.listenPort) yet",
                    detail: status.listenerBound
                        ? "TLS terminator ready for configured routes"
                        : "Starts on first AWS SSM HTTPS tunnel connect"
                )
                healthRow(
                    ok: status.routeCount > 0,
                    icon: status.routeCount > 0 ? "point.3.connected.trianglepath.dotted" : "point.3.filled.connected.trianglepath.dotted",
                    title: status.routeCount > 0
                        ? "\(status.routeCount) active route\(status.routeCount == 1 ? "" : "s")"
                        : "No active routes",
                    detail: status.hostnames.isEmpty
                        ? "Connect an HTTPS tunnel to register one"
                        : status.hostnames.joined(separator: ", ")
                )
            } else {
                healthRow(
                    ok: false,
                    icon: "exclamationmark.triangle.fill",
                    title: "Helper is registered but not responding",
                    detail: "launchd has the daemon, but XPC ping failed. Try Uninstall Helper and re-install, or check Console.app for CloudTunnelsProxyHelper crashes."
                )
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private func healthRow(
        ok: Bool,
        icon: String,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ok ? .green : .orange)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private static func formatUptime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private func startPolling() {
        refreshTimer?.invalidate()
        // Kick an immediate refresh so the panel isn't empty for 2s.
        Task { @MainActor in await refreshHelperStatus() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in
                let prev = installer.status
                installer.refreshStatus()
                if installer.status.isEnabled, prev != .enabled {
                    await loadCAIfNeeded()
                }
                await refreshHelperStatus()
            }
        }
    }

    /// Fetch the live helper health via XPC. Only attempts the call when
    /// SMAppService says the daemon is enabled — otherwise we'd just get
    /// timeouts that flood the log with `XPC error: Couldn't communicate
    /// with a helper application.`
    private func refreshHelperStatus() async {
        guard installer.status.isEnabled else {
            helperStatus = nil
            return
        }
        let snapshot = await proxyClient.fetchStatus()
        helperStatus = snapshot
        statusFetchedAt = Date()
    }

    private func loadCAIfNeeded() async {
        guard caPEM.isEmpty, !loadingCA else { return }
        loadingCA = true
        defer { loadingCA = false }
        do {
            // Helper writes ca.pem to disk and returns the PEM. The keychain
            // install is GUI-side only — see SystemKeychainTrust for why.
            let pem = try await proxyClient.ensureCAInstalled()
            try SystemKeychainTrust.installIfNeeded()
            caPEM = pem
            caFingerprint = Self.fingerprint(forPEM: pem) ?? "unavailable"
            lastError = nil
        } catch SystemKeychainTrust.Error.userCancelled {
            lastError = "Keychain install cancelled. Tunnels will still run, but browsers will show a cert warning until you trust the CA."
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func uninstall() {
        Task {
            do {
                try await proxyClient.uninstall()
            } catch {
                lastError = error.localizedDescription
            }
            // Best-effort keychain cleanup. User may cancel the auth prompt
            // here — that's fine, the tunnels still work, the cert just
            // sticks around until they manually remove it.
            do {
                try SystemKeychainTrust.removeIfPresent()
            } catch SystemKeychainTrust.Error.userCancelled {
                // silent
            } catch {
                lastError = error.localizedDescription
            }
            installer.unregister()
            caPEM = ""
            caFingerprint = ""
        }
    }

    /// Strip the PEM armor and compute SHA-256 of the DER bytes — matches
    /// what `openssl x509 -fingerprint -sha256 -noout` prints. Useful for
    /// users to verify the cert manually if they want.
    private static func fingerprint(forPEM pem: String) -> String? {
        let lines = pem.split(separator: "\n").filter {
            !$0.contains("BEGIN CERTIFICATE") && !$0.contains("END CERTIFICATE")
        }
        let base64 = lines.joined()
        guard let der = Data(base64Encoded: base64) else { return nil }
        let digest = SHA256.hash(data: der)
        return digest.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

private struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blendingMode
    }
}

private extension LocalProxySetupView {
    var statusIcon: String {
        switch installer.status {
        case .enabled: return "lock.shield.fill"
        case .requiresApproval: return "exclamationmark.triangle.fill"
        case .notRegistered: return "lock.shield"
        case .notFound: return "questionmark.circle"
        }
    }

    var statusColor: Color {
        switch installer.status {
        case .enabled: return .green
        case .requiresApproval: return .orange
        case .notRegistered: return .accentColor
        case .notFound: return .red
        }
    }

    var statusSummary: String {
        switch installer.status {
        case .enabled: return "Privileged helper installed and reachable"
        case .requiresApproval: return "Waiting for approval in System Settings → Login Items"
        case .notRegistered: return "Not yet installed — click Install to begin"
        case .notFound: return "Helper bundle not found — rebuild the .app with `make app`"
        }
    }
}
