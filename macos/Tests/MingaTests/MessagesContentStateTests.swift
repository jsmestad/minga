import Testing
import Foundation

@Suite("Messages restart-safe identity (issue #2353)")
struct MessagesContentStateIdentityTests {
    private func wire(_ id: UInt32, _ text: String = "msg") -> Wire.MessageEntry {
        Wire.MessageEntry(
            id: id, level: 1, subsystem: 0, timestampSecs: 0, filePath: "", text: text)
    }

    @Test("a backend restart (sequence resets to 1) yields unique row identities")
    @MainActor func restartKeepsIdentitiesUnique() {
        let state = MessagesContentState()
        state.appendEntries([wire(1), wire(2)])
        // Backend restarts: the BEAM MessageStore sequence resets to 1, 2 again.
        state.appendEntries([wire(1), wire(2)])

        let ids = state.entries.map(\.id)
        #expect(ids.count == 4)
        // All four rows have distinct SwiftUI identities despite repeated seqs,
        // so ForEach emits no duplicate-ID warning.
        #expect(Set(ids).count == 4)
        // The raw backend sequence is preserved on each entry.
        #expect(state.entries.map(\.seq) == [1, 2, 1, 2])
    }

    @Test("identity is the (generation, seq) composite, not the raw sequence")
    @MainActor func identityIsComposite() {
        let state = MessagesContentState()
        state.appendEntries([wire(1)])
        #expect(state.entries[0].id == MessageEntry.makeID(generation: 0, seq: 1))

        // Restart: same seq 1, but a new generation namespaces it.
        state.appendEntries([wire(1)])
        #expect(state.entries[1].id == MessageEntry.makeID(generation: 1, seq: 1))
    }

    @Test("a normal increasing sequence stays in a single generation")
    @MainActor func monotonicSequenceOneGeneration() {
        let state = MessagesContentState()
        state.appendEntries([wire(1), wire(2), wire(3)])
        #expect(state.entries.map(\.id) == [
            MessageEntry.makeID(generation: 0, seq: 1),
            MessageEntry.makeID(generation: 0, seq: 2),
            MessageEntry.makeID(generation: 0, seq: 3),
        ])
    }

    @Test("a resend of already-seen IDs is namespaced into a new generation")
    @MainActor func resendNamespaced() {
        let state = MessagesContentState()
        state.appendEntries([wire(1), wire(2), wire(3)])
        // Backend resends 2, 3 (e.g. after a reconnect) without a full restart.
        state.appendEntries([wire(2), wire(3)])

        let ids = state.entries.map(\.id)
        #expect(ids.count == 5)
        #expect(Set(ids).count == 5)
    }

    @Test("identities stay unique across many restarts (no ForEach collisions)")
    @MainActor func manyRestartsStayUnique() {
        let state = MessagesContentState()
        for _ in 0..<5 {
            state.appendEntries([wire(1), wire(2), wire(3)])
        }
        let ids = state.entries.map(\.id)
        #expect(ids.count == 15)
        #expect(Set(ids).count == ids.count)
    }

    @Test("entries are capped and identities stay unique across the trim boundary")
    @MainActor func trimKeepsIdentitiesUniqueAndDedupeInSync() {
        let state = MessagesContentState()
        // 6 restarts × 300 = 1800 appended, well past the 1000-entry cap.
        for _ in 0..<6 {
            state.appendEntries((1...300).map { wire(UInt32($0)) })
        }
        // Trimmed to the cap, and every retained row still has a unique identity,
        // so ForEach never sees a duplicate ID even after the dedupe set has been
        // pruned alongside the trimmed window.
        #expect(state.entries.count == 1000)
        #expect(Set(state.entries.map(\.id)).count == 1000)

        // A resend of an early sequence (whose original generation was trimmed
        // out) still appends in a fresh generation rather than being wrongly
        // deduped against a dropped id, and the cap holds.
        state.appendEntries([wire(1)])
        #expect(state.entries.count == 1000)
        #expect(Set(state.entries.map(\.id)).count == state.entries.count)
    }
}
