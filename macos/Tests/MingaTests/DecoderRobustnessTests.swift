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
        let data = Data([OP_CLEAR])
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

    @Test("set_cursor truncated (only 3 bytes instead of 5)")
    func truncatedSetCursor() {
        let data = Data([OP_SET_CURSOR, 0x00, 0x05]) // missing col bytes
        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("draw_text truncated header")
    func truncatedDrawTextHeader() {
        // draw_text needs 13 bytes after opcode; provide only 5
        let data = Data([OP_DRAW_TEXT, 0x00, 0x01, 0x00, 0x02, 0xFF])
        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("draw_text truncated text body")
    func truncatedDrawTextBody() {
        // Header says text_len=10 but only 3 bytes of text follow
        var data = Data()
        data.append(OP_DRAW_TEXT)
        data.append(contentsOf: [0x00, 0x00]) // row
        data.append(contentsOf: [0x00, 0x00]) // col
        data.append(contentsOf: [0xFF, 0x00, 0x00]) // fg
        data.append(contentsOf: [0x00, 0x00, 0x00]) // bg
        data.append(0x00) // attrs
        data.append(contentsOf: [0x00, 0x0A]) // text_len=10
        data.append(contentsOf: "Hi".utf8) // only 2 bytes, not 10

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("draw_styled_text truncated header")
    func truncatedDrawStyledText() {
        // Needs 20 bytes after opcode; provide only 10
        var data = Data([OP_DRAW_STYLED_TEXT])
        data.append(contentsOf: Array(repeating: UInt8(0), count: 10))
        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("set_title truncated (length prefix but no text)")
    func truncatedSetTitle() {
        var data = Data([OP_SET_TITLE])
        data.append(contentsOf: [0x00, 0x10]) // title_len=16 but no text
        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("define_region truncated")
    func truncatedDefineRegion() {
        // Needs 14 bytes after opcode; provide only 5
        var data = Data([OP_DEFINE_REGION])
        data.append(contentsOf: Array(repeating: UInt8(0), count: 5))
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

    @Test("gui_status_bar truncated header")
    func truncatedStatusBar() {
        var data = Data([OP_GUI_STATUS_BAR])
        data.append(0) // contentKind
        data.append(0) // mode
        // Missing rest of header (cursorLine, cursorCol, etc.)

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("gui_picker visible but truncated items")
    func truncatedPicker() {
        var data = Data([OP_GUI_PICKER])
        data.append(1) // visible
        data.append(contentsOf: [0x00, 0x00]) // selectedIndex
        data.append(contentsOf: [0x00, 0x01]) // filteredCount
        data.append(contentsOf: [0x00, 0x01]) // totalCount
        data.append(contentsOf: [0x00, 0x00]) // title_len=0
        data.append(contentsOf: [0x00, 0x00]) // query_len=0
        data.append(0) // hasPreview
        data.append(contentsOf: [0x00, 0x02]) // itemCount=2
        // No item data

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("gui_agent_chat visible but truncated messages")
    func truncatedAgentChat() {
        var data = Data([OP_GUI_AGENT_CHAT])
        data.append(1) // visible
        data.append(0) // status
        data.append(contentsOf: [0x00, 0x00]) // model_len=0
        data.append(contentsOf: [0x00, 0x00]) // prompt_len=0
        data.append(0) // no pending
        data.append(contentsOf: [0x00, 0x03]) // messageCount=3
        // No message data

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("gui_file_tree truncated entry")
    func truncatedFileTree() {
        var data = Data([OP_GUI_FILE_TREE])
        data.append(contentsOf: [0x00, 0x00]) // selectedIndex
        data.append(contentsOf: [0x00, 0x1E]) // treeWidth
        data.append(contentsOf: [0x00, 0x01]) // entryCount=1
        data.append(contentsOf: [0x00, 0x00]) // rootPath_len=0
        // Entry needs path_hash(4)+flags(1)+depth(1)+git(1)+icon_len(1)+...
        // Provide only 3 bytes
        data.append(contentsOf: [0x00, 0x00, 0x00])

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("gui_gutter truncated entries")
    func truncatedGutter() {
        var data = Data([OP_GUI_GUTTER])
        // Header: window_id(2)+content_row(2)+content_col(2)+content_height(2)
        //         +is_active(1)+cursor_line(4)+style(1)+ln_width(1)+sign_width(1)+line_count(2) = 18
        data.append(contentsOf: Array(repeating: UInt8(0), count: 16))
        data.append(contentsOf: [0x00, 0x05]) // lineCount=5
        // Each entry is 6 bytes; claim 5 entries but provide none

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

    @Test("gui_window_content truncated rows")
    func truncatedWindowContent() {
        var data = Data([OP_GUI_WINDOW_CONTENT])
        // Header: window_id(2)+flags(1)+cursor_row(2)+cursor_col(2)+cursor_shape(1)+row_count(2) = 10
        data.append(contentsOf: [0x00, 0x01]) // windowId
        data.append(0x01) // flags
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // cursor
        data.append(0x00) // cursor_shape
        data.append(contentsOf: [0x00, 0x05]) // rowCount=5
        // No row data

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
            (Data([OP_GUI_TOOL_MANAGER, 0]), "tool_manager"),
        ]

        for (payload, name) in hiddenPayloads {
            let (cmd, size) = try decodeCommand(data: payload, offset: 0)
            #expect(cmd != nil, "Hidden \(name) should decode to a command")
            #expect(size == 2, "Hidden \(name) should consume 2 bytes")
        }
    }

    @Test("Single-byte commands at end of buffer don't over-read")
    func singleByteAtEnd() throws {
        let (cmd, size) = try decodeCommand(data: Data([OP_CLEAR]), offset: 0)
        #expect(size == 1)
        guard case .clear = cmd else {
            Issue.record("Expected .clear"); return
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
        data.append(OP_CLEAR)
        data.append(OP_BATCH_END)

        var commands: [RenderCommand] = []
        try decodeCommands(from: data) { cmd in
            commands.append(cmd)
        }
        #expect(commands.count == 2)
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
}
