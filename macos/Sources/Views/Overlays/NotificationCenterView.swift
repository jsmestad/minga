/// Bottom-right notification stack rendered with native SwiftUI chrome.

import SwiftUI
import MingaProtocol

/// Renders editor notifications owned by the BEAM.
public struct NotificationCenterView: View {
    public init(state: NotificationCenterState, encoder: InputEncoder? = nil, bottomInset: CGFloat) {
        self.state = state
        self.encoder = encoder
        self.bottomInset = bottomInset
    }
    public let state: NotificationCenterState
    @Environment(\.themeColors) private var theme

    public let encoder: InputEncoder?
    public let bottomInset: CGFloat

    public var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            ForEach(state.notifications) { notification in
                NotificationCard(notification: notification, encoder: encoder)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 18)
        .padding(.bottom, bottomInset)
        .allowsHitTesting(!state.notifications.isEmpty)
        .animation(.easeOut(duration: 0.16), value: state.notifications)
    }
}

private struct NotificationCard: View {
    let notification: EditorNotification
    @Environment(\.themeColors) private var theme
    let encoder: InputEncoder?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                severityIcon
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(notification.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.popupFg)
                            .lineLimit(2)

                        Spacer(minLength: 8)

                        if notification.dismissable {
                            Button {
                                encoder?.sendNotificationDismiss(id: notification.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(theme.popupMutedFg)
                            .help("Dismiss notification")
                        }
                    }

                    metadataRow
                }
            }

            if !notification.body.isEmpty {
                Text(notification.body)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.popupSecondaryFg)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !notification.actions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(notification.actions) { action in
                        Button(action.label) {
                            encoder?.sendNotificationAction(id: notification.id, actionId: action.id)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(theme.accent)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 360, alignment: .leading)
        .background(theme.popupBg, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(notificationBorderColor, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.32), radius: 16, x: 0, y: 8)
    }

    private var severityIcon: some View {
        Group {
            if notification.level == .progress {
                ProgressView()
                    .controlSize(.small)
                    .tint(severityColor)
            } else {
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(severityColor)
            }
        }
    }

    private var metadataRow: some View {
        HStack(spacing: 6) {
            Text(notification.levelName.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(severityColor)

            if !notification.source.isEmpty {
                Text(notification.source)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.popupMutedFg)
            }

            Text(notification.updatedAt, style: .relative)
                .font(.system(size: 10))
                .foregroundStyle(theme.popupDisabledFg)
        }
    }

    private var notificationBorderColor: Color {
        severityColor.opacity(0.58)
    }

    private var severityColor: Color {
        switch notification.level {
        case .warning: return theme.gutterWarningFg
        case .error: return theme.gutterErrorFg
        case .success: return theme.gitAddedFg
        case .progress: return theme.accent
        case .info, .unknown(_): return theme.gutterInfoFg
        }
    }

    private var iconName: String {
        switch notification.level {
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .success: return "checkmark.circle.fill"
        case .info, .progress, .unknown(_): return "info.circle.fill"
        }
    }
}

#Preview("Notification") {
    let theme = PreviewFixtures.theme()
    let state = NotificationCenterState()
    let now = UInt64(Date().timeIntervalSince1970)
    state.update(rawNotifications: [
        Wire.EditorNotification(
            id: "notif-1",
            level: .info,
            flags: 0x01,
            createdAt: now,
            updatedAt: now,
            autoDismissMs: nil,
            title: "Extension loaded",
            body: "org-mode v0.3.0 activated for .org files",
            source: "Extensions",
            actions: [
                Wire.NotificationAction(id: "configure", label: "Configure"),
            ]
        ),
    ])
    return NotificationCenterView(state: state, encoder: nil, bottomInset: 40)
        .frame(width: 800, height: 600)
        .background(theme.editorBg)
        .environment(theme)
}

#Preview("Notification Stack") {
    let theme = PreviewFixtures.theme()
    let state = NotificationCenterState()
    let now = UInt64(Date().timeIntervalSince1970)
    state.update(rawNotifications: [
        Wire.EditorNotification(
            id: "notif-error",
            level: .error,
            flags: 0x01,
            createdAt: now - 120,
            updatedAt: now - 120,
            autoDismissMs: nil,
            title: "Build failed",
            body: "Compilation error in lib/minga/editor.ex:42",
            source: "Compiler",
            actions: [
                Wire.NotificationAction(id: "show", label: "Show Error"),
            ]
        ),
        Wire.EditorNotification(
            id: "notif-warning",
            level: .warning,
            flags: 0x01,
            createdAt: now - 60,
            updatedAt: now - 60,
            autoDismissMs: nil,
            title: "Deprecation warning",
            body: "Minga.Buffer.read/1 is deprecated.",
            source: "Compiler",
            actions: []
        ),
        Wire.EditorNotification(
            id: "notif-success",
            level: .success,
            flags: 0x01,
            createdAt: now,
            updatedAt: now,
            autoDismissMs: 5000,
            title: "Tests passed",
            body: "42 tests, 0 failures",
            source: "ExUnit",
            actions: []
        ),
    ])
    return NotificationCenterView(state: state, encoder: nil, bottomInset: 40)
        .frame(width: 800, height: 600)
        .background(theme.editorBg)
        .environment(theme)
}
