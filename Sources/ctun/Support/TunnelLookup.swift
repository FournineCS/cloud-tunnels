import Foundation
import TunnelCore

/// Resolve a tunnel by case-insensitive name match. Falls back to a
/// substring match when no exact name matches and the result is unique.
enum TunnelLookup {
    static func find(name: String, in tunnels: [Tunnel]) -> Tunnel? {
        let needle = name.trimmingCharacters(in: .whitespaces).lowercased()
        if let exact = tunnels.first(where: { $0.name.lowercased() == needle }) {
            return exact
        }
        let substring = tunnels.filter { $0.name.lowercased().contains(needle) }
        return substring.count == 1 ? substring.first : nil
    }

    static func errorMessage(name: String, tunnels: [Tunnel]) -> String {
        let needle = name.lowercased()
        let candidates = tunnels.filter { $0.name.lowercased().contains(needle) }
        if candidates.isEmpty {
            return "No tunnel matches '\(name)'. Run `ctun list` to see available tunnels."
        }
        let names = candidates.map { "  - \($0.name)" }.joined(separator: "\n")
        return "'\(name)' is ambiguous. Matches:\n\(names)"
    }
}
