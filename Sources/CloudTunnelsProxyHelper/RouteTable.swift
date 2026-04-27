import Foundation
import ProxyHelperShared

/// In-memory map of `hostname → ProxyRoute` driven by XPC `addRoute` /
/// `removeRoute` calls. Source of truth for the Caddy config — when
/// it changes, `CaddyManager` regenerates and reloads.
///
/// Side effect of `upsert`: ensures the per-hostname leaf cert+key
/// files exist on disk under `LocalCA`'s leaves directory. Caddy reads
/// those file paths via its `apps.tls.certificates.load_files` config
/// (see `CaddyfileBuilder`), so they must be written before Caddy
/// reloads its config.
public actor RouteTable {

    private let ca: LocalCA
    private var entries: [String: ProxyRoute] = [:]

    public init(ca: LocalCA) {
        self.ca = ca
    }

    // MARK: - Mutations (called from XPC handlers)

    /// Adds or replaces a route. Issues (or refreshes) the leaf cert
    /// for the hostname so Caddy's load_files can pick it up. Throws
    /// if the cert generation fails — caller should surface this so
    /// the GUI can show a meaningful error.
    public func upsert(_ route: ProxyRoute) async throws {
        _ = try await ca.issueLeaf(for: route.hostname)
        entries[route.hostname.lowercased()] = route
    }

    /// Removes a route by hostname. The cert files on disk are not
    /// deleted — they're harmless and reuseable if the same route
    /// is re-added later.
    public func remove(hostname: String) {
        entries.removeValue(forKey: hostname.lowercased())
    }

    public func removeAll() {
        entries.removeAll()
    }

    // MARK: - Reads (consumed by CaddyManager / XPC status)

    public func snapshot() -> [ProxyRoute] {
        // Stable order so the generated Caddy JSON is deterministic
        // (helps both with unit tests and with avoiding spurious
        // diffs in the on-disk caddy.json).
        entries.keys.sorted().compactMap { entries[$0] }
    }

    public var isEmpty: Bool {
        entries.isEmpty
    }
}
