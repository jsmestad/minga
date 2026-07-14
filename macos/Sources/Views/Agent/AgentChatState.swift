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

/// Value-semantic resident transcript used to validate and prepare a complete
/// frame before any GUI state is published.
public struct AgentTranscriptSnapshot {
    let messages: [ChatMessageEntry]
    let epoch: UInt32
    let hasTranscript: Bool
    let truncated: Bool
    let promptVersion: Int

    /// Exact retained payload weight of the resident transcript.
    public func exactResourceWeight() throws -> FrameResourceWeight {
        var weight = FrameResourceWeight(arrayEntries: messages.count)
        for message in messages {
            weight = try weight.adding(try FrameResourceWeight.measuringOwnedPayload(message))
        }
        return weight
    }

    /// Computes the exact resulting transcript weight without materializing mapped messages.
    public func resourceWeightAfterPreparing(
        mode: UInt8, epoch: UInt32, trimFront: Int, baseCount: Int,
        messages rawMessages: [Wire.ChatMessage]
    ) throws -> FrameResourceWeight {
        var weight: FrameResourceWeight
        if mode == 0 {
            weight = FrameResourceWeight(arrayEntries: rawMessages.count)
        } else {
            guard hasTranscript else { throw AgentTranscriptPreparationFailure.beforeSeed }
            guard epoch == self.epoch else { throw AgentTranscriptPreparationFailure.epochMismatch }
            guard trimFront >= 0, baseCount >= 0,
                  messages.count >= trimFront + baseCount else {
                throw AgentTranscriptPreparationFailure.desynced
            }
            weight = FrameResourceWeight(arrayEntries: baseCount + rawMessages.count)
            for message in messages[trimFront ..< (trimFront + baseCount)] {
                weight = try weight.adding(try FrameResourceWeight.measuringOwnedPayload(message))
            }
        }
        for message in rawMessages {
            weight = try weight.adding(try FrameResourceWeight.measuringOwnedPayload(message))
        }
        return weight
    }
}

/// Stable reason that a transcript operation cannot join the resident transcript snapshot.
public enum AgentTranscriptPreparationFailure: Error, Equatable {
    case beforeSeed
    case epochMismatch
    case desynced
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
    // private(set): the resident array must only change together with its epoch
    // bookkeeping (applyTranscript/update/hide/seed), never by direct assignment.
    public private(set) var messages: [ChatMessageEntry] = []

    /// Seeds the message list directly for previews and view tests. Production
    /// mutation goes through `applyTranscript`; this bypasses the epoch
    /// bookkeeping on purpose and must not be called on a live transcript.
    public func seed(messages: [ChatMessageEntry]) {
        self.messages = messages
    }

    /// Transcript epoch of the resident stream currently held in `messages` (0x86).
    /// A `full_replace` carrying a new epoch swaps the array wholesale and adopts
    /// the epoch; an `append` must match this epoch or it is dropped as stale.
    public private(set) var transcriptEpoch: UInt32 = 0

    /// Whether a `full_replace` has seeded the resident transcript. Appends before
    /// the first full_replace are dropped until a full_replace arrives.
    @ObservationIgnored private var hasTranscript: Bool = false

    /// True when older messages sit outside the resident byte-cap window (0x86
    /// `truncated` flag). A UI hint that the visible history is not the full session.
    public private(set) var transcriptTruncated: Bool = false

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

    /// Updates the chat chrome (visibility, status, model, prompt, help).
    ///
    /// Message content is no longer sourced here (#2654 slice 2): the resident
    /// transcript arrives on the 0x86 stream via `applyTranscript`. `rawMessages`
    /// is retained only as an optional seeding convenience for previews and tests;
    /// when nil (the live 0x78 path), `messages` is left untouched.
    public func update(visible: Bool, status: UInt8, model: String, thinkingLevel: String, prompt: String, promptLineCount: UInt8, promptCursorLine: UInt16, promptCursorCol: UInt16, promptVimMode: UInt8, promptVisibleRows: UInt8, promptCompletion: Wire.PromptCompletion?, helpVisible: Bool, helpGroups: [HelpGroup], rawMessages: [Wire.ChatMessage]? = nil) {
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
        if let rawMessages {
            self.messages = rawMessages.map(Self.mapMessage)
        }
    }

    /// Applies a resident transcript frame (0x86, #2654 slice 2).
    ///
    /// `mode` 0 = full_replace: swap the message array atomically and adopt the
    /// carried epoch (a session switch or structural change; the bottom-anchored
    /// view pins to the newest content, which is the right per-epoch reset).
    ///
    /// `mode` 1 = append: a front-eviction plus id-keyed suffix upsert. First
    /// `trimFront` messages are dropped from the FRONT of the resident store
    /// (resident byte-cap eviction). Then, over the remainder, the first
    /// `baseCount` messages stay put and everything past them is replaced by
    /// `rawMessages`. `baseCount` is the encoder's unchanged-leading (content-hash)
    /// prefix length over the remainder, NOT the client's resident count, so
    /// `baseCount < remainder.count` is the normal streaming in-place patch, not a
    /// dropped frame. Kept entries keep their stable `ChatMessageEntry.id`, so the
    /// `ForEach` diff preserves the reader's scroll position. A frame is dropped
    /// (await the next full_replace) only when it cannot be applied safely: before
    /// any full_replace, an epoch mismatch, or the remainder being shorter than
    /// `baseCount` (a genuinely dropped frame).
    /// Named outcome of one transcript frame, so drops are observable instead of a
    /// silent void return. The dropped cases are defense-in-depth: they are unreachable
    /// while the encoder's per-connection cache lifecycle holds (a fresh frontend
    /// connection starts from an empty `AgentTranscriptSentState`, so every epoch's
    /// first frame is a full_replace). If one ever fires, the transcript is frozen
    /// until the next full_replace — which is exactly why it must be loud.
    public enum TranscriptApplyOutcome: Equatable {
        case appliedFullReplace
        case appliedAppend
        /// An append arrived before any full_replace seeded the store.
        case droppedBeforeSeed
        /// An append carried a different epoch than the store holds.
        case droppedEpochMismatch
        /// The store is shorter than `trim_front + base_count` (GUI_PROTOCOL.md 0x86).
        case droppedDesynced
    }

    @discardableResult
    public func applyTranscript(mode: UInt8, epoch: UInt32, truncated: Bool = false, trimFront: Int = 0, baseCount: Int, messages rawMessages: [Wire.ChatMessage]) -> TranscriptApplyOutcome {
        switch Self.prepareTranscript(
            from: transcriptSnapshot,
            mode: mode,
            epoch: epoch,
            truncated: truncated,
            trimFront: trimFront,
            baseCount: baseCount,
            messages: rawMessages
        ) {
        case .success(let prepared):
            publishTranscript(prepared)
            return mode == 0 ? .appliedFullReplace : .appliedAppend
        case .failure(.beforeSeed):
            PortLogger.warn("transcript append before seed dropped (epoch \(epoch))")
            return .droppedBeforeSeed
        case .failure(.epochMismatch):
            PortLogger.warn("transcript append epoch mismatch dropped (frame \(epoch), store \(transcriptEpoch))")
            return .droppedEpochMismatch
        case .failure(.desynced):
            PortLogger.warn("transcript append desynced dropped (resident \(messages.count), trimFront \(trimFront), baseCount \(baseCount), epoch \(epoch))")
            return .droppedDesynced
        }
    }

    /// Captures the resident transcript as a value for frame-level validation.
    public var transcriptSnapshot: AgentTranscriptSnapshot {
        AgentTranscriptSnapshot(
            messages: messages,
            epoch: transcriptEpoch,
            hasTranscript: hasTranscript,
            truncated: transcriptTruncated,
            promptVersion: promptVersion
        )
    }

    /// Validates and applies one full or append transcript operation without mutating presented state.
    public static func prepareTranscript(
        from current: AgentTranscriptSnapshot,
        mode: UInt8,
        epoch: UInt32,
        truncated: Bool,
        trimFront: Int,
        baseCount: Int,
        messages rawMessages: [Wire.ChatMessage]
    ) -> Result<AgentTranscriptSnapshot, AgentTranscriptPreparationFailure> {
        let mapped = rawMessages.map(Self.mapMessage)
        if mode == 0 {
            return .success(AgentTranscriptSnapshot(
                messages: mapped,
                epoch: epoch,
                hasTranscript: true,
                truncated: truncated,
                promptVersion: current.promptVersion + 1
            ))
        }
        guard current.hasTranscript else { return .failure(.beforeSeed) }
        guard epoch == current.epoch else { return .failure(.epochMismatch) }
        guard trimFront >= 0,
              baseCount >= 0,
              current.messages.count >= trimFront + baseCount else {
            return .failure(.desynced)
        }
        let kept = current.messages[trimFront ..< (trimFront + baseCount)]
        return .success(AgentTranscriptSnapshot(
            messages: Array(kept) + mapped,
            epoch: current.epoch,
            hasTranscript: true,
            truncated: truncated,
            promptVersion: current.promptVersion + 1
        ))
    }

    /// Installs a transcript snapshot that was fully validated before frame publication.
    public func publishTranscript(_ snapshot: AgentTranscriptSnapshot) {
        messages = snapshot.messages
        transcriptEpoch = snapshot.epoch
        hasTranscript = snapshot.hasTranscript
        transcriptTruncated = snapshot.truncated
        promptVersion = snapshot.promptVersion
    }

    /// Maps a decoded wire message onto its displayable `ChatMessageEntry`.
    /// Shared by the transcript stream (0x86) and the preview/test seeding path.
    static func mapMessage(_ msg: Wire.ChatMessage) -> ChatMessageEntry {
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

    public func hide() {
        visible = false
        messages = []
        helpVisible = false
        helpGroups = []
        transcriptEpoch = 0
        hasTranscript = false
        transcriptTruncated = false
    }
}
