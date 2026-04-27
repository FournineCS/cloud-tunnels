import XCTest
@testable import CloudTunnelsProxyHelper

/// Pure mutation tests against in-memory /etc/hosts content. The
/// side-effecting `HostsFileWriter` is intentionally out of scope here —
/// it requires root and a real /etc/hosts and is exercised only by the
/// end-to-end manual verification step.
final class HostsFileTests: XCTestCase {

    private let baseline = """
    ##
    # Host Database
    ##
    127.0.0.1\tlocalhost
    255.255.255.255\tbroadcasthost
    ::1             localhost
    """

    private let tunnelA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let tunnelB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    // MARK: - Format

    func testFormatLineShape() {
        let line = HostsFile.formatLine(
            tunnelID: tunnelA,
            hostname: "vpce.example.com"
        )
        XCTAssertEqual(
            line,
            "127.0.0.1\tvpce.example.com\t# CloudTunnels:11111111-1111-1111-1111-111111111111"
        )
    }

    // MARK: - Append

    func testAppendingPreservesForeignLines() {
        let file = HostsFile(content: baseline)
        let next = file.appending(tunnelID: tunnelA, hostname: "vpce.example.com")
        XCTAssertTrue(next.content.contains("# Host Database"))
        XCTAssertTrue(next.content.contains("127.0.0.1\tlocalhost"))
        XCTAssertTrue(next.content.contains("vpce.example.com"))
        XCTAssertTrue(next.content.contains(tunnelA.uuidString.lowercased()))
    }

    func testAppendingEnsuresTrailingNewline() {
        let file = HostsFile(content: "127.0.0.1\tlocalhost")  // no trailing \n
        let next = file.appending(tunnelID: tunnelA, hostname: "vpce.example.com")
        XCTAssertTrue(next.content.hasSuffix("\n"))
    }

    func testAppendingIsIdempotentForSameHostname() {
        let file = HostsFile(content: baseline)
        let once = file.appending(tunnelID: tunnelA, hostname: "vpce.example.com")
        let twice = once.appending(tunnelID: tunnelA, hostname: "vpce.example.com")
        XCTAssertEqual(once.content, twice.content)
    }

    func testAppendingReplacesStaleManagedLineForSameHostname() {
        // Simulates: tunnel A wrote a line, the helper crashed, the user
        // recreated the tunnel (new UUID), reconnect should self-heal into
        // a single canonical line owned by the new UUID.
        let file = HostsFile(content: baseline)
        let withStale = file.appending(tunnelID: tunnelA, hostname: "vpce.example.com")
        let recovered = withStale.appending(tunnelID: tunnelB, hostname: "vpce.example.com")

        let lines = recovered.content.split(separator: "\n").map(String.init)
        let managedLines = lines.filter { $0.contains("vpce.example.com") }
        XCTAssertEqual(managedLines.count, 1, "Should converge on a single managed line per hostname")
        XCTAssertTrue(managedLines[0].contains(tunnelB.uuidString.lowercased()))
        XCTAssertFalse(managedLines[0].contains(tunnelA.uuidString.lowercased()))
    }

    func testAppendingDoesNotTouchForeignLineForSameHostname() {
        // User pre-wrote their own /etc/hosts entry for the same hostname.
        // We must NOT delete it. The fact that two lines now point at
        // 127.0.0.1 is harmless — both target the loopback.
        let foreign = baseline + "\n127.0.0.1\tvpce.example.com  # set by hand"
        let file = HostsFile(content: foreign)
        let next = file.appending(tunnelID: tunnelA, hostname: "vpce.example.com")
        XCTAssertTrue(next.content.contains("set by hand"))
        XCTAssertTrue(next.content.contains(HostsFile.markerPrefix + tunnelA.uuidString.lowercased()))
    }

    func testAppendingMultipleHostsForSameTunnel() {
        let file = HostsFile(content: baseline)
        let next = file
            .appending(tunnelID: tunnelA, hostname: "a.example.com")
            .appending(tunnelID: tunnelA, hostname: "b.example.com")
        XCTAssertTrue(next.content.contains("a.example.com"))
        XCTAssertTrue(next.content.contains("b.example.com"))
        XCTAssertEqual(next.managedEntries().count, 2)
    }

    // MARK: - Remove by tunnel ID

    func testRemovingLinesByTunnelIDLeavesOthersAlone() {
        let file = HostsFile(content: baseline)
            .appending(tunnelID: tunnelA, hostname: "a.example.com")
            .appending(tunnelID: tunnelB, hostname: "b.example.com")

        let cleaned = file.removingLines(taggedWith: tunnelA)
        XCTAssertFalse(cleaned.content.contains("a.example.com"))
        XCTAssertTrue(cleaned.content.contains("b.example.com"))
        XCTAssertTrue(cleaned.content.contains("# Host Database"))
    }

    func testRemovingByTunnelIDIsNoOpWhenAbsent() {
        let file = HostsFile(content: baseline)
        let cleaned = file.removingLines(taggedWith: tunnelA)
        XCTAssertEqual(cleaned.content, file.content.appendingNewline())
    }

    func testRemovingByTunnelIDNeverTouchesForeignLines() {
        let foreign = baseline + "\n127.0.0.1\tvpce.example.com  # set by hand"
        let file = HostsFile(content: foreign)
            .appending(tunnelID: tunnelA, hostname: "vpce.example.com")
        let cleaned = file.removingLines(taggedWith: tunnelA)
        XCTAssertTrue(cleaned.content.contains("set by hand"), "Foreign line must survive cleanup")
        XCTAssertFalse(cleaned.content.contains(tunnelA.uuidString.lowercased()))
    }

    // MARK: - Remove all managed

    func testRemovingAllManagedLinesUninstall() {
        let file = HostsFile(content: baseline)
            .appending(tunnelID: tunnelA, hostname: "a.example.com")
            .appending(tunnelID: tunnelB, hostname: "b.example.com")
        let cleaned = file.removingAllManagedLines()
        XCTAssertFalse(cleaned.content.contains("CloudTunnels:"))
        XCTAssertTrue(cleaned.content.contains("# Host Database"))
        XCTAssertTrue(cleaned.content.contains("127.0.0.1\tlocalhost"))
    }

    // MARK: - Queries

    func testManagedEntriesRoundTrip() {
        let file = HostsFile(content: baseline)
            .appending(tunnelID: tunnelA, hostname: "a.example.com")
            .appending(tunnelID: tunnelB, hostname: "b.example.com")
        let entries = file.managedEntries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.contains { $0.tunnelID == tunnelA && $0.hostname == "a.example.com" })
        XCTAssertTrue(entries.contains { $0.tunnelID == tunnelB && $0.hostname == "b.example.com" })
    }

    func testContainsManagedHost() {
        let file = HostsFile(content: baseline)
            .appending(tunnelID: tunnelA, hostname: "vpce.example.com")
        XCTAssertTrue(file.containsManagedHost("vpce.example.com"))
        XCTAssertFalse(file.containsManagedHost("other.example.com"))
        XCTAssertFalse(file.containsManagedHost("localhost"))  // foreign, not managed
    }
}

private extension String {
    func appendingNewline() -> String {
        if hasSuffix("\n") { return self }
        return self + "\n"
    }
}
