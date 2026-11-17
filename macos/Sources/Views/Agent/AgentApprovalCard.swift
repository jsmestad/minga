import SwiftUI

public struct AgentApprovalCard: View {
    public enum Action: Equatable, Sendable {
        case approve(sessionId: String, requestId: String, toolCallId: String)
        case trustSession(sessionId: String, requestId: String, toolCallId: String)
        case trustTurn(sessionId: String, requestId: String, toolCallId: String)
        case deny(sessionId: String, requestId: String, toolCallId: String)
    }

    public init(name: String, summary: String, toolCallId: String, sessionId: String, requestId: String, previewKind: UInt8, previewLines: [String], sendAction: ViewActionHandler<Action>?) {
        self.name = name
        self.summary = summary
        self.sessionId = sessionId
        self.requestId = requestId
        self.toolCallId = toolCallId
        self.previewKind = previewKind
        self.previewLines = previewLines
        self.sendAction = sendAction
    }
    public let name: String
    public let summary: String
    public let sessionId: String
    public let requestId: String
    public let toolCallId: String
    public let previewKind: UInt8
    public let previewLines: [String]
    @Environment(\.themeColors) private var theme
    public let sendAction: ViewActionHandler<Action>?

    public var body: some View {
        let visiblePreviewLines = Array(previewLines.prefix(8))

        VStack(alignment: .leading, spacing: Spacing.md) {
            approvalToolCallHeader(name: name, summary: summary, previewKind: previewKind)

            if !visiblePreviewLines.isEmpty {
                approvalPreviewLines(visiblePreviewLines)
            }

            approvalButtons
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(approvalCardBackground)
        .overlay(approvalCardBorder)
    }

    // MARK: - Header

    private func approvalToolCallHeader(name: String, summary: String, previewKind: UInt8) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                Image(systemName: "exclamationmark.shield")
                    .font(Typography.font(.emphasis))
                    .foregroundStyle(Color.orange)

                Text("Approval required")
                    .font(Typography.font(.body, weight: .semibold))
                    .foregroundStyle(theme.agentTextFg)
            }

            Text(name)
                .font(Typography.font(.body, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.agentToolHeader)

            if !summary.isEmpty {
                approvalToolCallSummary(summary: summary, previewKind: previewKind)
            }
        }
    }

    // MARK: - Summary

    @ViewBuilder
    private func approvalToolCallSummary(summary: String, previewKind: UInt8) -> some View {
        if previewKind == 2 {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(summary)
                    .font(Typography.font(.body, weight: .regular, design: .monospaced))
                    .foregroundStyle(theme.agentTextFg)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        } else {
            Text(summary)
                .font(Typography.font(.body, weight: .regular, design: .monospaced))
                .foregroundStyle(theme.agentTextFg)
                .lineLimit(2)
        }
    }

    // MARK: - Preview lines

    private func approvalPreviewLines(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.hairline) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                approvalPreviewLine(line)
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(approvalPreviewBackground)
        .overlay(approvalPreviewBorder)
    }

    private func approvalPreviewLine(_ line: String) -> some View {
        Text(line)
            .font(Typography.font(.caption, design: .monospaced))
            .foregroundStyle(approvalPreviewLineColor(line))
            .truncationMode(.tail)
    }

    private func approvalPreviewLineColor(_ line: String) -> Color {
        if line.hasPrefix("+") {
            return Color.green.opacity(0.75)
        }
        if line.hasPrefix("-") {
            return Color.red.opacity(0.75)
        }
        return theme.agentTextFg.opacity(0.65)
    }

    // MARK: - Buttons

    private var approvalButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.sm) {
                approvalButtonContent
            }
            VStack(alignment: .leading, spacing: Spacing.sm) {
                approvalButtonContent
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var approvalButtonContent: some View {
        Button("Approve (y)") {
            sendAction?(.approve(sessionId: sessionId, requestId: requestId, toolCallId: toolCallId))
        }
        .buttonStyle(.borderedProminent)

        Button("Trust for session (a)") {
            sendAction?(.trustSession(sessionId: sessionId, requestId: requestId, toolCallId: toolCallId))
        }
        .buttonStyle(.bordered)

        Button("Trust for this turn (t)") {
            sendAction?(.trustTurn(sessionId: sessionId, requestId: requestId, toolCallId: toolCallId))
        }
        .buttonStyle(.bordered)

        Button("Deny (n)") {
            sendAction?(.deny(sessionId: sessionId, requestId: requestId, toolCallId: toolCallId))
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Card chrome

    private var approvalCardBackground: some View {
        RoundedRectangle(cornerRadius: Radius.lg).fill(theme.agentCodeBg.opacity(0.9))
    }

    private var approvalCardBorder: some View {
        RoundedRectangle(cornerRadius: Radius.lg).stroke(Color.orange.opacity(0.5), lineWidth: 1)
    }

    private var approvalPreviewBackground: some View {
        RoundedRectangle(cornerRadius: Radius.md).fill(theme.agentCodeBg.opacity(0.8))
    }

    private var approvalPreviewBorder: some View {
        RoundedRectangle(cornerRadius: Radius.md).stroke(theme.agentCodeBorder.opacity(0.35), lineWidth: 1)
    }

    private func approvalPreviewLabel(_ kind: UInt8) -> String {
        switch kind {
        case 1: return "Diff"
        case 2: return "Command"
        case 3: return "Target"
        default: return "Args"
        }
    }
}
