import SwiftUI
import MingaProtocol

public struct AgentToolCallCard: View {
    public init(messageID: Int, name: String, summary: String, status: UInt8, isError: Bool, collapsed: Bool, autoApprovedScope: UInt8, durationMs: UInt32, result: String? = nil, resultLines: [[Wire.StyledTextRun]]? = nil, previewLines: [String], encoder: InputEncoder? = nil, styledLineView: @escaping ([Wire.StyledTextRun], CGFloat, Bool) -> AnyView) {
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
        self.encoder = encoder
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
    public let encoder: InputEncoder?
    /// Closure to render a styled line, provided by the parent since it's shared
    /// with assistant message rendering.
    public let styledLineView: ([Wire.StyledTextRun], CGFloat, Bool) -> AnyView

    public var body: some View {
        let hasResult = result?.isEmpty == false || resultLines?.isEmpty == false
        let visiblePreviewLines = Array(previewLines.prefix(8))

        VStack(alignment: .leading, spacing: 0) {
            // Header (clickable to toggle collapse)
            HStack(spacing: 6) {
                // Collapse/expand chevron (only shown when there's result content)
                if hasResult {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(theme.agentTextFg.opacity(0.4))
                }

                // Running spinner or status icon
                if status == 0 {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.6)
                } else {
                    Image(systemName: toolIcon(status))
                        .font(.system(size: 10))
                        .foregroundStyle(isError ? Color.red.opacity(0.8) : theme.agentToolHeader)
                }

                Text(name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.agentTextFg)
                    .layoutPriority(1)

                // Tool summary (command, path, etc.)
                if !summary.isEmpty {
                    toolCallSummaryView(name: name, summary: summary)
                }

                Spacer(minLength: 8)

                if durationMs > 0 {
                    Text(formatDuration(durationMs))
                        .font(.system(size: 10))
                        .foregroundStyle(theme.agentTextFg.opacity(0.3))
                }

                statusBadge(status, isError: isError)

                if let autoApprovedLabel = autoApprovedScopeLabel(autoApprovedScope) {
                    autoApprovedPill(label: autoApprovedLabel)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture {
                if hasResult, let messageID = UInt32(exactly: messageID), messageID != 0 {
                    encoder?.sendAgentToolToggle(messageID: messageID)
                }
            }

            if !visiblePreviewLines.isEmpty {
                Rectangle()
                    .fill(theme.agentToolBorder.opacity(0.2))
                    .frame(height: 1)

                previewLinesView(visiblePreviewLines)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }

            // Result (collapsed by default, supports styled or plain text)
            if !collapsed && hasResult {
                Rectangle()
                    .fill(theme.agentToolBorder.opacity(0.2))
                    .frame(height: 1)

                ScrollView([.horizontal, .vertical]) {
                    if let lines = resultLines, !lines.isEmpty {
                        // Styled result with tree-sitter/markdown formatting
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, runs in
                                styledLineView(runs, 11, true)
                            }
                        }
                        .padding(10)
                    } else if let text = result, !text.isEmpty {
                        // Plain text fallback
                        Text(text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.agentTextFg.opacity(0.7))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(10)
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.agentCodeBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isError ? Color.red.opacity(0.3) : theme.agentToolBorder.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Summary

    @ViewBuilder
    private func toolCallSummaryView(name: String, summary: String) -> some View {
        if name == "shell" {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(summary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.agentTextFg.opacity(0.5))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(summary)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.agentTextFg.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Preview lines

    private func previewLinesView(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                previewLine(line)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(previewBackground)
        .overlay(previewBorder)
    }

    private func previewLine(_ line: String) -> some View {
        Text(line)
            .font(.system(size: 10, design: .monospaced))
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
        RoundedRectangle(cornerRadius: 6).fill(theme.agentCodeBg.opacity(0.8))
    }

    private var previewBorder: some View {
        RoundedRectangle(cornerRadius: 6).stroke(theme.agentCodeBorder.opacity(0.35), lineWidth: 1)
    }

    // MARK: - Badges & helpers

    @ViewBuilder
    private func statusBadge(_ status: UInt8, isError: Bool) -> some View {
        let (text, color): (String, Color) = {
            if isError { return ("error", Color.red) }
            switch status {
            case 0: return ("running", Color.orange)
            case 1: return ("done", Color.green)
            case 2: return ("error", Color.red)
            default: return ("", Color.clear)
            }
        }()

        if !text.isEmpty {
            Text(text)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(color.opacity(0.8))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color.opacity(0.1))
                )
        }
    }

    private func autoApprovedPill(label: String) -> some View {
        Text("auto-approved · \(label)")
            .font(.system(size: 10, design: .rounded))
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

    private func toolIcon(_ status: UInt8) -> String {
        switch status {
        case 0: return "gearshape"
        case 1: return "checkmark.circle"
        case 2: return "exclamationmark.triangle"
        default: return "gearshape"
        }
    }
}
