import Foundation

public enum TerminalApp: String, Codable, CaseIterable, Hashable, Sendable {
    case terminal      // Terminal.app
    case iterm2        // iTerm2
    case ghostty       // Ghostty

    public var displayName: String {
        switch self {
        case .terminal: return "Terminal"
        case .iterm2: return "iTerm2"
        case .ghostty: return "Ghostty"
        }
    }
}

public enum HTTPClient: String, Codable, CaseIterable, Hashable, Sendable {
    case systemBrowser  // default browser
    case bruno          // Bruno API client

    public var displayName: String {
        switch self {
        case .systemBrowser: return "System browser"
        case .bruno: return "Bruno"
        }
    }
}

public struct Preferences: Codable, Equatable, Sendable {
    public var autoReconnect: Bool
    public var authCheckIntervalMin: Int
    public var terminalApp: TerminalApp
    public var httpClient: HTTPClient
    public var calendar: CalendarPreferences

    public static let `default` = Preferences(
        autoReconnect: true,
        authCheckIntervalMin: 30,
        terminalApp: .terminal,
        httpClient: .systemBrowser,
        calendar: .default
    )

    enum CodingKeys: String, CodingKey {
        case autoReconnect = "auto_reconnect"
        case authCheckIntervalMin = "auth_check_interval_min"
        case terminalApp = "terminal_app"
        case httpClient = "http_client"
        case calendar
    }

    public init(
        autoReconnect: Bool,
        authCheckIntervalMin: Int,
        terminalApp: TerminalApp = .terminal,
        httpClient: HTTPClient = .systemBrowser,
        calendar: CalendarPreferences = .default
    ) {
        self.autoReconnect = autoReconnect
        self.authCheckIntervalMin = authCheckIntervalMin
        self.terminalApp = terminalApp
        self.httpClient = httpClient
        self.calendar = calendar
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.autoReconnect = (try? c.decode(Bool.self, forKey: .autoReconnect)) ?? true
        self.authCheckIntervalMin = (try? c.decode(Int.self, forKey: .authCheckIntervalMin)) ?? 30
        self.terminalApp = (try? c.decode(TerminalApp.self, forKey: .terminalApp)) ?? .terminal
        self.httpClient = (try? c.decode(HTTPClient.self, forKey: .httpClient)) ?? .systemBrowser
        self.calendar = (try? c.decode(CalendarPreferences.self, forKey: .calendar)) ?? .default
    }
}

public struct AppConfig: Codable, Equatable, Sendable {
    public var tunnels: [Tunnel]
    public var preferences: Preferences

    public static let `default` = AppConfig(tunnels: [], preferences: .default)

    enum CodingKeys: String, CodingKey {
        case tunnels
        case preferences
    }

    public init(tunnels: [Tunnel], preferences: Preferences) {
        self.tunnels = tunnels
        self.preferences = preferences
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.tunnels = (try? c.decode([Tunnel].self, forKey: .tunnels)) ?? []
        self.preferences = (try? c.decode(Preferences.self, forKey: .preferences)) ?? .default
    }
}
