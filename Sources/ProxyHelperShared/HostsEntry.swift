import Foundation

/// A single `127.0.0.1 <hostname>` line the helper should manage in /etc/hosts.
/// Tagged with the originating tunnel UUID so the helper can surgically
/// remove only its own lines on disconnect.
public struct HostsEntry: Codable, Hashable, Sendable {
    public var tunnelID: UUID
    public var hostname: String

    public init(tunnelID: UUID, hostname: String) {
        self.tunnelID = tunnelID
        self.hostname = hostname
    }
}
