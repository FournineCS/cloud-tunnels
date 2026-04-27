import XCTest
@testable import CloudTunnels
@testable import TunnelCore

final class SSHLauncherTests: XCTestCase {
    private let launcher = SSHLauncher()

    // MARK: - arguments(for:) — sshConfigAlias upstream

    func testSSHConfigAliasSOCKSOnly() throws {
        let tunnel = Tunnel(
            name: "gke", localPort: 1080,
            provider: .ssh(SSHConfig(
                upstream: .sshConfigAlias("bastion-03"),
                socksPort: 1080
            ))
        )
        let args = try launcher.arguments(for: tunnel)
        XCTAssertEqual(args.first, "-N")
        XCTAssertTrue(args.contains("-T"))
        XCTAssertTrue(args.contains("-D"))
        XCTAssertTrue(args.contains("127.0.0.1:1080"))
        XCTAssertFalse(args.contains("-L"))
        XCTAssertTrue(args.contains("ExitOnForwardFailure=yes"))
        XCTAssertEqual(args.last, "bastion-03")
    }

    func testSSHConfigAliasLocalForwardOnly() throws {
        let tunnel = Tunnel(
            name: "loft", localPort: 9443,
            provider: .ssh(SSHConfig(
                upstream: .sshConfigAlias("bastion-03"),
                localForwards: [
                    SSHLocalForward(localPort: 9443, remoteHost: "loft.infra.gcp.example.com", remotePort: 443)
                ]
            ))
        )
        let args = try launcher.arguments(for: tunnel)
        XCTAssertTrue(args.contains("-L"))
        XCTAssertTrue(args.contains("9443:loft.infra.gcp.example.com:443"))
        XCTAssertFalse(args.contains("-D"))
        XCTAssertEqual(args.last, "bastion-03")
    }

    func testSSHConfigAliasSocksAndMultipleForwards() throws {
        let tunnel = Tunnel(
            name: "loft", localPort: 9446,
            provider: .ssh(SSHConfig(
                upstream: .sshConfigAlias("bastion-03"),
                socksPort: 9446,
                localForwards: [
                    SSHLocalForward(localPort: 9444, remoteHost: "loft.infra.gcp.example.com", remotePort: 443),
                    SSHLocalForward(localPort: 15432, remoteHost: "db.prod", remotePort: 5432),
                ]
            ))
        )
        let args = try launcher.arguments(for: tunnel)
        XCTAssertTrue(args.contains("127.0.0.1:9446"))
        XCTAssertTrue(args.contains("9444:loft.infra.gcp.example.com:443"))
        XCTAssertTrue(args.contains("15432:db.prod:5432"))
        // Exactly two -L occurrences
        XCTAssertEqual(args.filter { $0 == "-L" }.count, 2)
        // Exactly one -D
        XCTAssertEqual(args.filter { $0 == "-D" }.count, 1)
        XCTAssertEqual(args.last, "bastion-03")
    }

    // MARK: - arguments(for:) — gcloudIAP upstream

    func testGcloudIAPUpstreamWrapsSshArgs() throws {
        let tunnel = Tunnel(
            name: "qa", localPort: 9446,
            provider: .ssh(SSHConfig(
                upstream: .gcloudIAP(
                    instance: "bastion-03",
                    zone: "us-central1-a",
                    project: "my-gcp-project",
                    account: "user@example.com"
                ),
                socksPort: 9446,
                localForwards: [
                    SSHLocalForward(localPort: 9444, remoteHost: "loft.infra.gcp.example.com", remotePort: 443)
                ]
            ))
        )
        let args = try launcher.arguments(for: tunnel)
        XCTAssertEqual(args[0], "compute")
        XCTAssertEqual(args[1], "ssh")
        XCTAssertEqual(args[2], "bastion-03")
        XCTAssertTrue(args.contains("--zone=us-central1-a"))
        XCTAssertTrue(args.contains("--project=my-gcp-project"))
        XCTAssertTrue(args.contains("--account=user@example.com"))
        XCTAssertTrue(args.contains("--tunnel-through-iap"))
        guard let sepIdx = args.firstIndex(of: "--") else {
            XCTFail("missing -- separator"); return
        }
        // Everything after -- is the ssh-side argv built by sshForwardingArgs.
        let sshArgs = Array(args[(sepIdx + 1)...])
        XCTAssertEqual(sshArgs.first, "-N")
        XCTAssertTrue(sshArgs.contains("-D"))
        XCTAssertTrue(sshArgs.contains("127.0.0.1:9446"))
        XCTAssertTrue(sshArgs.contains("-L"))
        XCTAssertTrue(sshArgs.contains("9444:loft.infra.gcp.example.com:443"))
    }

    func testGcloudIAPUpstreamWithoutAccountOmitsFlag() throws {
        let tunnel = Tunnel(
            name: "qa", localPort: 1080,
            provider: .ssh(SSHConfig(
                upstream: .gcloudIAP(
                    instance: "bastion-03",
                    zone: "us-central1-a",
                    project: "p",
                    account: nil
                ),
                socksPort: 1080
            ))
        )
        let args = try launcher.arguments(for: tunnel)
        XCTAssertFalse(args.contains(where: { $0.hasPrefix("--account=") }))
    }

    // MARK: - Provider mismatch

    func testProviderMismatchThrows() {
        let tunnel = Tunnel(
            name: "x", localPort: 2222,
            provider: .gcpIAP(GCPIAPConfig(instance: "i", instancePort: 22, zone: "z", project: "p"))
        )
        XCTAssertThrowsError(try launcher.arguments(for: tunnel))
    }

    // MARK: - Auth failure patterns

    func testAuthExpiredPatternsAllMatch() {
        for pattern in launcher.authFailurePatterns {
            XCTAssertTrue(
                launcher.isAuthExpired("ssh error: \(pattern)"),
                "expected detection for: \(pattern)"
            )
        }
    }

    // MARK: - SSHConfig Codable

    func testSSHConfigCodableRoundTrip() throws {
        let original = SSHConfig(
            upstream: .gcloudIAP(instance: "b", zone: "z", project: "p", account: "sam@s.com"),
            socksPort: 9446,
            localForwards: [
                SSHLocalForward(localPort: 9444, remoteHost: "loft.infra", remotePort: 443)
            ],
            kubeconfigPatch: KubeconfigPatch(clusterName: "qa", insecureSkipTLSVerify: true)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SSHConfig.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testProviderConfigTaggedUnionRoundTrip() throws {
        let pc = ProviderConfig.ssh(SSHConfig(
            upstream: .sshConfigAlias("bastion-03"),
            socksPort: 1080
        ))
        let data = try JSONEncoder().encode(pc)
        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: data)
        XCTAssertEqual(decoded, pc)
        XCTAssertEqual(decoded.kind, .ssh)
    }

    // MARK: - Validation

    func testValidationAcceptsSocksOnly() throws {
        let tunnel = Tunnel(
            name: "ok", localPort: 1080,
            provider: .ssh(SSHConfig(
                upstream: .sshConfigAlias("bastion-03"),
                socksPort: 1080
            ))
        )
        XCTAssertNoThrow(try tunnel.validate(against: []))
    }

    func testValidationAcceptsForwardOnly() throws {
        let tunnel = Tunnel(
            name: "ok", localPort: 9443,
            provider: .ssh(SSHConfig(
                upstream: .sshConfigAlias("bastion-03"),
                localForwards: [
                    SSHLocalForward(localPort: 9443, remoteHost: "loft.infra", remotePort: 443)
                ]
            ))
        )
        XCTAssertNoThrow(try tunnel.validate(against: []))
    }

    func testValidationRejectsNoSocksAndNoForwards() {
        let tunnel = Tunnel(
            name: "bad", localPort: 0,
            provider: .ssh(SSHConfig(
                upstream: .sshConfigAlias("bastion-03")
            ))
        )
        XCTAssertThrowsError(try tunnel.validate(against: []))
    }

    func testValidationRejectsEmptyAlias() {
        let tunnel = Tunnel(
            name: "bad", localPort: 1080,
            provider: .ssh(SSHConfig(
                upstream: .sshConfigAlias(""),
                socksPort: 1080
            ))
        )
        XCTAssertThrowsError(try tunnel.validate(against: []))
    }

    func testValidationRejectsKubeconfigPatchWithoutSocks() {
        let tunnel = Tunnel(
            name: "bad", localPort: 9443,
            provider: .ssh(SSHConfig(
                upstream: .sshConfigAlias("bastion-03"),
                localForwards: [
                    SSHLocalForward(localPort: 9443, remoteHost: "a", remotePort: 443)
                ],
                kubeconfigPatch: KubeconfigPatch(clusterName: "qa")
            ))
        )
        XCTAssertThrowsError(try tunnel.validate(against: []))
    }

    func testValidationDetectsPortConflictAcrossMultipleSSHPorts() {
        let existing = Tunnel(
            name: "a", localPort: 9444,
            provider: .ssh(SSHConfig(
                upstream: .sshConfigAlias("bastion-03"),
                socksPort: 9446,
                localForwards: [
                    SSHLocalForward(localPort: 9444, remoteHost: "a", remotePort: 1)
                ]
            ))
        )
        let duplicate = Tunnel(
            name: "b", localPort: 9444,
            provider: .ssh(SSHConfig(
                upstream: .sshConfigAlias("bastion-03"),
                localForwards: [
                    SSHLocalForward(localPort: 9444, remoteHost: "x", remotePort: 2)
                ]
            ))
        )
        XCTAssertThrowsError(try duplicate.validate(against: [existing]))
    }

    // MARK: - KubeconfigPatcher argv builders

    func testKubeconfigApplyArgsCore() {
        let patch = KubeconfigPatch(clusterName: "qa-next", insecureSkipTLSVerify: true)
        let args = KubeconfigPatcher.buildSetClusterArgs(patch: patch, socksPort: 9446)
        XCTAssertEqual(args[0], "config")
        XCTAssertEqual(args[1], "set-cluster")
        XCTAssertEqual(args[2], "qa-next")
        XCTAssertTrue(args.contains("--proxy-url=socks5://127.0.0.1:9446"))
        XCTAssertTrue(args.contains("--insecure-skip-tls-verify=true"))
    }

    func testKubeconfigApplyArgsWithoutInsecure() {
        let patch = KubeconfigPatch(clusterName: "x", insecureSkipTLSVerify: false)
        let args = KubeconfigPatcher.buildSetClusterArgs(patch: patch, socksPort: 1080)
        XCTAssertFalse(args.contains("--insecure-skip-tls-verify=true"))
    }

    func testKubeconfigApplyArgsWithPath() {
        let patch = KubeconfigPatch(clusterName: "x", kubeconfigPath: "/tmp/kube.yaml")
        let args = KubeconfigPatcher.buildSetClusterArgs(patch: patch, socksPort: 1080)
        XCTAssertEqual(args[0], "--kubeconfig=/tmp/kube.yaml")
        XCTAssertEqual(args[1], "config")
    }

    func testKubeconfigUnsetArgs() {
        let patch = KubeconfigPatch(clusterName: "qa-next", kubeconfigPath: nil)
        let argsList = KubeconfigPatcher.buildUnsetArgs(patch: patch)
        XCTAssertEqual(argsList.count, 2)
        XCTAssertEqual(argsList[0], ["config", "unset", "clusters.qa-next.proxy-url"])
        XCTAssertEqual(argsList[1], ["config", "unset", "clusters.qa-next.insecure-skip-tls-verify"])
    }

    // MARK: - SSH config parser

    func testSSHConfigParserReadsFixture() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssh-config-test-\(UUID().uuidString)")
        let body = """
        # comment
        Host bastion-03
          HostName 1.2.3.4
          User sam

        Host db-server
          HostName 10.2.0.136
          User sam
          ProxyJump bastion-03

        Host *.prod
          User sam

        Host free-form = value-ignored
          HostName 5.6.7.8
        """
        try body.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let hosts = SSHConfigParser.hosts(at: tmp)
        let aliases = hosts.map(\.alias).sorted()
        XCTAssertTrue(aliases.contains("bastion-03"))
        XCTAssertTrue(aliases.contains("db-server"))
        XCTAssertFalse(aliases.contains("*.prod"), "wildcard hosts must be skipped")

        let db = hosts.first { $0.alias == "db-server" }
        XCTAssertEqual(db?.proxyJump, "bastion-03")
        XCTAssertEqual(db?.hostName, "10.2.0.136")
        XCTAssertEqual(db?.user, "sam")
    }

    func testSSHConfigParserMissingFileReturnsEmpty() {
        let nowhere = URL(fileURLWithPath: "/tmp/definitely-does-not-exist-\(UUID().uuidString)")
        XCTAssertEqual(SSHConfigParser.hosts(at: nowhere), [])
    }
}
