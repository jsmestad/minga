/// Encodes input events from the GUI to the BEAM via stdout.
///
/// All events are length-prefixed with a 4-byte big-endian header
/// (`{:packet, 4}` framing). The encoder writes directly to stdout
/// with a lock to prevent interleaved writes from multiple threads.

import Foundation

/// Protocol for sending input events to the BEAM. The real implementation
/// writes to stdout; tests can use a spy conformance to verify calls.
protocol InputEncoder: AnyObject, Sendable {
    func sendReady(cols: UInt16, rows: UInt16)
    func sendKeyPress(codepoint: UInt32, modifiers: UInt8)
    func sendResize(cols: UInt16, rows: UInt16)
    func sendMouseEvent(row: Int16, col: Int16, button: UInt8, modifiers: UInt8, eventType: UInt8, clickCount: UInt8)
    func sendPasteEvent(text: String)
    func sendLog(level: UInt8, message: String)

    // GUI actions (semantic commands from SwiftUI chrome)
    func sendSelectTab(id: UInt32)
    func sendCloseTab(id: UInt32)
    func sendFileTreeClick(index: UInt16)
    func sendFileTreeToggle(index: UInt16)
    func sendFileTreeNewFile()
    func sendFileTreeNewFolder()
    func sendFileTreeCollapseAll()
    func sendFileTreeRefresh()
    func sendCompletionSelect(index: UInt16)
    func sendBreadcrumbClick(index: UInt8)
    func sendTogglePanel(panel: UInt8)
    func sendNewTab()

    // Bottom panel actions
    func sendPanelSwitchTab(index: UInt8)
    func sendPanelDismiss()
    func sendPanelResize(heightPercent: UInt8)

    // File actions
    func sendOpenFile(path: String)

    // Tool manager actions
    func sendToolInstall(name: String)
    func sendToolUninstall(name: String)
    func sendToolUpdate(name: String)
    func sendToolDismiss()

    // Agent chat actions
    func sendAgentToolToggle(index: UInt16)
}

extension InputEncoder {
    /// Convenience: send a mouse event with click count defaulting to 1.
    func sendMouseEvent(row: Int16, col: Int16, button: UInt8, modifiers: UInt8, eventType: UInt8) {
        sendMouseEvent(row: row, col: col, button: button, modifiers: modifiers, eventType: eventType, clickCount: 1)
    }
}

/// Thread-safe encoder that writes `{:packet, 4}` framed events to stdout.
final class ProtocolEncoder: InputEncoder, @unchecked Sendable {
    private let lock = NSLock()
    private let output: FileHandle

    /// Creates an encoder. Defaults to stdout for production use.
    /// Pass a pipe's write handle for testing binary layout.
    init(output: FileHandle = .standardOutput) {
        self.output = output
    }

    /// Send the ready event with initial dimensions and capabilities.
    func sendReady(cols: UInt16, rows: UInt16) {
        var buf = Data(count: 13)
        buf[0] = OP_READY
        writeU16(&buf, 1, cols)
        writeU16(&buf, 3, rows)
        buf[5] = CAPS_VERSION
        buf[6] = 6 // 6 capability fields
        buf[7] = FRONTEND_NATIVE_GUI
        buf[8] = COLOR_RGB
        buf[9] = UNICODE_15
        buf[10] = IMAGE_NATIVE
        buf[11] = FLOAT_NATIVE
        buf[12] = TEXT_PROPORTIONAL
        writeFrame(buf)
    }

    /// Send a key press event.
    func sendKeyPress(codepoint: UInt32, modifiers: UInt8) {
        var buf = Data(count: 6)
        buf[0] = OP_KEY_PRESS
        writeU32(&buf, 1, codepoint)
        buf[5] = modifiers
        writeFrame(buf)
    }

    /// Send a resize event (dimensions in cells).
    func sendResize(cols: UInt16, rows: UInt16) {
        var buf = Data(count: 5)
        buf[0] = OP_RESIZE
        writeU16(&buf, 1, cols)
        writeU16(&buf, 3, rows)
        writeFrame(buf)
    }

    /// Send a mouse event with click count.
    /// GUI frontends send the native `NSEvent.clickCount`; the BEAM uses it
    /// directly for double/triple-click detection (no timing needed).
    func sendMouseEvent(row: Int16, col: Int16, button: UInt8, modifiers: UInt8, eventType: UInt8, clickCount: UInt8) {
        var buf = Data(count: 9)
        buf[0] = OP_MOUSE_EVENT
        writeI16(&buf, 1, row)
        writeI16(&buf, 3, col)
        buf[5] = button
        buf[6] = modifiers
        buf[7] = eventType
        buf[8] = clickCount
        writeFrame(buf)
    }

    /// Send a paste event to the BEAM containing the full pasted text.
    /// Layout: opcode(1) + text_len(2, big-endian) + text(text_len).
    /// Text is UTF-8 encoded. Maximum length is 65535 bytes (UInt16.max).
    func sendPasteEvent(text: String) {
        let utf8 = Array(text.utf8)
        let textLen = min(utf8.count, Int(UInt16.max))
        var buf = Data(count: 3 + textLen)
        buf[0] = OP_PASTE_EVENT
        writeU16(&buf, 1, UInt16(textLen))
        if textLen > 0 {
            buf.replaceSubrange(3..<(3 + textLen), with: utf8[0..<textLen])
        }
        writeFrame(buf)
    }

    /// Send a log message to the BEAM for display in *Messages*.
    /// Layout: opcode(1) + level(1) + msg_len(2, big-endian) + msg(msg_len).
    func sendLog(level: UInt8, message: String) {
        let utf8 = Array(message.utf8)
        let msgLen = min(utf8.count, Int(UInt16.max))
        var buf = Data(count: 4 + msgLen)
        buf[0] = OP_LOG_MESSAGE
        buf[1] = level
        writeU16(&buf, 2, UInt16(msgLen))
        if msgLen > 0 {
            buf.replaceSubrange(4..<(4 + msgLen), with: utf8[0..<msgLen])
        }
        writeFrame(buf)
    }

    // MARK: - GUI Actions

    /// Send a gui_action: select_tab. Layout: opcode(1) + action_type(1) + tab_id(4).
    func sendSelectTab(id: UInt32) {
        var buf = Data(count: 6)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_SELECT_TAB
        writeU32(&buf, 2, id)
        writeFrame(buf)
    }

    /// Send a gui_action: close_tab. Layout: opcode(1) + action_type(1) + tab_id(4).
    func sendCloseTab(id: UInt32) {
        var buf = Data(count: 6)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_CLOSE_TAB
        writeU32(&buf, 2, id)
        writeFrame(buf)
    }

    /// Send a gui_action: file_tree_click. Layout: opcode(1) + action_type(1) + index(2).
    func sendFileTreeClick(index: UInt16) {
        var buf = Data(count: 4)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_FILE_TREE_CLICK
        writeU16(&buf, 2, index)
        writeFrame(buf)
    }

    /// Send a gui_action: file_tree_toggle. Layout: opcode(1) + action_type(1) + index(2).
    func sendFileTreeToggle(index: UInt16) {
        var buf = Data(count: 4)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_FILE_TREE_TOGGLE
        writeU16(&buf, 2, index)
        writeFrame(buf)
    }

    /// Send a gui_action: file_tree_new_file. Layout: opcode(1) + action_type(1).
    func sendFileTreeNewFile() {
        var buf = Data(count: 2)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_FILE_TREE_NEW_FILE
        writeFrame(buf)
    }

    /// Send a gui_action: file_tree_new_folder. Layout: opcode(1) + action_type(1).
    func sendFileTreeNewFolder() {
        var buf = Data(count: 2)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_FILE_TREE_NEW_FOLDER
        writeFrame(buf)
    }

    /// Send a gui_action: file_tree_collapse_all. Layout: opcode(1) + action_type(1).
    func sendFileTreeCollapseAll() {
        var buf = Data(count: 2)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_FILE_TREE_COLLAPSE_ALL
        writeFrame(buf)
    }

    /// Send a gui_action: file_tree_refresh. Layout: opcode(1) + action_type(1).
    func sendFileTreeRefresh() {
        var buf = Data(count: 2)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_FILE_TREE_REFRESH
        writeFrame(buf)
    }

    /// Send a gui_action: completion_select. Layout: opcode(1) + action_type(1) + index(2).
    func sendCompletionSelect(index: UInt16) {
        var buf = Data(count: 4)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_COMPLETION_SELECT
        writeU16(&buf, 2, index)
        writeFrame(buf)
    }

    /// Send a gui_action: breadcrumb_click. Layout: opcode(1) + action_type(1) + index(1).
    func sendBreadcrumbClick(index: UInt8) {
        var buf = Data(count: 3)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_BREADCRUMB_CLICK
        buf[2] = index
        writeFrame(buf)
    }

    /// Send a gui_action: toggle_panel. Layout: opcode(1) + action_type(1) + panel(1).
    func sendTogglePanel(panel: UInt8) {
        var buf = Data(count: 3)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_TOGGLE_PANEL
        buf[2] = panel
        writeFrame(buf)
    }

    /// Send a gui_action: new_tab. Layout: opcode(1) + action_type(1).
    func sendNewTab() {
        var buf = Data(count: 2)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_NEW_TAB
        writeFrame(buf)
    }

    /// Send a gui_action: panel_switch_tab. Layout: opcode(1) + action_type(1) + tab_index(1).
    func sendPanelSwitchTab(index: UInt8) {
        var buf = Data(count: 3)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_PANEL_SWITCH_TAB
        buf[2] = index
        writeFrame(buf)
    }

    /// Send a gui_action: panel_dismiss. Layout: opcode(1) + action_type(1).
    func sendPanelDismiss() {
        var buf = Data(count: 2)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_PANEL_DISMISS
        writeFrame(buf)
    }

    /// Send a gui_action: panel_resize. Layout: opcode(1) + action_type(1) + height_percent(1).
    func sendPanelResize(heightPercent: UInt8) {
        var buf = Data(count: 3)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_PANEL_RESIZE
        buf[2] = heightPercent
        writeFrame(buf)
    }

    /// Send a gui_action: tool_install. Layout: opcode(1) + action_type(1) + name_len(2) + name.
    func sendToolInstall(name: String) {
        sendToolAction(GUI_ACTION_TOOL_INSTALL, name: name)
    }

    /// Send a gui_action: tool_uninstall. Layout: opcode(1) + action_type(1) + name_len(2) + name.
    func sendToolUninstall(name: String) {
        sendToolAction(GUI_ACTION_TOOL_UNINSTALL, name: name)
    }

    /// Send a gui_action: tool_update. Layout: opcode(1) + action_type(1) + name_len(2) + name.
    func sendToolUpdate(name: String) {
        sendToolAction(GUI_ACTION_TOOL_UPDATE, name: name)
    }

    /// Send a gui_action: tool_dismiss.
    func sendToolDismiss() {
        var buf = Data(count: 2)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_TOOL_DISMISS
        writeFrame(buf)
    }

    private func sendToolAction(_ actionType: UInt8, name: String) {
        let utf8 = Array(name.utf8)
        let nameLen = min(utf8.count, Int(UInt16.max))
        var buf = Data(count: 4 + nameLen)
        buf[0] = OP_GUI_ACTION
        buf[1] = actionType
        writeU16(&buf, 2, UInt16(nameLen))
        if nameLen > 0 {
            buf.replaceSubrange(4..<(4 + nameLen), with: utf8[0..<nameLen])
        }
        writeFrame(buf)
    }

    /// Send a gui_action: agent_tool_toggle. Layout: opcode(1) + action_type(1) + index(2).
    func sendAgentToolToggle(index: UInt16) {
        var buf = Data(count: 4)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_AGENT_TOOL_TOGGLE
        writeU16(&buf, 2, index)
        writeFrame(buf)
    }

    /// Send a gui_action: open_file. Layout: opcode(1) + action_type(1) + path_len(2) + path(path_len).
    func sendOpenFile(path: String) {
        let utf8 = Array(path.utf8)
        let pathLen = min(utf8.count, Int(UInt16.max))
        var buf = Data(count: 4 + pathLen)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_OPEN_FILE
        writeU16(&buf, 2, UInt16(pathLen))
        if pathLen > 0 {
            buf.replaceSubrange(4..<(4 + pathLen), with: utf8[0..<pathLen])
        }
        writeFrame(buf)
    }

    // MARK: - Private

    /// Write a length-prefixed frame to stdout.
    private func writeFrame(_ payload: Data) {
        var frame = Data(count: 4 + payload.count)
        let len = UInt32(payload.count)
        frame[0] = UInt8((len >> 24) & 0xFF)
        frame[1] = UInt8((len >> 16) & 0xFF)
        frame[2] = UInt8((len >> 8) & 0xFF)
        frame[3] = UInt8(len & 0xFF)
        frame.replaceSubrange(4..<(4 + payload.count), with: payload)

        lock.lock()
        defer { lock.unlock() }
        output.write(frame)
    }

    private func writeU16(_ buf: inout Data, _ offset: Int, _ value: UInt16) {
        buf[offset] = UInt8((value >> 8) & 0xFF)
        buf[offset + 1] = UInt8(value & 0xFF)
    }

    private func writeU32(_ buf: inout Data, _ offset: Int, _ value: UInt32) {
        buf[offset] = UInt8((value >> 24) & 0xFF)
        buf[offset + 1] = UInt8((value >> 16) & 0xFF)
        buf[offset + 2] = UInt8((value >> 8) & 0xFF)
        buf[offset + 3] = UInt8(value & 0xFF)
    }

    private func writeI16(_ buf: inout Data, _ offset: Int, _ value: Int16) {
        writeU16(&buf, offset, UInt16(bitPattern: value))
    }
}
