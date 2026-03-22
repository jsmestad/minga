/// Observable agent chat state driven by BEAM gui_agent_chat messages.

import SwiftUI

/// A displayable chat message for SwiftUI rendering.
enum ChatMessageEntry: Identifiable {
    case user(id: Int, text: String)
    case assistant(id: Int, text: String)
    /// Assistant message with pre-styled text runs from the BEAM (tree-sitter or markdown parser).
    case styledAssistant(id: Int, lines: [[StyledTextRun]])
    case thinking(id: Int, text: String, collapsed: Bool)
    case toolCall(id: Int, name: String, status: UInt8, isError: Bool, collapsed: Bool, durationMs: UInt32, result: String)
    case styledToolCall(id: Int, name: String, status: UInt8, isError: Bool, collapsed: Bool, durationMs: UInt32, resultLines: [[StyledTextRun]])
    case system(id: Int, text: String, isError: Bool)
    case usage(id: Int, input: UInt32, output: UInt32, cacheRead: UInt32, cacheWrite: UInt32, costMicros: UInt32)

    var id: Int {
        switch self {
        case .user(let id, _), .assistant(let id, _), .styledAssistant(let id, _),
             .thinking(let id, _, _),
             .toolCall(let id, _, _, _, _, _, _),
             .styledToolCall(let id, _, _, _, _, _, _),
             .system(let id, _, _),
             .usage(let id, _, _, _, _, _):
            return id
        }
    }
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

    /// Monotonically increasing counter for BlinkingCursor reset token.
    /// Increments on every update() so the cursor resets on each BEAM frame.
    var promptVersion: Int = 0

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

    func update(visible: Bool, status: UInt8, model: String, prompt: String, pendingToolName: String?, pendingToolSummary: String, rawMessages: [GUIChatMessage]) {
        self.visible = visible
        self.status = status
        self.model = model
        self.prompt = prompt
        self.promptVersion += 1
        self.pendingApproval = pendingToolName.map { PendingApproval(toolName: $0, summary: pendingToolSummary) }
        self.messages = rawMessages.enumerated().map { i, msg in
            switch msg {
            case .user(let text):
                return .user(id: i, text: text)
            case .assistant(let text):
                return .assistant(id: i, text: text)
            case .styledAssistant(let lines):
                return .styledAssistant(id: i, lines: lines)
            case .thinking(let text, let collapsed):
                return .thinking(id: i, text: text, collapsed: collapsed)
            case .toolCall(let name, let st, let isError, let collapsed, let duration, let result):
                return .toolCall(id: i, name: name, status: st, isError: isError, collapsed: collapsed, durationMs: duration, result: result)
            case .styledToolCall(let name, let st, let isError, let collapsed, let duration, let resultLines):
                return .styledToolCall(id: i, name: name, status: st, isError: isError, collapsed: collapsed, durationMs: duration, resultLines: resultLines)
            case .system(let text, let isError):
                return .system(id: i, text: text, isError: isError)
            case .usage(let inp, let outp, let cacheR, let cacheW, let costM):
                return .usage(id: i, input: inp, output: outp, cacheRead: cacheR, cacheWrite: cacheW, costMicros: costM)
            }
        }
    }

    func hide() {
        visible = false
        messages = []
    }
}
