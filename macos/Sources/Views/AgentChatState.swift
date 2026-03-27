/// Observable agent chat state driven by BEAM gui_agent_chat messages.

import SwiftUI

/// A displayable chat message for SwiftUI rendering.
enum ChatMessageEntry: Identifiable {
    case user(id: Int, text: String)
    case assistant(id: Int, text: String)
    /// Assistant message with pre-styled text runs from the BEAM (tree-sitter or markdown parser).
    case styledAssistant(id: Int, lines: [[StyledTextRun]])
    case thinking(id: Int, text: String, collapsed: Bool)
    case toolCall(id: Int, name: String, summary: String, status: UInt8, isError: Bool, collapsed: Bool, durationMs: UInt32, result: String)
    case styledToolCall(id: Int, name: String, summary: String, status: UInt8, isError: Bool, collapsed: Bool, durationMs: UInt32, resultLines: [[StyledTextRun]])
    case system(id: Int, text: String, isError: Bool)
    case usage(id: Int, input: UInt32, output: UInt32, cacheRead: UInt32, cacheWrite: UInt32, costMicros: UInt32)

    var id: Int {
        switch self {
        case .user(let id, _), .assistant(let id, _), .styledAssistant(let id, _),
             .thinking(let id, _, _),
             .toolCall(let id, _, _, _, _, _, _, _),
             .styledToolCall(let id, _, _, _, _, _, _, _),
             .system(let id, _, _),
             .usage(let id, _, _, _, _, _):
            return id
        }
    }
}

/// A group of keybindings for the help overlay cheatsheet.
struct HelpGroup: Identifiable {
    let title: String
    let bindings: [(key: String, description: String)]

    var id: String { title }
}

@MainActor
@Observable
final class AgentChatState {
    var visible: Bool = false
    var status: UInt8 = 0
    var model: String = ""
    var prompt: String = ""
    var messages: [ChatMessageEntry] = []
    var pendingApproval: PendingApproval?
    var helpVisible: Bool = false
    var helpGroups: [HelpGroup] = []

    /// Monotonically increasing counter for change detection.
    /// Increments on every update() so SwiftUI observers detect frame changes.
    var promptVersion: Int = 0

    // ── Prompt cell-grid metadata (for Metal rendering) ──

    /// Number of logical lines in the prompt buffer.
    var promptLineCount: UInt8 = 1
    /// Cursor row within the prompt buffer.
    var promptCursorLine: UInt16 = 0
    /// Cursor column within the prompt buffer.
    var promptCursorCol: UInt16 = 0
    /// Vim mode: 0=normal, 1=insert, 2=visual, 3=visual_line, 4=operator_pending.
    var promptVimMode: UInt8 = 0
    /// Number of visible rows in the prompt (after wrapping, clamped to max).
    var promptVisibleRows: UInt8 = 1

    /// Whether the prompt is in insert mode (for SwiftUI styling).
    var isPromptInsertMode: Bool { promptVimMode == 1 }

    struct PendingApproval {
        let toolName: String
        let summary: String
    }

    var statusLabel: String {
        switch status {
        case 0: return "idle"
        case 1: return "thinking"
        case 2: return "running tool"
        case 3: return "error"
        default: return "idle"
        }
    }

    var isThinking: Bool { status == 1 || status == 2 }

    func update(visible: Bool, status: UInt8, model: String, prompt: String, promptLineCount: UInt8, promptCursorLine: UInt16, promptCursorCol: UInt16, promptVimMode: UInt8, promptVisibleRows: UInt8, pendingToolName: String?, pendingToolSummary: String, helpVisible: Bool, helpGroups: [HelpGroup], rawMessages: [GUIChatMessage]) {
        self.visible = visible
        self.status = status
        self.model = model
        self.prompt = prompt
        self.promptLineCount = promptLineCount
        self.promptCursorLine = promptCursorLine
        self.promptCursorCol = promptCursorCol
        self.promptVimMode = promptVimMode
        self.promptVisibleRows = promptVisibleRows
        self.promptVersion += 1
        self.pendingApproval = pendingToolName.map { PendingApproval(toolName: $0, summary: pendingToolSummary) }
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
            case .thinking(let text, let collapsed):
                return .thinking(id: id, text: text, collapsed: collapsed)
            case .toolCall(let name, let summary, let st, let isError, let collapsed, let duration, let result):
                return .toolCall(id: id, name: name, summary: summary, status: st, isError: isError, collapsed: collapsed, durationMs: duration, result: result)
            case .styledToolCall(let name, let summary, let st, let isError, let collapsed, let duration, let resultLines):
                return .styledToolCall(id: id, name: name, summary: summary, status: st, isError: isError, collapsed: collapsed, durationMs: duration, resultLines: resultLines)
            case .system(let text, let isError):
                return .system(id: id, text: text, isError: isError)
            case .usage(let inp, let outp, let cacheR, let cacheW, let costM):
                return .usage(id: id, input: inp, output: outp, cacheRead: cacheR, cacheWrite: cacheW, costMicros: costM)
            }
        }
    }

    func hide() {
        visible = false
        messages = []
        helpVisible = false
        helpGroups = []
    }
}
