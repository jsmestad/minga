import Testing
import Foundation
import MingaProtocol

@Suite("Messages wire-assigned identity")
struct MessagesContentStateIdentityTests {
    private func wire(_ id: UInt32, streamInstance: UInt32 = 1, _ text: String = "msg") -> Wire.MessageEntry {
        Wire.MessageEntry(streamInstance: streamInstance, id: id, level: 1, subsystem: 0, timestampSecs: 0, filePath: "", text: text)
    }

    @Test("reused sequence IDs from a new stream instance do not collide")
    @MainActor func reusedSequenceIDsAcrossInstancesStayUnique() {
        let state = MessagesContentState()
        state.appendEntries([wire(1, streamInstance: 10), wire(2, streamInstance: 10)])
        state.appendEntries([wire(1, streamInstance: 11), wire(2, streamInstance: 11)])

        let ids = state.entries.map(\.id)
        #expect(ids == [
            MessageEntry.makeID(streamInstance: 10, seq: 1),
            MessageEntry.makeID(streamInstance: 10, seq: 2),
            MessageEntry.makeID(streamInstance: 11, seq: 1),
            MessageEntry.makeID(streamInstance: 11, seq: 2),
        ])
        #expect(Set(ids).count == ids.count)
        #expect(state.entries.map(\.seq) == [1, 2, 1, 2])
    }

    @Test("identity is composed directly from wire stream instance and sequence")
    @MainActor func identityComesFromWireFields() {
        let state = MessagesContentState()
        state.appendEntries([wire(7, streamInstance: 42)])

        #expect(state.entries[0].id == MessageEntry.makeID(streamInstance: 42, seq: 7))
    }

    @Test("entries are capped without a defensive identity dedupe path")
    @MainActor func trimKeepsLatestEntries() {
        let state = MessagesContentState()
        state.appendEntries((1...1005).map { wire(UInt32($0), streamInstance: 3) })

        #expect(state.entries.count == 1000)
        #expect(state.entries.first?.seq == 6)
        #expect(state.entries.last?.seq == 1005)
    }
}
