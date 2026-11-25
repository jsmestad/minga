import Foundation
import MingaProtocol

nonisolated public enum SemanticItemSurface: UInt8, Equatable, Sendable {
    case completion = 1
    case picker = 2
    case fileTree = 3
    case commandCompletion = 4
    case timeline = 5
    case review = 6
}

/// A row offered by a particular installation of the Git status panel.
nonisolated public struct GitStatusEntryTarget: Equatable, Sendable {
    public let panelID: UInt64
    public let path: String
    public let section: UInt8

    public init(panelID: UInt64, path: String, section: UInt8) {
        self.panelID = panelID
        self.path = path
        self.section = section
    }
}

/// A position in the immutable composed row that the frontend displayed.
nonisolated public struct EditorTextTarget: Equatable, Sendable {
    public let windowID: UInt16
    public let presentationID: UInt64
    public let rowIndex: UInt32
    public let rowID: UInt64
    public let utf16Offset: UInt32

    public init(windowID: UInt16, presentationID: UInt64, rowIndex: UInt32, rowID: UInt64, utf16Offset: UInt32) {
        self.windowID = windowID
        self.presentationID = presentationID
        self.rowIndex = rowIndex
        self.rowID = rowID
        self.utf16Offset = utf16Offset
    }
}

nonisolated public enum TextPresentationState: UInt8, Equatable, Sendable {
    case discarded = 0
    case active = 1
}
/// Semantic tool-approval decisions; wire values belong to the generated protocol.
nonisolated public enum AgentApprovalDecision: Equatable, Sendable {
    case approve
    case approveSession
    case approveTurn
    case reject
}


/// Every event the native frontend can send to the BEAM.
///
/// This is the only production outbound action hierarchy. `ProtocolEncoder`
/// exhaustively chooses the wire encoding for every case.
nonisolated public enum OutboundAction: Equatable, Sendable {
    case ready(cols: UInt16, rows: UInt16)
    case keyPress(codepoint: UInt32, modifiers: UInt8, sequence: UInt32, composerOffer: UInt64 = 0)
    case resize(cols: UInt16, rows: UInt16)
    /// Whether the app is in the foreground (active) or in the background. Sent once after `ready` and on every change.
    case frontendForeground(Bool)
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
    case editorText(target: EditorTextTarget, button: UInt8, modifiers: UInt8, eventType: UInt8, clickCount: UInt8, scrollX: Int8, scrollY: Int8)
    case textPresentationState(windowID: UInt16, presentationID: UInt64, state: TextPresentationState)
    /// Physical fit observed for the exact retained prompt TextPresentation.
    case agentPromptFit(windowID: UInt16, generation: UInt64, columns: UInt16, maxRows: UInt16)
    /// Wrapped viewport movement; positive rows scroll down.
    case agentPromptScroll(windowID: UInt16, generation: UInt64, deltaRows: Int32)
    case scrollBatch(windowID: UInt16, deltaLines: Int16, direction: UInt8)
    /// Signed viewport movement; the BEAM echoes the positive input sequence for this pane.
    case horizontalPan(windowID: UInt16, deltaColumns: Int16, inputSeq: UInt32)
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
    /// The result rows the picker list of one picker generation shows. The BEAM pages the picker by `rows`.
    case pickerFit(generation: UInt32, rows: UInt16)
    case fileTreeEditConfirm(token: UInt32, text: String)
    case fileTreeEditCancel
    case fileTreeDrop(sourcePaths: [String], targetIndex: UInt16, targetID: String, targetPathHash: UInt32, targetPath: String, targetIsDirectory: Bool, modifiers: UInt8, generation: UInt32)
    case fileTreeCollapseAll
    case fileTreeRefresh
    case semanticItemActivate(surface: SemanticItemSurface, intent: UInt8, generation: UInt32, itemID: Data)
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
    case panelDismiss
    case panelResize(heightPercent: UInt8)
    /// Resolves only the immutable approval displayed by the originating control.
    case agentToolApproval(sessionId: String, requestId: String, toolCallId: String, decision: AgentApprovalDecision)
    case agentToolToggle(messageID: UInt32)
    case agentReadRetainedOutput(messageID: UInt32, offer: Wire.RetainedOutputOffer)
    case agentComposerSubmit(generation: UInt64, offer: UInt64)
    case agentComposerQueue(generation: UInt64, offer: UInt64, followUp: Bool, target: AgentQueueTarget)
    case agentOpenQuestion(offer: UInt64)
    case agentStopTurn(AgentStopTarget)
    /// Runs the remedy the displayed failed Agent start offers; the BEAM ignores it once the tab no longer offers it.
    case agentStartRemedy(AgentStartRemedy.Kind)
    case executeCommand(name: String)
    case openFile(path: String)
    case gitStageFile(GitStatusEntryTarget)
    case gitUnstageFile(GitStatusEntryTarget)
    case gitDiscardFile(GitStatusEntryTarget)
    case gitStageAll(panelID: UInt64)
    case gitUnstageAll(panelID: UInt64)
    case gitCommit(panelID: UInt64, message: String)
    case gitOpenFile(GitStatusEntryTarget)
    case gitOpenDiff(GitStatusEntryTarget)
    case gitPush(panelID: UInt64)
    case gitPull(panelID: UInt64)
    case gitFetch(panelID: UInt64)
    case gitCommitAmend(panelID: UInt64, message: String)
    case gitPullAndRetry(toastID: UInt64)
    case workspaceRename(id: UInt16, name: String)
    case workspaceSetIcon(id: UInt16, icon: String)
    case workspaceClose(id: UInt16)
    case spaceLeaderChord(codepoint: UInt32, modifiers: UInt8)
    /// Presses a which-key row's key while the panel on `path` is still open.
    case whichKeyPress(path: String, codepoint: UInt32, modifiers: UInt8)
    /// Goes back up the which-key breadcrumb to the crumb on `path`.
    case whichKeyBack(path: String)
    case spaceLeaderRetract(codepoint: UInt32, modifiers: UInt8)
    case findPasteboardSearch(text: String, direction: UInt8)
    case agentApprove
    case agentRequestChanges
    case agentDismiss
    case chatScrolledAwayFromBottom
    case chatReturnedToBottom
    case scrollToLine(windowID: UInt16, generation: UInt64, line: UInt32)
    case scrollToVisualRank(windowID: UInt16, presentationID: UInt64, rank: UInt32)
    case foldToggleAtLine(windowID: UInt16, generation: UInt64, bufferLine: UInt32)
    case focusWindow(windowID: UInt16, generation: UInt64)
    case configQuery
    case configUpdate(key: String, value: SettingValue)
    case notificationDismiss(id: String)
    case notificationAction(id: String, actionID: String)
    case observatoryInspect(pid: String)
    case fontSizeAdjust(direction: UInt8)
    case searchFocus(replaceMode: Bool)
    case searchQuery(sessionID: UInt32, editSequence: UInt32, query: String, flags: UInt8)
    case searchNext
    case searchPrevious
    case searchReplace(replacement: String)
    case searchReplaceAll(replacement: String)
    case searchDismiss
}

/// A reason an outbound action was not admitted to the ordered transport.
nonisolated public enum OutboundActionRejection: Equatable, Sendable {
    case disconnected
    case payloadTooLarge(limitBytes: Int, attemptedBytes: Int)
    case collectionTooLarge(limitCount: Int, attemptedCount: Int)
    case capacityExhausted(limitBytes: Int, attemptedBytes: Int)
    case invalidPayload(String)
}

/// The synchronous admission outcome for one outbound action.
nonisolated public enum OutboundActionResult: Equatable, Sendable {
    case accepted
    case rejected(OutboundActionRejection)

    public var wasAccepted: Bool {
        self == .accepted
    }
}

/// The raw-input and app-composition boundary for outbound actions.
nonisolated public protocol OutboundActionEncoding: AnyObject, Sendable {
    @discardableResult
    func send(_ action: OutboundAction) -> OutboundActionResult
}

/// An explicit closure-backed boundary for previews, tests, and disconnected state.
nonisolated public final class ClosureOutboundActionEncoder: OutboundActionEncoding, Sendable {
    private let handler: @Sendable (OutboundAction) -> OutboundActionResult

    public init(handler: @escaping @Sendable (OutboundAction) -> OutboundActionResult) {
        self.handler = handler
    }

    @discardableResult
    public func send(_ action: OutboundAction) -> OutboundActionResult {
        handler(action)
    }
}
