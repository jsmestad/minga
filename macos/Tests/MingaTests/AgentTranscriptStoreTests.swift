/// Tests for the resident Agent transcript sequence (#3572): order and identity against an array oracle, B+ occupancy across leaf and branch boundaries, joins of unequal heights, bounded structural work, snapshot and iterator lifetime, and exact retained weight.

import Foundation
import MingaProtocol
@testable import MingaUI
import Testing

/// Deterministic generator so failing transitions reproduce exactly.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// Sizes on both sides of every leaf and branch capacity boundary.
private let boundarySizes: [Int] = [0, 1, 2, 15, 16, 17, 31, 32, 33, 34, 63, 64, 65, 511, 512, 513, 1_023, 1_024, 1_025, 1_056, 2_049]

@Suite("Agent transcript resident sequence")
struct AgentTranscriptStoreTests {
    /// One message with nested Unicode, Markdown, or tool payload, chosen by `id`.
    private func message(_ id: Int, revision: Int = 0) -> Wire.ChatMessage {
        let beamId = UInt32(id)
        switch id % 5 {
        case 0:
            return Wire.ChatMessage(beamId: beamId, content: .user(text: "frage \(id).\(revision) ß 👋"))
        case 1:
            let run = Wire.StyledTextRun(text: "läuft \(revision) 🚀", fgR: 1, fgG: 2, fgB: 3, bgR: 0, bgG: 0, bgB: 0, bold: true, italic: false, underline: false, code: false, linkURL: "https://example.test/ü")
            let block = Wire.AgentMarkdownBlock(id: 1, kind: .paragraph, flags: 1, lines: [[run], []], level: 0, indent: 0, ordered: false, ordinal: 0, height: 2, language: "", label: "", targetPath: "/tmp/日本/\(id).ex", capabilityFlags: 0)
            return Wire.ChatMessage(beamId: beamId, content: .assistantMarkdown(blocks: [block]))
        case 2:
            return Wire.ChatMessage(beamId: beamId, content: .toolCall(name: "edit_file", summary: "lib/\(id).ex", status: 1, isError: false, collapsed: true, autoApprovedScope: 0, durationMs: 3, result: "✓ \(revision)", previewKind: 1, previewLines: ["+é", "-ü"]))
        case 3:
            return Wire.ChatMessage(beamId: beamId, content: .system(text: "", isError: revision.isMultiple(of: 2)))
        default:
            return Wire.ChatMessage(beamId: beamId, content: .assistant(text: "reply \(id).\(revision)"))
        }
    }

    private func messages(_ ids: Range<Int>, revision: Int = 0) -> [Wire.ChatMessage] {
        var result: [Wire.ChatMessage] = []
        result.reserveCapacity(ids.count)
        for id in ids { result.append(message(id, revision: revision)) }
        return result
    }

    /// Identity plus a payload fingerprint, so the oracle notices revised content as well as order.
    @MainActor private func fingerprint(_ entry: ChatMessageEntry) -> String {
        switch entry {
        case .user(let id, let text), .assistant(let id, let text): return "\(id):\(text)"
        case .assistantMarkdown(let id, let blocks): return "\(id):md\(blocks.first?.lines.first?.first?.text ?? "")"
        case .toolCall(let id, _, _, _, _, _, _, _, let result, _, _, _, _): return "\(id):tool\(result)"
        case .system(let id, _, let isError): return "\(id):sys\(isError)"
        default: return "\(entry.id):other"
        }
    }

    @MainActor private func fingerprints(_ snapshot: AgentTranscriptSnapshot) -> [String] {
        snapshot.messages.map(fingerprint)
    }

    @MainActor private func oracleWeight(_ snapshot: AgentTranscriptSnapshot) throws -> FrameResourceWeight {
        var weight = FrameResourceWeight(arrayEntries: snapshot.messages.count)
        for message in snapshot.messages {
            weight = try weight.adding(try FrameResourceWeight.measuringOwnedPayload(message))
        }
        return weight
    }

    @MainActor private func replaced(_ messages: [Wire.ChatMessage], epoch: UInt32 = 1) throws -> AgentTranscriptSnapshot {
        try AgentChatState.prepareTranscript(
            from: AgentChatState().transcriptSnapshot, mode: 0, epoch: epoch, truncated: false,
            trimFront: 0, baseCount: 0, messages: messages
        ).get()
    }

    @MainActor private func appended(
        _ snapshot: AgentTranscriptSnapshot, trimFront: Int, baseCount: Int, _ messages: [Wire.ChatMessage]
    ) throws -> AgentTranscriptSnapshot {
        try AgentChatState.prepareTranscript(
            from: snapshot, mode: 1, epoch: snapshot.epoch, truncated: false,
            trimFront: trimFront, baseCount: baseCount, messages: messages
        ).get()
    }

    @MainActor private func expectValid(_ snapshot: AgentTranscriptSnapshot, _ oracle: [String], _ context: String) throws {
        let structure = snapshot.messages.structure()
        #expect(structure.violations.isEmpty, "\(context): \(structure.violations.prefix(3))")
        #expect(snapshot.messages.count == oracle.count, "\(context)")
        #expect(fingerprints(snapshot) == oracle, "\(context)")
        #expect(snapshot.resourceWeight == (try oracleWeight(snapshot)), "\(context)")
    }

    @Test("full replacement builds a balanced sequence on both sides of every capacity boundary")
    @MainActor func boundaryBuilds() throws {
        for size in boundarySizes {
            let snapshot = try replaced(messages(0..<size))
            try expectValid(snapshot, messages(0..<size).map { fingerprint(AgentChatState.mapMessage($0)) }, "size \(size)")
            let expectedHeight = size == 0 ? -1 : (size <= 32 ? 0 : (size <= 1_024 ? 1 : 2))
            #expect(snapshot.messages.structure().height == expectedHeight, "size \(size)")
            for index in [0, size / 2, size - 1] where index >= 0 && index < size {
                #expect(snapshot.messages[index].id == index, "size \(size) index \(index)")
            }
        }
    }

    @Test("every retained range and appended batch matches an array oracle across tree heights")
    @MainActor func rangeAndAppendMatchOracle() throws {
        for baseSize in [0, 1, 17, 32, 33, 1_024, 1_025, 2_049] {
            let base = try replaced(messages(0..<baseSize))
            let baseOracle = fingerprints(base)
            var cases: [(Int, Int)] = [(0, baseSize), (baseSize, 0), (0, 0)]
            for cut in [1, 15, 16, 17, 31, 32, 33, 1_000, 1_024, 1_025] where cut < baseSize {
                cases.append((cut, baseSize - cut))
                cases.append((0, cut))
                cases.append((cut / 2, cut - cut / 2))
            }
            for (trimFront, baseCount) in cases {
                for appendCount in [0, 1, 16, 33, 1_100] {
                    let batch = messages(10_000..<(10_000 + appendCount), revision: 1)
                    let next = try appended(base, trimFront: trimFront, baseCount: baseCount, batch)
                    let expected = Array(baseOracle[trimFront..<(trimFront + baseCount)]) + batch.map { fingerprint(AgentChatState.mapMessage($0)) }
                    try expectValid(next, expected, "base \(baseSize) trim \(trimFront) keep \(baseCount) append \(appendCount)")
                }
            }
            // Every derived snapshot left the original untouched.
            try expectValid(base, baseOracle, "base \(baseSize) after derivations")
        }
    }

    @Test("randomized streaming, trimming, tail replacement, and batches keep every snapshot valid")
    @MainActor func randomizedTransitionsMatchOracle() throws {
        var generator = SplitMix64(state: 3_572)
        var snapshot = try replaced(messages(0..<700))
        var oracle = fingerprints(snapshot)
        var held: [(AgentTranscriptSnapshot, [String])] = []
        var nextId = 700
        for step in 0..<600 {
            let count = oracle.count
            let trimFront = count == 0 ? 0 : Int.random(in: 0...min(count, 40), using: &generator)
            let remainder = count - trimFront
            let baseCount = remainder == 0 ? 0 : remainder - Int.random(in: 0...min(remainder, 3), using: &generator)
            let appendCount = step.isMultiple(of: 50) ? Int.random(in: 0...300, using: &generator) : Int.random(in: 0...4, using: &generator)
            var batch: [Wire.ChatMessage] = []
            for _ in 0..<appendCount {
                batch.append(message(nextId, revision: step))
                nextId += 1
            }
            snapshot = try appended(snapshot, trimFront: trimFront, baseCount: baseCount, batch)
            oracle = Array(oracle[trimFront..<(trimFront + baseCount)]) + batch.map { fingerprint(AgentChatState.mapMessage($0)) }
            if step.isMultiple(of: 37) {
                try expectValid(snapshot, oracle, "step \(step)")
                held.append((snapshot, oracle))
            }
        }
        try expectValid(snapshot, oracle, "final")
        for (index, entry) in held.enumerated() {
            try expectValid(entry.0, entry.1, "held snapshot \(index)")
        }
    }

    @Test("repeated front eviction with one append keeps occupancy at 10,000 entries")
    @MainActor func repeatedRebalancing() throws {
        var snapshot = try replaced(messages(0..<10_000))
        for step in 0..<2_000 {
            snapshot = try appended(snapshot, trimFront: 1, baseCount: 9_999, [message(10_000 + step)])
            if step.isMultiple(of: 250) {
                #expect(snapshot.messages.structure().violations.isEmpty, "step \(step)")
            }
        }
        #expect(snapshot.messages.structure().violations.isEmpty)
        #expect(snapshot.messages.count == 10_000)
        #expect(snapshot.messages[0].id == 2_000)
        #expect(snapshot.messages[9_999].id == 11_999)
    }

    @Test("ordinary deltas do bounded structural work at 100 and 10,000 entries", arguments: [100, 10_000])
    @MainActor func boundedDeltaWork(messageCount: Int) throws {
        let base = try replaced(messages(0..<messageCount))
        let height = base.messages.structure().height
        // Each delta rebuilds at most a few root-to-leaf paths: the trim boundary, the keep boundary, and the join with the appended batch. Each rebuilt node copies at most two nodes' worth of slots.
        let pathNodes = 6 * (height + 1)
        let operations: [(String, Int, Int, [Wire.ChatMessage])] = [
            ("tail replacement", 0, messageCount - 1, [message(messageCount - 1, revision: 1)]),
            ("append", 0, messageCount, [message(messageCount)]),
            ("front trim with append", 1, messageCount - 1, [message(messageCount)]),
        ]
        for (name, trimFront, baseCount, batch) in operations {
            let counters = try appended(base, trimFront: trimFront, baseCount: baseCount, batch).accountingCounters
            print("AgentTranscript \(name) at \(messageCount) entries, height \(height): \(counters)")
            #expect(counters.changedEntriesMeasured == 1, "\(name)")
            #expect(counters.sequenceNodesCreated <= pathNodes, "\(name): \(counters.sequenceNodesCreated) nodes")
            #expect(counters.retainedEntriesCopied <= 2 * AgentTranscriptTestLimits.slots * 3, "\(name): \(counters.retainedEntriesCopied) entry slots")
            #expect(counters.unchangedEntriesVisited == counters.retainedEntriesCopied, "\(name)")
            #expect(counters.branchSlotsCopied <= pathNodes * 2 * AgentTranscriptTestLimits.slots, "\(name): \(counters.branchSlotsCopied) branch slots")
        }
    }

    @Test("a full replacement builds each node once, bottom-up")
    @MainActor func keyframeBuildsEachNodeOnce() throws {
        let snapshot = try replaced(messages(0..<10_000))
        // 313 leaves, 10 branches, and one root.
        #expect(snapshot.messages.structure().nodes.count == 324)
        #expect(snapshot.accountingCounters.sequenceNodesCreated == 324)
        #expect(snapshot.accountingCounters.retainedEntriesCopied == 0)
        #expect(snapshot.accountingCounters.branchSlotsCopied == 323)
    }

    @Test("old snapshots keep their entries and independent iterators after newer frames")
    @MainActor func oldSnapshotsAndIterators() throws {
        let old = try replaced(messages(0..<2_000))
        let oldOracle = fingerprints(old)
        var first = old.messages.makeIterator()
        var second = old.messages.makeIterator()
        for _ in 0..<500 { _ = first.next() }

        let trimmed = try appended(old, trimFront: 1_500, baseCount: 400, [message(5_000)])
        let revised = try appended(trimmed, trimFront: 0, baseCount: 100, messages(6_000..<6_050, revision: 2))
        let emptied = try appended(revised, trimFront: revised.messages.count, baseCount: 0, [])
        #expect(emptied.messages.isEmpty)
        #expect(emptied.messages.structure().height == -1)

        var resumed: [String] = []
        while let entry = first.next() { resumed.append(fingerprint(entry)) }
        #expect(resumed == Array(oldOracle[500...]))
        var full: [String] = []
        while let entry = second.next() { full.append(fingerprint(entry)) }
        #expect(full == oldOracle)
        try expectValid(old, oldOracle, "old after newer frames")
        #expect(revised.messages.count == 150)
    }

    @Test("discarded subtrees are released once no snapshot holds them")
    @MainActor func discardedSubtreesRelease() throws {
        weak var discardedLeaf: AnyObject?
        weak var sharedLeaf: AnyObject?
        var current: AgentTranscriptSnapshot? = try replaced(messages(0..<2_000))
        do {
            let nodes = current!.messages.structure().nodes
            discardedLeaf = nodes[2]
            sharedLeaf = nodes.last
        }
        // Evict the first half: the first leaves leave the sequence, the last leaf stays shared.
        let next = try appended(current!, trimFront: 1_000, baseCount: 1_000, [])
        #expect(discardedLeaf != nil)
        current = nil
        #expect(discardedLeaf == nil, "an evicted leaf outlived every snapshot")
        #expect(sharedLeaf != nil, "a retained leaf was released while the new snapshot still holds it")
        #expect(next.messages.count == 1_000)

        weak var replacedRoot: AnyObject?
        var session: AgentTranscriptSnapshot? = try replaced(messages(0..<500))
        replacedRoot = session!.messages.structure().nodes.first
        session = try replaced(messages(0..<3), epoch: 2)
        #expect(replacedRoot == nil, "a replaced session's sequence outlived its snapshot")
        #expect(session?.messages.count == 3)
    }

    @Test("a rejected operation keeps the complete last-good snapshot")
    @MainActor func rejectionKeepsLastGood() throws {
        let state = AgentChatState()
        state.applyTranscript(mode: 0, epoch: 4, baseCount: 0, messages: messages(0..<1_000))
        let before = state.transcriptSnapshot
        let oracle = fingerprints(before)
        #expect(state.applyTranscript(mode: 1, epoch: 4, trimFront: 900, baseCount: 101, messages: [message(2_000)]) == .droppedDesynced)
        #expect(state.applyTranscript(mode: 1, epoch: 5, baseCount: 1_000, messages: [message(2_000)]) == .droppedEpochMismatch)
        #expect(state.transcriptRevision == before.revision)
        try expectValid(state.transcriptSnapshot, oracle, "after rejections")
        #expect(state.transcriptSnapshot.resourceWeight == before.resourceWeight)
    }
}

private enum AgentTranscriptTestLimits {
    static let slots = 32
}

@Suite("Agent transcript rows")
struct AgentTranscriptRowsTests {
    private func user(_ id: UInt32, _ text: String) -> Wire.ChatMessage {
        Wire.ChatMessage(beamId: id, content: .user(text: text))
    }

    private func assistant(_ id: UInt32, _ text: String) -> Wire.ChatMessage {
        Wire.ChatMessage(beamId: id, content: .assistant(text: text))
    }

    @MainActor private func text(_ entry: ChatMessageEntry) -> String {
        switch entry {
        case .user(_, let text), .assistant(_, let text), .system(_, let text, _): return text
        default: return ""
        }
    }

    @Test("rows expose each message identity and offset by index and by iteration", arguments: [0, 1, 100, 10_000])
    @MainActor func rowsMatchSnapshot(messageCount: Int) {
        let state = AgentChatState()
        var wire: [Wire.ChatMessage] = []
        for id in 0..<messageCount { wire.append(assistant(UInt32(id * 3 + 7), "m\(id)")) }
        state.applyTranscript(mode: 0, epoch: 1, baseCount: 0, messages: wire)
        let rows = AgentTranscriptRows(state.messages)

        #expect(rows.count == messageCount)
        #expect(rows.isEmpty == (messageCount == 0))
        var iterated: [AgentTranscriptRow] = []
        for row in rows { iterated.append(row) }
        var indexed: [AgentTranscriptRow] = []
        for index in rows.indices { indexed.append(rows[index]) }
        #expect(iterated == indexed)
        #expect(indexed.map(\.offset) == Array(0..<messageCount))
        #expect(indexed.map(\.id) == wire.map { Int($0.beamId) })
        for row in [indexed.first, indexed.last].compactMap({ $0 }) {
            #expect(rows.message(at: row).id == row.id)
        }
    }

    @Test("dividers start each new user turn but never separate consecutive user messages")
    @MainActor func dividerRule() {
        let state = AgentChatState()
        state.applyTranscript(mode: 0, epoch: 1, baseCount: 0, messages: [
            user(1, "a"), user(2, "b"), assistant(3, "c"),
            Wire.ChatMessage(beamId: 4, content: .system(text: "s", isError: false)),
            user(5, "d"), assistant(6, "e"), user(7, "f"),
        ])
        let rows = AgentTranscriptRows(state.messages)
        #expect(rows.map { rows.showsDivider(before: $0) } == [false, false, false, false, true, false, true])
    }

    @Test("rows captured from an older snapshot keep their entries and dividers after newer frames")
    @MainActor func deferredRowsStayOnTheirSnapshot() {
        let state = AgentChatState()
        state.applyTranscript(mode: 0, epoch: 1, baseCount: 0, messages: [
            assistant(1, "intro"), user(2, "first"), assistant(3, "streaming"), user(4, "second"),
        ])
        let captured = AgentTranscriptRows(state.messages)
        let capturedRows = Array(captured)
        let expectedText = capturedRows.map { text(captured.message(at: $0)) }
        let expectedDividers = capturedRows.map { captured.showsDivider(before: $0) }
        #expect(expectedDividers == [false, true, false, true])

        // Streaming tail replacement, front trim, a session replacement, and an empty history.
        state.applyTranscript(mode: 1, epoch: 1, baseCount: 2, messages: [assistant(3, "streaming done"), user(4, "second")])
        #expect(text(AgentTranscriptRows(state.messages).message(at: AgentTranscriptRow(id: 3, offset: 2))) == "streaming done")
        state.applyTranscript(mode: 1, epoch: 1, trimFront: 2, baseCount: 2, messages: [])
        let trimmedRows = AgentTranscriptRows(state.messages)
        #expect(Array(trimmedRows).map(\.id) == [3, 4])
        #expect(trimmedRows.showsDivider(before: trimmedRows[1]))
        #expect(!trimmedRows.showsDivider(before: trimmedRows[0]), "the first row after a trim has no predecessor")
        state.applyTranscript(mode: 0, epoch: 2, baseCount: 0, messages: [user(9, "fresh")])
        #expect(Array(AgentTranscriptRows(state.messages)).map(\.id) == [9])
        state.hide()
        #expect(AgentTranscriptRows(state.messages).isEmpty)

        #expect(Array(captured) == capturedRows)
        #expect(capturedRows.map { text(captured.message(at: $0)) } == expectedText)
        #expect(capturedRows.map { captured.showsDivider(before: $0) } == expectedDividers)
    }
}
