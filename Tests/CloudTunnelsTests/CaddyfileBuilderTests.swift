import XCTest
@testable import CloudTunnelsProxyHelper
import ProxyHelperShared

final class CaddyfileBuilderTests: XCTestCase {

    private let leavesDir = URL(fileURLWithPath: "/tmp/cloudtunnels-test/leaves", isDirectory: true)

    func testEmptyRoutesProducesAdminAndEmptyHTTPServer() throws {
        let config = CaddyfileBuilder.makeConfig(routes: [], leavesDirectory: leavesDir)
        XCTAssertEqual(config.admin.listen, "127.0.0.1:2019")
        XCTAssertNil(config.apps.tls, "no certs needed when no routes")
        XCTAssertEqual(config.apps.http.servers.count, 1)
        let server = try XCTUnwrap(config.apps.http.servers["main"])
        XCTAssertEqual(server.listen, [":443"])
        XCTAssertTrue(server.routes.isEmpty)
    }

    func testSingleRouteHasMatchingCertAndReverseProxyHandler() throws {
        let route = ProxyRoute(
            tunnelID: UUID(),
            hostname: "vpce-host.example.com",
            upstreamPort: 8444,
            insecureUpstream: true
        )
        let config = CaddyfileBuilder.makeConfig(routes: [route], leavesDirectory: leavesDir)

        // Cert load_files
        let tls = try XCTUnwrap(config.apps.tls)
        XCTAssertEqual(tls.certificates.loadFiles.count, 1)
        let cert = tls.certificates.loadFiles[0]
        XCTAssertEqual(cert.certificate, "/tmp/cloudtunnels-test/leaves/vpce-host.example.com.pem")
        XCTAssertEqual(cert.key, "/tmp/cloudtunnels-test/leaves/vpce-host.example.com.key")
        XCTAssertEqual(cert.tags, ["vpce-host.example.com"])

        // HTTP route
        let server = try XCTUnwrap(config.apps.http.servers["main"])
        XCTAssertEqual(server.routes.count, 1)
        let httpRoute = server.routes[0]
        XCTAssertTrue(httpRoute.terminal)
        XCTAssertEqual(httpRoute.match.first?.host, ["vpce-host.example.com"])

        // reverse_proxy handler
        XCTAssertEqual(httpRoute.handle.count, 1)
        let handler = httpRoute.handle[0]
        XCTAssertEqual(handler.handler, "reverse_proxy")
        XCTAssertEqual(handler.upstreams?.first?.dial, "127.0.0.1:8444")

        // Host header rewrite — defensive even though Caddy preserves it by default
        XCTAssertEqual(handler.headers?.request?.set["Host"], ["vpce-host.example.com"])

        // Transport: http with insecure TLS
        let transport = try XCTUnwrap(handler.transport)
        XCTAssertEqual(transport.protocolName, "http")
        XCTAssertTrue(transport.tls.insecureSkipVerify)
    }

    func testInsecureUpstreamFalseDisablesSkipVerify() throws {
        let route = ProxyRoute(
            tunnelID: UUID(),
            hostname: "secure.example.com",
            upstreamPort: 9443,
            insecureUpstream: false
        )
        let config = CaddyfileBuilder.makeConfig(routes: [route], leavesDirectory: leavesDir)
        let server = try XCTUnwrap(config.apps.http.servers["main"])
        let transport = try XCTUnwrap(server.routes[0].handle[0].transport)
        XCTAssertFalse(transport.tls.insecureSkipVerify)
    }

    func testMultipleRoutesProduceDistinctVirtualHosts() throws {
        let routes = [
            ProxyRoute(tunnelID: UUID(), hostname: "a.example.com", upstreamPort: 8443, insecureUpstream: true),
            ProxyRoute(tunnelID: UUID(), hostname: "b.example.com", upstreamPort: 8444, insecureUpstream: true),
            ProxyRoute(tunnelID: UUID(), hostname: "c.example.com", upstreamPort: 8445, insecureUpstream: true),
        ]
        let config = CaddyfileBuilder.makeConfig(routes: routes, leavesDirectory: leavesDir)

        let tls = try XCTUnwrap(config.apps.tls)
        XCTAssertEqual(tls.certificates.loadFiles.count, 3)
        XCTAssertEqual(tls.certificates.loadFiles.map(\.tags.first), ["a.example.com", "b.example.com", "c.example.com"])

        let server = try XCTUnwrap(config.apps.http.servers["main"])
        XCTAssertEqual(server.routes.count, 3)
        let dials = server.routes.compactMap { $0.handle.first?.upstreams?.first?.dial }
        XCTAssertEqual(dials, ["127.0.0.1:8443", "127.0.0.1:8444", "127.0.0.1:8445"])
    }

    func testHostnameNormalizedToLowercaseInCertPaths() throws {
        // Certificate filenames are written by LocalCA in lowercase form
        // (issueLeaf normalizes). The Caddy config must reference the
        // lowercase paths so the file actually exists on disk.
        let route = ProxyRoute(
            tunnelID: UUID(),
            hostname: "MixedCase.Example.COM",
            upstreamPort: 8443,
            insecureUpstream: true
        )
        let config = CaddyfileBuilder.makeConfig(routes: [route], leavesDirectory: leavesDir)
        let cert = try XCTUnwrap(config.apps.tls?.certificates.loadFiles.first)
        XCTAssertEqual(cert.certificate, "/tmp/cloudtunnels-test/leaves/mixedcase.example.com.pem")
        XCTAssertEqual(cert.key, "/tmp/cloudtunnels-test/leaves/mixedcase.example.com.key")
        XCTAssertEqual(cert.tags, ["mixedcase.example.com"])
    }

    func testJSONEncodingProducesValidCaddyKeys() throws {
        let route = ProxyRoute(
            tunnelID: UUID(),
            hostname: "h.example.com",
            upstreamPort: 8443,
            insecureUpstream: true
        )
        let data = try CaddyfileBuilder.build(routes: [route], leavesDirectory: leavesDir)
        let json = String(data: data, encoding: .utf8) ?? ""
        // Critical Caddy schema keys that must appear with their exact
        // wire spelling (snake_case where Caddy expects it).
        XCTAssertTrue(json.contains("\"load_files\""), "TLS load_files key must be snake_case")
        XCTAssertTrue(json.contains("\"insecure_skip_verify\""), "TLS skip-verify key must be snake_case")
        XCTAssertTrue(json.contains("\"protocol\""), "transport protocol key")
        XCTAssertTrue(json.contains("\"reverse_proxy\""), "handler name")
        XCTAssertTrue(json.contains("\"127.0.0.1:2019\""), "admin API listen")
        XCTAssertTrue(json.contains("\":443\""), "https listen")
        XCTAssertTrue(json.contains("\"127.0.0.1:8443\""), "upstream dial")
    }
}
