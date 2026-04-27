import XCTest
@testable import CloudTunnels

final class K8sSecretCoderTests: XCTestCase {

    // MARK: - encodeAsSecretYAML

    func testEncodeProducesValidSecretYAML() {
        let yaml = K8sSecretCoder.encodeAsSecretYAML(
            value: "hunter2",
            name: "my-app",
            key: "password"
        )
        XCTAssertTrue(yaml.contains("apiVersion: v1"))
        XCTAssertTrue(yaml.contains("kind: Secret"))
        XCTAssertTrue(yaml.contains("name: my-app"))
        XCTAssertTrue(yaml.contains("type: Opaque"))
        XCTAssertTrue(yaml.contains("password: aHVudGVyMg==")) // "hunter2" in base64
    }

    func testEncodeFallsBackToDefaultName() {
        let yaml = K8sSecretCoder.encodeAsSecretYAML(value: "x", name: "", key: "")
        XCTAssertTrue(yaml.contains("name: my-secret"))
        XCTAssertTrue(yaml.contains("key: eA==")) // "x" in base64
    }

    func testEncodeRoundTripThroughDecode() {
        let yaml = K8sSecretCoder.encodeAsSecretYAML(
            value: "p@ss!w0rd with spaces",
            name: "creds",
            key: "db_password"
        )
        let decoded = K8sSecretCoder.decodeSecretYAML(yaml)
        XCTAssertEqual(decoded?.count, 1)
        XCTAssertEqual(decoded?[0].key, "db_password")
        XCTAssertEqual(decoded?[0].value, "p@ss!w0rd with spaces")
    }

    // MARK: - decodeSecretYAML

    func testDecodesMultipleKeys() {
        let yaml = """
        apiVersion: v1
        kind: Secret
        metadata:
          name: creds
        type: Opaque
        data:
          username: YWRtaW4=
          password: aHVudGVyMg==
          api-key: c2tfdGVzdA==
        """
        let decoded = K8sSecretCoder.decodeSecretYAML(yaml)
        XCTAssertEqual(decoded?.count, 3)
        XCTAssertEqual(decoded?.first { $0.key == "username" }?.value, "admin")
        XCTAssertEqual(decoded?.first { $0.key == "password" }?.value, "hunter2")
        XCTAssertEqual(decoded?.first { $0.key == "api-key" }?.value, "sk_test")
    }

    func testDecodesWith4SpaceIndent() {
        // `kubectl get secret -o yaml` sometimes uses 4-space
        // indentation depending on your cluster config. Make
        // sure we handle both.
        let yaml = """
        apiVersion: v1
        kind: Secret
        metadata:
            name: creds
        data:
            username: YWRtaW4=
            password: aHVudGVyMg==
        """
        let decoded = K8sSecretCoder.decodeSecretYAML(yaml)
        XCTAssertEqual(decoded?.count, 2)
    }

    func testDecodesIgnoresMetadataAfterData() {
        let yaml = """
        apiVersion: v1
        kind: Secret
        data:
          token: dG9rLTEyMw==
        type: Opaque
        metadata:
          name: creds
        """
        let decoded = K8sSecretCoder.decodeSecretYAML(yaml)
        XCTAssertEqual(decoded?.count, 1)
        XCTAssertEqual(decoded?[0].key, "token")
        XCTAssertEqual(decoded?[0].value, "tok-123")
    }

    func testDecodesIgnoresCommentsInDataBlock() {
        let yaml = """
        apiVersion: v1
        kind: Secret
        data:
          # this is the DB password
          password: aHVudGVyMg==
          # username below
          username: YWRtaW4=
        """
        let decoded = K8sSecretCoder.decodeSecretYAML(yaml)
        XCTAssertEqual(decoded?.count, 2)
    }

    func testDecodesStripsQuotedValues() {
        let yaml = """
        data:
          a: "YWRtaW4="
          b: 'aHVudGVyMg=='
          c: cGxhaW4=
        """
        let decoded = K8sSecretCoder.decodeSecretYAML(yaml)
        XCTAssertEqual(decoded?.count, 3)
        XCTAssertEqual(decoded?.first { $0.key == "a" }?.value, "admin")
        XCTAssertEqual(decoded?.first { $0.key == "b" }?.value, "hunter2")
        XCTAssertEqual(decoded?.first { $0.key == "c" }?.value, "plain")
    }

    func testDecodesHandlesEmptyDataBlock() {
        let yaml = """
        apiVersion: v1
        kind: Secret
        data:
        type: Opaque
        """
        let decoded = K8sSecretCoder.decodeSecretYAML(yaml)
        XCTAssertEqual(decoded?.count, 0)
    }

    func testDecodesReturnsNilWhenNoDataBlock() {
        let yaml = """
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: x
        """
        XCTAssertNil(K8sSecretCoder.decodeSecretYAML(yaml))
    }

    func testDecodesSurfacesRawBase64OnNonUTF8() {
        // Base64 of random bytes that aren't valid UTF-8.
        let nonUTF8 = Data([0xff, 0xfe, 0xfd]).base64EncodedString()
        let yaml = """
        data:
          binary: \(nonUTF8)
        """
        let decoded = K8sSecretCoder.decodeSecretYAML(yaml)
        XCTAssertEqual(decoded?.count, 1)
        XCTAssertNil(decoded?[0].value)
        XCTAssertEqual(decoded?[0].rawBase64, nonUTF8)
    }

    // MARK: - leadingSpaces

    func testLeadingSpacesCountsSpaces() {
        XCTAssertEqual(K8sSecretCoder.leadingSpaces("    foo"), 4)
        XCTAssertEqual(K8sSecretCoder.leadingSpaces("  foo"), 2)
        XCTAssertEqual(K8sSecretCoder.leadingSpaces("foo"), 0)
    }

    func testLeadingSpacesTreatsTabsAsOne() {
        XCTAssertEqual(K8sSecretCoder.leadingSpaces("\t\tfoo"), 2)
    }

    // MARK: - parseDataLine

    func testParseDataLineHappyPath() {
        let entry = K8sSecretCoder.parseDataLine("password: aHVudGVyMg==")
        XCTAssertEqual(entry?.key, "password")
        XCTAssertEqual(entry?.value, "hunter2")
        XCTAssertEqual(entry?.rawBase64, "aHVudGVyMg==")
    }

    func testParseDataLineRejectsLineWithoutColon() {
        XCTAssertNil(K8sSecretCoder.parseDataLine("password hunter2"))
    }

    func testParseDataLineRejectsEmptyKey() {
        XCTAssertNil(K8sSecretCoder.parseDataLine(": hunter2"))
    }
}
