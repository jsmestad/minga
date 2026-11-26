import AppKit
import Foundation
import MingaProtocol
@testable import MingaUI
import Testing

@Suite("Agent queue")
@MainActor
struct AgentQueueTests {
    @Test("The admitted queue retains all 32 rows and the exact selected and removed identities")
    func retainedSelection() throws {
        let queue = try visibleQueue(in: queueCommand())
        #expect(queue.focused)
        #expect(queue.origin == .init(workspaceID: 0x12345678, recordID: "récord"))
        #expect(queue.title == "*minga-queue*")
        #expect(queue.summary == "32 queued")
        #expect(queue.removedNote == "Removed, not sent.")
        #expect(queue.pending.count == 32)
        #expect(queue.selectedRow?.identity == .init(id: 32, revision: 0x0102030405060708))
        #expect(queue.selectedRow?.kind == .followUp)
        #expect(queue.selectedRow?.label == "32")
        #expect(queue.selectedRow?.preview == "Preview 32 🧩")
        #expect(queue.selectedRow?.attachmentCount == 2)
        #expect(queue.removed.map(\.id) == [51, 52])
        #expect(queue.hints == [.init(action: .pasteBefore, key: "P", label: "before")])
        #expect(queue.empty == nil)
    }

    @Test("Queue show and hide are strict command windows, including when embedded in a packet")
    func commandBoundaries() throws {
        let hide = framed([0])
        let show = queueCommand()
        let commands = try decodeFrame(from: hide + show + hide).commands
        #expect(commands.count == 3)
        guard case .guiAgentQueue(nil) = commands.first?.command,
              case .guiAgentQueue(nil) = commands.last?.command else {
            Issue.record("Expected both queue hide commands")
            return
        }
        #expect(throws: ProtocolDecodeError.self) { try decodeFrame(from: framed([0, 0])) }
        #expect(throws: ProtocolDecodeError.self) { try decodeFrame(from: framed([2])) }
        #expect(throws: ProtocolDecodeError.self) { try decodeFrame(from: framed(Array(show.dropFirst(5).dropLast())) + hide) }
        #expect(throws: ProtocolDecodeError.self) { try decodeFrame(from: framed(Array(show.dropFirst(5)) + [0])) }
        #expect(throws: ProtocolDecodeError.self) { try decodeFrame(from: queueCommand(rowRevision: 0)) }

        let empty = try visibleQueue(in: queueCommand(empty: true))
        #expect(empty.selectedRow == nil)
        #expect(empty.empty?.title == "Nothing queued.")
        let action = try #require(empty.empty?.actions.first)
        #expect(action.key == "↩")
        #expect(empty.request(forEmptyAction: action) == AgentQueueRequest(action: .composer, origin: empty.origin))
    }

    @Test("Staged queue and focus update atomically and hide clears the last-good snapshot")
    func commitVisibility() throws {
        let gui = GUIState()
        let policy = EditorFocusPolicy(editorView: NSView(), focusOwnerState: gui.focusOwnerState)
        let dispatcher = CommandDispatcher(cols: 80, rows: 24, guiState: gui, applicationEffectSink: { effect in
            if case .focusOwnerChanged(let owner) = effect { policy.focusOwnerDidChange(owner) }
        })
        let queue = try visibleQueue(in: queueCommand())
        let empty = try visibleQueue(in: queueCommand(empty: true))
        let (focusCommand, _) = try decodeCommand(data: Data([OP_GUI_FOCUS_OWNER, 0, 10, 0, 15, 0, 0, 0, 1, 0, 0, 0, 7]), offset: 0)
        let slots = CommandDispatcher.requiredThemeSlots.map { ($0, $0, $0, $0) }
        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: slots))
        dispatcher.dispatch(.guiAgentQueue(empty))
        dispatcher.dispatch(.guiAgentQueue(queue))
        dispatcher.dispatch(try #require(focusCommand))
        #expect(gui.agentQueueState.snapshot == nil)
        #expect(gui.focusOwnerState.decodedOwner == nil)
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))
        #expect(gui.editorInput.agentQueueState.snapshot == queue)
        #expect(gui.focusOwnerState.decodedOwner?.ownsAgentQueue == true)
        #expect(gui.focusOwnerState.decodedOwner?.responderKind == .editorView)

        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 1, generation: 1))
        dispatcher.dispatch(.guiAgentQueue(nil))
        dispatcher.dispatch(.commitFrame(frameSeq: 99, seq: 0))
        #expect(gui.agentQueueState.snapshot == queue)
        dispatcher.dispatch(.beginFrame(frameSeq: 3, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: slots))
        dispatcher.dispatch(.guiAgentQueue(nil))
        dispatcher.dispatch(.commitFrame(frameSeq: 3, seq: 0))
        #expect(gui.agentQueueState.snapshot == nil)
        dispatcher.applyForTesting(.guiAgentQueue(queue))
        gui.resetProtocolConnection()
        #expect(gui.agentQueueState.snapshot == nil)
    }

    @Test("Row, paste, close and empty controls send only their displayed identities over 0x76")
    func displayedActionBytes() throws {
        let state = AgentQueueState()
        state.update(try visibleQueue(in: queueCommand()))
        let drawn = try #require(state.snapshot)
        let row = try #require(drawn.pending.first)
        let select = drawn.select(row)
        let paste = try #require(drawn.request(for: .pasteBefore))
        let close = try #require(drawn.request(for: .close))
        state.update(try visibleQueue(in: queueCommand(empty: true)))
        let empty = try #require(state.snapshot)
        let action = try #require(empty.empty?.actions.first)
        let composer = try #require(empty.request(forEmptyAction: action))
        #expect(empty.request(for: .remove) == nil)
        #expect(empty.request(for: .edit) == nil)
        #expect(empty.request(for: .pasteAfter) == nil)

        let pipe = Pipe()
        let encoder = try ProtocolEncoder(output: pipe.fileHandleForWriting)
        for request in [select, paste, close, composer] {
            #expect(encoder.send(FrontendActionComposition.outbound(AgentChatView.Action.queue(request))) == .accepted)
        }
        guard case .rejected(.invalidPayload) = encoder.send(.agentQueueAction(.pasteAfter, origin: drawn.origin, row: nil, removed: drawn.removed.first?.identity)) else {
            Issue.record("A paste without a displayed pending anchor entered transport")
            return
        }
        #expect(encoder.waitForPendingWritesForTesting())
        try pipe.fileHandleForWriting.close()
        let raw = pipe.fileHandleForReading.readDataToEndOfFile()
        let record: [UInt8] = [0, 7, 114, 195, 169, 99, 111, 114, 100]
        let zeros = [UInt8](repeating: 0, count: 16)
        func expected(_ action: UInt8, pairs: [UInt8]) -> Data {
            Data([0, 0, 0, 48, 0x07, 0x76, action, 0x12, 0x34, 0x56, 0x78] + record + pairs)
        }
        let expectedActions = expected(0, pairs: [0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 3, 4, 5, 6, 7, 8] + zeros)
            + expected(3, pairs: [0, 0, 0, 0, 0, 0, 0, 32, 1, 2, 3, 4, 5, 6, 7, 8,
                                   0, 0, 0, 0, 0, 0, 0, 51, 8, 7, 6, 5, 4, 3, 2, 1])
            + expected(5, pairs: zeros + zeros) + expected(6, pairs: zeros + zeros)
        #expect(raw.prefix(expectedActions.count) == expectedActions)
        // Invalid payloads report a diagnostic frame, not a GUI action.
        try #require(raw.count > expectedActions.count)
        var diagnostic = try ByteCursor(raw, range: expectedActions.count..<raw.count)
        let diagnosticLength = try diagnostic.readUInt32()
        let diagnosticOpcode = try diagnostic.readUInt8()
        #expect(diagnosticLength == diagnostic.remaining + 1)
        #expect(diagnosticOpcode == OP_LOG_MESSAGE)
    }

    private func visibleQueue(in packet: Data) throws -> Wire.AgentQueue {
        let (command, size) = try decodeCommand(data: packet, offset: 0)
        #expect(size == packet.count)
        guard case .guiAgentQueue(let queue) = command else {
            throw ProtocolDecodeError.malformed
        }
        return try #require(queue)
    }

    private func framed(_ body: [UInt8]) -> Data {
        var result = Data([0xAE])
        result.append(contentsOf: withUnsafeBytes(of: UInt32(body.count).bigEndian, Array.init))
        result.append(contentsOf: body)
        return result
    }

    private func queueCommand(empty: Bool = false, rowRevision: UInt64 = 0x0102030405060708) -> Data {
        var payload: [UInt8] = [1, 1, 0x12, 0x34, 0x56, 0x78]
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.bigEndian) { payload.append(contentsOf: $0) }
        }
        func string8(_ text: String) {
            append(UInt8(text.utf8.count))
            payload.append(contentsOf: text.utf8)
        }
        func string16(_ text: String) {
            append(UInt16(text.utf8.count))
            payload.append(contentsOf: text.utf8)
        }
        func row(id: UInt64, revision: UInt64, kind: UInt8, attachments: UInt16) {
            append(id)
            append(revision)
            append(kind)
            string8(String(id))
            string16("Preview \(id) 🧩")
            append(attachments)
        }
        string16("récord")
        string16("*minga-queue*")
        string16(empty ? "Queue" : "32 queued")
        string16(empty ? "" : "Removed, not sent.")
        append(UInt64(empty ? 0 : 32))
        if empty {
            payload += [1, 5]
            string8("q")
            string16("close")
            payload += [0, 0]
        } else {
            payload += [1, 3]
            string8("P")
            string16("before")
            payload.append(32)
            for id in 1...32 {
                row(id: UInt64(id), revision: rowRevision, kind: id == 32 ? 1 : 0, attachments: id == 32 ? 2 : 0)
            }
            payload.append(2)
            row(id: 51, revision: 0x0807060504030201, kind: 1, attachments: 0)
            row(id: 52, revision: 7, kind: 0, attachments: 3)
        }
        string8("")
        string16(empty ? "Nothing queued." : "")
        string16(empty ? "Queued messages wait here." : "")
        payload += [0, empty ? 1 : 0]
        if empty {
            string8("queue_return_to_composer")
            string16("↩")
            string16("Back to the composer")
        }
        return framed(payload)
    }
}
