import Foundation

/// Filesystem layout the helper owns. All paths are absolute and live under
/// `/Library/Application Support/CloudTunnels/proxy/` so the helper running
/// as root has unambiguous write access regardless of the calling user.
public enum HelperPaths {
    public static let dataDirectory = URL(
        fileURLWithPath: "/Library/Application Support/CloudTunnels/proxy",
        isDirectory: true
    )

    public static var caCertPath: URL {
        dataDirectory.appendingPathComponent("ca/ca.pem")
    }

    public static var caKeyPath: URL {
        dataDirectory.appendingPathComponent("ca/ca.key")
    }

    public static var leavesDirectory: URL {
        dataDirectory.appendingPathComponent("leaves", isDirectory: true)
    }

    public static func ensureExists() throws {
        try FileManager.default.createDirectory(
            at: dataDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o755))]
        )
    }
}

/// Aggregate handle for every long-lived service the helper exposes over
/// XPC. Constructed once at startup by `main.swift` and shared with the
/// XPC delegate.
public final class HelperContext: @unchecked Sendable {
    public let dataDirectory: URL
    public let ca: LocalCA
    public let routeTable: RouteTable
    public let caddyManager: CaddyManager
    public let keychain: KeychainTrust
    public let hostsWriter: HostsFileWriter

    /// When this helper process started. Reported via `status()` so the
    /// UI can show uptime and detect silent restarts.
    public let bootTime: Date

    public init(dataDirectory: URL = HelperPaths.dataDirectory) throws {
        try HelperPaths.ensureExists()
        self.dataDirectory = dataDirectory

        let ca = try LocalCA.loadOrCreate(in: dataDirectory)
        let routeTable = RouteTable(ca: ca)
        let caddyManager = CaddyManager(
            configPath: dataDirectory.appendingPathComponent("caddy.json"),
            leavesDirectory: HelperPaths.leavesDirectory
        )

        self.ca = ca
        self.routeTable = routeTable
        self.caddyManager = caddyManager
        self.keychain = KeychainTrust()
        self.hostsWriter = HostsFileWriter()
        self.bootTime = Date()
    }
}
