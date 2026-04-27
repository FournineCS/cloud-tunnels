import Foundation
import X509
import Security

/// Connects to `host:port`, performs a TLS handshake, captures the
/// server-presented certificate chain, and returns the leaf cert
/// parsed into an `Inspected` struct via the existing CertInspector.
///
/// Uses URLSession with a dummy HEAD request + a custom auth
/// challenge delegate that extracts the `SecTrust`, reads every
/// `SecCertificate` in its chain, converts each to DER bytes via
/// `SecCertificateCopyData`, and re-parses them through
/// `X509.Certificate(derEncoded:)`. Then we cancel the challenge so
/// no actual HTTP request goes over the wire.
///
/// Why not `Network.framework` (`NWConnection`) directly: it's more
/// code for a feature that doesn't need low-level control, and
/// URLSession's delegate already gives us the full chain.
public enum SSLChecker {

    public struct CheckResult: Equatable {
        /// Parsed leaf cert (same struct the CertInspector view
        /// renders) plus the chain length so the view can show
        /// "2 cert chain" in the result row.
        public let leaf: CertInspector.Inspected
        public let chainLength: Int
        public let hostname: String
        public let port: Int
        /// Every cert in the server-presented chain parsed into
        /// the same `Inspected` struct. `chain[0]` equals `leaf`;
        /// subsequent entries are intermediates ordered per
        /// SecTrust (leaf → intermediates → root if sent).
        public let chain: [CertInspector.Inspected]
    }

    public enum CheckError: LocalizedError {
        case invalidHost(String)
        case network(String)
        case noCertificateChain
        case parseFailed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidHost(let h):
                return "Invalid hostname or port: \(h)"
            case .network(let msg):
                return "Could not connect: \(msg)"
            case .noCertificateChain:
                return "Server did not present a certificate chain."
            case .parseFailed(let detail):
                return "Failed to parse certificate: \(detail)"
            }
        }
    }

    /// Connect to `hostname:port`, capture the cert chain, return
    /// the parsed leaf. Cancels the HTTP request before any
    /// application data is sent — only the TLS handshake actually
    /// runs on the wire.
    public static func check(hostname: String, port: Int = 443) async throws -> CheckResult {
        let trimmedHost = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, port > 0, port <= 65535 else {
            throw CheckError.invalidHost("\(hostname):\(port)")
        }

        let url: URL
        if port == 443 {
            guard let u = URL(string: "https://\(trimmedHost)/") else {
                throw CheckError.invalidHost(trimmedHost)
            }
            url = u
        } else {
            guard let u = URL(string: "https://\(trimmedHost):\(port)/") else {
                throw CheckError.invalidHost(trimmedHost)
            }
            url = u
        }

        let delegate = TrustCapturingDelegate()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10

        // Fire the request. We expect it to fail — our delegate
        // cancels the auth challenge after capturing the chain.
        // We don't actually care about the HTTP result; only the
        // captured cert chain matters.
        do {
            _ = try await session.data(for: request)
        } catch {
            // Two legitimate exit paths:
            //   (a) delegate captured the chain and cancelled, so
            //       the request errors with NSURLErrorCancelled or
            //       a TLS-handshake-aborted error. That's fine.
            //   (b) real network failure (no route, DNS, etc.) with
            //       no chain captured. Re-throw with the error.
            if delegate.capturedChain.isEmpty {
                throw CheckError.network(error.localizedDescription)
            }
        }
        session.invalidateAndCancel()

        guard !delegate.capturedChain.isEmpty else {
            throw CheckError.noCertificateChain
        }

        // Parse every cert in the chain. The chain's first element
        // is the leaf per SecTrust ordering (leaf → intermediates
        // → root). Failing to parse any entry is fatal — a broken
        // cert in the middle of the chain is something the user
        // needs to know about, not hide.
        var chain: [CertInspector.Inspected] = []
        for secCert in delegate.capturedChain {
            let der = SecCertificateCopyData(secCert) as Data
            do {
                let cert = try Certificate(derEncoded: Array(der))
                chain.append(CertInspector.summarize(cert))
            } catch {
                throw CheckError.parseFailed(error.localizedDescription)
            }
        }

        return CheckResult(
            leaf: chain[0],
            chainLength: chain.count,
            hostname: trimmedHost,
            port: port,
            chain: chain
        )
    }
}

/// URLSession delegate that captures the server trust's certificate
/// chain during the TLS auth challenge and immediately cancels. The
/// capture happens before any HTTP payload flows, so we're only on
/// the wire for the handshake itself.
private final class TrustCapturingDelegate: NSObject, URLSessionDelegate {
    var capturedChain: [SecCertificate] = []
    private let lock = NSLock()

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        defer {
            // Always cancel the auth challenge. We never want to
            // actually complete the request — we just needed the
            // handshake to extract the server's certificate.
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        if #available(macOS 12.0, *) {
            let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
            self.capturedChain = chain
        } else {
            // Fallback for older macOS: copy certs one at a time.
            var chain: [SecCertificate] = []
            let count = SecTrustGetCertificateCount(trust)
            for i in 0..<count {
                if let cert = SecTrustGetCertificateAtIndex(trust, i) {
                    chain.append(cert)
                }
            }
            self.capturedChain = chain
        }
    }
}
