import Foundation

struct PublicIPInfo: Equatable {
    let ip: String
    let asn: String?
    let org: String?
    let country: String?
}

enum PublicIPError: LocalizedError {
    case requestFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .requestFailed(let msg): return msg
        case .invalidResponse: return "Invalid response from IP service"
        }
    }
}

enum PublicIP {
    static func fetch() async throws -> PublicIPInfo {
        // ipapi.co returns ip + ASN + org + country in one shot.
        guard let url = URL(string: "https://ipapi.co/json/") else {
            throw PublicIPError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("Cloud-Tunnel/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw PublicIPError.requestFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            let decoded = try JSONDecoder().decode(IPAPIResponse.self, from: data)
            return PublicIPInfo(
                ip: decoded.ip,
                asn: decoded.asn,
                org: decoded.org,
                country: decoded.country_name
            )
        } catch let e as PublicIPError {
            throw e
        } catch {
            throw PublicIPError.requestFailed(error.localizedDescription)
        }
    }

    private struct IPAPIResponse: Decodable {
        let ip: String
        let asn: String?
        let org: String?
        let country_name: String?
    }
}
