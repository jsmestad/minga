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
    case toolCall(id: Int, name: String, summary: String, status: UInt8, isError: Bool, collapsed: Bool, autoApprovedScope: UInt8, durationMs: UInt32, result: String, previewKind: UInt8, previewLines: [String], retainedOutputOffer: Wire.RetainedOutputOffer? = nil)
    case styledToolCall(id: Int, name: String, summary: String, status: UInt8, isError: Bool, collapsed: Bool, autoApprovedScope: UInt8, durationMs: UInt32, resultLines: [[Wire.StyledTextRun]], previewKind: UInt8, previewLines: [String], retainedOutputOffer: Wire.RetainedOutputOffer? = nil)
    case approvalToolCall(id: Int, name: String, summary: String, toolCallId: String, sessionId: String, requestId: String, previewKind: UInt8, previewLines: [String])
    case system(id: Int, text: String, isError: Bool)
    case usage(id: Int, input: UInt32, output: UInt32, cacheRead: UInt32, cacheWrite: UInt32, costMicros: UInt32)

    public var id: Int {
        switch self {
        case .user(let id, _), .assistant(let id, _), .styledAssistant(let id, _),
             .assistantMarkdown(let id, _),
             .thinking(let id, _, _),
             .toolCall(let id, _, _, _, _, _, _, _, _, _, _, _),
             .styledToolCall(let id, _, _, _, _, _, _, _, _, _, _, _),
             .approvalToolCall(let id, _, _, _, _, _, _, _),
             .system(let id, _, _),
             .usage(let id, _, _, _, _, _):
            return id
        }
    }

    /// Exact owned-payload weight of this entry, measured from its typed fields. Equals `FrameResourceWeight.measuringOwnedPayload(self)` without reflection: integers, flags, and the retained-output offer own no payload.
    public func resourceWeight() throws -> FrameResourceWeight {
        var tally = FrameOwnedPayloadTally()
        switch self {
        case .user(_, let text), .assistant(_, let text), .thinking(_, let text, _), .system(_, let text, _):
            try tally.add(text)
        case .styledAssistant(_, let lines):
            try Wire.StyledTextRun.measureOwnedPayload(lines: lines, into: &tally)
        case .assistantMarkdown(_, let blocks):
            try tally.addEntries(blocks.count)
            for block in blocks { try block.measureOwnedPayload(into: &tally) }
        case .toolCall(_, let name, let summary, _, _, _, _, _, let result, _, let previewLines, _):
            try tally.add(name)
            try tally.add(summary)
            try tally.add(result)
            try tally.add(previewLines)
        case .styledToolCall(_, let name, let summary, _, _, _, _, _, let resultLines, _, let previewLines, _):
            try tally.add(name)
            try tally.add(summary)
            try Wire.StyledTextRun.measureOwnedPayload(lines: resultLines, into: &tally)
            try tally.add(previewLines)
        case .approvalToolCall(_, let name, let summary, let toolCallId, let sessionId, let requestId, _, let previewLines):
            try tally.add(name)
            try tally.add(summary)
            try tally.add(toolCallId)
            try tally.add(sessionId)
            try tally.add(requestId)
            try tally.add(previewLines)
        case .usage:
            break
        }
        return tally.weight
    }
}

/// Deterministic work counters for transcript preparation.
public struct AgentTranscriptAccountingCounters: Sendable, Equatable {
    /// New or replacement entries measured for exact resource weight.
    public var changedEntriesMeasured = 0
    /// Entry values read while rebuilding boundary leaves. Bounded by the leaves on the rebuilt paths, never by retained history.
    public var unchangedEntriesVisited = 0
    /// Entry values copied into rebuilt boundary leaves. Bounded by the leaves on the rebuilt paths, never by retained history.
    public var retainedEntriesCopied = 0
    /// Persistent sequence nodes created, both new leaves and rebuilt boundary nodes.
    public var sequenceNodesCreated = 0
    /// Child references written into created branch nodes.
    public var branchSlotsCopied = 0

    /// Creates zeroed counters.
    public init() {}

    /// Accumulates work across every transcript operation staged in one frame.
    public mutating func add(_ other: AgentTranscriptAccountingCounters) {
        changedEntriesMeasured += other.changedEntriesMeasured
        unchangedEntriesVisited += other.unchangedEntriesVisited
        retainedEntriesCopied += other.retainedEntriesCopied
        sequenceNodesCreated += other.sequenceNodesCreated
        branchSlotsCopied += other.branchSlotsCopied
    }
}

nonisolated private struct WeightedChatMessageEntry {
    let message: ChatMessageEntry
    let resourceWeight: FrameResourceWeight
    /// The message identity, stored so that identity reads do not copy the message payload.
    let id: Int
}

nonisolated private func addingKnownValid(
    _ left: FrameResourceWeight,
    _ right: FrameResourceWeight
) -> FrameResourceWeight {
    do {
        return try left.adding(right)
    } catch {
        preconditionFailure("validated transcript resource weight overflowed")
    }
}

/// Child record of a branch: the child and the cumulative entry count through it.
nonisolated private struct AgentTranscriptChild {
    let node: AgentTranscriptNode
    let end: Int
}

/// Immutable node of the resident transcript's persistent weighted B+ sequence.
///
/// Leaves (height 0) hold up to `maximumSlots` entries; branches hold up to `maximumSlots` child records. Every node except the root holds at least `minimumSlots`. The node is `nonisolated` so that releasing nodes, including discarded boundary nodes, does not pay for a main-actor isolated deinit.
nonisolated private final class AgentTranscriptNode {
    static let maximumSlots = 32
    static let minimumSlots = 16

    let height: Int
    let entries: [WeightedChatMessageEntry]
    let children: [AgentTranscriptChild]
    let count: Int
    let resourceWeight: FrameResourceWeight

    init(leaf entries: [WeightedChatMessageEntry]) {
        precondition(!entries.isEmpty && entries.count <= Self.maximumSlots, "transcript leaf occupancy")
        var weight = FrameResourceWeight(arrayEntries: entries.count)
        for entry in entries {
            weight = addingKnownValid(weight, entry.resourceWeight)
        }
        height = 0
        self.entries = entries
        children = []
        count = entries.count
        resourceWeight = weight
    }

    init<Nodes: Collection<AgentTranscriptNode>>(branch nodes: Nodes) {
        precondition(nodes.count >= 2 && nodes.count <= Self.maximumSlots, "transcript branch occupancy")
        var records: [AgentTranscriptChild] = []
        records.reserveCapacity(nodes.count)
        var total = 0
        var weight = FrameResourceWeight()
        let childHeight = nodes.first?.height ?? 0
        for node in nodes {
            precondition(node.height == childHeight, "transcript branch children must share a height")
            total += node.count
            weight = addingKnownValid(weight, node.resourceWeight)
            records.append(AgentTranscriptChild(node: node, end: total))
        }
        height = childHeight + 1
        entries = []
        children = records
        count = total
        resourceWeight = weight
    }

    /// Entries in a leaf, or children in a branch.
    var slotCount: Int { height == 0 ? entries.count : children.count }

    /// Index of the child holding entry `index`, by binary search over cumulative counts.
    func childIndex(containing index: Int) -> Int {
        var low = 0
        var high = children.count - 1
        while low < high {
            let middle = (low + high) / 2
            if children[middle].end <= index {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    /// Entries before child `index`.
    func start(ofChild index: Int) -> Int {
        index == 0 ? 0 : children[index - 1].end
    }
}

/// Read-only resident transcript entries with stable value semantics.
///
/// The persistent B+ sequence lets transcript preparation retain unchanged history without copying it. Integer indexes remain stable within a snapshot; indexed access descends the tree in O(height) without allocating.
public struct AgentTranscriptMessages: BidirectionalCollection {
    public typealias Index = Int
    public typealias Element = ChatMessageEntry

    /// In-order iterator that visits each resident entry once, leaf by leaf.
    public struct Iterator: IteratorProtocol {
        private var cursor: AgentTranscriptLeafCursor

        fileprivate init(root: AgentTranscriptNode?) {
            cursor = AgentTranscriptLeafCursor(root: root)
        }

        public mutating func next() -> ChatMessageEntry? {
            cursor.next()?.message
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
        let slot = leafSlot(at: index)
        return slot.leaf.entries[slot.position].message
    }

    /// Stable message identity at `index`, read in place without copying the message payload.
    func identity(at index: Int) -> Int {
        let slot = leafSlot(at: index)
        return slot.leaf.entries[slot.position].id
    }

    /// The leaf and position holding entry `index`, found by an O(height) descent that allocates nothing.
    private func leafSlot(at index: Int) -> (leaf: AgentTranscriptNode, position: Int) {
        precondition(index >= startIndex && index < endIndex, "transcript index out of bounds")
        guard var node = root else { preconditionFailure("valid transcript index was not present") }
        var remaining = index
        while node.height > 0 {
            let child = node.childIndex(containing: remaining)
            remaining -= node.start(ofChild: child)
            node = node.children[child].node
        }
        return (node, remaining)
    }

    /// In-order iterator over message identities.
    struct IdentityIterator: IteratorProtocol {
        private var cursor: AgentTranscriptLeafCursor

        fileprivate init(root: AgentTranscriptNode?) {
            cursor = AgentTranscriptLeafCursor(root: root)
        }

        mutating func next() -> Int? {
            cursor.next()?.id
        }
    }

    func makeIdentityIterator() -> IdentityIterator { IdentityIterator(root: root) }
}

/// Walks the leaves of one immutable sequence in order. Each iterator owns its own stack, so independent iterators over old snapshots stay valid.
nonisolated private struct AgentTranscriptLeafCursor {
    private var stack: [(node: AgentTranscriptNode, next: Int)] = []
    private var leaf: AgentTranscriptNode?
    private var position = 0

    init(root: AgentTranscriptNode?) {
        descend(root)
    }

    mutating func next() -> WeightedChatMessageEntry? {
        while true {
            if let current = leaf, position < current.entries.count {
                let entry = current.entries[position]
                position += 1
                return entry
            }
            leaf = nil
            guard let top = stack.popLast() else { return nil }
            if top.next + 1 < top.node.children.count {
                stack.append((top.node, top.next + 1))
            }
            descend(top.node.children[top.next].node)
        }
    }

    private mutating func descend(_ start: AgentTranscriptNode?) {
        guard var node = start else { return }
        while node.height > 0 {
            if node.children.count > 1 {
                stack.append((node, 1))
            }
            node = node.children[0].node
        }
        leaf = node
        position = 0
    }
}

#if DEBUG
/// Structural facts of one resident sequence, for invariant tests.
struct AgentTranscriptStructure {
    /// Leaf height is 0; an empty sequence reports -1.
    let height: Int
    /// Every node of the sequence, so tests can observe release with weak references.
    let nodes: [AnyObject]
    /// Broken occupancy, height, count, or weight invariants.
    let violations: [String]
}

extension AgentTranscriptMessages {
    /// Walks the whole sequence and reports its structure. Test-only.
    func structure() -> AgentTranscriptStructure {
        guard let root else { return AgentTranscriptStructure(height: -1, nodes: [], violations: []) }
        var nodes: [AnyObject] = []
        var violations: [String] = []
        Self.inspect(root, isRoot: true, nodes: &nodes, violations: &violations)
        return AgentTranscriptStructure(height: root.height, nodes: nodes, violations: violations)
    }

    private static func inspect(
        _ node: AgentTranscriptNode,
        isRoot: Bool,
        nodes: inout [AnyObject],
        violations: inout [String]
    ) {
        nodes.append(node)
        let slots = node.slotCount
        let minimum = isRoot ? (node.height == 0 ? 1 : 2) : AgentTranscriptNode.minimumSlots
        if slots < minimum || slots > AgentTranscriptNode.maximumSlots {
            violations.append("height \(node.height) node holds \(slots) slots")
        }
        if node.height == 0 {
            var weight = FrameResourceWeight(arrayEntries: node.entries.count)
            for entry in node.entries {
                weight = addingKnownValid(weight, entry.resourceWeight)
            }
            if node.count != node.entries.count || weight != node.resourceWeight {
                violations.append("leaf count or weight is stale")
            }
            return
        }
        var total = 0
        var weight = FrameResourceWeight()
        for child in node.children {
            if child.node.height != node.height - 1 {
                violations.append("child height \(child.node.height) under height \(node.height)")
            }
            total += child.node.count
            weight = addingKnownValid(weight, child.node.resourceWeight)
            if child.end != total {
                violations.append("cumulative child count is stale")
            }
            inspect(child.node, isRoot: false, nodes: &nodes, violations: &violations)
        }
        if total != node.count || weight != node.resourceWeight {
            violations.append("branch count or weight is stale")
        }
    }
}
#endif

/// Canonical resident transcript storage: a persistent weighted B+ sequence with bulk replace, contiguous range retention, and suffix append.
private struct AgentTranscriptStore {
    private typealias Node = AgentTranscriptNode

    private(set) var root: AgentTranscriptNode?

    init() {
        root = nil
    }

    private init(root: AgentTranscriptNode?) {
        self.root = root
    }

    var count: Int { root?.count ?? 0 }
    var messages: AgentTranscriptMessages { AgentTranscriptMessages(root: root) }

    var resourceWeight: FrameResourceWeight { root?.resourceWeight ?? FrameResourceWeight() }

    static func replacingAll(
        _ messages: [ChatMessageEntry],
        counters: inout AgentTranscriptAccountingCounters
    ) throws -> AgentTranscriptStore {
        let entries = try measuredEntries(messages, counters: &counters)
        _ = try weight(of: entries)
        return AgentTranscriptStore(root: build(entries, counters: &counters))
    }

    /// Retains the `baseCount` entries after the first `trimFront`, then appends `messages`. Untouched subtrees are shared; only boundary leaves and the paths above them are rebuilt.
    func replacingResidentRange(
        trimFront: Int,
        baseCount: Int,
        with messages: [ChatMessageEntry],
        counters: inout AgentTranscriptAccountingCounters
    ) throws -> AgentTranscriptStore {
        precondition(trimFront >= 0 && baseCount >= 0 && trimFront + baseCount <= count, "transcript range out of bounds")
        var sequenceCounters = counters
        let entries = try Self.measuredEntries(messages, counters: &sequenceCounters)
        let appendedWeight = try Self.weight(of: entries)
        let afterTrim = Self.dropFirst(root, trimFront, counters: &sequenceCounters)
        let kept = Self.takeFirst(afterTrim, baseCount, counters: &sequenceCounters)
        _ = try (kept?.resourceWeight ?? FrameResourceWeight()).adding(appendedWeight)
        let appended = Self.build(entries, counters: &sequenceCounters)
        let nextRoot = Self.concatenate(kept, appended, counters: &sequenceCounters)
        counters = sequenceCounters
        return AgentTranscriptStore(root: nextRoot)
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
                resourceWeight: try message.resourceWeight(),
                id: message.id
            ))
            counters.changedEntriesMeasured += 1
        }
        return entries
    }

    /// Checked aggregate weight of `entries`, including one collection entry per message.
    private static func weight(of entries: [WeightedChatMessageEntry]) throws -> FrameResourceWeight {
        var total = FrameResourceWeight(arrayEntries: entries.count)
        for entry in entries {
            total = try total.adding(entry.resourceWeight)
        }
        return total
    }

    // MARK: Construction

    /// Sizes of `parts` groups that split `total` slots as evenly as possible.
    private static func evenSizes(total: Int, parts: Int) -> [Int] {
        let base = total / parts
        let extra = total % parts
        var sizes: [Int] = []
        sizes.reserveCapacity(parts)
        for part in 0..<parts {
            sizes.append(part < extra ? base + 1 : base)
        }
        return sizes
    }

    private static func groupCount(for total: Int) -> Int {
        (total + Node.maximumSlots - 1) / Node.maximumSlots
    }

    private static func makeLeaf<Entries: Collection<WeightedChatMessageEntry>>(
        _ entries: Entries,
        counters: inout AgentTranscriptAccountingCounters
    ) -> Node {
        counters.sequenceNodesCreated += 1
        return Node(leaf: Array(entries))
    }

    private static func makeBranch<Nodes: Collection<Node>>(
        _ nodes: Nodes,
        counters: inout AgentTranscriptAccountingCounters
    ) -> Node {
        counters.sequenceNodesCreated += 1
        counters.branchSlotsCopied += nodes.count
        return Node(branch: nodes)
    }

    /// Builds a balanced sequence bottom-up in O(n). Evenly sized groups keep every non-root node at least half full.
    private static func build(
        _ entries: [WeightedChatMessageEntry],
        counters: inout AgentTranscriptAccountingCounters
    ) -> Node? {
        guard !entries.isEmpty else { return nil }
        var level: [Node] = []
        level.reserveCapacity(groupCount(for: entries.count))
        var offset = 0
        for size in evenSizes(total: entries.count, parts: groupCount(for: entries.count)) {
            level.append(makeLeaf(entries[offset..<(offset + size)], counters: &counters))
            offset += size
        }
        while level.count > 1 {
            var parents: [Node] = []
            parents.reserveCapacity(groupCount(for: level.count))
            offset = 0
            for size in evenSizes(total: level.count, parts: groupCount(for: level.count)) {
                parents.append(makeBranch(level[offset..<(offset + size)], counters: &counters))
                offset += size
            }
            level = parents
        }
        return level[0]
    }

    /// A root holding `slots` of one level: nil when empty, the only child when a branch would hold one child.
    private static func root(
        leafEntries entries: ArraySlice<WeightedChatMessageEntry>,
        counters: inout AgentTranscriptAccountingCounters
    ) -> Node? {
        guard !entries.isEmpty else { return nil }
        counters.retainedEntriesCopied += entries.count
        counters.unchangedEntriesVisited += entries.count
        return makeLeaf(entries, counters: &counters)
    }

    private static func root(
        children: ArraySlice<AgentTranscriptChild>,
        counters: inout AgentTranscriptAccountingCounters
    ) -> Node? {
        switch children.count {
        case 0:
            return nil
        case 1:
            return children[children.startIndex].node
        default:
            return makeBranch(children.lazy.map { $0.node }, counters: &counters)
        }
    }

    // MARK: Range selection

    /// The sequence without its first `amount` entries.
    private static func dropFirst(
        _ node: Node?,
        _ amount: Int,
        counters: inout AgentTranscriptAccountingCounters
    ) -> Node? {
        guard let node else { return nil }
        if amount == 0 { return node }
        if amount >= node.count { return nil }
        if node.height == 0 {
            return root(leafEntries: node.entries[amount...], counters: &counters)
        }
        let child = node.childIndex(containing: amount)
        let rest = dropFirst(
            node.children[child].node, amount - node.start(ofChild: child), counters: &counters
        )
        let right = root(children: node.children[(child + 1)...], counters: &counters)
        return concatenate(rest, right, counters: &counters)
    }

    /// The first `amount` entries of the sequence.
    private static func takeFirst(
        _ node: Node?,
        _ amount: Int,
        counters: inout AgentTranscriptAccountingCounters
    ) -> Node? {
        guard let node else { return nil }
        if amount >= node.count { return node }
        if amount == 0 { return nil }
        if node.height == 0 {
            return root(leafEntries: node.entries[..<amount], counters: &counters)
        }
        let child = node.childIndex(containing: amount - 1)
        let left = root(children: node.children[..<child], counters: &counters)
        let part = takeFirst(
            node.children[child].node, amount - node.start(ofChild: child), counters: &counters
        )
        return concatenate(left, part, counters: &counters)
    }

    // MARK: Join

    /// Joins two sequences in order. Untouched subtrees are shared; only the spine of the taller tree down to the shorter tree's height is rebuilt.
    private static func concatenate(
        _ left: Node?,
        _ right: Node?,
        counters: inout AgentTranscriptAccountingCounters
    ) -> Node? {
        guard let left else { return right }
        guard let right else { return left }
        let joined: [Node]
        if left.height == right.height {
            joined = joinSameHeight(left, right, counters: &counters)
        } else if left.height > right.height {
            joined = appendToRightSpine(left, right, counters: &counters)
        } else {
            joined = prependToLeftSpine(left, right, counters: &counters)
        }
        if joined.count == 1 { return joined[0] }
        return makeBranch(joined, counters: &counters)
    }

    /// Joins two nodes of one height into one or two nodes that are each at least half full, or one root.
    private static func joinSameHeight(
        _ left: Node,
        _ right: Node,
        counters: inout AgentTranscriptAccountingCounters
    ) -> [Node] {
        if left.slotCount >= Node.minimumSlots && right.slotCount >= Node.minimumSlots {
            return [left, right]
        }
        let total = left.slotCount + right.slotCount
        let parts = total <= Node.maximumSlots ? 1 : 2
        let sizes = evenSizes(total: total, parts: parts)
        if left.height == 0 {
            let combined = left.entries + right.entries
            counters.retainedEntriesCopied += total
            counters.unchangedEntriesVisited += total
            var nodes: [Node] = []
            var offset = 0
            for size in sizes {
                nodes.append(makeLeaf(combined[offset..<(offset + size)], counters: &counters))
                offset += size
            }
            return nodes
        }
        let combined = left.children.map { $0.node } + right.children.map { $0.node }
        var nodes: [Node] = []
        var offset = 0
        for size in sizes {
            nodes.append(makeBranch(combined[offset..<(offset + size)], counters: &counters))
            offset += size
        }
        return nodes
    }

    /// Rebuilds a branch from `children`, splitting it in two when it overflows.
    private static func branches(
        _ children: [Node],
        counters: inout AgentTranscriptAccountingCounters
    ) -> [Node] {
        if children.count <= Node.maximumSlots {
            return [makeBranch(children, counters: &counters)]
        }
        let sizes = evenSizes(total: children.count, parts: 2)
        return [
            makeBranch(children[0..<sizes[0]], counters: &counters),
            makeBranch(children[sizes[0]...], counters: &counters),
        ]
    }

    /// Inserts the shorter `right` at the end of `left`'s rightmost path.
    private static func appendToRightSpine(
        _ left: Node,
        _ right: Node,
        counters: inout AgentTranscriptAccountingCounters
    ) -> [Node] {
        var children = left.children.map { $0.node }
        let last = children.removeLast()
        let replacement: [Node]
        if last.height == right.height {
            replacement = joinSameHeight(last, right, counters: &counters)
        } else {
            replacement = appendToRightSpine(last, right, counters: &counters)
        }
        children.append(contentsOf: replacement)
        return branches(children, counters: &counters)
    }

    /// Inserts the shorter `left` at the start of `right`'s leftmost path.
    private static func prependToLeftSpine(
        _ left: Node,
        _ right: Node,
        counters: inout AgentTranscriptAccountingCounters
    ) -> [Node] {
        var children = right.children.map { $0.node }
        let first = children.removeFirst()
        let replacement: [Node]
        if first.height == left.height {
            replacement = joinSameHeight(left, first, counters: &counters)
        } else {
            replacement = prependToLeftSpine(left, first, counters: &counters)
        }
        children.insert(contentsOf: replacement, at: 0)
        return branches(children, counters: &counters)
    }
}


/// Value-semantic resident transcript used to validate and prepare a complete
/// frame before any GUI state is published.
public struct AgentTranscriptSnapshot {
    fileprivate let store: AgentTranscriptStore
    let epoch: UInt32
    let hasTranscript: Bool
    let truncated: Bool
    /// Identity of this transcript value. Advances, with wrapping, each time the
    /// stored snapshot is replaced, and never for chrome or composer updates.
    let revision: UInt64
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
        revision: UInt64,
        accountingCounters: AgentTranscriptAccountingCounters
    ) {
        self.store = store
        self.epoch = epoch
        self.hasTranscript = hasTranscript
        self.truncated = truncated
        self.revision = revision
        self.accountingCounters = accountingCounters
    }

    fileprivate static func seeded(
        messages: [ChatMessageEntry],
        epoch: UInt32 = 0,
        hasTranscript: Bool = false,
        truncated: Bool = false,
        revision: UInt64
    ) throws -> AgentTranscriptSnapshot {
        var counters = AgentTranscriptAccountingCounters()
        let store = try AgentTranscriptStore.replacingAll(messages, counters: &counters)
        return AgentTranscriptSnapshot(
            store: store,
            epoch: epoch,
            hasTranscript: hasTranscript,
            truncated: truncated,
            revision: revision,
            accountingCounters: counters
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

@Observable
public final class AgentChatState {
    public init(visible: Bool = false, status: AgentStatus = .idle, model: String = "", thinkingLevel: String = "medium", prompt: String = "", messages: [ChatMessageEntry] = [], promptLineCount: UInt8 = 1, promptCursorLine: UInt16 = 0, promptCursorCol: UInt16 = 0, promptMode: EditorMode = .normal, promptVisibleRows: UInt8 = 1, promptCompletion: Wire.PromptCompletion? = nil) {
        self.visible = visible
        self.status = status
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.prompt = prompt
        do {
            transcriptSnapshotStorage = try AgentTranscriptSnapshot.seeded(
                messages: messages,
                revision: 0
            )
        } catch {
            preconditionFailure("preview transcript resource accounting overflowed")
        }
        self.promptLineCount = promptLineCount
        self.promptCursorLine = promptCursorLine
        self.promptCursorCol = promptCursorCol
        self.promptMode = promptMode
        self.promptVisibleRows = promptVisibleRows
        self.promptCompletion = promptCompletion
    }
    public var visible: Bool = false
    public var status: AgentStatus = .idle
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
                revision: transcriptRevision &+ 1
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

    /// The single authority for "the transcript changed". It advances only when
    /// the stored snapshot is replaced (prepare and publish, hide, seed), so
    /// chrome and composer updates never invalidate transcript readers.
    public var transcriptRevision: UInt64 { transcriptSnapshotStorage.revision }

    // ── Prompt cell-grid metadata (for Metal rendering) ──

    /// Number of logical lines in the prompt buffer.
    public var promptLineCount: UInt8 = 1
    /// Cursor row within the prompt buffer.
    public var promptCursorLine: UInt16 = 0
    /// Cursor column within the prompt buffer.
    public var promptCursorCol: UInt16 = 0
    public var promptMode: EditorMode = .normal
    /// Number of visible rows in the prompt (after wrapping, clamped to max).
    public var promptVisibleRows: UInt8 = 1
    public private(set) var draftAttachmentCount: UInt8 = 0
    public private(set) var draftAttachmentOffer: UInt64 = 0
    public private(set) var question: AgentQuestionOffer?
    public private(set) var stopTarget: AgentStopTarget?
    public private(set) var promptPresentation: UInt64 = 0
    public private(set) var queueTarget: AgentQueueTarget?
    public private(set) var lifecycle: AgentChatLifecycle = .conversation
    /// Production font pitch projected only at accepted editor-frame publication.
    public private(set) var promptRowPitch: CGFloat = 0

    /// Publishes physical font metrics without introducing a prompt font or text layout.
    public func updatePromptRowPitch(_ pitch: CGFloat) {
        promptRowPitch = pitch
    }

    /// Whether the prompt is in insert mode (for SwiftUI styling).
    public var isPromptInsertMode: Bool { promptMode.isInsert }

    // ── Prompt completion popup ──

    /// Active completion popup for @-mention or /slash commands. Nil when no popup is showing.
    public var promptCompletion: Wire.PromptCompletion?

    public var statusLabel: String {
        if question != nil { return "Waiting for your answer" }
        switch status {
        case .idle: return "idle"
        case .thinking: return "thinking"
        case .executingTool: return "running tool"
        case .error: return "error"
        case .planning: return "planning"
        case .approvalWaiting: return "Awaiting approval"
        case .unknown: return "unknown"
        }
    }

    public var isThinking: Bool { question == nil && status.isWorking }
    public var hasActiveTurn: Bool { status.hasActiveTurn }

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

    /// Updates the chat chrome (visibility, status, model, prompt).
    ///
    /// Message content is sourced from the resident 0x86 stream via `applyTranscript`.
    public func update(visible: Bool, status: AgentStatus, model: String, thinkingLevel: String, prompt: String, promptLineCount: UInt8, promptCursorLine: UInt16, promptCursorCol: UInt16, promptMode: EditorMode, promptVisibleRows: UInt8, promptCompletion: Wire.PromptCompletion?, draftAttachmentCount: UInt8 = 0, draftAttachmentOffer: UInt64 = 0, question: AgentQuestionOffer? = nil, stopTarget: AgentStopTarget? = nil, promptPresentation: UInt64 = 0, queueTarget: AgentQueueTarget? = nil, lifecycle: AgentChatLifecycle = .conversation) {
        self.visible = visible
        self.lifecycle = lifecycle
        self.status = status
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.prompt = prompt
        self.promptLineCount = promptLineCount
        self.promptCursorLine = promptCursorLine
        self.promptCursorCol = promptCursorCol
        self.promptMode = promptMode
        self.promptVisibleRows = promptVisibleRows
        self.promptCompletion = promptCompletion
        self.draftAttachmentCount = draftAttachmentCount
        self.draftAttachmentOffer = draftAttachmentOffer
        self.question = question
        self.stopTarget = stopTarget
        self.promptPresentation = promptPresentation
        self.queueTarget = queueTarget
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
        transcriptSnapshotStorage
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
                    revision: current.revision &+ 1,
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
                revision: current.revision &+ 1,
                accountingCounters: counters
            ))
        } catch {
            return .failure(.resourcePolicy)
        }
    }

    /// Installs a transcript snapshot that was fully validated before frame publication.
    public func publishTranscript(_ snapshot: AgentTranscriptSnapshot) {
        transcriptSnapshotStorage = snapshot
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
            return .toolCall(id: id, name: name, summary: summary, status: st, isError: isError, collapsed: collapsed, autoApprovedScope: autoApprovedScope, durationMs: duration, result: result, previewKind: previewKind, previewLines: previewLines, retainedOutputOffer: msg.retainedOutputOffer)
        case .styledToolCall(let name, let summary, let st, let isError, let collapsed, let autoApprovedScope, let duration, let resultLines, let previewKind, let previewLines):
            return .styledToolCall(id: id, name: name, summary: summary, status: st, isError: isError, collapsed: collapsed, autoApprovedScope: autoApprovedScope, durationMs: duration, resultLines: resultLines, previewKind: previewKind, previewLines: previewLines, retainedOutputOffer: msg.retainedOutputOffer)
        case .approvalToolCall(let name, let summary, let toolCallId, let sessionId, let requestId, let previewKind, let previewLines):
            return .approvalToolCall(id: id, name: name, summary: summary, toolCallId: toolCallId, sessionId: sessionId, requestId: requestId, previewKind: previewKind, previewLines: previewLines)
        case .system(let text, let isError):
            return .system(id: id, text: text, isError: isError)
        case .usage(let inp, let outp, let cacheR, let cacheW, let costM):
            return .usage(id: id, input: inp, output: outp, cacheRead: cacheR, cacheWrite: cacheW, costMicros: costM)
        }
    }

    public func hide() {
        visible = false
        lifecycle = .conversation
        draftAttachmentCount = 0
        draftAttachmentOffer = 0
        question = nil
        stopTarget = nil
        promptPresentation = 0
        queueTarget = nil
        do {
            transcriptSnapshotStorage = try AgentTranscriptSnapshot.seeded(
                messages: [],
                revision: transcriptRevision &+ 1
            )
        } catch {
            preconditionFailure("empty transcript resource accounting overflowed")
        }
    }
}
