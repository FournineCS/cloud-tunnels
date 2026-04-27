import XCTest
@testable import CloudTunnels
@testable import TunnelCore

@MainActor
final class QuickActionTests: XCTestCase {
    private func makeTunnel(
        kind: TunnelKind,
        localPort: Int = 2222,
        username: String? = nil,
        path: String? = nil,
        database: String? = nil
    ) -> Tunnel {
        Tunnel(
            name: "t-\(kind.rawValue)",
            localPort: localPort,
            provider: .gcpIAP(GCPIAPConfig(
                instance: "i", instancePort: 22, zone: "z", project: "p"
            )),
            kind: kind,
            actionConfig: ActionConfig(username: username, path: path, database: database)
        )
    }

    // MARK: SSH

    /// Builds an AWS SSM tunnel with an optional LocalHTTPSProxy sidecar.
    /// Only used by the Local-HTTPS-proxy URL tests below.
    private func makeAWSTunnel(
        localPort: Int,
        kind: TunnelKind = .https,
        path: String? = nil,
        proxy: LocalHTTPSProxy? = nil
    ) -> Tunnel {
        Tunnel(
            name: "aws-\(kind.rawValue)",
            localPort: localPort,
            provider: .awsSSM(AWSSSMConfig(
                target: "i-0abc",
                remoteHost: "vpce.example.com",
                remotePort: 443,
                localProxy: proxy
            )),
            kind: kind,
            actionConfig: ActionConfig(username: nil, path: path, database: nil)
        )
    }

    func testSSHCommandWithUsername() {
        let t = makeTunnel(kind: .ssh, localPort: 2222, username: "ec2-user")
        XCTAssertEqual(QuickAction.sshCommand(for: t), "ssh -p 2222 ec2-user@localhost")
    }

    // MARK: Local HTTPS proxy URL rewriting

    func testHTTPSURLPrefersLocalProxyHostnameWhenSet() {
        let t = makeAWSTunnel(
            localPort: 8445,
            proxy: LocalHTTPSProxy(hostname: "vpce.example.com")
        )
        XCTAssertEqual(
            QuickAction.url(for: t)?.absoluteString,
            "https://vpce.example.com/"
        )
    }

    func testHTTPSURLPreservesPathWhenUsingLocalProxy() {
        let t = makeAWSTunnel(
            localPort: 8445,
            path: "home",
            proxy: LocalHTTPSProxy(hostname: "vpce.example.com")
        )
        XCTAssertEqual(
            QuickAction.url(for: t)?.absoluteString,
            "https://vpce.example.com/home"
        )
    }

    func testHTTPSURLFallsBackToLocalhostWhenProxyNotSet() {
        // Same provider, no LocalHTTPSProxy configured — must keep the
        // existing loopback behavior so non-proxy tunnels are unaffected.
        let t = makeAWSTunnel(localPort: 8445, proxy: nil)
        XCTAssertEqual(
            QuickAction.url(for: t)?.absoluteString,
            "https://localhost:8445/"
        )
    }

    func testHTTPSURLIgnoresProxyWhenKindIsHTTP() {
        // The proxy is HTTPS-only; an http:// quick action should still go
        // to localhost since the proxy listener doesn't bind plaintext :80.
        let t = makeAWSTunnel(
            localPort: 8445,
            kind: .http,
            proxy: LocalHTTPSProxy(hostname: "vpce.example.com")
        )
        XCTAssertEqual(
            QuickAction.url(for: t)?.absoluteString,
            "http://localhost:8445/"
        )
    }

    func testLocalProxyHostnameHelperReturnsNilForNonAWSProviders() {
        let t = makeTunnel(kind: .https, localPort: 8443)  // GCP IAP
        XCTAssertNil(QuickAction.localProxyHostname(for: t))
    }

    func testLocalProxyHostnameHelperReturnsNilForEmptyHostname() {
        // Defensive — schema decoder normalises empty strings to nil, but
        // construct directly to verify the helper still bails out.
        let t = makeAWSTunnel(
            localPort: 8445,
            proxy: LocalHTTPSProxy(hostname: "")
        )
        XCTAssertNil(QuickAction.localProxyHostname(for: t))
    }

    func testSSHCommandWithoutUsername() {
        let t = makeTunnel(kind: .ssh, localPort: 2222)
        XCTAssertEqual(QuickAction.sshCommand(for: t), "ssh -p 2222 localhost")
    }

    // MARK: HTTP / HTTPS

    func testHTTPDefaultPath() {
        let t = makeTunnel(kind: .http, localPort: 8080)
        XCTAssertEqual(QuickAction.url(for: t)?.absoluteString, "http://localhost:8080/")
    }

    func testHTTPCustomPath() {
        let t = makeTunnel(kind: .http, localPort: 8080, path: "/admin")
        XCTAssertEqual(QuickAction.url(for: t)?.absoluteString, "http://localhost:8080/admin")
    }

    func testHTTPSPathWithoutLeadingSlash() {
        let t = makeTunnel(kind: .https, localPort: 8443, path: "dashboard")
        XCTAssertEqual(QuickAction.url(for: t)?.absoluteString, "https://localhost:8443/dashboard")
    }

    func testHTTPSDefaultPath() {
        let t = makeTunnel(kind: .https, localPort: 8443)
        XCTAssertEqual(QuickAction.url(for: t)?.absoluteString, "https://localhost:8443/")
    }

    // MARK: VNC

    func testVNCURL() {
        let t = makeTunnel(kind: .vnc, localPort: 5900)
        XCTAssertEqual(QuickAction.url(for: t)?.absoluteString, "vnc://localhost:5900")
    }

    // MARK: Databases

    func testPostgresWithDatabase() {
        let t = makeTunnel(kind: .postgres, localPort: 15432, database: "mydb")
        XCTAssertEqual(QuickAction.url(for: t)?.absoluteString, "postgresql://localhost:15432/mydb")
    }

    func testPostgresWithoutDatabase() {
        let t = makeTunnel(kind: .postgres, localPort: 15432)
        XCTAssertEqual(QuickAction.url(for: t)?.absoluteString, "postgresql://localhost:15432/")
    }

    func testMySQLURL() {
        let t = makeTunnel(kind: .mysql, localPort: 13306, database: "core")
        XCTAssertEqual(QuickAction.url(for: t)?.absoluteString, "mysql://localhost:13306/core")
    }

    func testMongoDBURL() {
        let t = makeTunnel(kind: .mongodb, localPort: 27017, database: "events")
        XCTAssertEqual(QuickAction.url(for: t)?.absoluteString, "mongodb://localhost:27017/events")
    }

    // MARK: Kinds with no URL

    func testTCPHasNoURL() {
        XCTAssertNil(QuickAction.url(for: makeTunnel(kind: .tcp)))
    }

    func testSSHHasNoURL() {
        XCTAssertNil(QuickAction.url(for: makeTunnel(kind: .ssh)))
    }

    func testRedisHasNoURL() {
        XCTAssertNil(QuickAction.url(for: makeTunnel(kind: .redis)))
    }

    func testRDPHasNoURL() {
        XCTAssertNil(QuickAction.url(for: makeTunnel(kind: .rdp)))
    }

    func testK8sHasNoURL() {
        XCTAssertNil(QuickAction.url(for: makeTunnel(kind: .k8s)))
    }

    func testKafkaHasNoURL() {
        XCTAssertNil(QuickAction.url(for: makeTunnel(kind: .kafka)))
    }

    // MARK: Vault / Elasticsearch URL builders

    func testVaultDefaultPathIsUI() {
        let t = makeTunnel(kind: .vault, localPort: 8200)
        XCTAssertEqual(QuickAction.url(for: t)?.absoluteString, "https://localhost:8200/ui")
    }

    func testVaultCustomPathOverridesDefault() {
        let t = makeTunnel(kind: .vault, localPort: 8200, path: "/v1/sys/health")
        XCTAssertEqual(QuickAction.url(for: t)?.absoluteString, "https://localhost:8200/v1/sys/health")
    }

    func testVaultPathWithoutLeadingSlash() {
        let t = makeTunnel(kind: .vault, localPort: 8200, path: "v1/auth/aws/login")
        XCTAssertEqual(QuickAction.url(for: t)?.absoluteString, "https://localhost:8200/v1/auth/aws/login")
    }

    func testElasticsearchDefaultPathIsClusterHealth() {
        let t = makeTunnel(kind: .elasticsearch, localPort: 9200)
        XCTAssertEqual(QuickAction.url(for: t)?.absoluteString, "http://localhost:9200/_cluster/health?pretty")
    }

    func testElasticsearchCustomPath() {
        let t = makeTunnel(kind: .elasticsearch, localPort: 9200, path: "/_cat/indices?v")
        XCTAssertEqual(QuickAction.url(for: t)?.absoluteString, "http://localhost:9200/_cat/indices?v")
    }

    // MARK: TunnelKind defaults for new kinds

    func testNewKindDefaultPorts() {
        XCTAssertEqual(TunnelKind.k8s.defaultLocalPort, 6443)
        XCTAssertEqual(TunnelKind.vault.defaultLocalPort, 8200)
        XCTAssertEqual(TunnelKind.elasticsearch.defaultLocalPort, 9200)
        XCTAssertEqual(TunnelKind.kafka.defaultLocalPort, 9092)
    }

    func testNewKindDisplayNames() {
        XCTAssertEqual(TunnelKind.k8s.displayName, "Kubernetes")
        XCTAssertEqual(TunnelKind.vault.displayName, "Vault")
        XCTAssertEqual(TunnelKind.elasticsearch.displayName, "Elasticsearch")
        XCTAssertEqual(TunnelKind.kafka.displayName, "Kafka")
    }

    func testVaultAndElasticsearchSupportPath() {
        XCTAssertTrue(TunnelKind.vault.supportsPath)
        XCTAssertTrue(TunnelKind.elasticsearch.supportsPath)
    }

    func testK8sAndKafkaDoNotSupportPathOrDatabase() {
        XCTAssertFalse(TunnelKind.k8s.supportsPath)
        XCTAssertFalse(TunnelKind.k8s.supportsDatabase)
        XCTAssertFalse(TunnelKind.kafka.supportsPath)
        XCTAssertFalse(TunnelKind.kafka.supportsDatabase)
    }

    // MARK: k8s quick action command picker

    func testK8sQuickActionCommandFallsBackToKubectlWhenK9sAbsent() {
        // We can't easily inject a fake binary search path, but in
        // most CI environments k9s isn't installed at the hardcoded
        // paths, so we expect the kubectl fallback. If the build
        // machine *does* have k9s installed, accept that too.
        let cmd = QuickAction.k8sQuickActionCommand()
        XCTAssertTrue(
            cmd == "k9s" || cmd == "kubectl get pods --all-namespaces",
            "unexpected k8s command: \(cmd)"
        )
    }

    // MARK: RDP file content

    func testRDPFileContentWithoutUsername() {
        let t = makeTunnel(kind: .rdp, localPort: 3389)
        let body = QuickAction.rdpFileContent(for: t)
        XCTAssertTrue(body.contains("full address:s:localhost:3389"))
        XCTAssertTrue(body.contains("prompt for credentials:i:1"))
        XCTAssertFalse(body.contains("username:"))
    }

    func testRDPFileContentWithUsername() {
        let t = makeTunnel(kind: .rdp, localPort: 3389, username: "Administrator")
        let body = QuickAction.rdpFileContent(for: t)
        XCTAssertTrue(body.contains("full address:s:localhost:3389"))
        XCTAssertTrue(body.contains("username:s:Administrator"))
    }
}
