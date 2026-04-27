import Foundation
import os
import ProxyHelperShared

/// GUI-side wrapper around the privileged proxy helper's NSXPC interface.
/// Exposes the @objc reply-block protocol as Swift `async throws` methods
/// and handles connection lifecycle (lazy connect, reconnect on invalidation,
/// typed errors).
///
/// The actual XPC machinery is intentionally stateless across calls — we
/// build a fresh `NSXPCConnection` per request rather than holding one
/// long-lived connection. This keeps the model simple, lets the helper
/// daemon restart underneath us without sticky stale state, and adds
/// negligible overhead since launchd caches the Mach service handle.
public actor ProxyClient {

    public enum Error: Swift.Error, LocalizedError {
        /// The helper is not registered with launchd at all (SMAppService
        /// status is `.notRegistered` or `.requiresApproval`). The caller
        /// should prompt the user to run the install flow.
        case helperNotInstalled
        /// The helper is registered but not currently reachable (crashed,
        /// disabled in System Settings, etc.). Usually transient.
        case helperUnreachable(String)
        /// The helper accepted the call but reported a failure via NSError.
        case helperReturnedError(NSError)
        /// Local encode/decode of the JSON payload across the XPC boundary.
        case codec(String)

        public var errorDescription: String? {
            switch self {
            case .helperNotInstalled:
                return "Local proxy helper is not installed. Open Preferences → Local Proxy to install it."
            case .helperUnreachable(let detail):
                return "Local proxy helper is unreachable: \(detail)"
            case .helperReturnedError(let err):
                return err.localizedDescription
            case .codec(let detail):
                return "XPC codec error: \(detail)"
            }
        }
    }

    private let log = Logger(
        subsystem: "com.fourninecloud.cloud-tunnels",
        category: "ProxyClient"
    )

    public init() {}

    // MARK: - Public surface

    /// Round-trip a no-op call to the helper. Returns `true` only if the
    /// helper is reachable and responsive.
    public func ping() async -> Bool {
        do {
            let proxy = try makeProxy()
            return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                proxy.ping { ok in cont.resume(returning: ok) }
            }
        } catch {
            return false
        }
    }

    /// Ask the helper for a full health snapshot: listener bind state,
    /// active routes, uptime, PID. Returns `nil` if the helper is
    /// unreachable so the UI can distinguish "not installed / not running"
    /// from "running but no routes".
    public func fetchStatus() async -> HelperStatus? {
        do {
            let proxy = try makeProxy()
            let result: (Data?, NSError?) = await withCheckedContinuation { cont in
                proxy.status { data, err in
                    cont.resume(returning: (data, err))
                }
            }
            if let err = result.1 {
                log.debug("status error: \(err.localizedDescription, privacy: .public)")
                return nil
            }
            guard let data = result.0 else { return nil }
            return try ProxyHelperCodec.decode(HelperStatus.self, from: data)
        } catch {
            log.debug("status call failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Asks the helper to load (or create) the local CA, install it into
    /// the System keychain, and return the PEM. The PEM is useful for
    /// displaying the fingerprint in the Preferences pane.
    @discardableResult
    public func ensureCAInstalled() async throws -> String {
        let proxy = try makeProxy()
        let result: (Data?, NSError?) = await withCheckedContinuation { cont in
            proxy.ensureCAInstalled { data, err in
                cont.resume(returning: (data, err))
            }
        }
        if let err = result.1 { throw Error.helperReturnedError(err) }
        guard let data = result.0, let pem = String(data: data, encoding: .utf8) else {
            throw Error.codec("ensureCAInstalled returned nil PEM")
        }
        return pem
    }

    public func addRoute(_ route: ProxyRoute) async throws {
        let proxy = try makeProxy()
        let payload: Data
        do {
            payload = try ProxyHelperCodec.encode(route)
        } catch {
            throw Error.codec("\(error)")
        }
        let err: NSError? = await withCheckedContinuation { cont in
            proxy.addRoute(payload: payload) { err in
                cont.resume(returning: err)
            }
        }
        if let err { throw Error.helperReturnedError(err) }
    }

    public func removeRoute(hostname: String) async throws {
        let proxy = try makeProxy()
        let err: NSError? = await withCheckedContinuation { cont in
            proxy.removeRoute(hostname: hostname) { err in
                cont.resume(returning: err)
            }
        }
        if let err { throw Error.helperReturnedError(err) }
    }

    public func listRoutes() async throws -> [ProxyRoute] {
        let proxy = try makeProxy()
        let result: (Data?, NSError?) = await withCheckedContinuation { cont in
            proxy.listRoutes { data, err in
                cont.resume(returning: (data, err))
            }
        }
        if let err = result.1 { throw Error.helperReturnedError(err) }
        guard let data = result.0 else { return [] }
        do {
            return try ProxyHelperCodec.decode([ProxyRoute].self, from: data)
        } catch {
            throw Error.codec("\(error)")
        }
    }

    public func setHostsEntries(_ entries: [HostsEntry]) async throws {
        let proxy = try makeProxy()
        let payload: Data
        do {
            payload = try ProxyHelperCodec.encode(entries)
        } catch {
            throw Error.codec("\(error)")
        }
        let err: NSError? = await withCheckedContinuation { cont in
            proxy.setHostsEntries(payload: payload) { err in
                cont.resume(returning: err)
            }
        }
        if let err { throw Error.helperReturnedError(err) }
    }

    public func removeHostsEntries(tunnelID: UUID) async throws {
        let proxy = try makeProxy()
        let err: NSError? = await withCheckedContinuation { cont in
            proxy.removeHostsEntries(tunnelIDString: tunnelID.uuidString.lowercased()) { err in
                cont.resume(returning: err)
            }
        }
        if let err { throw Error.helperReturnedError(err) }
    }

    public func uninstall() async throws {
        let proxy = try makeProxy()
        let err: NSError? = await withCheckedContinuation { cont in
            proxy.uninstall { err in
                cont.resume(returning: err)
            }
        }
        if let err { throw Error.helperReturnedError(err) }
    }

    // MARK: - Internals

    /// Build a one-shot NSXPC proxy object backed by a fresh connection.
    /// The connection is held alive by the proxy reference for the duration
    /// of the call; the reply block fires before the proxy goes out of scope.
    private func makeProxy() throws -> ProxyHelperProtocol {
        let connection = NSXPCConnection(
            machServiceName: ProxyHelperMachService.name,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: ProxyHelperProtocol.self)
        connection.invalidationHandler = { [log] in
            log.debug("XPC connection invalidated for \(ProxyHelperMachService.name, privacy: .public)")
        }
        connection.interruptionHandler = { [log] in
            log.debug("XPC connection interrupted for \(ProxyHelperMachService.name, privacy: .public)")
        }
        connection.resume()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [log] error in
            log.error("XPC error: \(error.localizedDescription, privacy: .public)")
        }) as? ProxyHelperProtocol else {
            throw Error.helperUnreachable("could not cast remote proxy to ProxyHelperProtocol")
        }
        return proxy
    }
}
