import Foundation

/// Wrapper around the public onetimesecret.com share API. Posts a
/// secret anonymously and returns a one-time URL that the recipient
/// can visit exactly once before the link self-destructs.
///
/// Used by the Password Generator, JWT Secret Generator, and the
/// standalone "Share Secret" tool to give users a safer way to hand
/// off generated secrets than pasting them into Slack or email.
///
/// No API key required — anonymous shares are rate-limited but free.
/// If the user wants a longer TTL or to track who viewed the link
/// they can sign up at onetimesecret.com and use the authenticated
/// API; that's deferred until someone asks for it.
public enum OneTimeSecret {

    /// Time-to-live options the user can pick when sharing. Anonymous
    /// shares are capped by the upstream service at 7 days; we offer
    /// shorter TTLs as well because a 1-hour share is a sensible
    /// default for an interactive credential handoff.
    public enum TTL: Int, CaseIterable, Identifiable {
        case fiveMinutes = 300
        case oneHour = 3600
        case oneDay = 86400
        case oneWeek = 604800

        public var id: Int { rawValue }

        public var displayName: String {
            switch self {
            case .fiveMinutes: return "5 minutes"
            case .oneHour: return "1 hour"
            case .oneDay: return "1 day"
            case .oneWeek: return "1 week (max for anonymous)"
            }
        }
    }

    public enum ShareError: LocalizedError, Equatable {
        /// Network-level failure: DNS, TCP, TLS, etc. before we got
        /// any HTTP response.
        case network(String)
        /// Upstream returned a non-2xx HTTP status. The body text is
        /// surfaced so the user can see the real error message.
        case upstream(Int, String)
        /// Response was 2xx but the JSON didn't contain a usable
        /// `secret_key` field. Indicates an API change or upstream
        /// degradation.
        case malformed(String)
        /// Caller passed an empty string. We catch this client-side
        /// because the upstream returns a confusing error in that case.
        case emptySecret

        public var errorDescription: String? {
            switch self {
            case .network(let msg): return "Network error: \(msg)"
            case .upstream(let code, let body): return "onetimesecret returned \(code): \(body)"
            case .malformed(let detail): return "Malformed response from onetimesecret: \(detail)"
            case .emptySecret: return "Cannot share an empty secret."
            }
        }
    }

    /// API endpoint used for anonymous shares. The v1 API is the
    /// stable, documented one; v2 exists but requires authentication.
    public static let apiURL = URL(string: "https://onetimesecret.com/api/v1/share")!

    /// User-facing prefix for the share link the recipient will visit.
    /// The full URL is built by appending the `secret_key` returned
    /// by the API.
    public static let shareURLPrefix = "https://onetimesecret.com/secret/"

    // MARK: - Public API

    /// POSTs the secret anonymously and returns the share URL.
    /// Throws `ShareError` for network, HTTP, or parsing failures.
    public static func share(_ secret: String, ttl: TTL) async throws -> URL {
        guard !secret.isEmpty else { throw ShareError.emptySecret }

        let body = encodeFormBody(secret: secret, ttlSeconds: ttl.rawValue)

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.upload(for: request, from: body)
        } catch {
            throw ShareError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ShareError.malformed("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "<binary>"
            throw ShareError.upstream(http.statusCode, bodyText)
        }

        let secretKey = try parseSecretKey(from: data)
        return try buildShareURL(secretKey: secretKey)
    }

    // MARK: - Pure helpers (testable without network)

    /// Build the form body for the share request. Exposed for tests
    /// so we can verify the encoding without hitting the real API.
    /// Both fields go through percent-encoding because secrets may
    /// contain `&`, `=`, `+`, etc.
    public static func encodeFormBody(secret: String, ttlSeconds: Int) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encodedSecret = secret.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let bodyString = "secret=\(encodedSecret)&ttl=\(ttlSeconds)"
        return bodyString.data(using: .utf8) ?? Data()
    }

    /// Pull the `secret_key` field from the API's JSON response.
    /// Onetimesecret v1 returns a flat object like:
    ///   { "custid": "anon", "metadata_key": "...", "secret_key": "..." }
    public static func parseSecretKey(from data: Data) throws -> String {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ShareError.malformed("not JSON: \(error.localizedDescription)")
        }
        guard let obj = json as? [String: Any] else {
            throw ShareError.malformed("response is not a JSON object")
        }
        guard let key = obj["secret_key"] as? String, !key.isEmpty else {
            throw ShareError.malformed("missing or empty secret_key field")
        }
        return key
    }

    /// Build the share URL from a returned secret_key. Validates that
    /// the key is non-empty and produces a parseable URL.
    public static func buildShareURL(secretKey: String) throws -> URL {
        guard let url = URL(string: shareURLPrefix + secretKey) else {
            throw ShareError.malformed("could not build share URL from key \(secretKey)")
        }
        return url
    }
}
