import Foundation

public struct CloudSQLProxyLauncher: TunnelLauncher {
    public let providerName = "Cloud SQL Proxy"

    public let listeningMarkers: [String] = [
        "The proxy has started successfully and is ready for new connections",
        "Ready for new connections",
        "Listening on",
    ]

    public let authFailurePatterns: [String] = [
        "reauthentication required",
        "could not find default credentials",
        "application default credentials",
        "invalid_grant",
        "token expired",
        "PermissionDenied",
        "permission denied",
        "invalid authentication credentials",
        "login required",
    ]

    public let fallbackConnectedSeconds: TimeInterval = 10

    public init() {}

    public func executableURL() throws -> URL {
        try CloudSQLProxyLocator.find()
    }

    public func arguments(for tunnel: Tunnel) throws -> [String] {
        guard case .cloudSQLProxy(let cfg) = tunnel.provider else {
            throw TunnelLauncherError.providerMismatch(
                expected: "cloudSQLProxy",
                got: tunnel.provider.kind.rawValue
            )
        }
        var args: [String] = [
            cfg.instanceConnectionName,
            "--address", "127.0.0.1",
            "--port", String(tunnel.localPort),
        ]
        if cfg.privateIP {
            args.append("--private-ip")
        }
        if cfg.autoIAMAuthn {
            args.append("--auto-iam-authn")
        }
        if let sa = cfg.impersonateServiceAccount, !sa.isEmpty {
            args.append(contentsOf: ["--impersonate-service-account", sa])
        }
        return args
    }

    public func environment(for tunnel: Tunnel) -> [String: String]? {
        guard case .cloudSQLProxy(let cfg) = tunnel.provider,
              let account = cfg.account, !account.isEmpty else {
            return nil
        }
        return ["CLOUDSDK_CORE_ACCOUNT": account]
    }
}
