/// Native agent chat view replacing the cell-grid rendered agent panel.
///
/// Renders conversation messages with proper visual hierarchy:
/// user prompts in distinct bubbles, assistant responses with markdown-style
/// formatting, tool calls as collapsible cards, thinking blocks as muted
/// expandable sections, and a prompt input area at the bottom.

import SwiftUI

/// Measures the ScrollView's visible viewport height so the content
/// can be bottom-anchored when there are fewer messages than screen space.
private struct ScrollViewHeightKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct AgentChatView: View {
    let state: AgentChatState
    let theme: ThemeColors
    let isInsertMode: Bool
    let encoder: InputEncoder?
    /// Cell dimensions from the Metal renderer, used to size the prompt gap.
    var cellHeight: CGFloat = 16

    @State private var scrollViewHeight: CGFloat = 0
    /// Tracks whether the user has scrolled away from the bottom.
    /// When true, auto-scroll is paused to let the user read earlier content.
    @State private var userHasScrolledUp: Bool = false
    /// Whether auto-scroll should follow streaming output.
    private var shouldAutoScroll: Bool { !userHasScrolledUp }

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            chatHeader

            // Messages: bottom-anchored so few messages cluster near the
            // prompt input rather than leaving a void below them.
            ZStack {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 12) {
                            ForEach(Array(state.messages.enumerated()), id: \.element.id) { index, msg in
                                messageViewWithDivider(msg, index: index)
                            }

                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 16)
                        .frame(minHeight: scrollViewHeight, alignment: .bottom)
                    }
                    .defaultScrollAnchor(.bottom)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: ScrollViewHeightKey.self,
                                value: geo.size.height
                            )
                        }
                    )
                    .onPreferenceChange(ScrollViewHeightKey.self) { height in
                        scrollViewHeight = height
                    }
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        // User is "at bottom" if within 50pt of the bottom edge
                        let atBottom = geometry.contentOffset.y + geometry.visibleRect.height >= geometry.contentSize.height - 50
                        return atBottom
                    } action: { _, isAtBottom in
                        userHasScrolledUp = !isAtBottom
                    }
                    .onChange(of: state.messages.count) { _, _ in
                        if shouldAutoScroll {
                            scrollToBottom(proxy: proxy)
                        }
                    }
                    .onChange(of: state.promptVersion) { _, _ in
                        // Triggers on every BEAM frame update (streaming content growth)
                        if shouldAutoScroll && state.isThinking {
                            scrollToBottom(proxy: proxy)
                        }
                    }
                    // "Follow output" pill when user scrolled up during streaming
                    if userHasScrolledUp && state.isThinking {
                        VStack {
                            Spacer()
                            Button {
                                userHasScrolledUp = false
                                scrollToBottom(proxy: proxy)
                            } label: {
                                followOutputPillLabel
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Follow output")
                            .accessibilityHint("Scrolls to latest content and resumes auto-scroll")
                            .padding(.bottom, 8)
                        }
                        .transition(.opacity)
                        .animation(
                            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                                ? nil : .easeOut(duration: 0.2),
                            value: userHasScrolledUp
                        )
                    }
                }
                .opacity(state.helpVisible ? 0.15 : 1.0)

                if state.helpVisible {
                    helpOverlay
                }
            }

            // Approval banner (when tool needs user confirmation)
            if let approval = state.pendingApproval {
                approvalBanner(approval)
            }

            // Prompt completion popup (floats above the prompt area)
            if let completion = state.promptCompletion {
                promptCompletionPopup(completion)
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

            Button {
                // Send '?' to toggle help overlay
                encoder?.sendKeyPress(codepoint: 0x3F, modifiers: 0)
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(state.helpVisible ? theme.accent : theme.popupFg.opacity(0.4))
            }
            .buttonStyle(.plain)
            .help("Keyboard shortcuts (?)")
            .accessibilityLabel("Help")
            .accessibilityHint("Shows keybinding cheatsheet")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(theme.modelineBarBg)

        Rectangle()
            .fill(theme.popupBorder.opacity(0.3))
            .frame(height: 1)
    }

    // MARK: - Messages

    /// Wraps each message with an optional divider in a single VStack.
    /// Keeping one view per ForEach iteration prevents LazyVStack from
    /// miscalculating tap targets due to variable-height implicit Groups.
    @ViewBuilder
    private func messageViewWithDivider(_ msg: ChatMessageEntry, index: Int) -> some View {
        VStack(spacing: 8) {
            if index > 0 && shouldShowDivider(before: msg, after: state.messages[index - 1]) {
                Rectangle()
                    .fill(theme.popupBorder.opacity(0.15))
                    .frame(height: 1)
                    .padding(.horizontal, 4)
            }
            messageView(msg)
        }
    }

    @ViewBuilder
    private func messageView(_ msg: ChatMessageEntry) -> some View {
        switch msg {
        case .user(_, let text):
            userMessage(text)
        case .assistant(_, let text):
            assistantBlock(text)
        case .styledAssistant(_, let lines):
            styledAssistantBlock(lines)
        case .thinking(_, let text, let collapsed):
            thinkingBlock(text, collapsed: collapsed)
        case .toolCall(let id, let name, let summary, let status, let isError, let collapsed, let duration, let result):
            toolCallCard(messageIndex: id, name: name, summary: summary, status: status, isError: isError, collapsed: collapsed, durationMs: duration, result: result, resultLines: nil)
        case .styledToolCall(let id, let name, let summary, let status, let isError, let collapsed, let duration, let resultLines):
            toolCallCard(messageIndex: id, name: name, summary: summary, status: status, isError: isError, collapsed: collapsed, durationMs: duration, result: nil, resultLines: resultLines)
        case .system(_, let text, let isError):
            systemMessage(text, isError: isError)
        case .usage(_, let input, let output, _, _, let costMicros):
            usageRow(input: input, output: output, costMicros: costMicros)
        }
    }

    @ViewBuilder
    private func userMessage(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Sender label
            HStack(spacing: 4) {
                Image(systemName: "person.fill")
                    .font(.system(size: 9))
                Text("You")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(theme.popupFg.opacity(0.45))

            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(theme.popupFg)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.accent.opacity(0.04))
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
    private func styledAssistantBlock(_ lines: [[Wire.StyledTextRun]]) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, runs in
                    if runs.isEmpty || (runs.count == 1 && runs[0].text.isEmpty) {
                        // Empty line: render as a spacer with line height
                        Text(" ")
                            .font(.system(size: 13))
                            .foregroundStyle(.clear)
                    } else {
                        Text(buildAttributedString(runs))
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                    }
                }
            }
            Spacer(minLength: 40)
        }
    }

    private func buildAttributedString(_ runs: [Wire.StyledTextRun], baseFontSize: CGFloat = 13, monospaced: Bool = false) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            var attr = AttributedString(run.text)
            let fg = Color(
                red: Double(run.fgR) / 255.0,
                green: Double(run.fgG) / 255.0,
                blue: Double(run.fgB) / 255.0
            )
            // Only apply foreground if not all zeros (default/unstyled)
            if run.fgR != 0 || run.fgG != 0 || run.fgB != 0 {
                attr.foregroundColor = fg
            } else {
                attr.foregroundColor = theme.popupFg.opacity(0.9)
            }
            // Apply background if non-zero
            if run.bgR != 0 || run.bgG != 0 || run.bgB != 0 {
                attr.backgroundColor = Color(
                    red: Double(run.bgR) / 255.0,
                    green: Double(run.bgG) / 255.0,
                    blue: Double(run.bgB) / 255.0
                )
            }
            let design: Font.Design = monospaced ? .monospaced : .default
            if run.bold && run.italic {
                attr.font = .system(size: baseFontSize, weight: .bold, design: design).italic()
            } else if run.bold {
                attr.font = .system(size: baseFontSize, weight: .bold, design: design)
            } else if run.italic {
                attr.font = .system(size: baseFontSize, design: design).italic()
            } else if monospaced {
                attr.font = .system(size: baseFontSize, design: .monospaced)
            }
            if run.underline {
                attr.underlineStyle = .single
            }
            result += attr
        }
        return result
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
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .padding(.leading, 14)
            }
        }
    }

    @ViewBuilder
    private func toolCallCard(messageIndex: Int, name: String, summary: String, status: UInt8, isError: Bool, collapsed: Bool, durationMs: UInt32, result: String?, resultLines: [[Wire.StyledTextRun]]?) -> some View {
        let hasResult = (result != nil && !result!.isEmpty) || (resultLines != nil && !resultLines!.isEmpty)

        VStack(alignment: .leading, spacing: 0) {
            // Header (clickable to toggle collapse)
            HStack(spacing: 6) {
                // Collapse/expand chevron (only shown when there's result content)
                if hasResult {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(theme.popupFg.opacity(0.4))
                }

                // Running spinner or status icon
                if status == 0 {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.6)
                } else {
                    Image(systemName: toolIcon(status))
                        .font(.system(size: 10))
                        .foregroundStyle(isError ? Color.red.opacity(0.8) : theme.accent)
                }

                Text(name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.popupFg)
                    .layoutPriority(1)

                // Tool summary (command, path, etc.)
                if !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.popupFg.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                if durationMs > 0 {
                    Text(formatDuration(durationMs))
                        .font(.system(size: 10))
                        .foregroundStyle(theme.popupFg.opacity(0.3))
                }

                statusBadge(status, isError: isError)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture {
                if hasResult, messageIndex <= Int(UInt16.max) {
                    encoder?.sendAgentToolToggle(index: UInt16(messageIndex))
                }
            }

            // Result (collapsed by default, supports styled or plain text)
            if !collapsed && hasResult {
                Rectangle()
                    .fill(theme.popupBorder.opacity(0.2))
                    .frame(height: 1)

                ScrollView(.vertical) {
                    if let lines = resultLines, !lines.isEmpty {
                        // Styled result with tree-sitter/markdown formatting
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, runs in
                                if runs.isEmpty || (runs.count == 1 && runs[0].text.isEmpty) {
                                    Text(" ")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.clear)
                                } else {
                                    Text(buildAttributedString(runs, baseFontSize: 11, monospaced: true))
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .padding(10)
                    } else if let text = result, !text.isEmpty {
                        // Plain text fallback
                        Text(text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.popupFg.opacity(0.7))
                            .textSelection(.enabled)
                            .padding(10)
                    }
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
                .textSelection(.enabled)
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

    /// Whether the agent is actively streaming a response.
    private var isStreaming: Bool { state.status == 1 || state.status == 2 }

    /// Whether the send button should be enabled (insert mode with text).
    private var canSend: Bool { isInsertMode && !state.prompt.isEmpty && !isStreaming }

    /// The SF Symbol name for the action button, morphing between send and stop.
    private var actionButtonIcon: String {
        isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill"
    }

    /// The action button's foreground color based on state.
    private var actionButtonColor: Color {
        if isStreaming { return .red }
        if canSend { return theme.accent }
        return theme.popupFg.opacity(0.2)
    }

    /// Capsule border color: accent when in insert mode, subtle border otherwise.
    private var capsuleBorderColor: Color {
        if isInsertMode { return theme.accent.opacity(0.5) }
        return theme.popupBorder.opacity(0.3)
    }

    /// Capsule background opacity shifts with mode.
    private var capsuleBgOpacity: Double {
        if isInsertMode { return 0.8 }
        if isStreaming { return 0.6 }
        return 0.4
    }

    /// Vim mode label shown in the prompt border.
    private var modeLabel: String {
        switch state.promptVimMode {
        case 0: return "NORMAL"
        case 2: return "VISUAL"
        case 3: return "V-LINE"
        case 4: return "OP"
        default: return "" // insert mode: no label
        }
    }

    @ViewBuilder
    private var promptArea: some View {
        HStack(spacing: 8) {
            promptCapsule
            actionButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent prompt")
    }

    @ViewBuilder
    private var promptCapsule: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Mode indicator bar (only in non-insert modes)
            if !modeLabel.isEmpty {
                HStack(spacing: 4) {
                    Text(modeLabel)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(theme.accent)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 2)
            }

            // Prompt text with monospaced font and cursor
            HStack(spacing: 0) {
                if isStreaming && state.prompt.isEmpty {
                    Text("Generating...")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(theme.popupFg.opacity(0.3))
                        .italic()
                } else if state.prompt.isEmpty && !isInsertMode {
                    Text("Ask anything...")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(theme.popupFg.opacity(0.25))
                } else {
                    // Render prompt text with cursor overlay
                    promptTextWithCursor
                }

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, modeLabel.isEmpty ? 10 : 6)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.popupBg.opacity(capsuleBgOpacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(capsuleBorderColor, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            if !isInsertMode && !isStreaming {
                encoder?.sendKeyPress(codepoint: 0x69, modifiers: 0)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Chat input")
        .accessibilityValue(state.prompt.isEmpty ? "Empty" : state.prompt)
        .accessibilityHint(isInsertMode ? "Type a message, press Return to send" : "Press i to start typing")
    }

    /// Monospace character width at the prompt font size, computed from actual font metrics.
    private var promptCharWidth: CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let size = ("M" as NSString).size(withAttributes: [.font: font])
        return size.width
    }

    /// Line height for the prompt font, derived from actual font metrics.
    private var promptLineHeight: CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        return ceil(font.ascender - font.descender + font.leading)
    }

    /// Renders the prompt text with a cursor at the BEAM-reported position.
    /// Uses monospaced font so cursor positioning aligns with character columns.
    @ViewBuilder
    private var promptTextWithCursor: some View {
        let lines = state.prompt.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let cursorLine = Int(state.promptCursorLine)
        let cursorCol = Int(state.promptCursorCol)
        let isBlock = state.promptVimMode == 0 || state.promptVimMode >= 2
        let charW = promptCharWidth
        let lineH = promptLineHeight

        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.prefix(8).enumerated()), id: \.offset) { lineIdx, line in
                ZStack(alignment: .leading) {
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(theme.popupFg.opacity(isStreaming ? 0.4 : 1.0))

                    if lineIdx == cursorLine && !isStreaming {
                        let cursorX = CGFloat(cursorCol) * charW

                        if isBlock {
                            Rectangle()
                                .fill(theme.accent.opacity(0.7))
                                .frame(width: charW, height: lineH)
                                .offset(x: cursorX)
                        } else {
                            Rectangle()
                                .fill(theme.accent)
                                .frame(width: 1.5, height: lineH)
                                .offset(x: cursorX)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        Button {
            if isStreaming {
                // Send Ctrl+C to abort
                encoder?.sendKeyPress(codepoint: 0x63, modifiers: 0x02)
            } else if canSend {
                // Send Enter to submit
                encoder?.sendKeyPress(codepoint: 0x0D, modifiers: 0)
            }
        } label: {
            Image(systemName: actionButtonIcon)
                .font(.system(size: 24))
                .foregroundStyle(actionButtonColor)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .disabled(!canSend && !isStreaming)
        .accessibilityLabel(isStreaming ? "Stop generating" : "Send message")
        .accessibilityHint(isStreaming ? "Sends Ctrl+C to abort" : "Sends the current prompt")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Prompt completion popup

    /// Renders a floating completion popup for @-mention or /slash commands.
    /// Styled to match the existing CompletionOverlay used for LSP completions.
    @ViewBuilder
    private func promptCompletionPopup(_ completion: Wire.PromptCompletion) -> some View {
        let isSlash = completion.type == 1
        let maxVisible = min(completion.candidates.count, 10)

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(completion.candidates.prefix(10).enumerated()), id: \.offset) { index, candidate in
                HStack(spacing: 6) {
                    Image(systemName: isSlash ? "command" : "doc")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.popupFg.opacity(0.4))
                        .frame(width: 14)

                    Text(candidate.name)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.popupFg)
                        .lineLimit(1)

                    if !candidate.description.isEmpty {
                        Text(candidate.description)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.popupFg.opacity(0.4))
                            .lineLimit(1)
                    }

                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(index == Int(completion.selected) ? theme.accent.opacity(0.15) : Color.clear)
            }
        }
        .frame(maxWidth: 400)
        .frame(maxHeight: CGFloat(maxVisible) * 24)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.popupBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(theme.popupBorder.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 8, y: -4)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isSlash ? "Slash command completion" : "File mention completion")
    }

    // MARK: - Help overlay

    @ViewBuilder
    private var helpOverlay: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Keyboard Shortcuts")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.popupFg)
                    Spacer()
                    Text("Press ? or Esc to close")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.popupFg.opacity(0.4))
                }

                ForEach(state.helpGroups) { group in
                    helpGroupView(group)
                }
            }
            .padding(20)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.popupBg.opacity(0.95))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(theme.popupBorder.opacity(0.3), lineWidth: 1)
        )
        .padding(16)
        .transition(.opacity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keyboard shortcuts help")
    }

    @ViewBuilder
    private func helpGroupView(_ group: HelpGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.accent)

            ForEach(Array(group.bindings.enumerated()), id: \.offset) { _, binding in
                HStack(spacing: 0) {
                    Text(binding.key)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.popupFg.opacity(0.9))
                        .frame(width: 140, alignment: .leading)

                    Text(binding.description)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.popupFg.opacity(0.6))

                    Spacer()
                }
            }
        }
    }

    // MARK: - Follow output pill

    @ViewBuilder
    private var followOutputPillLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.down")
                .font(.system(size: 10, weight: .semibold))
            Text("Follow output")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(theme.popupFg.opacity(0.8))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(theme.popupBg.opacity(0.9))
        )
        .overlay(
            Capsule()
                .strokeBorder(theme.popupBorder.opacity(0.3), lineWidth: 1)
        )
    }

    /// Scrolls to the last message with smooth animation.
    private func scrollToBottom(proxy: ScrollViewProxy) {
        guard let lastId = state.messages.last?.id else { return }
        let animation: Animation? = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? nil : .easeOut(duration: 0.15)
        withAnimation(animation) {
            proxy.scrollTo(lastId, anchor: .bottom)
        }
    }

    // MARK: - Message dividers

    /// Show a divider between user messages and the preceding message group.
    /// This creates visual rhythm between conversation turns.
    private func shouldShowDivider(before current: ChatMessageEntry, after previous: ChatMessageEntry) -> Bool {
        // Show divider before user messages (start of a new turn),
        // unless the previous message was also a user message.
        switch (previous, current) {
        case (.user, .user): return false
        case (_, .user): return true
        default: return false
        }
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
