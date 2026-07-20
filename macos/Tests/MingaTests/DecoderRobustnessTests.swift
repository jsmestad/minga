/// Tests for protocol decoder robustness against malformed input.
///
/// Verifies the decoder throws ProtocolDecodeError (not crashes) when
/// receiving truncated, empty, or otherwise invalid binary data. This
/// is critical for 0.1.0 stability: if the BEAM process crashes mid-write
/// or the port buffer is corrupted, the GUI should log an error and
/// continue, not segfault or panic.

import Testing
import Foundation

// MARK: - Empty and minimal payloads

@Suite("Decoder Robustness: Empty Input")
struct DecoderEmptyInputTests {

    @Test("Empty data throws insufficientData")
    func emptyData() {
        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: Data(), offset: 0)
        }
    }

    @Test("Offset past end throws insufficientData")
    func offsetPastEnd() {
        let data = Data([OP_COMMIT_FRAME])
        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 5)
        }
    }

    @Test("Unknown opcode throws unknownOpcode")
    func unknownOpcode() {
        let data = Data([0xFE])  // Not a valid opcode
        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }
}

// MARK: - Truncated basic commands

@Suite("Decoder Robustness: Truncated Basic Commands")
struct DecoderTruncatedBasicTests {

    @Test("set_title truncated (length prefix but no text)")
    func truncatedSetTitle() {
        var data = Data([OP_SET_TITLE])
        data.append(contentsOf: [0x00, 0x10]) // title_len=16 but no text
        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("set_font truncated")
    func truncatedSetFont() {
        var data = Data([OP_SET_FONT])
        data.append(contentsOf: [0x00, 0x0D]) // size=13
        // Missing weight, ligatures, name_len, name
        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }
}

// MARK: - Truncated GUI chrome commands

@Suite("Decoder Robustness: Truncated GUI Chrome")
struct DecoderTruncatedGUIChromeTests {

    @Test("gui_theme truncated (count says 5 but only 2 slots)")
    func truncatedTheme() {
        var data = Data([OP_GUI_THEME])
        data.append(5) // 5 slots claimed
        // Only 2 slots provided (8 bytes instead of 20)
        data.append(contentsOf: [0x01, 0xFF, 0x00, 0x00])
        data.append(contentsOf: [0x02, 0x00, 0xFF, 0x00])

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("gui_tab_bar truncated tab entry")
    func truncatedTabBar() {
        var data = Data([OP_GUI_TAB_BAR])
        data.append(0) // active_index
        data.append(1) // tab_count=1
        // Tab needs flags(1)+id(4)+icon_len(1)+icon+label_len(2)+label
        // Provide only flags+id (5 bytes), missing icon_len
        data.append(0x01) // flags
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // id
        // Missing icon_len

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("gui_completion visible but truncated items")
    func truncatedCompletion() {
        var data = Data([OP_GUI_COMPLETION])
        data.append(1) // visible
        data.append(contentsOf: [0x00, 0x05]) // anchorRow
        data.append(contentsOf: [0x00, 0x0A]) // anchorCol
        data.append(contentsOf: [0x00, 0x00]) // selectedIndex
        data.append(contentsOf: [0x00, 0x03]) // itemCount=3
        // No item data

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("gui_which_key visible but truncated bindings")
    func truncatedWhichKey() {
        var data = Data([OP_GUI_WHICH_KEY])
        data.append(1) // visible
        data.append(contentsOf: [0x00, 0x03]) // prefix_len=3
        data.append(contentsOf: "SPC".utf8)
        data.append(0) // page
        data.append(1) // pageCount
        data.append(contentsOf: [0x00, 0x05]) // bindingCount=5
        // No binding data

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("gui_status_bar truncated section header")
    func truncatedStatusBar() {
        var data = Data([OP_GUI_STATUS_BAR])
        data.append(1) // section_count = 1
        data.append(0x01) // section_id = identity
        // Missing section_len (needs 2 bytes)

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("gui_picker truncated section header")
    func truncatedPicker() {
        var data = Data([OP_GUI_PICKER])
        data.append(1) // section_count = 1
        data.append(0x01) // section_id
        // Missing section_len (needs 2 bytes)

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("gui_agent_chat truncated section header")
    func truncatedAgentChat() {
        var data = Data([OP_GUI_AGENT_CHAT])
        data.append(2) // section_count = 2
        data.append(0x01) // section_id
        // Missing section_len

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("gui_file_tree truncated entry")
    func truncatedFileTree() {
        var payload = Data()
        payload.append(1) // version
        payload.append(0x03) // visible + focused
        payload.append(contentsOf: [0x00, 0x00]) // selected_id_len
        payload.append(contentsOf: [0x00, 0x00]) // root_len
        payload.append(contentsOf: [0x00, 0x1E]) // treeWidth
        payload.append(contentsOf: [0x00, 0x01]) // rowCount=1
        payload.append(0xAA) // incomplete row

        var data = Data([OP_GUI_FILE_TREE])
        data.append(contentsOf: [0x00, 0x00, 0x00, UInt8(payload.count)])
        data.append(payload)

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("gui_gutter truncated section payload")
    func truncatedGutter() {
        var data = Data([OP_GUI_GUTTER])
        data.append(1) // section_count = 1
        data.append(0x01) // section_id
        data.append(contentsOf: [0x00, 0x20]) // section_len = 32 (but only 0 bytes follow)

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("gui_bottom_panel visible but truncated tabs")
    func truncatedBottomPanel() {
        var data = Data([OP_GUI_BOTTOM_PANEL])
        data.append(1) // visible
        data.append(0) // activeTabIndex
        data.append(30) // heightPercent
        data.append(0) // filterPreset
        data.append(3) // tabCount=3
        // No tab data

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("gui_window_content truncated section payload")
    func truncatedWindowContent() {
        var data = Data([OP_GUI_WINDOW_CONTENT])
        appendU32(&data, 6) // payload_len = section_count + incomplete section header
        data.append(1) // section_count = 1
        data.append(0x01) // section_id
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x40]) // section_len = 64 (but only 0 bytes follow)

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("gui_window_content truncated advertised row payload")
    func truncatedWindowContentRow() {
        var rowBytes = Data()
        rowBytes.append(0x00) // rowType = normal
        appendU64(&rowBytes, 1)
        appendU32(&rowBytes, 0)
        appendU32(&rowBytes, 0x1234_5678)
        appendU32(&rowBytes, 1)
        rowBytes.append(0x61)
        rowBytes.append(0x00) // only one byte of span_count

        let data = windowContentData(rowsPayload: windowContentRowsPayload(rowBytes: rowBytes))
        expectMalformedWindowContent(data)
    }

    @Test("gui_window_content truncated advertised span payload")
    func truncatedWindowContentSpan() {
        var rowBytes = Data()
        rowBytes.append(0x00) // rowType = normal
        appendU64(&rowBytes, 1)
        appendU32(&rowBytes, 0)
        appendU32(&rowBytes, 0x1234_5678)
        appendU32(&rowBytes, 1)
        rowBytes.append(0x61)
        appendU16(&rowBytes, 1)
        appendU16(&rowBytes, 0)
        appendU16(&rowBytes, 1)
        rowBytes.append(contentsOf: [0xFF, 0x00, 0x00])
        rowBytes.append(contentsOf: [0x00, 0x00, 0x00])
        rowBytes.append(0x00)
        rowBytes.append(0x00) // missing the last byte of the span payload

        let data = windowContentData(rowsPayload: windowContentRowsPayload(rowBytes: rowBytes))
        expectMalformedWindowContent(data)
    }
}

private func windowContentData(rowsPayload: Data, scrollSeq: UInt32? = nil) -> Data {
    var headerPayload = Data()
    appendU16(&headerPayload, 1) // window_id
    headerPayload.append(0x03) // flags
    appendU16(&headerPayload, 0) // cursor_row
    appendU16(&headerPayload, 0) // cursor_col
    headerPayload.append(0x00) // cursor_shape
    appendU16(&headerPayload, 0) // scroll_left
    if scrollSeq != nil {
        appendU32(&headerPayload, 42) // content_epoch, matched by the scroll_presentation section below
    }

    var payload = Data()
    payload.append(scrollSeq != nil ? 3 : 2)
    payload.append(windowContentSection(id: 0x01, payload: headerPayload))
    payload.append(windowContentSection(id: 0x02, payload: rowsPayload))

    if let scrollSeq {
        var scrollPresentationPayload = Data()
        appendU16(&scrollPresentationPayload, 1) // window_id
        scrollPresentationPayload.append(0x00) // flags
        appendU32(&scrollPresentationPayload, 5) // anchor_top
        appendU16(&scrollPresentationPayload, 0) // anchor_left
        appendU16(&scrollPresentationPayload, 0) // anchor_visual_row_offset
        appendU32(&scrollPresentationPayload, 5) // visible_start_line
        appendU32(&scrollPresentationPayload, 10) // visible_end_line
        appendU32(&scrollPresentationPayload, 0) // overscan_start_line
        appendU32(&scrollPresentationPayload, 20) // overscan_end_line
        appendU32(&scrollPresentationPayload, 42) // content_epoch (matches header above)
        appendU32(&scrollPresentationPayload, 7) // layout_generation
        appendU32(&scrollPresentationPayload, scrollSeq) // scroll_seq

        payload.append(windowContentSection(id: 0x0A, payload: scrollPresentationPayload))
    }

    var data = Data([OP_GUI_WINDOW_CONTENT])
    appendU32(&data, UInt32(payload.count))
    data.append(payload)
    return data
}

private func windowContentSection(id: UInt8, payload: Data) -> Data {
    var section = Data([id])
    appendU32(&section, UInt32(payload.count))
    section.append(payload)
    return section
}

private func windowContentRowsPayload(rowBytes: Data) -> Data {
    var payload = Data()
    appendU32(&payload, 1)
    payload.append(rowBytes)
    return payload
}

private func windowContentData(sections: [Data]) -> Data {
    var payload = Data([UInt8(sections.count)])
    for section in sections {
        payload.append(section)
    }

    var data = Data([OP_GUI_WINDOW_CONTENT])
    appendU32(&data, UInt32(payload.count))
    data.append(payload)
    return data
}

private func windowDeltaData(opcode: UInt8, header: Data, rows: Data) -> Data {
    var data = Data([opcode, 2])
    data.append(windowContentSection(id: 0x01, payload: header))
    data.append(windowContentSection(id: 0x02, payload: rows))
    return data
}

private func appendU16(_ data: inout Data, _ value: UInt16) {
    data.append(UInt8(value >> 8))
    data.append(UInt8(value & 0xFF))
}

private func appendU32(_ data: inout Data, _ value: UInt32) {
    data.append(UInt8((value >> 24) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
}

private func appendU64(_ data: inout Data, _ value: UInt64) {
    data.append(UInt8((value >> 56) & 0xFF))
    data.append(UInt8((value >> 48) & 0xFF))
    data.append(UInt8((value >> 40) & 0xFF))
    data.append(UInt8((value >> 32) & 0xFF))
    data.append(UInt8((value >> 24) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
}

private func expectMalformedWindowContent(_ data: Data) {
    do {
        _ = try decodeCommand(data: data, offset: 0)
        Issue.record("Expected ProtocolDecodeError.malformed")
    } catch ProtocolDecodeError.malformed {
    } catch {
        Issue.record("Expected ProtocolDecodeError.malformed, got \(error)")
    }
}

// MARK: - Scroll presentation scroll_seq field (#2661)

@Suite("Decoder: Scroll Presentation scroll_seq (#2661)")
struct DecoderScrollPresentationScrollSeqTests {

    private static func emptyRowsPayload() -> Data {
        var payload = Data()
        appendU32(&payload, 0) // row_count = 0
        return payload
    }

    @Test("decodes the scroll_seq field appended to the scroll_presentation section")
    func decodesScrollSeq() throws {
        let data = windowContentData(rowsPayload: Self.emptyRowsPayload(), scrollSeq: 99)

        let (command, _) = try decodeCommand(data: data, offset: 0)
        guard case .guiWindowContent(let content) = command else {
            Issue.record("Expected guiWindowContent")
            return
        }
        #expect(content.scrollPresentation?.scrollSeq == 99)
    }

    @Test("truncated scroll_presentation section (missing scroll_seq bytes) throws malformed")
    func truncatedScrollSeq() {
        var data = windowContentData(rowsPayload: Self.emptyRowsPayload(), scrollSeq: 99)
        // Chop off the last 2 of the 4 scroll_seq bytes; the section's declared
        // length still claims the full 39 bytes so the decoder must reject it
        // rather than reading past the truncated buffer.
        data.removeLast(2)

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }
}

// MARK: - Forward-compatible unknown opcodes (0x90+)

@Suite("Decoder Robustness: Unknown Opcodes Fail Closed")
struct DecoderForwardCompatTests {

    @Test("Unknown opcode >= 0x90 with valid length prefix is rejected")
    func skipUnknownOpcode() {
        let data = Data([0xFE, 0x00, 0x04, 0xDE, 0xAD, 0xBE, 0xEF])
        #expect(throws: ProtocolDecodeError.self) {
            _ = try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("Unknown opcode prevents subsequent command publication")
    func skipThenDecode() {
        let data = Data([0xFE, 0x00, 0x00, OP_SET_CURSOR_SHAPE, CURSOR_BLOCK])
        var commands: [RenderCommand] = []
        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommands(from: data) { commands.append($0) }
        }
        #expect(commands.isEmpty)
    }

    @Test("Unknown opcode with zero-length payload is rejected")
    func skipZeroPayload() {
        #expect(throws: ProtocolDecodeError.self) {
            _ = try decodeCommand(data: Data([0xB0, 0x00, 0x00]), offset: 0)
        }
    }

    @Test("First unknown opcode rejects the complete packet")
    func skipMultipleUnknown() {
        let data = Data([0xFD, 0x00, 0x00, 0xFC, 0x00, 0x00])
        #expect(throws: ProtocolDecodeError.self) {
            _ = try decodeFrame(from: data)
        }
    }

    @Test("Known opcode 0x90 (clipboard_write) is NOT skipped")
    func knownOpcodeNotSkipped() throws {
        // OP_CLIPBOARD_WRITE (0x90) uses the length-prefixed format but is a known opcode
        var data = Data()
        data.append(OP_CLIPBOARD_WRITE) // 0x90
        // payload: target(1) + text_len(4) + text
        let text = "hello"
        let payloadLen = 1 + 4 + text.utf8.count // 10
        data.append(contentsOf: [0x00, 0x00, 0x00, UInt8(payloadLen)])
        data.append(0x00) // target = general pasteboard
        data.append(contentsOf: [0x00, 0x00, 0x00, UInt8(text.utf8.count)])
        data.append(contentsOf: text.utf8)

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(cmd != nil, "Known 0x90 opcode should decode, not skip")
        #expect(size == 1 + 4 + payloadLen)
        guard case .clipboardWrite(let target, let decoded) = cmd else {
            Issue.record("Expected .clipboardWrite, got \(String(describing: cmd))"); return
        }
        #expect(target == 0x00)
        #expect(decoded == "hello")
    }

    @Test("Unknown opcode below 0x90 still throws unknownOpcode")
    func unknownBelowThreshold() {
        // Opcode 0x8F is below the forward-compat threshold
        let data = Data([0x8F])
        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("Unknown opcode >= 0x90 with truncated length throws malformed")
    func truncatedLengthThrows() {
        // Only 1 byte of the 2-byte length prefix
        let data = Data([0xFE, 0x00])
        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("Unknown opcode >= 0x90 with truncated payload throws malformed")
    func truncatedPayloadThrows() {
        // Length says 10 bytes but only 3 available
        var data = Data()
        data.append(0xFE)
        data.append(contentsOf: [0x00, 0x0A]) // payload_length = 10
        data.append(contentsOf: [0x01, 0x02, 0x03]) // only 3 bytes

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }
}

// MARK: - Edge cases

@Suite("Decoder Robustness: Edge Cases")
struct DecoderEdgeCaseTests {

    @Test("Valid hidden states don't throw (minimal payloads)")
    func hiddenStatesValid() throws {
        // All "hidden" variants are 2-byte payloads that should decode cleanly
        let hiddenPayloads: [(Data, String)] = [
            (Data([OP_GUI_COMPLETION, 0]), "completion"),
            (Data([OP_GUI_WHICH_KEY, 0]), "which_key"),
            (Data([OP_GUI_PICKER, 0]), "picker"),
            (Data([OP_GUI_PICKER_PREVIEW, 0]), "picker_preview"),
            (Data([OP_GUI_AGENT_CHAT, 0]), "agent_chat"),
            (Data([OP_GUI_BOTTOM_PANEL, 0]), "bottom_panel"),
        ]

        for (payload, name) in hiddenPayloads {
            let (cmd, size) = try decodeCommand(data: payload, offset: 0)
            #expect(cmd != nil, "Hidden \(name) should decode to a command")
            #expect(size == 2, "Hidden \(name) should consume 2 bytes")
        }
    }

    @Test("Small fixed-size command at end of buffer doesn't over-read")
    func smallFixedAtEnd() throws {
        let (cmd, size) = try decodeCommand(data: Data([OP_SET_CURSOR_SHAPE, CURSOR_BLOCK]), offset: 0)
        #expect(size == 2)
        guard case .setCursorShape = cmd else {
            Issue.record("Expected .setCursorShape"); return
        }
    }

    @Test("set_window_bg with exact 4 bytes succeeds")
    func exactWindowBg() throws {
        let data = Data([OP_SET_WINDOW_BG, 0x28, 0x2C, 0x34])
        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 4)
        #expect(cmd != nil)
    }

    @Test("decodeCommands stops cleanly at end of valid multi-command payload")
    func multiCommandStopsCleanly() throws {
        var data = Data()
        data.append(OP_SET_CURSOR_SHAPE)
        data.append(CURSOR_BLOCK)
        data.append(OP_COMMIT_FRAME)
        data.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0]) // commit_frame frame_seq + echoed input_seq (fixed:9, #2219/#2215)

        var commands: [RenderCommand] = []
        try decodeCommands(from: data) { cmd in
            commands.append(cmd)
        }
        #expect(commands.count == 2)
    }

    @Test("decodeCommands includes opcode and offset context on malformed command")
    func malformedMultiCommandReportsContext() throws {
        var data = Data()
        data.append(OP_SET_CURSOR_SHAPE)
        data.append(CURSOR_BLOCK)
        data.append(OP_SET_TITLE)
        data.append(contentsOf: [0x00, 0x05, 0x68])

        do {
            try decodeCommands(from: data) { _ in }
            Issue.record("Expected decodeCommands to throw")
        } catch let error as ProtocolDecodeError {
            guard case .commandFailed(let opcode, let offset, let remaining, let cause) = error else {
                Issue.record("Expected contextual commandFailed error, got \(String(describing: error))")
                return
            }

            #expect(opcode == OP_SET_TITLE)
            #expect(offset == 2)
            #expect(remaining == 4)
            #expect(String(describing: cause) == "insufficient data" || String(describing: cause) == "malformed")
            #expect(String(describing: error).contains("opcode 0x"))
            #expect(String(describing: error).contains("offset 2"))
        }
    }

    @Test("Zero-length strings decode correctly")
    func zeroLengthStrings() throws {
        var data = Data([OP_SET_TITLE])
        data.append(contentsOf: [0x00, 0x00]) // title_len=0

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 3)
        guard case .setTitle(let title) = cmd else {
            Issue.record("Expected .setTitle"); return
        }
        #expect(title == "")
    }

    @Test("gui_theme with zero slots succeeds")
    func zeroSlotTheme() throws {
        let data = Data([OP_GUI_THEME, 0])
        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 2)
        guard case .guiTheme(let slots) = cmd else {
            Issue.record("Expected .guiTheme"); return
        }
        #expect(slots.isEmpty)
    }

    @Test("gui_breadcrumb with zero segments succeeds")
    func zeroSegmentBreadcrumb() throws {
        let data = Data([OP_GUI_BREADCRUMB, 0])
        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 2)
        guard case .guiBreadcrumb(let segments) = cmd else {
            Issue.record("Expected .guiBreadcrumb"); return
        }
        #expect(segments.isEmpty)
    }

    @Test("gui_window_content rejects an impossible u32 row count")
    func rejectsImpossibleWindowRowCount() {
        let data = Data([OP_GUI_WINDOW_CONTENT, 0, 0, 0, 9, 1, 0x02, 0, 0, 0, 4, 0xFF, 0xFF, 0xFF, 0xFF])

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }
}

@Suite("Decoder Robustness: u32 Window Framing")
struct DecoderU32WindowFramingTests {
    private let header = Data([0, 1, 0x03, 0, 0, 0, 0, 0, 0, 0])
    private let deltaHeader = Data([0, 1, 0, 0, 0, 1, 0x01, 0, 0, 0, 0, 0, 0, 0])
    private let emptyRows = Data([0, 0, 0, 0])

    @Test("gui_window_content requires one header and rows section")
    func requiresHeaderAndRows() {
        let headerSection = windowContentSection(id: 0x01, payload: header)
        let rowsSection = windowContentSection(id: 0x02, payload: emptyRows)
        let invalidCommands = [
            windowContentData(sections: []),
            windowContentData(sections: [headerSection]),
            windowContentData(sections: [rowsSection]),
            windowContentData(sections: [headerSection, headerSection, rowsSection]),
            windowContentData(sections: [headerSection, rowsSection, rowsSection])
        ]

        for data in invalidCommands {
            #expect(throws: ProtocolDecodeError.self) {
                try decodeCommand(data: data, offset: 0)
            }
        }
    }

    @Test("window deltas reject truncated sections and trailing row bytes")
    func rejectsMalformedDeltaSections() {
        for opcode in [OP_GUI_WINDOW_ROWS_DELTA, OP_GUI_WINDOW_VIEWPORT_DELTA] {
            var truncatedSection = Data([opcode, 1, 0x01])
            appendU32(&truncatedSection, 15)
            truncatedSection.append(deltaHeader)

            #expect(throws: ProtocolDecodeError.self) {
                try decodeCommand(data: truncatedSection, offset: 0)
            }

            let trailingRows = Data([0, 0, 0, 0, 0xFF])
            let trailingRowsCommand = windowDeltaData(opcode: opcode, header: deltaHeader, rows: trailingRows)
            #expect(throws: ProtocolDecodeError.self) {
                try decodeCommand(data: trailingRowsCommand, offset: 0)
            }
        }
    }

    @Test("clipboard_write decodes more than UInt16 bytes")
    func decodesLargeClipboardWrite() throws {
        let text = Data(repeating: 0x78, count: 65_536)
        var data = Data([OP_CLIPBOARD_WRITE])
        appendU32(&data, UInt32(5 + text.count))
        data.append(0)
        appendU32(&data, UInt32(text.count))
        data.append(text)

        let (command, _) = try decodeCommand(data: data, offset: 0)
        guard case .clipboardWrite(_, let decoded) = command else {
            Issue.record("Expected clipboardWrite")
            return
        }
        #expect(decoded.utf8.count == text.count)
    }

    @Test("window deltas decode more than UInt16 rows")
    func decodesLargeWindowDelta() throws {
        let rowCount = 65_536
        var rows = Data()
        appendU32(&rows, UInt32(rowCount))

        for rowId in 0..<rowCount {
            rows.append(0)
            appendU64(&rows, UInt64(rowId))
            appendU32(&rows, 0)
        }

        let data = windowDeltaData(opcode: OP_GUI_WINDOW_ROWS_DELTA, header: deltaHeader, rows: rows)
        let (command, _) = try decodeCommand(data: data, offset: 0)
        guard case .guiWindowRowsDelta(let delta) = command else {
            Issue.record("Expected guiWindowRowsDelta")
            return
        }
        #expect(delta.rows.count == rowCount)
    }
}
