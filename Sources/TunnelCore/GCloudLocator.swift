import Foundation

public enum GCloudError: LocalizedError {
    case notFound

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "gcloud CLI not found. Install from https://cloud.google.com/sdk/docs/install"
        }
    }
}

public struct GCloudLocator {
    public static let searchPaths: [String] = [
        "/usr/local/bin/gcloud",
        "/opt/homebrew/bin/gcloud",
        (NSHomeDirectory() as NSString).appendingPathComponent("google-cloud-sdk/bin/gcloud"),
    ]

    public static func find() throws -> URL {
        if let url = try? whichGCloud() { return url }
        let fm = FileManager.default
        for path in searchPaths {
            if fm.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        throw GCloudError.notFound
    }

    private static func whichGCloud() throws -> URL {
        let proc = Process()
        proc.launchPath = "/usr/bin/which"
        proc.arguments = ["gcloud"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw GCloudError.notFound }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
            throw GCloudError.notFound
        }
        return URL(fileURLWithPath: path)
    }
}
