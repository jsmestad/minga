import SwiftUI
import MingaProtocol

public struct AgentPromptView: View {
    public init(state: AgentChatState, isInsertMode: Bool, encoder: InputEncoder? = nil) {
        self.state = state
        self.isInsertMode = isInsertMode
        self.encoder = encoder
    }
    public let state: AgentChatState
    @Environment(\.themeColors) private var theme

    public let isInsertMode: Bool
    public let encoder: InputEncoder?

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
        if canSend { return theme.agentInputBorder }
        return theme.agentTextFg.opacity(0.2)
    }

    /// Capsule border color: accent when in insert mode, subtle border otherwise.
    private var capsuleBorderColor: Color {
        if isInsertMode { return theme.agentInputBorder.opacity(0.5) }
        return theme.agentCodeBorder.opacity(0.3)
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

    public var body: some View {
        VStack(spacing: 0) {
            // Prompt completion popup (floats above the prompt area)
            if let completion = state.promptCompletion {
                promptCompletionPopup(completion)
            }

            // Prompt area
            promptArea
        }
    }

    // MARK: - Prompt area

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
                        .foregroundStyle(theme.agentInputBorder)
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
                        .foregroundStyle(theme.agentInputPlaceholder)
                        .italic()
                } else if state.prompt.isEmpty && !isInsertMode {
                    Text("Ask anything...")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(theme.agentInputPlaceholder)
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
                .fill(theme.agentInputBg.opacity(capsuleBgOpacity))
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
                        .foregroundStyle(theme.agentTextFg.opacity(isStreaming ? 0.4 : 1.0))

                    if lineIdx == cursorLine && !isStreaming {
                        let cursorX = CGFloat(cursorCol) * charW

                        if isBlock {
                            Rectangle()
                                .fill(theme.agentInputBorder.opacity(0.7))
                                .frame(width: charW, height: lineH)
                                .offset(x: cursorX)
                        } else {
                            Rectangle()
                                .fill(theme.agentInputBorder)
                                .frame(width: 1.5, height: lineH)
                                .offset(x: cursorX)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Action button

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

    @ViewBuilder
    private func promptCompletionPopup(_ completion: Wire.PromptCompletion) -> some View {
        let isSlash = completion.type == 1

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(completion.candidates.enumerated()), id: \.offset) { index, candidate in
                HStack(spacing: 6) {
                    Image(systemName: isSlash ? "command" : "doc")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.agentTextFg.opacity(0.4))
                        .frame(width: 14)

                    Text(candidate.name)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.agentTextFg)
                        .lineLimit(1)

                    if !candidate.description.isEmpty {
                        Text(candidate.description)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.agentTextFg.opacity(0.4))
                            .lineLimit(1)
                    }

                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(index == Int(completion.selected) ? theme.agentInputBorder.opacity(0.15) : Color.clear)
            }
        }
        .frame(maxWidth: 400)
        .frame(maxHeight: CGFloat(completion.candidates.count) * 24)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.agentCodeBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(theme.agentCodeBorder.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 8, y: -4)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isSlash ? "Slash command completion" : "File mention completion")
    }
}
