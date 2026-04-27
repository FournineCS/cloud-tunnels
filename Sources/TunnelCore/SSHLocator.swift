import Foundation

public enum SSHError: LocalizedError {
    case notFound

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "ssh CLI not found. Expected at /usr/bin/ssh on macOS."
        }
    }
}

public struct SSHLocator {
    public static let searchPaths: [String] = [
        "/usr/bin/ssh",
        "/usr/local/bin/ssh",
        "/opt/homebrew/bin/ssh",
    ]

    public static func find() throws -> URL {
        let fm = FileManager.default
        for path in searchPaths {
            if fm.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        if let url = try? whichSSH() { return url }
        throw SSHError.notFound
    }

    private static func whichSSH() throws -> URL {
        let proc = Process()
        proc.launchPath = "/usr/bin/which"
        proc.arguments = ["ssh"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw SSHError.notFound }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
            throw SSHError.notFound
        }
        return URL(fileURLWithPath: path)
    }
}
