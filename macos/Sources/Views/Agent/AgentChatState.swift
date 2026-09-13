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

/// Deterministic work counters for transcript preparation.
public struct AgentTranscriptAccountingCounters: Sendable, Equatable {
    /// New or replacement entries measured reflectively for exact resource weight.
    public var changedEntriesMeasured = 0
    /// Unchanged resident entries visited while preparing a transcript operation.
    public var unchangedEntriesVisited = 0
    /// Unchanged resident entry values copied while preparing a transcript operation.
    public var retainedEntriesCopied = 0
    /// Persistent sequence nodes copied or created for bounded collection bookkeeping.
    public var sequenceNodesCreated = 0

    /// Creates zeroed counters.
    public init() {}

    /// Accumulates work across every transcript operation staged in one frame.
    public mutating func add(_ other: AgentTranscriptAccountingCounters) {
        changedEntriesMeasured += other.changedEntriesMeasured
        unchangedEntriesVisited += other.unchangedEntriesVisited
        retainedEntriesCopied += other.retainedEntriesCopied
        sequenceNodesCreated += other.sequenceNodesCreated
    }
}

private struct WeightedChatMessageEntry {
    let message: ChatMessageEntry
    let resourceWeight: FrameResourceWeight
}

private func addingKnownValid(
    _ left: FrameResourceWeight,
    _ right: FrameResourceWeight
) -> FrameResourceWeight {
    do {
        return try left.adding(right)
    } catch {
        preconditionFailure("validated transcript resource weight overflowed")
    }
}

/// Immutable node in the resident transcript's persistent implicit treap.
private final class AgentTranscriptNode {
    let entry: WeightedChatMessageEntry
    let priority: UInt64
    let left: AgentTranscriptNode?
    let right: AgentTranscriptNode?
    let count: Int
    let resourceWeight: FrameResourceWeight

    init(
        entry: WeightedChatMessageEntry,
        priority: UInt64,
        left: AgentTranscriptNode?,
        right: AgentTranscriptNode?
    ) {
        self.entry = entry
        self.priority = priority
        self.left = left
        self.right = right
        count = (left?.count ?? 0) + 1 + (right?.count ?? 0)
        resourceWeight = addingKnownValid(
            addingKnownValid(
                left?.resourceWeight ?? FrameResourceWeight(),
                entry.resourceWeight
            ),
            addingKnownValid(
                FrameResourceWeight(arrayEntries: 1),
                right?.resourceWeight ?? FrameResourceWeight()
            )
        )
    }
}

/// Read-only resident transcript entries with stable value semantics.
///
/// The underlying persistent tree lets transcript preparation retain unchanged
/// history without copying it. Integer indexes remain stable within a snapshot.
public struct AgentTranscriptMessages: BidirectionalCollection {
    public typealias Index = Int
    public typealias Element = ChatMessageEntry

    /// In-order iterator that visits each resident entry once.
    public struct Iterator: IteratorProtocol {
        private var stack: [AgentTranscriptNode] = []

        fileprivate init(root: AgentTranscriptNode?) {
            pushLeftSpine(root)
        }

        public mutating func next() -> ChatMessageEntry? {
            guard let node = stack.popLast() else { return nil }
            pushLeftSpine(node.right)
            return node.entry.message
        }

        private mutating func pushLeftSpine(_ root: AgentTranscriptNode?) {
            var node = root
            while let current = node {
                stack.append(current)
                node = current.left
            }
        }
    }

    fileprivate let root: AgentTranscriptNode?

    public var startIndex: Int { 0 }
    public var endIndex: Int { root?.count ?? 0 }
    public var count: Int { root?.count ?? 0 }

    public func index(after index: Int) -> Int { index + 1 }
    public func index(before index: Int) -> Int { index - 1 }

    public func makeIterator() -> Iterator { Iterator(root: root) }

    public subscript(index: Int) -> ChatMessageEntry {
        precondition(index >= startIndex && index < endIndex, "transcript index out of bounds")
        var remaining = index
        var node = root
        while let current = node {
            let leftCount = current.left?.count ?? 0
            if remaining < leftCount {
                node = current.left
            } else if remaining == leftCount {
                return current.entry.message
            } else {
                remaining -= leftCount + 1
                node = current.right
            }
        }
        preconditionFailure("valid transcript index was not present")
    }
}

private struct AgentTranscriptStore {
    private(set) var root: AgentTranscriptNode?
    private(set) var nextOrdinal: UInt64

    init() {
        root = nil
        nextOrdinal = 0
    }

    var count: Int { root?.count ?? 0 }
    var messages: AgentTranscriptMessages { AgentTranscriptMessages(root: root) }

    var resourceWeight: FrameResourceWeight { root?.resourceWeight ?? FrameResourceWeight() }

    static func replacingAll(
        _ messages: [ChatMessageEntry],
        counters: inout AgentTranscriptAccountingCounters
    ) throws -> AgentTranscriptStore {
        var store = AgentTranscriptStore()
        let entries = try measuredEntries(messages, counters: &counters)
        store.root = try store.build(entries, counters: &counters)
        return store
    }

    func replacingResidentRange(
        trimFront: Int,
        baseCount: Int,
        with messages: [ChatMessageEntry],
        counters: inout AgentTranscriptAccountingCounters
    ) throws -> AgentTranscriptStore {
        var ordinal = nextOrdinal
        var sequenceCounters = counters
        let (_, remainder) = Self.split(root, at: trimFront, counters: &sequenceCounters)
        let (kept, _) = Self.split(remainder, at: baseCount, counters: &sequenceCounters)
        let entries = try Self.measuredEntries(messages, counters: &sequenceCounters)

        var appendedWeight = FrameResourceWeight(arrayEntries: entries.count)
        for entry in entries {
            appendedWeight = try appendedWeight.adding(entry.resourceWeight)
        }
        _ = try (kept?.resourceWeight ?? FrameResourceWeight()).adding(appendedWeight)

        var appended: AgentTranscriptNode?
        for entry in entries {
            let node = Self.makeNode(
                entry: entry,
                priority: Self.priority(for: ordinal),
                left: nil,
                right: nil,
                counters: &sequenceCounters
            )
            appended = Self.merge(appended, node, counters: &sequenceCounters)
            ordinal &+= 1
        }

        let nextRoot = Self.merge(kept, appended, counters: &sequenceCounters)
        counters = sequenceCounters
        return AgentTranscriptStore(root: nextRoot, nextOrdinal: ordinal)
    }

    private init(root: AgentTranscriptNode?, nextOrdinal: UInt64) {
        self.root = root
        self.nextOrdinal = nextOrdinal
    }

    private mutating func build(
        _ entries: [WeightedChatMessageEntry],
        counters: inout AgentTranscriptAccountingCounters
    ) throws -> AgentTranscriptNode? {
        var payloadWeight = FrameResourceWeight(arrayEntries: entries.count)
        for entry in entries {
            payloadWeight = try payloadWeight.adding(entry.resourceWeight)
        }
        _ = payloadWeight

        var result: AgentTranscriptNode?
        for entry in entries {
            let node = Self.makeNode(
                entry: entry,
                priority: Self.priority(for: nextOrdinal),
                left: nil,
                right: nil,
                counters: &counters
            )
            result = Self.merge(result, node, counters: &counters)
            nextOrdinal &+= 1
        }
        return result
    }

    private static func measuredEntries(
        _ messages: [ChatMessageEntry],
        counters: inout AgentTranscriptAccountingCounters
    ) throws -> [WeightedChatMessageEntry] {
        var entries: [WeightedChatMessageEntry] = []
        entries.reserveCapacity(messages.count)
        for message in messages {
            entries.append(WeightedChatMessageEntry(
                message: message,
                resourceWeight: try FrameResourceWeight.measuringOwnedPayload(message)
            ))
            counters.changedEntriesMeasured += 1
        }
        return entries
    }

    private static func makeNode(
        entry: WeightedChatMessageEntry,
        priority: UInt64,
        left: AgentTranscriptNode?,
        right: AgentTranscriptNode?,
        counters: inout AgentTranscriptAccountingCounters
    ) -> AgentTranscriptNode {
        counters.sequenceNodesCreated += 1
        return AgentTranscriptNode(
            entry: entry, priority: priority, left: left, right: right
        )
    }

    private static func split(
        _ node: AgentTranscriptNode?,
        at index: Int,
        counters: inout AgentTranscriptAccountingCounters
    ) -> (AgentTranscriptNode?, AgentTranscriptNode?) {
        guard let node else { return (nil, nil) }
        let leftCount = node.left?.count ?? 0
        if index <= leftCount {
            let (before, after) = split(node.left, at: index, counters: &counters)
            return (
                before,
                makeNode(
                    entry: node.entry, priority: node.priority,
                    left: after, right: node.right, counters: &counters
                )
            )
        }
        let (before, after) = split(
            node.right, at: index - leftCount - 1, counters: &counters
        )
        return (
            makeNode(
                entry: node.entry, priority: node.priority,
                left: node.left, right: before, counters: &counters
            ),
            after
        )
    }

    private static func merge(
        _ left: AgentTranscriptNode?,
        _ right: AgentTranscriptNode?,
        counters: inout AgentTranscriptAccountingCounters
    ) -> AgentTranscriptNode? {
        guard let left else { return right }
        guard let right else { return left }
        if left.priority <= right.priority {
            return makeNode(
                entry: left.entry, priority: left.priority, left: left.left,
                right: merge(left.right, right, counters: &counters), counters: &counters
            )
        }
        return makeNode(
            entry: right.entry, priority: right.priority,
            left: merge(left, right.left, counters: &counters), right: right.right,
            counters: &counters
        )
    }

    private static func priority(for ordinal: UInt64) -> UInt64 {
        var value = ordinal &+ 0x9E37_79B9_7F4A_7C15
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
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
    fileprivate let store: AgentTranscriptStore
    let epoch: UInt32
    let hasTranscript: Bool
    let truncated: Bool
    let promptVersion: Int
    /// Work performed to prepare the operation that created this snapshot.
    public let accountingCounters: AgentTranscriptAccountingCounters

    /// Resident messages in presentation order.
    public var messages: AgentTranscriptMessages { store.messages }

    /// Exact retained payload weight, including the top-level transcript collection.
    public var resourceWeight: FrameResourceWeight { store.resourceWeight }

    fileprivate init(
        store: AgentTranscriptStore,
        epoch: UInt32,
        hasTranscript: Bool,
        truncated: Bool,
        promptVersion: Int,
        accountingCounters: AgentTranscriptAccountingCounters
    ) {
        self.store = store
        self.epoch = epoch
        self.hasTranscript = hasTranscript
        self.truncated = truncated
        self.promptVersion = promptVersion
        self.accountingCounters = accountingCounters
    }

    fileprivate static func seeded(
        messages: [ChatMessageEntry],
        epoch: UInt32 = 0,
        hasTranscript: Bool = false,
        truncated: Bool = false,
        promptVersion: Int = 0
    ) throws -> AgentTranscriptSnapshot {
        var counters = AgentTranscriptAccountingCounters()
        let store = try AgentTranscriptStore.replacingAll(messages, counters: &counters)
        return AgentTranscriptSnapshot(
            store: store,
            epoch: epoch,
            hasTranscript: hasTranscript,
            truncated: truncated,
            promptVersion: promptVersion,
            accountingCounters: counters
        )
    }

    fileprivate func withPromptVersion(_ promptVersion: Int) -> AgentTranscriptSnapshot {
        AgentTranscriptSnapshot(
            store: store,
            epoch: epoch,
            hasTranscript: hasTranscript,
            truncated: truncated,
            promptVersion: promptVersion,
            accountingCounters: accountingCounters
        )
    }
}

/// Stable reason that a transcript operation cannot join the resident transcript snapshot.
public enum AgentTranscriptPreparationFailure: Error, Equatable {
    case beforeSeed
    case epochMismatch
    case desynced
    case resourcePolicy
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
        do {
            transcriptSnapshotStorage = try AgentTranscriptSnapshot.seeded(
                messages: messages,
                promptVersion: promptVersion
            )
        } catch {
            preconditionFailure("preview transcript resource accounting overflowed")
        }
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
    // The resident sequence, epoch, truncation, and exact weight are one value.
    // Publishing swaps that value only after the complete frame is accepted.
    private var transcriptSnapshotStorage: AgentTranscriptSnapshot

    /// Resident transcript entries in presentation order.
    public var messages: AgentTranscriptMessages { transcriptSnapshotStorage.messages }

    /// Seeds the message list directly for previews and view tests. Production
    /// mutation goes through `applyTranscript`; this bypasses the epoch
    /// bookkeeping on purpose and must not be called on a live transcript.
    public func seed(messages: [ChatMessageEntry]) {
        do {
            transcriptSnapshotStorage = try AgentTranscriptSnapshot.seeded(
                messages: messages,
                promptVersion: promptVersion
            )
        } catch {
            preconditionFailure("preview transcript resource accounting overflowed")
        }
    }

    /// Transcript epoch of the resident stream currently held in `messages` (0x86).
    /// A `full_replace` carrying a new epoch swaps the array wholesale and adopts
    /// the epoch; an `append` must match this epoch or it is dropped as stale.
    public var transcriptEpoch: UInt32 { transcriptSnapshotStorage.epoch }

    /// Whether a `full_replace` has seeded the resident transcript. Appends before
    /// the first full_replace are dropped until a full_replace arrives.
    private var hasTranscript: Bool {
        transcriptSnapshotStorage.hasTranscript
    }

    /// True when older messages sit outside the resident byte-cap window (0x86
    /// `truncated` flag). A UI hint that the visible history is not the full session.
    public var transcriptTruncated: Bool { transcriptSnapshotStorage.truncated }

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
    /// Message content is sourced from the resident 0x86 stream via `applyTranscript`.
    public func update(visible: Bool, status: UInt8, model: String, thinkingLevel: String, prompt: String, promptLineCount: UInt8, promptCursorLine: UInt16, promptCursorCol: UInt16, promptVimMode: UInt8, promptVisibleRows: UInt8, promptCompletion: Wire.PromptCompletion?, helpVisible: Bool, helpGroups: [HelpGroup]) {
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
    /// the streamed messages. `baseCount` is the encoder's unchanged-leading (content-hash)
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
        /// Exact resource accounting overflowed while preparing the operation.
        case droppedResourcePolicy
    }

    @discardableResult
    public func applyTranscript(mode: UInt8, epoch: UInt32, truncated: Bool = false, trimFront: Int = 0, baseCount: Int, messages transcriptMessages: [Wire.ChatMessage]) -> TranscriptApplyOutcome {
        switch Self.prepareTranscript(
            from: transcriptSnapshot,
            mode: mode,
            epoch: epoch,
            truncated: truncated,
            trimFront: trimFront,
            baseCount: baseCount,
            messages: transcriptMessages
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
        case .failure(.resourcePolicy):
            PortLogger.error("transcript resource accounting failed (epoch \(epoch))")
            return .droppedResourcePolicy
        }
    }

    /// Captures the resident transcript as a value for frame-level validation.
    public var transcriptSnapshot: AgentTranscriptSnapshot {
        transcriptSnapshotStorage.withPromptVersion(promptVersion)
    }

    /// Validates and applies one full or append transcript operation without mutating presented state.
    public static func prepareTranscript(
        from current: AgentTranscriptSnapshot,
        mode: UInt8,
        epoch: UInt32,
        truncated: Bool,
        trimFront: Int,
        baseCount: Int,
        messages transcriptMessages: [Wire.ChatMessage]
    ) -> Result<AgentTranscriptSnapshot, AgentTranscriptPreparationFailure> {
        var counters = AgentTranscriptAccountingCounters()
        if mode == 0 {
            do {
                let mapped = transcriptMessages.map(Self.mapMessage)
                let store = try AgentTranscriptStore.replacingAll(mapped, counters: &counters)
                return .success(AgentTranscriptSnapshot(
                    store: store,
                    epoch: epoch,
                    hasTranscript: true,
                    truncated: truncated,
                    promptVersion: current.promptVersion + 1,
                    accountingCounters: counters
                ))
            } catch {
                return .failure(.resourcePolicy)
            }
        }
        guard current.hasTranscript else { return .failure(.beforeSeed) }
        guard epoch == current.epoch else { return .failure(.epochMismatch) }
        guard trimFront >= 0,
              baseCount >= 0,
              current.messages.count >= trimFront + baseCount else {
            return .failure(.desynced)
        }
        do {
            let mapped = transcriptMessages.map(Self.mapMessage)
            let store = try current.store.replacingResidentRange(
                trimFront: trimFront,
                baseCount: baseCount,
                with: mapped,
                counters: &counters
            )
            return .success(AgentTranscriptSnapshot(
                store: store,
                epoch: current.epoch,
                hasTranscript: true,
                truncated: truncated,
                promptVersion: current.promptVersion + 1,
                accountingCounters: counters
            ))
        } catch {
            return .failure(.resourcePolicy)
        }
    }

    /// Installs a transcript snapshot that was fully validated before frame publication.
    public func publishTranscript(_ snapshot: AgentTranscriptSnapshot) {
        transcriptSnapshotStorage = snapshot
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
        helpVisible = false
        helpGroups = []
        do {
            transcriptSnapshotStorage = try AgentTranscriptSnapshot.seeded(
                messages: [],
                promptVersion: promptVersion
            )
        } catch {
            preconditionFailure("empty transcript resource accounting overflowed")
        }
    }
}
