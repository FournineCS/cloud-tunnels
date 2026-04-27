import ArgumentParser
import Foundation
import TunnelCore

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Inspect the shared config file used by ctun and the menu-bar app.",
        subcommands: [PathSub.self, ShowSub.self],
        defaultSubcommand: PathSub.self
    )

    struct PathSub: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "path",
            abstract: "Print the absolute path of config.json."
        )

        func run() throws {
            Output.out(ConfigStore.shared.configFileURL.path)
        }
    }

    struct ShowSub: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Pretty-print the contents of config.json."
        )

        func run() throws {
            let url = ConfigStore.shared.configFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                Output.err("No config file at \(url.path)")
                throw ExitCode(3)
            }
            let data = try Data(contentsOf: url)
            if let s = String(data: data, encoding: .utf8) {
                Output.out(s)
            }
        }
    }
}
