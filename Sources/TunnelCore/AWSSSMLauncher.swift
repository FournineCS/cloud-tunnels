import Foundation

public struct AWSSSMLauncher: TunnelLauncher {
    public let providerName = "AWS SSM"

    /// session-manager-plugin emits these once the local listener is bound.
    public let listeningMarkers: [String] = [
        "Waiting for connections",
        "Port opened for sessionId",
    ]

    /// Stderr / stdout substrings that indicate credentials are expired or
    /// otherwise invalid. Case-insensitive match.
    public let authFailurePatterns: [String] = [
        "ExpiredToken",
        "The security token included in the request is expired",
        "Error when retrieving credentials from sso",
        "sso session has expired",
        "Token has expired",
        "InvalidClientTokenId",
        "AccessDeniedException",
        "UnrecognizedClientException",
    ]

    public let fallbackConnectedSeconds: TimeInterval = 10

    public init() {}

    public func executableURL() throws -> URL {
        try AWSLocator.findAWS()
    }

    public func arguments(for tunnel: Tunnel) throws -> [String] {
        guard case .awsSSM(let cfg) = tunnel.provider else {
            throw TunnelLauncherError.providerMismatch(expected: "awsSSM", got: tunnel.provider.kind.rawValue)
        }
        guard !cfg.target.isEmpty else {
            throw TunnelLauncherError.unsupportedConfig("AWS SSM target (instance ID) is required")
        }

        let parameters = try Self.buildParametersJSON(
            remoteHost: cfg.remoteHost,
            remotePort: cfg.remotePort,
            localPort: tunnel.localPort
        )
        let documentName = (cfg.remoteHost?.isEmpty == false)
            ? "AWS-StartPortForwardingSessionToRemoteHost"
            : "AWS-StartPortForwardingSession"

        var args: [String] = [
            "ssm", "start-session",
            "--target", cfg.target,
            "--document-name", documentName,
            "--parameters", parameters,
        ]
        if let profile = cfg.profile, !profile.isEmpty {
            args.append(contentsOf: ["--profile", profile])
        }
        if let region = cfg.region, !region.isEmpty {
            args.append(contentsOf: ["--region", region])
        }
        return args
    }

    /// Builds the `--parameters` JSON string. Uses `JSONEncoder` to avoid
    /// hand-rolled escaping bugs.
    public static func buildParametersJSON(
        remoteHost: String?,
        remotePort: Int,
        localPort: Int
    ) throws -> String {
        var dict: [String: [String]] = [
            "portNumber": [String(remotePort)],
            "localPortNumber": [String(localPort)],
        ]
        if let host = remoteHost, !host.isEmpty {
            dict["host"] = [host]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(dict)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
