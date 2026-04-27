import Foundation

public enum TunnelStatus: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(since: Date)
    case error(String)

    public var isActive: Bool {
        switch self {
        case .connecting, .connected: return true
        case .disconnected, .error: return false
        }
    }

    public var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    public var symbolName: String {
        switch self {
        case .disconnected: return "circle"
        case .connecting: return "circle.dotted"
        case .connected: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}
