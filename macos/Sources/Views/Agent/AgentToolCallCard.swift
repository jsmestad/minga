import SwiftUI
import MingaProtocol

public struct AgentToolCallCard: View {
    public enum Action: Equatable, Sendable {
        case toggle(messageID: UInt32)
    }

    public init(messageID: Int, name: String, summary: String, status: UInt8, isError: Bool, collapsed: Bool, autoApprovedScope: UInt8, durationMs: UInt32, result: String? = nil, resultLines: [[Wire.StyledTextRun]]? = nil, previewLines: [String], sendAction: ViewActionHandler<Action>?, styledLineView: @escaping ([Wire.StyledTextRun], CGFloat, Bool) -> AnyView) {
        self.messageID = messageID
        self.name = name
        self.summary = summary
        self.status = status
        self.isError = isError
        self.collapsed = collapsed
        self.autoApprovedScope = autoApprovedScope
        self.durationMs = durationMs
        self.result = result
        self.resultLines = resultLines
        self.previewLines = previewLines
        self.sendAction = sendAction
        self.styledLineView = styledLineView
    }
    public let messageID: Int
    public let name: String
    public let summary: String
    public let status: UInt8
    public let isError: Bool
    public let collapsed: Bool
    public let autoApprovedScope: UInt8
    public let durationMs: UInt32
    public let result: String?
    public let resultLines: [[Wire.StyledTextRun]]?
    public let previewLines: [String]
    @Environment(\.themeColors) private var theme
    public let sendAction: ViewActionHandler<Action>?
    /// Closure to render a styled line, provided by the parent since it's shared
    /// with assistant message rendering.
    public let styledLineView: ([Wire.StyledTextRun], CGFloat, Bool) -> AnyView

    private var outcome: ToolCallStatus { ToolCallStatus(rawValue: status) }

    private var statusLabel: String {
        switch outcome {
        case .running: "running"
        case .complete: "done"
        case .error: "error"
        case .denied: "Denied"
        case .cancelled: "Cancelled"
        case .approvalExpired: "Expired"
        case .unknown: isError ? "error" : "unknown"
        }
    }

    private var statusColor: Color {
        switch outcome {
        case .running, .denied, .approvalExpired: .orange
        case .complete: .green
        case .error: .red
        case .cancelled: theme.agentMutedFg
        case .unknown: isError ? .red : theme.agentToolHeader
        }
    }

    public var body: some View {
        let hasResult = result?.isEmpty == false || resultLines?.isEmpty == false
        let visiblePreviewLines = Array(previewLines.prefix(8))

        VStack(alignment: .leading, spacing: 0) {
            // Header (clickable to toggle collapse)
            HStack(spacing: Spacing.sm) {
                // Collapse/expand chevron (only shown when there's result content)
                if hasResult {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(Typography.font(.micro, weight: .medium))
                        .foregroundStyle(theme.agentTextFg.opacity(0.4))
                }

                // Running spinner or status icon
                if outcome == .running {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.6)
                } else {
                    Image(systemName: toolIcon)
                        .font(Typography.font(.caption))
                        .foregroundStyle(statusColor.opacity(0.8))
                }

                Text(name)
                    .font(Typography.font(.body, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.agentTextFg)
                    .layoutPriority(1)

                // Tool summary (command, path, etc.)
                if !summary.isEmpty {
                    toolCallSummaryView(name: name, summary: summary)
                }

                Spacer(minLength: 8)

                if durationMs > 0 && outcome != .denied && outcome != .approvalExpired {
                    Text(formatDuration(durationMs))
                        .font(Typography.font(.caption))
                        .foregroundStyle(theme.agentTextFg.opacity(0.3))
                }

                statusBadge

                if let autoApprovedLabel = autoApprovedScopeLabel(autoApprovedScope) {
                    autoApprovedPill(label: autoApprovedLabel)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(name): \(statusLabel). \(summary)")
            .onTapGesture {
                if hasResult, let messageID = UInt32(exactly: messageID), messageID != 0 {
                    sendAction?(.toggle(messageID: messageID))
                }
            }

            if !visiblePreviewLines.isEmpty {
                Rectangle()
                    .fill(theme.agentToolBorder.opacity(0.2))
                    .frame(height: 1)

                previewLinesView(visiblePreviewLines)
                    .padding(.horizontal, Spacing.md)
                    .padding(.bottom, Spacing.md)
            }

            // Result (collapsed by default, supports styled or plain text)
            if !collapsed && hasResult {
                Rectangle()
                    .fill(theme.agentToolBorder.opacity(0.2))
                    .frame(height: 1)

                ScrollView([.horizontal, .vertical]) {
                    if let lines = resultLines, !lines.isEmpty {
                        // Styled result with tree-sitter/markdown formatting
                        VStack(alignment: .leading, spacing: Spacing.hairline) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, runs in
                                styledLineView(runs, Typography.Step.small.rawValue, true)
                            }
                        }
                        .padding(Spacing.md)
                    } else if let text = result, !text.isEmpty {
                        // Plain text fallback
                        Text(text)
                            .font(Typography.font(.small, design: .monospaced))
                            .foregroundStyle(theme.agentTextFg.opacity(0.7))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(Spacing.md)
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Radius.lg)
                .fill(theme.agentCodeBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(statusColor.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Summary

    @ViewBuilder
    private func toolCallSummaryView(name: String, summary: String) -> some View {
        if name == "shell" {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(summary)
                    .font(Typography.font(.small, design: .monospaced))
                    .foregroundStyle(theme.agentTextFg.opacity(0.5))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(summary)
                .font(Typography.font(.small, design: .monospaced))
                .foregroundStyle(theme.agentTextFg.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Preview lines

    private func previewLinesView(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.hairline) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                previewLine(line)
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(previewBackground)
        .overlay(previewBorder)
    }

    private func previewLine(_ line: String) -> some View {
        Text(line)
            .font(Typography.font(.caption, design: .monospaced))
            .foregroundStyle(previewLineColor(line))
            .truncationMode(.tail)
    }

    private func previewLineColor(_ line: String) -> Color {
        if line.hasPrefix("+") {
            return Color.green.opacity(0.75)
        }
        if line.hasPrefix("-") {
            return Color.red.opacity(0.75)
        }
        return theme.agentTextFg.opacity(0.65)
    }

    private var previewBackground: some View {
        RoundedRectangle(cornerRadius: Radius.md).fill(theme.agentCodeBg.opacity(0.8))
    }

    private var previewBorder: some View {
        RoundedRectangle(cornerRadius: Radius.md).stroke(theme.agentCodeBorder.opacity(0.35), lineWidth: 1)
    }

    // MARK: - Badges & helpers

    @ViewBuilder
    private var statusBadge: some View {
        Text(statusLabel)
            .font(Typography.font(.micro, weight: .medium))
            .foregroundStyle(statusColor.opacity(0.8))
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.hairline)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .fill(statusColor.opacity(0.1))
            )
    }

    private func autoApprovedPill(label: String) -> some View {
        Text("auto-approved · \(label)")
            .font(Typography.font(.caption, design: .rounded))
            .foregroundStyle(theme.agentTextFg.opacity(0.55))
            .accessibilityLabel("Auto-approved for this \(label)")
    }

    private func autoApprovedScopeLabel(_ scope: UInt8) -> String? {
        switch scope {
        case 1: return "session"
        case 2: return "turn"
        default: return nil
        }
    }

    private func formatDuration(_ ms: UInt32) -> String {
        if ms < 1000 { return "\(ms)ms" }
        return String(format: "%.1fs", Double(ms) / 1000.0)
    }

    private var toolIcon: String {
        switch outcome {
        case .running: "gearshape"
        case .complete: "checkmark.circle"
        case .error: "exclamationmark.triangle"
        case .denied: "hand.raised"
        case .cancelled: "stop.circle"
        case .approvalExpired: "clock.badge.exclamationmark"
        case .unknown: isError ? "exclamationmark.triangle" : "questionmark.circle"
        }
    }
}
