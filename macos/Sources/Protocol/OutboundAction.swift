import Foundation
import MingaProtocol

/// Every event the native frontend can send to the BEAM.
///
/// This is the only production outbound action hierarchy. `ProtocolEncoder`
/// exhaustively chooses the wire encoding for every case.
public enum OutboundAction: Equatable, Sendable {
    case ready(cols: UInt16, rows: UInt16)
    case keyPress(codepoint: UInt32, modifiers: UInt8, sequence: UInt32)
    case resize(cols: UInt16, rows: UInt16)
    case requestKeyframe(lastGoodFrameSequence: UInt32, generation: UInt32)
    case frameApplied(generation: UInt32, frameSequence: UInt32)
    case frameRejected(generation: UInt32, frameSequence: UInt32, lastAppliedFrameSequence: UInt32, reason: UInt8, disposition: UInt8)
    case windowReferenceMiss(generation: UInt32, frameSequence: UInt32, lastAppliedFrameSequence: UInt32, windowID: UInt16)
    case operationNativeResult(NativeOperationResult)
    case nativePresentationObservation(NativePresentationEvidence)
    case applicationQuitRequest(requestID: UInt32)
    case applicationQuitDecision(requestID: UInt32, decision: UInt8)
    case fileDialogResult(requestID: UInt32, outcome: UInt8, paths: [String])
    case mouse(row: Int16, column: Int16, button: UInt8, modifiers: UInt8, eventType: UInt8, clickCount: UInt8)
    case scrollBatch(windowID: UInt16, deltaLines: Int16, direction: UInt8)
    case paste(String)
    case log(level: UInt8, message: String)
    case selectTab(id: UInt32)
    case closeTab(id: UInt32)
    case emptyStateActivate(id: String)
    case tabCopyPath(id: UInt32)
    case tabReorder(id: UInt32, newIndex: UInt16)
    case tabPin(id: UInt32)
    case tabUnpin(id: UInt32)
    case tabMoveLeft(id: UInt32)
    case tabMoveRight(id: UInt32)
    case hoverOpen
    case pickerQueryChanged(generation: UInt32, editSequence: UInt32, text: String)
    case pickerItemActivate(generation: UInt32, activationID: UInt32)
    case pickerActionActivate(generation: UInt32, activationID: UInt32)
    case fileTreeClick(index: UInt16)
    case fileTreeToggle(index: UInt16)
    case fileTreeOpenInSplit(index: UInt16)
    case fileTreeNewFile(parentIndex: UInt16)
    case fileTreeNewFolder(parentIndex: UInt16)
    case fileTreeEditConfirm(token: UInt32, text: String)
    case fileTreeEditCancel
    case fileTreeDelete(index: UInt16)
    case fileTreeRename(index: UInt16)
    case fileTreeDuplicate(index: UInt16)
    case fileTreeMove(sourceIndex: UInt16, targetDirectoryIndex: UInt16)
    case fileTreeDrop(sourcePaths: [String], targetIndex: UInt16, targetID: String, targetPathHash: UInt32, targetPath: String, targetIsDirectory: Bool, modifiers: UInt8)
    case fileTreeCollapseAll
    case fileTreeRefresh
    case completionSelect(itemID: String)
    case togglePanel(panel: UInt8)
    case sidebarAction(sidebarID: String, kind: String, action: String)
    case extensionAction(extensionID: String, action: String, payload: Data)
    case newTab
    case systemWillSleep
    case systemDidWake
    case systemWillUnmount(volumePath: String)
    case powerThermalState(lowPowerMode: Bool, thermalState: UInt8)
    case commandCopy
    case commandCut
    case panelSwitchTab(index: UInt8)
    case panelDismiss
    case panelResize(heightPercent: UInt8)
    case agentToolToggle(messageID: UInt32)
    case executeCommand(name: String)
    case minibufferSelect(index: UInt16)
    case openFile(path: String)
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
    case workspaceRename(id: UInt16, name: String)
    case workspaceSetIcon(id: UInt16, icon: String)
    case workspaceClose(id: UInt16)
    case spaceLeaderChord(codepoint: UInt32, modifiers: UInt8)
    case spaceLeaderRetract(codepoint: UInt32, modifiers: UInt8)
    case findPasteboardSearch(text: String, direction: UInt8)
    case agentApprove
    case agentRequestChanges
    case agentDismiss
    case chatScrolledAwayFromBottom
    case chatReturnedToBottom
    case scrollToLine(line: UInt32)
    case foldToggleAtLine(windowID: UInt16, bufferLine: UInt32)
    case focusWindow(windowID: UInt16, generation: UInt64)
    case configQuery
    case configUpdate(key: String, value: SettingValue)
    case notificationDismiss(id: String)
    case notificationAction(id: String, actionID: String)
    case observatoryInspect(pid: String)
    case fontSizeAdjust(direction: UInt8)
    case timelineNavigate(index: UInt16)
    case searchFocus(replaceMode: Bool)
    case searchQuery(sessionID: UInt32, editSequence: UInt32, query: String, flags: UInt8)
    case searchNext
    case searchPrevious
    case searchReplace(replacement: String)
    case searchReplaceAll(replacement: String)
    case searchDismiss
}

/// A reason an outbound action was not admitted to the ordered transport.
public enum OutboundActionRejection: Equatable, Sendable {
    case disconnected
    case payloadTooLarge(limitBytes: Int, attemptedBytes: Int)
    case collectionTooLarge(limitCount: Int, attemptedCount: Int)
    case capacityExhausted(limitBytes: Int, attemptedBytes: Int)
    case invalidPayload(String)
}

/// The synchronous admission outcome for one outbound action.
public enum OutboundActionResult: Equatable, Sendable {
    case accepted
    case rejected(OutboundActionRejection)

    public var wasAccepted: Bool {
        self == .accepted
    }
}

/// The raw-input and app-composition boundary for outbound actions.
public protocol OutboundActionEncoding: AnyObject, Sendable {
    @discardableResult
    func send(_ action: OutboundAction) -> OutboundActionResult
}

/// An explicit closure-backed boundary for previews, tests, and disconnected state.
public final class ClosureOutboundActionEncoder: OutboundActionEncoding, Sendable {
    private let handler: @Sendable (OutboundAction) -> OutboundActionResult

    public init(handler: @escaping @Sendable (OutboundAction) -> OutboundActionResult) {
        self.handler = handler
    }

    @discardableResult
    public func send(_ action: OutboundAction) -> OutboundActionResult {
        handler(action)
    }
}
