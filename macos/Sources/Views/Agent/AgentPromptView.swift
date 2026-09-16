import SwiftUI
import MingaProtocol
import CoreText

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

    /// Line height for the prompt font, derived from actual font metrics.
    private var promptLineHeight: CGFloat {
        let font = AgentPromptLineLayout.font
        return ceil(font.ascender - font.descender + font.leading)
    }

    /// Renders each prompt line and its cursor through one native text layout.
    /// The BEAM column remains a UTF-8 byte offset until the line resolves it to a glyph boundary.
    @ViewBuilder
    private var promptTextWithCursor: some View {
        let lines = state.prompt.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let cursorLine = Int(state.promptCursorLine)
        let cursorCol = Int(state.promptCursorCol)
        let isBlock = state.promptVimMode == 0 || state.promptVimMode >= 2
        let lineH = promptLineHeight

        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.prefix(8).enumerated()), id: \.offset) { lineIdx, line in
                AgentPromptLineView(
                    text: line,
                    cursorByteOffset: lineIdx == cursorLine && !isStreaming ? cursorCol : nil,
                    cursorShape: isBlock ? .block : .beam,
                    textColor: theme.agentTextFg.opacity(isStreaming ? 0.4 : 1.0),
                    cursorColor: theme.agentInputBorder.opacity(isBlock ? 0.7 : 1.0)
                )
                .frame(height: lineH)
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

enum AgentPromptCursorShape {
    case block
    case beam
}

struct AgentPromptCaretMetrics {
    let x: CGFloat
    let blockWidth: CGFloat
}

@MainActor struct AgentPromptLineLayout {
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    let line: CTLine
    let size: CGSize
    let baseline: CGFloat
    let caret: AgentPromptCaretMetrics?

    static func make(text: String, cursorByteOffset: Int?, textColor: NSColor) -> AgentPromptLineLayout {
        let displayText = text + " "
        let attributedText = NSAttributedString(string: displayText, attributes: [
            .font: font,
            .foregroundColor: textColor
        ])
        let line = CTLineCreateWithAttributedString(attributedText)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let height = ceil(ascent + descent + leading)
        let baseline = descent + leading / 2
        let caret = cursorByteOffset.flatMap { caretMetrics(text: text, displayLine: line, utf8ByteOffset: $0) }

        return AgentPromptLineLayout(
            line: line,
            size: CGSize(width: ceil(width), height: height),
            baseline: baseline,
            caret: caret
        )
    }

    static func caretMetrics(text: String, utf8ByteOffset: Int) -> AgentPromptCaretMetrics? {
        let displayText = text + " "
        let attributedText = NSAttributedString(string: displayText, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributedText)
        return caretMetrics(text: text, displayLine: line, utf8ByteOffset: utf8ByteOffset)
    }

    private static func caretMetrics(text: String, displayLine: CTLine, utf8ByteOffset: Int) -> AgentPromptCaretMetrics? {
        guard let stringIndex = stringIndex(in: text, utf8ByteOffset: utf8ByteOffset) else { return nil }
        let utf16Offset = stringIndex.utf16Offset(in: text)
        let nextUTF16Offset: Int

        if stringIndex == text.endIndex {
            nextUTF16Offset = utf16Offset + 1
        } else {
            nextUTF16Offset = text.index(after: stringIndex).utf16Offset(in: text)
        }

        let x = CTLineGetOffsetForStringIndex(displayLine, utf16Offset, nil)
        let nextX = CTLineGetOffsetForStringIndex(displayLine, nextUTF16Offset, nil)
        return AgentPromptCaretMetrics(x: x, blockWidth: max(nextX - x, 1))
    }

    private static func stringIndex(in text: String, utf8ByteOffset: Int) -> String.Index? {
        guard utf8ByteOffset >= 0 && utf8ByteOffset <= text.utf8.count else { return nil }
        let utf8Index = text.utf8.index(text.utf8.startIndex, offsetBy: utf8ByteOffset)
        return String.Index(utf8Index, within: text)
    }
}

private struct AgentPromptLineView: NSViewRepresentable {
    let text: String
    let cursorByteOffset: Int?
    let cursorShape: AgentPromptCursorShape
    let textColor: Color
    let cursorColor: Color

    func makeNSView(context: Context) -> AgentPromptLineNSView {
        let view = AgentPromptLineNSView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: AgentPromptLineNSView, context: Context) {
        update(nsView)
    }

    private func update(_ view: AgentPromptLineNSView) {
        view.update(
            text: text,
            cursorByteOffset: cursorByteOffset,
            cursorShape: cursorShape,
            textColor: Self.nsColor(textColor),
            cursorColor: Self.nsColor(cursorColor)
        )
    }

    private static func nsColor(_ color: Color) -> NSColor {
        NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
    }
}

final class AgentPromptLineNSView: NSView {
    private(set) var promptLayout = AgentPromptLineLayout.make(text: "", cursorByteOffset: nil, textColor: .textColor)
    private(set) var cursorShape = AgentPromptCursorShape.beam
    private(set) var cursorColor = NSColor.controlAccentColor

    override var acceptsFirstResponder: Bool { false }
    override var intrinsicContentSize: NSSize { promptLayout.size }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityElement(false)
    }

    func update(text: String, cursorByteOffset: Int?, cursorShape: AgentPromptCursorShape, textColor: NSColor, cursorColor: NSColor) {
        promptLayout = AgentPromptLineLayout.make(text: text, cursorByteOffset: cursorByteOffset, textColor: textColor)
        self.cursorShape = cursorShape
        self.cursorColor = cursorColor
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    func cursorRect() -> CGRect? {
        guard let caret = promptLayout.caret else { return nil }
        let width = cursorShape == .block ? caret.blockWidth : 1.5
        return CGRect(x: caret.x, y: 0, width: width, height: promptLayout.size.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.saveGState()
        if let cursorRect = cursorRect(), cursorShape == .block {
            context.setFillColor(cursorColor.cgColor)
            context.fill(cursorRect)
        }
        context.textPosition = CGPoint(x: 0, y: promptLayout.baseline)
        CTLineDraw(promptLayout.line, context)
        if let cursorRect = cursorRect(), cursorShape == .beam {
            context.setFillColor(cursorColor.cgColor)
            context.fill(cursorRect)
        }
        context.restoreGState()
    }
}
