/// Tests for ProtocolEncoder binary layout.
///
/// Verifies the exact bytes the encoder writes to the wire match the
/// protocol spec. Uses a pipe to capture output instead of stdout.
/// Each test creates a fresh encoder, calls one method, reads the
/// {:packet, 4} framed output, and asserts the payload bytes.

import Testing
import Foundation

/// Helper to create a pipe-backed encoder and read the framed output.
private func captureFrame(_ action: (ProtocolEncoder) -> Void) -> Data {
    let pipe = Pipe()
    let encoder = ProtocolEncoder(output: pipe.fileHandleForWriting)
    action(encoder)
    // Close write end so read doesn't block
    pipe.fileHandleForWriting.closeFile()
    let raw = pipe.fileHandleForReading.readDataToEndOfFile()
    // Strip the 4-byte length prefix to get the payload
    guard raw.count >= 4 else { return Data() }
    let len = Int(raw[0]) << 24 | Int(raw[1]) << 16 | Int(raw[2]) << 8 | Int(raw[3])
    guard raw.count >= 4 + len else { return Data() }
    return raw.subdata(in: 4..<(4 + len))
}

/// Read a big-endian UInt16 from data at offset.
private func readU16(_ data: Data, _ offset: Int) -> UInt16 {
    UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
}

/// Read a big-endian UInt32 from data at offset.
private func readU32(_ data: Data, _ offset: Int) -> UInt32 {
    UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 |
    UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
}

/// Read a big-endian Int16 from data at offset.
private func readI16(_ data: Data, _ offset: Int) -> Int16 {
    Int16(bitPattern: readU16(data, offset))
}

// MARK: - Ready event

@Suite("Encoder Binary: Ready")
struct EncoderReadyTests {
    @Test("ready event has correct opcode and capabilities")
    func readyLayout() {
        let payload = captureFrame { $0.sendReady(cols: 120, rows: 40) }

        #expect(payload.count == 13)
        #expect(payload[0] == OP_READY)
        #expect(readU16(payload, 1) == 120) // cols
        #expect(readU16(payload, 3) == 40)  // rows
        #expect(payload[5] == CAPS_VERSION)
        #expect(payload[6] == 6) // 6 capability fields
        #expect(payload[7] == FRONTEND_NATIVE_GUI)
        #expect(payload[8] == COLOR_RGB)
        #expect(payload[9] == UNICODE_15)
        #expect(payload[10] == IMAGE_NATIVE)
        #expect(payload[11] == FLOAT_NATIVE)
        #expect(payload[12] == TEXT_PROPORTIONAL)
    }
}

// MARK: - Key press

@Suite("Encoder Binary: Key Press")
struct EncoderKeyPressTests {
    @Test("key press encodes codepoint and modifiers")
    func keyPressLayout() {
        let payload = captureFrame { $0.sendKeyPress(codepoint: 27, modifiers: 0x02) }

        #expect(payload.count == 6)
        #expect(payload[0] == OP_KEY_PRESS)
        #expect(readU32(payload, 1) == 27)  // codepoint (Escape)
        #expect(payload[5] == 0x02)          // modifiers (Ctrl)
    }

    @Test("key press with large codepoint")
    func keyPressLargeCodepoint() {
        // Kitty arrow key codepoint
        let payload = captureFrame { $0.sendKeyPress(codepoint: 57350, modifiers: 0) }

        #expect(readU32(payload, 1) == 57350)
    }
}

// MARK: - Resize

@Suite("Encoder Binary: Resize")
struct EncoderResizeTests {
    @Test("resize encodes cols and rows")
    func resizeLayout() {
        let payload = captureFrame { $0.sendResize(cols: 200, rows: 50) }

        #expect(payload.count == 5)
        #expect(payload[0] == OP_RESIZE)
        #expect(readU16(payload, 1) == 200) // cols
        #expect(readU16(payload, 3) == 50)  // rows
    }
}

// MARK: - Mouse event

@Suite("Encoder Binary: Mouse Event")
struct EncoderMouseEventTests {
    @Test("mouse event encodes all fields including click count")
    func mouseEventLayout() {
        let payload = captureFrame {
            $0.sendMouseEvent(row: 10, col: -5, button: MOUSE_BUTTON_LEFT,
                             modifiers: 0x01, eventType: MOUSE_PRESS, clickCount: 3)
        }

        #expect(payload.count == 9)
        #expect(payload[0] == OP_MOUSE_EVENT)
        #expect(readI16(payload, 1) == 10)   // row (signed)
        #expect(readI16(payload, 3) == -5)   // col (signed, negative for left of view)
        #expect(payload[5] == MOUSE_BUTTON_LEFT)
        #expect(payload[6] == 0x01)           // modifiers (Shift)
        #expect(payload[7] == MOUSE_PRESS)
        #expect(payload[8] == 3)              // clickCount (triple-click)
    }

    @Test("scroll event uses correct button constants")
    func scrollLayout() {
        let payload = captureFrame {
            $0.sendMouseEvent(row: 0, col: 0, button: MOUSE_SCROLL_DOWN,
                             modifiers: 0, eventType: MOUSE_PRESS, clickCount: 1)
        }

        #expect(payload[5] == MOUSE_SCROLL_DOWN)
    }
}

// MARK: - Paste event

@Suite("Encoder Binary: Paste Event")
struct EncoderPasteEventTests {
    @Test("paste event encodes text with length prefix")
    func pasteLayout() {
        let payload = captureFrame { $0.sendPasteEvent(text: "hello\nworld") }

        #expect(payload[0] == OP_PASTE_EVENT)
        let textLen = readU16(payload, 1)
        #expect(textLen == 11) // "hello\nworld" = 11 bytes
        let text = String(data: payload[3..<(3 + Int(textLen))], encoding: .utf8)
        #expect(text == "hello\nworld")
    }

    @Test("paste event with unicode text")
    func pasteUnicode() {
        let payload = captureFrame { $0.sendPasteEvent(text: "日本語") }

        let textLen = readU16(payload, 1)
        #expect(textLen == 9) // 3 CJK chars × 3 bytes each
        let text = String(data: payload[3..<(3 + Int(textLen))], encoding: .utf8)
        #expect(text == "日本語")
    }

    @Test("paste event with empty text")
    func pasteEmpty() {
        let payload = captureFrame { $0.sendPasteEvent(text: "") }

        #expect(payload[0] == OP_PASTE_EVENT)
        #expect(readU16(payload, 1) == 0) // text_len = 0
        #expect(payload.count == 3) // opcode + len only
    }
}

// MARK: - Log message

@Suite("Encoder Binary: Log Message")
struct EncoderLogMessageTests {
    @Test("log message encodes level and text")
    func logLayout() {
        let payload = captureFrame { $0.sendLog(level: LOG_LEVEL_INFO, message: "test msg") }

        #expect(payload[0] == OP_LOG_MESSAGE)
        #expect(payload[1] == LOG_LEVEL_INFO)
        let msgLen = readU16(payload, 2)
        #expect(msgLen == 8) // "test msg"
        let msg = String(data: payload[4..<(4 + Int(msgLen))], encoding: .utf8)
        #expect(msg == "test msg")
    }
}

// MARK: - GUI actions

@Suite("Encoder Binary: GUI Actions")
struct EncoderGUIActionTests {
    @Test("select_tab encodes action type and tab ID")
    func selectTabLayout() {
        let payload = captureFrame { $0.sendSelectTab(id: 42) }

        #expect(payload.count == 6)
        #expect(payload[0] == OP_GUI_ACTION)
        #expect(payload[1] == GUI_ACTION_SELECT_TAB)
        #expect(readU32(payload, 2) == 42)
    }

    @Test("close_tab encodes action type and tab ID")
    func closeTabLayout() {
        let payload = captureFrame { $0.sendCloseTab(id: 99) }

        #expect(payload[0] == OP_GUI_ACTION)
        #expect(payload[1] == GUI_ACTION_CLOSE_TAB)
        #expect(readU32(payload, 2) == 99)
    }

    @Test("file_tree_click encodes index as UInt16")
    func fileTreeClickLayout() {
        let payload = captureFrame { $0.sendFileTreeClick(index: 15) }

        #expect(payload.count == 4)
        #expect(payload[1] == GUI_ACTION_FILE_TREE_CLICK)
        #expect(readU16(payload, 2) == 15)
    }

    @Test("completion_select encodes index as UInt16")
    func completionSelectLayout() {
        let payload = captureFrame { $0.sendCompletionSelect(index: 3) }

        #expect(payload[1] == GUI_ACTION_COMPLETION_SELECT)
        #expect(readU16(payload, 2) == 3)
    }

    @Test("breadcrumb_click encodes index as UInt8")
    func breadcrumbClickLayout() {
        let payload = captureFrame { $0.sendBreadcrumbClick(index: 2) }

        #expect(payload.count == 3)
        #expect(payload[1] == GUI_ACTION_BREADCRUMB_CLICK)
        #expect(payload[2] == 2)
    }

    @Test("toggle_panel encodes panel ID")
    func togglePanelLayout() {
        let payload = captureFrame { $0.sendTogglePanel(panel: 1) }

        #expect(payload.count == 3)
        #expect(payload[1] == GUI_ACTION_TOGGLE_PANEL)
        #expect(payload[2] == 1)
    }

    @Test("new_tab is just opcode + action_type")
    func newTabLayout() {
        let payload = captureFrame { $0.sendNewTab() }

        #expect(payload.count == 2)
        #expect(payload[1] == GUI_ACTION_NEW_TAB)
    }

    @Test("panel_switch_tab encodes tab index")
    func panelSwitchTabLayout() {
        let payload = captureFrame { $0.sendPanelSwitchTab(index: 2) }

        #expect(payload.count == 3)
        #expect(payload[1] == GUI_ACTION_PANEL_SWITCH_TAB)
        #expect(payload[2] == 2)
    }

    @Test("panel_resize encodes height percent")
    func panelResizeLayout() {
        let payload = captureFrame { $0.sendPanelResize(heightPercent: 40) }

        #expect(payload.count == 3)
        #expect(payload[1] == GUI_ACTION_PANEL_RESIZE)
        #expect(payload[2] == 40)
    }

    @Test("open_file encodes path with length prefix")
    func openFileLayout() {
        let path = "/home/user/project/lib/editor.ex"
        let payload = captureFrame { $0.sendOpenFile(path: path) }

        #expect(payload[0] == OP_GUI_ACTION)
        #expect(payload[1] == GUI_ACTION_OPEN_FILE)
        let pathLen = readU16(payload, 2)
        #expect(pathLen == UInt16(path.utf8.count))
        let decoded = String(data: payload[4..<(4 + Int(pathLen))], encoding: .utf8)
        #expect(decoded == path)
    }

    @Test("tool_install encodes name with length prefix")
    func toolInstallLayout() {
        let payload = captureFrame { $0.sendToolInstall(name: "elixir_ls") }

        #expect(payload[1] == GUI_ACTION_TOOL_INSTALL)
        let nameLen = readU16(payload, 2)
        #expect(nameLen == 9)
        let name = String(data: payload[4..<(4 + Int(nameLen))], encoding: .utf8)
        #expect(name == "elixir_ls")
    }

    @Test("tool_dismiss is just opcode + action_type")
    func toolDismissLayout() {
        let payload = captureFrame { $0.sendToolDismiss() }

        #expect(payload.count == 2)
        #expect(payload[1] == GUI_ACTION_TOOL_DISMISS)
    }

    @Test("execute_command encodes command name with length prefix")
    func executeCommandLayout() {
        let payload = captureFrame { $0.sendExecuteCommand(name: "buffer_prev") }

        #expect(payload[0] == OP_GUI_ACTION)
        #expect(payload[1] == GUI_ACTION_EXECUTE_COMMAND)
        let nameLen = readU16(payload, 2)
        #expect(nameLen == 11) // "buffer_prev".count
        let name = String(data: payload[4..<(4 + Int(nameLen))], encoding: .utf8)
        #expect(name == "buffer_prev")
    }
}

// MARK: - Frame header

@Suite("Encoder Binary: Frame Header")
struct EncoderFrameHeaderTests {
    @Test("frame has correct {:packet, 4} length prefix")
    func frameHeader() {
        let pipe = Pipe()
        let encoder = ProtocolEncoder(output: pipe.fileHandleForWriting)
        encoder.sendResize(cols: 80, rows: 24)
        pipe.fileHandleForWriting.closeFile()
        let raw = pipe.fileHandleForReading.readDataToEndOfFile()

        // {:packet, 4}: first 4 bytes are big-endian payload length
        let declaredLen = Int(raw[0]) << 24 | Int(raw[1]) << 16 | Int(raw[2]) << 8 | Int(raw[3])
        #expect(declaredLen == 5) // resize payload = 5 bytes
        #expect(raw.count == 4 + declaredLen)
    }
}
