import Foundation

public struct SSHLauncher: TunnelLauncher {
    public let providerName = "SSH"

    // OpenSSH with -N -T is quiet. Rely on TunnelProcess fallback timer.
    public let listeningMarkers: [String] = []

    public let authFailurePatterns: [String] = [
        "Permission denied",
        "Host key verification failed",
        "no such identity",
        "Too many authentication failures",
        "Connection refused",
        "Connection timed out",
        "Could not resolve hostname",
        "No route to host",
        "channel_setup_fwd_listener_tcpip: cannot listen",
        // gcloud-wrapped SSH may surface these when IAP auth dies
        "UNAUTHENTICATED",
        "Reauthentication required",
        "login required",
        "token has been expired",
        "invalid_grant",
        "Invalid Credentials",
    ]

    public let fallbackConnectedSeconds: TimeInterval = 5

    public init() {}

    /// Not used by TunnelProcess — it calls `executableURL(for:)` below.
    /// Provided for protocol conformance; picks ssh as the default.
    public func executableURL() throws -> URL {
        try SSHLocator.find()
    }

    /// TunnelProcess calls this; SSH picks ssh or gcloud based on upstream mode.
    public func executableURL(for tunnel: Tunnel) throws -> URL {
        guard case .ssh(let cfg) = tunnel.provider else {
            throw TunnelLauncherError.providerMismatch(expected: "ssh", got: tunnel.provider.kind.rawValue)
        }
        switch cfg.upstream {
        case .sshConfigAlias:
            return try SSHLocator.find()
        case .gcloudIAP:
            return try GCloudLocator.find()
        }
    }

    public func arguments(for tunnel: Tunnel) throws -> [String] {
        guard case .ssh(let cfg) = tunnel.provider else {
            throw TunnelLauncherError.providerMismatch(expected: "ssh", got: tunnel.provider.kind.rawValue)
        }

        switch cfg.upstream {
        case .sshConfigAlias(let alias):
            var args = Self.sshForwardingArgs(cfg: cfg)
            args.append(alias)
            return args

        case .gcloudIAP(let instance, let zone, let project, let account):
            var args: [String] = [
                "compute", "ssh", instance,
                "--zone=\(zone)",
                "--project=\(project)",
            ]
            if let account, !account.isEmpty {
                args.append("--account=\(account)")
            }
            args.append("--tunnel-through-iap")
            args.append("--")
            args.append(contentsOf: Self.sshForwardingArgs(cfg: cfg))
            return args
        }
    }

    /// Builds the `-N -T -D ... -L ... -o ...` portion shared by both upstream
    /// modes. Exposed `internal` for unit tests.
    static func sshForwardingArgs(cfg: SSHConfig) -> [String] {
        var args: [String] = ["-N", "-T"]
        if let sp = cfg.socksPort {
            args.append("-D")
            args.append("127.0.0.1:\(sp)")
        }
        for fwd in cfg.localForwards {
            args.append("-L")
            args.append("\(fwd.localPort):\(fwd.remoteHost):\(fwd.remotePort)")
        }
        args.append(contentsOf: [
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
        ])
        return args
    }
}
