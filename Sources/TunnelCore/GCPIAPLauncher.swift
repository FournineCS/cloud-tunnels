import Foundation

public struct GCPIAPLauncher: TunnelLauncher {
    public let providerName = "GCP IAP"

    public let listeningMarkers: [String] = [
        "Listening on port"
    ]

    public let authFailurePatterns: [String] = [
        "UNAUTHENTICATED",
        "Reauthentication required",
        "login required",
        "token has been expired",
        "invalid_grant",
        "Invalid Credentials",
    ]

    public init() {}

    public func executableURL() throws -> URL {
        try GCloudLocator.find()
    }

    public func arguments(for tunnel: Tunnel) throws -> [String] {
        guard case .gcpIAP(let cfg) = tunnel.provider else {
            throw TunnelLauncherError.providerMismatch(expected: "gcpIAP", got: tunnel.provider.kind.rawValue)
        }
        var args: [String] = [
            "compute", "start-iap-tunnel",
            cfg.instance,
            String(cfg.instancePort),
            "--local-host-port=localhost:\(tunnel.localPort)",
            "--zone=\(cfg.zone)",
            "--project=\(cfg.project)",
        ]
        if let account = cfg.account, !account.isEmpty {
            args.append("--account=\(account)")
        }
        return args
    }
}
