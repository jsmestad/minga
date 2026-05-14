/// Encodes input events from the GUI to the BEAM via stdout.
///
/// All events are length-prefixed with a 4-byte big-endian header
/// (`{:packet, 4}` framing). The encoder enqueues frames on a serial
/// write queue and drains stdout asynchronously so UI threads never block
/// behind pipe backpressure.

import Darwin
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
    func sendTabCopyPath(id: UInt32)
    func sendHoverOpenAction()
    func sendFileTreeClick(index: UInt16)
    func sendFileTreeToggle(index: UInt16)
    func sendFileTreeOpenInSplit(index: UInt16)
    func sendFileTreeNewFile(parentIndex: UInt16)
    func sendFileTreeNewFolder(parentIndex: UInt16)
    func sendFileTreeEditConfirm(text: String)
    func sendFileTreeEditCancel()
    func sendFileTreeDelete(index: UInt16)
    func sendFileTreeRename(index: UInt16)
    func sendFileTreeDuplicate(index: UInt16)
    func sendFileTreeMove(sourceIndex: UInt16, targetDirIndex: UInt16)
    func sendFileTreeCollapseAll()
    func sendFileTreeRefresh()
    func sendCompletionSelect(index: UInt16)
    func sendBreadcrumbClick(index: UInt8)
    func sendTogglePanel(panel: UInt8)
    func sendNewTab()
    func sendSystemWillSleep()
    func sendSystemDidWake()

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

    // Generic command execution
    func sendExecuteCommand(name: String)

    // Minibuffer actions
    func sendMinibufferSelect(index: UInt16)

    // Git status actions
    func sendGitStageFile(path: String)
    func sendGitUnstageFile(path: String)
    func sendGitDiscardFile(path: String)
    func sendGitStageAll()
    func sendGitUnstageAll()
    func sendGitCommit(message: String)
    func sendGitOpenFile(path: String)
    func sendGitPush()
    func sendGitPull()
    func sendGitFetch()
    func sendGitCommitAmend(message: String)
    func sendGitPullAndRetry()
    func sendGroupRename(id: UInt16, name: String)
    func sendGroupSetIcon(id: UInt16, icon: String)
    func sendGroupClose(id: UInt16)

    // Space leader key-chord
    func sendSpaceLeaderChord(codepoint: UInt32, modifiers: UInt8)
    func sendSpaceLeaderRetract(codepoint: UInt32, modifiers: UInt8)

    // Menu bar commands (mode-aware copy/cut from macOS menu)
    func sendCmdCopy()
    func sendCmdCut()

    // Find Pasteboard
    func sendFindPasteboardSearch(text: String, direction: UInt8)

    // Board actions
    func sendBoardSelectCard(id: UInt32)
    func sendBoardCloseCard(id: UInt32)
    func sendBoardReorder(cardId: UInt32, newIndex: UInt16)
    func sendDispatchAgent(task: String, model: String)

    // Agent review actions
    func sendAgentApprove()
    func sendAgentRequestChanges()
    func sendAgentDismiss()
    func sendChangeSummaryClick(index: UInt32)
    func sendScrollToLine(line: UInt32)
}

extension InputEncoder {
    /// Convenience: send a mouse event with click count defaulting to 1.
    func sendMouseEvent(row: Int16, col: Int16, button: UInt8, modifiers: UInt8, eventType: UInt8) {
        sendMouseEvent(row: row, col: col, button: button, modifiers: modifiers, eventType: eventType, clickCount: 1)
    }
}

/// Thread-safe encoder that writes `{:packet, 4}` framed events to stdout.
///
/// Uses POSIX `write()` instead of `FileHandle.write()` to avoid
/// `NSFileHandleOperationException` (ObjC exception) on broken pipes.
/// ObjC exceptions cannot be caught from Swift, so `FileHandle.write()`
/// to a dead pipe zombifies the app (beachball). POSIX `write()` returns
/// -1 with `errno = EPIPE`, which we handle by marking the encoder as
/// disconnected and silently dropping subsequent writes.
final class ProtocolEncoder: InputEncoder, @unchecked Sendable {
    private let fd: Int32
    private let writeQueue = DispatchQueue(label: "minga.encoder.write", qos: .userInteractive)
    private let writeQueueKey = DispatchSpecificKey<Void>()
    private let maxBufferSize: Int
    private let retryDelay: DispatchTimeInterval = .milliseconds(10)

    /// Once a write fails with EPIPE, all subsequent writes are dropped.
    private var connected: Bool = true
    private var writeBuffer = Data()
    private var bufferSize: Int = 0
    private var drainRetryScheduled: Bool = false
    private var droppedCount: UInt64 = 0

    /// Creates an encoder. Defaults to stdout for production use.
    /// Pass a pipe's write handle for testing binary layout.
    init(output: FileHandle = .standardOutput, maxBufferSize: Int = 64 * 1024) {
        self.fd = output.fileDescriptor
        self.maxBufferSize = maxBufferSize
        writeQueue.setSpecific(key: writeQueueKey, value: ())
        setNonBlocking(fd: fd)
    }

    /// Mark the encoder as disconnected. Called by the reader's
    /// `onDisconnect` callback so writes stop immediately without
    /// waiting for the next EPIPE.
    func disconnect() {
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.connected = false
            self.writeBuffer.removeAll(keepingCapacity: false)
            self.bufferSize = 0
        }
    }

    /// Snapshot of dropped messages for diagnostics and tests.
    var droppedMessageCount: UInt64 {
        if DispatchQueue.getSpecific(key: writeQueueKey) != nil {
            return droppedCount
        }
        return writeQueue.sync { droppedCount }
    }

    /// Snapshot of buffered bytes for diagnostics and tests.
    var bufferedByteCount: Int {
        if DispatchQueue.getSpecific(key: writeQueueKey) != nil {
            return bufferSize
        }
        return writeQueue.sync { bufferSize }
    }

    /// Snapshot of currently buffered framed bytes for unit tests.
    func bufferedDataForTesting() -> Data {
        if DispatchQueue.getSpecific(key: writeQueueKey) != nil {
            return writeBuffer
        }
        return writeQueue.sync { writeBuffer }
    }

    /// Blocks until previously enqueued writes have had a chance to drain.
    /// This is for unit tests only; production callers must not use it.
    @discardableResult
    func waitForPendingWritesForTesting(timeout: TimeInterval = 1.0) -> Bool {
        if DispatchQueue.getSpecific(key: writeQueueKey) != nil {
            return true
        }

        let semaphore = DispatchSemaphore(value: 0)
        writeQueue.async { [weak self] in
            self?.drainBuffer()
            semaphore.signal()
        }
        return semaphore.wait(timeout: .now() + timeout) == .success
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

    /// Send a gui_action: tab_copy_path. Layout: opcode(1) + action_type(1) + tab_id(4).
    func sendTabCopyPath(id: UInt32) {
        var buf = Data(count: 6)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_TAB_COPY_PATH
        writeU32(&buf, 2, id)
        writeFrame(buf)
    }

    /// Send a gui_action: hover_open_action. Layout: opcode(1) + action_type(1).
    func sendHoverOpenAction() {
        var buf = Data(count: 2)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_HOVER_OPEN_ACTION
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

    /// Send a gui_action: file_tree_open_in_split. Layout: opcode(1) + action_type(1) + index(2).
    func sendFileTreeOpenInSplit(index: UInt16) {
        var buf = Data(count: 4)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_FILE_TREE_OPEN_IN_SPLIT
        writeU16(&buf, 2, index)
        writeFrame(buf)
    }

    /// Send a gui_action: file_tree_new_file. Layout: opcode(1) + action_type(1) + parent_index(2).
    func sendFileTreeNewFile(parentIndex: UInt16) {
        var buf = Data(count: 4)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_FILE_TREE_NEW_FILE
        buf[2] = UInt8(parentIndex >> 8)
        buf[3] = UInt8(parentIndex & 0xFF)
        writeFrame(buf)
    }

    /// Send a gui_action: file_tree_new_folder. Layout: opcode(1) + action_type(1) + parent_index(2).
    func sendFileTreeNewFolder(parentIndex: UInt16) {
        var buf = Data(count: 4)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_FILE_TREE_NEW_FOLDER
        buf[2] = UInt8(parentIndex >> 8)
        buf[3] = UInt8(parentIndex & 0xFF)
        writeFrame(buf)
    }

    /// Send a gui_action: file_tree_edit_confirm. Layout: opcode(1) + action_type(1) + text_len(2) + text(N).
    func sendFileTreeEditConfirm(text: String) {
        let textData = text.data(using: .utf8) ?? Data()
        var buf = Data(count: 4 + textData.count)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_FILE_TREE_EDIT_CONFIRM
        buf[2] = UInt8(textData.count >> 8)
        buf[3] = UInt8(textData.count & 0xFF)
        buf.replaceSubrange(4..<(4 + textData.count), with: textData)
        writeFrame(buf)
    }

    /// Send a gui_action: file_tree_edit_cancel. Layout: opcode(1) + action_type(1).
    func sendFileTreeEditCancel() {
        var buf = Data(count: 2)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_FILE_TREE_EDIT_CANCEL
        writeFrame(buf)
    }

    /// Send a gui_action: file_tree_delete. Layout: opcode(1) + action_type(1) + index(2).
    func sendFileTreeDelete(index: UInt16) {
        var buf = Data(count: 4)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_FILE_TREE_DELETE
        buf[2] = UInt8(index >> 8)
        buf[3] = UInt8(index & 0xFF)
        writeFrame(buf)
    }

    /// Send a gui_action: file_tree_rename. Layout: opcode(1) + action_type(1) + index(2).
    func sendFileTreeRename(index: UInt16) {
        var buf = Data(count: 4)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_FILE_TREE_RENAME
        buf[2] = UInt8(index >> 8)
        buf[3] = UInt8(index & 0xFF)
        writeFrame(buf)
    }

    /// Send a gui_action: file_tree_duplicate. Layout: opcode(1) + action_type(1) + index(2).
    func sendFileTreeDuplicate(index: UInt16) {
        var buf = Data(count: 4)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_FILE_TREE_DUPLICATE
        buf[2] = UInt8(index >> 8)
        buf[3] = UInt8(index & 0xFF)
        writeFrame(buf)
    }

    /// Send a gui_action: file_tree_move. Layout: opcode(1) + action_type(1) + source(2) + target(2).
    func sendFileTreeMove(sourceIndex: UInt16, targetDirIndex: UInt16) {
        var buf = Data(count: 6)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_FILE_TREE_MOVE
        buf[2] = UInt8(sourceIndex >> 8)
        buf[3] = UInt8(sourceIndex & 0xFF)
        buf[4] = UInt8(targetDirIndex >> 8)
        buf[5] = UInt8(targetDirIndex & 0xFF)
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

    /// Send a gui_action: system_will_sleep. Layout: opcode(1) + action_type(1).
    func sendSystemWillSleep() {
        var buf = Data(count: 2)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_SYSTEM_WILL_SLEEP
        writeFrame(buf)
    }

    /// Send a gui_action: system_did_wake. Layout: opcode(1) + action_type(1).
    func sendSystemDidWake() {
        var buf = Data(count: 2)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_SYSTEM_DID_WAKE
        writeFrame(buf)
    }

    /// Send a gui_action: cmd_copy (mode-aware copy from menu bar).
    func sendCmdCopy() {
        var buf = Data(count: 2)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_CMD_COPY
        writeFrame(buf)
    }

    /// Send a gui_action: cmd_cut (mode-aware cut from menu bar).
    func sendCmdCut() {
        var buf = Data(count: 2)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_CMD_CUT
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

    /// Send a gui_action: execute_command. Layout: opcode(1) + action_type(1) + name_len(2) + name(name_len).
    ///
    /// Dispatches a named command through the BEAM's command registry.
    /// The command name must match a registered atom (e.g., "buffer_prev", "find_file").
    func sendExecuteCommand(name: String) {
        let utf8 = Array(name.utf8)
        let nameLen = min(utf8.count, Int(UInt16.max))
        var buf = Data(count: 4 + nameLen)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_EXECUTE_COMMAND
        writeU16(&buf, 2, UInt16(nameLen))
        if nameLen > 0 {
            buf.replaceSubrange(4..<4 + nameLen, with: utf8.prefix(nameLen))
        }
        writeFrame(buf)
    }

    /// Send a gui_action: minibuffer_select. Accepts a candidate by index.
    func sendMinibufferSelect(index: UInt16) {
        var buf = Data(count: 4)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_MINIBUFFER_SELECT
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

    // MARK: - Git Status Actions

    func sendGitStageFile(path: String) {
        sendGitPathAction(GUI_ACTION_GIT_STAGE_FILE, path: path)
    }

    func sendGitUnstageFile(path: String) {
        sendGitPathAction(GUI_ACTION_GIT_UNSTAGE_FILE, path: path)
    }

    func sendGitDiscardFile(path: String) {
        sendGitPathAction(GUI_ACTION_GIT_DISCARD_FILE, path: path)
    }

    func sendGitStageAll() {
        var buf = Data(count: 2)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_GIT_STAGE_ALL
        writeFrame(buf)
    }

    func sendGitUnstageAll() {
        var buf = Data(count: 2)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_GIT_UNSTAGE_ALL
        writeFrame(buf)
    }

    func sendGitCommit(message: String) {
        let utf8 = Array(message.utf8)
        let msgLen = min(utf8.count, Int(UInt16.max))
        var buf = Data(count: 4 + msgLen)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_GIT_COMMIT
        writeU16(&buf, 2, UInt16(msgLen))
        if msgLen > 0 {
            buf.replaceSubrange(4..<(4 + msgLen), with: utf8[0..<msgLen])
        }
        writeFrame(buf)
    }

    func sendGitOpenFile(path: String) {
        sendGitPathAction(GUI_ACTION_GIT_OPEN_FILE, path: path)
    }

    func sendGitPush() {
        var buf = Data(count: 2)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_GIT_PUSH
        writeFrame(buf)
    }

    func sendGitPull() {
        var buf = Data(count: 2)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_GIT_PULL
        writeFrame(buf)
    }

    func sendGitFetch() {
        var buf = Data(count: 2)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_GIT_FETCH
        writeFrame(buf)
    }

    func sendGitCommitAmend(message: String) {
        let utf8 = Array(message.utf8)
        let msgLen = min(utf8.count, Int(UInt16.max))
        var buf = Data(count: 4 + msgLen)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_GIT_COMMIT_AMEND
        writeU16(&buf, 2, UInt16(msgLen))
        if msgLen > 0 {
            buf.replaceSubrange(4..<(4 + msgLen), with: utf8[0..<msgLen])
        }
        writeFrame(buf)
    }

    /// Send a gui_action: git_pull_and_retry. Layout: opcode(1) + action_type(1).
    func sendGitPullAndRetry() {
        var buf = Data(count: 2)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_GIT_PULL_AND_RETRY
        writeFrame(buf)
    }

    func sendGroupRename(id: UInt16, name: String) {
        let utf8 = Array(name.utf8)
        let nameLen = min(utf8.count, Int(UInt16.max))
        var buf = Data(count: 6 + nameLen)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_GROUP_RENAME
        writeU16(&buf, 2, id)
        writeU16(&buf, 4, UInt16(nameLen))
        if nameLen > 0 {
            buf.replaceSubrange(6..<(6 + nameLen), with: utf8[0..<nameLen])
        }
        writeFrame(buf)
    }

    func sendGroupSetIcon(id: UInt16, icon: String) {
        let utf8 = Array(icon.utf8)
        let iconLen = min(utf8.count, 255)
        var buf = Data(count: 5 + iconLen)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_GROUP_SET_ICON
        writeU16(&buf, 2, id)
        buf[4] = UInt8(iconLen)
        if iconLen > 0 {
            buf.replaceSubrange(5..<(5 + iconLen), with: utf8[0..<iconLen])
        }
        writeFrame(buf)
    }

    func sendGroupClose(id: UInt16) {
        var buf = Data(count: 4)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_GROUP_CLOSE
        writeU16(&buf, 2, id)
        writeFrame(buf)
    }

    /// Send a gui_action: space_leader_chord.
    /// Clean chord: SPC was never sent. The BEAM enters leader mode directly.
    /// Layout: opcode(1) + action_type(1) + codepoint(4) + modifiers(1).
    func sendSpaceLeaderChord(codepoint: UInt32, modifiers: UInt8) {
        var buf = Data(count: 7)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_SPACE_LEADER_CHORD
        writeU32(&buf, 2, codepoint)
        buf[6] = modifiers
        writeFrame(buf)
    }

    /// Send a gui_action: space_leader_retract.
    /// Fallback chord: SPC was already sent (grace timer fired). The BEAM
    /// deletes the space and enters leader mode.
    /// Same wire format as chord (the BEAM needs the key that triggered it).
    func sendSpaceLeaderRetract(codepoint: UInt32, modifiers: UInt8) {
        var buf = Data(count: 7)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_SPACE_LEADER_RETRACT
        writeU32(&buf, 2, codepoint)
        buf[6] = modifiers
        writeFrame(buf)
    }

    /// Send a gui_action: find_pasteboard_search.
    /// Layout: opcode(1) + action_type(1) + direction(1) + text_len(2) + text.
    /// Direction: 0 = forward (Cmd+G), 1 = backward (Cmd+Shift+G).
    func sendFindPasteboardSearch(text: String, direction: UInt8) {
        let utf8 = Array(text.utf8)
        let textLen = min(utf8.count, Int(UInt16.max))
        var buf = Data(count: 5 + textLen)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_FIND_PASTEBOARD_SEARCH
        buf[2] = direction
        writeU16(&buf, 3, UInt16(textLen))
        if textLen > 0 {
            buf.replaceSubrange(5..<(5 + textLen), with: utf8[0..<textLen])
        }
        writeFrame(buf)
    }

    private func sendGitPathAction(_ actionType: UInt8, path: String) {
        let utf8 = Array(path.utf8)
        let pathLen = min(utf8.count, Int(UInt16.max))
        var buf = Data(count: 4 + pathLen)
        buf[0] = OP_GUI_ACTION
        buf[1] = actionType
        writeU16(&buf, 2, UInt16(pathLen))
        if pathLen > 0 {
            buf.replaceSubrange(4..<(4 + pathLen), with: utf8[0..<pathLen])
        }
        writeFrame(buf)
    }

    // MARK: - Board Actions

    /// Send a gui_action: board_select_card. Layout: opcode(1) + action_type(1) + card_id(4).
    func sendBoardSelectCard(id: UInt32) {
        var buf = Data(count: 6)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_BOARD_SELECT_CARD
        writeU32(&buf, 2, id)
        writeFrame(buf)
    }

    /// Send a gui_action: board_close_card. Layout: opcode(1) + action_type(1) + card_id(4).
    func sendBoardCloseCard(id: UInt32) {
        var buf = Data(count: 6)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_BOARD_CLOSE_CARD
        writeU32(&buf, 2, id)
        writeFrame(buf)
    }

    /// Send a gui_action: board_reorder. Layout: opcode(1) + action_type(1) + card_id(4) + new_index(2).
    func sendBoardReorder(cardId: UInt32, newIndex: UInt16) {
        var buf = Data(count: 8)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_BOARD_REORDER
        writeU32(&buf, 2, cardId)
        writeU16(&buf, 6, newIndex)
        writeFrame(buf)
    }

    /// Send a gui_action: board_dispatch_agent.
    /// Layout: opcode(1) + action_type(1) + model_len(2) + model_name + task_len(2) + task_text.
    func sendDispatchAgent(task: String, model: String) {
        let taskUtf8 = Array(task.utf8)
        let modelUtf8 = Array(model.utf8)
        let taskLen = min(taskUtf8.count, Int(UInt16.max))
        let modelLen = min(modelUtf8.count, Int(UInt16.max))

        var buf = Data(count: 6 + modelLen + taskLen)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_BOARD_DISPATCH_AGENT

        // Write model
        writeU16(&buf, 2, UInt16(modelLen))
        if modelLen > 0 {
            buf.replaceSubrange(4..<(4 + modelLen), with: modelUtf8[0..<modelLen])
        }

        // Write task
        let taskOffset = 4 + modelLen
        writeU16(&buf, taskOffset, UInt16(taskLen))
        if taskLen > 0 {
            buf.replaceSubrange((taskOffset + 2)..<(taskOffset + 2 + taskLen), with: taskUtf8[0..<taskLen])
        }

        writeFrame(buf)
    }

    /// Send a gui_action: agent_approve. Layout: opcode(1) + action_type(1).
    func sendAgentApprove() {
        var buf = Data(count: 2)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_AGENT_APPROVE
        writeFrame(buf)
    }

    /// Send a gui_action: agent_request_changes. Layout: opcode(1) + action_type(1).
    func sendAgentRequestChanges() {
        var buf = Data(count: 2)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_AGENT_REQUEST_CHANGES
        writeFrame(buf)
    }

    /// Send a gui_action: agent_dismiss. Layout: opcode(1) + action_type(1).
    func sendAgentDismiss() {
        var buf = Data(count: 2)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_AGENT_DISMISS
        writeFrame(buf)
    }

    /// Send a gui_action: change_summary_click. Layout: opcode(1) + action_type(1) + index(4).
    func sendChangeSummaryClick(index: UInt32) {
        var buf = Data(count: 6)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_CHANGE_SUMMARY_CLICK
        writeU32(&buf, 2, index)
        writeFrame(buf)
    }

    /// Send a gui_action: scroll_to_line. Layout: opcode(1) + action_type(1) + line(4).
    func sendScrollToLine(line: UInt32) {
        var buf = Data(count: 6)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_SCROLL_TO_LINE
        writeU32(&buf, 2, line)
        writeFrame(buf)
    }

    // MARK: - Private

    /// Enqueue a length-prefixed frame for asynchronous POSIX `write()`.
    ///
    /// `FileHandle.write()` raises an ObjC `NSFileHandleOperationException`
    /// on EPIPE that Swift cannot catch, zombifying the app. POSIX `write()`
    /// returns -1 and sets `errno = EPIPE`, which we handle by flipping
    /// `connected` to false. The file descriptor is non-blocking, so pipe
    /// backpressure returns EAGAIN instead of freezing the caller.
    private func writeFrame(_ payload: Data) {
        let frame = makeFrame(payload)
        writeQueue.async { [weak self] in
            guard let self, self.connected else { return }
            self.writeBuffer.append(frame)
            self.bufferSize += frame.count
            self.dropOldestFramesIfNeeded()
            self.drainBuffer()
        }
    }

    private func makeFrame(_ payload: Data) -> Data {
        var frame = Data(count: 4 + payload.count)
        let len = UInt32(payload.count)
        frame[0] = UInt8((len >> 24) & 0xFF)
        frame[1] = UInt8((len >> 16) & 0xFF)
        frame[2] = UInt8((len >> 8) & 0xFF)
        frame[3] = UInt8(len & 0xFF)
        frame.replaceSubrange(4..<(4 + payload.count), with: payload)
        return frame
    }

    private func drainBuffer() {
        guard connected else { return }

        while bufferSize > 0 {
            let written = writeBuffer.withUnsafeBytes { buffer -> Int in
                guard let ptr = buffer.baseAddress else { return 0 }
                return Darwin.write(fd, ptr, bufferSize)
            }

            if written > 0 {
                writeBuffer.removeSubrange(0..<written)
                bufferSize -= written
                continue
            }

            if written == 0 {
                scheduleDrainRetry()
                return
            }

            let error = errno
            if error == EINTR {
                continue
            }
            if error == EAGAIN || error == EWOULDBLOCK {
                scheduleDrainRetry()
                return
            }

            connected = false
            writeBuffer.removeAll(keepingCapacity: false)
            bufferSize = 0
            return
        }
    }

    private func scheduleDrainRetry() {
        guard !drainRetryScheduled, connected else { return }
        drainRetryScheduled = true
        writeQueue.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
            guard let self else { return }
            self.drainRetryScheduled = false
            self.drainBuffer()
        }
    }

    private func dropOldestFramesIfNeeded() {
        guard bufferSize > maxBufferSize else { return }

        var droppedThisPass: UInt64 = 0
        while bufferSize > maxBufferSize, writeBuffer.count >= 4 {
            let payloadLength = Int(writeBuffer[0]) << 24 | Int(writeBuffer[1]) << 16 | Int(writeBuffer[2]) << 8 | Int(writeBuffer[3])
            let frameLength = 4 + payloadLength
            guard frameLength > 4, frameLength <= writeBuffer.count else {
                writeBuffer.removeAll(keepingCapacity: false)
                bufferSize = 0
                droppedThisPass += 1
                break
            }

            // A single valid frame can be slightly larger than the default
            // threshold, for example a maximum-size paste event. Preserve it
            // rather than silently dropping user input before a drain attempt.
            guard frameLength < writeBuffer.count else { break }

            writeBuffer.removeSubrange(0..<frameLength)
            bufferSize -= frameLength
            droppedThisPass += 1
        }

        guard droppedThisPass > 0 else { return }
        droppedCount += droppedThisPass
        PortLogger.warn("GUI output buffer exceeded \(maxBufferSize) bytes; dropped \(droppedThisPass) oldest messages (total \(droppedCount))")
    }

    private func setNonBlocking(fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { return }
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
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
