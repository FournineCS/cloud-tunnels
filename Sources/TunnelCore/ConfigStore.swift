import Foundation
import os

public final class ConfigStore {
    public static let shared = ConfigStore()

    private let fm = FileManager.default
    private let log = Logger(subsystem: "com.fourninecloud.cloud-tunnels", category: "config")

    public let configDirectoryURL: URL
    public let configFileURL: URL
    /// Ordered list of legacy config locations checked on first launch when
    /// the new config file doesn't exist yet. First hit wins.
    public let legacyConfigURLs: [URL]

    public init(
        configDirectoryURL: URL? = nil,
        legacyConfigURLs: [URL]? = nil
    ) {
        let appSupportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appSupport = configDirectoryURL
            ?? appSupportRoot.appendingPathComponent("CloudTunnels", isDirectory: true)
        self.configDirectoryURL = appSupport
        self.configFileURL = appSupport.appendingPathComponent("config.json")
        self.legacyConfigURLs = legacyConfigURLs ?? [
            // Previous Application Support location (pre-rename).
            appSupportRoot.appendingPathComponent("GCPIAPTunnel/config.json"),
            // Original dotfile location from the Python predecessor.
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gcp-iap-tunnels/config.json"),
        ]
    }

    public func load() -> AppConfig {
        ensureDirectory()
        migrateIfNeeded()
        guard fm.fileExists(atPath: configFileURL.path) else {
            let fresh = AppConfig.default
            (try? save(fresh)) ?? ()
            return fresh
        }
        do {
            let data = try Data(contentsOf: configFileURL)
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            log.error("config load failed, using default: \(error.localizedDescription, privacy: .public)")
            return .default
        }
    }

    public func save(_ config: AppConfig) throws {
        ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)

        let tmp = configDirectoryURL.appendingPathComponent("config.json.tmp")
        try data.write(to: tmp, options: [.atomic])
        _ = try fm.replaceItemAt(configFileURL, withItemAt: tmp)
    }

    private func ensureDirectory() {
        if !fm.fileExists(atPath: configDirectoryURL.path) {
            try? fm.createDirectory(at: configDirectoryURL, withIntermediateDirectories: true)
        }
    }

    private func migrateIfNeeded() {
        guard !fm.fileExists(atPath: configFileURL.path) else { return }
        for legacy in legacyConfigURLs where fm.fileExists(atPath: legacy.path) {
            do {
                let data = try Data(contentsOf: legacy)
                try data.write(to: configFileURL, options: [.atomic])
                log.info("migrated legacy config from \(legacy.path, privacy: .public)")
                return
            } catch {
                log.error("legacy migration from \(legacy.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
