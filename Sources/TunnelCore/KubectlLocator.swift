import Foundation

public enum KubectlError: LocalizedError {
    case notFound

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "kubectl CLI not found. Install from https://kubernetes.io/docs/tasks/tools/#kubectl"
        }
    }
}

public struct KubectlLocator {
    public static let searchPaths: [String] = [
        "/usr/local/bin/kubectl",
        "/opt/homebrew/bin/kubectl",
        (NSHomeDirectory() as NSString).appendingPathComponent("bin/kubectl"),
        "/usr/bin/kubectl",
    ]

    public static func find() throws -> URL {
        if let url = try? whichKubectl() { return url }
        let fm = FileManager.default
        for path in searchPaths {
            if fm.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        throw KubectlError.notFound
    }

    private static func whichKubectl() throws -> URL {
        let proc = Process()
        proc.launchPath = "/usr/bin/which"
        proc.arguments = ["kubectl"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw KubectlError.notFound }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
            throw KubectlError.notFound
        }
        return URL(fileURLWithPath: path)
    }
}
