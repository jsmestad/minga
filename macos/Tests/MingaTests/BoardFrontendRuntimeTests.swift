import Testing
import Foundation

private func appendBoardRuntimeU16(_ data: inout Data, _ value: UInt16) {
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
}

private func appendBoardRuntimeU32(_ data: inout Data, _ value: UInt32) {
    data.append(UInt8((value >> 24) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
}

private func appendBoardRuntimeString16(_ data: inout Data, _ value: String) {
    let bytes = Array(value.utf8)
    appendBoardRuntimeU16(&data, UInt16(bytes.count))
    data.append(contentsOf: bytes)
}

private func sampleBoardRuntimePayload() -> Data {
    var payload = Data([0x87, 0x01])
    appendBoardRuntimeU32(&payload, 0x0000002A)
    appendBoardRuntimeU16(&payload, 0x0001)
    payload.append(0x01)
    appendBoardRuntimeString16(&payload, "auth")
    appendBoardRuntimeU32(&payload, 0x0000002A)
    payload.append(0x03)
    payload.append(0x03)
    appendBoardRuntimeString16(&payload, "fix auth")
    payload.append(0x08)
    payload.append(contentsOf: Array("claude-4".utf8))
    appendBoardRuntimeU32(&payload, 0x00000064)
    payload.append(0x01)
    appendBoardRuntimeString16(&payload, "lib/auth.ex")
    payload.append(0x02)
    appendBoardRuntimeU16(&payload, 0x0000)
    appendBoardRuntimeU16(&payload, 0xFFFF)
    return payload
}

/// Zoomed-state payload: visible=0, the single card is status working, and the
/// trailing zoomed_card_id points at it (matching the BEAM's zoomed encoding).
private func sampleZoomedBoardRuntimePayload() -> Data {
    var payload = Data([0x87, 0x00])
    appendBoardRuntimeU32(&payload, 0x0000002A)  // focused id
    appendBoardRuntimeU16(&payload, 0x0001)  // card count
    payload.append(0x00)  // filter mode off
    appendBoardRuntimeString16(&payload, "")  // empty filter text
    appendBoardRuntimeU32(&payload, 0x0000002A)  // card id
    payload.append(0x01)  // status working
    payload.append(0x02)  // flags: focused
    appendBoardRuntimeString16(&payload, "fix auth")
    payload.append(0x08)
    payload.append(contentsOf: Array("claude-4".utf8))
    appendBoardRuntimeU32(&payload, 0x00000064)  // timestamp
    payload.append(0x00)  // recent file count
    payload.append(0x00)  // sparkline count
    appendBoardRuntimeU32(&payload, 0x0000002A)  // zoomed_card_id trailer
    return payload
}

private func extensionRuntimeEnvelope(extensionID: String, channel: String, payload: Data) -> Data {
    var body = Data()
    appendBoardRuntimeString16(&body, extensionID)
    appendBoardRuntimeString16(&body, channel)
    body.append(payload)
    var data = Data([OP_GUI_EXTENSION_RUNTIME])
    appendBoardRuntimeU32(&data, UInt32(body.count))
    data.append(body)
    return data
}

private func captureBoardActionFrame(_ action: (ProtocolEncoder) -> Void) -> Data {
    let pipe = Pipe()
    let encoder = ProtocolEncoder(output: pipe.fileHandleForWriting)
    action(encoder)
    #expect(encoder.waitForPendingWritesForTesting())
    pipe.fileHandleForWriting.closeFile()
    let raw = pipe.fileHandleForReading.readDataToEndOfFile()
    guard raw.count >= 4 else { return Data() }
    let len = Int(raw[0]) << 24 | Int(raw[1]) << 16 | Int(raw[2]) << 8 | Int(raw[3])
    guard raw.count >= 4 + len else { return Data() }
    return raw.subdata(in: 4..<(4 + len))
}

private func expectedBoardExtensionAction(action: String, payload: [UInt8]) -> Data {
    var data = Data([OP_GUI_ACTION, GUI_ACTION_EXTENSION_ACTION])
    appendBoardRuntimeString16(&data, "minga_board")
    appendBoardRuntimeString16(&data, action)
    data.append(contentsOf: payload)
    return data
}

@Suite("Board Frontend Runtime")
struct BoardFrontendRuntimeTests {
    @Test("decodes generic runtime envelope into Board state")
    @MainActor func decodeRuntimeEnvelopeIntoBoardState() throws {
        let boardPayload = sampleBoardRuntimePayload()
        let envelope = extensionRuntimeEnvelope(extensionID: "minga_board", channel: "board", payload: boardPayload)
        let (cmd, size) = try decodeCommand(data: envelope, offset: 0)
        #expect(size == envelope.count)
        guard case .guiExtensionRuntime(let message) = cmd else {
            Issue.record("Expected guiExtensionRuntime, got \(String(describing: cmd))")
            return
        }
        #expect(message.extensionID == "minga_board")
        #expect(message.channel == "board")
        #expect(message.payload == boardPayload)

        BoardFrontendRuntime.resetForTesting()
        let registry = FrontendExtensionRuntimeRegistry()
        BoardFrontendRuntime.register(into: registry, encoder: nil, theme: ThemeColors())
        registry.dispatch(message)

        let state = BoardFrontendRuntime.stateForTesting
        #expect(state.visible)
        #expect(state.focusedCardId == 0x0000002A)
        #expect(state.filterMode)
        #expect(state.filterText == "auth")
        #expect(state.cards.count == 1)
        let card = try #require(state.cards.first)
        #expect(card.id == 0x0000002A)
        #expect(card.status == .needsYou)
        #expect(card.isYouCard)
        #expect(card.isFocused)
        #expect(card.task == "fix auth")
        #expect(card.model == "claude-4")
        #expect(card.dispatchTimestamp == 0x00000064)
        #expect(card.recentFiles == ["lib/auth.ex"])
        #expect(card.sparkline.count == 2)
    }

    @Test("decodes zoomed_card_id trailer and resolves the zoomed card")
    @MainActor func decodeZoomedCardIdTrailer() throws {
        let payload = sampleZoomedBoardRuntimePayload()
        let envelope = extensionRuntimeEnvelope(extensionID: "minga_board", channel: "board", payload: payload)
        let (cmd, _) = try decodeCommand(data: envelope, offset: 0)
        guard case .guiExtensionRuntime(let message) = cmd else {
            Issue.record("Expected guiExtensionRuntime, got \(String(describing: cmd))")
            return
        }

        BoardFrontendRuntime.resetForTesting()
        let registry = FrontendExtensionRuntimeRegistry()
        BoardFrontendRuntime.register(into: registry, encoder: nil, theme: ThemeColors())
        registry.dispatch(message)

        let state = BoardFrontendRuntime.stateForTesting
        // Grid is hidden while zoomed, but the zoomed card resolves for the header.
        #expect(!state.visible)
        #expect(state.zoomedCardId == 0x0000002A)
        let zoomed = try #require(state.zoomedCard)
        #expect(zoomed.id == 0x0000002A)
        #expect(zoomed.task == "fix auth")
        #expect(zoomed.model == "claude-4")
        #expect(zoomed.status == .working)
    }

    @Test("payload without zoomed trailer leaves the board un-zoomed")
    @MainActor func decodeWithoutZoomTrailer() throws {
        // The grid-view sample payload has no zoomed_card_id trailer; the decoder
        // must tolerate it and report no zoomed card.
        let payload = sampleBoardRuntimePayload()
        let envelope = extensionRuntimeEnvelope(extensionID: "minga_board", channel: "board", payload: payload)
        let (cmd, _) = try decodeCommand(data: envelope, offset: 0)
        guard case .guiExtensionRuntime(let message) = cmd else {
            Issue.record("Expected guiExtensionRuntime, got \(String(describing: cmd))")
            return
        }

        BoardFrontendRuntime.resetForTesting()
        let registry = FrontendExtensionRuntimeRegistry()
        BoardFrontendRuntime.register(into: registry, encoder: nil, theme: ThemeColors())
        registry.dispatch(message)

        let state = BoardFrontendRuntime.stateForTesting
        #expect(state.zoomedCardId == nil)
        #expect(state.zoomedCard == nil)
    }

    @Test("truncated generic extension runtime envelope throws")
    func truncatedRuntimeEnvelopeThrows() {
        var data = Data([OP_GUI_EXTENSION_RUNTIME])
        appendBoardRuntimeU32(&data, 0x00000010)
        data.append(contentsOf: [0x00, 0x0B, 0x6D, 0x69, 0x6E, 0x67, 0x61])

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("Board action helpers encode exact generic extension action bytes")
    func encodeBoardActions() {
        #expect(captureBoardActionFrame { $0.sendBoardSelectCard(id: 0x01020304) } == expectedBoardExtensionAction(action: "select_card", payload: [0x01, 0x02, 0x03, 0x04]))
        #expect(captureBoardActionFrame { $0.sendBoardCloseCard(id: 0x01020304) } == expectedBoardExtensionAction(action: "close_card", payload: [0x01, 0x02, 0x03, 0x04]))
        #expect(captureBoardActionFrame { $0.sendBoardReorder(cardId: 0x01020304, newIndex: 0x0506) } == expectedBoardExtensionAction(action: "reorder", payload: [0x01, 0x02, 0x03, 0x04, 0x05, 0x06]))
        #expect(captureBoardActionFrame { $0.sendBoardDispatchAgent(task: "fix auth", model: "claude-4") } == expectedBoardExtensionAction(action: "dispatch_agent", payload: [0x00, 0x08, 0x66, 0x69, 0x78, 0x20, 0x61, 0x75, 0x74, 0x68, 0x00, 0x08, 0x63, 0x6C, 0x61, 0x75, 0x64, 0x65, 0x2D, 0x34]))
    }
}
