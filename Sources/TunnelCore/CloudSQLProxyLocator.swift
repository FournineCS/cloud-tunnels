import Foundation

public enum CloudSQLProxyError: LocalizedError {
    case notFound

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "cloud-sql-proxy CLI not found. Install from https://cloud.google.com/sql/docs/postgres/connect-auth-proxy#install"
        }
    }
}

public struct CloudSQLProxyLocator {
    public static let searchPaths: [String] = [
        "/usr/local/bin/cloud-sql-proxy",
        "/opt/homebrew/bin/cloud-sql-proxy",
        (NSHomeDirectory() as NSString).appendingPathComponent("bin/cloud-sql-proxy"),
        "/usr/local/google-cloud-sdk/bin/cloud-sql-proxy",
    ]

    public static func find() throws -> URL {
        if let url = try? whichProxy() { return url }
        let fm = FileManager.default
        for path in searchPaths {
            if fm.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        throw CloudSQLProxyError.notFound
    }

    private static func whichProxy() throws -> URL {
        let proc = Process()
        proc.launchPath = "/usr/bin/which"
        proc.arguments = ["cloud-sql-proxy"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw CloudSQLProxyError.notFound }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
            throw CloudSQLProxyError.notFound
        }
        return URL(fileURLWithPath: path)
    }
}
