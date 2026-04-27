import Foundation

/// System-wide IPC between the menu-bar app and the `ctun` CLI.
///
/// Uses `DistributedNotificationCenter` so neither side needs an XPC service,
/// app group, or sandbox entitlement. The CLI posts a stop request; if a
/// running GUI instance manages the same tunnel, it disconnects cleanly
/// (suppressing auto-reconnect) instead of being fought over by both processes.
public enum IPCNotifications {
    public static let stopRequestName = Notification.Name("com.fourninecloud.cloud-tunnels.stop-request")

    /// Posts a system-wide notification asking any running CloudTunnels.app
    /// instance to disconnect the given tunnel cleanly. No-op if no app is
    /// listening — safe to call unconditionally.
    public static func postStopRequest(tunnelID: UUID) {
        DistributedNotificationCenter.default().postNotificationName(
            stopRequestName,
            object: tunnelID.uuidString,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    /// Subscribes to stop requests. Handler receives the tunnel UUID and runs
    /// on the supplied queue (default: main). Returns the observer token —
    /// pass to `DistributedNotificationCenter.default().removeObserver(_:)`
    /// to unsubscribe.
    @discardableResult
    public static func observeStopRequest(
        on queue: OperationQueue = .main,
        handler: @escaping @Sendable (UUID) -> Void
    ) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: stopRequestName,
            object: nil,
            queue: queue
        ) { notification in
            guard let str = notification.object as? String,
                  let id = UUID(uuidString: str) else { return }
            handler(id)
        }
    }
}
