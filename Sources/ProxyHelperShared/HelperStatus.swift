import Foundation

/// Structured health snapshot returned by `ProxyHelperProtocol.status`.
/// Lives in `ProxyHelperShared` so both sides of the XPC boundary decode
/// it with the same schema.
public struct HelperStatus: Codable, Sendable, Equatable {
    /// Unix PID of the running helper process.
    public let helperPID: Int32

    /// True if the NIO listener is bound on `listenPort`.
    public let listenerBound: Bool

    /// The port the helper listens on for reverse-proxied HTTPS traffic
    /// (always 443 in v1, but reported so the UI doesn't hardcode it).
    public let listenPort: Int

    /// Number of routes currently registered with the helper.
    public let routeCount: Int

    /// Hostnames of the registered routes, sorted. Exposed so the UI can
    /// show the user exactly which hosts the helper will terminate TLS for.
    public let hostnames: [String]

    /// Helper process boot time. Uptime is derived client-side for display.
    public let bootTime: Date

    public init(
        helperPID: Int32,
        listenerBound: Bool,
        listenPort: Int,
        routeCount: Int,
        hostnames: [String],
        bootTime: Date
    ) {
        self.helperPID = helperPID
        self.listenerBound = listenerBound
        self.listenPort = listenPort
        self.routeCount = routeCount
        self.hostnames = hostnames
        self.bootTime = bootTime
    }

    public var uptime: TimeInterval {
        Date().timeIntervalSince(bootTime)
    }
}
