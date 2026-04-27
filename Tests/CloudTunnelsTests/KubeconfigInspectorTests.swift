import XCTest
@testable import CloudTunnels

final class KubeconfigInspectorTests: XCTestCase {

    // MARK: - JSON decoding from fixtures

    /// Representative `kubectl config view -o json` output with
    /// a proxy-url'd cluster (the shape our SSH tunnel kubeconfig
    /// patch produces), a secondary cluster, and two contexts
    /// where the second is the current one.
    private let fullFixture = #"""
    {
        "kind": "Config",
        "apiVersion": "v1",
        "current-context": "gke_prod",
        "clusters": [
            {
                "name": "gke_my-gcp-project_us-central1_my-cluster",
                "cluster": {
                    "server": "https://1.2.3.4",
                    "proxy-url": "socks5://127.0.0.1:1080",
                    "insecure-skip-tls-verify": true,
                    "certificate-authority-data": "LS0tLS1CRUdJTi..."
                }
            },
            {
                "name": "docker-desktop",
                "cluster": {
                    "server": "https://localhost:6443",
                    "certificate-authority-data": "LS0tLS1CRUdJTi..."
                }
            }
        ],
        "contexts": [
            {
                "name": "docker-desktop",
                "context": {
                    "cluster": "docker-desktop",
                    "user": "docker-desktop",
                    "namespace": "default"
                }
            },
            {
                "name": "gke_prod",
                "context": {
                    "cluster": "gke_my-gcp-project_us-central1_my-cluster",
                    "user": "gke_admin"
                }
            }
        ],
        "users": [
            {
                "name": "docker-desktop",
                "user": {
                    "client-certificate-data": "LS0tLS1CRUdJTi...",
                    "client-key-data": "LS0tLS1CRUdJTi..."
                }
            },
            {
                "name": "gke_admin",
                "user": {
                    "exec": {
                        "command": "gke-gcloud-auth-plugin",
                        "apiVersion": "client.authentication.k8s.io/v1beta1"
                    }
                }
            }
        ]
    }
    """#

    func testDecodesFullKubeconfig() throws {
        let inspected = try KubeconfigInspector.decode(jsonString: fullFixture)
        XCTAssertEqual(inspected.currentContext, "gke_prod")
        XCTAssertEqual(inspected.clusters.count, 2)
        XCTAssertEqual(inspected.contexts.count, 2)
        XCTAssertEqual(inspected.users.count, 2)
    }

    func testProxyURLSurfacedOnCluster() throws {
        let inspected = try KubeconfigInspector.decode(jsonString: fullFixture)
        let prodCluster = inspected.clusters.first { $0.name.hasPrefix("gke_my-gcp-project") }
        XCTAssertNotNil(prodCluster)
        XCTAssertEqual(prodCluster?.proxyURL, "socks5://127.0.0.1:1080")
        XCTAssertTrue(prodCluster?.insecureSkipTLSVerify == true)
    }

    func testNonProxyClusterHasNilProxyURL() throws {
        let inspected = try KubeconfigInspector.decode(jsonString: fullFixture)
        let docker = inspected.clusters.first { $0.name == "docker-desktop" }
        XCTAssertNotNil(docker)
        XCTAssertNil(docker?.proxyURL)
        XCTAssertFalse(docker?.insecureSkipTLSVerify == true)
    }

    func testCurrentContextFlaggedOnCorrectRow() throws {
        let inspected = try KubeconfigInspector.decode(jsonString: fullFixture)
        let currentCtx = inspected.contexts.first { $0.isCurrent }
        XCTAssertEqual(currentCtx?.name, "gke_prod")
        XCTAssertEqual(inspected.contexts.filter { $0.isCurrent }.count, 1)
    }

    func testContextNamespaceCarriedThrough() throws {
        let inspected = try KubeconfigInspector.decode(jsonString: fullFixture)
        let docker = inspected.contexts.first { $0.name == "docker-desktop" }
        XCTAssertEqual(docker?.namespace, "default")
    }

    // MARK: - auth-method classification

    func testClassifyAuthMethodClientCertificate() {
        let user = KubeconfigInspector.KubeconfigDTO.UserDetails(
            token: nil,
            username: nil,
            password: nil,
            clientCertificate: nil,
            clientCertificateData: "LS0tLS1CRUdJTi...",
            clientKey: nil,
            clientKeyData: "LS0tLS1CRUdJTi...",
            authProvider: nil,
            exec: nil
        )
        XCTAssertEqual(KubeconfigInspector.classifyAuthMethod(user), "client certificate")
    }

    func testClassifyAuthMethodExec() {
        let user = KubeconfigInspector.KubeconfigDTO.UserDetails(
            token: nil,
            username: nil,
            password: nil,
            clientCertificate: nil,
            clientCertificateData: nil,
            clientKey: nil,
            clientKeyData: nil,
            authProvider: nil,
            exec: .init(command: "aws-iam-authenticator", apiVersion: "client.authentication.k8s.io/v1beta1")
        )
        XCTAssertEqual(KubeconfigInspector.classifyAuthMethod(user), "exec (plugin)")
    }

    func testClassifyAuthMethodToken() {
        let user = KubeconfigInspector.KubeconfigDTO.UserDetails(
            token: "eyJhbGciOi...",
            username: nil,
            password: nil,
            clientCertificate: nil,
            clientCertificateData: nil,
            clientKey: nil,
            clientKeyData: nil,
            authProvider: nil,
            exec: nil
        )
        XCTAssertEqual(KubeconfigInspector.classifyAuthMethod(user), "token")
    }

    func testClassifyAuthMethodAuthProvider() {
        let user = KubeconfigInspector.KubeconfigDTO.UserDetails(
            token: nil,
            username: nil,
            password: nil,
            clientCertificate: nil,
            clientCertificateData: nil,
            clientKey: nil,
            clientKeyData: nil,
            authProvider: .init(name: "gcp"),
            exec: nil
        )
        XCTAssertEqual(KubeconfigInspector.classifyAuthMethod(user), "auth-provider: gcp")
    }

    func testClassifyAuthMethodBasic() {
        let user = KubeconfigInspector.KubeconfigDTO.UserDetails(
            token: nil,
            username: "admin",
            password: "secret",
            clientCertificate: nil,
            clientCertificateData: nil,
            clientKey: nil,
            clientKeyData: nil,
            authProvider: nil,
            exec: nil
        )
        XCTAssertEqual(KubeconfigInspector.classifyAuthMethod(user), "basic (username/password)")
    }

    func testClassifyAuthMethodUnknown() {
        let user = KubeconfigInspector.KubeconfigDTO.UserDetails(
            token: nil,
            username: nil,
            password: nil,
            clientCertificate: nil,
            clientCertificateData: nil,
            clientKey: nil,
            clientKeyData: nil,
            authProvider: nil,
            exec: nil
        )
        XCTAssertEqual(KubeconfigInspector.classifyAuthMethod(user), "unknown")
    }

    // MARK: - Error paths

    func testDecodeFailsOnInvalidJSON() {
        XCTAssertThrowsError(
            try KubeconfigInspector.decode(jsonString: "not a kubeconfig")
        ) { error in
            guard case KubeconfigInspector.InspectError.decodeFailed = error else {
                return XCTFail("expected decodeFailed, got \(error)")
            }
        }
    }

    func testDecodeHandlesEmptyKubeconfig() throws {
        let empty = #"{"kind":"Config","apiVersion":"v1","current-context":"","clusters":null,"contexts":null,"users":null}"#
        let inspected = try KubeconfigInspector.decode(jsonString: empty)
        XCTAssertTrue(inspected.clusters.isEmpty)
        XCTAssertTrue(inspected.contexts.isEmpty)
        XCTAssertTrue(inspected.users.isEmpty)
    }
}
