import XCTest
@testable import TunnelCore

/// Schema tests for LocalHTTPSProxy and its embedding in AWSSSMConfig /
/// ProviderConfig. The on-disk format is load-bearing: old config files
/// (no local_proxy field) must keep loading, and new files must round-trip
/// cleanly through the tagged-union envelope.
final class LocalProxyConfigTests: XCTestCase {

    // MARK: - LocalHTTPSProxy round-trip

    func testLocalHTTPSProxyDefaults() throws {
        let proxy = LocalHTTPSProxy(hostname: "mwaa.airflow.us-west-2.on.aws")
        XCTAssertTrue(proxy.manageHosts)
        XCTAssertTrue(proxy.insecureUpstream)
    }

    func testLocalHTTPSProxyEncodeUsesSnakeCaseKeys() throws {
        let proxy = LocalHTTPSProxy(
            hostname: "mwaa.example.com",
            manageHosts: false,
            insecureUpstream: true
        )
        let data = try JSONEncoder().encode(proxy)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["hostname"] as? String, "mwaa.example.com")
        XCTAssertEqual(json["manage_hosts"] as? Bool, false)
        XCTAssertEqual(json["insecure_upstream"] as? Bool, true)
        XCTAssertNil(json["manageHosts"])
    }

    func testLocalHTTPSProxyDecodeFillsMissingDefaults() throws {
        // Only `hostname` provided — `manage_hosts` and `insecure_upstream`
        // should default to true so old configs / minimal entries Just Work.
        let json = #"{"hostname":"mwaa.example.com"}"#
        let proxy = try JSONDecoder().decode(
            LocalHTTPSProxy.self, from: Data(json.utf8)
        )
        XCTAssertEqual(proxy.hostname, "mwaa.example.com")
        XCTAssertTrue(proxy.manageHosts)
        XCTAssertTrue(proxy.insecureUpstream)
    }

    func testLocalHTTPSProxyRoundTripPreservesAllFields() throws {
        let original = LocalHTTPSProxy(
            hostname: "abc-vpce.c6.airflow.us-west-2.on.aws",
            manageHosts: false,
            insecureUpstream: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LocalHTTPSProxy.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - AWSSSMConfig embedding

    func testAWSSSMConfigWithoutProxyHasNilLocalProxy() throws {
        let cfg = AWSSSMConfig(
            target: "i-0abc",
            remoteHost: "vpce.example.com",
            remotePort: 443,
            profile: "consumer-dev"
        )
        XCTAssertNil(cfg.localProxy)
    }

    func testAWSSSMConfigDecodeWithoutLocalProxyKeyIsBackwardsCompatible() throws {
        // This is the legacy on-disk shape — before the local_proxy field
        // existed. Must still decode without error so users upgrading the app
        // never lose tunnels.
        let legacy = """
        {
          "target": "i-04693612c2b1b6db8",
          "remote_host": "vpce.example.com",
          "remote_port": 443,
          "profile": "consumer-dev"
        }
        """
        let cfg = try JSONDecoder().decode(
            AWSSSMConfig.self, from: Data(legacy.utf8)
        )
        XCTAssertEqual(cfg.target, "i-04693612c2b1b6db8")
        XCTAssertEqual(cfg.remoteHost, "vpce.example.com")
        XCTAssertEqual(cfg.remotePort, 443)
        XCTAssertEqual(cfg.profile, "consumer-dev")
        XCTAssertNil(cfg.localProxy)
    }

    func testAWSSSMConfigDecodeWithEmbeddedLocalProxy() throws {
        let json = """
        {
          "target": "i-0abc",
          "remote_host": "vpce.example.com",
          "remote_port": 443,
          "profile": "consumer-dev",
          "local_proxy": {
            "hostname": "vpce.example.com",
            "manage_hosts": true,
            "insecure_upstream": true
          }
        }
        """
        let cfg = try JSONDecoder().decode(
            AWSSSMConfig.self, from: Data(json.utf8)
        )
        let proxy = try XCTUnwrap(cfg.localProxy)
        XCTAssertEqual(proxy.hostname, "vpce.example.com")
        XCTAssertTrue(proxy.manageHosts)
        XCTAssertTrue(proxy.insecureUpstream)
    }

    func testAWSSSMConfigDecodeRejectsEmptyHostnameProxy() throws {
        // Empty hostname is meaningless — normalize to nil so the form's
        // "I cleared the field" path produces a clean state, mirroring the
        // empty-string-to-nil treatment of profile/region.
        let json = """
        {
          "target": "i-0abc",
          "remote_port": 443,
          "local_proxy": {
            "hostname": "",
            "manage_hosts": true,
            "insecure_upstream": true
          }
        }
        """
        let cfg = try JSONDecoder().decode(
            AWSSSMConfig.self, from: Data(json.utf8)
        )
        XCTAssertNil(cfg.localProxy)
    }

    func testAWSSSMConfigRoundTripWithProxy() throws {
        let original = AWSSSMConfig(
            target: "i-0abc",
            remoteHost: "vpce.example.com",
            remotePort: 443,
            profile: "consumer-dev",
            region: "us-west-2",
            localProxy: LocalHTTPSProxy(
                hostname: "vpce.example.com",
                manageHosts: true,
                insecureUpstream: true
            )
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AWSSSMConfig.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testAWSSSMConfigRoundTripWithoutProxyOmitsKeyOnReDecode() throws {
        let original = AWSSSMConfig(target: "i-0abc", remotePort: 443)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AWSSSMConfig.self, from: data)
        XCTAssertNil(decoded.localProxy)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - ProviderConfig tagged union

    func testProviderConfigTaggedUnionPreservesProxyAcrossEncode() throws {
        let inner = AWSSSMConfig(
            target: "i-04693612c2b1b6db8",
            remoteHost: "vpce.example.com",
            remotePort: 443,
            profile: "consumer-dev",
            localProxy: LocalHTTPSProxy(hostname: "vpce.example.com")
        )
        let provider = ProviderConfig.awsSSM(inner)

        let data = try JSONEncoder().encode(provider)
        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: data)

        guard case .awsSSM(let roundTripped) = decoded else {
            XCTFail("Tagged union should decode back to .awsSSM")
            return
        }
        XCTAssertEqual(roundTripped, inner)
        XCTAssertEqual(roundTripped.localProxy?.hostname, "vpce.example.com")
    }

    func testProviderConfigEnvelopeShapeIsStable() throws {
        // The on-disk envelope is { "type": "awsSSM", "data": {...} }. Pin it
        // explicitly so a reorder or rename of the discriminator gets caught
        // by tests rather than by users silently losing config.
        let provider = ProviderConfig.awsSSM(
            AWSSSMConfig(target: "i-0abc", remotePort: 443)
        )
        let data = try JSONEncoder().encode(provider)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["type"] as? String, "awsSSM")
        XCTAssertNotNil(json["data"])
    }
}
