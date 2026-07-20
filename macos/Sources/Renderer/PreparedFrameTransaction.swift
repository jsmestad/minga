/// Value-semantic frame preparation and validation.
///
/// Commands are classified while a frame is staged. Window deltas are resolved
/// against the last-good snapshot immediately, so publication never has to scan
/// the command stream or look up a live reference that was not validated first.

import Foundation
import MingaProtocol
import MingaUI

extension GUIFrameImpact {
    /// Exhaustive semantic dependency graph from protocol commands to consumer regions.
    static func impact(for command: RenderCommand) -> GUIFrameImpact {
        switch command {
        case .guiTheme:
            return .all

        case .guiWindowContent, .guiWindowOverlayDelta, .guiWindowViewportDelta,
             .guiWindowRowsDelta, .guiLineSpacing, .setFont, .setFontFallback,
             .registerFont:
            return [.editor, .editorOverlay]

        case .setCursorShape, .setLinkCursor, .guiGutterSeparator, .guiCursorline,
             .guiGutter, .guiIndentGuides, .guiCursorAnimation,
             .guiSplitSeparators, .guiAgentTranscript:
            return .editor

        case .guiCompletion, .guiHoverPopup, .guiHoverAction, .guiSignatureHelp,
             .guiExtensionOverlay:
            return .editorOverlay

        case .guiWhichKey, .guiPicker, .guiPickerPreview, .guiFloatPopup,
             .guiNotifications, .guiExtensionRuntime, .protocolError:
            return .windowOverlay

        case .guiTabBar, .guiFileTree, .guiFileTreeSelection, .guiObservatory,
             .guiBreadcrumb, .guiGitStatus, .guiWorkspaces, .guiAgentContext,
             .guiChangeSummary, .guiEditTimeline, .guiMinibuffer,
             .guiSearchState, .guiSidebars:
            return .shell

        case .guiStatusBar, .guiAgentChat, .guiEmptyState:
            return [.shell, .editor]

        case .guiBottomPanel, .guiExtensionPanel:
            return [.shell, .windowOverlay]

        case .beginFrame, .commitFrame, .setTitle, .setWindowBg,
             .clipboardWrite, .guiConfigState:
            return []
        }
    }
}

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
    /// Final consumer impact, including effects introduced while freezing the transaction.
    let impact: GUIFrameImpact
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

private enum PreparedDomain {
    case window
    case chrome
    case overlay
    case resource
    case focus
    case metadata
}

private struct PreparedDomainBuffer {
    private var order: [PreparedCoalescingKey] = []
    private var commandsByKey: [PreparedCoalescingKey: RenderCommand] = [:]
    private var weightsByKey: [PreparedCoalescingKey: FrameResourceWeight] = [:]
    private var nextAppendKey = 0

    var isEmpty: Bool { order.isEmpty }
    var commands: [RenderCommand] { order.compactMap { commandsByKey[$0] } }

    func weight(for key: PreparedCoalescingKey) -> FrameResourceWeight {
        weightsByKey[key] ?? FrameResourceWeight()
    }

    mutating func replace(
        _ command: RenderCommand, key: PreparedCoalescingKey,
        weight: FrameResourceWeight
    ) {
        if commandsByKey[key] == nil { order.append(key) }
        commandsByKey[key] = command
        weightsByKey[key] = weight
    }

    mutating func append(_ command: RenderCommand, weight: FrameResourceWeight) {
        let key = PreparedCoalescingKey.appended(nextAppendKey)
        order.append(key)
        commandsByKey[key] = command
        weightsByKey[key] = weight
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
    private var semanticImpact: GUIFrameImpact = []
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
    private var themeWeight = FrameResourceWeight()
    private var transcriptWeight = FrameResourceWeight()
    private var stagingWeight = FrameResourceWeight()
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

        do {
            transcriptWeight = try committedTranscript.exactResourceWeight()
            stagingWeight = transcriptWeight
            for content in workingWindows.values {
                stagingWeight = try stagingWeight.adding(content.exactResourceWeight())
            }
            if stagingWeight.firstExceeded(limit: stagingLimit) != nil {
                rejection = .resourcePolicy
            }
        } catch {
            rejection = .resourcePolicy
        }
    }

    mutating func stage(
        _ command: RenderCommand,
        resourceWeight: FrameResourceWeight = FrameResourceWeight(commands: 1)
    ) {
        guard rejection == nil else { return }
        semanticImpact.formUnion(GUIFrameImpact.impact(for: command))
        switch command {
        case .guiTheme(let slots):
            guard replaceStagingWeight(removing: themeWeight, adding: resourceWeight) else { return }
            themeWeight = resourceWeight
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
            stageReplacing(
                command, key: .window(kind: .gutter, id: data.windowId),
                weight: resourceWeight, domain: .window
            )

        case .guiIndentGuides(let data):
            referencedWindowIds.insert(data.windowId)
            touchedWindowIds.insert(data.windowId)
            stageReplacing(
                command, key: .window(kind: .indentGuides, id: data.windowId),
                weight: resourceWeight, domain: .window
            )

        case .setFont, .setFontFallback, .guiConfigState:
            stageReplacing(
                command, key: .command(command.preparedUpdateKey),
                weight: resourceWeight, domain: .resource
            )

        case .registerFont(let id, _):
            registeredFontIds.insert(id)
            stageReplacing(command, key: .font(id), weight: resourceWeight, domain: .resource)

        case .setCursorShape, .setLinkCursor, .guiFileTreeSelection:
            stageReplacing(
                command, key: .command(command.preparedUpdateKey),
                weight: resourceWeight, domain: .focus
            )

        case .guiCompletion, .guiWhichKey, .guiPicker, .guiPickerPreview,
             .guiAgentChat, .guiMinibuffer, .guiHoverPopup, .guiHoverAction,
             .guiSignatureHelp, .guiFloatPopup, .guiExtensionOverlay,
             .guiSearchState, .guiEmptyState, .protocolError:
            stageReplacing(
                command, key: .command(command.preparedUpdateKey),
                weight: resourceWeight, domain: .overlay
            )

        case .setTitle, .setWindowBg, .guiGutterSeparator, .guiCursorline,
             .guiLineSpacing, .guiCursorAnimation, .guiSplitSeparators,
             .guiStatusBar, .clipboardWrite:
            stageReplacing(
                command, key: .command(command.preparedUpdateKey),
                weight: resourceWeight, domain: .metadata
            )

        case .guiAgentTranscript(let mode, let epoch, let truncated, let trimFront, let baseCount, let messages):
            stageTranscript(
                mode: mode, epoch: epoch, truncated: truncated,
                trimFront: Int(trimFront), baseCount: Int(baseCount), messages: messages
            )

        case .guiBottomPanel, .guiExtensionRuntime:
            // These carry append/upsert semantics; every payload is meaningful.
            stageAppending(command, weight: resourceWeight, domain: .chrome)

        case .guiTabBar, .guiFileTree, .guiObservatory, .guiBreadcrumb,
             .guiGitStatus, .guiWorkspaces, .guiAgentContext,
             .guiChangeSummary, .guiNotifications, .guiEditTimeline,
             .guiExtensionPanel, .guiSidebars:
            stageReplacing(
                command, key: .command(command.preparedUpdateKey),
                weight: resourceWeight, domain: .chrome
            )

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
        var finalImpact = semanticImpact
        if windowsChanged {
            // Includes authoritative pruning, pane geometry, scroll reset, and
            // local AppKit scroll-presentation discard performed during promotion.
            finalImpact.formUnion([.editor, .editorOverlay])
        }
        let transaction = PreparedFrameTransaction(
            frameSeq: frameSeq,
            baseFrameSeq: baseFrameSeq,
            generation: generation,
            impact: finalImpact,
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

    private mutating func stageTranscript(
        mode: UInt8, epoch: UInt32, truncated: Bool,
        trimFront: Int, baseCount: Int, messages: [Wire.ChatMessage]
    ) {
        let nextTranscriptWeight: FrameResourceWeight
        let nextStagingWeight: FrameResourceWeight
        do {
            nextTranscriptWeight = try workingTranscript.resourceWeightAfterPreparing(
                mode: mode, epoch: epoch, trimFront: trimFront,
                baseCount: baseCount, messages: messages
            )
            nextStagingWeight = try prospectiveStagingWeight(
                removing: transcriptWeight, adding: nextTranscriptWeight
            )
            guard nextStagingWeight.firstExceeded(limit: stagingLimit) == nil else {
                rejection = .resourcePolicy
                return
            }
        } catch let failure as AgentTranscriptPreparationFailure {
            switch failure {
            case .beforeSeed: rejection = .transcriptBeforeSeed
            case .epochMismatch: rejection = .transcriptEpochMismatch
            case .desynced: rejection = .transcriptDesynced
            }
            return
        } catch {
            rejection = .resourcePolicy
            return
        }

        switch AgentChatState.prepareTranscript(
            from: workingTranscript, mode: mode, epoch: epoch,
            truncated: truncated, trimFront: trimFront,
            baseCount: baseCount, messages: messages
        ) {
        case .success(let prepared):
            stagingWeight = nextStagingWeight
            transcriptWeight = nextTranscriptWeight
            workingTranscript = prepared
            changedTranscript = prepared
        case .failure(.beforeSeed): rejection = .transcriptBeforeSeed
        case .failure(.epochMismatch): rejection = .transcriptEpochMismatch
        case .failure(.desynced): rejection = .transcriptDesynced
        }
    }

    private mutating func stageReplacing(
        _ command: RenderCommand, key: PreparedCoalescingKey,
        weight: FrameResourceWeight, domain: PreparedDomain
    ) {
        let previousWeight = domainWeight(domain, key: key)
        guard replaceStagingWeight(removing: previousWeight, adding: weight) else { return }
        replaceDomainCommand(command, key: key, weight: weight, domain: domain)
    }

    private mutating func stageAppending(
        _ command: RenderCommand, weight: FrameResourceWeight, domain: PreparedDomain
    ) {
        guard replaceStagingWeight(removing: FrameResourceWeight(), adding: weight) else { return }
        switch domain {
        case .chrome: chromeCommands.append(command, weight: weight)
        case .window, .overlay, .resource, .focus, .metadata:
            rejection = .resourcePolicy
        }
    }

    private func domainWeight(
        _ domain: PreparedDomain, key: PreparedCoalescingKey
    ) -> FrameResourceWeight {
        switch domain {
        case .window: windowCommands.weight(for: key)
        case .chrome: chromeCommands.weight(for: key)
        case .overlay: overlayCommands.weight(for: key)
        case .resource: resourceCommands.weight(for: key)
        case .focus: focusCommands.weight(for: key)
        case .metadata: metadataCommands.weight(for: key)
        }
    }

    private mutating func replaceDomainCommand(
        _ command: RenderCommand, key: PreparedCoalescingKey,
        weight: FrameResourceWeight, domain: PreparedDomain
    ) {
        switch domain {
        case .window: windowCommands.replace(command, key: key, weight: weight)
        case .chrome: chromeCommands.replace(command, key: key, weight: weight)
        case .overlay: overlayCommands.replace(command, key: key, weight: weight)
        case .resource: resourceCommands.replace(command, key: key, weight: weight)
        case .focus: focusCommands.replace(command, key: key, weight: weight)
        case .metadata: metadataCommands.replace(command, key: key, weight: weight)
        }
    }

    private func prospectiveStagingWeight(
        removing previousWeight: FrameResourceWeight,
        adding nextWeight: FrameResourceWeight
    ) throws -> FrameResourceWeight {
        try stagingWeight.subtracting(previousWeight).adding(nextWeight)
    }

    private mutating func replaceStagingWeight(
        removing previousWeight: FrameResourceWeight,
        adding nextWeight: FrameResourceWeight
    ) -> Bool {
        do {
            let prospective = try prospectiveStagingWeight(
                removing: previousWeight, adding: nextWeight
            )
            guard prospective.firstExceeded(limit: stagingLimit) == nil else {
                rejection = .resourcePolicy
                return false
            }
            stagingWeight = prospective
            return true
        } catch {
            rejection = .resourcePolicy
            return false
        }
    }

    private mutating func stageWindow(_ content: GUIWindowContent) -> Bool {
        let residentWeight = content.exactResourceWeight()
        if residentWeight.firstExceeded(limit: residentLimit) != nil {
            rejection = .resourcePolicy
            return false
        }
        let previousWeight = workingWindows[content.windowId]?.exactResourceWeight()
            ?? FrameResourceWeight()
        guard replaceStagingWeight(
            removing: previousWeight, adding: residentWeight
        ) else { return false }
        workingWindows[content.windowId] = content
        changedWindows[content.windowId] = content
        return true
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
