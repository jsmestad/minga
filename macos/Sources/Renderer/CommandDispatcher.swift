/// Routes decoded protocol commands to FrameState and GUIState, triggering rendering.
///
/// Rendering is semantic-first: content flows through gui_window_content (0x80)
/// and the dedicated gui_* opcodes. The cell-paradigm commands (draw_text,
/// set_cursor, clear, region tracking) were retired in protocol_version 2.
///
/// ## Frame transactions (#2747)
///
/// Every BEAM frame is bracketed by `begin_frame` and `commit_frame`. Between
/// the two, commands compile into typed domain updates in a value-semantic
/// `PreparedFrameTransactionBuilder`; presented state remains untouched.
/// Window deltas and resource references resolve while staging. Commit validates
/// ordering and freezes the builder before entering one focused GUI publication
/// boundary, so an invalid frame cannot partially publish.
///
/// Rejection (truncation via double-begin, seq mismatch, base mismatch, or a
/// decode failure surfaced while a transaction is open) discards the builder
/// and requests a fresh keyframe via `onRequestKeyframe`. A subtle
/// resync-pending hint (`GUIState.resyncState`) is raised until the next clean
/// commit lands.

import MingaProtocol
import MingaUI
import Foundation
import AppKit
import os

private enum FileTreeNavigationCodepoints {
    static let downKey: UInt32 = 106
    static let upKey: UInt32 = 107
    static let downArrow: UInt32 = 57353
    static let upArrow: UInt32 = 57352
}

private enum PickerNavigationCodepoints {
    static let downKey: UInt32 = 106
    static let upKey: UInt32 = 107
    static let downArrow: UInt32 = 57353
    static let upArrow: UInt32 = 57352
}

private struct TerminalRejectionSignature: Equatable {
    let generation: UInt32
    let frameSeq: UInt32
    let lastGoodFrameSeq: UInt32
    let reason: UInt8
}

private enum CompletionNavigationCodepoints {
    static let ctrlN: UInt32 = 110
    static let ctrlP: UInt32 = 112
    static let downArrow: UInt32 = 57353
    static let upArrow: UInt32 = 57352
    static let ctrlModifier: UInt8 = 0x02
}

/// Dispatches render commands to FrameState (metadata) and GUIState (chrome).
@MainActor
final class CommandDispatcher {
    /// Per-frame metadata for the Metal render pass.
    var frameState: FrameState

    /// Font manager for per-span font family support.
    var fontManager: FontManager?

    /// Called after each `commit_frame` command promotes its staged transaction.
    /// The renderer hooks into this to trigger a GPU frame.
    var onFrameReady: (() -> Void)?

    /// Called after each `commit_frame` command so recovery logic knows the
    /// BEAM is still responding to input (formerly `onBatchEnd`, renamed for the
    /// frame-transaction model in #2219 child D).
    var onFramePresented: (() -> Void)?

    /// Called on any frame-transaction invalidation (#2219 child D). The
    /// parameter is `last_good_frame_seq`: the most recent frame_seq this
    /// dispatcher committed cleanly, or 0 if it has none. The app wires this to
    /// `ProtocolEncoder.sendRequestKeyframe(...)` so the BEAM re-sends the next
    /// frame as a full keyframe.
    var onRequestKeyframe: ((UInt32) -> Void)?

    /// Called when the window title should change.
    var onTitleChanged: ((String) -> Void)?

    /// Called when the BEAM sends a window background color (RGB).
    var onWindowBgChanged: ((NSColor) -> Void)?

    /// Called when the BEAM toggles the go-to-definition link cursor (#2630).
    /// `true` shows the pointing-hand cursor for a navigable Cmd+hover symbol.
    var onLinkCursorChanged: ((Bool) -> Void)?

    /// Called when the BEAM sends a font configuration change.
    /// Parameters: family, size, ligatures, weight byte.
    var onFontChanged: ((String, UInt16, Bool, UInt8) -> Void)?

    /// Called when the editor mode changes (for accessibility announcements).
    /// Parameter: mode name string (e.g., "NORMAL", "INSERT", "VISUAL").
    var onModeChanged: ((String) -> Void)?

    /// Called when agent chat visibility changes. Used to install/remove
    /// the keyboard event monitor on EditorNSView since SwiftUI onChange
    /// can miss updates during animated transitions.
    var onAgentChatVisibilityChanged: ((Bool) -> Void)?

    /// Called when line_spacing changes, so EditorNSView can trigger a resize.
    var onLineSpacingChanged: ((Float) -> Void)?

    /// Called when a reset-required scroll presentation is promoted into GUI state.
    /// The editor view uses this to discard local smooth-scroll state once per frame.
    var onScrollPresentationReset: (() -> Void)?

    /// Called when the BEAM changes the GUI cursor animation preference.
    var onCursorAnimationChanged: ((Bool) -> Void)?

    /// Called once after the first `commit_frame` is received from the BEAM.
    /// Used in bundle mode to flush pending file URLs after the BEAM is ready.
    var onFirstRender: (() -> Void)?

    /// Tracks the last mode to detect changes.
    private var lastMode: UInt8 = 0

    /// All GUI chrome sub-states. Injected at init from AppDelegate.
    /// Non-optional: forgetting to wire this is a compile-time error.
    let guiState: GUIState
    private let resourcePolicy: FrameResourcePolicy

    /// Records input-to-apply and input-to-presentation as separate milestones.
    /// A committed transaction marks apply only; Metal owns submission/completion.
    let latency = LatencyRecorder()

    /// Input sequence attached to the newest applied frame awaiting a draw.
    private var pendingPresentationInputSeq: UInt32 = 0

    /// Claims the newest applied input sequence for one Metal submission.
    func takePresentationInputSeq() -> UInt32 {
        let seq = pendingPresentationInputSeq
        pendingPresentationInputSeq = 0
        return seq
    }

    /// Discards an applied frame that cannot acquire a drawable/presentation path.
    func discardPendingPresentation(reason: LatencyRecorder.DiscardReason) {
        guard pendingPresentationInputSeq != 0 else { return }
        latency.discard(seq: pendingPresentationInputSeq, reason: reason)
        pendingPresentationInputSeq = 0
    }

    /// Window ids that arrived in the current frame batch. Used for input hit testing so stale
    /// retained pane geometry can still render without being clickable.
    // TODO(#2241-adjacent): no reset path since the cell-era clear opcode was
    // retired; grows by distinct window ids seen this session (bounded, ids are
    // reused). Reset at semantic frame start when frame lifecycle is reworked.
    private(set) var currentFrameWindowIds: Set<UInt16> = []

    // MARK: - Frame transaction staging (#2219 child D)

    /// frame_seq of the currently open `begin_frame`, or nil when no transaction
    /// is open. Set on `begin_frame`, cleared on `commit_frame` or invalidation.
    private(set) var openFrameSeq: UInt32?

    /// base_frame_seq and BEAM-owned generation of the open transaction.
    private var openBaseFrameSeq: UInt32 = 0
    private var openGeneration: UInt32 = 0
    private var openGenerationIsStale = false

    /// Value-semantic builder for the open frame. Commands are classified and
    /// window deltas are resolved during staging; commit only freezes and publishes.
    private var transactionBuilder: PreparedFrameTransactionBuilder?

    /// Font resources known to the publisher. Font id 0 is the primary font.
    private var registeredFontIds: Set<UInt8> = [0]

    /// Typed result boundary consumed by the frame acknowledgement work in #2739.
    var onTransactionResult: ((FrameTransactionResult) -> Void)?

    /// Number of focused publication-boundary entries, exposed for instrumentation.
    private(set) var publicationCount = 0

    /// Cost of the most recently published frame in changed-domain operations.
    private(set) var lastPublicationOperationCounts: PreparedFrameOperationCounts?

    /// frame_seq of the last transaction this dispatcher committed cleanly.
    /// Doubles as the delta base validator and the `last_good_frame_seq` carried
    /// by `request_keyframe` on invalidation. 0 until the first clean commit.
    private(set) var lastCommittedFrameSeq: UInt32 = 0
    private(set) var lastCommittedGeneration: UInt32 = 0
    private var lastTerminalRejection: TerminalRejectionSignature?

    /// True once at least one frame has committed, so `lastCommittedFrameSeq == 0`
    /// can still be told apart from "never committed" when validating a base.
    private var hasCommitted = false

    /// Resync is complete only when a requested base-0 keyframe commits cleanly.
    /// A keyframe that fails while staged must trigger one fresh request, while stale
    /// delta frames arriving before that keyframe remain debounced.
    private enum ResyncRecoveryState: Equatable {
        case clean
        case awaitingKeyframe
        case keyframeInFlight
    }
    private var resyncRecoveryState: ResyncRecoveryState = .clean

    /// gui_theme must carry the full slot set the frontends rely on. Missing slots are a protocol bug, not a theme fallback case.
    static let requiredThemeSlots: [UInt8] = [
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A,
        0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
        0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
        0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A,
        0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A,
        0x40,
        0x50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x5B,
        0x5C, 0x5D, 0x5E, 0x5F, 0x60, 0x61,
        0x62,
        0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE,
    ]

    init(
        cols: UInt16, rows: UInt16, guiState: GUIState,
        resourcePolicy: FrameResourcePolicy = .default
    ) {
        self.frameState = FrameState(cols: cols, rows: rows)
        self.guiState = guiState
        self.resourcePolicy = resourcePolicy
    }

    /// Entry point from the protocol reader. Routes a decoded command through the
    /// frame-transaction state machine: frame markers open/close transactions,
    /// transaction-scoped commands compile into the prepared builder, and explicitly
    /// sanctioned out-of-band commands apply immediately (or stage if inside a
    /// transaction). Everything else outside a transaction triggers active
    /// recovery: invalidation and a keyframe request.
    ///
    /// This is the negative-guard pattern from Go's model.go (applyCommands,
    /// lines 444-459): give known out-of-band commands explicit match arms so
    /// any new BEAM out-of-band command without a match arm defaults to
    /// active recovery rather than silent drop. Contrast the old positive-allowlist
    /// design where a missing entry caused an unnecessary keyframe request with no
    /// application of the command.
    /// Stages every immutable command from one decoded packet through the same
    /// prepared-transaction builder. Packet decoding itself remains off-main.
    func dispatch(_ frame: DecodedFrame) {
        for decoded in frame.commands {
            dispatch(decoded.command, opcode: decoded.opcode)
        }
    }

    func dispatch(_ command: RenderCommand, opcode: UInt8? = nil) {
        switch command {
        case .beginFrame(let frameSeq, let baseFrameSeq, let generation):
            beginTransaction(frameSeq: frameSeq, baseFrameSeq: baseFrameSeq, generation: generation)

        case .commitFrame(let frameSeq, let seq):
            commitTransaction(frameSeq: frameSeq, inputSeq: seq)

        // Sanctioned out-of-band commands: the BEAM legitimately emits these
        // outside a begin/commit bracket. If one arrives inside an open
        // transaction it compiles for atomic publication; outside one it applies
        // immediately. Mirrors Go's explicit match arms at model.go:444-450.
        //
        // setTitle / setWindowBg / setLinkCursor / clipboardWrite: post-commit
        //   side-channels.
        // protocolError: handshake rejection, always pre-transaction.
        // setFont / setFontFallback / registerFont / guiConfigState: startup
        //   config emitted before the first frame (equivalent to Go's CommandNoop
        //   for font commands, but Swift actually applies them).
        case .guiConfigState:
            // Settings is an independently interactive scene. Its config stream
            // is startup/out-of-band state and never participates in a render frame.
            guiState.performOutOfBandPublication {
                apply(command)
            }

        case .setTitle, .setWindowBg, .setLinkCursor, .protocolError,
             .setFont, .setFontFallback, .registerFont, .clipboardWrite:
            if openFrameSeq != nil {
                transactionBuilder?.stage(command)
            } else {
                guiState.performOutOfBandPublication {
                    apply(command)
                }
            }

        default:
            if openFrameSeq != nil {
                // Inside a transaction: compile into typed domain updates.
                transactionBuilder?.stage(command)
            } else {
                // A command arrived with no open transaction and no sanctioned
                // out-of-band match above. Either a new BEAM out-of-band command
                // was added to the protocol without a corresponding explicit arm
                // here, or the byte stream is desynced. Active recovery: discard
                // staged state and request a keyframe. Mirrors Go model.go:454-456.
                reject(
                    .outOfTransactionCommand(opcode: opcode),
                    frameSeq: nil,
                    logReason: "out-of-transaction command",
                    sourceOpcode: opcode
                )
            }
        }
    }

    /// Opens a frame transaction. A second `begin_frame` before its matching
    /// `commit_frame` is truncation: the prior frame never closed, so its staged
    /// commands are discarded and we resync before opening the new transaction.
    private func beginTransaction(frameSeq: UInt32, baseFrameSeq: UInt32, generation: UInt32) {
        if let openFrameSeq {
            // Double-begin = truncation of the previous frame.
            reject(
                .beginWhileOpen(openFrameSeq: openFrameSeq, incomingFrameSeq: frameSeq),
                frameSeq: openFrameSeq,
                logReason: "begin_frame while a transaction was open"
            )
        }
        openFrameSeq = frameSeq
        openBaseFrameSeq = baseFrameSeq
        openGeneration = generation
        openGenerationIsStale = hasCommitted && generation < lastCommittedGeneration
        transactionBuilder = PreparedFrameTransactionBuilder(
            frameSeq: frameSeq,
            baseFrameSeq: baseFrameSeq,
            generation: generation,
            committedWindows: guiState.windowContents,
            registeredFontIds: registeredFontIds,
            committedTranscript: guiState.agentChatState.transcriptSnapshot,
            stagingLimit: resourcePolicy.staging.weight,
            residentLimit: resourcePolicy.resident.weightPerWindow
        )
        if baseFrameSeq == 0 && resyncRecoveryState == .awaitingKeyframe {
            resyncRecoveryState = .keyframeInFlight
        }
    }

    /// Closes, freezes, and publishes the open transaction. Validation completes
    /// before `publish(_:)` is entered, so a rejected frame has no observable writes.
    private func commitTransaction(frameSeq: UInt32, inputSeq: UInt32) {
        if openGenerationIsStale {
            openFrameSeq = nil
            transactionBuilder = nil
            openGenerationIsStale = false
            return
        }
        guard let open = openFrameSeq else {
            reject(
                .commitWithoutBegin(frameSeq: frameSeq),
                frameSeq: frameSeq,
                logReason: "commit_frame with no open transaction"
            )
            return
        }
        guard frameSeq == open else {
            reject(
                .commitSequenceMismatch(openFrameSeq: open, commitFrameSeq: frameSeq),
                frameSeq: open,
                logReason: "commit_frame seq \(frameSeq) != open begin seq \(open)"
            )
            return
        }
        guard !hasCommitted || frameSeq > lastCommittedFrameSeq else {
            reject(
                .frameSequenceNotIncreasing(lastFrameSeq: lastCommittedFrameSeq, incomingFrameSeq: frameSeq),
                frameSeq: frameSeq,
                logReason: "frame_seq \(frameSeq) is not newer than \(lastCommittedFrameSeq)"
            )
            return
        }

        let baseValid = openBaseFrameSeq == 0 ||
            (hasCommitted && openBaseFrameSeq == lastCommittedFrameSeq)
        guard baseValid else {
            reject(
                .baseSequenceMismatch(expectedFrameSeq: lastCommittedFrameSeq, actualBaseFrameSeq: openBaseFrameSeq),
                frameSeq: frameSeq,
                logReason: "base_frame_seq \(openBaseFrameSeq) != last committed \(lastCommittedFrameSeq)"
            )
            return
        }
        guard let transactionBuilder else {
            reject(.decodeFailure(frameSeq: frameSeq), frameSeq: frameSeq, logReason: "missing frame builder")
            return
        }

        switch transactionBuilder.freeze(requiredThemeSlots: Self.requiredThemeSlots) {
        case .failure(let rejection):
            reject(rejection, frameSeq: frameSeq, logReason: rejection.logDescription)
            return
        case .success(let transaction):
            if openBaseFrameSeq == 0 && resyncRecoveryState == .keyframeInFlight {
                resyncRecoveryState = .clean
                guiState.resyncState.clear()
            }
            publish(transaction)
        }

        lastCommittedFrameSeq = frameSeq
        lastCommittedGeneration = openGeneration
        hasCommitted = true
        lastTerminalRejection = nil
        openFrameSeq = nil
        self.transactionBuilder = nil

        os_signpost(.event, log: renderLog, name: "SemanticApply", "frame=%{public}u input=%{public}u", frameSeq, inputSeq)
        if pendingPresentationInputSeq != 0, pendingPresentationInputSeq != inputSeq {
            latency.discard(seq: pendingPresentationInputSeq, reason: .superseded)
        }
        latency.markApplied(seq: inputSeq)
        pendingPresentationInputSeq = inputSeq
        onTransactionResult?(.applied(generation: openGeneration, frameSeq: frameSeq))
        if let firstRender = onFirstRender {
            firstRender()
            onFirstRender = nil
        }
        onFramePresented?()
        onFrameReady?()
    }

    /// The sole committed-GUI publication boundary.
    private func publish(_ transaction: PreparedFrameTransaction) {
        guiState.performFramePublication(frameSeq: transaction.frameSeq) {
            if let theme = transaction.theme { apply(.guiTheme(slots: theme.slots)) }
            if let resources = transaction.resources { resources.commands.forEach(apply) }
            if let windows = transaction.windows { apply(windows) }
            if let metadata = transaction.metadata { metadata.commands.forEach(apply) }
            if let chrome = transaction.chrome {
                if let transcript = chrome.transcript {
                    guiState.agentChatState.publishTranscript(transcript)
                }
                chrome.commands.forEach(apply)
            }
            if let overlays = transaction.overlays { overlays.commands.forEach(apply) }
            if let focus = transaction.focus { focus.commands.forEach(apply) }
        }
        publicationCount += 1
        lastPublicationOperationCounts = transaction.operationCounts
    }

    private func apply(_ updates: PreparedWindowUpdates) {
        for (windowId, content) in updates.replacements {
            let previousScroll = guiState.windowContents[windowId]?.scrollPresentation
            guiState.windowContents[windowId] = content
            if shouldResetScrollPresentation(previous: previousScroll, next: content.scrollPresentation) {
                discardLocalPresentation(.offset, windowId: windowId)
            }
            frameState.cursorVisible = content.cursorVisible
            frameState.dirty = true
        }
        updates.commands.forEach(apply)
        if let authoritativeWindowIds = updates.authoritativeWindowIds {
            pruneAuthoritativeFrameState(liveWindowIds: authoritativeWindowIds)
        } else {
            currentFrameWindowIds.formUnion(updates.touchedWindowIds)
        }
    }

    private func pruneAuthoritativeFrameState(liveWindowIds: Set<UInt16>) {
        guiState.windowContents = Dictionary(uniqueKeysWithValues: guiState.windowContents.filter { liveWindowIds.contains($0.key) })
        frameState.windowGutters = Dictionary(uniqueKeysWithValues: frameState.windowGutters.filter { liveWindowIds.contains($0.key) })
        frameState.windowIndentGuides = Dictionary(uniqueKeysWithValues: frameState.windowIndentGuides.filter { liveWindowIds.contains($0.key) })
        currentFrameWindowIds = liveWindowIds
        refreshDerivedGutterStateAfterPrune()
    }

    private func refreshDerivedGutterStateAfterPrune() {
        guard let activeGutter = frameState.windowGutters.values.filter(\.isActive).sorted(by: { $0.windowId < $1.windowId }).first else {
            frameState.gutterCol = 0
            frameState.viewportTopLine = 0xFFFF_FFFF
            return
        }

        frameState.gutterCol = UInt16(activeGutter.lineNumberWidth) + UInt16(activeGutter.signColWidth)
        frameState.viewportTopLine = activeGutter.entries.first?.bufLine ?? 0xFFFF_FFFF
    }

    /// Rejects one frame, leaves the last-good publication untouched, and emits
    /// exactly one typed result for the acknowledgement layer in #2739.
    private func reject(
        _ rejection: PreparedFrameRejection,
        frameSeq: UInt32?,
        logReason: String,
        sourceOpcode: UInt8? = nil
    ) {
        let opcodeContext = sourceOpcode.map { String(format: ", opcode=0x%02X", $0) } ?? ""
        let rejectedFrameSeq = frameSeq ?? 0
        openFrameSeq = nil
        openBaseFrameSeq = 0
        transactionBuilder = nil
        openGenerationIsStale = false

        if case .missingWindowReference(let windowId) = rejection {
            // A row/window reference miss has a targeted BEAM recovery path. Keep
            // unrelated committed surfaces live and do not enter global base-zero
            // resync; the replacement window arrives on the acknowledged base.
            PortLogger.warn("Frame transaction missed window \(windowId) (\(logReason)\(opcodeContext)); awaiting targeted replacement")
            onTransactionResult?(.windowRefMiss(
                generation: openGeneration,
                frameSeq: rejectedFrameSeq,
                lastAppliedFrameSeq: lastCommittedFrameSeq,
                windowId: windowId
            ))
            return
        }

        let terminal = rejection.disposition == .terminalFrontendFailure
        let terminalSignature = TerminalRejectionSignature(
            generation: openGeneration,
            frameSeq: rejectedFrameSeq,
            lastGoodFrameSeq: lastCommittedFrameSeq,
            reason: rejection.wireCode
        )
        guard !terminal || lastTerminalRejection != terminalSignature else { return }
        if terminal { lastTerminalRejection = terminalSignature }

        if terminal {
            resyncRecoveryState = .clean
            if guiState.resyncState.pending {
                guiState.performOutOfBandPublication {
                    guiState.resyncState.clear()
                }
            }
            PortLogger.error("Frame transaction terminally rejected (\(logReason)\(opcodeContext)); preserving last-good frame \(lastCommittedFrameSeq)")
        } else {
            let shouldRequestKeyframe = resyncRecoveryState != .awaitingKeyframe
            resyncRecoveryState = .awaitingKeyframe
            PortLogger.warn("Frame transaction rejected (\(logReason)\(opcodeContext)); awaiting BEAM recovery from \(lastCommittedFrameSeq)")
            guiState.performOutOfBandPublication {
                guiState.resyncState.markPending(
                    lastGoodFrameSeq: lastCommittedFrameSeq,
                    generation: openGeneration,
                    rejection: rejection.logDescription
                )
            }
            if shouldRequestKeyframe {
                // Compatibility/test seam only. Production recovery is driven by the
                // typed onTransactionResult status wired in MingaApp.
                onRequestKeyframe?(lastCommittedFrameSeq)
            }
        }
        onTransactionResult?(.rejected(
            generation: openGeneration,
            frameSeq: rejectedFrameSeq,
            lastAppliedFrameSeq: lastCommittedFrameSeq,
            reason: rejection
        ))
    }

    /// Surfaced by the protocol reader when `decodeCommands` throws mid-stream.
    /// Per the AC-1 consult, a sizing failure or unknown opcode INSIDE an open
    /// transaction tightens the reader's usual warn-and-continue policy: the byte
    /// boundaries are no longer trustworthy, so we invalidate and resync. Outside
    /// a transaction there is nothing staged to discard, so the reader keeps its
    /// existing log-and-continue behavior.
    func decodeFailed() {
        guard let openFrameSeq else { return }
        reject(
            .decodeFailure(frameSeq: openFrameSeq),
            frameSeq: openFrameSeq,
            logReason: "decode failure inside an open transaction"
        )
    }

    /// Rejects the open frame under the deterministic hard resource policy.
    /// The last-good semantic publication remains active and no keyframe is requested.
    func resourcePolicyRejected() {
        guard let openFrameSeq else { return }
        reject(
            .resourcePolicy,
            frameSeq: openFrameSeq,
            logReason: "frontend resource policy exceeded"
        )
    }

    /// Publishes a correlated terminal result when decode failed before the
    /// transaction crossed actor isolation. Last-good semantic state is untouched.
    func resourcePolicyRejected(envelope: FrameEnvelope) {
        openGeneration = envelope.generation
        openFrameSeq = envelope.frameSeq
        openBaseFrameSeq = envelope.baseFrameSeq
        reject(
            .resourcePolicy,
            frameSeq: envelope.frameSeq,
            logReason: "frontend decode resource policy exceeded"
        )
    }

    /// Test seam: apply a single command directly to the presented state,
    /// bypassing the frame-transaction machinery. Production code never calls
    /// this; it routes through `dispatch`. Routing/setup tests use it to assert a
    /// command's mutation without bracketing every call in begin/commit.
    func applyForTesting(_ command: RenderCommand) {
        if case .guiAgentTranscript(let mode, let epoch, let truncated, let trimFront, let baseCount, let messages) = command {
            _ = guiState.agentChatState.applyTranscript(
                mode: mode,
                epoch: epoch,
                truncated: truncated,
                trimFront: Int(trimFront),
                baseCount: Int(baseCount),
                messages: messages
            )
            return
        }
        apply(command)
    }

    // MARK: - View-driven FrameState mutations

    /// Applies a view-derived viewport resize. The cell-grid dimensions depend on
    /// the NSView's pixel size and font metrics, which the BEAM cannot know, so
    /// the trigger is an AppKit event (font change, window resize, line-spacing
    /// change) rather than a protocol opcode. Routing it here keeps
    /// `CommandDispatcher` the single writer to `FrameState`: every mutation has
    /// one place to add logging, ordering checks, or BEAM coordination. The view
    /// still sends the `sendResize`/`sendReady` event itself, since that is a
    /// view-to-BEAM event, not state.
    func applyViewportResize(newCols: UInt16, newRows: UInt16) {
        frameState.resize(newCols: newCols, newRows: newRows)
    }

    /// Clears the dirty flag after the view has consumed the current
    /// `FrameState` for a render. The view drives the render but does not own the
    /// state, so it calls this instead of writing `frameState.dirty` directly.
    func markRendered() {
        frameState.dirty = false
    }

    /// Applies a zero-latency local file-tree navigation preview when the BEAM marks the current tree model as eligible.
    /// The key still goes to the BEAM; this only moves the transient selection highlight until the next authoritative file-tree payload reconciles it.
    @discardableResult
    func previewFileTreeNavigation(codepoint: UInt32, modifiers: UInt8) -> Bool {
        guard modifiers == 0 else { return false }

        let changed: Bool
        switch codepoint {
        case FileTreeNavigationCodepoints.downKey, FileTreeNavigationCodepoints.downArrow:
            changed = guiState.fileTreeState.previewNavigation(delta: 1)
        case FileTreeNavigationCodepoints.upKey, FileTreeNavigationCodepoints.upArrow:
            changed = guiState.fileTreeState.previewNavigation(delta: -1)
        default:
            return false
        }
        if changed { guiState.performOutOfBandPublication {} }
        return changed
    }

    @discardableResult
    func previewCompletionNavigation(codepoint: UInt32, modifiers: UInt8) -> Bool {
        let delta: Int
        if modifiers == CompletionNavigationCodepoints.ctrlModifier {
            switch codepoint {
            case CompletionNavigationCodepoints.ctrlN:
                delta = 1
            case CompletionNavigationCodepoints.ctrlP:
                delta = -1
            default:
                return false
            }
        } else if modifiers == 0 {
            switch codepoint {
            case CompletionNavigationCodepoints.downArrow:
                delta = 1
            case CompletionNavigationCodepoints.upArrow:
                delta = -1
            default:
                return false
            }
        } else {
            return false
        }
        let changed = guiState.completionState.previewNavigation(delta: delta)
        if changed { guiState.performOutOfBandPublication {} }
        return changed
    }

    @discardableResult
    func previewPickerNavigation(codepoint: UInt32, modifiers: UInt8) -> Bool {
        guard modifiers == 0 else { return false }

        let changed: Bool
        switch codepoint {
        case PickerNavigationCodepoints.downKey, PickerNavigationCodepoints.downArrow:
            changed = guiState.pickerState.previewNavigation(delta: 1)
        case PickerNavigationCodepoints.upKey, PickerNavigationCodepoints.upArrow:
            changed = guiState.pickerState.previewNavigation(delta: -1)
        default:
            return false
        }
        if changed { guiState.performOutOfBandPublication {} }
        return changed
    }

    /// Apply one domain command to the presented FrameState/GUIState. This is
    /// called directly for out-of-band commands and from the focused prepared
    /// publication boundary for committed domain updates. It must NOT handle frame
    /// markers (begin/commit) — those drive the transaction state machine in
    /// `dispatch`/`commitTransaction`, not the presented state.
    private func apply(_ command: RenderCommand) {
        switch command {
        case .setCursorShape(let shape):
            frameState.cursorShape = shape

        case .beginFrame, .commitFrame:
            // Frame markers drive the transaction state machine in `dispatch`,
            // not the presented state. They are intercepted before `apply` is
            // called and are never staged into a prepared transaction, so reaching
            // here means a routing bug.
            PortLogger.warn("Frame marker reached apply(_:); transaction routing bug")

        case .setTitle(let title):
            onTitleChanged?(title)

        case .setWindowBg(let r, let g, let b):
            let rgb: UInt32 = (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
            frameState.defaultBg = rgb
            let color = NSColor(
                red: CGFloat(r) / 255.0,
                green: CGFloat(g) / 255.0,
                blue: CGFloat(b) / 255.0,
                alpha: 1.0
            )
            PortLogger.info("Window bg received: r=\(r) g=\(g) b=\(b)")
            onWindowBgChanged?(color)

        case .setLinkCursor(let active):
            onLinkCursorChanged?(active)

        case .protocolError(let message):
            // The BEAM rejected this frontend's handshake protocol_version, so
            // we will never reach ready. Log to the port log and latch a blocking
            // error overlay instead of leaving a blank window (ticket #2237).
            PortLogger.error("Protocol error from BEAM: \(message)")
            guiState.protocolErrorState.present(message: message)

        case .setFont(let family, let size, let ligatures, let weight):
            onFontChanged?(family, size, ligatures, weight)

        case .setFontFallback(let families):
            fontManager?.setFallbackFonts(families)

        case .registerFont(let id, let family):
            fontManager?.registerFont(id: id, name: family)
            registeredFontIds.insert(id)

        case .guiConfigState(let configState):
            guiState.settingsState.apply(configState: configState)

        case .guiNotifications(let notifications):
            guiState.notificationCenterState.update(rawNotifications: notifications)

        case .guiEditTimeline(let visible, let viewingIndex, let entries, let files):
            guiState.editTimelineState.update(visible: visible, viewingIndex: viewingIndex, wireEntries: entries, wireFiles: files)

        case .guiTheme(let slots):
            guiState.replaceTheme(slots: slots)
            let tc = guiState.themeColors
            frameState.gutterColors = GutterThemeColors(
                fg: tc.gutterFgRGB,
                currentFg: tc.gutterCurrentFgRGB,
                errorFg: tc.gutterErrorFgRGB,
                warningFg: tc.gutterWarningFgRGB,
                infoFg: tc.gutterInfoFgRGB,
                hintFg: tc.gutterHintFgRGB,
                foldFg: tc.gutterFoldFgRGB,
                gitAddedFg: tc.gitAddedFgRGB,
                gitModifiedFg: tc.gitModifiedFgRGB,
                gitDeletedFg: tc.gitDeletedFgRGB
            )

        case .guiTabBar(let activeIndex, let tabs):
            guiState.tabBarState.update(activeIndex: activeIndex, entries: tabs)

        case .guiEmptyState(let visible, let crashed, let version, let focusedId, let sections):
            if visible {
                guiState.emptyStateState.update(crashed: crashed, version: version, focusedId: focusedId, sections: sections)
            } else {
                guiState.emptyStateState.hide()
            }

        case .guiWorkspaces(let version, let activeWorkspaceId, let mode, let flags, let workspaces, let visibleTabs):
            guiState.workspaceState.update(version: version, activeWorkspaceId: activeWorkspaceId, mode: mode, flags: flags, workspaces: workspaces, visibleTabs: visibleTabs)
            guiState.tabBarState.updateWorkspaces(activeWorkspaceId: activeWorkspaceId, mode: mode, flags: flags, entries: workspaces, visibleTabs: visibleTabs)


        case .guiAgentContext(let visible, let task, let dispatchTimestamp, let status, let canApprove, let progress, let todos):
            guiState.agentContextBarState.update(visible: visible, task: task, dispatchTimestamp: dispatchTimestamp,
                                                  status: status, canApprove: canApprove, progress: progress, todos: todos)
        case .guiChangeSummary(let visible, let entries, let selectedIndex):
            guiState.changeSummaryState.update(visible: visible, entries: entries, selectedIndex: selectedIndex)

        case .guiIndentGuides(let data):
            frameState.windowIndentGuides[data.windowId] = data
            currentFrameWindowIds.insert(data.windowId)
            frameState.dirty = true

        case .guiLineSpacing(let spacing):
            let oldSpacing = frameState.lineSpacing
            frameState.lineSpacing = max(spacing, 1.0)
            frameState.dirty = true
            if oldSpacing != frameState.lineSpacing {
                onLineSpacingChanged?(frameState.lineSpacing)
            }

        case .guiCursorAnimation(let enabled):
            onCursorAnimationChanged?(enabled)

        case .clipboardWrite(let target, let text):
            handleClipboardWrite(target: target, text: text)

        case .guiObservatory(let visible, _, let nodes):
            if visible {
                guiState.observatoryState.update(visible: true, rawNodes: nodes)
            } else {
                guiState.observatoryState.hide()
            }

        case .guiFileTree(let version, let treeFlags, let treeState, let selectedId, let treeWidth, let rootPath, let errorReason, let entries):
            let visible = treeState != FileTreeVisibilityState.hidden.rawValue
            let focused = treeFlags & 0x02 != 0
            if visible {
                guiState.fileTreeState.update(version: version, treeFlags: treeFlags, selectedId: selectedId, focused: focused, treeWidth: treeWidth, rootPath: rootPath, rawEntries: entries, treeState: treeState, errorReason: errorReason)
            } else {
                guiState.fileTreeState.hide(rootPath: rootPath)
            }

        case .guiFileTreeSelection(let selectedId, let focused):
            guiState.fileTreeState.updateSelection(selectedId: selectedId, focused: focused)

        case .guiCompletion(let visible, let anchorRow, let anchorCol, let selectedIndex, let items, let documentation):
            if visible {
                guiState.completionState.update(visible: true, anchorRow: anchorRow, anchorCol: anchorCol, selectedIndex: selectedIndex, rawItems: items, documentation: documentation)
            } else {
                guiState.completionState.hide()
            }

        case .guiWhichKey(let visible, let prefix, let page, let pageCount, let bindings):
            if visible {
                guiState.whichKeyState.update(visible: true, prefix: prefix, page: page, pageCount: pageCount, rawBindings: bindings)
            } else {
                guiState.whichKeyState.hide()
            }

        case .guiBreadcrumb(let segments):
            guiState.breadcrumbState.update(segments: segments)

        case .guiStatusBar(let update):
            guiState.statusBarState.update(from: update)
            guiState.feedbackState.update(message: update.message)
            frameState.totalLineCount = update.lineCount
            if update.mode != lastMode {
                lastMode = update.mode
                onModeChanged?(guiState.statusBarState.modeName)
            }

        case .guiPicker(let visible, let selectedIndex, let filteredCount, let totalCount, let markedCount, let title, let query, let hasPreview, let items, let actionMenu, let modePrefix, let loadStatus):
            if visible {
                guiState.pickerState.update(visible: true, selectedIndex: selectedIndex, filteredCount: filteredCount, totalCount: totalCount, markedCount: markedCount, title: title, query: query, hasPreview: hasPreview, rawItems: items, actionMenu: actionMenu, modePrefix: modePrefix, loadStatus: loadStatus)
            } else {
                guiState.pickerState.hide()
            }

        case .guiPickerPreview(let visible, let lines):
            if visible {
                guiState.pickerState.updatePreview(lines: lines)
            } else {
                guiState.pickerState.clearPreview()
            }

        case .guiAgentChat(let visible, let status, let model, let thinkingLevel, let prompt, let promptLineCount, let promptCursorLine, let promptCursorCol, let promptVimMode, let promptVisibleRows, let promptCompletion, _, _, let helpVisible, let helpGroups, _):
            // The 0x78 messages section is intentionally ignored (#2654 slice 2):
            // the resident transcript is sourced from the 0x86 gui_agent_transcript
            // stream via .guiAgentTranscript. Only chrome fields are applied here.
            let wasVisible = guiState.agentChatState.visible
            if visible {
                let groups = helpGroups.map { g in
                    HelpGroup(title: g.title, bindings: g.bindings.map { ($0.key, $0.description) })
                }
                guiState.agentChatState.update(visible: true, status: status, model: model, thinkingLevel: thinkingLevel, prompt: prompt, promptLineCount: promptLineCount, promptCursorLine: promptCursorLine, promptCursorCol: promptCursorCol, promptVimMode: promptVimMode, promptVisibleRows: promptVisibleRows, promptCompletion: promptCompletion, helpVisible: helpVisible, helpGroups: groups)
            } else {
                guiState.agentChatState.hide()
            }
            if guiState.agentChatState.visible != wasVisible {
                onAgentChatVisibilityChanged?(guiState.agentChatState.visible)
            }

        case .guiAgentTranscript:
            // Prepared transactions publish the validated value snapshot directly.
            // Reaching this path would bypass all-or-nothing transcript validation.
            assertionFailure("guiAgentTranscript must be prepared before publication")

        case .guiGutterSeparator(let col, let r, let g, let b):
            let rgb: UInt32 = (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
            // Use the gutter fg color for the scroll indicator.
            frameState.scrollIndicatorColor = rgb
            frameState.gutterCol = col
            frameState.gutterSeparatorColor = rgb
            frameState.dirty = true

        case .guiCursorline(let row, let r, let g, let b):
            let rgb: UInt32 = (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
            frameState.cursorlineRow = row
            frameState.cursorlineBg = rgb
            frameState.dirty = true

        case .guiGutter(let data):
            frameState.windowGutters[data.windowId] = data
            currentFrameWindowIds.insert(data.windowId)
            if data.isActive {
                frameState.activeWindowId = data.windowId
                frameState.gutterCol = UInt16(data.lineNumberWidth) + UInt16(data.signColWidth)
                // Derive viewport top from the first gutter entry's buffer line.
                if let firstEntry = data.entries.first {
                    frameState.viewportTopLine = firstEntry.bufLine
                }
            }
            frameState.dirty = true

        case .guiWindowContent(let data):
            let previousScroll = guiState.windowContents[data.windowId]?.scrollPresentation
            guiState.windowContents[data.windowId] = data
            currentFrameWindowIds.insert(data.windowId)
            if shouldResetScrollPresentation(previous: previousScroll, next: data.scrollPresentation) {
                discardLocalPresentation(.offset, windowId: data.windowId)
            }
            frameState.cursorVisible = data.cursorVisible

        case .guiWindowOverlayDelta(let delta):
            guard let current = guiState.windowContents[delta.windowId] else { break }
            guard let updated = current.applyingOverlayDelta(delta) else { break }
            guiState.windowContents[delta.windowId] = updated
            currentFrameWindowIds.insert(delta.windowId)
            frameState.cursorVisible = delta.cursorVisible
            frameState.dirty = true

        case .guiWindowViewportDelta(let delta), .guiWindowRowsDelta(let delta):
            guard let current = guiState.windowContents[delta.windowId] else { break }
            guard current.contentEpoch == delta.contentEpoch else { break }
            guard let updated = current.applyingRowsDelta(delta) else {
                guiState.windowContents.removeValue(forKey: delta.windowId)
                break
            }
            let previousScroll = current.scrollPresentation
            guiState.windowContents[delta.windowId] = updated
            currentFrameWindowIds.insert(delta.windowId)
            if shouldResetScrollPresentation(previous: previousScroll, next: updated.scrollPresentation) {
                discardLocalPresentation(.offset, windowId: delta.windowId)
            }
            frameState.cursorVisible = delta.cursorVisible
            frameState.dirty = true

        case .guiBottomPanel(let visible, let activeTabIndex, let heightPercent, let filterPreset, let tabs, let entries):
            if visible {
                let panelTabs = tabs.enumerated().map { (i, t) in
                    BottomPanelTab(id: i, tabType: t.tabType, name: t.name)
                }
                guiState.bottomPanelState.update(
                    visible: true,
                    activeTabIndex: Int(activeTabIndex),
                    heightPercent: Int(heightPercent),
                    filterPreset: filterPreset,
                    tabs: panelTabs
                )
                if !entries.isEmpty {
                    guiState.bottomPanelState.messagesState.appendEntries(entries)
                }
            } else {
                guiState.bottomPanelState.hide()
            }

        case .guiToolManager(let visible, let filter, let selectedIndex, let rawTools):
            if visible {
                let tools = rawTools.map { t in
                    ToolEntry(
                        id: t.name,
                        name: t.name,
                        label: t.label,
                        description: t.description,
                        category: ToolCategory(rawValue: t.category) ?? .lspServer,
                        status: ToolStatus(rawValue: t.status) ?? .notInstalled,
                        method: ToolMethod(rawValue: t.method) ?? .npm,
                        languages: t.languages,
                        version: t.version,
                        homepage: t.homepage,
                        provides: t.provides,
                        errorReason: t.errorReason
                    )
                }
                guiState.toolManagerState.update(
                    visible: true,
                    filter: ToolFilter(rawValue: filter) ?? .all,
                    selectedIndex: selectedIndex,
                    tools: tools
                )
            } else {
                guiState.toolManagerState.hide()
            }

        case .guiMinibuffer(let visible, let mode, let cursorPos, let prompt,
                             let input, let context, let selectedIndex,
                             let totalCandidates, let candidates):
            if visible {
                guiState.minibufferState.update(
                    visible: true, mode: mode, cursorPos: cursorPos,
                    prompt: prompt, input: input, context: context,
                    selectedIndex: selectedIndex, totalCandidates: totalCandidates,
                    rawCandidates: candidates
                )
            } else {
                guiState.minibufferState.hide()
            }

        case .guiHoverPopup(let visible, let anchorRow, let anchorCol,
                             let focused, let scrollOffset, let lines):
            if visible {
                guiState.hoverPopupState.update(
                    visible: true, anchorRow: anchorRow, anchorCol: anchorCol,
                    focused: focused, scrollOffset: scrollOffset, rawLines: lines
                )
            } else {
                guiState.hoverPopupState.hide()
            }

        case .guiHoverAction(let visible, let actionName):
            if visible {
                guiState.hoverPopupState.setOpenAction(name: actionName)
            } else {
                guiState.hoverPopupState.clearOpenAction()
            }

        case .guiSignatureHelp(let visible, let anchorRow, let anchorCol,
                                let activeSignature, let activeParameter, let signatures):
            if visible {
                guiState.signatureHelpState.update(
                    visible: true, anchorRow: anchorRow, anchorCol: anchorCol,
                    activeSignature: activeSignature, activeParameter: activeParameter,
                    rawSignatures: signatures
                )
            } else {
                guiState.signatureHelpState.hide()
            }

        case .guiSplitSeparators(let borderColor, let verticals, let horizontals):
            frameState.splitBorderColor = borderColor
            frameState.verticalSeparators = verticals
            frameState.horizontalSeparators = horizontals
            frameState.dirty = true

        case .guiFloatPopup(let visible, let width, let height, let title, let lines):
            if visible {
                guiState.floatPopupState.update(
                    visible: true, width: width, height: height,
                    title: title, lines: lines
                )
            } else {
                guiState.floatPopupState.hide()
            }

        case .guiGitStatus(let repoState, let syncing, let ahead, let behind, let branchName, let rawEntries, let rawToast, let entryBasePath, let lastCommitMessage, let stashCount):
            // When git_status_panel is nil, the BEAM sends notARepo + empty
            // entries as the "panel closed" signal (same pattern as file tree
            // sending empty entries to trigger hide). Can't gate on
            // rawEntries.isEmpty alone: a clean working tree (normal repo,
            // 0 changed files) is a valid visible-panel state. The compound
            // check notARepo + empty is the specific sentinel the BEAM sends
            // when git_status_panel is nil. (#1047)
            let parsedRepoState = GitRepoState(rawValue: repoState) ?? .notARepo
            let toast: (String, ToastLevel, ToastAction)? = rawToast.map { t in
                let parsedLevel = ToastLevel(rawValue: t.level)
                let parsedAction = ToastAction(rawValue: t.action)
                if parsedLevel == nil || parsedAction == nil {
                    PortLogger.warn("Invalid git toast metadata: level=\(t.level) action=\(t.action)")
                }
                return (t.message, parsedLevel ?? .error, parsedAction ?? .none)
            }

            if parsedRepoState == .notARepo && rawEntries.isEmpty && entryBasePath.isEmpty {
                guiState.gitStatusState.hide(syncing: syncing, toast: toast)
            } else {
                let entries = rawEntries.compactMap { raw -> GitStatusEntry? in
                    guard let section = GitStatusSection(rawValue: raw.section) else {
                        PortLogger.warn("Invalid git status section: \(raw.section)")
                        return nil
                    }
                    let status = GitFileStatus(rawValue: raw.status) ?? .unknown
                    if status == .unknown && raw.status != GitFileStatus.unknown.rawValue {
                        PortLogger.warn("Invalid git file status: \(raw.status)")
                    }
                    return GitStatusEntry(
                        pathHash: raw.pathHash,
                        section: section,
                        status: status,
                        path: raw.path
                    )
                }
                guiState.gitStatusState.update(
                    repoState: parsedRepoState,
                    branchName: branchName,
                    ahead: ahead,
                    behind: behind,
                    syncing: syncing,
                    entries: entries,
                    toast: toast,
                    entryBasePath: entryBasePath,
                    lastCommitMessage: lastCommitMessage,
                    stashCount: stashCount
                )
            }

        case .guiExtensionOverlay(let entries):
            guiState.extensionOverlayState.update(entries)

        case .guiExtensionPanel(let panels):
            guiState.extensionPanelState.update(panels)

        case .guiExtensionRuntime(let message):
            guiState.frontendExtensions.dispatch(message)

        case .guiSearchState(let active, let matchCount, let currentIndex, let flags):
            if active {
                guiState.searchState.update(active: true, matchCount: matchCount, currentIndex: currentIndex, flags: flags)
            } else {
                guiState.searchState.hide()
            }

        case .guiSidebars(_, let activeId, let sidebars):
            guiState.sidebarHostState.update(activeId: activeId, sidebars: sidebars)
        }
    }

    // MARK: - Local presentation

    enum TransformKind {
        case offset
        case identity
    }

    struct ScrollAnchorKey: Equatable {
        let contentEpoch: UInt32
        let layoutGeneration: UInt32
        let anchorTop: UInt32
        let anchorLeft: UInt16
        let anchorVisualRowOffset: UInt16

        init(_ sp: GUIScrollPresentation) {
            self.contentEpoch = sp.contentEpoch
            self.layoutGeneration = sp.layoutGeneration
            self.anchorTop = sp.anchorTop
            self.anchorLeft = sp.anchorLeft
            self.anchorVisualRowOffset = sp.anchorVisualRowOffset
        }
    }

    private func shouldResetScrollPresentation(previous: GUIScrollPresentation?, next: GUIScrollPresentation?) -> Bool {
        if let next, next.resetRequired { return true }
        guard let prev = previous else { return false }
        guard let next else { return true }
        // #2661: a strictly newer scroll-authority sequence means the BEAM
        // committed a fresh authoritative anchor (a jump racing a local
        // scroll report), even in the rare case where the jump coincidentally
        // lands on the same anchor key as the frontend's own in-flight offset.
        if next.scrollSeq > prev.scrollSeq { return true }
        return !next.isSameAnchorKey(as: prev)
    }

    func discardLocalPresentation(_ kind: TransformKind, windowId: UInt16 = 0) {
        switch kind {
        case .offset:
            onScrollPresentationReset?()
        case .identity:
            break
        }
    }

    // MARK: - Clipboard

    private func handleClipboardWrite(target: UInt8, text: String) {
        let pasteboard: NSPasteboard
        if target == 1 {
            pasteboard = NSPasteboard(name: .find)
        } else {
            pasteboard = NSPasteboard.general
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

}
