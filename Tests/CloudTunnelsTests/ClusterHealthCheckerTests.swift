import XCTest
@testable import CloudTunnels

final class ClusterHealthCheckerTests: XCTestCase {

    // MARK: - parseServerVersion

    /// Real shape of `kubectl version --context=X -o json` output
    /// against a live v1.29 cluster. We care that the parser
    /// pulls out `serverVersion.gitVersion` and ignores everything
    /// else.
    private let healthyVersionJSON = #"""
    {
        "clientVersion": {
            "major": "1",
            "minor": "29",
            "gitVersion": "v1.29.3"
        },
        "serverVersion": {
            "major": "1",
            "minor": "29",
            "gitVersion": "v1.29.5-gke.1091000",
            "buildDate": "2024-06-19T10:58:49Z",
            "platform": "linux/amd64"
        }
    }
    """#

    func testParsesGitVersionFromServerBlock() {
        let v = ClusterHealthChecker.parseServerVersion(from: healthyVersionJSON)
        XCTAssertEqual(v, "v1.29.5-gke.1091000")
    }

    func testParsesNilWhenMissingServerBlock() {
        let clientOnly = #"{"clientVersion":{"gitVersion":"v1.29.3"}}"#
        XCTAssertNil(ClusterHealthChecker.parseServerVersion(from: clientOnly))
    }

    func testParsesNilFromInvalidJSON() {
        XCTAssertNil(ClusterHealthChecker.parseServerVersion(from: "not json"))
    }

    // MARK: - summarizeError

    func testSummarizeConnectionRefused() {
        let stderr = "error: unable to connect to the server: dial tcp 10.0.0.1:6443: connect: connection refused"
        let msg = ClusterHealthChecker.summarizeError(stderr: stderr, exitCode: 1)
        XCTAssertEqual(msg, "Connection refused — API server unreachable")
    }

    func testSummarizeNoRouteToHost() {
        let stderr = "Unable to connect to the server: dial tcp: lookup x: no route to host"
        let msg = ClusterHealthChecker.summarizeError(stderr: stderr, exitCode: 1)
        XCTAssertEqual(msg, "No route to host — likely no tunnel or VPN active")
    }

    func testSummarizeIOTimeout() {
        let stderr = "Unable to connect to the server: dial tcp 10.0.0.1:6443: i/o timeout"
        let msg = ClusterHealthChecker.summarizeError(stderr: stderr, exitCode: 1)
        XCTAssertEqual(msg, "Request timed out")
    }

    func testSummarizeUnauthorized() {
        let stderr = "error: You must be logged in to the server (Unauthorized)"
        let msg = ClusterHealthChecker.summarizeError(stderr: stderr, exitCode: 1)
        XCTAssertEqual(msg, "Unauthorized — credentials expired or invalid")
    }

    func testSummarizeForbidden() {
        let stderr = "Error from server (Forbidden): pods is forbidden"
        let msg = ClusterHealthChecker.summarizeError(stderr: stderr, exitCode: 1)
        XCTAssertEqual(msg, "Forbidden — credentials valid but lack permissions")
    }

    func testSummarizeContextNotFound() {
        let stderr = "error: context \"nosuch\" does not exist"
        let msg = ClusterHealthChecker.summarizeError(stderr: stderr, exitCode: 1)
        XCTAssertEqual(msg, "Context does not exist in kubeconfig")
    }

    func testSummarizeTimeoutExitCode() {
        let msg = ClusterHealthChecker.summarizeError(stderr: "", exitCode: 124)
        XCTAssertEqual(msg, "Timed out — server did not respond")
    }

    func testSummarizeFallsBackToFirstLine() {
        let stderr = "something unusual happened\nmore detail"
        let msg = ClusterHealthChecker.summarizeError(stderr: stderr, exitCode: 1)
        XCTAssertEqual(msg, "something unusual happened")
    }

    func testSummarizeEmptyStderrFallsBackToExitCode() {
        let msg = ClusterHealthChecker.summarizeError(stderr: "", exitCode: 42)
        XCTAssertEqual(msg, "Probe failed (exit 42)")
    }

    // MARK: - probe() with injected runner

    func testProbeReachableReturnsServerVersion() {
        let runner: ClusterHealthChecker.Runner = { _, _ in
            Kubectl.Result(
                stdout: self.healthyVersionJSON,
                stderr: "",
                exitCode: 0
            )
        }
        let health = ClusterHealthChecker.probe(
            context: "prod",
            cluster: "gke_prod",
            runner: runner
        )
        XCTAssertTrue(health.reachable)
        XCTAssertEqual(health.serverVersion, "v1.29.5-gke.1091000")
        XCTAssertNil(health.errorSummary)
    }

    func testProbeUnreachableSummarizesStderr() {
        let runner: ClusterHealthChecker.Runner = { _, _ in
            Kubectl.Result(
                stdout: "",
                stderr: "Unable to connect to the server: dial tcp 10.0.0.1:6443: connect: connection refused",
                exitCode: 1
            )
        }
        let health = ClusterHealthChecker.probe(
            context: "prod",
            cluster: "gke_prod",
            runner: runner
        )
        XCTAssertFalse(health.reachable)
        XCTAssertNil(health.serverVersion)
        XCTAssertEqual(health.errorSummary, "Connection refused — API server unreachable")
    }

    func testProbeTimeoutMapsTo124ExitCode() {
        let runner: ClusterHealthChecker.Runner = { _, _ in
            Kubectl.Result(
                stdout: "",
                stderr: "kubectl timed out after 2s",
                exitCode: 124
            )
        }
        let health = ClusterHealthChecker.probe(
            context: "prod",
            cluster: "gke_prod",
            runner: runner
        )
        XCTAssertFalse(health.reachable)
        XCTAssertEqual(health.errorSummary, "Timed out — server did not respond")
    }

    func testProbeReachableButVersionMissingIsStillReachable() {
        // kubectl version -o json sometimes returns only client
        // info if the server request itself succeeded but returned
        // a degraded response. We still count that as reachable
        // — exit 0 is authoritative — but serverVersion is nil.
        let runner: ClusterHealthChecker.Runner = { _, _ in
            Kubectl.Result(
                stdout: #"{"clientVersion":{"gitVersion":"v1.29.3"}}"#,
                stderr: "",
                exitCode: 0
            )
        }
        let health = ClusterHealthChecker.probe(
            context: "weird",
            cluster: "weird-cluster",
            runner: runner
        )
        XCTAssertTrue(health.reachable)
        XCTAssertNil(health.serverVersion)
    }
}
