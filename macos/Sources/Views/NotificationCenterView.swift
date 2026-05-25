/// Bottom-right notification stack rendered with native SwiftUI chrome.

import SwiftUI

/// Renders editor notifications owned by the BEAM.
struct NotificationCenterView: View {
    let state: NotificationCenterState
    let theme: ThemeColors
    let encoder: InputEncoder?
    let bottomInset: CGFloat

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            ForEach(state.notifications) { notification in
                NotificationCard(notification: notification, theme: theme, encoder: encoder)
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
    let theme: ThemeColors
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
