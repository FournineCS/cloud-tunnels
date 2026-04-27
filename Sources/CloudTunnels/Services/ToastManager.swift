import Foundation
import SwiftUI

/// Lightweight in-app toast for one-shot user feedback that doesn't
/// rely on macOS Notifications. We use this because the user may have
/// declined notification authorization (visible in the logs as
/// "notification auth error: Notifications are not allowed for this
/// application"), in which case `Notifications.post` is a silent
/// no-op and actions like "Activate kubectl context" leave the user
/// guessing whether anything happened.
///
/// The current toast is rendered as a thin banner inside the menu
/// bar popover (above the footer). Callers post a message and an
/// optional level; the banner auto-dismisses after `duration` seconds.
@MainActor
final class ToastManager: ObservableObject {

    enum Level {
        case info
        case success
        case warning
        case error

        var symbol: String {
            switch self {
            case .info: return "info.circle.fill"
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            }
        }

        var color: Color {
            switch self {
            case .info: return .accentColor
            case .success: return .green
            case .warning: return .orange
            case .error: return .red
            }
        }
    }

    struct Toast: Equatable {
        let id: UUID
        let title: String
        let body: String?
        let level: Level

        static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
    }

    @Published private(set) var current: Toast?

    private var dismissTask: Task<Void, Never>?

    /// Show a toast. If another toast is currently visible, replaces
    /// it (latest message wins — we don't queue, because users care
    /// about the freshest action they took, not history).
    func show(
        title: String,
        body: String? = nil,
        level: Level = .info,
        duration: TimeInterval = 4
    ) {
        let toast = Toast(id: UUID(), title: title, body: body, level: level)
        self.current = toast
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if self?.current?.id == toast.id {
                self?.current = nil
            }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        current = nil
    }
}

// MARK: - View

/// Renders the current toast as a thin banner. Tap to dismiss early.
struct ToastBanner: View {
    @ObservedObject var manager: ToastManager

    var body: some View {
        if let toast = manager.current {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: toast.level.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(toast.level.color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(toast.title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    if let body = toast.body, !body.isEmpty {
                        Text(body)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 6)
                Button {
                    manager.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(toast.level.color.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(toast.level.color.opacity(0.25), lineWidth: 0.5)
                    )
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeOut(duration: 0.18), value: toast.id)
        }
    }
}
