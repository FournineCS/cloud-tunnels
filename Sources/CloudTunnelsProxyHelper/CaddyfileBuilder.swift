import Foundation
import ProxyHelperShared

/// Generates a Caddy v2 JSON config from the helper's route table.
///
/// We use Caddy's JSON API (not the Caddyfile format) because it's
/// structured, programmatically generated, and hot-reloadable via the
/// admin API at `POST http://127.0.0.1:2019/load`. The Caddyfile would
/// require an extra `caddy adapt` step at every reload.
///
/// The output mirrors the user's hand-written Caddyfile semantically:
///   - listen on `:443`
///   - one virtual host per route, matched by SNI + Host header
///   - per-host TLS using leaf certs that `LocalCA` writes to disk
///   - `reverse_proxy https://127.0.0.1:<upstreamPort>` with
///     `tls_insecure_skip_verify` — the SSM-tunneled upstream presents
///     a public-CA cert for a different name, so we accept it
///   - `header_up Host <public-hostname>` — explicit even though Caddy
///     preserves Host by default, matches the user's working config
public enum CaddyfileBuilder {

    /// Path Caddy writes its admin API to. Bound to loopback only — no
    /// non-root user on this machine should be able to control Caddy.
    public static let adminListen = "127.0.0.1:2019"

    /// Public listen address for the proxy server itself.
    public static let httpsListen = ":443"

    public static func build(
        routes: [ProxyRoute],
        leavesDirectory: URL
    ) throws -> Data {
        let config = makeConfig(routes: routes, leavesDirectory: leavesDirectory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(config)
    }

    // MARK: - Config tree

    static func makeConfig(
        routes: [ProxyRoute],
        leavesDirectory: URL
    ) -> CaddyConfig {
        // Per-host TLS cert files. Caddy auto-matches incoming SNI
        // against each cert's SAN/CN, so we don't need explicit
        // tls_connection_policies — just load_files and let it match.
        let certs: [CaddyConfig.Apps.TLS.LoadedCert] = routes.map { route in
            let host = route.hostname.lowercased()
            return .init(
                certificate: leavesDirectory.appendingPathComponent("\(host).pem").path,
                key: leavesDirectory.appendingPathComponent("\(host).key").path,
                tags: [host]
            )
        }

        // One Caddy "route" per ProxyRoute. Match by Host header,
        // rewrite Host to the public hostname (defensive — Caddy
        // preserves it by default but the user's working Caddyfile
        // sets it explicitly), reverse-proxy to the SSM tunnel
        // upstream over HTTPS with cert verification disabled.
        let httpRoutes: [CaddyConfig.Apps.HTTP.Route] = routes.map { route in
            CaddyConfig.Apps.HTTP.Route(
                match: [.init(host: [route.hostname])],
                handle: [
                    .init(
                        handler: "reverse_proxy",
                        upstreams: [
                            .init(dial: "127.0.0.1:\(route.upstreamPort)")
                        ],
                        headers: .init(
                            request: .init(
                                set: ["Host": [route.hostname]]
                            )
                        ),
                        transport: .init(
                            protocolName: "http",
                            tls: .init(insecureSkipVerify: route.insecureUpstream)
                        )
                    )
                ],
                terminal: true
            )
        }

        return CaddyConfig(
            admin: .init(listen: adminListen),
            apps: .init(
                tls: certs.isEmpty ? nil : .init(
                    certificates: .init(loadFiles: certs)
                ),
                http: .init(
                    servers: [
                        "main": .init(
                            listen: [httpsListen],
                            routes: httpRoutes
                        )
                    ]
                )
            ),
            logging: .init(
                logs: ["default": .init(level: "INFO")]
            )
        )
    }
}

// MARK: - Caddy v2 JSON schema (subset we use)

/// Minimal Codable mirror of Caddy v2's JSON config schema. Only the
/// fields we actually populate are modeled — Caddy ignores unknown
/// fields and fills in defaults for omitted ones.
public struct CaddyConfig: Codable, Equatable {
    public let admin: Admin
    public let apps: Apps
    public let logging: Logging?

    public struct Admin: Codable, Equatable {
        public let listen: String
    }

    public struct Apps: Codable, Equatable {
        public let tls: TLS?
        public let http: HTTP

        public struct TLS: Codable, Equatable {
            public let certificates: Certificates

            public struct Certificates: Codable, Equatable {
                public let loadFiles: [LoadedCert]
                enum CodingKeys: String, CodingKey { case loadFiles = "load_files" }
            }

            public struct LoadedCert: Codable, Equatable {
                public let certificate: String
                public let key: String
                public let tags: [String]
            }
        }

        public struct HTTP: Codable, Equatable {
            public let servers: [String: Server]

            public struct Server: Codable, Equatable {
                public let listen: [String]
                public let routes: [Route]
            }

            public struct Route: Codable, Equatable {
                public let match: [Match]
                public let handle: [Handler]
                public let terminal: Bool

                public struct Match: Codable, Equatable {
                    public let host: [String]
                }

                public struct Handler: Codable, Equatable {
                    public let handler: String
                    public let upstreams: [Upstream]?
                    public let headers: Headers?
                    public let transport: Transport?

                    public struct Upstream: Codable, Equatable {
                        public let dial: String
                    }

                    public struct Headers: Codable, Equatable {
                        public let request: HeaderOps?

                        public struct HeaderOps: Codable, Equatable {
                            public let set: [String: [String]]
                        }
                    }

                    public struct Transport: Codable, Equatable {
                        public let protocolName: String
                        public let tls: TLSConfig

                        enum CodingKeys: String, CodingKey {
                            case protocolName = "protocol"
                            case tls
                        }

                        public struct TLSConfig: Codable, Equatable {
                            public let insecureSkipVerify: Bool
                            enum CodingKeys: String, CodingKey {
                                case insecureSkipVerify = "insecure_skip_verify"
                            }
                        }
                    }
                }
            }
        }
    }

    public struct Logging: Codable, Equatable {
        public let logs: [String: Log]

        public struct Log: Codable, Equatable {
            public let level: String
        }
    }
}
