/// Native agent chat view replacing the cell-grid rendered agent panel.
///
/// Renders conversation messages with proper visual hierarchy:
/// user prompts in distinct bubbles, assistant responses with markdown-style
/// formatting, tool calls as collapsible cards, thinking blocks as muted
/// expandable sections, and a prompt input area at the bottom.

import SwiftUI

struct AgentChatView: View {
    let state: AgentChatState
    let theme: ThemeColors
    let isInsertMode: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            chatHeader

            // Messages
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 12) {
                        ForEach(state.messages) { msg in
                            messageView(msg)
                        }

                        // Bottom padding so the last message has breathing room
                        // above the prompt separator / approval banner.
                        Spacer(minLength: 16)
                            .id("bottom-padding")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
                .onChange(of: state.messages.count) { _, _ in
                    withAnimation(nil) {
                        proxy.scrollTo("bottom-padding", anchor: .bottom)
                    }
                }
            }

            // Approval banner (when tool needs user confirmation)
            if let approval = state.pendingApproval {
                approvalBanner(approval)
            }

            // Prompt area
            promptArea
        }
        .background(theme.editorBg)
    }

    // MARK: - Header

    @ViewBuilder
    private var chatHeader: some View {
        HStack(spacing: 8) {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)

            Text(state.model.isEmpty ? "Agent" : state.model)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.popupFg)

            if state.isThinking {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
            }

            Spacer()

            Text(state.statusLabel)
                .font(.system(size: 11))
                .foregroundStyle(theme.popupFg.opacity(0.4))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(theme.modelineBarBg)

        Rectangle()
            .fill(theme.popupBorder.opacity(0.3))
            .frame(height: 1)
    }

    // MARK: - Messages

    @ViewBuilder
    private func messageView(_ msg: ChatMessageEntry) -> some View {
        switch msg {
        case .user(_, let text):
            userBubble(text)
        case .assistant(_, let text):
            assistantBlock(text)
        case .thinking(_, let text, let collapsed):
            thinkingBlock(text, collapsed: collapsed)
        case .toolCall(_, let name, let status, let isError, let collapsed, let duration, let result):
            toolCallCard(name: name, status: status, isError: isError, collapsed: collapsed, durationMs: duration, result: result)
        case .system(_, let text, let isError):
            systemMessage(text, isError: isError)
        case .usage(_, let input, let output, _, _, let costMicros):
            usageRow(input: input, output: output, costMicros: costMicros)
        }
    }

    @ViewBuilder
    private func userBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 60)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(theme.popupFg)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(theme.accent.opacity(0.15))
                )
        }
    }

    @ViewBuilder
    private func assistantBlock(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(theme.popupFg.opacity(0.9))
                .textSelection(.enabled)
                .lineSpacing(4)
            Spacer(minLength: 40)
        }
    }

    @ViewBuilder
    private func thinkingBlock(_ text: String, collapsed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9))
                Text("Thinking...")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
            }
            .foregroundStyle(theme.popupFg.opacity(0.4))

            if !collapsed && !text.isEmpty {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.popupFg.opacity(0.35))
                    .lineSpacing(3)
                    .padding(.leading, 14)
            }
        }
    }

    @ViewBuilder
    private func toolCallCard(name: String, status: UInt8, isError: Bool, collapsed: Bool, durationMs: UInt32, result: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: toolIcon(status))
                    .font(.system(size: 10))
                    .foregroundStyle(isError ? Color.red.opacity(0.8) : theme.accent)

                Text(name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.popupFg)

                Spacer()

                if durationMs > 0 {
                    Text(formatDuration(durationMs))
                        .font(.system(size: 10))
                        .foregroundStyle(theme.popupFg.opacity(0.3))
                }

                statusBadge(status, isError: isError)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            // Result (collapsed by default)
            if !collapsed && !result.isEmpty {
                Rectangle()
                    .fill(theme.popupBorder.opacity(0.2))
                    .frame(height: 1)

                ScrollView(.vertical) {
                    Text(result)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.popupFg.opacity(0.7))
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(maxHeight: 200)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.popupBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isError ? Color.red.opacity(0.3) : theme.popupBorder.opacity(0.3), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func systemMessage(_ text: String, isError: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isError ? "exclamationmark.triangle" : "info.circle")
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 11))
        }
        .foregroundStyle(isError ? Color.red.opacity(0.7) : theme.popupFg.opacity(0.4))
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func usageRow(input: UInt32, output: UInt32, costMicros: UInt32) -> some View {
        let cost = Double(costMicros) / 1_000_000.0
        HStack(spacing: 12) {
            Spacer()
            Label("\(input)", systemImage: "arrow.up")
            Label("\(output)", systemImage: "arrow.down")
            Text(String(format: "$%.4f", cost))
        }
        .font(.system(size: 10))
        .foregroundStyle(theme.popupFg.opacity(0.3))
    }

    // MARK: - Prompt

    // MARK: - Approval banner

    @ViewBuilder
    private func approvalBanner(_ approval: AgentChatState.PendingApproval) -> some View {
        VStack(spacing: 6) {
            Rectangle()
                .fill(theme.popupBorder.opacity(0.3))
                .frame(height: 1)

            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.shield")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Tool needs approval")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.popupFg)

                    HStack(spacing: 4) {
                        Text(approval.toolName)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(theme.accent)

                        if !approval.summary.isEmpty {
                            Text(approval.summary)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(theme.popupFg.opacity(0.6))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }

                Spacer()

                Text("y")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.green.opacity(0.1)))
                Text("approve")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.popupFg.opacity(0.5))

                Text("n")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.red.opacity(0.1)))
                Text("reject")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.popupFg.opacity(0.5))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.05))
        }
    }

    // MARK: - Prompt area

    @ViewBuilder
    private var promptArea: some View {
        Rectangle()
            .fill(theme.popupBorder.opacity(0.3))
            .frame(height: 1)

        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isInsertMode ? theme.accent : theme.popupFg.opacity(0.3))

            if state.prompt.isEmpty {
                Text(isInsertMode ? "Type a message, Enter to send" : "Press i to type")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.popupFg.opacity(isInsertMode ? 0.4 : 0.25))
            } else {
                // Text + cursor with zero spacing so cursor sits right at the insertion point
                HStack(spacing: 0) {
                    Text(state.prompt)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.popupFg)
                    if isInsertMode {
                        // Cursor indicator
                        Rectangle()
                            .fill(theme.accent)
                            .frame(width: 1.5, height: 16)
                    }
                }
            }

            Spacer()

            if !isInsertMode {
                Text("NORMAL")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.modeNormalFg)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(theme.modeNormalBg))
            }

            Text(state.model)
                .font(.system(size: 10))
                .foregroundStyle(theme.popupFg.opacity(0.3))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isInsertMode ? theme.modelineBarBg : theme.modelineBarBg.opacity(0.7))
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch state.status {
        case 0: return Color.gray
        case 1: return theme.accent
        case 2: return Color.orange
        case 3: return Color.red
        default: return Color.gray
        }
    }

    private func toolIcon(_ status: UInt8) -> String {
        switch status {
        case 0: return "gearshape"
        case 1: return "checkmark.circle"
        case 2: return "exclamationmark.triangle"
        default: return "gearshape"
        }
    }

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

    private func formatDuration(_ ms: UInt32) -> String {
        if ms < 1000 { return "\(ms)ms" }
        return String(format: "%.1fs", Double(ms) / 1000.0)
    }
}
