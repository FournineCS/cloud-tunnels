import XCTest
@testable import CloudTunnels
@testable import TunnelCore

final class AWSSSMLauncherTests: XCTestCase {
    private let launcher = AWSSSMLauncher()

    func testParametersJSONDirectMode() throws {
        let json = try AWSSSMLauncher.buildParametersJSON(
            remoteHost: nil, remotePort: 22, localPort: 2222
        )
        let dict = try JSONDecoder().decode([String: [String]].self, from: Data(json.utf8))
        XCTAssertEqual(dict["portNumber"], ["22"])
        XCTAssertEqual(dict["localPortNumber"], ["2222"])
        XCTAssertNil(dict["host"])
    }

    func testParametersJSONBastionMode() throws {
        let json = try AWSSSMLauncher.buildParametersJSON(
            remoteHost: "db.prod.internal", remotePort: 5432, localPort: 15432
        )
        let dict = try JSONDecoder().decode([String: [String]].self, from: Data(json.utf8))
        XCTAssertEqual(dict["host"], ["db.prod.internal"])
        XCTAssertEqual(dict["portNumber"], ["5432"])
        XCTAssertEqual(dict["localPortNumber"], ["15432"])
    }

    func testArgumentsDirectMode() throws {
        let tunnel = Tunnel(
            name: "ssh", localPort: 2222,
            provider: .awsSSM(AWSSSMConfig(target: "i-0abc", remotePort: 22))
        )
        let args = try launcher.arguments(for: tunnel)
        XCTAssertEqual(args[0], "ssm")
        XCTAssertEqual(args[1], "start-session")
        XCTAssertTrue(args.contains("--target"))
        XCTAssertTrue(args.contains("i-0abc"))
        XCTAssertTrue(args.contains("AWS-StartPortForwardingSession"))
        XCTAssertFalse(args.contains("AWS-StartPortForwardingSessionToRemoteHost"))
        XCTAssertFalse(args.contains("--profile"))
        XCTAssertFalse(args.contains("--region"))
    }

    func testArgumentsBastionToRemote() throws {
        let tunnel = Tunnel(
            name: "rds", localPort: 15432,
            provider: .awsSSM(AWSSSMConfig(
                target: "i-0bastion",
                remoteHost: "db.prod",
                remotePort: 5432,
                profile: "prod-ro",
                region: "us-west-2"
            ))
        )
        let args = try launcher.arguments(for: tunnel)
        XCTAssertTrue(args.contains("AWS-StartPortForwardingSessionToRemoteHost"))
        XCTAssertTrue(args.contains("--profile"))
        XCTAssertTrue(args.contains("prod-ro"))
        XCTAssertTrue(args.contains("--region"))
        XCTAssertTrue(args.contains("us-west-2"))

        // The --parameters value should be valid JSON containing the right keys
        guard let paramIdx = args.firstIndex(of: "--parameters") else {
            XCTFail("--parameters missing"); return
        }
        let paramJSON = args[paramIdx + 1]
        let dict = try JSONDecoder().decode([String: [String]].self, from: Data(paramJSON.utf8))
        XCTAssertEqual(dict["host"], ["db.prod"])
        XCTAssertEqual(dict["portNumber"], ["5432"])
        XCTAssertEqual(dict["localPortNumber"], ["15432"])
    }

    func testProviderMismatchThrows() {
        let tunnel = Tunnel(
            name: "x", localPort: 2222,
            provider: .gcpIAP(GCPIAPConfig(instance: "i", instancePort: 22, zone: "z", project: "p"))
        )
        XCTAssertThrowsError(try launcher.arguments(for: tunnel))
    }

    func testAuthExpiredPatternsAllMatch() {
        for pattern in launcher.authFailurePatterns {
            XCTAssertTrue(
                launcher.isAuthExpired("aws cli error: \(pattern)"),
                "expected detection for: \(pattern)"
            )
        }
    }

    func testListeningMarker() {
        XCTAssertTrue(launcher.isListening("Waiting for connections..."))
        XCTAssertTrue(launcher.isListening("Port opened for sessionId: abc-123"))
        XCTAssertFalse(launcher.isListening("Starting session with SessionId: abc"))
    }

    func testProfileListParsing() {
        let parsed = AWSAuthManager.parseProfileList("default\nprod-ro\nstage\n")
        XCTAssertEqual(parsed, ["default", "prod-ro", "stage"])
    }

    func testCallerIdentityParsing() {
        let json = """
        {"UserId": "AIDAEXAMPLE", "Account": "123456789012", "Arn": "arn:aws:iam::123456789012:user/sam"}
        """
        let id = AWSAuthManager.parseCallerIdentity(json)
        XCTAssertEqual(id.accountId, "123456789012")
        XCTAssertEqual(id.arn, "arn:aws:iam::123456789012:user/sam")
    }
}
