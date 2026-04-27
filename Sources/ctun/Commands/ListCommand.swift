import ArgumentParser
import Foundation
import TunnelCore

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all configured tunnels."
    )

    @Flag(name: [.short, .long], help: "Filter by provider.")
    var gcp: Bool = false

    @Flag(name: [.short, .long], help: "Filter by AWS SSM provider.")
    var aws: Bool = false

    @Flag(name: .long, help: "Output as JSON.")
    var json: Bool = false

    func run() throws {
        let config = ConfigStore.shared.load()
        var tunnels = config.tunnels
        if gcp { tunnels = tunnels.filter { $0.provider.kind == .gcpIAP } }
        if aws { tunnels = tunnels.filter { $0.provider.kind == .awsSSM } }
        tunnels.sort { $0.name.lowercased() < $1.name.lowercased() }

        if tunnels.isEmpty {
            Output.err("No tunnels configured. Open the CloudTunnels menu-bar app to add one.")
            return
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(tunnels)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            return
        }

        let nameW = max(4, (tunnels.map(\.name.count).max() ?? 4) + 2)
        let kindW = 6
        let portW = 7
        Output.out(
            Output.pad("NAME", nameW)
            + Output.pad("KIND", kindW)
            + Output.pad("PORT", portW)
            + "TARGET"
        )
        for t in tunnels {
            Output.out(
                Output.pad(t.name, nameW)
                + Output.pad(t.provider.kind.shortTag, kindW)
                + Output.pad(String(t.localPort), portW)
                + t.provider.targetDescription
            )
        }
    }
}
