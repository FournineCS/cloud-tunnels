import Foundation

/// NSXPC interface implemented by the privileged proxy helper daemon and
/// consumed by the CloudTunnels GUI process. All payloads are JSON-encoded
/// `Data` because NSXPCConnection cannot bridge Swift-only Codable types
/// directly — wrap/unwrap via `ProxyHelperCodec` on both sides.
///
/// The helper validates the calling process's code signature against the
/// app's expected signing identity inside its `NSXPCListenerDelegate`, so the
/// protocol itself does not carry credentials.
@objc public protocol ProxyHelperProtocol {
    /// Liveness probe.
    func ping(reply: @escaping (Bool) -> Void)

    /// Full health snapshot: process PID, listener bind state, route count,
    /// active hostnames, helper uptime. Encoded as JSON `HelperStatus`.
    /// Always succeeds when the helper is reachable — the status fields
    /// themselves describe any degraded sub-state.
    func status(reply: @escaping (Data?, NSError?) -> Void)

    /// Generate the local CA on first call (cached afterwards), install it
    /// into /Library/Keychains/System.keychain as a trusted root, and return
    /// the PEM-encoded CA cert so the GUI can display its fingerprint.
    func ensureCAInstalled(reply: @escaping (Data?, NSError?) -> Void)

    /// Add or replace a route. `payload` is JSON-encoded `ProxyRoute`.
    /// Idempotent: re-adding an existing hostname rebuilds its leaf cert
    /// and updates the upstream port without dropping the listener.
    func addRoute(payload: Data, reply: @escaping (NSError?) -> Void)

    /// Remove a single route by hostname. The listener stays up while any
    /// route remains; an empty route table starts a short grace period
    /// after which the listener shuts down.
    func removeRoute(hostname: String, reply: @escaping (NSError?) -> Void)

    /// Snapshot the current route table. Returns JSON-encoded `[ProxyRoute]`.
    func listRoutes(reply: @escaping (Data?, NSError?) -> Void)

    /// Append the given hostnames to /etc/hosts tagged with the tunnel UUID.
    /// `payload` is JSON-encoded `[HostsEntry]`. Idempotent.
    func setHostsEntries(payload: Data, reply: @escaping (NSError?) -> Void)

    /// Remove every /etc/hosts line tagged with the given tunnel UUID.
    /// `tunnelIDString` is the lowercase UUID string.
    func removeHostsEntries(tunnelIDString: String, reply: @escaping (NSError?) -> Void)

    /// Surrender all state: stop the listener, clear the route table, remove
    /// every CloudTunnels-tagged /etc/hosts line, remove the CA cert from the
    /// System keychain. Used by `make uninstall-helper` and the Reset button.
    func uninstall(reply: @escaping (NSError?) -> Void)
}

/// Shared JSON codec used on both sides of the NSXPC boundary. Keeps the
/// encoder and decoder configuration in one place so payload format never
/// drifts between GUI and helper.
public enum ProxyHelperCodec {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public static let decoder = JSONDecoder()

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}

/// Standard error domain for NSError values returned over the XPC boundary.
public let ProxyHelperErrorDomain = "com.fourninecloud.cloud-tunnels.proxy-helper"

public enum ProxyHelperErrorCode: Int {
    case unknown = 1
    case decodeFailed = 2
    case caUnavailable = 3
    case keychainTrustFailed = 4
    case listenerStartFailed = 5
    case hostsWriteFailed = 6
    case routeNotFound = 7
    case unauthorizedClient = 8
}

public extension NSError {
    /// Convenience constructor for helper-side error returns.
    static func proxyHelper(
        _ code: ProxyHelperErrorCode,
        _ message: String
    ) -> NSError {
        NSError(
            domain: ProxyHelperErrorDomain,
            code: code.rawValue,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
