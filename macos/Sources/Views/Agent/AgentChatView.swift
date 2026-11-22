/// Native agent chat view replacing the cell-grid rendered agent panel.
///
/// Renders conversation messages with proper visual hierarchy:
/// user prompts in distinct bubbles, assistant responses with markdown-style
/// formatting, tool calls as collapsible cards, thinking blocks as muted
/// expandable sections, and a prompt input area at the bottom.

import SwiftUI
import MingaProtocol

/// Test hook that records each evaluation of the conversation list body.
/// Production leaves it nil; tests install it to prove which state changes
/// re-evaluate the conversation.
struct AgentConversationListEvaluationProbe: Sendable {
    let record: @MainActor @Sendable () -> Void
}

private struct AgentConversationListEvaluationProbeKey: EnvironmentKey {
    static let defaultValue: AgentConversationListEvaluationProbe? = nil
}

extension EnvironmentValues {
    var agentConversationListEvaluationProbe: AgentConversationListEvaluationProbe? {
        get { self[AgentConversationListEvaluationProbeKey.self] }
        set { self[AgentConversationListEvaluationProbeKey.self] = newValue }
    }
}

public struct AgentChatView: View {
    public enum Action: Equatable, Sendable {
        case toolApproval(AgentApprovalCard.Action)
        case executeCommand(name: String)
        case agentToolToggle(messageID: UInt32)
        case agentReadRetainedOutput(messageID: UInt32, offer: Wire.RetainedOutputOffer)
        case composerSubmit(generation: UInt64, offer: UInt64)
        case composerQueue(generation: UInt64, offer: UInt64, followUp: Bool, target: AgentQueueTarget)
        case openQuestion(offer: UInt64)
        case stopTurn(AgentStopTarget)
        case chatScrolledAwayFromBottom
        case chatReturnedToBottom
    }

    public init(state: AgentChatState, isInsertMode: Bool, sendAction: ViewActionHandler<Action>?) {
        self.state = state
        self.isInsertMode = isInsertMode
        self.sendAction = sendAction
    }
    public let state: AgentChatState
    @Environment(\.themeColors) private var theme

    public let isInsertMode: Bool
    public let sendAction: ViewActionHandler<Action>?

    @State private var availableHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 0

    public var body: some View {
        VStack(spacing: 0) {
            // Header bar
            AgentChatHeaderView(state: state, sendAction: childAction { action in
                switch action {
                case .executeCommand(let name): .executeCommand(name: name)
                }
            })
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }

            if state.lifecycle != .conversation {
                lifecycleNotice
            }
            AgentConversationList(state: state, sendAction: state.lifecycle == .conversation ? sendAction : nil)

            if state.lifecycle == .conversation, let question = state.question {
                HStack(spacing: Spacing.md) {
                    Text(question.prompt)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Answer question") {
                        sendAction?(.openQuestion(offer: question.offer))
                    }
                    .fixedSize()
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.sm)
            }

            // Prompt (completion popup + input capsule)
            if state.lifecycle == .conversation || state.promptVisibleRows > 0 {
                AgentPromptView(state: state, isInsertMode: isInsertMode, sendAction: childAction { [generation = state.promptPresentation, offer = state.draftAttachmentOffer] action in
                    switch action {
                    case .submit: .composerSubmit(generation: generation, offer: offer)
                    case .queue(let followUp, let target): .composerQueue(generation: generation, offer: offer, followUp: followUp, target: target)
                    case .abort(let target): .stopTurn(target)
                    case .attachments: .executeCommand(name: "agent_draft_attachments")
                    }
                }, maximumHeight: max(0, availableHeight - headerHeight))
            }
        }
        .backgroundPreferenceValue(AgentPromptApertureKey.self) { aperture in
            GeometryReader { geometry in
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geometry.size))
                    if !aperture.isEmpty { path.addRect(aperture) }
                }
                .fill(theme.agentPanelBg, style: FillStyle(eoFill: true))
            }
            .allowsHitTesting(false)
        }
        .coordinateSpace(name: "agentChat")
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { availableHeight = $0 }
    }

    private var lifecycleNotice: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            switch state.lifecycle {
            case .conversation:
                EmptyView()
            case .starting:
                Text("Starting Agent").font(.headline)
            case .failed(let reason):
                Text("Agent unavailable").font(.headline)
                Text(reason)
                if state.promptVisibleRows == 0 {
                    Text("Switch away from this tab and return to reopen the composer.")
                } else {
                    Text("Start a new Agent session (SPC a n).")
                }
            case .unavailable:
                Text("Agent unavailable").font(.headline)
                Text("Start a new Agent session (SPC a n), then reopen the conversation in Sessions.")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func childAction<ChildAction: Sendable>(_ translate: @escaping @Sendable (ChildAction) -> Action) -> ViewActionHandler<ChildAction>? {
        guard let sendAction else { return nil }
        return { action in sendAction(translate(action)) }
    }
}

/// The conversation transcript, the follow-output gating, and the Follow
/// output pill. Its body reads only transcript state, so chrome and composer
/// frames do not re-evaluate it.
struct AgentConversationList: View {
    let state: AgentChatState
    let sendAction: ViewActionHandler<AgentChatView.Action>?

    @Environment(\.themeColors) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.agentConversationListEvaluationProbe) private var evaluationProbe
    /// When true, auto-scroll is paused to let the user read earlier content.
    @State private var userHasScrolledUp: Bool = false
    @State private var position = ScrollPosition()
    /// Whether auto-scroll should follow streaming output.
    private var shouldAutoScroll: Bool { !userHasScrolledUp }

    var body: some View {
        let _ = evaluationProbe?.record()
        ZStack {
            ScrollView(.vertical) {
                LazyVStack(spacing: Spacing.lg) {
                    if state.transcriptTruncated {
                        olderMessagesOmittedIndicator
                    }

                    ForEach(Array(state.messages.enumerated()), id: \.element.id) { index, msg in
                        messageViewWithDivider(msg, index: index)
                    }

                }
                .padding(.horizontal, Spacing.xl)
                .padding(.top, Spacing.lg)
                .padding(.bottom, Spacing.xl)
            }
            .scrollPosition($position)
            // Open at the newest message, and sit a conversation shorter
            // than the pane directly above the composer.
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // User is "at bottom" if within 50pt of the bottom edge
                let atBottom = geometry.contentOffset.y + geometry.visibleRect.height >= geometry.contentSize.height - 50
                return atBottom
            } action: { _, isAtBottom in
                setScrolledUp(!isAtBottom)
            }
            .onChange(of: state.messages.count) { _, _ in
                if shouldAutoScroll {
                    scrollToBottom()
                }
            }
            .onChange(of: state.transcriptRevision) { _, _ in
                // A streaming frame can grow the last message without changing
                // the count, so follow every transcript revision during a turn.
                // Chrome and composer frames never advance the revision.
                if shouldAutoScroll && state.hasActiveTurn {
                    scrollToBottom()
                }
            }
            // Keep the latest-output action available after generation finishes.
            if userHasScrolledUp {
                VStack {
                    Spacer()
                    Button {
                        setScrolledUp(false)
                        scrollToBottom()
                    } label: {
                        followOutputPillLabel
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Follow output")
                    .accessibilityHint("Scrolls to latest content and resumes auto-scroll")
                    .padding(.bottom, Spacing.md)
                }
                .transition(.opacity)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.2),
                    value: userHasScrolledUp
                )
            }
        }
    }

    // MARK: - Messages
    private var olderMessagesOmittedIndicator: some View {
        Button {
            sendAction?(.executeCommand(name: "agent_retained_history"))
        } label: {
            Text("Browse earlier messages")
                .font(Typography.font(.small, weight: .medium))
                .foregroundStyle(theme.agentMutedFg)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)
                .background(Capsule().fill(theme.agentCodeBg.opacity(0.75)))
                .overlay(Capsule().strokeBorder(theme.agentCodeBorder.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(sendAction == nil)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityHint("Earlier session messages are outside the current display.")
    }


    /// Wraps each message with an optional divider in a single VStack.
    /// Keeping one view per ForEach iteration prevents LazyVStack from
    /// miscalculating tap targets due to variable-height implicit Groups.
    @ViewBuilder
    private func messageViewWithDivider(_ msg: ChatMessageEntry, index: Int) -> some View {
        VStack(spacing: Spacing.md) {
            if index > 0 && shouldShowDivider(before: msg, after: state.messages[index - 1]) {
                Rectangle()
                    .fill(theme.agentCodeBorder.opacity(0.15))
                    .frame(height: 1)
                    .padding(.horizontal, Spacing.xs)
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
            assistantMessage { assistantBlock(text) }
        case .styledAssistant(_, let lines):
            assistantMessage { styledAssistantBlock(lines) }
        case .assistantMarkdown(_, let blocks):
            assistantMessage { assistantMarkdownBlock(blocks) }
        case .thinking(_, let text, let collapsed):
            thinkingBlock(text, collapsed: collapsed)
        case .toolCall(let id, let name, let summary, let status, let isError, let collapsed, let autoApprovedScope, let duration, let result, _, let previewLines, let offer):
            AgentToolCallCard(messageID: id, name: name, summary: summary, status: status, isError: isError, collapsed: collapsed, autoApprovedScope: autoApprovedScope, durationMs: duration, result: result, resultLines: nil, previewLines: previewLines, retainedOutputOffer: offer, sendAction: toolCallAction)
        case .styledToolCall(let id, let name, let summary, let status, let isError, let collapsed, let autoApprovedScope, let duration, let resultLines, _, let previewLines, let offer):
            AgentToolCallCard(messageID: id, name: name, summary: summary, status: status, isError: isError, collapsed: collapsed, autoApprovedScope: autoApprovedScope, durationMs: duration, result: nil, resultLines: resultLines, previewLines: previewLines, retainedOutputOffer: offer, sendAction: toolCallAction)
        case .approvalToolCall(_, let name, let summary, let toolCallId, let sessionId, let requestId, let previewKind, let previewLines):
            AgentApprovalCard(name: name, summary: summary, toolCallId: toolCallId, sessionId: sessionId, requestId: requestId, previewKind: previewKind, previewLines: previewLines, sendAction: childAction { .toolApproval($0) })
        case .system(_, let text, let isError):
            systemMessage(text, isError: isError)
        case .usage(_, let input, let output, _, _, let costMicros):
            usageRow(input: input, output: output, costMicros: costMicros)
        }
    }

    private func assistantMessage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "sparkles")
                    .font(Typography.font(.micro))
                Text("Minga")
                    .font(Typography.font(.small, weight: .medium))
            }
            .foregroundStyle(theme.agentAssistantLabel)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Radius.lg)
                .fill(theme.agentAssistantBorder.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(theme.agentAssistantBorder.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Assistant reply")
    }

    @ViewBuilder
    private func userMessage(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            // Sender label
            HStack(spacing: Spacing.xs) {
                Image(systemName: "person.fill")
                    .font(Typography.font(.micro))
                Text("You")
                    .font(Typography.font(.small, weight: .medium))
            }
            .foregroundStyle(theme.agentUserLabel)

            Text(text)
                .font(Typography.font(.emphasis))
                .foregroundStyle(theme.agentTextFg)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .background(theme.agentUserBorder.opacity(0.06))
    }

    @ViewBuilder
    private func assistantBlock(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(Typography.font(.emphasis))
                .foregroundStyle(theme.agentTextFg)
                .textSelection(.enabled)
                .lineSpacing(4)
            Spacer(minLength: 40)
        }
    }

    @ViewBuilder
    private func styledAssistantBlock(_ lines: [[Wire.StyledTextRun]]) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, runs in
                    styledLineView(runs, baseFontSize: Typography.Step.emphasis.rawValue, monospaced: false)
                }
            }
            Spacer(minLength: 40)
        }
    }

    @ViewBuilder
    private func assistantMarkdownBlock(_ blocks: [Wire.AgentMarkdownBlock]) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Spacing.md) {
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
            markdownLines(block.lines, baseFontSize: Typography.Step.emphasis.rawValue, monospaced: false)
        case .heading:
            markdownLines(block.lines, baseFontSize: block.level == 1 ? Typography.Step.toolbar.rawValue : Typography.Step.title.rawValue, monospaced: false)
        case .listItem:
            markdownLines(block.lines, baseFontSize: Typography.Step.emphasis.rawValue, monospaced: false)
                .padding(.leading, CGFloat(block.indent) * Spacing.lg)
        case .blockquote:
            markdownLines(block.lines, baseFontSize: Typography.Step.emphasis.rawValue, monospaced: false)
                .padding(.leading, Spacing.md)
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
        VStack(alignment: .leading, spacing: Spacing.hairline) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, runs in
                styledLineView(runs, baseFontSize: baseFontSize, monospaced: monospaced)
            }
        }
    }

    @ViewBuilder
    private func agentCodeCard(_ block: Wire.AgentMarkdownBlock) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Text(block.label.isEmpty ? "Code" : block.label)
                    .font(Typography.font(.caption, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.agentTextFg.opacity(0.55))
                if !block.targetPath.isEmpty {
                    Text(block.targetPath)
                        .font(Typography.font(.caption, design: .monospaced))
                        .foregroundStyle(theme.agentTextFg.opacity(0.38))
                }
                if !block.isComplete {
                    Text("streaming")
                        .font(Typography.font(.caption, design: .monospaced))
                        .foregroundStyle(theme.agentTextFg.opacity(0.38))
                }
                Spacer(minLength: 0)
            }

            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    ForEach(Array(block.lines.enumerated()), id: \.offset) { _, runs in
                        styledLineView(runs, baseFontSize: Typography.Step.body.rawValue, monospaced: true, allowHorizontalScroll: false)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .padding(.vertical, Spacing.hairline)
            }
        }
        .padding(Spacing.md)
        .background(RoundedRectangle(cornerRadius: Radius.lg).fill(theme.agentCodeBg))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(theme.agentCodeBorder.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(codeBlockAccessibilityLabel(block))
        .accessibilityHint("Horizontally scrolls code content.")
    }

    private func codeBlockAccessibilityLabel(_ block: Wire.AgentMarkdownBlock) -> String {
        let language = block.label.isEmpty ? "Code" : block.label
        let state = block.isComplete ? "complete" : "streaming"
        return "Code block, \(language), \(block.lines.count) lines, \(state)"
    }

    private func styledLineView(_ runs: [Wire.StyledTextRun], baseFontSize: CGFloat, monospaced: Bool, allowHorizontalScroll: Bool = true) -> AgentStyledLine {
        AgentStyledLine(runs: runs, baseFontSize: baseFontSize, monospaced: monospaced, allowHorizontalScroll: allowHorizontalScroll)
    }

    @ViewBuilder
    private func thinkingBlock(_ text: String, collapsed: Bool) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(Typography.font(.micro))
                Text("Thinking...")
                    .font(Typography.font(.small, weight: .medium))
                Spacer()
            }
            .foregroundStyle(theme.agentTextFg.opacity(0.4))

            if !collapsed && !text.isEmpty {
                Text(text)
                    .font(Typography.font(.body))
                    .foregroundStyle(theme.agentTextFg.opacity(0.35))
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .padding(.leading, Spacing.lg)
            }
        }
    }

    @ViewBuilder
    private func systemMessage(_ text: String, isError: Bool) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: isError ? "exclamationmark.triangle" : "info.circle")
                .font(Typography.font(.caption))
            Text(text)
                .font(Typography.font(.small))
                .textSelection(.enabled)
        }
        .foregroundStyle(isError ? Color.red.opacity(0.7) : theme.agentTextFg.opacity(0.4))
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func usageRow(input: UInt32, output: UInt32, costMicros: UInt32) -> some View {
        HStack(spacing: Spacing.lg) {
            Spacer()
            Label("\(input)", systemImage: "arrow.up")
                .accessibilityLabel("\(input) input tokens")
            Label("\(output)", systemImage: "arrow.down")
                .accessibilityLabel("\(output) output tokens")
            if costMicros > 0 {
                let amount = reportedCost(costMicros)
                Text(amount)
                    .accessibilityLabel("Reported cost \(amount)")
            }
        }
        .font(Typography.font(.caption))
        .foregroundStyle(theme.agentTextFg.opacity(0.3))
    }

    private func reportedCost(_ micros: UInt32) -> String {
        let dollars = micros / 1_000_000
        var fraction = micros % 1_000_000
        var places: Int32 = 6
        while places > 2 && fraction.isMultiple(of: 10) {
            fraction /= 10
            places -= 1
        }
        return String(format: "$%u.%0*u", dollars, places, fraction)
    }

    // MARK: - Follow output pill

    @ViewBuilder
    private var followOutputPillLabel: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "arrow.down")
                .font(Typography.font(.caption, weight: .semibold))
            Text("Follow output")
                .font(Typography.font(.small, weight: .medium))
        }
        .foregroundStyle(theme.agentTextFg.opacity(0.8))
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
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
            sendAction?(.chatScrolledAwayFromBottom)
        } else {
            sendAction?(.chatReturnedToBottom)
        }
    }

    private var toolCallAction: ViewActionHandler<AgentToolCallCard.Action>? {
        childAction { action in
            switch action {
            case .toggle(let messageID): .agentToolToggle(messageID: messageID)
            case .readRetainedOutput(let messageID, let offer): .agentReadRetainedOutput(messageID: messageID, offer: offer)
            }
        }
    }

    private func childAction<ChildAction: Sendable>(_ translate: @escaping @Sendable (ChildAction) -> AgentChatView.Action) -> ViewActionHandler<ChildAction>? {
        guard let sendAction else { return nil }
        return { action in sendAction(translate(action)) }
    }

    /// Scrolls to the bottom edge with a short ease-out, or none under Reduce Motion.
    private func scrollToBottom() {
        let animation: Animation? = reduceMotion ? nil : .easeOut(duration: 0.15)
        withAnimation(animation) {
            position.scrollTo(edge: .bottom)
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
    AgentChatView(state: agentChatPreviewState(), isInsertMode: false, sendAction: { _ in })
        .frame(width: 760, height: 600)
}
