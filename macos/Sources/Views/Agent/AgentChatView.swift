/// Native agent chat view replacing the cell-grid rendered agent panel.
///
/// Renders conversation messages with proper visual hierarchy:
/// user prompts in distinct bubbles, assistant responses with markdown-style
/// formatting, tool calls as collapsible cards, thinking blocks as muted
/// expandable sections, and a prompt input area at the bottom.

import SwiftUI
import MingaProtocol

/// Measures the ScrollView's visible viewport height so the content
/// can be bottom-anchored when there are fewer messages than screen space.
private struct ScrollViewHeightKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

public struct AgentChatView: View {
    public init(state: AgentChatState, isInsertMode: Bool, encoder: InputEncoder? = nil, cellHeight: CGFloat = 16) {
        self.state = state
        self.isInsertMode = isInsertMode
        self.encoder = encoder
        self.cellHeight = cellHeight
    }
    public let state: AgentChatState
    @Environment(\.themeColors) private var theme
    @Environment(\.guiFrameVersion) private var frameVersion
    public let isInsertMode: Bool
    public let encoder: InputEncoder?
    /// Cell dimensions from the Metal renderer, used to size the prompt gap.
    public var cellHeight: CGFloat = 16

    @State private var scrollViewHeight: CGFloat = 0
    /// Tracks whether the user has scrolled away from the bottom.
    /// When true, auto-scroll is paused to let the user read earlier content.
    @State private var userHasScrolledUp: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Whether auto-scroll should follow streaming output.
    private var shouldAutoScroll: Bool { !userHasScrolledUp }

    public var body: some View {
        let _ = frameVersion
        VStack(spacing: 0) {
            // Header bar
            AgentChatHeaderView(state: state, encoder: encoder)

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
                        setScrolledUp(!isAtBottom)
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
                                setScrolledUp(false)
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
                            reduceMotion ? nil : .easeOut(duration: 0.2),
                            value: userHasScrolledUp
                        )
                    }
                }
                .opacity(state.helpVisible ? 0.15 : 1.0)

                if state.helpVisible {
                    helpOverlay
                }
            }

            // Prompt (completion popup + input capsule)
            AgentPromptView(state: state, isInsertMode: isInsertMode, encoder: encoder)
        }
        .background(theme.agentPanelBg)
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
                    .fill(theme.agentCodeBorder.opacity(0.15))
                    .frame(height: 1)
                    .padding(.horizontal, 4)
            }
            messageView(msg, index: index)
        }
    }

    @ViewBuilder
    private func messageView(_ msg: ChatMessageEntry, index: Int) -> some View {
        switch msg {
        case .user(_, let text):
            userMessage(text)
        case .assistant(_, let text):
            assistantBlock(text)
        case .styledAssistant(_, let lines):
            styledAssistantBlock(lines)
        case .assistantMarkdown(_, let blocks):
            assistantMarkdownBlock(blocks)
        case .thinking(_, let text, let collapsed):
            thinkingBlock(text, collapsed: collapsed)
        case .toolCall(_, let name, let summary, let status, let isError, let collapsed, let autoApprovedScope, let duration, let result, _, let previewLines):
            AgentToolCallCard(messageIndex: index, name: name, summary: summary, status: status, isError: isError, collapsed: collapsed, autoApprovedScope: autoApprovedScope, durationMs: duration, result: result, resultLines: nil, previewLines: previewLines, encoder: encoder, styledLineView: { runs, fontSize, mono in
                AnyView(styledLineView(runs, baseFontSize: fontSize, monospaced: mono))
            })
        case .styledToolCall(_, let name, let summary, let status, let isError, let collapsed, let autoApprovedScope, let duration, let resultLines, _, let previewLines):
            AgentToolCallCard(messageIndex: index, name: name, summary: summary, status: status, isError: isError, collapsed: collapsed, autoApprovedScope: autoApprovedScope, durationMs: duration, result: nil, resultLines: resultLines, previewLines: previewLines, encoder: encoder, styledLineView: { runs, fontSize, mono in
                AnyView(styledLineView(runs, baseFontSize: fontSize, monospaced: mono))
            })
        case .approvalToolCall(_, let name, let summary, let toolCallId, let previewKind, let previewLines):
            AgentApprovalCard(name: name, summary: summary, toolCallId: toolCallId, previewKind: previewKind, previewLines: previewLines, encoder: encoder)
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
            .foregroundStyle(theme.agentUserLabel)

            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(theme.agentTextFg)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.agentUserBorder.opacity(0.06))
    }

    @ViewBuilder
    private func assistantBlock(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(theme.agentTextFg.opacity(0.9))
                .textSelection(.enabled)
                .lineSpacing(4)
            Spacer(minLength: 40)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.agentAssistantBorder.opacity(0.03))
        )
    }

    @ViewBuilder
    private func styledAssistantBlock(_ lines: [[Wire.StyledTextRun]]) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, runs in
                    styledLineView(runs, baseFontSize: 13, monospaced: false)
                }
            }
            Spacer(minLength: 40)
        }
    }

    @ViewBuilder
    private func assistantMarkdownBlock(_ blocks: [Wire.AgentMarkdownBlock]) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(blocks) { block in
                    markdownBlockView(block)
                }
            }
            Spacer(minLength: 40)
        }
    }

    @ViewBuilder
    private func markdownBlockView(_ block: Wire.AgentMarkdownBlock) -> some View {
        switch block.kind {
        case .paragraph:
            markdownLines(block.lines, baseFontSize: 13, monospaced: false)
        case .heading:
            markdownLines(block.lines, baseFontSize: block.level == 1 ? 15 : 14, monospaced: false)
        case .listItem:
            markdownLines(block.lines, baseFontSize: 13, monospaced: false)
                .padding(.leading, CGFloat(block.indent) * 12)
        case .blockquote:
            markdownLines(block.lines, baseFontSize: 13, monospaced: false)
                .padding(.leading, 8)
                .overlay(alignment: .leading) {
                    Rectangle().fill(theme.agentToolBorder.opacity(0.35)).frame(width: 2)
                }
        case .rule:
            Rectangle().fill(theme.agentToolBorder.opacity(0.25)).frame(height: 1)
        case .spacer:
            Spacer().frame(height: CGFloat(max(block.height, 1)) * 6)
        case .codeBlock:
            agentCodeCard(block)
        }
    }

    @ViewBuilder
    private func markdownLines(_ lines: [[Wire.StyledTextRun]], baseFontSize: CGFloat, monospaced: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, runs in
                styledLineView(runs, baseFontSize: baseFontSize, monospaced: monospaced)
            }
        }
    }

    @ViewBuilder
    private func agentCodeCard(_ block: Wire.AgentMarkdownBlock) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(block.label.isEmpty ? "Code" : block.label)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.agentTextFg.opacity(0.55))
                if !block.targetPath.isEmpty {
                    Text(block.targetPath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.agentTextFg.opacity(0.38))
                }
                if !block.isComplete {
                    Text("streaming")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.agentTextFg.opacity(0.38))
                }
                Spacer(minLength: 0)
            }

            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(block.lines.enumerated()), id: \.offset) { _, runs in
                        styledLineView(runs, baseFontSize: 12, monospaced: true, allowHorizontalScroll: false)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.agentCodeBg))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.agentCodeBorder.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(codeBlockAccessibilityLabel(block))
        .accessibilityHint("Horizontally scrolls code content.")
    }

    private func codeBlockAccessibilityLabel(_ block: Wire.AgentMarkdownBlock) -> String {
        let language = block.label.isEmpty ? "Code" : block.label
        let state = block.isComplete ? "complete" : "streaming"
        return "Code block, \(language), \(block.lines.count) lines, \(state)"
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
                attr.foregroundColor = theme.agentTextFg.opacity(0.9)
            }
            // Apply background if non-zero
            if run.bgR != 0 || run.bgG != 0 || run.bgB != 0 {
                attr.backgroundColor = Color(
                    red: Double(run.bgR) / 255.0,
                    green: Double(run.bgG) / 255.0,
                    blue: Double(run.bgB) / 255.0
                )
            }
            let runMonospaced = monospaced || run.code
            let design: Font.Design = runMonospaced ? .monospaced : .default
            if run.bold && run.italic {
                attr.font = .system(size: baseFontSize, weight: .bold, design: design).italic()
            } else if run.bold {
                attr.font = .system(size: baseFontSize, weight: .bold, design: design)
            } else if run.italic {
                attr.font = .system(size: baseFontSize, design: design).italic()
            } else if runMonospaced {
                attr.font = .system(size: baseFontSize, design: .monospaced)
            }
            if run.underline {
                attr.underlineStyle = .single
            }
            if let url = safeLinkURL(run.linkURL) {
                attr.link = url
            }
            result += attr
        }
        return result
    }

    @ViewBuilder
    private func styledLineView(_ runs: [Wire.StyledTextRun], baseFontSize: CGFloat, monospaced: Bool, allowHorizontalScroll: Bool = true) -> some View {
        if runs.isEmpty || (runs.count == 1 && runs[0].text.isEmpty) {
            Text(" ")
                .font(.system(size: baseFontSize, design: monospaced ? .monospaced : .default))
                .foregroundStyle(.clear)
        } else if allowHorizontalScroll && shouldScrollHorizontally(runs) {
            ScrollView(.horizontal) {
                Text(buildAttributedString(runs, baseFontSize: baseFontSize, monospaced: monospaced))
                    .font(.system(size: baseFontSize, design: monospaced ? .monospaced : .default))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
            }
        } else {
            Text(buildAttributedString(runs, baseFontSize: baseFontSize, monospaced: monospaced))
                .font(.system(size: baseFontSize, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled)
        }
    }

    private func shouldScrollHorizontally(_ runs: [Wire.StyledTextRun]) -> Bool {
        let textRuns = runs.filter { !$0.text.isEmpty }
        return !textRuns.isEmpty && textRuns.allSatisfy(\.code)
    }

    private func safeLinkURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https":
            guard let host = url.host, !host.isEmpty else { return nil }
            return url
        case "mailto":
            guard !url.path.isEmpty else { return nil }
            return url
        default:
            return nil
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
            .foregroundStyle(theme.agentTextFg.opacity(0.4))

            if !collapsed && !text.isEmpty {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.agentTextFg.opacity(0.35))
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .padding(.leading, 14)
            }
        }
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
        .foregroundStyle(isError ? Color.red.opacity(0.7) : theme.agentTextFg.opacity(0.4))
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
        .foregroundStyle(theme.agentTextFg.opacity(0.3))
    }

    // MARK: - Help overlay

    @ViewBuilder
    private var helpOverlay: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Keyboard Shortcuts")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.agentTextFg)
                    Spacer()
                    Text("Press ? or Esc to close")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.agentTextFg.opacity(0.4))
                }

                ForEach(state.helpGroups) { group in
                    helpGroupView(group)
                }
            }
            .padding(20)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.agentPanelBg.opacity(0.95))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(theme.agentCodeBorder.opacity(0.3), lineWidth: 1)
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
                .foregroundStyle(theme.agentHeaderFg)

            ForEach(Array(group.bindings.enumerated()), id: \.offset) { _, binding in
                HStack(spacing: 0) {
                    Text(binding.key)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.agentTextFg.opacity(0.9))
                        .frame(width: 140, alignment: .leading)

                    Text(binding.description)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.agentTextFg.opacity(0.6))

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
        .foregroundStyle(theme.agentTextFg.opacity(0.8))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(theme.agentCodeBg.opacity(0.9))
        )
        .overlay(
            Capsule()
                .strokeBorder(theme.agentCodeBorder.opacity(0.3), lineWidth: 1)
        )
    }

    /// Updates the local scrolled-up flag and, only on a transition, reports the
    /// pin intent to the BEAM so it owns the authoritative pin state (#2654).
    /// The frontend keeps presenting its local scroll same-frame; the report just
    /// pauses or resumes BEAM-side auto-follow of streaming output.
    private func setScrolledUp(_ scrolledUp: Bool) {
        guard scrolledUp != userHasScrolledUp else { return }
        userHasScrolledUp = scrolledUp
        if scrolledUp {
            encoder?.sendChatScrolledAwayFromBottom()
        } else {
            encoder?.sendChatReturnedToBottom()
        }
    }

    /// Scrolls to the last message with smooth animation.
    private func scrollToBottom(proxy: ScrollViewProxy) {
        guard let lastId = state.messages.last?.id else { return }
        let animation: Animation? = reduceMotion ? nil : .easeOut(duration: 0.15)
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
}

// MARK: - Previews

@MainActor
private func agentChatPreviewState() -> AgentChatState {
    let state = AgentChatState()
    PreviewFixtures.populateAgentChat(state)
    return state
}

#Preview("Agent Chat", traits: .mingaChrome) {
    AgentChatView(state: agentChatPreviewState(), isInsertMode: false, encoder: nil, cellHeight: 18)
        .frame(width: 760, height: 600)
}
