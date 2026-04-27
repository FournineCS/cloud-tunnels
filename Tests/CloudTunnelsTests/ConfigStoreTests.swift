import XCTest
@testable import CloudTunnels
@testable import TunnelCore

final class ConfigStoreTests: XCTestCase {
    private var tempDir: URL!
    private var legacyDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cloud-tunnels-tests-\(UUID().uuidString)", isDirectory: true)
        legacyDir = tempDir.appendingPathComponent("legacy", isDirectory: true)
        try? FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testGCPRoundTrip() throws {
        let store = ConfigStore(
            configDirectoryURL: tempDir.appendingPathComponent("cfg"),
            legacyConfigURLs: [legacyDir.appendingPathComponent("config.json")]
        )
        let tunnel = Tunnel(
            name: "db",
            localPort: 15432,
            autoConnect: true,
            provider: .gcpIAP(GCPIAPConfig(
                instance: "prod-db",
                instancePort: 5432,
                zone: "us-central1-a",
                project: "acme-prod",
                account: "user@example.com"
            ))
        )
        let cfg = AppConfig(tunnels: [tunnel], preferences: Preferences(autoReconnect: false, authCheckIntervalMin: 15))
        try store.save(cfg)

        let loaded = store.load()
        XCTAssertEqual(loaded.tunnels.count, 1)
        XCTAssertEqual(loaded.tunnels[0].name, "db")
        XCTAssertEqual(loaded.tunnels[0].localPort, 15432)
        XCTAssertEqual(loaded.tunnels[0].autoConnect, true)
        guard case .gcpIAP(let gcp) = loaded.tunnels[0].provider else {
            XCTFail("expected gcpIAP provider"); return
        }
        XCTAssertEqual(gcp.instance, "prod-db")
        XCTAssertEqual(gcp.instancePort, 5432)
        XCTAssertEqual(gcp.account, "user@example.com")
    }

    func testAWSSSMRoundTrip() throws {
        let store = ConfigStore(
            configDirectoryURL: tempDir.appendingPathComponent("cfg"),
            legacyConfigURLs: [legacyDir.appendingPathComponent("config.json")]
        )
        let tunnel = Tunnel(
            name: "rds",
            localPort: 15432,
            autoConnect: false,
            provider: .awsSSM(AWSSSMConfig(
                target: "i-0abc123",
                remoteHost: "db.prod.internal",
                remotePort: 5432,
                profile: "prod-readonly",
                region: "us-west-2"
            ))
        )
        try store.save(AppConfig(tunnels: [tunnel], preferences: .default))
        let loaded = store.load()
        guard case .awsSSM(let aws) = loaded.tunnels[0].provider else {
            XCTFail("expected awsSSM"); return
        }
        XCTAssertEqual(aws.target, "i-0abc123")
        XCTAssertEqual(aws.remoteHost, "db.prod.internal")
        XCTAssertEqual(aws.remotePort, 5432)
        XCTAssertEqual(aws.profile, "prod-readonly")
        XCTAssertEqual(aws.region, "us-west-2")
    }

    func testLegacyMissingAccountDecodesAsNil() throws {
        let legacyPath = legacyDir.appendingPathComponent("config.json")
        try """
        { "tunnels": [{"name":"x","instance":"i","instance_port":22,"local_port":2222,"zone":"z","project":"p"}] }
        """.write(to: legacyPath, atomically: true, encoding: .utf8)
        let store = ConfigStore(
            configDirectoryURL: tempDir.appendingPathComponent("cfg"),
            legacyConfigURLs: [legacyPath]
        )
        guard case .gcpIAP(let gcp) = store.load().tunnels[0].provider else {
            XCTFail("expected gcpIAP"); return
        }
        XCTAssertNil(gcp.account)
    }

    func testAuthListJSONParsing() {
        let json = """
        [
          {"account": "alice@example.com", "status": "ACTIVE"},
          {"account": "bob@example.com", "status": ""}
        ]
        """
        let parsed = AuthManager.parseAuthList(json)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].email, "alice@example.com")
        XCTAssertEqual(parsed[0].isActive, true)
        XCTAssertEqual(parsed[1].email, "bob@example.com")
        XCTAssertEqual(parsed[1].isActive, false)
    }

    func testLegacyMigration() throws {
        let legacyPath = legacyDir.appendingPathComponent("config.json")
        let legacyJSON = """
        {
          "tunnels": [
            {
              "name": "ssh-box",
              "instance": "bastion",
              "instance_port": 22,
              "local_port": 2222,
              "zone": "us-east1-b",
              "project": "acme-legacy",
              "auto_connect": true
            }
          ],
          "preferences": {
            "auto_reconnect": true,
            "auth_check_interval_min": 45
          }
        }
        """
        try legacyJSON.write(to: legacyPath, atomically: true, encoding: .utf8)

        let store = ConfigStore(
            configDirectoryURL: tempDir.appendingPathComponent("cfg"),
            legacyConfigURLs: [legacyPath]
        )
        let cfg = store.load()
        XCTAssertEqual(cfg.tunnels.count, 1)
        XCTAssertEqual(cfg.tunnels[0].name, "ssh-box")
        XCTAssertEqual(cfg.tunnels[0].localPort, 2222)
        guard case .gcpIAP(let gcp) = cfg.tunnels[0].provider else {
            XCTFail("expected gcpIAP from legacy schema"); return
        }
        XCTAssertEqual(gcp.instance, "bastion")
        XCTAssertEqual(gcp.zone, "us-east1-b")
        XCTAssertEqual(gcp.project, "acme-legacy")
        XCTAssertEqual(cfg.preferences.authCheckIntervalMin, 45)
        // Legacy file should be left in place as a rollback
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyPath.path))
    }

    func testLegacyStringPortsTolerated() throws {
        let legacyPath = legacyDir.appendingPathComponent("config.json")
        let legacyJSON = """
        {
          "tunnels": [
            {
              "name": "x",
              "instance": "i",
              "instance_port": "22",
              "local_port": "2222",
              "zone": "z",
              "project": "p"
            }
          ]
        }
        """
        try legacyJSON.write(to: legacyPath, atomically: true, encoding: .utf8)

        let store = ConfigStore(
            configDirectoryURL: tempDir.appendingPathComponent("cfg"),
            legacyConfigURLs: [legacyPath]
        )
        let cfg = store.load()
        XCTAssertEqual(cfg.tunnels[0].localPort, 2222)
        guard case .gcpIAP(let gcp) = cfg.tunnels[0].provider else {
            XCTFail("expected gcpIAP"); return
        }
        XCTAssertEqual(gcp.instancePort, 22)
    }

    func testValidationRejectsDuplicateLocalPort() throws {
        let gcp = GCPIAPConfig(instance: "i", instancePort: 22, zone: "z", project: "p")
        let a = Tunnel(name: "a", localPort: 2222, provider: .gcpIAP(gcp))
        let b = Tunnel(name: "b", localPort: 2222, provider: .gcpIAP(gcp))
        XCTAssertNoThrow(try a.validate(against: []))
        XCTAssertThrowsError(try b.validate(against: [a]))
    }

    func testRoundTripPreservesKindAndActionConfig() throws {
        let store = ConfigStore(
            configDirectoryURL: tempDir.appendingPathComponent("cfg"),
            legacyConfigURLs: [legacyDir.appendingPathComponent("config.json")]
        )
        let t = Tunnel(
            name: "rds",
            localPort: 15432,
            provider: .gcpIAP(GCPIAPConfig(instance: "i", instancePort: 5432, zone: "z", project: "p")),
            kind: .postgres,
            actionConfig: ActionConfig(database: "mydb")
        )
        try store.save(AppConfig(tunnels: [t], preferences: .default))
        let loaded = store.load().tunnels[0]
        XCTAssertEqual(loaded.kind, .postgres)
        XCTAssertEqual(loaded.actionConfig.database, "mydb")
    }

    func testLegacyConfigDecodesAsTCPKind() throws {
        let legacyPath = legacyDir.appendingPathComponent("config.json")
        try """
        { "tunnels": [{"name":"x","instance":"i","instance_port":22,"local_port":2222,"zone":"z","project":"p"}] }
        """.write(to: legacyPath, atomically: true, encoding: .utf8)
        let store = ConfigStore(
            configDirectoryURL: tempDir.appendingPathComponent("cfg"),
            legacyConfigURLs: [legacyPath]
        )
        let loaded = store.load().tunnels[0]
        XCTAssertEqual(loaded.kind, .tcp)
        XCTAssertNil(loaded.actionConfig.username)
        XCTAssertNil(loaded.actionConfig.path)
        XCTAssertNil(loaded.actionConfig.database)
    }

    func testValidationRejectsOutOfRangePort() {
        let bad = Tunnel(
            name: "x", localPort: 2222,
            provider: .gcpIAP(GCPIAPConfig(instance: "i", instancePort: 99999, zone: "z", project: "p"))
        )
        XCTAssertThrowsError(try bad.validate(against: []))
    }
}
