import AppKit
import Foundation
import TunnelCore
import os

@MainActor
enum QuickAction {
    private static let log = Logger(subsystem: "com.fourninecloud.cloud-tunnels", category: "quick-action")
    private static let connectTimeoutSeconds: TimeInterval = 30

    /// Run the appropriate quick action for the tunnel. Auto-connects first
    /// if the tunnel isn't already in `.connected` state. Posts a notification
    /// on failure.
    static func perform(for tunnel: Tunnel, manager: TunnelManager) async {
        let id = tunnel.id
        let terminalApp = manager.preferences.terminalApp
        let httpClient = manager.preferences.httpClient

        // Auto-connect-then-fire
        if !isConnected(id: id, manager: manager) {
            log.info("auto-connecting tunnel \(tunnel.name, privacy: .public) for quick action")
            manager.connect(id: id)
            let connected = await waitForConnected(id: id, manager: manager)
            if !connected {
                Notifications.post(
                    title: "CloudTunnels",
                    body: "\(tunnel.name): connect timed out — try again in a moment"
                )
                return
            }
        }

        await fire(action: tunnel, terminalApp: terminalApp, httpClient: httpClient)
    }

    private static func isConnected(id: UUID, manager: TunnelManager) -> Bool {
        if case .connected = manager.statuses[id] { return true }
        return false
    }

    private static func waitForConnected(id: UUID, manager: TunnelManager) async -> Bool {
        let deadline = Date().addingTimeInterval(connectTimeoutSeconds)
        while Date() < deadline {
            if isConnected(id: id, manager: manager) { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    // MARK: - Action dispatch

    private static func fire(action tunnel: Tunnel, terminalApp: TerminalApp, httpClient: HTTPClient) async {
        switch tunnel.kind {
        case .tcp:
            copyToPasteboard("localhost:\(tunnel.localPort)", reason: "\(tunnel.name) address copied")

        case .ssh:
            let command = sshCommand(for: tunnel)
            runTerminal(command: command, app: terminalApp)

        case .redis:
            let command = "redis-cli -h localhost -p \(tunnel.localPort)"
            runTerminal(command: command, app: terminalApp)

        case .k8s:
            // Prefer k9s (interactive TUI) over a one-shot kubectl
            // command — most users with a k8s tunnel are doing
            // exploration, not single-shot lookups. Falls back to
            // kubectl get pods if k9s isn't installed. Either way
            // the user runs against whatever their CURRENT kubectl
            // context is (use the cube button on the row to switch
            // it to the cluster bound to this tunnel first).
            let command = k8sQuickActionCommand()
            runTerminal(command: command, app: terminalApp)

        case .http, .https:
            if let url = url(for: tunnel) {
                openHTTP(url: url, client: httpClient, tunnelName: tunnel.name)
            } else {
                Notifications.post(
                    title: "CloudTunnels",
                    body: "\(tunnel.name): unable to build URL"
                )
            }

        case .vault, .elasticsearch:
            // Both expose an HTTP/S API + (Vault: UI) on a known port.
            // Open the appropriate URL in the user's preferred HTTP
            // client (system browser or Bruno).
            if let url = url(for: tunnel) {
                openHTTP(url: url, client: httpClient, tunnelName: tunnel.name)
            } else {
                Notifications.post(
                    title: "CloudTunnels",
                    body: "\(tunnel.name): unable to build URL"
                )
            }

        case .kafka:
            // Kafka is plain TCP with a binary protocol; no URL to
            // open. The most useful action is to put the bootstrap
            // address on the clipboard so the user can paste it into
            // their consumer/producer config.
            copyToPasteboard(
                "localhost:\(tunnel.localPort)",
                reason: "\(tunnel.name): Kafka bootstrap address copied"
            )

        case .vnc, .postgres, .mysql, .mongodb:
            if let url = url(for: tunnel) {
                openOrFallback(url: url, scheme: tunnel.kind.displayName)
            } else {
                Notifications.post(
                    title: "CloudTunnels",
                    body: "\(tunnel.name): unable to build URL"
                )
            }

        case .rdp:
            do {
                let fileURL = try writeRDPFile(for: tunnel)
                if !NSWorkspace.shared.open(fileURL) {
                    Notifications.post(
                        title: "CloudTunnels",
                        body: "Microsoft Remote Desktop not installed. RDP file at \(fileURL.path)"
                    )
                }
            } catch {
                Notifications.post(
                    title: "CloudTunnels",
                    body: "Failed to write RDP file: \(error.localizedDescription)"
                )
            }
        }
    }

    /// Picks the best available kubectl-adjacent command to run in
    /// Terminal for a Kubernetes tunnel. Prefers k9s (interactive TUI)
    /// when present because that's what most users want for a
    /// freshly-tunneled cluster.
    static func k8sQuickActionCommand() -> String {
        let candidates: [(path: String, command: String)] = [
            ("/opt/homebrew/bin/k9s", "k9s"),
            ("/usr/local/bin/k9s", "k9s"),
        ]
        let fm = FileManager.default
        for c in candidates where fm.isExecutableFile(atPath: c.path) {
            return c.command
        }
        return "kubectl get pods --all-namespaces"
    }

    // MARK: - URL builders (pure, testable)

    /// Builds the URL string for kinds that map to a URL scheme.
    /// Returns nil for kinds that don't (ssh, redis, rdp, tcp).
    ///
    /// HTTPS is special: when the tunnel has a local HTTPS proxy configured
    /// (AWS SSM only for v1), we open `https://<proxy-hostname>/` instead of
    /// `https://localhost:<port>/`. The proxy listens on port 443 and rewrites
    /// the Host header upstream, so the browser sees a green padlock and the
    /// upstream ALB routes correctly.
    static func url(for tunnel: Tunnel) -> URL? {
        switch tunnel.kind {
        case .http:
            return URL(string: "http://localhost:\(tunnel.localPort)\(normalizedPath(tunnel.actionConfig.path))")
        case .https:
            if let host = localProxyHostname(for: tunnel) {
                return URL(string: "https://\(host)\(normalizedPath(tunnel.actionConfig.path))")
            }
            return URL(string: "https://localhost:\(tunnel.localPort)\(normalizedPath(tunnel.actionConfig.path))")
        case .vault:
            // Vault defaults to HTTPS with self-signed certs in prod
            // but plain HTTP in dev mode. We can't tell which without
            // probing, so we follow the user's explicit choice via the
            // `path` field — if they typed a path starting with /ui
            // or /v1, default to HTTPS. Sensible default: /ui (Vault
            // web UI), since that's the most common manual-use case.
            let path = tunnel.actionConfig.path?.isEmpty == false
                ? normalizedPath(tunnel.actionConfig.path)
                : "/ui"
            return URL(string: "https://localhost:\(tunnel.localPort)\(path)")
        case .elasticsearch:
            // Elasticsearch / OpenSearch ships an HTTP API on 9200
            // with no UI. Default landing page is the cluster health
            // endpoint, which is the most useful "is it alive" check.
            let path = tunnel.actionConfig.path?.isEmpty == false
                ? normalizedPath(tunnel.actionConfig.path)
                : "/_cluster/health?pretty"
            return URL(string: "http://localhost:\(tunnel.localPort)\(path)")
        case .vnc:
            return URL(string: "vnc://localhost:\(tunnel.localPort)")
        case .postgres:
            return URL(string: "postgresql://localhost:\(tunnel.localPort)/\(tunnel.actionConfig.database ?? "")")
        case .mysql:
            return URL(string: "mysql://localhost:\(tunnel.localPort)/\(tunnel.actionConfig.database ?? "")")
        case .mongodb:
            return URL(string: "mongodb://localhost:\(tunnel.localPort)/\(tunnel.actionConfig.database ?? "")")
        case .tcp, .ssh, .rdp, .redis, .k8s, .kafka:
            return nil
        }
    }

    static func sshCommand(for tunnel: Tunnel) -> String {
        let userPrefix = (tunnel.actionConfig.username?.isEmpty == false)
            ? "\(tunnel.actionConfig.username!)@"
            : ""
        return "ssh -p \(tunnel.localPort) \(userPrefix)localhost"
    }

    static func rdpFileContent(for tunnel: Tunnel) -> String {
        var lines = [
            "full address:s:localhost:\(tunnel.localPort)",
            "prompt for credentials:i:1",
            "screen mode id:i:2",
        ]
        if let user = tunnel.actionConfig.username, !user.isEmpty {
            lines.append("username:s:\(user)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func normalizedPath(_ raw: String?) -> String {
        guard let p = raw, !p.isEmpty else { return "/" }
        return p.hasPrefix("/") ? p : "/\(p)"
    }

    /// Returns the local HTTPS proxy hostname for this tunnel, if any.
    /// AWS SSM is the only provider that carries `LocalHTTPSProxy` in v1.
    /// When set, the HTTPS quick action opens `https://<hostname>/` instead
    /// of the loopback URL — the proxy listener on :443 reverse-proxies to
    /// the SSM tunnel's local port with the right Host header.
    static func localProxyHostname(for tunnel: Tunnel) -> String? {
        if case .awsSSM(let cfg) = tunnel.provider,
           let proxy = cfg.localProxy,
           !proxy.hostname.isEmpty {
            return proxy.hostname
        }
        return nil
    }

    // MARK: - System bridges

    private static func openOrFallback(url: URL, scheme: String) {
        if NSWorkspace.shared.open(url) {
            log.info("opened url scheme=\(scheme, privacy: .public)")
            return
        }
        copyToPasteboard(url.absoluteString, reason: "No app for \(scheme). URL copied to clipboard.")
    }

    private static func runTerminal(command: String, app: TerminalApp) {
        switch app {
        case .ghostty:
            // Ghostty is a native arm64 terminal. On macOS the docs explicitly
            // say "use `open -na Ghostty.app --args -e <command>`" rather than
            // AppleScript. This avoids the AE permission dance entirely.
            runGhostty(command: command)
        case .terminal, .iterm2:
            runViaAppleScript(command: command, app: app)
        }
    }

    private static func runGhostty(command: String) {
        // Tokenize the command — `open --args` passes each arg literally.
        // We split on spaces; for our use cases (ssh / redis-cli) the
        // arguments don't contain quoted spaces.
        let tokens = command.split(separator: " ").map(String.init)
        let proc = Process()
        proc.launchPath = "/usr/bin/open"
        proc.arguments = ["-na", "Ghostty.app", "--args", "-e"] + tokens
        do {
            try proc.run()
        } catch {
            log.error("ghostty launch failed: \(error.localizedDescription, privacy: .public)")
            Notifications.post(
                title: "CloudTunnels",
                body: "Couldn't open Ghostty. Command copied to clipboard."
            )
            copyToPasteboard(command, reason: nil)
        }
    }

    private static func runViaAppleScript(command: String, app: TerminalApp) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script: String
        switch app {
        case .terminal:
            // For Terminal.app: `do script` opens a new window with the
            // command. Activate AFTER so the window is created before we
            // bring it forward.
            script = """
            tell application "Terminal"
                do script "\(escaped)"
                activate
            end tell
            """
        case .iterm2:
            // iTerm2 has its own scripting model. `create window with default
            // profile command "..."` runs the command in a new window.
            script = """
            tell application "iTerm"
                activate
                create window with default profile command "\(escaped)"
            end tell
            """
        case .ghostty:
            // Handled separately
            return
        }

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            if let error {
                log.error("AppleScript error (\(app.rawValue, privacy: .public)): \(String(describing: error), privacy: .public)")
                let appName = app.displayName
                Notifications.post(
                    title: "CloudTunnels",
                    body: "Couldn't open \(appName). Grant automation permission in System Settings → Privacy & Security → Automation, or check that \(appName) is installed. Command copied to clipboard."
                )
                copyToPasteboard(command, reason: nil)
            }
        }
    }

    /// Routes HTTP/HTTPS quick actions to either the system browser or Bruno.
    /// Bruno doesn't have a public "open this URL" scheme, so we open the app
    /// and put the URL on the pasteboard so the user can paste it into a new
    /// request.
    private static func openHTTP(url: URL, client: HTTPClient, tunnelName: String) {
        switch client {
        case .systemBrowser:
            openOrFallback(url: url, scheme: "HTTP")
        case .bruno:
            let brunoURL = URL(fileURLWithPath: "/Applications/Bruno.app")
            if NSWorkspace.shared.open(brunoURL) {
                copyToPasteboard(
                    url.absoluteString,
                    reason: "Bruno opened. URL for \(tunnelName) is on your clipboard — paste into a new request."
                )
            } else {
                Notifications.post(
                    title: "CloudTunnels",
                    body: "Bruno not found at /Applications/Bruno.app. Falling back to default browser."
                )
                openOrFallback(url: url, scheme: "HTTP")
            }
        }
    }

    private static func writeRDPFile(for tunnel: Tunnel) throws -> URL {
        let content = rdpFileContent(for: tunnel)
        let safeName = tunnel.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "_")
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-tunnel-\(safeName).rdp")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private static func copyToPasteboard(_ string: String, reason: String?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
        if let reason {
            Notifications.post(title: "CloudTunnels", body: reason)
        }
    }
}
