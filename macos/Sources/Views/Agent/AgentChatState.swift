/// Observable agent chat state driven by BEAM gui_agent_chat messages.

import SwiftUI
import MingaProtocol

/// A displayable chat message for SwiftUI rendering.
public enum ChatMessageEntry: Identifiable {
    case user(id: Int, text: String)
    case assistant(id: Int, text: String)
    /// Assistant message with pre-styled text runs from the BEAM (tree-sitter or markdown parser).
    case styledAssistant(id: Int, lines: [[Wire.StyledTextRun]])
    /// Assistant message with BEAM-authored semantic markdown blocks.
    case assistantMarkdown(id: Int, blocks: [Wire.AgentMarkdownBlock])
    case thinking(id: Int, text: String, collapsed: Bool)
    case toolCall(id: Int, name: String, summary: String, status: UInt8, isError: Bool, collapsed: Bool, autoApprovedScope: UInt8, durationMs: UInt32, result: String, previewKind: UInt8, previewLines: [String])
    case styledToolCall(id: Int, name: String, summary: String, status: UInt8, isError: Bool, collapsed: Bool, autoApprovedScope: UInt8, durationMs: UInt32, resultLines: [[Wire.StyledTextRun]], previewKind: UInt8, previewLines: [String])
    case approvalToolCall(id: Int, name: String, summary: String, toolCallId: String, previewKind: UInt8, previewLines: [String])
    case system(id: Int, text: String, isError: Bool)
    case usage(id: Int, input: UInt32, output: UInt32, cacheRead: UInt32, cacheWrite: UInt32, costMicros: UInt32)

    public var id: Int {
        switch self {
        case .user(let id, _), .assistant(let id, _), .styledAssistant(let id, _),
             .assistantMarkdown(let id, _),
             .thinking(let id, _, _),
             .toolCall(let id, _, _, _, _, _, _, _, _, _, _),
             .styledToolCall(let id, _, _, _, _, _, _, _, _, _, _),
             .approvalToolCall(let id, _, _, _, _, _),
             .system(let id, _, _),
             .usage(let id, _, _, _, _, _):
            return id
        }
    }
}

/// A group of keybindings for the help overlay cheatsheet.
public struct HelpGroup: Identifiable {
    public init(title: String, bindings: [(key: String, description: String)]) {
        self.title = title
        self.bindings = bindings
    }
    public let title: String
    public let bindings: [(key: String, description: String)]

    public var id: String { title }
}

@MainActor
@Observable
public final class AgentChatState {
    public init(visible: Bool = false, status: UInt8 = 0, model: String = "", thinkingLevel: String = "medium", prompt: String = "", messages: [ChatMessageEntry] = [], helpVisible: Bool = false, helpGroups: [HelpGroup] = [], promptVersion: Int = 0, promptLineCount: UInt8 = 1, promptCursorLine: UInt16 = 0, promptCursorCol: UInt16 = 0, promptVimMode: UInt8 = 0, promptVisibleRows: UInt8 = 1, promptCompletion: Wire.PromptCompletion? = nil) {
        self.visible = visible
        self.status = status
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.prompt = prompt
        self.messages = messages
        self.helpVisible = helpVisible
        self.helpGroups = helpGroups
        self.promptVersion = promptVersion
        self.promptLineCount = promptLineCount
        self.promptCursorLine = promptCursorLine
        self.promptCursorCol = promptCursorCol
        self.promptVimMode = promptVimMode
        self.promptVisibleRows = promptVisibleRows
        self.promptCompletion = promptCompletion
    }
    public var visible: Bool = false
    public var status: UInt8 = 0
    public var model: String = ""
    public var thinkingLevel: String = "medium"
    public var prompt: String = ""
    public var messages: [ChatMessageEntry] = []
    public var helpVisible: Bool = false
    public var helpGroups: [HelpGroup] = []

    /// Monotonically increasing counter for change detection.
    /// Increments on every update() so SwiftUI observers detect frame changes.
    public var promptVersion: Int = 0

    // ── Prompt cell-grid metadata (for Metal rendering) ──

    /// Number of logical lines in the prompt buffer.
    public var promptLineCount: UInt8 = 1
    /// Cursor row within the prompt buffer.
    public var promptCursorLine: UInt16 = 0
    /// Cursor column within the prompt buffer.
    public var promptCursorCol: UInt16 = 0
    /// Vim mode: 0=normal, 1=insert, 2=visual, 3=visual_line, 4=operator_pending.
    public var promptVimMode: UInt8 = 0
    /// Number of visible rows in the prompt (after wrapping, clamped to max).
    public var promptVisibleRows: UInt8 = 1

    /// Whether the prompt is in insert mode (for SwiftUI styling).
    public var isPromptInsertMode: Bool { promptVimMode == 1 }

    // ── Prompt completion popup ──

    /// Active completion popup for @-mention or /slash commands. Nil when no popup is showing.
    public var promptCompletion: Wire.PromptCompletion?

    public var statusLabel: String {
        switch status {
        case 0: return "idle"
        case 1: return "thinking"
        case 2: return "running tool"
        case 3: return "error"
        default: return "idle"
        }
    }

    public var isThinking: Bool { status == 1 || status == 2 }

    public var displayModel: String {
        guard let separator = model.firstIndex(of: ":") else { return model }
        return String(model[model.index(after: separator)...])
    }

    public var thinkingLabel: String {
        switch thinkingLevel {
        case "off": return "Off"
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        default: return thinkingLevel.isEmpty ? "Off" : thinkingLevel.capitalized
        }
    }

    public var thinkingIconName: String {
        switch thinkingLevel {
        case "medium": return "brain.head.profile"
        case "high": return "brain.head.profile.fill"
        default: return "brain"
        }
    }

    public func update(visible: Bool, status: UInt8, model: String, thinkingLevel: String, prompt: String, promptLineCount: UInt8, promptCursorLine: UInt16, promptCursorCol: UInt16, promptVimMode: UInt8, promptVisibleRows: UInt8, promptCompletion: Wire.PromptCompletion?, helpVisible: Bool, helpGroups: [HelpGroup], rawMessages: [Wire.ChatMessage]) {
        self.visible = visible
        self.status = status
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.prompt = prompt
        self.promptLineCount = promptLineCount
        self.promptCursorLine = promptCursorLine
        self.promptCursorCol = promptCursorCol
        self.promptVimMode = promptVimMode
        self.promptVisibleRows = promptVisibleRows
        self.promptCompletion = promptCompletion
        self.promptVersion += 1
        self.helpVisible = helpVisible
        self.helpGroups = helpGroups
        self.messages = rawMessages.map { msg in
            let id = Int(msg.beamId)
            switch msg.content {
            case .user(let text):
                return .user(id: id, text: text)
            case .assistant(let text):
                return .assistant(id: id, text: text)
            case .styledAssistant(let lines):
                return .styledAssistant(id: id, lines: lines)
            case .assistantMarkdown(let blocks):
                return .assistantMarkdown(id: id, blocks: blocks)
            case .thinking(let text, let collapsed):
                return .thinking(id: id, text: text, collapsed: collapsed)
            case .toolCall(let name, let summary, let st, let isError, let collapsed, let autoApprovedScope, let duration, let result, let previewKind, let previewLines):
                return .toolCall(id: id, name: name, summary: summary, status: st, isError: isError, collapsed: collapsed, autoApprovedScope: autoApprovedScope, durationMs: duration, result: result, previewKind: previewKind, previewLines: previewLines)
            case .styledToolCall(let name, let summary, let st, let isError, let collapsed, let autoApprovedScope, let duration, let resultLines, let previewKind, let previewLines):
                return .styledToolCall(id: id, name: name, summary: summary, status: st, isError: isError, collapsed: collapsed, autoApprovedScope: autoApprovedScope, durationMs: duration, resultLines: resultLines, previewKind: previewKind, previewLines: previewLines)
            case .approvalToolCall(let name, let summary, let toolCallId, let previewKind, let previewLines):
                return .approvalToolCall(id: id, name: name, summary: summary, toolCallId: toolCallId, previewKind: previewKind, previewLines: previewLines)
            case .system(let text, let isError):
                return .system(id: id, text: text, isError: isError)
            case .usage(let inp, let outp, let cacheR, let cacheW, let costM):
                return .usage(id: id, input: inp, output: outp, cacheRead: cacheR, cacheWrite: cacheW, costMicros: costM)
            }
        }
    }

    public func hide() {
        visible = false
        messages = []
        helpVisible = false
        helpGroups = []
    }
}
