import XCTest
@testable import CloudTunnelsProxyHelper
import ProxyHelperShared

/// Integration smoke test: runs `caddy validate` against the JSON
/// config that `CaddyfileBuilder` actually emits. Unit tests only
/// cover our Swift-side schema, so they can't catch cases where we
/// use a valid-looking field name that Caddy rejects (like the
/// `--adapter json` flag incident where our code was technically
/// "correct" but Caddy itself refused to accept it).
///
/// Skipped if Caddy isn't installed at one of the expected paths.
/// Not skipped on CI — the CI image should have Caddy, and a
/// silently-passing smoke test defeats the purpose.
final class CaddyConfigSmokeTests: XCTestCase {

    /// Search paths for a local caddy binary. First hit wins.
    /// Mirrors `CaddyManager.defaultBinarySearchPaths` but excludes
    /// the bundled .app path since tests aren't running inside a
    /// bundle.
    private static let caddySearchPaths: [String] = [
        "/opt/homebrew/bin/caddy",
        "/usr/local/bin/caddy",
        "/usr/bin/caddy",
    ]

    private static func locateCaddy() -> String? {
        let fm = FileManager.default
        for path in caddySearchPaths where fm.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private static var isCaddyAvailable: Bool {
        locateCaddy() != nil
    }

    // MARK: - Helpers

    private func writeConfig(_ routes: [ProxyRoute]) async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudtunnels-caddy-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let configURL = tmp.appendingPathComponent("caddy.json")

        // Caddy validate actually parses the cert files we reference
        // via x509.ParseCertificate (not just checks PEM framing), so
        // hand-written placeholder PEMs fail with "malformed algorithm
        // identifier". We use the real LocalCA to mint proper
        // self-signed leaves — this also exercises the same cert
        // generation path the helper uses in production.
        let ca = try LocalCA.loadOrCreate(in: tmp)
        let leaves = tmp.appendingPathComponent("leaves", isDirectory: true)
        for route in routes {
            _ = try await ca.issueLeaf(for: route.hostname)
            // LocalCA writes files to `<tmp>/leaves/<hostname>.{pem,key}`
            // by convention; CaddyfileBuilder resolves the same paths.
            // Nothing more to do here — the files are on disk.
            _ = leaves
        }

        let data = try CaddyfileBuilder.build(routes: routes, leavesDirectory: leaves)
        try data.write(to: configURL)
        return configURL
    }

    private func runCaddyValidate(configURL: URL) throws -> (exitCode: Int32, stderr: String) {
        guard let caddy = Self.locateCaddy() else {
            throw XCTSkip("caddy binary not found in \(Self.caddySearchPaths.joined(separator: ", "))")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: caddy)
        proc.arguments = ["validate", "--config", configURL.path]
        let err = Pipe()
        let out = Pipe()
        proc.standardError = err
        proc.standardOutput = out
        try proc.run()
        proc.waitUntilExit()
        let stderrData = err.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
        return (proc.terminationStatus, stderrText)
    }

    // MARK: - Tests

    func testEmptyRouteSetValidates() async throws {
        try XCTSkipUnless(Self.isCaddyAvailable, "caddy not installed")
        let configURL = try await writeConfig([])
        let result = try runCaddyValidate(configURL: configURL)
        XCTAssertEqual(result.exitCode, 0, "caddy rejected empty-route config:\n\(result.stderr)")
    }

    func testSingleRouteValidates() async throws {
        try XCTSkipUnless(Self.isCaddyAvailable, "caddy not installed")
        let route = ProxyRoute(
            tunnelID: UUID(),
            hostname: "vpce-host.example.com",
            upstreamPort: 8443,
            insecureUpstream: true
        )
        let configURL = try await writeConfig([route])
        let result = try runCaddyValidate(configURL: configURL)
        XCTAssertEqual(result.exitCode, 0, "caddy rejected single-route config:\n\(result.stderr)")
    }

    func testMultipleRoutesValidate() async throws {
        try XCTSkipUnless(Self.isCaddyAvailable, "caddy not installed")
        let routes = [
            ProxyRoute(tunnelID: UUID(), hostname: "a.example.com", upstreamPort: 8443, insecureUpstream: true),
            ProxyRoute(tunnelID: UUID(), hostname: "b.example.com", upstreamPort: 8444, insecureUpstream: true),
            ProxyRoute(tunnelID: UUID(), hostname: "c.example.com", upstreamPort: 8445, insecureUpstream: false),
        ]
        let configURL = try await writeConfig(routes)
        let result = try runCaddyValidate(configURL: configURL)
        XCTAssertEqual(result.exitCode, 0, "caddy rejected multi-route config:\n\(result.stderr)")
    }
}
