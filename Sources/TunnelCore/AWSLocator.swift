import Foundation

public enum AWSError: LocalizedError {
    case awsNotFound
    case sessionManagerPluginNotFound

    public var errorDescription: String? {
        switch self {
        case .awsNotFound:
            return "AWS CLI not found. Install from https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
        case .sessionManagerPluginNotFound:
            return "session-manager-plugin not found. Install from https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"
        }
    }
}

public struct AWSLocator {
    public static let awsSearchPaths: [String] = [
        "/usr/local/bin/aws",
        "/opt/homebrew/bin/aws",
        "/usr/bin/aws",
    ]

    public static let pluginSearchPaths: [String] = [
        "/usr/local/bin/session-manager-plugin",
        "/opt/homebrew/bin/session-manager-plugin",
        "/usr/local/sessionmanagerplugin/bin/session-manager-plugin",
    ]

    public static func findAWS() throws -> URL {
        if let url = try? which("aws") { return url }
        let fm = FileManager.default
        for path in awsSearchPaths where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw AWSError.awsNotFound
    }

    /// Verifies session-manager-plugin is available. AWS CLI needs it to run
    /// SSM sessions, and its absence causes cryptic errors.
    public static func checkSessionManagerPlugin() throws {
        if (try? which("session-manager-plugin")) != nil { return }
        let fm = FileManager.default
        for path in pluginSearchPaths where fm.isExecutableFile(atPath: path) {
            return
        }
        throw AWSError.sessionManagerPluginNotFound
    }

    private static func which(_ name: String) throws -> URL {
        let proc = Process()
        proc.launchPath = "/usr/bin/which"
        proc.arguments = [name]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw AWSError.awsNotFound }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
            throw AWSError.awsNotFound
        }
        return URL(fileURLWithPath: path)
    }
}
