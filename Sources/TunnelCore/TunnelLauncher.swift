import Foundation

/// Provider-specific subprocess launcher for one tunnel. Implementors define
/// how to locate their CLI, build the argv, and detect connection/auth state
/// from its stderr output.
public protocol TunnelLauncher: Sendable {
    var providerName: String { get }
    var listeningMarkers: [String] { get }
    var authFailurePatterns: [String] { get }
    var fallbackConnectedSeconds: TimeInterval { get }

    func executableURL() throws -> URL
    func executableURL(for tunnel: Tunnel) throws -> URL
    func arguments(for tunnel: Tunnel) throws -> [String]

    /// Optional extra environment variables to merge into the child process.
    /// Returning nil (the default) leaves the parent environment untouched.
    func environment(for tunnel: Tunnel) -> [String: String]?
}

extension TunnelLauncher {
    public var fallbackConnectedSeconds: TimeInterval { 15 }

    public func isAuthExpired(_ text: String) -> Bool {
        let lower = text.lowercased()
        return authFailurePatterns.contains { lower.contains($0.lowercased()) }
    }

    public func isListening(_ line: String) -> Bool {
        listeningMarkers.contains { line.contains($0) }
    }

    /// Default: ignore the tunnel and call the parameterless variant.
    /// Launchers that need tunnel-dependent binary selection (e.g. SSH)
    /// override this.
    public func executableURL(for tunnel: Tunnel) throws -> URL {
        try executableURL()
    }

    public func environment(for tunnel: Tunnel) -> [String: String]? { nil }
}

public enum TunnelLauncherError: LocalizedError {
    case providerMismatch(expected: String, got: String)
    case unsupportedConfig(String)

    public var errorDescription: String? {
        switch self {
        case .providerMismatch(let expected, let got):
            return "Launcher mismatch: expected \(expected), got \(got)"
        case .unsupportedConfig(let why):
            return why
        }
    }
}

/// Picks the right launcher for a tunnel's provider.
public enum LauncherFactory {
    public static func launcher(for tunnel: Tunnel) -> any TunnelLauncher {
        switch tunnel.provider {
        case .gcpIAP: return GCPIAPLauncher()
        case .awsSSM: return AWSSSMLauncher()
        case .cloudSQLProxy: return CloudSQLProxyLauncher()
        case .ssh: return SSHLauncher()
        }
    }
}
