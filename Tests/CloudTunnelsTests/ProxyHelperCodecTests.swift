import Foundation
import XCTest
@testable import ProxyHelperShared

/// Verifies that DTOs serialized through `ProxyHelperCodec` survive a JSON
/// round-trip — this is the format every NSXPC payload uses, so a regression
/// here silently breaks all GUI ↔ helper communication.
final class ProxyHelperCodecTests: XCTestCase {

    func testProxyRouteRoundTrip() throws {
        let original = ProxyRoute(
            tunnelID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            hostname: "vpce.example.com",
            upstreamPort: 8443,
            insecureUpstream: true
        )
        let data = try ProxyHelperCodec.encode(original)
        let decoded = try ProxyHelperCodec.decode(ProxyRoute.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testProxyRouteEncodingIsStableAcrossRuns() throws {
        // ProxyHelperCodec sets sortedKeys so encoded payloads are
        // deterministic — important for any downstream content-addressing
        // and for diffing test fixtures.
        let route = ProxyRoute(
            tunnelID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            hostname: "abc.example.com",
            upstreamPort: 9443,
            insecureUpstream: false
        )
        let first = try ProxyHelperCodec.encode(route)
        let second = try ProxyHelperCodec.encode(route)
        XCTAssertEqual(first, second)
    }

    func testHostsEntryRoundTrip() throws {
        let original = HostsEntry(
            tunnelID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            hostname: "abc.example.com"
        )
        let data = try ProxyHelperCodec.encode(original)
        let decoded = try ProxyHelperCodec.decode(HostsEntry.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testProxyRouteArrayRoundTrip() throws {
        let originals = [
            ProxyRoute(tunnelID: UUID(), hostname: "a.example.com", upstreamPort: 8443),
            ProxyRoute(tunnelID: UUID(), hostname: "b.example.com", upstreamPort: 8444),
            ProxyRoute(tunnelID: UUID(), hostname: "c.example.com", upstreamPort: 8445),
        ]
        let data = try ProxyHelperCodec.encode(originals)
        let decoded = try ProxyHelperCodec.decode([ProxyRoute].self, from: data)
        XCTAssertEqual(decoded, originals)
    }

    func testHostsEntryArrayRoundTrip() throws {
        let originals = [
            HostsEntry(tunnelID: UUID(), hostname: "a.example.com"),
            HostsEntry(tunnelID: UUID(), hostname: "b.example.com"),
        ]
        let data = try ProxyHelperCodec.encode(originals)
        let decoded = try ProxyHelperCodec.decode([HostsEntry].self, from: data)
        XCTAssertEqual(decoded, originals)
    }

    func testProxyRouteDecodeRejectsMalformedPayload() {
        let bad = Data("not json".utf8)
        XCTAssertThrowsError(try ProxyHelperCodec.decode(ProxyRoute.self, from: bad))
    }

    func testMachServiceNameIsStable() {
        // Pin the constant so a rename can't silently break the GUI ↔ helper
        // wiring (the launchd plist's `MachServices` key uses the same string).
        XCTAssertEqual(
            ProxyHelperMachService.name,
            "com.fourninecloud.cloud-tunnels.proxy-helper"
        )
    }

    func testProxyRouteDefaultsInsecureUpstreamToTrue() {
        let route = ProxyRoute(tunnelID: UUID(), hostname: "x.example.com", upstreamPort: 1234)
        XCTAssertTrue(route.insecureUpstream)
    }
}
