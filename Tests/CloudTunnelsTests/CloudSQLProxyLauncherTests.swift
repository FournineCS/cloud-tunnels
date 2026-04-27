import XCTest
@testable import CloudTunnels
@testable import TunnelCore

final class CloudSQLProxyLauncherTests: XCTestCase {
    private let launcher = CloudSQLProxyLauncher()

    // MARK: - arguments(for:)

    func testArgumentsCoreOnly() throws {
        let tunnel = Tunnel(
            name: "prod-db", localPort: 15432,
            provider: .cloudSQLProxy(CloudSQLProxyConfig(
                instanceConnectionName: "myproj:us-central1:db-main"
            ))
        )
        let args = try launcher.arguments(for: tunnel)
        XCTAssertEqual(args[0], "myproj:us-central1:db-main")
        XCTAssertTrue(args.contains("--address"))
        XCTAssertTrue(args.contains("127.0.0.1"))
        XCTAssertTrue(args.contains("--port"))
        XCTAssertTrue(args.contains("15432"))
        XCTAssertFalse(args.contains("--private-ip"))
        XCTAssertFalse(args.contains("--auto-iam-authn"))
        XCTAssertFalse(args.contains("--impersonate-service-account"))
    }

    func testArgumentsWithPrivateIP() throws {
        let tunnel = Tunnel(
            name: "prod-db", localPort: 15432,
            provider: .cloudSQLProxy(CloudSQLProxyConfig(
                instanceConnectionName: "p:r:i",
                privateIP: true
            ))
        )
        let args = try launcher.arguments(for: tunnel)
        XCTAssertTrue(args.contains("--private-ip"))
    }

    func testArgumentsWithAutoIAM() throws {
        let tunnel = Tunnel(
            name: "prod-db", localPort: 15432,
            provider: .cloudSQLProxy(CloudSQLProxyConfig(
                instanceConnectionName: "p:r:i",
                autoIAMAuthn: true
            ))
        )
        let args = try launcher.arguments(for: tunnel)
        XCTAssertTrue(args.contains("--auto-iam-authn"))
    }

    func testArgumentsWithImpersonation() throws {
        let tunnel = Tunnel(
            name: "prod-db", localPort: 15432,
            provider: .cloudSQLProxy(CloudSQLProxyConfig(
                instanceConnectionName: "p:r:i",
                impersonateServiceAccount: "runner@p.iam.gserviceaccount.com"
            ))
        )
        let args = try launcher.arguments(for: tunnel)
        guard let idx = args.firstIndex(of: "--impersonate-service-account") else {
            XCTFail("--impersonate-service-account missing"); return
        }
        XCTAssertEqual(args[idx + 1], "runner@p.iam.gserviceaccount.com")
    }

    func testArgumentsAllFlags() throws {
        let tunnel = Tunnel(
            name: "prod-db", localPort: 15432,
            provider: .cloudSQLProxy(CloudSQLProxyConfig(
                instanceConnectionName: "p:r:i",
                account: "sam@example.com",
                privateIP: true,
                autoIAMAuthn: true,
                impersonateServiceAccount: "sa@p.iam.gserviceaccount.com"
            ))
        )
        let args = try launcher.arguments(for: tunnel)
        XCTAssertTrue(args.contains("--private-ip"))
        XCTAssertTrue(args.contains("--auto-iam-authn"))
        XCTAssertTrue(args.contains("--impersonate-service-account"))
    }

    func testProviderMismatchThrows() {
        let tunnel = Tunnel(
            name: "x", localPort: 2222,
            provider: .gcpIAP(GCPIAPConfig(instance: "i", instancePort: 22, zone: "z", project: "p"))
        )
        XCTAssertThrowsError(try launcher.arguments(for: tunnel))
    }

    // MARK: - environment(for:)

    func testEnvironmentNilWhenNoAccount() {
        let tunnel = Tunnel(
            name: "x", localPort: 15432,
            provider: .cloudSQLProxy(CloudSQLProxyConfig(instanceConnectionName: "p:r:i"))
        )
        XCTAssertNil(launcher.environment(for: tunnel))
    }

    func testEnvironmentSetsCloudSDKAccount() {
        let tunnel = Tunnel(
            name: "x", localPort: 15432,
            provider: .cloudSQLProxy(CloudSQLProxyConfig(
                instanceConnectionName: "p:r:i",
                account: "sam@example.com"
            ))
        )
        XCTAssertEqual(launcher.environment(for: tunnel)?["CLOUDSDK_CORE_ACCOUNT"], "sam@example.com")
    }

    // MARK: - listening + auth markers

    func testListeningMarker() {
        XCTAssertTrue(launcher.isListening(
            "The proxy has started successfully and is ready for new connections"))
        XCTAssertTrue(launcher.isListening("Ready for new connections!"))
        XCTAssertFalse(launcher.isListening("Authorizing with ADC"))
    }

    func testAuthExpiredPatternsAllMatch() {
        for pattern in launcher.authFailurePatterns {
            XCTAssertTrue(
                launcher.isAuthExpired("cloud-sql-proxy: \(pattern)"),
                "expected detection for: \(pattern)"
            )
        }
    }

    // MARK: - Codable round-trip

    func testConfigCodableRoundTrip() throws {
        let original = CloudSQLProxyConfig(
            instanceConnectionName: "proj:us-central1:db",
            account: "sam@example.com",
            privateIP: true,
            autoIAMAuthn: true,
            impersonateServiceAccount: "sa@proj.iam.gserviceaccount.com"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CloudSQLProxyConfig.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testConfigCodableDefaultsWhenFlagsMissing() throws {
        let json = """
        { "instance_connection_name": "proj:us-central1:db" }
        """
        let decoded = try JSONDecoder().decode(CloudSQLProxyConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.instanceConnectionName, "proj:us-central1:db")
        XCTAssertNil(decoded.account)
        XCTAssertFalse(decoded.privateIP)
        XCTAssertFalse(decoded.autoIAMAuthn)
        XCTAssertNil(decoded.impersonateServiceAccount)
    }

    func testConfigEmptyStringsDecodeAsNil() throws {
        let json = """
        {
            "instance_connection_name": "proj:us-central1:db",
            "account": "",
            "impersonate_service_account": ""
        }
        """
        let decoded = try JSONDecoder().decode(CloudSQLProxyConfig.self, from: Data(json.utf8))
        XCTAssertNil(decoded.account)
        XCTAssertNil(decoded.impersonateServiceAccount)
    }

    func testProviderConfigTaggedUnionRoundTrip() throws {
        let cfg = ProviderConfig.cloudSQLProxy(CloudSQLProxyConfig(
            instanceConnectionName: "p:r:i",
            privateIP: true
        ))
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: data)
        XCTAssertEqual(decoded, cfg)
        XCTAssertEqual(decoded.kind, .cloudSQLProxy)
    }

    func testTargetDescriptionShowsInstance() {
        let cfg = ProviderConfig.cloudSQLProxy(CloudSQLProxyConfig(
            instanceConnectionName: "myproj:us-central1:db-main"
        ))
        XCTAssertEqual(cfg.targetDescription, "db-main")
    }

    // MARK: - Validation

    func testValidationAcceptsThreePartName() throws {
        let tunnel = Tunnel(
            name: "ok", localPort: 15432,
            provider: .cloudSQLProxy(CloudSQLProxyConfig(instanceConnectionName: "p:r:i"))
        )
        XCTAssertNoThrow(try tunnel.validate(against: []))
    }

    func testValidationRejectsEmptyName() {
        let tunnel = Tunnel(
            name: "bad", localPort: 15432,
            provider: .cloudSQLProxy(CloudSQLProxyConfig(instanceConnectionName: ""))
        )
        XCTAssertThrowsError(try tunnel.validate(against: []))
    }

    func testValidationRejectsMalformedName() {
        for bad in ["project", "project:region", "project:region:instance:extra", ":r:i", "p::i", "p:r:"] {
            let tunnel = Tunnel(
                name: "bad", localPort: 15432,
                provider: .cloudSQLProxy(CloudSQLProxyConfig(instanceConnectionName: bad))
            )
            XCTAssertThrowsError(
                try tunnel.validate(against: []),
                "expected validation failure for: \(bad)"
            )
        }
    }
}
