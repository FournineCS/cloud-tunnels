import ArgumentParser
import Foundation
import TunnelCore

struct Ctun: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ctun",
        abstract: "Cloud-tunnel CLI — manage GCP IAP and AWS SSM tunnels from the terminal.",
        discussion: """
        Reads tunnel definitions from the menu-bar app's config at:
          ~/Library/Application Support/CloudTunnels/config.json

        Add or edit tunnels in the GUI app; invoke them from the shell with ctun.
        """,
        version: "0.1.0",
        subcommands: [
            ListCommand.self,
            StartCommand.self,
            StopCommand.self,
            StatusCommand.self,
            ConfigCommand.self,
            RunDetachedCommand.self,
        ]
    )
}

Ctun.main()
