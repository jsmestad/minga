/// The `InputEncoder` protocol: the GUI-to-BEAM input event surface.
///
/// Lives in `MingaUI` so chrome views and preview support can depend on the
/// abstract encoder without pulling in the concrete stdout `ProtocolEncoder`
/// (which lives in the app target alongside the Metal renderer). The real
/// implementation writes `{:packet, 4}` framed events to stdout; tests and
/// previews use spy or null conformances.

import Foundation
import MingaProtocol

/// Protocol for sending input events to the BEAM. The real implementation
/// writes to stdout; tests can use a spy conformance to verify calls.
public protocol InputEncoder: AnyObject, Sendable {
    func sendReady(cols: UInt16, rows: UInt16)
    func sendKeyPress(codepoint: UInt32, modifiers: UInt8)
    /// Send a key press carrying the latency correlation sequence (ticket
    /// #2215). The BEAM echoes the sequence on commit_frame so a keystroke-to-
    /// present sample can be resolved.
    func sendKeyPress(codepoint: UInt32, modifiers: UInt8, seq: UInt32)
    func sendResize(cols: UInt16, rows: UInt16)
    /// Ask the BEAM to send the next frame as a full keyframe (#2219 child D).
    /// Manual recovery request carrying the failed BEAM generation.
    func sendRequestKeyframe(lastGoodFrameSeq: UInt32, generation: UInt32)
    func sendFrameApplied(generation: UInt32, frameSeq: UInt32)
    func sendFrameRejected(generation: UInt32, frameSeq: UInt32, lastAppliedFrameSeq: UInt32, reason: UInt8)
    func sendWindowRefMiss(generation: UInt32, frameSeq: UInt32, lastAppliedFrameSeq: UInt32, windowId: UInt16)
    func sendMouseEvent(row: Int16, col: Int16, button: UInt8, modifiers: UInt8, eventType: UInt8, clickCount: UInt8)
    func sendPasteEvent(text: String)
    func sendLog(level: UInt8, message: String)

    // GUI actions (semantic commands from SwiftUI chrome)
    func sendSelectTab(id: UInt32)
    func sendCloseTab(id: UInt32)
    func sendEmptyStateActivate(id: String)
    func sendTabCopyPath(id: UInt32)
    func sendTabReorder(id: UInt32, newIndex: UInt16)
    func sendTabPin(id: UInt32)
    func sendTabUnpin(id: UInt32)
    func sendTabMoveLeft(id: UInt32)
    func sendTabMoveRight(id: UInt32)
    func sendHoverOpenAction()
    func sendPickerQueryChanged(generation: UInt32, editSeq: UInt32, text: String)
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
    func sendFileTreeDrop(sourcePaths: [String], targetIndex: UInt16, targetId: String, targetPathHash: UInt32, targetPath: String, targetIsDir: Bool, modifiers: UInt8)
    func sendFileTreeCollapseAll()
    func sendFileTreeRefresh()
    func sendCompletionSelect(index: UInt16)
    func sendBreadcrumbClick(index: UInt8)
    func sendTogglePanel(panel: UInt8)
    func sendSidebarAction(sidebarId: String, kind: String, action: String)
    func sendExtensionAction(extensionID: String, action: String, payload: Data)
    func sendNewTab()
    func sendSystemWillSleep()
    func sendSystemDidWake()
    func sendSystemWillUnmount(volumePath: String)
    func sendPowerThermalState(lowPowerMode: Bool, thermalState: UInt8)

    // Bottom panel actions
    func sendPanelSwitchTab(index: UInt8)
    func sendPanelDismiss()
    func sendPanelResize(heightPercent: UInt8)

    // File actions
    func sendOpenFile(path: String)


    // Agent chat actions
    func sendAgentToolToggle(messageID: UInt32)

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
    func sendGitOpenDiff(path: String, section: UInt8)
    func sendGitPush()
    func sendGitPull()
    func sendGitFetch()
    func sendGitCommitAmend(message: String)
    func sendGitPullAndRetry()
    func sendWorkspaceRename(id: UInt16, name: String)
    func sendWorkspaceSetIcon(id: UInt16, icon: String)
    func sendWorkspaceClose(id: UInt16)

    // Space leader key-chord
    func sendSpaceLeaderChord(codepoint: UInt32, modifiers: UInt8)
    func sendSpaceLeaderRetract(codepoint: UInt32, modifiers: UInt8)

    // Menu bar commands (mode-aware copy/cut from macOS menu)
    func sendCmdCopy()
    func sendCmdCut()

    // Find Pasteboard
    func sendFindPasteboardSearch(text: String, direction: UInt8)

    // Agent review actions
    func sendAgentApprove()
    func sendAgentRequestChanges()
    func sendAgentDismiss()
    func sendChangeSummaryClick(index: UInt32)
    func sendScrollToLine(line: UInt32)

    // Agent chat pin intents (#2654 slice 2): reported when a frontend that owns
    // its transcript scroll locally crosses the bottom threshold.
    func sendChatScrolledAwayFromBottom()
    func sendChatReturnedToBottom()
    func sendFoldToggleAtLine(windowId: UInt16, bufferLine: UInt32)

    // Native settings actions
    func sendConfigQuery()
    func sendConfigUpdate(key: String, value: SettingValue)

    // Notification center actions
    func sendNotificationDismiss(id: String)
    func sendNotificationAction(id: String, actionId: String)

    // BEAM Observatory actions
    func sendObservatoryInspect(pid: String)

    // Font size adjustment
    func sendFontSizeAdjust(direction: UInt8)

    // Scroll batching
    func sendScrollBatch(windowId: UInt16, deltaLines: Int16, direction: UInt8)

    // Edit timeline actions
    func sendTimelineNavigate(index: UInt16)

    // Search toolbar actions
    func sendSearchQuery(query: String, flags: UInt8)
    func sendSearchNext()
    func sendSearchPrev()
    func sendSearchReplace(replacement: String)
    func sendSearchReplaceAll(replacement: String)
    func sendSearchDismiss()
}

public extension InputEncoder {
    /// Convenience: send a mouse event with click count defaulting to 1.
    func sendMouseEvent(row: Int16, col: Int16, button: UInt8, modifiers: UInt8, eventType: UInt8) {
        sendMouseEvent(row: row, col: col, button: button, modifiers: modifiers, eventType: eventType, clickCount: 1)
    }

    /// Default: forward to the sequence-less encoder so existing test spies and
    /// alternate conformers do not need to implement latency stamping (ticket
    /// #2215). `ProtocolEncoder` overrides this to append the sequence on the wire.
    func sendKeyPress(codepoint: UInt32, modifiers: UInt8, seq: UInt32) {
        sendKeyPress(codepoint: codepoint, modifiers: modifiers)
    }

    /// Default no-ops so existing test spies need not implement frame status.
    func sendRequestKeyframe(lastGoodFrameSeq: UInt32, generation: UInt32) {}
    func sendFrameApplied(generation: UInt32, frameSeq: UInt32) {}
    func sendFrameRejected(generation: UInt32, frameSeq: UInt32, lastAppliedFrameSeq: UInt32, reason: UInt8) {}
    func sendWindowRefMiss(generation: UInt32, frameSeq: UInt32, lastAppliedFrameSeq: UInt32, windowId: UInt16) {}

    /// Default no-op so existing test spies do not need to implement native picker editing.
    func sendPickerQueryChanged(generation: UInt32, editSeq: UInt32, text: String) {}

    /// Default no-op so existing test spies do not need to implement settings actions.
    func sendConfigQuery() {}

    /// Default no-op so existing test spies do not need to implement settings actions.
    func sendConfigUpdate(key: String, value: SettingValue) {}

    /// Default no-op so existing test spies do not need to implement notification actions.
    func sendNotificationDismiss(id: String) {}

    /// Default no-op so existing test spies do not need to implement notification actions.
    func sendNotificationAction(id: String, actionId: String) {}

    /// Default no-op so existing test spies do not need to implement sidebar host actions.
    func sendSidebarAction(sidebarId: String, kind: String, action: String) {}

    /// Default no-op so existing test spies do not need to implement frontend extension actions.
    func sendExtensionAction(extensionID: String, action: String, payload: Data) {}

    /// Default no-op so existing test spies do not need to implement power and thermal actions.
    func sendPowerThermalState(lowPowerMode: Bool, thermalState: UInt8) {}

    /// Default no-op so existing test spies do not need to implement font size actions.
    func sendFontSizeAdjust(direction: UInt8) {}

    func sendScrollBatch(windowId: UInt16, deltaLines: Int16, direction: UInt8) {}

    /// Default no-op so existing test spies do not need to implement timeline actions.
    func sendTimelineNavigate(index: UInt16) {}

    /// Default no-op so existing test spies do not need to implement search actions.
    func sendSearchQuery(query: String, flags: UInt8) {}
    func sendSearchNext() {}
    func sendSearchPrev() {}
    func sendSearchReplace(replacement: String) {}
    func sendSearchReplaceAll(replacement: String) {}
    func sendSearchDismiss() {}

    /// Default no-op so existing test spies do not need to implement launchpad activation.
    func sendEmptyStateActivate(id: String) {}
}

/// A no-op `InputEncoder` for SwiftUI previews and canvas rendering.
///
/// Previews render chrome views without the concrete stdout `ProtocolEncoder`
/// (an app-target type that lives alongside the Metal renderer). Every method
/// is a no-op; user actions in a preview go nowhere. Methods that have a
/// default no-op in the protocol extension are inherited; the rest are
/// implemented explicitly here.
public final class NullInputEncoder: InputEncoder, @unchecked Sendable {
    public init() {}

    public func sendReady(cols: UInt16, rows: UInt16) {}
    public func sendKeyPress(codepoint: UInt32, modifiers: UInt8) {}
    public func sendResize(cols: UInt16, rows: UInt16) {}
    public func sendMouseEvent(row: Int16, col: Int16, button: UInt8, modifiers: UInt8, eventType: UInt8, clickCount: UInt8) {}
    public func sendPasteEvent(text: String) {}
    public func sendLog(level: UInt8, message: String) {}

    public func sendSelectTab(id: UInt32) {}
    public func sendCloseTab(id: UInt32) {}
    public func sendEmptyStateActivate(id: String) {}
    public func sendTabCopyPath(id: UInt32) {}
    public func sendTabReorder(id: UInt32, newIndex: UInt16) {}
    public func sendTabPin(id: UInt32) {}
    public func sendTabUnpin(id: UInt32) {}
    public func sendTabMoveLeft(id: UInt32) {}
    public func sendTabMoveRight(id: UInt32) {}
    public func sendHoverOpenAction() {}
    public func sendFileTreeClick(index: UInt16) {}
    public func sendFileTreeToggle(index: UInt16) {}
    public func sendFileTreeOpenInSplit(index: UInt16) {}
    public func sendFileTreeNewFile(parentIndex: UInt16) {}
    public func sendFileTreeNewFolder(parentIndex: UInt16) {}
    public func sendFileTreeEditConfirm(text: String) {}
    public func sendFileTreeEditCancel() {}
    public func sendFileTreeDelete(index: UInt16) {}
    public func sendFileTreeRename(index: UInt16) {}
    public func sendFileTreeDuplicate(index: UInt16) {}
    public func sendFileTreeMove(sourceIndex: UInt16, targetDirIndex: UInt16) {}
    public func sendFileTreeDrop(sourcePaths: [String], targetIndex: UInt16, targetId: String, targetPathHash: UInt32, targetPath: String, targetIsDir: Bool, modifiers: UInt8) {}
    public func sendFileTreeCollapseAll() {}
    public func sendFileTreeRefresh() {}
    public func sendCompletionSelect(index: UInt16) {}
    public func sendBreadcrumbClick(index: UInt8) {}
    public func sendTogglePanel(panel: UInt8) {}
    public func sendNewTab() {}
    public func sendSystemWillSleep() {}
    public func sendSystemDidWake() {}
    public func sendSystemWillUnmount(volumePath: String) {}
    public func sendPanelSwitchTab(index: UInt8) {}
    public func sendPanelDismiss() {}
    public func sendPanelResize(heightPercent: UInt8) {}
    public func sendOpenFile(path: String) {}
    public func sendAgentToolToggle(messageID: UInt32) {}
    public func sendExecuteCommand(name: String) {}
    public func sendMinibufferSelect(index: UInt16) {}
    public func sendGitStageFile(path: String) {}
    public func sendGitUnstageFile(path: String) {}
    public func sendGitDiscardFile(path: String) {}
    public func sendGitStageAll() {}
    public func sendGitUnstageAll() {}
    public func sendGitCommit(message: String) {}
    public func sendGitOpenFile(path: String) {}
    public func sendGitOpenDiff(path: String, section: UInt8) {}
    public func sendGitPush() {}
    public func sendGitPull() {}
    public func sendGitFetch() {}
    public func sendGitCommitAmend(message: String) {}
    public func sendGitPullAndRetry() {}
    public func sendWorkspaceRename(id: UInt16, name: String) {}
    public func sendWorkspaceSetIcon(id: UInt16, icon: String) {}
    public func sendWorkspaceClose(id: UInt16) {}
    public func sendSpaceLeaderChord(codepoint: UInt32, modifiers: UInt8) {}
    public func sendSpaceLeaderRetract(codepoint: UInt32, modifiers: UInt8) {}
    public func sendCmdCopy() {}
    public func sendCmdCut() {}
    public func sendFindPasteboardSearch(text: String, direction: UInt8) {}
    public func sendAgentApprove() {}
    public func sendAgentRequestChanges() {}
    public func sendAgentDismiss() {}
    public func sendChangeSummaryClick(index: UInt32) {}
    public func sendScrollToLine(line: UInt32) {}
    public func sendChatScrolledAwayFromBottom() {}
    public func sendChatReturnedToBottom() {}
    public func sendFoldToggleAtLine(windowId: UInt16, bufferLine: UInt32) {}
    public func sendObservatoryInspect(pid: String) {}
}
