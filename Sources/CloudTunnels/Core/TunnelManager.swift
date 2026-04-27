import Combine
import Foundation
import ProxyHelperShared
import TunnelCore
import os

@MainActor
final class TunnelManager: ObservableObject {
    @Published private(set) var tunnels: [Tunnel] = []
    @Published private(set) var statuses: [UUID: TunnelStatus] = [:]
    @Published var preferences: Preferences = .default

    var onAuthExpired: (() -> Void)?

    private let store: ConfigStore
    private let log = Logger(subsystem: "com.fourninecloud.cloud-tunnels", category: "manager")

    private var runners: [UUID: TunnelProcess] = [:]
    private var drainTasks: [UUID: Task<Void, Never>] = [:]
    private var reconnectAttempts: [UUID: Int] = [:]
    private var stopRequestObserver: NSObjectProtocol?
    private var patchedClusters: [UUID: KubeconfigPatch] = [:]
    private let kubeconfigPatcher = KubeconfigPatcher()

    /// Tracks which tunnels currently have an active local HTTPS proxy
    /// registration with the helper daemon. Used by the cleanup path so
    /// `removeLocalProxyIfNeeded` knows what to unregister even when the
    /// originating config has already been edited.
    private var activeProxies: [UUID: LocalHTTPSProxy] = [:]
    private let proxyClient = ProxyClient()
    let proxyInstaller = ProxyHelperInstaller()

    static let maxReconnectAttempts = 3
    static let reconnectDelaySeconds: UInt64 = 10

    init(store: ConfigStore = .shared) {
        self.store = store
        let cfg = store.load()
        self.tunnels = cfg.tunnels
        self.preferences = cfg.preferences
        for t in cfg.tunnels { statuses[t.id] = .disconnected }

        // Listen for `ctun stop <name>` requests so we disconnect the same
        // tunnel cleanly (no auto-reconnect race) when the CLI asks for it.
        self.stopRequestObserver = IPCNotifications.observeStopRequest { [weak self] id in
            Task { @MainActor in
                guard let self else { return }
                if self.tunnels.contains(where: { $0.id == id }) {
                    self.log.info("ipc stop request received for \(id.uuidString, privacy: .public)")
                    self.disconnect(id: id)
                }
            }
        }
    }

    deinit {
        if let stopRequestObserver {
            DistributedNotificationCenter.default().removeObserver(stopRequestObserver)
        }
    }

    // MARK: - CRUD

    func add(_ tunnel: Tunnel) throws {
        try tunnel.validate(against: tunnels)
        tunnels.append(tunnel)
        statuses[tunnel.id] = .disconnected
        try persist()
    }

    func update(_ tunnel: Tunnel) throws {
        guard let idx = tunnels.firstIndex(where: { $0.id == tunnel.id }) else { return }
        try tunnel.validate(against: tunnels, excluding: tunnel.id)
        tunnels[idx] = tunnel
        try persist()
    }

    func delete(id: UUID) {
        stop(id: id)
        tunnels.removeAll { $0.id == id }
        statuses.removeValue(forKey: id)
        try? persist()
    }

    func setPreferences(_ prefs: Preferences) {
        preferences = prefs
        try? persist()
    }

    private func persist() throws {
        try store.save(AppConfig(tunnels: tunnels, preferences: preferences))
    }

    // MARK: - Lifecycle

    func connect(id: UUID) {
        guard let tunnel = tunnels.first(where: { $0.id == id }) else { return }
        if let current = statuses[id], current.isActive { return }

        let launcher = LauncherFactory.launcher(for: tunnel)
        let runner = TunnelProcess(tunnel: tunnel, launcher: launcher)
        runners[id] = runner
        statuses[id] = .connecting

        let stream = runner.start()
        drainTasks[id] = Task { [weak self] in
            for await event in stream {
                await self?.handle(event: event, for: id)
            }
        }
    }

    func disconnect(id: UUID) {
        stop(id: id)
        statuses[id] = .disconnected
    }

    private func stop(id: UUID) {
        runners[id]?.stop()
        drainTasks[id]?.cancel()
        drainTasks[id] = nil
        runners[id] = nil
    }

    func disconnectAll() {
        for id in tunnels.map(\.id) { stop(id: id) }
    }

    func connectAutoStart() {
        for t in tunnels where t.autoConnect { connect(id: t.id) }
    }

    private func handle(event: TunnelEvent, for id: UUID) async {
        switch event {
        case .connecting:
            statuses[id] = .connecting
        case .connected:
            statuses[id] = .connected(since: Date())
            reconnectAttempts[id] = 0
            applyKubeconfigPatchIfNeeded(id: id)
            await applyLocalProxyIfNeeded(id: id)
        case .stopped:
            statuses[id] = .disconnected
            restoreKubeconfigPatchIfNeeded(id: id)
            await removeLocalProxyIfNeeded(id: id)
            stop(id: id)
        case .authExpired(let msg):
            statuses[id] = .error("Authentication expired — please re-login")
            restoreKubeconfigPatchIfNeeded(id: id)
            await removeLocalProxyIfNeeded(id: id)
            stop(id: id)
            log.error("tunnel \(id.uuidString, privacy: .public) auth expired: \(msg, privacy: .public)")
            onAuthExpired?()
        case .failed(let msg):
            statuses[id] = .error(msg)
            restoreKubeconfigPatchIfNeeded(id: id)
            await removeLocalProxyIfNeeded(id: id)
            stop(id: id)
            log.error("tunnel \(id.uuidString, privacy: .public) failed: \(msg, privacy: .public)")
            if preferences.autoReconnect {
                await scheduleReconnect(id: id)
            }
        }
    }

    // MARK: - Local HTTPS proxy lifecycle

    /// Mirrors `applyKubeconfigPatchIfNeeded` for the AWS-SSM-only local
    /// HTTPS proxy sidecar. Failures are non-fatal: we surface a notification
    /// and let the underlying tunnel stay connected so the user can still
    /// hit the upstream by IP/port if they want.
    private func applyLocalProxyIfNeeded(id: UUID) async {
        guard
            let tunnel = tunnels.first(where: { $0.id == id }),
            case .awsSSM(let cfg) = tunnel.provider,
            let proxy = cfg.localProxy
        else { return }

        proxyInstaller.refreshStatus()
        guard proxyInstaller.status.isEnabled else {
            log.info("Local proxy for \(tunnel.name, privacy: .public) skipped — helper not enabled")
            Notifications.post(
                title: "Local HTTPS proxy not enabled",
                body: "\(tunnel.name): install the proxy helper from Preferences → Local Proxy."
            )
            return
        }

        do {
            // Ask the helper to materialize the CA on disk, then install
            // it into the System keychain from the GUI side (the helper
            // can't do this itself — see SystemKeychainTrust).
            _ = try await proxyClient.ensureCAInstalled()
            try SystemKeychainTrust.installIfNeeded()
            try await proxyClient.addRoute(
                ProxyRoute(
                    tunnelID: id,
                    hostname: proxy.hostname,
                    upstreamPort: tunnel.localPort,
                    insecureUpstream: proxy.insecureUpstream
                )
            )
            if proxy.manageHosts {
                try await proxyClient.setHostsEntries([
                    HostsEntry(tunnelID: id, hostname: proxy.hostname)
                ])
            }
            activeProxies[id] = proxy
            log.info("Local proxy active for \(tunnel.name, privacy: .public) — https://\(proxy.hostname, privacy: .public)/")
        } catch {
            log.error("Local proxy setup failed for \(tunnel.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            Notifications.post(
                title: "Local HTTPS proxy failed",
                body: "\(tunnel.name): \(error.localizedDescription)"
            )
        }
    }

    /// Reverses whatever `applyLocalProxyIfNeeded` registered. Errors are
    /// swallowed — cleanup never throws into the tunnel teardown path.
    private func removeLocalProxyIfNeeded(id: UUID) async {
        guard let proxy = activeProxies.removeValue(forKey: id) else { return }
        do {
            try await proxyClient.removeRoute(hostname: proxy.hostname)
        } catch {
            log.error("removeRoute(\(proxy.hostname, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
        }
        if proxy.manageHosts {
            do {
                try await proxyClient.removeHostsEntries(tunnelID: id)
            } catch {
                log.error("removeHostsEntries(\(id.uuidString, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Kubeconfig lifecycle

    private func applyKubeconfigPatchIfNeeded(id: UUID) {
        guard let tunnel = tunnels.first(where: { $0.id == id }),
              case .ssh(let cfg) = tunnel.provider,
              let patch = cfg.kubeconfigPatch,
              let socksPort = cfg.socksPort else { return }
        do {
            try kubeconfigPatcher.apply(patch: patch, socksPort: socksPort)
            patchedClusters[id] = patch
        } catch {
            log.error("kubeconfig patch failed for \(tunnel.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            Notifications.post(
                title: "Kubeconfig patch failed",
                body: "\(tunnel.name): \(error.localizedDescription)"
            )
        }
    }

    private func restoreKubeconfigPatchIfNeeded(id: UUID) {
        guard let patch = patchedClusters.removeValue(forKey: id) else { return }
        kubeconfigPatcher.restore(patch: patch)
    }

    private func scheduleReconnect(id: UUID) async {
        let attempts = (reconnectAttempts[id] ?? 0) + 1
        reconnectAttempts[id] = attempts
        guard attempts <= Self.maxReconnectAttempts else {
            if case .error(let msg) = statuses[id] {
                statuses[id] = .error("Gave up after \(Self.maxReconnectAttempts) retries. \(msg)")
            }
            return
        }
        try? await Task.sleep(nanoseconds: Self.reconnectDelaySeconds * 1_000_000_000)
        connect(id: id)
    }
}
