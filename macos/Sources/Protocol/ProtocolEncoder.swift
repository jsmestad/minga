/// Encodes input events from the GUI to the BEAM via stdout.
///
/// All events are length-prefixed with a 4-byte big-endian header
/// (`{:packet, 4}` framing). The encoder enqueues frames on a serial
/// write queue and drains stdout asynchronously so UI threads never block
/// behind pipe backpressure.

import Darwin
import Foundation
import os
import MingaProtocol
import MingaUI

/// Thread-safe encoder that writes `{:packet, 4}` framed events to stdout.
///
/// Uses POSIX `write()` instead of `FileHandle.write()` to avoid
/// `NSFileHandleOperationException` (ObjC exception) on broken pipes.
/// ObjC exceptions cannot be caught from Swift, so `FileHandle.write()`
/// to a dead pipe zombifies the app (beachball). POSIX `write()` returns
/// -1 with `errno = EPIPE`, which becomes one terminal transport failure.
enum OutboundTransportFailure: Equatable, Sendable {
    case capacityExhausted(limit: Int, attemptedFrameBytes: Int)
    case frameTooLarge(limit: Int, payloadBytes: Int)
    case peerDisconnected
    case writeFailed(errorCode: Int32)

    var userFacingMessage: String {
        switch self {
        case .capacityExhausted(let limit, let attemptedFrameBytes):
            let cause = "The \(attemptedFrameBytes)-byte frame did not fit in the configured \(limit)-byte queue."
            return "Minga stopped accepting input. " + cause + " Restart the editor core before continuing."
        case .frameTooLarge(let limit, let payloadBytes):
            let cause = "The \(payloadBytes)-byte outbound payload exceeded the \(limit)-byte protocol limit."
            return "Minga stopped accepting input. " + cause + " Restart the editor core before continuing."
        case .peerDisconnected:
            return "The editor connection closed unexpectedly."
        case .writeFailed(let errorCode):
            let detail = "Minga lost its connection to the editor core while sending an outbound frame "
                + "(write error \(errorCode))."
            return detail + " Restart the editor core before continuing."
        }
    }
}

struct OutboundTransportFailureReport: Equatable, Sendable {
    let failure: OutboundTransportFailure
    let undeliveredDurableFrameCount: Int
    let undeliveredDurableByteCount: Int

    var userFacingMessage: String {
        guard undeliveredDurableFrameCount > 0 else { return failure.userFacingMessage }
        let summary = "Undelivered accepted input: \(undeliveredDurableFrameCount) durable frames, "
            + "\(undeliveredDurableByteCount) bytes."
        return failure.userFacingMessage + " " + summary
    }
}

/// An input action rejected before transport admission; the connection remains usable.
enum OutboundInputRejection: Equatable, Sendable {
    case pasteTooLarge(limitBytes: Int, attemptedBytes: Int)

    var userFacingMessage: String {
        switch self {
        case .pasteTooLarge(let limitBytes, let attemptedBytes):
            return "Minga did not insert the clipboard text. Its UTF-8 encoding is \(attemptedBytes) bytes; the current limit is \(limitBytes) bytes."
        }
    }
}

enum OutboundTransportInitializationError: Error, Equatable {
    case nonBlockingSetupFailed(errorCode: Int32)

    var userFacingMessage: String {
        switch self {
        case .nonBlockingSetupFailed(let errorCode):
            return "Minga could not configure nonblocking input transport (error \(errorCode))."
        }
    }
}

final class ProtocolEncoder: InputEncoder, @unchecked Sendable {
    enum DisconnectReason: Sendable {
        case expectedTeardown
        case unexpectedPeerClosure
    }

    private enum CoalescingClass: Equatable, Sendable {
        case viewportResize
        case nativePresentationObservation
    }

    private enum DeliveryPolicy: Equatable, Sendable {
        case durable
        case coalescing(CoalescingClass)
    }

    private struct QueuedFrame: Sendable {
        let bytes: Data
        let deliveryPolicy: DeliveryPolicy
        var writeOffset: Int = 0

        var remainingByteCount: Int { bytes.count - writeOffset }
    }

    typealias WriteOperation = @Sendable (Int32, UnsafeRawPointer, Int) -> Int
    typealias NonBlockingSetupOperation = @Sendable (Int32) -> Int32?

    private let fd: Int32
    private let writeQueue = DispatchQueue(label: "minga.encoder.write", qos: .userInteractive)
    private let writeQueueKey = DispatchSpecificKey<Void>()
    private let maxBufferSize: Int
    private let maximumPayloadSize: Int
    private let retryDelay: DispatchTimeInterval?
    private let writeOperation: WriteOperation
    private let onTransportFailure: @MainActor @Sendable (OutboundTransportFailureReport) -> Void
    private let onInputRejection: @MainActor @Sendable (OutboundInputRejection) -> Void
    private let maximumWriteCallsPerDrainPass = 32

    /// All mutable transport state is confined to `writeQueue`.
    private var connected: Bool = true
    private var queuedFrames: [QueuedFrame] = []
    private var firstQueuedFrameIndex: Int = 0
    private var bufferSize: Int = 0
    private var drainPassScheduled: Bool = false
    private var drainRetryScheduled: Bool = false
    private var terminalFailureReported: Bool = false

    /// Creates an encoder. Defaults to stdout for production use.
    /// Pass a pipe's write handle for testing binary layout.
    init(
        output: FileHandle = .standardOutput,
        maxBufferSize: Int = Int(RESOURCE_MAX_FRAME_BYTES) + 4,
        maximumPayloadSize: Int = Int(RESOURCE_MAX_FRAME_BYTES),
        retryDelay: DispatchTimeInterval? = .milliseconds(10),
        nonBlockingSetupOperation: @escaping NonBlockingSetupOperation = ProtocolEncoder.configureNonBlocking,
        writeOperation: @escaping WriteOperation = { fileDescriptor, pointer, count in
            Darwin.write(fileDescriptor, pointer, count)
        },
        onTransportFailure: @escaping @MainActor @Sendable (OutboundTransportFailureReport) -> Void = { _ in },
        onInputRejection: @escaping @MainActor @Sendable (OutboundInputRejection) -> Void = { _ in }
    ) throws {
        if let errorCode = nonBlockingSetupOperation(output.fileDescriptor) {
            throw OutboundTransportInitializationError.nonBlockingSetupFailed(errorCode: errorCode)
        }
        self.fd = output.fileDescriptor
        self.maxBufferSize = maxBufferSize
        self.maximumPayloadSize = maximumPayloadSize
        self.retryDelay = retryDelay
        self.writeOperation = writeOperation
        self.onTransportFailure = onTransportFailure
        self.onInputRejection = onInputRejection
        writeQueue.setSpecific(key: writeQueueKey, value: ())
    }

    /// Mark the encoder as disconnected. Called by the reader's
    /// `onDisconnect` callback so writes stop immediately without
    /// waiting for the next EPIPE.
    func disconnect(reason: DisconnectReason) {
        writeQueue.async { [weak self] in
            guard let self, self.connected else { return }
            switch reason {
            case .expectedTeardown:
                self.connected = false
                self.clearQueue()
            case .unexpectedPeerClosure:
                self.failTransport(.peerDisconnected)
            }
        }
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
            return bufferedData()
        }
        return writeQueue.sync { bufferedData() }
    }

    /// Snapshot of the partially written head offset for unit tests.
    var headWriteOffsetForTesting: Int? {
        if DispatchQueue.getSpecific(key: writeQueueKey) != nil {
            return headWriteOffset()
        }
        return writeQueue.sync { headWriteOffset() }
    }

    /// Admits an arbitrary legal payload through the production framing path for boundary tests.
    func writePayloadForTesting(_ payload: Data) {
        writeFrame(payload)
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
            self?.drainBuffer(writeCallBudget: .max)
            semaphore.signal()
        }
        return semaphore.wait(timeout: .now() + timeout) == .success
    }

    /// Send the ready event with initial dimensions and capabilities.
    ///
    /// The macOS GUI renders every surface through the semantic protocol
    /// (`gui_window_content` and the `gui_*` chrome opcodes via
    /// `WindowContentRenderer`/`CommandDispatcher`), so it advertises
    /// `semantic_ui = true`. The BEAM uses this capability, not `frontend_type`,
    /// to select the semantic render/chrome path shared with the Go TUI.
    func sendReady(cols: UInt16, rows: UInt16) {
        var buf = Data(count: 29)
        buf[0] = OP_READY
        writeU16(&buf, 1, cols)
        writeU16(&buf, 3, rows)
        buf[5] = CAPS_VERSION
        buf[6] = 20 // original 7 fields plus capability-format-2 policy tail
        buf[7] = FRONTEND_NATIVE_GUI
        buf[8] = COLOR_RGB
        buf[9] = UNICODE_15
        buf[10] = IMAGE_NATIVE
        buf[11] = FLOAT_NATIVE
        buf[12] = TEXT_PROPORTIONAL
        buf[13] = SEMANTIC_UI_ENABLED
        buf[14] = RESOURCE_POLICY_VERSION
        writeU32(&buf, 15, RESOURCE_MAX_FRAME_BYTES)
        writeU32(&buf, 19, RESOURCE_MAX_FRAME_COMMANDS)
        writeU32(&buf, 23, RESOURCE_MAX_WINDOW_ROWS)
        // protocol_version (u16): the wire contract this frontend was generated
        // against. The BEAM rejects a mismatch with an explicit protocol_error.
        writeU16(&buf, 27, PROTOCOL_VERSION)
        writeFrame(buf)
    }

    /// Send a key press event without a latency correlation sequence.
    func sendKeyPress(codepoint: UInt32, modifiers: UInt8) {
        sendKeyPress(codepoint: codepoint, modifiers: modifiers, seq: 0)
    }

    /// Send a key press event carrying a u32 latency correlation sequence
    /// (ticket #2215) appended after the modifiers byte.
    func sendKeyPress(codepoint: UInt32, modifiers: UInt8, seq: UInt32) {
        var buf = Data(count: 10)
        buf[0] = OP_KEY_PRESS
        writeU32(&buf, 1, codepoint)
        buf[5] = modifiers
        writeU32(&buf, 6, seq)
        os_signpost(.event, log: inputLog, name: "InputSent", "seq=%{public}u codepoint=%{public}u modifiers=%{public}u", seq, codepoint, modifiers)
        writeFrame(buf)
    }

    /// Send a resize event (dimensions in cells).
    func sendResize(cols: UInt16, rows: UInt16) {
        var buf = Data(count: 5)
        buf[0] = OP_RESIZE
        writeU16(&buf, 1, cols)
        writeU16(&buf, 3, rows)
        writeFrame(buf, deliveryPolicy: .coalescing(.viewportResize))
    }

    /// Request a fresh BEAM recovery generation.
    func sendRequestKeyframe(lastGoodFrameSeq: UInt32, generation: UInt32) {
        var buf = Data(count: 9)
        buf[0] = OP_REQUEST_KEYFRAME
        writeU32(&buf, 1, lastGoodFrameSeq)
        writeU32(&buf, 5, generation)
        writeFrame(buf)
    }

    /// Report semantic publication, deliberately independent of Metal presentation.
    func sendFrameApplied(generation: UInt32, frameSeq: UInt32) {
        var buf = Data(count: 9)
        buf[0] = OP_FRAME_APPLIED
        writeU32(&buf, 1, generation)
        writeU32(&buf, 5, frameSeq)
        writeFrame(buf)
    }

    func sendOperationNativeResult(_ result: NativeOperationResult) {
        var buf = Data(count: 57)
        buf[0] = OP_OPERATION_NATIVE_RESULT
        writeU64(&buf, 1, result.operationID)
        writeU64(&buf, 9, result.targetToken)
        writeU32(&buf, 17, result.evidence.generation)
        writeU32(&buf, 21, result.evidence.frameSeq)
        writeU16(&buf, 25, result.evidence.windowID)
        buf[27] = result.outcome.rawValue
        buf[28] = result.evidence.focusReady ? 1 : 0
        buf[29] = result.evidence.boundary.rawValue
        writeU32(&buf, 30, result.evidence.applicationRevision)
        if let lastVisible = result.lastVisible {
            writeU64(&buf, 34, lastVisible.targetToken)
            writeU32(&buf, 42, lastVisible.generation)
            writeU32(&buf, 46, lastVisible.frameSeq)
            writeU16(&buf, 50, lastVisible.windowID)
            buf[52] = lastVisible.focusReady ? 1 : 0
            writeU32(&buf, 53, lastVisible.applicationRevision)
        }
        writeFrame(buf)
    }

    func sendNativePresentationObservation(_ evidence: NativePresentationEvidence) {
        var buf = Data(count: 24)
        buf[0] = OP_NATIVE_PRESENTATION_OBSERVATION
        writeU64(&buf, 1, evidence.targetToken)
        writeU32(&buf, 9, evidence.applicationRevision)
        writeU32(&buf, 13, evidence.generation)
        writeU32(&buf, 17, evidence.frameSeq)
        writeU16(&buf, 21, evidence.windowID)
        buf[23] = evidence.focusReady ? 1 : 0
        writeFrame(buf, deliveryPolicy: .coalescing(.nativePresentationObservation))
    }

    func sendFrameRejected(
        generation: UInt32,
        frameSeq: UInt32,
        lastAppliedFrameSeq: UInt32,
        reason: UInt8
    ) {
        let generatedReason = GeneratedProtocol.FrameRejectionReason.decode(reason)
        let disposition: GeneratedProtocol.FrameRejectionDisposition =
            generatedReason == .resourcePolicy ? .terminalFrontendFailure : .retryableRecovery
        sendFrameRejected(
            generation: generation,
            frameSeq: frameSeq,
            lastAppliedFrameSeq: lastAppliedFrameSeq,
            reason: reason,
            disposition: disposition
        )
    }

    func sendFrameRejected(
        generation: UInt32,
        frameSeq: UInt32,
        lastAppliedFrameSeq: UInt32,
        reason: UInt8,
        disposition: GeneratedProtocol.FrameRejectionDisposition
    ) {
        var buf = Data(count: 15)
        buf[0] = OP_FRAME_REJECTED
        writeU32(&buf, 1, generation)
        writeU32(&buf, 5, frameSeq)
        writeU32(&buf, 9, lastAppliedFrameSeq)
        buf[13] = reason
        buf[14] = disposition.rawValue
        writeFrame(buf)
    }

    func sendWindowRefMiss(generation: UInt32, frameSeq: UInt32, lastAppliedFrameSeq: UInt32, windowId: UInt16) {
        var buf = Data(count: 15)
        buf[0] = OP_WINDOW_REF_MISS
        writeU32(&buf, 1, generation)
        writeU32(&buf, 5, frameSeq)
        writeU32(&buf, 9, lastAppliedFrameSeq)
        writeU16(&buf, 13, windowId)
        writeFrame(buf)
    }

    /// Begin one correlated native application-quit attempt on the ordered input channel.
    @discardableResult
    func sendApplicationQuitRequest(requestID: UInt32) -> Bool {
        var buf = Data(count: 5)
        buf[0] = OP_APPLICATION_QUIT_REQUEST
        writeU32(&buf, 1, requestID)
        return writeCriticalFrame(buf)
    }

    /// Send Save, Discard, or Cancel for the matching native application-quit attempt.
    @discardableResult
    func sendApplicationQuitDecision(requestID: UInt32, decision: UInt8) -> Bool {
        var buf = Data(count: 6)
        buf[0] = OP_APPLICATION_QUIT_DECISION
        writeU32(&buf, 1, requestID)
        buf[5] = decision
        return writeCriticalFrame(buf)
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

    func sendScrollBatch(windowId: UInt16, deltaLines: Int16, direction: UInt8) {
        var buf = Data(count: 6)
        buf[0] = OP_SCROLL_BATCH
        writeU16(&buf, 1, windowId)
        writeI16(&buf, 3, deltaLines)
        buf[5] = direction
        writeFrame(buf)
    }

    /// Send a paste event to the BEAM containing the full pasted text.
    /// Layout: opcode(1) + text_len(2, big-endian) + text(text_len).
    /// Text is UTF-8 encoded. Maximum length is 65535 bytes (UInt16.max).
    /// Oversized input is rejected in full without changing transport state.
    func sendPasteEvent(text: String) {
        let textLen = text.utf8.count
        guard textLen <= Int(UInt16.max) else {
            let onInputRejection = self.onInputRejection
            Task { @MainActor in
                onInputRejection(.pasteTooLarge(limitBytes: Int(UInt16.max), attemptedBytes: textLen))
            }
            return
        }
        var buf = Data(count: 3 + textLen)
        buf[0] = OP_PASTE_EVENT
        writeU16(&buf, 1, UInt16(textLen))
        if textLen > 0 {
            buf.replaceSubrange(3..<(3 + textLen), with: text.utf8)
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

    /// Send a gui_action: empty_state_activate. Layout: opcode(1) + action_type(1) + id_len(1) + id(id_len).
    ///
    /// Activates a launchpad row (resume card, recent file, or action) by its
    /// semantic id. Activation is authoritative on the BEAM; the frontend only
    /// forwards the click.
    func sendEmptyStateActivate(id: String) {
        let utf8 = Array(id.utf8)
        let idLen = min(utf8.count, Int(UInt8.max))
        var buf = Data(count: 3 + idLen)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_EMPTY_STATE_ACTIVATE
        buf[2] = UInt8(idLen)
        if idLen > 0 {
            buf.replaceSubrange(3..<(3 + idLen), with: utf8[0..<idLen])
        }
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

    /// Send a gui_action: tab_reorder. Layout: opcode(1) + action_type(1) + tab_id(4) + new_index(2).
    func sendTabReorder(id: UInt32, newIndex: UInt16) {
        var buf = Data(count: 8)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_TAB_REORDER
        writeU32(&buf, 2, id)
        writeU16(&buf, 6, newIndex)
        writeFrame(buf)
    }

    /// Send a gui_action: tab_pin. Layout: opcode(1) + action_type(1) + tab_id(4).
    func sendTabPin(id: UInt32) {
        sendTabIdAction(actionType: GUI_ACTION_TAB_PIN, id: id)
    }

    /// Send a gui_action: tab_unpin. Layout: opcode(1) + action_type(1) + tab_id(4).
    func sendTabUnpin(id: UInt32) {
        sendTabIdAction(actionType: GUI_ACTION_TAB_UNPIN, id: id)
    }

    /// Send a gui_action: tab_move_left. Layout: opcode(1) + action_type(1) + tab_id(4).
    func sendTabMoveLeft(id: UInt32) {
        sendTabIdAction(actionType: GUI_ACTION_TAB_MOVE_LEFT, id: id)
    }

    /// Send a gui_action: tab_move_right. Layout: opcode(1) + action_type(1) + tab_id(4).
    func sendTabMoveRight(id: UInt32) {
        sendTabIdAction(actionType: GUI_ACTION_TAB_MOVE_RIGHT, id: id)
    }

    private func sendTabIdAction(actionType: UInt8, id: UInt32) {
        var buf = Data(count: 6)
        buf[0] = OP_GUI_ACTION
        buf[1] = actionType
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

    /// Send a gui_action: picker_query_changed with native edit correlation and complete UTF-8 text.
    func sendPickerQueryChanged(generation: UInt32, editSeq: UInt32, text: String) {
        var buf = Data([OP_GUI_ACTION, GUI_ACTION_PICKER_QUERY_CHANGED])
        appendU32(&buf, generation)
        appendU32(&buf, editSeq)
        appendString16(&buf, text)
        writeFrame(buf)
    }

    func sendPickerItemActivate(generation: UInt32, activationID: UInt32) {
        var buf = Data([OP_GUI_ACTION, GUI_ACTION_PICKER_ITEM_ACTIVATE])
        appendU32(&buf, generation)
        appendU32(&buf, activationID)
        writeFrame(buf)
    }

    func sendPickerActionActivate(generation: UInt32, activationID: UInt32) {
        var buf = Data([OP_GUI_ACTION, GUI_ACTION_PICKER_ACTION_ACTIVATE])
        appendU32(&buf, generation)
        appendU32(&buf, activationID)
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

    /// Send a gui_action: file_tree_edit_confirm. Layout: opcode(1) + action_type(1) + edit_token(4) + text_len(2) + text(N).
    func sendFileTreeEditConfirm(token: UInt32, text: String) {
        let textData = text.data(using: .utf8) ?? Data()
        var buf = Data(count: 8 + textData.count)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_FILE_TREE_EDIT_CONFIRM
        writeU32(&buf, 2, token)
        buf[6] = UInt8(textData.count >> 8)
        buf[7] = UInt8(textData.count & 0xFF)
        buf.replaceSubrange(8..<(8 + textData.count), with: textData)
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

    /// Send a gui_action: file_tree_drop. Layout: opcode(1) + action_type(1) + target_index(2) + target_hash(4) + target_kind(1) + modifiers(1) + target_id + target_path + sources.
    func sendFileTreeDrop(sourcePaths: [String], targetIndex: UInt16, targetId: String, targetPathHash: UInt32, targetPath: String, targetIsDir: Bool, modifiers: UInt8) {
        if let error = fileTreeDropPayloadError(sourcePaths: sourcePaths, targetId: targetId, targetPath: targetPath) {
            sendLog(level: LOG_LEVEL_WARN, message: error)
            return
        }

        var buf = Data()
        buf.append(OP_GUI_ACTION)
        buf.append(GUI_ACTION_FILE_TREE_DROP)
        appendU16(&buf, targetIndex)
        appendU32(&buf, targetPathHash)
        buf.append(targetIsDir ? 1 : 0)
        buf.append(modifiers)
        appendString16(&buf, targetId)
        appendString16(&buf, targetPath)
        appendU16(&buf, UInt16(min(sourcePaths.count, Int(UInt16.max))))

        for path in sourcePaths.prefix(Int(UInt16.max)) {
            appendString16(&buf, path)
        }

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


    /// Send a gui_action: toggle_panel. Layout: opcode(1) + action_type(1) + panel(1).
    func sendTogglePanel(panel: UInt8) {
        var buf = Data(count: 3)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_TOGGLE_PANEL
        buf[2] = panel
        writeFrame(buf)
    }

    /// Send a gui_action: sidebar_action. Layout: opcode(1) + action_type(1) + id + kind + action.
    func sendSidebarAction(sidebarId: String, kind: String, action: String) {
        var buf = Data([OP_GUI_ACTION, GUI_ACTION_SIDEBAR_ACTION])
        appendString16(&buf, sidebarId)
        appendString16(&buf, kind)
        appendString16(&buf, action)
        writeFrame(buf)
    }

    /// Send a gui_action: extension_action. Layout: opcode(1) + action_type(1) + extension_id + action + opaque payload.
    func sendExtensionAction(extensionID: String, action: String, payload: Data) {
        var buf = Data([OP_GUI_ACTION, GUI_ACTION_EXTENSION_ACTION])
        appendString16(&buf, extensionID)
        appendString16(&buf, action)
        buf.append(payload)
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

    /// Send a gui_action: system_will_unmount.
    /// Layout: opcode(1) + action_type(1) + path_len(2) + path(path_len).
    func sendSystemWillUnmount(volumePath: String) {
        var buf = Data()
        buf.append(OP_GUI_ACTION)
        buf.append(GUI_ACTION_SYSTEM_WILL_UNMOUNT)
        appendString16(&buf, volumePath)
        writeFrame(buf)
    }

    /// Send a gui_action: power_thermal_state. Layout: opcode(1) + action_type(1) + low_power(1) + thermal_state(1).
    func sendPowerThermalState(lowPowerMode: Bool, thermalState: UInt8) {
        var buf = Data(count: 4)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_POWER_THERMAL_STATE
        buf[2] = lowPowerMode ? 1 : 0
        buf[3] = thermalState
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


    /// Send a gui_action: agent_tool_toggle. Layout: opcode(1) + action_type(1) + message_id(4).
    func sendAgentToolToggle(messageID: UInt32) {
        var buf = Data(count: 6)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_AGENT_TOOL_TOGGLE
        writeU32(&buf, 2, messageID)
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
        sendGitCommit(message: message, amend: false)
    }

    private func sendGitCommit(message: String, amend: Bool) {
        let utf8 = Array(message.utf8)
        let msgLen = min(utf8.count, Int(UInt16.max))
        var buf = Data(count: 5 + msgLen)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_GIT_COMMIT
        buf[2] = amend ? 1 : 0
        writeU16(&buf, 3, UInt16(msgLen))
        if msgLen > 0 {
            buf.replaceSubrange(5..<(5 + msgLen), with: utf8[0..<msgLen])
        }
        writeFrame(buf)
    }

    func sendGitOpenFile(path: String) {
        sendGitPathAction(GUI_ACTION_GIT_OPEN_FILE, path: path)
    }

    func sendGitOpenDiff(path: String, section: UInt8) {
        let utf8 = Array(path.utf8)
        let pathLen = min(utf8.count, Int(UInt16.max))
        var buf = Data(count: 5 + pathLen)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_GIT_OPEN_DIFF
        writeU16(&buf, 2, UInt16(pathLen))
        if pathLen > 0 {
            buf.replaceSubrange(4..<(4 + pathLen), with: utf8[0..<pathLen])
        }
        buf[4 + pathLen] = section
        writeFrame(buf)
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
        sendGitCommit(message: message, amend: true)
    }

    /// Send a gui_action: git_pull_and_retry. Layout: opcode(1) + action_type(1).
    func sendGitPullAndRetry() {
        var buf = Data(count: 2)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_GIT_PULL_AND_RETRY
        writeFrame(buf)
    }

    func sendWorkspaceRename(id: UInt16, name: String) {
        let utf8 = Array(name.utf8)
        let nameLen = min(utf8.count, Int(UInt16.max))
        var buf = Data(count: 6 + nameLen)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_WORKSPACE_RENAME
        writeU16(&buf, 2, id)
        writeU16(&buf, 4, UInt16(nameLen))
        if nameLen > 0 {
            buf.replaceSubrange(6..<(6 + nameLen), with: utf8[0..<nameLen])
        }
        writeFrame(buf)
    }

    func sendWorkspaceSetIcon(id: UInt16, icon: String) {
        let utf8 = Array(icon.utf8)
        let iconLen = min(utf8.count, 255)
        var buf = Data(count: 5 + iconLen)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_WORKSPACE_SET_ICON
        writeU16(&buf, 2, id)
        buf[4] = UInt8(iconLen)
        if iconLen > 0 {
            buf.replaceSubrange(5..<(5 + iconLen), with: utf8[0..<iconLen])
        }
        writeFrame(buf)
    }

    func sendWorkspaceClose(id: UInt16) {
        var buf = Data(count: 4)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_WORKSPACE_CLOSE
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

    /// Send a gui_action: chat_scrolled_away_from_bottom. Layout: opcode(1) + action_type(1).
    /// Reports that the reader scrolled away from the transcript bottom (#2654),
    /// pausing BEAM-side auto-follow.
    func sendChatScrolledAwayFromBottom() {
        var buf = Data(count: 2)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_CHAT_SCROLLED_AWAY_FROM_BOTTOM
        writeFrame(buf)
    }

    /// Send a gui_action: chat_returned_to_bottom. Layout: opcode(1) + action_type(1).
    /// Reports that the reader returned to the transcript bottom (#2654),
    /// re-pinning BEAM-side auto-follow.
    func sendChatReturnedToBottom() {
        var buf = Data(count: 2)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_CHAT_RETURNED_TO_BOTTOM
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

    /// Send a gui_action: fold_toggle_at_line. Layout: opcode(1) + action_type(1) + window_id(2) + buffer_line(4).
    func sendFoldToggleAtLine(windowId: UInt16, bufferLine: UInt32) {
        var buf = Data(count: 8)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_FOLD_TOGGLE_AT_LINE
        writeU16(&buf, 2, windowId)
        writeU32(&buf, 4, bufferLine)
        writeFrame(buf)
    }

    /// Send a gui_action: config_query. Layout: opcode(1) + action_type(1).
    func sendConfigQuery() {
        var buf = Data(count: 2)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_CONFIG_QUERY
        writeFrame(buf)
    }

    /// Send a gui_action: config_update. Layout: opcode(1) + action_type(1) + key_len(1) + key + value.
    func sendConfigUpdate(key: String, value: SettingValue) {
        let keyBytes = Array(key.utf8.prefix(Int(UInt8.max)))
        var buf = Data()
        buf.append(OP_GUI_ACTION)
        buf.append(GUI_ACTION_CONFIG_UPDATE)
        buf.append(UInt8(keyBytes.count))
        buf.append(contentsOf: keyBytes)
        appendSettingValue(value, to: &buf)
        writeFrame(buf)
    }

    /// Send a gui_action: notification_dismiss. Layout: opcode(1) + action_type(1) + id_len(2) + id.
    func sendNotificationDismiss(id: String) {
        var buf = Data()
        buf.append(OP_GUI_ACTION)
        buf.append(GUI_ACTION_NOTIFICATION_DISMISS)
        appendString16(&buf, id)
        writeFrame(buf)
    }

    /// Send a gui_action: notification_action. Layout: opcode(1) + action_type(1) + id_len(2) + id + action_len(2) + action_id.
    func sendNotificationAction(id: String, actionId: String) {
        var buf = Data()
        buf.append(OP_GUI_ACTION)
        buf.append(GUI_ACTION_NOTIFICATION_ACTION)
        appendString16(&buf, id)
        appendString16(&buf, actionId)
        writeFrame(buf)
    }

    /// Send a gui_action: observatory_inspect. Layout: opcode(1) + action_type(1) + pid_len(2) + pid.
    func sendObservatoryInspect(pid: String) {
        var buf = Data()
        buf.append(OP_GUI_ACTION)
        buf.append(GUI_ACTION_OBSERVATORY_INSPECT)
        appendString16(&buf, pid)
        writeFrame(buf)
    }

    /// Send a gui_action: font_size_adjust. Layout: opcode(1) + action_type(1) + direction(1).
    /// Direction: 0x00 = decrease, 0x01 = increase, 0x02 = reset.
    func sendFontSizeAdjust(direction: UInt8) {
        var buf = Data(count: 3)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_FONT_SIZE_ADJUST
        buf[2] = direction
        writeFrame(buf)
    }

    /// Send a gui_action: timeline_navigate. Layout: opcode(1) + action_type(1) + index(2).
    func sendTimelineNavigate(index: UInt16) {
        var buf = Data(count: 4)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_TIMELINE_NAVIGATE
        writeU16(&buf, 2, index)
        writeFrame(buf)
    }

    // MARK: - Search Toolbar Actions

    /// Send a gui_action: search_query. Layout: opcode(1) + action_type(1) + query_len(2) + query + flags(1).
    func sendSearchQuery(query: String, flags: UInt8) {
        let utf8 = Array(query.utf8)
        let queryLen = min(utf8.count, Int(UInt16.max))
        var buf = Data(count: 4 + queryLen + 1)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_SEARCH_QUERY
        writeU16(&buf, 2, UInt16(queryLen))
        if queryLen > 0 {
            buf.replaceSubrange(4..<(4 + queryLen), with: utf8[0..<queryLen])
        }
        buf[4 + queryLen] = flags
        writeFrame(buf)
    }

    /// Send a gui_action: search_next. Layout: opcode(1) + action_type(1).
    func sendSearchNext() {
        var buf = Data(count: 2)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_SEARCH_NEXT
        writeFrame(buf)
    }

    /// Send a gui_action: search_prev. Layout: opcode(1) + action_type(1).
    func sendSearchPrev() {
        var buf = Data(count: 2)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_SEARCH_PREV
        writeFrame(buf)
    }

    /// Send a gui_action: search_replace. Layout: opcode(1) + action_type(1) + replacement_len(2) + replacement.
    func sendSearchReplace(replacement: String) {
        let utf8 = Array(replacement.utf8)
        let repLen = min(utf8.count, Int(UInt16.max))
        var buf = Data(count: 4 + repLen)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_SEARCH_REPLACE
        writeU16(&buf, 2, UInt16(repLen))
        if repLen > 0 {
            buf.replaceSubrange(4..<(4 + repLen), with: utf8[0..<repLen])
        }
        writeFrame(buf)
    }

    /// Send a gui_action: search_replace_all. Layout: opcode(1) + action_type(1) + replacement_len(2) + replacement.
    func sendSearchReplaceAll(replacement: String) {
        let utf8 = Array(replacement.utf8)
        let repLen = min(utf8.count, Int(UInt16.max))
        var buf = Data(count: 4 + repLen)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_SEARCH_REPLACE_ALL
        writeU16(&buf, 2, UInt16(repLen))
        if repLen > 0 {
            buf.replaceSubrange(4..<(4 + repLen), with: utf8[0..<repLen])
        }
        writeFrame(buf)
    }

    /// Send a gui_action: search_dismiss. Layout: opcode(1) + action_type(1).
    func sendSearchDismiss() {
        var buf = Data(count: 2)
        buf[0] = OP_GUI_ACTION
        buf[1] = GUI_ACTION_SEARCH_DISMISS
        writeFrame(buf)
    }

    private func appendSettingValue(_ value: SettingValue, to buf: inout Data) {
        switch value {
        case .bool(let enabled):
            buf.append(SETTING_VALUE_BOOL)
            buf.append(enabled ? 1 : 0)
        case .int(let number):
            buf.append(SETTING_VALUE_INT)
            appendI32(Int32(clamping: number), to: &buf)
        case .string(let text):
            buf.append(SETTING_VALUE_STRING)
            appendString16(&buf, text)
        case .atom(let text):
            buf.append(SETTING_VALUE_ATOM)
            appendString16(&buf, text)
        case .float(let number):
            buf.append(SETTING_VALUE_FLOAT)
            appendFloat64(number, to: &buf)
        }
    }

    private func appendI32(_ value: Int32, to buf: inout Data) {
        let unsigned = UInt32(bitPattern: value)
        buf.append(UInt8((unsigned >> 24) & 0xFF))
        buf.append(UInt8((unsigned >> 16) & 0xFF))
        buf.append(UInt8((unsigned >> 8) & 0xFF))
        buf.append(UInt8(unsigned & 0xFF))
    }

    private func appendFloat64(_ value: Double, to buf: inout Data) {
        let bits = value.bitPattern.bigEndian
        withUnsafeBytes(of: bits) { rawBuffer in
            buf.append(contentsOf: rawBuffer)
        }
    }

    // MARK: - Private

    /// Admit a length-prefixed frame before scheduling asynchronous POSIX `write()` work.
    ///
    /// `FileHandle.write()` raises an ObjC `NSFileHandleOperationException`
    /// on EPIPE that Swift cannot catch, zombifying the app. POSIX `write()`
    /// returns -1 and sets `errno = EPIPE`, which we handle by flipping
    /// `connected` to false. The file descriptor is non-blocking, so pipe
    /// backpressure returns EAGAIN instead of freezing the caller.
    private func writeFrame(_ payload: Data, deliveryPolicy: DeliveryPolicy = .durable) {
        withWriteQueue {
            guard admit(payload: payload, deliveryPolicy: deliveryPolicy) else { return }
            scheduleDrainPass()
        }
    }

    /// Admits a lifecycle frame only when this exact transport can retain it durably.
    ///
    /// The file descriptor is nonblocking, so this ordered queue hop cannot wait on pipe backpressure.
    /// A false result lets AppKit cancel termination instead of approving a quit that the BEAM never received.
    private func writeCriticalFrame(_ payload: Data) -> Bool {
        withWriteQueue {
            guard admit(payload: payload, deliveryPolicy: .durable) else { return false }
            scheduleDrainPass()
            return true
        }
    }

    private func withWriteQueue<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: writeQueueKey) != nil {
            return operation()
        }
        return writeQueue.sync(execute: operation)
    }

    private func admit(payload: Data, deliveryPolicy: DeliveryPolicy) -> Bool {
        guard connected else { return false }
        guard payload.count <= maximumPayloadSize else {
            failTransport(.frameTooLarge(limit: maximumPayloadSize, payloadBytes: payload.count))
            return false
        }

        let frame = QueuedFrame(bytes: makeFrame(payload), deliveryPolicy: deliveryPolicy)
        if replaceCoalescibleTail(with: frame) {
            return true
        }

        guard frame.bytes.count <= maxBufferSize,
              bufferSize <= maxBufferSize - frame.bytes.count else {
            failTransport(.capacityExhausted(limit: maxBufferSize, attemptedFrameBytes: frame.bytes.count))
            return false
        }

        queuedFrames.append(frame)
        bufferSize += frame.bytes.count
        return true
    }

    private func replaceCoalescibleTail(with frame: QueuedFrame) -> Bool {
        guard case .coalescing = frame.deliveryPolicy,
              firstQueuedFrameIndex < queuedFrames.count,
              let tail = queuedFrames.last,
              tail.writeOffset == 0,
              tail.deliveryPolicy == frame.deliveryPolicy else { return false }

        let replacementSize = bufferSize - tail.bytes.count + frame.bytes.count
        guard replacementSize <= maxBufferSize else { return false }

        queuedFrames[queuedFrames.count - 1] = frame
        bufferSize = replacementSize
        return true
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

    private func drainBuffer(writeCallBudget: Int) {
        guard connected else { return }

        var writeCalls = 0
        while firstQueuedFrameIndex < queuedFrames.count, writeCalls < writeCallBudget {
            let head = queuedFrames[firstQueuedFrameIndex]
            writeCalls += 1
            let written = head.bytes.withUnsafeBytes { buffer -> Int in
                guard let ptr = buffer.baseAddress else { return 0 }
                return writeOperation(fd, ptr.advanced(by: head.writeOffset), head.remainingByteCount)
            }

            if written > 0 {
                guard written <= head.remainingByteCount else {
                    failTransport(.writeFailed(errorCode: EIO))
                    return
                }

                let nextOffset = head.writeOffset + written
                if nextOffset == head.bytes.count {
                    firstQueuedFrameIndex += 1
                    bufferSize -= head.bytes.count
                    compactCompletedFramesIfNeeded()
                } else {
                    queuedFrames[firstQueuedFrameIndex].writeOffset = nextOffset
                }
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

            failTransport(.writeFailed(errorCode: Int32(error)))
            return
        }

        if firstQueuedFrameIndex < queuedFrames.count {
            scheduleDrainPass()
        }
    }

    private func scheduleDrainPass() {
        guard !drainPassScheduled, connected else { return }
        drainPassScheduled = true
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.drainPassScheduled = false
            self.drainBuffer(writeCallBudget: self.maximumWriteCallsPerDrainPass)
        }
    }

    private func scheduleDrainRetry() {
        guard let retryDelay, !drainRetryScheduled, connected else { return }
        drainRetryScheduled = true
        writeQueue.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
            guard let self else { return }
            self.drainRetryScheduled = false
            self.drainBuffer(writeCallBudget: self.maximumWriteCallsPerDrainPass)
        }
    }

    private func failTransport(_ failure: OutboundTransportFailure) {
        guard !terminalFailureReported else { return }
        let undeliveredFrames = queuedFrames[firstQueuedFrameIndex...]
            .filter { $0.deliveryPolicy == .durable }
        let report = OutboundTransportFailureReport(
            failure: failure,
            undeliveredDurableFrameCount: undeliveredFrames.count,
            undeliveredDurableByteCount: undeliveredFrames.reduce(0) { $0 + $1.remainingByteCount }
        )
        terminalFailureReported = true
        connected = false
        clearQueue()

        let callback = onTransportFailure
        Task { @MainActor in
            callback(report)
        }
    }

    private func bufferedData() -> Data {
        queuedFrames[firstQueuedFrameIndex...].reduce(into: Data()) { data, frame in
            data.append(frame.bytes.subdata(in: frame.writeOffset..<frame.bytes.count))
        }
    }

    private func headWriteOffset() -> Int? {
        guard firstQueuedFrameIndex < queuedFrames.count else { return nil }
        return queuedFrames[firstQueuedFrameIndex].writeOffset
    }

    private func compactCompletedFramesIfNeeded() {
        if firstQueuedFrameIndex == queuedFrames.count {
            queuedFrames.removeAll(keepingCapacity: true)
            firstQueuedFrameIndex = 0
            return
        }

        guard firstQueuedFrameIndex >= 64,
              firstQueuedFrameIndex * 2 >= queuedFrames.count else { return }
        queuedFrames.removeFirst(firstQueuedFrameIndex)
        firstQueuedFrameIndex = 0
    }

    private func clearQueue() {
        queuedFrames.removeAll(keepingCapacity: false)
        firstQueuedFrameIndex = 0
        bufferSize = 0
    }

    private static func configureNonBlocking(fileDescriptor: Int32) -> Int32? {
        let flags = fcntl(fileDescriptor, F_GETFL, 0)
        guard flags >= 0 else { return errno }
        guard fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else { return errno }
        return nil
    }

    private func fileTreeDropPayloadError(sourcePaths: [String], targetId: String, targetPath: String) -> String? {
        if sourcePaths.count > Int(UInt16.max) {
            return "File tree drop rejected: too many source paths for GUI protocol"
        }

        if !fitsString16(targetId) {
            return "File tree drop rejected: target identity exceeds GUI protocol limit"
        }

        if !fitsString16(targetPath) {
            return "File tree drop rejected: target path exceeds GUI protocol limit"
        }

        if sourcePaths.contains(where: { !fitsString16($0) }) {
            return "File tree drop rejected: source path exceeds GUI protocol limit"
        }

        return nil
    }

    private func fitsString16(_ text: String) -> Bool {
        text.utf8.count <= Int(UInt16.max)
    }

    private func appendU16(_ buf: inout Data, _ value: UInt16) {
        buf.append(UInt8((value >> 8) & 0xFF))
        buf.append(UInt8(value & 0xFF))
    }

    private func appendU32(_ buf: inout Data, _ value: UInt32) {
        buf.append(UInt8((value >> 24) & 0xFF))
        buf.append(UInt8((value >> 16) & 0xFF))
        buf.append(UInt8((value >> 8) & 0xFF))
        buf.append(UInt8(value & 0xFF))
    }

    private func appendString16(_ buf: inout Data, _ text: String) {
        let utf8 = Array(text.utf8)
        let length = min(utf8.count, Int(UInt16.max))
        appendU16(&buf, UInt16(length))
        if length > 0 {
            buf.append(contentsOf: utf8[0..<length])
        }
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

    private func writeU64(_ buf: inout Data, _ offset: Int, _ value: UInt64) {
        buf[offset] = UInt8((value >> 56) & 0xFF)
        buf[offset + 1] = UInt8((value >> 48) & 0xFF)
        buf[offset + 2] = UInt8((value >> 40) & 0xFF)
        buf[offset + 3] = UInt8((value >> 32) & 0xFF)
        buf[offset + 4] = UInt8((value >> 24) & 0xFF)
        buf[offset + 5] = UInt8((value >> 16) & 0xFF)
        buf[offset + 6] = UInt8((value >> 8) & 0xFF)
        buf[offset + 7] = UInt8(value & 0xFF)
    }

    private func writeI16(_ buf: inout Data, _ offset: Int, _ value: Int16) {
        writeU16(&buf, offset, UInt16(bitPattern: value))
    }
}
