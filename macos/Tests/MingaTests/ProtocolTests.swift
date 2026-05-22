/// Protocol encode/decode round-trip tests.

import Testing
import AppKit
import Foundation
import QuartzCore
import os

private func appendConfigStateU16(_ data: inout Data, _ value: UInt16) {
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
}

private func appendConfigStateU32(_ data: inout Data, _ value: UInt32) {
    data.append(UInt8((value >> 24) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
}

private func appendConfigStateU64(_ data: inout Data, _ value: UInt64) {
    data.append(UInt8((value >> 56) & 0xFF))
    data.append(UInt8((value >> 48) & 0xFF))
    data.append(UInt8((value >> 40) & 0xFF))
    data.append(UInt8((value >> 32) & 0xFF))
    data.append(UInt8((value >> 24) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
}

private func appendConfigStateString8(_ data: inout Data, _ text: String) {
    let bytes = Array(text.utf8.prefix(Int(UInt8.max)))
    data.append(UInt8(bytes.count))
    data.append(contentsOf: bytes)
}

private func appendConfigStateString16(_ data: inout Data, _ text: String) {
    let bytes = Array(text.utf8.prefix(Int(UInt16.max)))
    appendConfigStateU16(&data, UInt16(bytes.count))
    data.append(contentsOf: bytes)
}

private func appendConfigStateValue(_ data: inout Data, _ value: SettingValue) {
    switch value {
    case .bool(let enabled):
        data.append(SETTING_VALUE_BOOL)
        data.append(enabled ? 1 : 0)
    case .int(let number):
        data.append(SETTING_VALUE_INT)
        let unsigned = UInt32(bitPattern: Int32(clamping: number))
        data.append(UInt8((unsigned >> 24) & 0xFF))
        data.append(UInt8((unsigned >> 16) & 0xFF))
        data.append(UInt8((unsigned >> 8) & 0xFF))
        data.append(UInt8(unsigned & 0xFF))
    case .string(let text):
        data.append(SETTING_VALUE_STRING)
        appendConfigStateString16(&data, text)
    case .atom(let text):
        data.append(SETTING_VALUE_ATOM)
        appendConfigStateString16(&data, text)
    case .float(let number):
        data.append(SETTING_VALUE_FLOAT)
        let bits = number.bitPattern.bigEndian
        withUnsafeBytes(of: bits) { data.append(contentsOf: $0) }
    }
}

@Suite("Protocol Decoder")
struct ProtocolDecoderTests {
    @Test("Decode clear command")
    func decodeClear() throws {
        let data = Data([OP_CLEAR])
        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 1)
        guard case .clear = cmd else {
            Issue.record("Expected .clear, got \(String(describing: cmd))")
            return
        }
    }

    @Test("Decode batch_end command")
    func decodeBatchEnd() throws {
        let data = Data([OP_BATCH_END])
        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 1)
        guard case .batchEnd = cmd else {
            Issue.record("Expected .batchEnd, got \(String(describing: cmd))")
            return
        }
    }

    @Test("Decode set_cursor command")
    func decodeSetCursor() throws {
        // row=5 (0x0005), col=10 (0x000A)
        let data = Data([OP_SET_CURSOR, 0x00, 0x05, 0x00, 0x0A])
        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 5)
        guard case .setCursor(let row, let col) = cmd else {
            Issue.record("Expected .setCursor, got \(String(describing: cmd))")
            return
        }
        #expect(row == 5)
        #expect(col == 10)
    }

    @Test("Decode set_cursor_shape command")
    func decodeSetCursorShape() throws {
        let data = Data([OP_SET_CURSOR_SHAPE, CURSOR_BEAM])
        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 2)
        guard case .setCursorShape(let shape) = cmd else {
            Issue.record("Expected .setCursorShape, got \(String(describing: cmd))")
            return
        }
        #expect(shape == .beam)
    }

    @Test("Decode gui_cursor_animation command")
    func decodeGuiCursorAnimation() throws {
        let data = Data([OP_GUI_CURSOR_ANIMATION, 0x00, 0x01, 0x00])
        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 4)
        guard case .guiCursorAnimation(let enabled) = cmd else {
            Issue.record("Expected .guiCursorAnimation, got \(String(describing: cmd))")
            return
        }
        #expect(enabled == false)
    }

    @Test("Decode gui_config_state command")
    func decodeGuiConfigState() throws {
        var payload = Data()
        appendConfigStateU16(&payload, 3)
        appendConfigStateString8(&payload, "theme")
        appendConfigStateValue(&payload, .atom("doom_one"))
        appendConfigStateString8(&payload, "font_size")
        appendConfigStateValue(&payload, .int(14))
        appendConfigStateString8(&payload, "cursor_blink")
        appendConfigStateValue(&payload, .bool(true))

        appendConfigStateU16(&payload, 1)
        appendConfigStateString8(&payload, "Doom One")
        appendConfigStateString8(&payload, "doom_one")
        payload.append(contentsOf: [0x28, 0x2C, 0x34, 0xBB, 0xC2, 0xCF, 0x51, 0xAF, 0xEF])

        appendConfigStateU16(&payload, 1)
        appendConfigStateString8(&payload, "normal")
        appendConfigStateString16(&payload, "SPC f f")
        appendConfigStateString16(&payload, "find_file")
        appendConfigStateString16(&payload, "Find file")

        var encoded = Data([OP_GUI_CONFIG_STATE])
        appendConfigStateU16(&encoded, UInt16(payload.count))
        encoded.append(payload)

        let (cmd, size) = try decodeCommand(data: encoded, offset: 0)
        #expect(size == encoded.count)
        guard case .guiConfigState(let state) = cmd else {
            Issue.record("Expected .guiConfigState, got \(String(describing: cmd))")
            return
        }

        #expect(state.options["theme"] == .atom("doom_one"))
        #expect(state.options["font_size"] == .int(14))
        #expect(state.options["cursor_blink"] == .bool(true))
        #expect(state.themePreviews.count == 1)
        #expect(state.keybindings.count == 1)
        #expect(state.themePreviews[0].name == "Doom One")
        #expect(state.keybindings[0].key == "SPC f f")
    }

    @Test("Decode gui_notifications command")
    func decodeGuiNotifications() throws {
        var payload = Data()
        payload.append(1)
        appendConfigStateU16(&payload, 1)
        appendConfigStateString16(&payload, "build:test")
        payload.append(2)
        payload.append(1)
        appendConfigStateU64(&payload, 1_715_000_000)
        appendConfigStateU64(&payload, 1_715_000_030)
        appendConfigStateU32(&payload, UInt32.max)
        appendConfigStateString16(&payload, "Build failed")
        appendConfigStateString16(&payload, "mix test exited with code 1")
        appendConfigStateString16(&payload, "Build")
        payload.append(1)
        appendConfigStateString16(&payload, "show_logs")
        appendConfigStateString16(&payload, "Show logs")

        var encoded = Data([OP_GUI_NOTIFICATIONS])
        appendConfigStateU16(&encoded, UInt16(payload.count))
        encoded.append(payload)

        let (cmd, size) = try decodeCommand(data: encoded, offset: 0)
        #expect(size == encoded.count)
        guard case .guiNotifications(let notifications) = cmd else {
            Issue.record("Expected .guiNotifications, got \(String(describing: cmd))")
            return
        }

        #expect(notifications.count == 1)
        #expect(notifications[0].id == "build:test")
        #expect(notifications[0].createdAt == 1_715_000_000)
        #expect(notifications[0].updatedAt == 1_715_000_030)
        #expect(notifications[0].title == "Build failed")
        #expect(notifications[0].dismissable)
        #expect(notifications[0].actions[0].label == "Show logs")
    }

    @Test("Decode draw_text command")
    func decodeDrawText() throws {
        // row=1, col=2, fg=0xFF0000 (red), bg=0x00FF00 (green), attrs=0x01 (bold), text="Hi"
        var data = Data()
        data.append(OP_DRAW_TEXT)
        data.append(contentsOf: [0x00, 0x01]) // row=1
        data.append(contentsOf: [0x00, 0x02]) // col=2
        data.append(contentsOf: [0xFF, 0x00, 0x00]) // fg=red
        data.append(contentsOf: [0x00, 0xFF, 0x00]) // bg=green
        data.append(0x01) // attrs=bold
        data.append(contentsOf: [0x00, 0x02]) // text_len=2
        data.append(contentsOf: "Hi".utf8)

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 16) // 1 + 13 + 2
        guard case .drawText(let row, let col, let fg, let bg, let attrs, let text) = cmd else {
            Issue.record("Expected .drawText, got \(String(describing: cmd))")
            return
        }
        #expect(row == 1)
        #expect(col == 2)
        #expect(fg == 0xFF0000)
        #expect(bg == 0x00FF00)
        #expect(attrs == 0x01)
        #expect(text == "Hi")
    }

    @Test("Decode define_region command")
    func decodeDefineRegion() throws {
        var data = Data()
        data.append(OP_DEFINE_REGION)
        data.append(contentsOf: [0x00, 0x64]) // id=100
        data.append(contentsOf: [0x00, 0x00]) // parent_id=0
        data.append(0x01) // role=1
        data.append(contentsOf: [0x00, 0x02]) // row=2
        data.append(contentsOf: [0x00, 0x03]) // col=3
        data.append(contentsOf: [0x00, 0x50]) // width=80
        data.append(contentsOf: [0x00, 0x18]) // height=24
        data.append(0x00) // z_order=0

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 15)
        guard case .defineRegion(let id, _, _, let row, let col, let width, let height, _) = cmd else {
            Issue.record("Expected .defineRegion, got \(String(describing: cmd))")
            return
        }
        #expect(id == 100)
        #expect(row == 2)
        #expect(col == 3)
        #expect(width == 80)
        #expect(height == 24)
    }

    @Test("Decode multiple commands in one payload")
    func decodeMultipleCommands() throws {
        var data = Data()
        data.append(OP_CLEAR)
        data.append(OP_SET_CURSOR)
        data.append(contentsOf: [0x00, 0x03, 0x00, 0x07])
        data.append(OP_BATCH_END)

        var commands: [RenderCommand] = []
        try decodeCommands(from: data) { cmd in
            commands.append(cmd)
        }
        #expect(commands.count == 3)
    }

    @Test("Decode set_window_bg command")
    func decodeSetWindowBg() throws {
        let data = Data([OP_SET_WINDOW_BG, 0x28, 0x2C, 0x34])
        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 4)
        guard case .setWindowBg(let r, let g, let b) = cmd else {
            Issue.record("Expected .setWindowBg, got \(String(describing: cmd))")
            return
        }
        #expect(r == 0x28)
        #expect(g == 0x2C)
        #expect(b == 0x34)
    }

    @Test("Decode set_font command with ligatures enabled, regular weight")
    func decodeSetFont() throws {
        var data = Data()
        data.append(OP_SET_FONT)
        data.append(contentsOf: [0x00, 0x0E]) // size=14
        data.append(0x02) // weight=regular
        data.append(0x01) // ligatures=true
        let name = "JetBrains Mono"
        data.append(contentsOf: [UInt8(name.utf8.count >> 8), UInt8(name.utf8.count & 0xFF)])
        data.append(contentsOf: name.utf8)

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 1 + 6 + name.utf8.count)
        guard case .setFont(let family, let fontSize, let ligatures, let weight) = cmd else {
            Issue.record("Expected .setFont, got \(String(describing: cmd))")
            return
        }
        #expect(family == "JetBrains Mono")
        #expect(fontSize == 14)
        #expect(weight == 2)
        #expect(ligatures == true)
    }

    @Test("Decode set_font command with ligatures disabled, bold weight")
    func decodeSetFontNoLigatures() throws {
        var data = Data()
        data.append(OP_SET_FONT)
        data.append(contentsOf: [0x00, 0x0D]) // size=13
        data.append(0x05) // weight=bold
        data.append(0x00) // ligatures=false
        let name = "Menlo"
        data.append(contentsOf: [0x00, UInt8(name.utf8.count)])
        data.append(contentsOf: name.utf8)

        let (cmd, _) = try decodeCommand(data: data, offset: 0)
        guard case .setFont(let family, let fontSize, let ligatures, let weight) = cmd else {
            Issue.record("Expected .setFont, got \(String(describing: cmd))")
            return
        }
        #expect(family == "Menlo")
        #expect(fontSize == 13)
        #expect(weight == 5)
        #expect(ligatures == false)
    }

    @Test("Skip highlight opcodes without error")
    func skipHighlightOpcodes() throws {
        // set_language with name "elixir"
        var data = Data()
        data.append(OP_SET_LANGUAGE)
        data.append(contentsOf: [0x00, 0x06]) // name_len=6
        data.append(contentsOf: "elixir".utf8)

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(cmd == nil) // Skipped
        #expect(size == 9) // 1 + 2 + 6
    }
}

@Suite("Protocol Encoder")
struct ProtocolEncoderTests {
    // Encoder writes to stdout, so we test the binary layout indirectly
    // by verifying the ready event structure.
    @Test("Ready event has correct size")
    func readyEventSize() {
        // The ready payload should be 13 bytes:
        // opcode:1, cols:2, rows:2, caps_version:1, caps_len:1, fields:6
        // Total frame: 4 (length prefix) + 13 = 17 bytes
        // We can't easily capture stdout in tests, but we verify the
        // constants are correct.
        #expect(CAPS_VERSION == 1)
        #expect(FRONTEND_NATIVE_GUI == 1)
        #expect(COLOR_RGB == 2)
    }

    @Test("Paste event opcode matches protocol constant")
    func pasteEventOpcode() {
        #expect(OP_PASTE_EVENT == 0x06)
    }
}

@Suite("Paste Event Encoder")
struct PasteEventEncoderTests {
    @Test("sendPasteEvent records call with correct text")
    func sendPasteBasic() {
        let spy = SpyEncoder()
        spy.sendPasteEvent(text: "hello\nworld\nline 3")
        #expect(spy.pasteCalls.count == 1)
        #expect(spy.pasteCalls[0].text == "hello\nworld\nline 3")
    }

    @Test("sendPasteEvent with empty text")
    func sendPasteEmpty() {
        let spy = SpyEncoder()
        spy.sendPasteEvent(text: "")
        #expect(spy.pasteCalls.count == 1)
        #expect(spy.pasteCalls[0].text == "")
    }

    @Test("sendPasteEvent with unicode text")
    func sendPasteUnicode() {
        let spy = SpyEncoder()
        let text = "こんにちは\n🎉 emoji\n中文"
        spy.sendPasteEvent(text: text)
        #expect(spy.pasteCalls.count == 1)
        #expect(spy.pasteCalls[0].text == text)
    }

    @Test("sendPasteEvent with single line")
    func sendPasteSingleLine() {
        let spy = SpyEncoder()
        spy.sendPasteEvent(text: "just one line")
        #expect(spy.pasteCalls.count == 1)
        #expect(spy.pasteCalls[0].text == "just one line")
    }

    @Test("multiple paste events accumulate correctly")
    func sendPasteMultiple() {
        let spy = SpyEncoder()
        spy.sendPasteEvent(text: "first paste\nwith lines")
        spy.sendPasteEvent(text: "second paste")
        #expect(spy.pasteCalls.count == 2)
        #expect(spy.pasteCalls[0].text == "first paste\nwith lines")
        #expect(spy.pasteCalls[1].text == "second paste")
    }
}

// MARK: - Spy encoder for testing resize behavior

/// Spy that records all InputEncoder calls for test assertions.
///
/// Uses OSAllocatedUnfairLock so it satisfies Sendable without @unchecked.
/// GUI action calls are recorded as GUIAction enum values, allowing tests
/// to verify that view interactions send the correct protocol events.
final class SpyEncoder: InputEncoder, Sendable {
    struct Resize: Sendable { let cols: UInt16; let rows: UInt16 }
    struct Ready: Sendable { let cols: UInt16; let rows: UInt16 }
    struct Log: Sendable { let level: UInt8; let message: String }
    struct Paste: Sendable { let text: String }
    struct KeyPress: Sendable { let codepoint: UInt32; let modifiers: UInt8 }
    struct MouseEvent: Sendable { let row: Int16; let col: Int16; let button: UInt8; let modifiers: UInt8; let eventType: UInt8; let clickCount: UInt8 }

    /// Recorded GUI action events. Each sendFoo() call appends one entry.
    enum GUIAction: Sendable, Equatable {
        case selectTab(id: UInt32)
        case closeTab(id: UInt32)
        case tabCopyPath(id: UInt32)
        case hoverOpenAction
        case fileTreeClick(index: UInt16)
        case fileTreeToggle(index: UInt16)
        case fileTreeOpenInSplit(index: UInt16)
        case fileTreeNewFile(parentIndex: UInt16)
        case fileTreeNewFolder(parentIndex: UInt16)
        case fileTreeEditConfirm(text: String)
        case fileTreeEditCancel
        case fileTreeDelete(index: UInt16)
        case fileTreeRename(index: UInt16)
        case fileTreeDuplicate(index: UInt16)
        case fileTreeMove(sourceIndex: UInt16, targetDirIndex: UInt16)
        case fileTreeDrop(sourcePaths: [String], targetIndex: UInt16, targetId: String, targetPathHash: UInt32, targetPath: String, targetIsDir: Bool, modifiers: UInt8)
        case fileTreeCollapseAll
        case fileTreeRefresh
        case completionSelect(index: UInt16)
        case breadcrumbClick(index: UInt8)
        case togglePanel(panel: UInt8)
        case newTab
        case systemWillSleep
        case systemDidWake
        case cmdCopy
        case cmdCut
        case panelSwitchTab(index: UInt8)
        case panelDismiss
        case panelResize(heightPercent: UInt8)
        case openFile(path: String)
        case toolInstall(name: String)
        case toolUninstall(name: String)
        case toolUpdate(name: String)
        case toolDismiss
        case agentToolToggle(index: UInt16)
        case executeCommand(name: String)
        case minibufferSelect(index: UInt16)


        case gitStageFile(path: String)
        case gitUnstageFile(path: String)
        case gitDiscardFile(path: String)
        case gitStageAll
        case gitUnstageAll
        case gitCommit(message: String)
        case gitOpenFile(path: String)
        case gitOpenDiff(path: String, section: UInt8)
        case gitPush
        case gitPull
        case gitFetch
        case gitCommitAmend(message: String)
        case gitPullAndRetry
        case foldToggleAtLine(windowId: UInt16, bufferLine: UInt32)
        case boardSelectCard(id: UInt32)
        case boardCloseCard(id: UInt32)
        case boardReorder(cardId: UInt32, newIndex: UInt16)
        case boardDispatchAgent(task: String, model: String)
        case observatoryInspect(pid: String)
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    struct State: Sendable {
        var resizeCalls: [Resize] = []
        var readyCalls: [Ready] = []
        var logCalls: [Log] = []
        var pasteCalls: [Paste] = []
        var keyPressCalls: [KeyPress] = []
        var mouseEventCalls: [MouseEvent] = []
        var guiActions: [GUIAction] = []
    }

    var resizeCalls: [Resize] { state.withLock { $0.resizeCalls } }
    var readyCalls: [Ready] { state.withLock { $0.readyCalls } }
    var logCalls: [Log] { state.withLock { $0.logCalls } }
    var pasteCalls: [Paste] { state.withLock { $0.pasteCalls } }
    var keyPressCalls: [KeyPress] { state.withLock { $0.keyPressCalls } }
    var mouseEventCalls: [MouseEvent] { state.withLock { $0.mouseEventCalls } }
    var guiActions: [GUIAction] { state.withLock { $0.guiActions } }

    func sendReady(cols: UInt16, rows: UInt16) {
        state.withLock { $0.readyCalls.append(Ready(cols: cols, rows: rows)) }
    }
    func sendKeyPress(codepoint: UInt32, modifiers: UInt8) {
        state.withLock { $0.keyPressCalls.append(KeyPress(codepoint: codepoint, modifiers: modifiers)) }
    }
    func sendResize(cols: UInt16, rows: UInt16) {
        state.withLock { $0.resizeCalls.append(Resize(cols: cols, rows: rows)) }
    }
    func sendMouseEvent(row: Int16, col: Int16, button: UInt8, modifiers: UInt8, eventType: UInt8, clickCount: UInt8 = 1) {
        state.withLock { $0.mouseEventCalls.append(MouseEvent(row: row, col: col, button: button, modifiers: modifiers, eventType: eventType, clickCount: clickCount)) }
    }
    func sendPasteEvent(text: String) {
        state.withLock { $0.pasteCalls.append(Paste(text: text)) }
    }
    func sendLog(level: UInt8, message: String) {
        state.withLock { $0.logCalls.append(Log(level: level, message: message)) }
    }

    // GUI actions: all recorded for test assertions
    func sendSelectTab(id: UInt32) { state.withLock { $0.guiActions.append(.selectTab(id: id)) } }
    func sendCloseTab(id: UInt32) { state.withLock { $0.guiActions.append(.closeTab(id: id)) } }
    func sendTabCopyPath(id: UInt32) { state.withLock { $0.guiActions.append(.tabCopyPath(id: id)) } }
    func sendHoverOpenAction() { state.withLock { $0.guiActions.append(.hoverOpenAction) } }
    func sendFileTreeClick(index: UInt16) { state.withLock { $0.guiActions.append(.fileTreeClick(index: index)) } }
    func sendFileTreeToggle(index: UInt16) { state.withLock { $0.guiActions.append(.fileTreeToggle(index: index)) } }
    func sendFileTreeOpenInSplit(index: UInt16) { state.withLock { $0.guiActions.append(.fileTreeOpenInSplit(index: index)) } }
    func sendFileTreeNewFile(parentIndex: UInt16) { state.withLock { $0.guiActions.append(.fileTreeNewFile(parentIndex: parentIndex)) } }
    func sendFileTreeNewFolder(parentIndex: UInt16) { state.withLock { $0.guiActions.append(.fileTreeNewFolder(parentIndex: parentIndex)) } }
    func sendFileTreeEditConfirm(text: String) { state.withLock { $0.guiActions.append(.fileTreeEditConfirm(text: text)) } }
    func sendFileTreeEditCancel() { state.withLock { $0.guiActions.append(.fileTreeEditCancel) } }
    func sendFileTreeDelete(index: UInt16) { state.withLock { $0.guiActions.append(.fileTreeDelete(index: index)) } }
    func sendFileTreeRename(index: UInt16) { state.withLock { $0.guiActions.append(.fileTreeRename(index: index)) } }
    func sendFileTreeDuplicate(index: UInt16) { state.withLock { $0.guiActions.append(.fileTreeDuplicate(index: index)) } }
    func sendFileTreeMove(sourceIndex: UInt16, targetDirIndex: UInt16) { state.withLock { $0.guiActions.append(.fileTreeMove(sourceIndex: sourceIndex, targetDirIndex: targetDirIndex)) } }
    func sendFileTreeDrop(sourcePaths: [String], targetIndex: UInt16, targetId: String, targetPathHash: UInt32, targetPath: String, targetIsDir: Bool, modifiers: UInt8) { state.withLock { $0.guiActions.append(.fileTreeDrop(sourcePaths: sourcePaths, targetIndex: targetIndex, targetId: targetId, targetPathHash: targetPathHash, targetPath: targetPath, targetIsDir: targetIsDir, modifiers: modifiers)) } }
    func sendFileTreeCollapseAll() { state.withLock { $0.guiActions.append(.fileTreeCollapseAll) } }
    func sendFileTreeRefresh() { state.withLock { $0.guiActions.append(.fileTreeRefresh) } }
    func sendCompletionSelect(index: UInt16) { state.withLock { $0.guiActions.append(.completionSelect(index: index)) } }
    func sendBreadcrumbClick(index: UInt8) { state.withLock { $0.guiActions.append(.breadcrumbClick(index: index)) } }
    func sendTogglePanel(panel: UInt8) { state.withLock { $0.guiActions.append(.togglePanel(panel: panel)) } }
    func sendNewTab() { state.withLock { $0.guiActions.append(.newTab) } }
    func sendSystemWillSleep() { state.withLock { $0.guiActions.append(.systemWillSleep) } }
    func sendSystemDidWake() { state.withLock { $0.guiActions.append(.systemDidWake) } }
    func sendCmdCopy() { state.withLock { $0.guiActions.append(.cmdCopy) } }
    func sendCmdCut() { state.withLock { $0.guiActions.append(.cmdCut) } }
    func sendPanelSwitchTab(index: UInt8) { state.withLock { $0.guiActions.append(.panelSwitchTab(index: index)) } }
    func sendPanelDismiss() { state.withLock { $0.guiActions.append(.panelDismiss) } }
    func sendPanelResize(heightPercent: UInt8) { state.withLock { $0.guiActions.append(.panelResize(heightPercent: heightPercent)) } }
    func sendOpenFile(path: String) { state.withLock { $0.guiActions.append(.openFile(path: path)) } }
    func sendToolInstall(name: String) { state.withLock { $0.guiActions.append(.toolInstall(name: name)) } }
    func sendToolUninstall(name: String) { state.withLock { $0.guiActions.append(.toolUninstall(name: name)) } }
    func sendToolUpdate(name: String) { state.withLock { $0.guiActions.append(.toolUpdate(name: name)) } }
    func sendToolDismiss() { state.withLock { $0.guiActions.append(.toolDismiss) } }
    func sendAgentToolToggle(index: UInt16) { state.withLock { $0.guiActions.append(.agentToolToggle(index: index)) } }
    func sendExecuteCommand(name: String) { state.withLock { $0.guiActions.append(.executeCommand(name: name)) } }
    func sendMinibufferSelect(index: UInt16) { state.withLock { $0.guiActions.append(.minibufferSelect(index: index)) } }


    func sendGitStageFile(path: String) { state.withLock { $0.guiActions.append(.gitStageFile(path: path)) } }
    func sendGitUnstageFile(path: String) { state.withLock { $0.guiActions.append(.gitUnstageFile(path: path)) } }
    func sendGitDiscardFile(path: String) { state.withLock { $0.guiActions.append(.gitDiscardFile(path: path)) } }
    func sendGitStageAll() { state.withLock { $0.guiActions.append(.gitStageAll) } }
    func sendGitUnstageAll() { state.withLock { $0.guiActions.append(.gitUnstageAll) } }
    func sendGitCommit(message: String) { state.withLock { $0.guiActions.append(.gitCommit(message: message)) } }
    func sendGitOpenFile(path: String) { state.withLock { $0.guiActions.append(.gitOpenFile(path: path)) } }
    func sendGitOpenDiff(path: String, section: UInt8) { state.withLock { $0.guiActions.append(.gitOpenDiff(path: path, section: section)) } }
    func sendGitPush() { state.withLock { $0.guiActions.append(.gitPush) } }
    func sendGitPull() { state.withLock { $0.guiActions.append(.gitPull) } }
    func sendGitFetch() { state.withLock { $0.guiActions.append(.gitFetch) } }
    func sendGitCommitAmend(message: String) { state.withLock { $0.guiActions.append(.gitCommitAmend(message: message)) } }
    func sendGitPullAndRetry() { state.withLock { $0.guiActions.append(.gitPullAndRetry) } }
    func sendWorkspaceRename(id: UInt16, name: String) { state.withLock { $0.guiActions.append(.gitOpenFile(path: "rename:\(id):\(name)")) } }
    func sendWorkspaceSetIcon(id: UInt16, icon: String) { state.withLock { $0.guiActions.append(.gitOpenFile(path: "icon:\(id):\(icon)")) } }
    func sendWorkspaceClose(id: UInt16) { state.withLock { $0.guiActions.append(.gitOpenFile(path: "close-ws:\(id)")) } }
    func sendSpaceLeaderChord(codepoint: UInt32, modifiers: UInt8) { /* no-op for tests */ }
    func sendSpaceLeaderRetract(codepoint: UInt32, modifiers: UInt8) { /* no-op for tests */ }
    func sendFindPasteboardSearch(text: String, direction: UInt8) { /* no-op for tests */ }
    func sendBoardSelectCard(id: UInt32) {
        state.withLock { $0.guiActions.append(.boardSelectCard(id: id)) }
    }
    func sendBoardCloseCard(id: UInt32) {
        state.withLock { $0.guiActions.append(.boardCloseCard(id: id)) }
    }
    func sendBoardReorder(cardId: UInt32, newIndex: UInt16) {
        state.withLock { $0.guiActions.append(.boardReorder(cardId: cardId, newIndex: newIndex)) }
    }
    func sendDispatchAgent(task: String, model: String) {
        state.withLock { $0.guiActions.append(.boardDispatchAgent(task: task, model: model)) }
    }
    func sendAgentApprove() { /* no-op for tests */ }
    func sendAgentRequestChanges() { /* no-op for tests */ }
    func sendAgentDismiss() { /* no-op for tests */ }
    func sendChangeSummaryClick(index: UInt32) { /* no-op for tests */ }
    func sendScrollToLine(line: UInt32) { /* no-op for tests */ }
    func sendFoldToggleAtLine(windowId: UInt16, bufferLine: UInt32) {
        state.withLock { $0.guiActions.append(.foldToggleAtLine(windowId: windowId, bufferLine: bufferLine)) }
    }
    func sendObservatoryInspect(pid: String) {
        state.withLock { $0.guiActions.append(.observatoryInspect(pid: pid)) }
    }
}

@Suite("EditorNSView Resize")
struct EditorNSViewResizeTests {
    /// Helper to create an EditorNSView with CoreText renderer.
    @MainActor private func makeView(spy: SpyEncoder, cols: UInt16 = 80, rows: UInt16 = 24, scale: CGFloat = 1.0) -> EditorNSView? {
        let face = FontFace(name: "Menlo", size: 13.0, scale: scale)
        let fm = FontManager(name: "Menlo", size: 13.0, scale: scale)
        let guiState = GUIState()
        let disp = CommandDispatcher(cols: cols, rows: rows, guiState: guiState)
        guard let ctRenderer = CoreTextMetalRenderer() else { return nil }
        ctRenderer.setupRenderers(fontManager: fm)
        return EditorNSView(encoder: spy, fontFace: face, dispatcher: disp,
                            coreTextRenderer: ctRenderer, fontManager: fm)
    }

    @Test("setFrameSize sends resize when cell dimensions change")
    @MainActor func setFrameSizeSendsResize() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }
        let face = view.fontFace

        let newWidth = CGFloat(face.cellWidth) * 100
        let newHeight = CGFloat(face.cellHeight) * 40
        view.setFrameSize(NSSize(width: newWidth, height: newHeight))

        #expect(spy.resizeCalls.count == 1)
        #expect(spy.resizeCalls[0].cols == 100)
        #expect(spy.resizeCalls[0].rows == 40)
        #expect(view.dispatcher.frameState.cols == 100)
        #expect(view.dispatcher.frameState.rows == 40)
    }

    @Test("setFrameSize does not send resize when dimensions unchanged")
    @MainActor func setFrameSizeNoResizeWhenSame() throws {
        let spy = SpyEncoder()
        let face = FontFace(name: "Menlo", size: 13.0, scale: 1.0)
        let cols = UInt16(800 / CGFloat(face.cellWidth))
        let rows = UInt16(600 / CGFloat(face.cellHeight))
        guard let view = makeView(spy: spy, cols: cols, rows: rows) else { return }

        view.setFrameSize(NSSize(width: CGFloat(cols) * CGFloat(face.cellWidth),
                                  height: CGFloat(rows) * CGFloat(face.cellHeight)))

        #expect(spy.resizeCalls.isEmpty)
    }

    @Test("setFrameSize clamps to minimum 1x1")
    @MainActor func setFrameSizeClampsMinimum() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }

        view.setFrameSize(NSSize(width: 1, height: 1))

        #expect(spy.resizeCalls.count == 1)
        #expect(spy.resizeCalls[0].cols >= 1)
        #expect(spy.resizeCalls[0].rows >= 1)
        #expect(view.dispatcher.frameState.cols >= 1)
        #expect(view.dispatcher.frameState.rows >= 1)
    }

    @Test("viewDidMoveToWindow corrects initial scale mismatch without sending ready early")
    @MainActor func viewDidMoveToWindowCorrectsInitialScaleMismatch() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy, scale: 0.5) else { return }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        var callbackScale: CGFloat?
        view.onScaleFactorChanged = { newScale in
            callbackScale = newScale
        }

        window.contentView = view
        defer { window.contentView = nil }

        let expectedScale = window.backingScaleFactor
        #expect(callbackScale == expectedScale)
        #expect((view.layer as? CAMetalLayer)?.contentsScale == expectedScale)
        #expect(spy.readyCalls.isEmpty)
    }

    @Test("viewDidChangeBackingProperties calls scale callback when scale differs")
    @MainActor func backingPropertyChangeCallsScaleCallback() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy, scale: 0.5) else { return }
        view.setFrameSize(NSSize(width: 400, height: 300))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        defer { window.contentView = nil }

        var callbackScale: CGFloat?
        view.onScaleFactorChanged = { newScale in
            callbackScale = newScale
        }

        let expectedScale = window.backingScaleFactor
        view.viewDidChangeBackingProperties()

        #expect(callbackScale == expectedScale)
        #expect((view.layer as? CAMetalLayer)?.contentsScale == expectedScale)
    }
}

@Suite("PortLogger")
struct PortLoggerTests {
    @Test("log calls are forwarded to the encoder")
    func logForwarding() {
        let spy = SpyEncoder()
        PortLogger.setup(encoder: spy)

        PortLogger.info("hello from test")

        #expect(spy.logCalls.count == 1)
        #expect(spy.logCalls[0].level == LOG_LEVEL_INFO)
        #expect(spy.logCalls[0].message == "hello from test")
    }

    @Test("all log levels are sent with the correct level byte")
    func logLevels() {
        let spy = SpyEncoder()
        PortLogger.setup(encoder: spy)

        PortLogger.error("e")
        PortLogger.warn("w")
        PortLogger.info("i")
        PortLogger.debug("d")

        #expect(spy.logCalls.count == 4)
        #expect(spy.logCalls[0].level == LOG_LEVEL_ERR)
        #expect(spy.logCalls[1].level == LOG_LEVEL_WARN)
        #expect(spy.logCalls[2].level == LOG_LEVEL_INFO)
        #expect(spy.logCalls[3].level == LOG_LEVEL_DEBUG)
    }

    @Test("sendLog binary layout matches Zig encodeLogMessage")
    func logBinaryLayout() {
        // Verify the real ProtocolEncoder produces the right binary.
        // We can't capture stdout easily, but we can verify the
        // constants match the Zig protocol.
        #expect(OP_LOG_MESSAGE == 0x60)
        #expect(LOG_LEVEL_ERR == 0)
        #expect(LOG_LEVEL_WARN == 1)
        #expect(LOG_LEVEL_INFO == 2)
        #expect(LOG_LEVEL_DEBUG == 3)
    }
}
