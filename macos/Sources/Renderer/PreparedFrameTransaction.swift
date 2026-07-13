/// Value-semantic frame preparation and validation.
///
/// Commands are classified while a frame is staged. Window deltas are resolved
/// against the last-good snapshot immediately, so publication never has to scan
/// the command stream or look up a live reference that was not validated first.

import Foundation
import MingaProtocol
import MingaUI

/// The single typed result consumed by the frame-status protocol in #2739.
enum FrameTransactionResult: Sendable, Equatable {
    case applied(generation: UInt32, frameSeq: UInt32)
    case rejected(generation: UInt32, frameSeq: UInt32, lastAppliedFrameSeq: UInt32, reason: PreparedFrameRejection)
    case windowRefMiss(generation: UInt32, frameSeq: UInt32, lastAppliedFrameSeq: UInt32, windowId: UInt16)
}

/// A rejection is complete and stable before any observable state is changed.
enum PreparedFrameRejection: Error, Sendable, Equatable {
    case beginWhileOpen(openFrameSeq: UInt32, incomingFrameSeq: UInt32)
    case commitWithoutBegin(frameSeq: UInt32)
    case commitSequenceMismatch(openFrameSeq: UInt32, commitFrameSeq: UInt32)
    case frameSequenceNotIncreasing(lastFrameSeq: UInt32, incomingFrameSeq: UInt32)
    case baseSequenceMismatch(expectedFrameSeq: UInt32, actualBaseFrameSeq: UInt32)
    case missingTheme
    case incompleteTheme(missingSlots: [UInt8])
    case missingWindowReference(windowId: UInt16)
    case windowEpochMismatch(windowId: UInt16, expected: UInt32, actual: UInt32)
    case invalidRetainedRows(windowId: UInt16, contentEpoch: UInt32)
    case invalidRowSplice(windowId: UInt16, contentEpoch: UInt32)
    case missingFontResource(fontId: UInt8)
    case transcriptBeforeSeed
    case transcriptEpochMismatch
    case transcriptDesynced
    case decodeFailure(frameSeq: UInt32)
    case outOfTransactionCommand(opcode: UInt8?)
    case resourcePolicy

    /// Stable wire value generated from docs/protocol_schema.toml.
    var wireCode: UInt8 {
        switch self {
        case .beginWhileOpen: return GeneratedProtocol.FrameRejectionReason.truncation.rawValue
        case .commitWithoutBegin, .commitSequenceMismatch: return GeneratedProtocol.FrameRejectionReason.commitSequenceMismatch.rawValue
        case .frameSequenceNotIncreasing: return GeneratedProtocol.FrameRejectionReason.frameSequenceNotIncreasing.rawValue
        case .baseSequenceMismatch: return GeneratedProtocol.FrameRejectionReason.baseSequenceMismatch.rawValue
        case .missingTheme: return GeneratedProtocol.FrameRejectionReason.missingTheme.rawValue
        case .incompleteTheme: return GeneratedProtocol.FrameRejectionReason.incompleteTheme.rawValue
        case .missingWindowReference: return GeneratedProtocol.FrameRejectionReason.missingWindowReference.rawValue
        case .windowEpochMismatch: return GeneratedProtocol.FrameRejectionReason.windowEpochMismatch.rawValue
        case .invalidRetainedRows: return GeneratedProtocol.FrameRejectionReason.invalidRetainedRows.rawValue
        case .missingFontResource: return GeneratedProtocol.FrameRejectionReason.missingFontResource.rawValue
        case .transcriptBeforeSeed, .transcriptEpochMismatch, .transcriptDesynced: return GeneratedProtocol.FrameRejectionReason.transcriptDesync.rawValue
        case .decodeFailure: return GeneratedProtocol.FrameRejectionReason.decodeFailure.rawValue
        case .outOfTransactionCommand: return GeneratedProtocol.FrameRejectionReason.outOfTransactionCommand.rawValue
        case .invalidRowSplice: return GeneratedProtocol.FrameRejectionReason.invalidRowSplice.rawValue
        case .resourcePolicy: return GeneratedProtocol.FrameRejectionReason.resourcePolicy.rawValue
        }
    }

    /// Resource-policy rejection is terminal by default; lineage failures recover.
    var disposition: GeneratedProtocol.FrameRejectionDisposition {
        switch self {
        case .resourcePolicy: return .terminalFrontendFailure
        default: return .retryableRecovery
        }
    }

    var logDescription: String {
        switch self {
        case .beginWhileOpen(let open, let incoming):
            return "begin_frame \(incoming) while frame \(open) was open"
        case .commitWithoutBegin(let frameSeq):
            return "commit_frame \(frameSeq) with no open transaction"
        case .commitSequenceMismatch(let open, let commit):
            return "commit_frame seq \(commit) != open begin seq \(open)"
        case .frameSequenceNotIncreasing(let last, let incoming):
            return "frame_seq \(incoming) is not newer than \(last)"
        case .baseSequenceMismatch(let expected, let actual):
            return "base_frame_seq \(actual) != last committed \(expected)"
        case .missingTheme:
            return "missing gui_theme in keyframe"
        case .incompleteTheme(let slots):
            let formatted = slots.map { String(format: "0x%02X", $0) }.joined(separator: ", ")
            return "missing gui_theme slots: \(formatted)"
        case .missingWindowReference(let windowId):
            return "missing live window reference \(windowId)"
        case .windowEpochMismatch(let windowId, let expected, let actual):
            return "window \(windowId) epoch \(actual) != \(expected)"
        case .invalidRetainedRows(let windowId, let epoch):
            return "window \(windowId) has invalid retained rows for epoch \(epoch)"
        case .invalidRowSplice(let windowId, let epoch):
            return "window \(windowId) has an invalid row splice for epoch \(epoch)"
        case .missingFontResource(let fontId):
            return "missing font resource \(fontId)"
        case .transcriptBeforeSeed:
            return "agent transcript append before seed"
        case .transcriptEpochMismatch:
            return "agent transcript epoch mismatch"
        case .transcriptDesynced:
            return "agent transcript append desynced"
        case .decodeFailure(let frameSeq):
            return "decode failure in frame \(frameSeq)"
        case .outOfTransactionCommand:
            return "out-of-transaction command"
        case .resourcePolicy:
            return "frontend resource policy exceeded"
        }
    }
}

/// Instrumentation describes publication cost in domain operations, not commands.
struct PreparedFrameOperationCounts: Sendable, Equatable {
    let theme: Int
    let windows: Int
    let chrome: Int
    let overlays: Int
    let resources: Int
    let focus: Int
    let metadata: Int

    var total: Int { theme + windows + chrome + overlays + resources + focus + metadata }
}

struct PreparedThemeUpdate: Sendable {
    let slots: [(slotId: UInt8, r: UInt8, g: UInt8, b: UInt8)]
}

struct PreparedWindowUpdates: Sendable {
    let replacements: [UInt16: GUIWindowContent]
    let touchedWindowIds: Set<UInt16>
    let authoritativeWindowIds: Set<UInt16>?
    let commands: [RenderCommand]
}

struct PreparedChromeUpdates {
    let commands: [RenderCommand]
    let transcript: AgentTranscriptSnapshot?
}
struct PreparedOverlayUpdates: Sendable { let commands: [RenderCommand] }
struct PreparedResourceUpdates: Sendable { let commands: [RenderCommand] }
struct PreparedFocusUpdates: Sendable { let commands: [RenderCommand] }
struct PreparedMetadataUpdates: Sendable { let commands: [RenderCommand] }

/// Frozen transaction. All references, epochs, resources, and keyframe
/// requirements have been validated before this value can be created.
struct PreparedFrameTransaction {
    let frameSeq: UInt32
    let baseFrameSeq: UInt32
    let generation: UInt32
    let theme: PreparedThemeUpdate?
    let windows: PreparedWindowUpdates?
    let chrome: PreparedChromeUpdates?
    let overlays: PreparedOverlayUpdates?
    let resources: PreparedResourceUpdates?
    let focus: PreparedFocusUpdates?
    let metadata: PreparedMetadataUpdates?
    let operationCounts: PreparedFrameOperationCounts
}

/// Coalesces repeated updates to the same semantic state during staging. This is
/// what makes commit independent of decoded command count: each affected state
/// appears at most once in its prepared domain (per window/resource where keyed).
private enum PreparedWindowCommandKind: Hashable {
    case gutter
    case indentGuides
}

private enum PreparedCoalescingKey: Hashable {
    case command(Int)
    case window(kind: PreparedWindowCommandKind, id: UInt16)
    case font(UInt8)
    case appended(Int)
}

private struct PreparedDomainBuffer {
    private var order: [PreparedCoalescingKey] = []
    private var commandsByKey: [PreparedCoalescingKey: RenderCommand] = [:]
    private var nextAppendKey = 0

    var isEmpty: Bool { order.isEmpty }
    var commands: [RenderCommand] { order.compactMap { commandsByKey[$0] } }

    mutating func replace(_ command: RenderCommand, key: PreparedCoalescingKey) {
        if commandsByKey[key] == nil { order.append(key) }
        commandsByKey[key] = command
    }

    mutating func append(_ command: RenderCommand) {
        let key = PreparedCoalescingKey.appended(nextAppendKey)
        order.append(key)
        commandsByKey[key] = command
        nextAppendKey += 1
    }
}

/// Mutable value builder owned only by CommandDispatcher while a frame is open.
@MainActor
struct PreparedFrameTransactionBuilder {
    let frameSeq: UInt32
    let baseFrameSeq: UInt32
    let generation: UInt32

    private var theme: PreparedThemeUpdate?
    private var workingWindows: [UInt16: GUIWindowContent]
    private var changedWindows: [UInt16: GUIWindowContent] = [:]
    private var referencedWindowIds: Set<UInt16> = []
    private var touchedWindowIds: Set<UInt16> = []
    private var windowCommands = PreparedDomainBuffer()
    private var chromeCommands = PreparedDomainBuffer()
    private var overlayCommands = PreparedDomainBuffer()
    private var resourceCommands = PreparedDomainBuffer()
    private var focusCommands = PreparedDomainBuffer()
    private var metadataCommands = PreparedDomainBuffer()
    private var registeredFontIds: Set<UInt8>
    private var requiredFontIds: Set<UInt8> = []
    private var workingTranscript: AgentTranscriptSnapshot
    private var changedTranscript: AgentTranscriptSnapshot?
    private var rejection: PreparedFrameRejection?
    private let stagingLimit: FrameResourceWeight
    private let residentLimit: FrameResourceWeight

    init(
        frameSeq: UInt32,
        baseFrameSeq: UInt32,
        generation: UInt32,
        committedWindows: [UInt16: GUIWindowContent],
        registeredFontIds: Set<UInt8>,
        committedTranscript: AgentTranscriptSnapshot,
        stagingLimit: FrameResourceWeight = FrameResourcePolicy.default.staging.weight,
        residentLimit: FrameResourceWeight = FrameResourcePolicy.default.resident.weightPerWindow
    ) {
        self.frameSeq = frameSeq
        self.baseFrameSeq = baseFrameSeq
        self.generation = generation
        self.workingWindows = baseFrameSeq == 0 ? [:] : committedWindows
        self.registeredFontIds = registeredFontIds
        self.registeredFontIds.insert(0)
        self.workingTranscript = committedTranscript
        self.stagingLimit = stagingLimit
        self.residentLimit = residentLimit
    }

    mutating func stage(_ command: RenderCommand) {
        switch command {
        case .guiTheme(let slots):
            theme = PreparedThemeUpdate(slots: slots)

        case .guiWindowContent(let content):
            guard content.rowStore.validateInvariants() else {
                rejection = .invalidRetainedRows(
                    windowId: content.windowId,
                    contentEpoch: content.contentEpoch
                )
                return
            }
            let aggregated = aggregatingOperationCounters(for: content)
            guard stageWindow(aggregated) else { return }
            touchedWindowIds.insert(content.windowId)
            recordFontResources(in: content)

        case .guiWindowOverlayDelta(let delta):
            resolveOverlayDelta(delta)

        case .guiWindowViewportDelta(let delta), .guiWindowRowsDelta(let delta):
            resolveRowsDelta(delta)

        case .guiGutter(let data):
            referencedWindowIds.insert(data.windowId)
            touchedWindowIds.insert(data.windowId)
            windowCommands.replace(command, key: .window(kind: .gutter, id: data.windowId))

        case .guiIndentGuides(let data):
            referencedWindowIds.insert(data.windowId)
            touchedWindowIds.insert(data.windowId)
            windowCommands.replace(command, key: .window(kind: .indentGuides, id: data.windowId))

        case .setFont, .setFontFallback, .guiConfigState:
            resourceCommands.replace(command, key: .command(command.preparedUpdateKey))

        case .registerFont(let id, _):
            registeredFontIds.insert(id)
            resourceCommands.replace(command, key: .font(id))

        case .setCursorShape, .setLinkCursor, .guiFileTreeSelection:
            focusCommands.replace(command, key: .command(command.preparedUpdateKey))

        case .guiCompletion, .guiWhichKey, .guiPicker, .guiPickerPreview,
             .guiAgentChat, .guiMinibuffer, .guiHoverPopup, .guiHoverAction,
             .guiSignatureHelp, .guiFloatPopup, .guiExtensionOverlay,
             .guiSearchState, .guiEmptyState, .protocolError:
            overlayCommands.replace(command, key: .command(command.preparedUpdateKey))

        case .setTitle, .setWindowBg, .guiGutterSeparator, .guiCursorline,
             .guiLineSpacing, .guiCursorAnimation, .guiSplitSeparators,
             .guiStatusBar, .clipboardWrite:
            metadataCommands.replace(command, key: .command(command.preparedUpdateKey))

        case .guiAgentTranscript(let mode, let epoch, let truncated, let trimFront, let baseCount, let messages):
            guard rejection == nil else { return }
            switch AgentChatState.prepareTranscript(
                from: workingTranscript,
                mode: mode,
                epoch: epoch,
                truncated: truncated,
                trimFront: Int(trimFront),
                baseCount: Int(baseCount),
                messages: messages
            ) {
            case .success(let prepared):
                workingTranscript = prepared
                changedTranscript = prepared
            case .failure(.beforeSeed):
                rejection = .transcriptBeforeSeed
            case .failure(.epochMismatch):
                rejection = .transcriptEpochMismatch
            case .failure(.desynced):
                rejection = .transcriptDesynced
            }

        case .guiBottomPanel, .guiExtensionRuntime:
            // These carry append/upsert semantics; every payload is meaningful.
            chromeCommands.append(command)

        case .guiTabBar, .guiFileTree, .guiObservatory, .guiBreadcrumb,
             .guiToolManager, .guiGitStatus, .guiWorkspaces, .guiAgentContext,
             .guiChangeSummary, .guiNotifications, .guiEditTimeline,
             .guiExtensionPanel, .guiSidebars:
            chromeCommands.replace(command, key: .command(command.preparedUpdateKey))

        case .beginFrame, .commitFrame:
            break
        }
    }

    func freeze(requiredThemeSlots: [UInt8]) -> Result<PreparedFrameTransaction, PreparedFrameRejection> {
        if let rejection { return .failure(rejection) }

        if baseFrameSeq == 0, theme == nil { return .failure(.missingTheme) }
        if let theme {
            let present = Set(theme.slots.map(\.slotId))
            let missing = requiredThemeSlots.filter { !present.contains($0) }
            if !missing.isEmpty { return .failure(.incompleteTheme(missingSlots: missing)) }
        }

        let liveWindowIds = Set(workingWindows.keys)
        if let missingReference = referencedWindowIds.subtracting(liveWindowIds).min() {
            return .failure(.missingWindowReference(windowId: missingReference))
        }
        if let missingFont = requiredFontIds.subtracting(registeredFontIds).min() {
            return .failure(.missingFontResource(fontId: missingFont))
        }

        let windowsChanged = !changedWindows.isEmpty || !windowCommands.isEmpty || baseFrameSeq == 0
        let transaction = PreparedFrameTransaction(
            frameSeq: frameSeq,
            baseFrameSeq: baseFrameSeq,
            generation: generation,
            theme: theme,
            windows: windowsChanged ? PreparedWindowUpdates(
                replacements: changedWindows,
                touchedWindowIds: touchedWindowIds,
                authoritativeWindowIds: baseFrameSeq == 0 ? liveWindowIds : nil,
                commands: windowCommands.commands
            ) : nil,
            chrome: chromeCommands.isEmpty && changedTranscript == nil ? nil : PreparedChromeUpdates(
                commands: chromeCommands.commands,
                transcript: changedTranscript
            ),
            overlays: overlayCommands.isEmpty ? nil : PreparedOverlayUpdates(commands: overlayCommands.commands),
            resources: resourceCommands.isEmpty ? nil : PreparedResourceUpdates(commands: resourceCommands.commands),
            focus: focusCommands.isEmpty ? nil : PreparedFocusUpdates(commands: focusCommands.commands),
            metadata: metadataCommands.isEmpty ? nil : PreparedMetadataUpdates(commands: metadataCommands.commands),
            operationCounts: PreparedFrameOperationCounts(
                theme: theme == nil ? 0 : 1,
                windows: windowsChanged ? 1 : 0,
                chrome: chromeCommands.isEmpty && changedTranscript == nil ? 0 : 1,
                overlays: overlayCommands.isEmpty ? 0 : 1,
                resources: resourceCommands.isEmpty ? 0 : 1,
                focus: focusCommands.isEmpty ? 0 : 1,
                metadata: metadataCommands.isEmpty ? 0 : 1
            )
        )
        return .success(transaction)
    }

    private mutating func resolveOverlayDelta(_ delta: GUIWindowOverlayDelta) {
        touchedWindowIds.insert(delta.windowId)
        guard rejection == nil else { return }
        guard let current = workingWindows[delta.windowId] else {
            rejection = .missingWindowReference(windowId: delta.windowId)
            return
        }
        guard current.contentEpoch == delta.contentEpoch else {
            rejection = .windowEpochMismatch(
                windowId: delta.windowId,
                expected: current.contentEpoch,
                actual: delta.contentEpoch
            )
            return
        }
        guard let updated = current.applyingOverlayDelta(delta) else {
            rejection = .windowEpochMismatch(
                windowId: delta.windowId,
                expected: current.contentEpoch,
                actual: delta.contentEpoch
            )
            return
        }
        let aggregated = aggregatingOperationCounters(for: updated)
        _ = stageWindow(aggregated)
    }

    private mutating func resolveRowsDelta(_ delta: GUIWindowRowsDelta) {
        touchedWindowIds.insert(delta.windowId)
        guard rejection == nil else { return }
        guard let current = workingWindows[delta.windowId] else {
            rejection = .missingWindowReference(windowId: delta.windowId)
            return
        }
        guard current.contentEpoch == delta.contentEpoch else {
            rejection = .windowEpochMismatch(
                windowId: delta.windowId,
                expected: current.contentEpoch,
                actual: delta.contentEpoch
            )
            return
        }
        let updated: GUIWindowContent
        switch current.applyingRowsDeltaChecked(
            delta, residentLimit: residentLimit, stagingLimit: stagingLimit
        ) {
        case .success(let content):
            updated = content
        case .failure(.missingRowID), .failure(.contentHashMismatch):
            rejection = .missingWindowReference(windowId: delta.windowId)
            return
        case .failure(.resourcePolicy):
            rejection = .resourcePolicy
            return
        case .failure:
            rejection = delta.rowSplices == nil
                ? .invalidRetainedRows(windowId: delta.windowId, contentEpoch: delta.contentEpoch)
                : .invalidRowSplice(windowId: delta.windowId, contentEpoch: delta.contentEpoch)
            return
        }
        let aggregated = aggregatingOperationCounters(for: updated)
        guard stageWindow(aggregated) else { return }
        recordFontResources(in: delta)
    }

    private mutating func stageWindow(_ content: GUIWindowContent) -> Bool {
        do {
            let residentWeight = content.exactResourceWeight()
            if residentWeight.firstExceeded(limit: residentLimit) != nil {
                rejection = .resourcePolicy
                return false
            }
            var stagingWeight = FrameResourceWeight()
            for (windowID, existing) in workingWindows where windowID != content.windowId {
                stagingWeight = try stagingWeight.adding(existing.exactResourceWeight())
            }
            stagingWeight = try stagingWeight.adding(residentWeight)
            if stagingWeight.firstExceeded(limit: stagingLimit) != nil {
                rejection = .resourcePolicy
                return false
            }
            workingWindows[content.windowId] = content
            changedWindows[content.windowId] = content
            return true
        } catch {
            rejection = .resourcePolicy
            return false
        }
    }

    private func aggregatingOperationCounters(for content: GUIWindowContent) -> GUIWindowContent {
        let prior = changedWindows[content.windowId]?.rowStoreOperationCounters ?? .init()
        return content.reportingOperationCounters(prior + content.rowStoreOperationCounters)
    }

    private mutating func recordFontResources(in content: GUIWindowContent) {
        let allRows = content.rowStore.rows(in: 0..<content.rowStore.count).rows
        for row in allRows {
            recordFontResources(in: row)
        }
    }

    private mutating func recordFontResources(in delta: GUIWindowRowsDelta) {
        for entry in delta.rows {
            if case .full(let row) = entry { recordFontResources(in: row) }
        }
        for splice in delta.rowSplices ?? [] {
            for entry in splice.insertEntries {
                if case .full(let row) = entry { recordFontResources(in: row) }
            }
        }
    }

    private mutating func recordFontResources(in row: GUIVisualRow) {
        for span in row.spans where span.fontId != 0 {
            requiredFontIds.insert(span.fontId)
        }
    }
}

private extension RenderCommand {
    /// Stable semantic key used only within a prepared domain. Repeated payloads
    /// for the same state replace earlier payloads while staging.
    var preparedUpdateKey: Int {
        switch self {
        case .beginFrame: 1
        case .commitFrame: 2
        case .setCursorShape: 3
        case .setTitle: 4
        case .setWindowBg: 5
        case .setLinkCursor: 6
        case .protocolError: 7
        case .setFont: 8
        case .setFontFallback: 9
        case .registerFont: 10
        case .guiTheme: 11
        case .guiTabBar: 12
        case .guiFileTree: 13
        case .guiFileTreeSelection: 14
        case .guiObservatory: 15
        case .guiCompletion: 16
        case .guiWhichKey: 17
        case .guiBreadcrumb: 18
        case .guiStatusBar: 19
        case .guiPicker: 20
        case .guiPickerPreview: 21
        case .guiAgentChat: 22
        case .guiAgentTranscript: 23
        case .guiGutterSeparator: 24
        case .guiCursorline: 25
        case .guiGutter: 26
        case .guiBottomPanel: 27
        case .guiWindowContent: 28
        case .guiWindowOverlayDelta: 29
        case .guiWindowViewportDelta: 30
        case .guiWindowRowsDelta: 31
        case .guiToolManager: 32
        case .guiMinibuffer: 33
        case .guiHoverPopup: 34
        case .guiHoverAction: 35
        case .guiSignatureHelp: 36
        case .guiFloatPopup: 37
        case .clipboardWrite: 38
        case .guiIndentGuides: 39
        case .guiLineSpacing: 40
        case .guiCursorAnimation: 41
        case .guiSplitSeparators: 42
        case .guiGitStatus: 43
        case .guiWorkspaces: 44
        case .guiAgentContext: 45
        case .guiChangeSummary: 46
        case .guiConfigState: 47
        case .guiNotifications: 48
        case .guiEditTimeline: 49
        case .guiExtensionOverlay: 50
        case .guiExtensionPanel: 51
        case .guiExtensionRuntime: 52
        case .guiSearchState: 53
        case .guiSidebars: 54
        case .guiEmptyState: 55
        }
    }
}
