/// Agent context bar for the active agent surface.
///
/// Shows the agent's task, status badge, elapsed time, and review actions.
/// Replaces the breadcrumb bar when zoomed into a non-You agent card.

import SwiftUI
import MingaProtocol

public struct AgentContextBar: View {
    public enum ReviewAction: Equatable, Sendable {
        case approve
        case requestChanges
        case dismiss
    }

    public init(state: AgentContextBarState, onReview: @escaping @MainActor @Sendable (ReviewAction) -> Void) {
        self.state = state
        self.onReview = onReview
    }
    public let state: AgentContextBarState
    @Environment(\.themeColors) private var theme

    public let onReview: @MainActor @Sendable (ReviewAction) -> Void

    private let barHeight: CGFloat = 28

    /// Timer to refresh elapsed time every second.
    @State private var timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var elapsedDisplay: String = "0s"

    public var body: some View {
        if state.visible {
            HStack(spacing: Spacing.lg) {
                // Task description (left-aligned)
                Text(state.task)
                    .font(Typography.font(.body))
                    .foregroundStyle(theme.breadcrumbFg)
                    .lineLimit(1)
                    .truncationMode(.tail)

                statusBadge

                if !state.progress.activeAction.isEmpty {
                    Text(state.progress.activeAction)
                        .font(Typography.font(.small))
                        .foregroundStyle(theme.breadcrumbFg.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if state.progress.toolCount > 0 || state.progress.fileCount > 0 {
                    Text("\(state.progress.toolCount) tools / \(state.progress.fileCount) files")
                        .font(Typography.font(.small, design: .monospaced))
                        .foregroundStyle(theme.breadcrumbFg.opacity(0.6))
                        .lineLimit(1)
                }

                if let activeTodo = state.todos.first(where: { $0.status == 1 }) ?? state.todos.first {
                    Text(todoLabel(activeTodo))
                        .font(Typography.font(.small))
                        .foregroundStyle(theme.breadcrumbFg.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                // Elapsed time (right-aligned, monospaced)
                Text(elapsedDisplay)
                    .font(Typography.font(.small, design: .monospaced))
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
            .padding(.horizontal, Spacing.lg)
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
        HStack(spacing: Spacing.xs) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)

            Text(state.status.label)
                .font(Typography.font(.small, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
        .background(statusColor.opacity(0.15))
        .clipShape(.rect(cornerRadius: Radius.sm))
    }

    private var statusColor: Color {
        let c = state.status.color
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: Spacing.sm) {
            reviewButton(
                label: "Approve",
                systemIcon: "checkmark.circle.fill",
                color: Color(red: 0.2, green: 0.8, blue: 0.4),
                action: {
                    onReview(.approve)
                }
            )

            reviewButton(
                label: "Reject Changes",
                systemIcon: "exclamationmark.triangle.fill",
                color: Color(red: 1.0, green: 0.75, blue: 0.2),
                action: {
                    onReview(.requestChanges)
                }
            )

            reviewButton(
                label: "Dismiss",
                systemIcon: "xmark.circle.fill",
                color: Color(red: 0.6, green: 0.3, blue: 0.3),
                action: {
                    onReview(.dismiss)
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
            HStack(spacing: Spacing.xs) {
                Image(systemName: systemIcon)
                    .font(Typography.font(.caption, weight: .medium))
                Text(label)
                    .font(Typography.font(.small, weight: .medium))
            }
            .foregroundStyle(color)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
            .background(color.opacity(0.15))
            .clipShape(.rect(cornerRadius: Radius.sm))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
        .pointingHandCursor()
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

    private func todoLabel(_ todo: Wire.AgentTodo) -> String {
        switch todo.status {
        case 1:
            return "Now: \(todo.description)"
        case 2:
            return "Done: \(todo.description)"
        default:
            return "Next: \(todo.description)"
        }
    }
}
