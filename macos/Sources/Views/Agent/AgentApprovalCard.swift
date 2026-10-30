import SwiftUI

public struct AgentApprovalCard: View {
    public enum Action: Equatable, Sendable {
        case keyPress(codepoint: UInt32, modifiers: UInt8, sequence: UInt32)
    }

    public init(name: String, summary: String, toolCallId: String, previewKind: UInt8, previewLines: [String], sendAction: ViewActionHandler<Action>?) {
        self.name = name
        self.summary = summary
        self.toolCallId = toolCallId
        self.previewKind = previewKind
        self.previewLines = previewLines
        self.sendAction = sendAction
    }
    public let name: String
    public let summary: String
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

            approvalButtons(toolCallId: toolCallId)
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(approvalCardBackground)
        .overlay(approvalCardBorder)
    }

    // MARK: - Header

    private func approvalToolCallHeader(name: String, summary: String, previewKind: UInt8) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
            Image(systemName: "exclamationmark.shield")
                .font(Typography.font(.emphasis))
                .foregroundStyle(Color.orange)

            Text("Approval required")
                .font(Typography.font(.body, weight: .semibold))
                .foregroundStyle(theme.agentTextFg)

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

    private func approvalButtons(toolCallId _: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Button("Approve (y)") {
                sendAction?(.keyPress(codepoint: 0x79, modifiers: 0, sequence: 0))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            HStack(spacing: Spacing.sm) {
                Button("Trust for session (a)") {
                    sendAction?(.keyPress(codepoint: 0x61, modifiers: 0, sequence: 0))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Trust for this turn (t)") {
                    sendAction?(.keyPress(codepoint: 0x74, modifiers: 0, sequence: 0))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button("Deny (n)") {
                sendAction?(.keyPress(codepoint: 0x6E, modifiers: 0, sequence: 0))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
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
