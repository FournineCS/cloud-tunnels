import SwiftUI
import AppKit
import TunnelCore
import os

@MainActor
final class PresentationState: ObservableObject {
    @Published var editingTunnel: Tunnel? = nil
    @Published var defaultProvider: TunnelProvider = .gcpIAP
    /// Bumped on every Add/Edit open. Bound to `.id()` on the form view so
    /// SwiftUI tears down and re-creates the form (re-runs `init`, resetting
    /// all `@State`) instead of reusing the previous instance.
    @Published var editSessionID: UUID = UUID()

    /// Tracks whether the menu-bar popover is currently showing.
    /// Toggled by `MenuBarRoot.onAppear` / `.onDisappear`. Read by
    /// `CalendarManager`'s reminder-dispatch hook to decide between
    /// in-popover toast vs system notification routing.
    @Published var popoverIsVisible: Bool = false

    func beginEdit(tunnel: Tunnel?, provider: TunnelProvider) {
        editingTunnel = tunnel
        defaultProvider = tunnel?.provider.kind ?? provider
        editSessionID = UUID()
    }
}

@main
struct CloudTunnelsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var manager = TunnelManager()
    @StateObject private var auth = AuthManager()
    @StateObject private var awsAuth = AWSAuthManager()
    @StateObject private var presentation = PresentationState()
    @StateObject private var toasts = ToastManager()
    @StateObject private var calendar = CalendarManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarRoot()
                .environmentObject(manager)
                .environmentObject(auth)
                .environmentObject(awsAuth)
                .environmentObject(presentation)
                .environmentObject(toasts)
                .environmentObject(calendar)
        } label: {
            BrandImages.menuBarIcon
                .opacity(menuBarActive ? 1.0 : 0.55)
        }
        .menuBarExtraStyle(.window)

        Window("Tunnel", id: WindowID.addEdit) {
            AddEditWindowContent()
                .environmentObject(manager)
                .environmentObject(auth)
                .environmentObject(awsAuth)
                .environmentObject(presentation)
                .onAppear { activate() }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Preferences", id: WindowID.preferences) {
            PreferencesWindowContent()
                .environmentObject(manager)
                .onAppear { activate() }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Help", id: WindowID.help) {
            HelpWindowContent()
                .onAppear { activate() }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Logs", id: WindowID.logs) {
            LogsWindowContent()
                .onAppear { activate() }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

    /// Brighten the menu-bar mark when at least one tunnel is connected /
    /// connecting, dim it when fully idle. Errors keep the bright state so
    /// the badge dot drawn elsewhere stays the indicator-of-record for failure.
    private var menuBarActive: Bool {
        manager.statuses.values.contains { $0.isActive } ||
        manager.statuses.values.contains { if case .error = $0 { return true } else { return false } }
    }

    private func activate() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum WindowID {
    static let addEdit = "com.fourninecloud.cloud-tunnels.addEdit"
    static let preferences = "com.fourninecloud.cloud-tunnels.preferences"
    static let help = "com.fourninecloud.cloud-tunnels.help"
    static let logs = "com.fourninecloud.cloud-tunnels.logs"
}

// MARK: - MenuBar root

private struct MenuBarRoot: View {
    @EnvironmentObject var manager: TunnelManager
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var awsAuth: AWSAuthManager
    @EnvironmentObject var presentation: PresentationState
    @EnvironmentObject var toasts: ToastManager
    @EnvironmentObject var calendar: CalendarManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarView(
            manager: manager,
            auth: auth,
            awsAuth: awsAuth,
            onOpenAddEdit: { editing, provider in
                presentation.beginEdit(tunnel: editing, provider: provider)
                openWindow(id: WindowID.addEdit)
            },
            onOpenPreferences: { openWindow(id: WindowID.preferences) },
            onOpenHelp: { openWindow(id: WindowID.help) },
            onOpenLogs: { openWindow(id: WindowID.logs) },
            onAddGCPAccount: {
                Task { _ = await auth.login() }
            },
            onRevokeGCPAccount: { email in
                Task { _ = await auth.revoke(email: email) }
            },
            onAWSSsoLogin: { profile in
                Task {
                    let target = profile.isEmpty ? "default" : profile
                    _ = await awsAuth.ssoLogin(profile: target)
                }
            },
            onQuickAction: { tunnel in
                Task { await QuickAction.perform(for: tunnel, manager: manager) }
            },
            onActivateK8sContext: { tunnel in
                activateK8sContext(for: tunnel)
            },
            onQuit: { NSApp.terminate(nil) }
        )
        .task {
            if auth.accounts.isEmpty {
                await auth.refresh()
                auth.start(intervalMinutes: manager.preferences.authCheckIntervalMin)
            }
            // Sync the AWS auth manager's tracked-profiles set with the actual
            // tunnel list. Only profiles referenced by tunnels get probed.
            syncAWSTracked()
            if awsAuth.allProfileNames.isEmpty {
                await awsAuth.refresh()
                awsAuth.start(intervalMinutes: manager.preferences.authCheckIntervalMin)
            }
            // Calendar: request EventKit access once, then start the
            // polling loop. Idempotent — safe across popover re-opens.
            await calendar.requestAccessIfNeeded()
            // Route reminder firings through MeetingAlerter, which
            // decides toast-vs-notification based on popover state.
            let toastsRef = toasts
            let presentationRef = presentation
            calendar.onReminderDue = { event, minutesBefore in
                MeetingAlerter.fire(
                    event: event,
                    minutesBefore: minutesBefore,
                    popoverOpen: presentationRef.popoverIsVisible,
                    toasts: toastsRef
                )
            }
            calendar.start(with: manager.preferences.calendar)
        }
        .onChange(of: manager.tunnels) { _ in
            syncAWSTracked()
        }
        .onAppear {
            Notifications.requestAuthorization()
            manager.onAuthExpired = {
                Notifications.post(
                    title: "CloudTunnels",
                    body: "Authentication expired — click the menu bar icon to re-login"
                )
            }
            manager.connectAutoStart()
            presentation.popoverIsVisible = true
        }
        .onDisappear {
            presentation.popoverIsVisible = false
        }
    }

    /// Update the AWS auth manager's tracked-profiles set to match the AWS
    /// tunnels currently configured. Only profiles in this set get probed.
    private func syncAWSTracked() {
        var tracked: Set<String> = []
        for t in manager.tunnels {
            if case .awsSSM(let cfg) = t.provider, let profile = cfg.profile, !profile.isEmpty {
                tracked.insert(profile)
            }
        }
        awsAuth.setTrackedProfiles(tracked)
    }

    /// Switch the active kubectl context to the one bound to the SSH
    /// tunnel's kubeconfig patch cluster. Posts a notification with the
    /// outcome — switched / ambiguous / not-found / kubectl-missing /
    /// failed — so the user gets feedback regardless of how the call
    /// resolves. Runs `kubectl config use-context` on a background
    /// queue because Process+wait blocks the caller.
    private func activateK8sContext(for tunnel: Tunnel) {
        guard case .ssh(let cfg) = tunnel.provider,
              let patch = cfg.kubeconfigPatch else {
            return
        }
        let cluster = patch.clusterName
        let tunnelName = tunnel.name

        // Show an immediate "in progress" toast so the user gets
        // feedback the click registered, even before kubectl finishes.
        toasts.show(
            title: "Activating kubectl context…",
            body: "\(tunnelName) → \(cluster)",
            level: .info,
            duration: 60 // long fallback; overwritten by the result below
        )

        let toastsRef = toasts
        Task.detached(priority: .userInitiated) {
            let result = KubectlContext.switchToContextForCluster(cluster)
            await MainActor.run {
                switch result {
                case .switched(let ctx):
                    toastsRef.show(
                        title: "Switched kubectl context",
                        body: "Now using \(ctx)",
                        level: .success
                    )
                    // Also post a system notification — harmless if the
                    // user denied permission, useful if they didn't.
                    Notifications.post(
                        title: "Kubectl context switched",
                        body: "\(tunnelName): now using \(ctx)"
                    )
                case .ambiguous(let names):
                    toastsRef.show(
                        title: "Multiple contexts for this cluster",
                        body: "\(names.count) match: \(names.prefix(3).joined(separator: ", ")). Pick one manually with kubectl config use-context.",
                        level: .warning,
                        duration: 8
                    )
                case .notFound:
                    toastsRef.show(
                        title: "No kubectl context for this cluster",
                        body: "Cluster \(cluster) isn't referenced by any context.",
                        level: .warning,
                        duration: 6
                    )
                case .kubectlMissing:
                    toastsRef.show(
                        title: "kubectl not found",
                        body: "Install via `brew install kubernetes-cli`.",
                        level: .error,
                        duration: 8
                    )
                case .failed(let msg):
                    toastsRef.show(
                        title: "Kubectl context switch failed",
                        body: msg,
                        level: .error,
                        duration: 8
                    )
                }
            }
        }
    }
}

// MARK: - AddEdit window content

private struct AddEditWindowContent: View {
    @EnvironmentObject var manager: TunnelManager
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var awsAuth: AWSAuthManager
    @EnvironmentObject var presentation: PresentationState

    var body: some View {
        AddEditTunnelView(
            manager: manager,
            auth: auth,
            awsAuth: awsAuth,
            editing: presentation.editingTunnel,
            defaultProvider: presentation.defaultProvider,
            onClose: {
                closeWindow(id: WindowID.addEdit)
                maybeReturnToAccessory()
            }
        )
        .id(presentation.editSessionID)
        .onDisappear { maybeReturnToAccessory() }
    }
}

// MARK: - Help window content

private struct HelpWindowContent: View {
    var body: some View {
        HelpView(
            onClose: {
                closeWindow(id: WindowID.help)
                maybeReturnToAccessory()
            }
        )
        .onDisappear { maybeReturnToAccessory() }
    }
}

// MARK: - Preferences window content

private struct PreferencesWindowContent: View {
    @EnvironmentObject var manager: TunnelManager

    var body: some View {
        PreferencesView(
            manager: manager,
            onClose: {
                closeWindow(id: WindowID.preferences)
                maybeReturnToAccessory()
            }
        )
        .onDisappear { maybeReturnToAccessory() }
    }
}

/// macOS 13-compatible window close. Matches the SwiftUI Scene identifier
/// that was set via `Window(_, id:)`, which becomes the NSWindow's identifier.
@MainActor
fileprivate func closeWindow(id: String) {
    for window in NSApp.windows where window.identifier?.rawValue == id {
        window.close()
    }
}

/// Return the app to `.accessory` (menu-bar-only) activation once no
/// content windows are visible. Called after any window closes.
@MainActor
fileprivate func maybeReturnToAccessory() {
    // Defer to the next runloop so any closing window has finished ordering out.
    DispatchQueue.main.async {
        let hasContentWindow = NSApp.windows.contains { window in
            guard window.isVisible else { return false }
            let cls = String(describing: type(of: window))
            // Ignore menubar extras and status bar windows
            if cls.contains("StatusBar") || cls.contains("MenuBarExtra") || cls.contains("Popover") {
                return false
            }
            return window.contentViewController != nil
        }
        if !hasContentWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        Logger.app.info("app terminating")
    }
}
