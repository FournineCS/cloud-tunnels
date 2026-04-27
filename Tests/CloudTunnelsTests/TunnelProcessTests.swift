import XCTest
@testable import CloudTunnels
@testable import TunnelCore

final class GCPIAPLauncherPatternTests: XCTestCase {
    private let launcher = GCPIAPLauncher()

    func testAuthExpiredDetection() {
        for pattern in launcher.authFailurePatterns {
            XCTAssertTrue(
                launcher.isAuthExpired("some text with \(pattern) inside"),
                "expected detection for pattern: \(pattern)"
            )
            XCTAssertTrue(
                launcher.isAuthExpired("some text with \(pattern.uppercased()) inside"),
                "expected case-insensitive detection for pattern: \(pattern)"
            )
        }
    }

    func testNonAuthErrorNotFlagged() {
        XCTAssertFalse(launcher.isAuthExpired("ERROR: Connection refused by host"))
        XCTAssertFalse(launcher.isAuthExpired("Timed out waiting for tunnel handshake"))
    }

    func testListeningMarker() {
        XCTAssertTrue(launcher.isListening("Listening on port [2222]."))
        XCTAssertFalse(launcher.isListening("Testing if tunnel connection works."))
    }

    func testGCPArguments() throws {
        let tunnel = Tunnel(
            name: "ssh", localPort: 2222,
            provider: .gcpIAP(GCPIAPConfig(
                instance: "bastion",
                instancePort: 22,
                zone: "us-central1-a",
                project: "myproj",
                account: "user@example.com"
            ))
        )
        let args = try launcher.arguments(for: tunnel)
        XCTAssertEqual(args[0], "compute")
        XCTAssertEqual(args[1], "start-iap-tunnel")
        XCTAssertEqual(args[2], "bastion")
        XCTAssertEqual(args[3], "22")
        XCTAssertTrue(args.contains("--local-host-port=localhost:2222"))
        XCTAssertTrue(args.contains("--zone=us-central1-a"))
        XCTAssertTrue(args.contains("--project=myproj"))
        XCTAssertTrue(args.contains("--account=user@example.com"))
    }

    func testGCPArgumentsWithoutAccount() throws {
        let tunnel = Tunnel(
            name: "ssh", localPort: 2222,
            provider: .gcpIAP(GCPIAPConfig(instance: "i", instancePort: 22, zone: "z", project: "p"))
        )
        let args = try launcher.arguments(for: tunnel)
        XCTAssertFalse(args.contains(where: { $0.hasPrefix("--account=") }))
    }
}
