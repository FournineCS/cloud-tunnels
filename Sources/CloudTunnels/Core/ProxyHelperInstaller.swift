import Foundation
import os
import ServiceManagement

/// Wraps `SMAppService.daemon(plistName:)` for the privileged proxy helper.
/// Lives entirely in the GUI process — the helper itself never touches
/// SMAppService, only launchd via the embedded plist.
///
/// The plist file at `Contents/Library/LaunchDaemons/<name>.plist` inside
/// the .app bundle is what SMAppService registers with launchd. The first
/// `register()` call triggers the macOS authorization dialog that takes
/// the user to System Settings → Login Items where they toggle the helper
/// on. We poll `status` from the UI to drive the install banner.
@MainActor
public final class ProxyHelperInstaller: ObservableObject {

    public static let plistName = "com.fourninecloud.cloud-tunnels.proxy-helper.plist"

    public enum InstallStatus: Equatable {
        /// SMAppService has never seen this daemon (not yet installed).
        case notRegistered
        /// Daemon is registered and launchd has it loaded — ready to talk.
        case enabled
        /// User must approve in System Settings → Login Items.
        case requiresApproval
        /// The bundle's launchd plist could not be located on disk. Usually
        /// means the .app wasn't built with the helper bundling step.
        case notFound

        public var isEnabled: Bool { self == .enabled }
    }

    @Published public private(set) var status: InstallStatus = .notRegistered

    private let log = Logger(
        subsystem: "com.fourninecloud.cloud-tunnels",
        category: "ProxyHelperInstaller"
    )

    private var service: SMAppService {
        SMAppService.daemon(plistName: Self.plistName)
    }

    public init() {
        refreshStatus()
    }

    // MARK: - Public API

    /// Asks SMAppService to register the daemon. On first call this opens
    /// the System Settings approval dialog; subsequent calls are no-ops if
    /// the daemon is already enabled. After this returns, the user may
    /// still need to toggle the daemon on in System Settings — call
    /// `refreshStatus()` to observe when they do.
    public func register() throws {
        log.info("Registering proxy helper daemon")
        try service.register()
        refreshStatus()
    }

    /// Removes the daemon from launchd. Used by the Reset action and
    /// `make uninstall-helper`. Best-effort: errors are logged but not
    /// thrown so the rest of the cleanup pipeline can still run.
    public func unregister() {
        do {
            try service.unregister()
            log.info("Proxy helper daemon unregistered")
        } catch {
            log.error("Unregister failed: \(error.localizedDescription, privacy: .public)")
        }
        refreshStatus()
    }

    /// Re-queries SMAppService for the current daemon status and republishes
    /// it. Cheap; safe to call from `.onAppear` / a periodic timer.
    public func refreshStatus() {
        let next: InstallStatus
        switch service.status {
        case .notRegistered:
            next = .notRegistered
        case .enabled:
            next = .enabled
        case .requiresApproval:
            next = .requiresApproval
        case .notFound:
            next = .notFound
        @unknown default:
            next = .notRegistered
        }
        if next != status {
            log.info("Helper status changed: \(String(describing: self.status), privacy: .public) → \(String(describing: next), privacy: .public)")
            status = next
        }
    }

    /// Opens System Settings to the Login Items pane so the user can flip
    /// the helper toggle without hunting for it.
    public func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
