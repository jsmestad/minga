/// Agent context bar for Board shell when zoomed into an agent card.
///
/// Shows the agent's task, status badge, elapsed time, and review actions.
/// Replaces the breadcrumb bar when zoomed into a non-You agent card.

import SwiftUI

struct AgentContextBar: View {
    let state: AgentContextBarState
    let theme: ThemeColors
    let encoder: InputEncoder?

    private let barHeight: CGFloat = 28

    /// Timer to refresh elapsed time every second.
    @State private var timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var elapsedDisplay: String = "0s"

    var body: some View {
        if state.visible {
            HStack(spacing: 12) {
                // Task description (left-aligned)
                Text(state.task)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.breadcrumbFg)
                    .lineLimit(1)
                    .truncationMode(.tail)

                // Status badge (inline)
                statusBadge

                Spacer()

                // Elapsed time (right-aligned, monospaced)
                Text(elapsedDisplay)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.breadcrumbFg.opacity(0.6))
                    .onReceive(timer) { _ in
                        updateElapsedDisplay()
                    }
                    .onAppear {
                        updateElapsedDisplay()
                    }

                // Action buttons (right-aligned)
                if state.canApprove {
                    actionButtons
                }
            }
            .padding(.horizontal, 12)
            .frame(height: barHeight)
            .background(theme.breadcrumbBg)
            .focusable(false)
            .focusEffectDisabled()

            // Bottom border
            Rectangle()
                .fill(theme.breadcrumbSeparatorFg.opacity(0.3))
                .frame(height: 1)
        }
    }

    // MARK: - Status Badge

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)

            Text(state.status.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(statusColor.opacity(0.15))
        .cornerRadius(4)
    }

    private var statusColor: Color {
        let c = state.status.color
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 6) {
            reviewButton(
                label: "Approve",
                systemIcon: "checkmark.circle.fill",
                color: Color(red: 0.2, green: 0.8, blue: 0.4),
                action: {
                    encoder?.sendAgentApprove()
                }
            )

            reviewButton(
                label: "Request Changes",
                systemIcon: "exclamationmark.triangle.fill",
                color: Color(red: 1.0, green: 0.75, blue: 0.2),
                action: {
                    encoder?.sendAgentRequestChanges()
                }
            )

            reviewButton(
                label: "Dismiss",
                systemIcon: "xmark.circle.fill",
                color: Color(red: 0.6, green: 0.3, blue: 0.3),
                action: {
                    encoder?.sendAgentDismiss()
                }
            )
        }
    }

    @ViewBuilder
    private func reviewButton(
        label: String,
        systemIcon: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemIcon)
                    .font(.system(size: 10, weight: .medium))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .help(label)
        .onHover { isHovered in
            if isHovered { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    // MARK: - Helpers

    private func updateElapsedDisplay() {
        let seconds = state.elapsedSeconds
        if seconds < 60 {
            elapsedDisplay = "\(seconds)s"
        } else if seconds < 3600 {
            elapsedDisplay = "\(seconds / 60)m"
        } else {
            elapsedDisplay = "\(seconds / 3600)h \((seconds % 3600) / 60)m"
        }
    }
}
