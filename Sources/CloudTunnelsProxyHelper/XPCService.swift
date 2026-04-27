import Foundation
import os
import ProxyHelperShared

/// NSXPC delegate + `ProxyHelperProtocol` implementation. Bridges every
/// XPC reply block onto the corresponding async service method via Tasks
/// because NSXPC reply blocks are synchronous and our backing services are
/// actor-isolated / async.
///
/// Connection authentication: for v1 we accept any connection that launchd
/// hands us. The launchd plist binds the Mach service to `AssociatedBundleIdentifiers`
/// which already restricts access to the parent app process. Code signing
/// + Team ID validation via `SecCodeCopyGuestWithAttributes` is on the v2
/// list (requires a stable Developer ID).
public final class XPCService: NSObject, NSXPCListenerDelegate, ProxyHelperProtocol, @unchecked Sendable {

    private let context: HelperContext
    private let log = Logger(
        subsystem: "com.fourninecloud.cloud-tunnels.proxy-helper",
        category: "XPCService"
    )

    public init(context: HelperContext) {
        self.context = context
        super.init()
    }

    // MARK: - NSXPCListenerDelegate

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        log.info("Accepting XPC connection from pid=\(newConnection.processIdentifier, privacy: .public)")

        let iface = NSXPCInterface(with: ProxyHelperProtocol.self)
        newConnection.exportedInterface = iface
        newConnection.exportedObject = self
        newConnection.invalidationHandler = { [weak self] in
            self?.log.info("XPC connection invalidated")
        }
        newConnection.interruptionHandler = { [weak self] in
            self?.log.info("XPC connection interrupted")
        }
        newConnection.resume()
        return true
    }

    // MARK: - ProxyHelperProtocol

    public func ping(reply: @escaping (Bool) -> Void) {
        reply(true)
    }

    public func status(reply: @escaping (Data?, NSError?) -> Void) {
        let context = self.context
        Task { [log] in
            let routes = await context.routeTable.snapshot()
            // "Listener bound" now means: caddy is alive AND we have
            // at least one route registered. With zero routes there's
            // no caddy process running, which is correct.
            let caddyAlive = await context.caddyManager.isRunning
            let snapshot = HelperStatus(
                helperPID: ProcessInfo.processInfo.processIdentifier,
                listenerBound: caddyAlive,
                listenPort: 443,
                routeCount: routes.count,
                hostnames: routes.map(\.hostname).sorted(),
                bootTime: context.bootTime
            )
            do {
                let data = try ProxyHelperCodec.encode(snapshot)
                reply(data, nil)
            } catch {
                log.error("status encode failed: \(error.localizedDescription, privacy: .public)")
                reply(nil, NSError.proxyHelper(.unknown, "\(error)"))
            }
        }
    }

    public func ensureCAInstalled(reply: @escaping (Data?, NSError?) -> Void) {
        // The helper only generates the CA on disk and returns its PEM. The
        // GUI process is responsible for installing it into /Library/Keychains/
        // System.keychain via `osascript ... with administrator privileges`,
        // because macOS requires a GUI authorization prompt for any trust-
        // settings modification — and a launchd daemon has no GUI session, so
        // SecTrustSettingsSetTrustSettings here always fails with
        // errSecInteractionNotAllowed. See SystemKeychainTrust on the GUI side.
        let context = self.context
        Task { [log] in
            let pem = await context.ca.rootCertificatePEM()
            log.info("CA generated/loaded; PEM returned to GUI for keychain install")
            reply(pem.data(using: .utf8), nil)
        }
    }

    public func addRoute(payload: Data, reply: @escaping (NSError?) -> Void) {
        let context = self.context
        Task { [log] in
            do {
                let route = try ProxyHelperCodec.decode(ProxyRoute.self, from: payload)
                // Issue/refresh the leaf cert+key on disk for this
                // hostname so Caddy can find them via load_files when
                // it reloads its config.
                _ = try await context.routeTable.upsert(route)
                let snapshot = await context.routeTable.snapshot()
                try await context.caddyManager.start(routes: snapshot)
                log.info("Added route \(route.hostname, privacy: .public) → 127.0.0.1:\(route.upstreamPort, privacy: .public) (caddy now serving \(snapshot.count, privacy: .public) route(s))")
                reply(nil)
            } catch let error as DecodingError {
                reply(NSError.proxyHelper(.decodeFailed, "Bad ProxyRoute payload: \(error)"))
            } catch {
                log.error("addRoute failed: \(error.localizedDescription, privacy: .public)")
                reply(NSError.proxyHelper(.listenerStartFailed, "\(error)"))
            }
        }
    }

    public func removeRoute(hostname: String, reply: @escaping (NSError?) -> Void) {
        let context = self.context
        Task { [log] in
            await context.routeTable.remove(hostname: hostname)
            let snapshot = await context.routeTable.snapshot()
            do {
                if snapshot.isEmpty {
                    // No more routes — stop Caddy entirely so it
                    // releases :443 cleanly.
                    await context.caddyManager.stop()
                } else {
                    try await context.caddyManager.reload(routes: snapshot)
                }
                log.info("Removed route \(hostname, privacy: .public) (caddy now serving \(snapshot.count, privacy: .public) route(s))")
                reply(nil)
            } catch {
                log.error("removeRoute reload failed: \(error.localizedDescription, privacy: .public)")
                reply(NSError.proxyHelper(.listenerStartFailed, "\(error)"))
            }
        }
    }

    public func listRoutes(reply: @escaping (Data?, NSError?) -> Void) {
        let context = self.context
        Task {
            let routes = await context.routeTable.snapshot()
            do {
                let data = try ProxyHelperCodec.encode(routes)
                reply(data, nil)
            } catch {
                reply(nil, NSError.proxyHelper(.unknown, "\(error)"))
            }
        }
    }

    public func setHostsEntries(payload: Data, reply: @escaping (NSError?) -> Void) {
        let context = self.context
        Task { [log] in
            do {
                let entries = try ProxyHelperCodec.decode([HostsEntry].self, from: payload)
                for entry in entries {
                    try context.hostsWriter.appending(
                        tunnelID: entry.tunnelID,
                        hostname: entry.hostname
                    )
                }
                log.info("Wrote \(entries.count, privacy: .public) /etc/hosts entries")
                reply(nil)
            } catch let error as DecodingError {
                reply(NSError.proxyHelper(.decodeFailed, "Bad HostsEntry payload: \(error)"))
            } catch {
                log.error("setHostsEntries failed: \(error.localizedDescription, privacy: .public)")
                reply(NSError.proxyHelper(.hostsWriteFailed, "\(error)"))
            }
        }
    }

    public func removeHostsEntries(tunnelIDString: String, reply: @escaping (NSError?) -> Void) {
        let context = self.context
        Task { [log] in
            guard let id = UUID(uuidString: tunnelIDString) else {
                reply(NSError.proxyHelper(.decodeFailed, "Bad tunnel UUID"))
                return
            }
            do {
                try context.hostsWriter.removingLines(taggedWith: id)
                log.info("Cleaned hosts entries for tunnel \(tunnelIDString, privacy: .public)")
                reply(nil)
            } catch {
                reply(NSError.proxyHelper(.hostsWriteFailed, "\(error)"))
            }
        }
    }

    public func uninstall(reply: @escaping (NSError?) -> Void) {
        let context = self.context
        Task { [log] in
            do {
                try context.hostsWriter.removingAllManagedLines()
            } catch {
                log.error("Hosts cleanup during uninstall failed: \(error.localizedDescription, privacy: .public)")
            }
            await context.caddyManager.stop()
            await context.routeTable.removeAll()
            context.keychain.removeRoot(commonName: LocalCA.commonName)
            log.info("Helper uninstall complete")
            reply(nil)
        }
    }
}
