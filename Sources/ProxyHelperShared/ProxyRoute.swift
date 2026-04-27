import Foundation

/// A single hostname → upstream port mapping the proxy helper should serve.
/// Encoded as JSON `Data` for transport across the NSXPC boundary because
/// NSXPCConnection cannot bridge Swift-only Codable types directly.
public struct ProxyRoute: Codable, Hashable, Sendable {
    /// Tunnel UUID this route belongs to. Used by the helper for cleanup
    /// when the GUI calls `removeRoute`.
    public var tunnelID: UUID
    /// FQDN the local NIO listener answers for. Becomes the cert SAN.
    public var hostname: String
    /// Loopback port the upstream tunnel is forwarding to (e.g. SSM local port).
    public var upstreamPort: Int
    /// Skip TLS verification when proxying to the upstream. True for VPCE
    /// endpoints whose cert is for the public hostname, not 127.0.0.1.
    public var insecureUpstream: Bool

    public init(
        tunnelID: UUID,
        hostname: String,
        upstreamPort: Int,
        insecureUpstream: Bool = true
    ) {
        self.tunnelID = tunnelID
        self.hostname = hostname
        self.upstreamPort = upstreamPort
        self.insecureUpstream = insecureUpstream
    }
}
