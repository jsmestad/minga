/// Decodes binary render commands from the BEAM into Swift enums.
///
/// Each command starts with a 1-byte opcode followed by opcode-specific
/// fields. Multi-byte integers are big-endian. See `docs/PROTOCOL.md`.
///
/// Data types live in `ProtocolTypes.swift` under the `Wire` namespace.
/// This file contains only the `RenderCommand` enum, decode functions,
/// and private helpers.

import Foundation
import MingaProtocol

// `StatusBarUpdate` and its nested types moved to StatusBarUpdate.swift in the
// MingaProtocol framework. The decoder still constructs it below.

// MARK: - Render command types

/// A decoded render command from the BEAM.
enum RenderCommand: Sendable {
    /// Opens a frame transaction (#2219): frame_seq is the strictly monotonic
    /// global frame sequence; baseFrameSeq names the frame this transaction's
    /// deltas assume (0 means keyframe). Decoded but ignored for now; staging on
    /// begin/commit lands in a later child.
    ///
    /// The cell-paradigm render commands (clear, draw_text, draw_styled_text,
    /// set_cursor, and the region commands) were retired in protocol_version 2;
    /// all content now flows through gui_window_content (0x80) and the dedicated
    /// gui_* semantic opcodes.
    case beginFrame(frameSeq: UInt32, baseFrameSeq: UInt32, generation: UInt32)
    /// Closes a frame transaction (#2219): frameSeq matches the open begin_frame;
    /// seq is the echoed input correlation sequence (ticket #2215, formerly carried
    /// by batch_end). The frontend presents the frame and resolves keystroke latency
    /// here. 0 means "no correlation".
    case commitFrame(frameSeq: UInt32, seq: UInt32)
    case setCursorShape(CursorShape)
    case setTitle(String)
    case setWindowBg(r: UInt8, g: UInt8, b: UInt8)
    /// set_link_cursor (0x19, #2630): toggles the go-to-definition pointing-hand
    /// cursor while a Cmd+hover link preview is shown. `active` is the 1-byte body.
    case setLinkCursor(active: Bool)
    /// protocol_error (0x18): the BEAM rejected this frontend's handshake
    /// protocol_version, so it carries a UTF-8 reason the frontend shows as a
    /// blocking error instead of decoding a stream it cannot parse (ticket
    /// #2237). Wire format: opcode(1) + len(u16) + UTF-8 message.
    case protocolError(message: String)
    case setFont(family: String, size: UInt16, ligatures: Bool, weight: UInt8)
    case setFontFallback(families: [String])
    case registerFont(id: UInt8, family: String)
    case guiTheme(slots: [(slotId: UInt8, r: UInt8, g: UInt8, b: UInt8)])
    case guiTabBar(activeIndex: UInt8, tabs: [Wire.TabEntry])
    case guiFileTree(version: UInt8, treeFlags: UInt8, treeState: UInt8, selectedId: String, treeWidth: UInt16, rootPath: String, errorReason: String, entries: [Wire.FileTreeEntry])
    case guiFileTreeSelection(selectedId: String, focused: Bool)
    case guiObservatory(visible: Bool, nodeCount: UInt16, nodes: [Wire.ObservatoryNode])
    case guiCompletion(visible: Bool, anchorRow: UInt16, anchorCol: UInt16, selectedIndex: UInt16, items: [Wire.CompletionItem], documentation: String)
    case guiWhichKey(visible: Bool, prefix: String, page: UInt8, pageCount: UInt8, bindings: [Wire.WhichKeyBinding])
    case guiBreadcrumb(segments: [String])
    case guiStatusBar(StatusBarUpdate)
    case guiPicker(visible: Bool, selectedIndex: UInt16, filteredCount: UInt16, totalCount: UInt16, markedCount: UInt16, title: String, query: String, hasPreview: Bool, items: [Wire.PickerItem], actionMenu: Wire.PickerActionMenu?, modePrefix: String, loadStatus: Wire.PickerLoadStatus)
    case guiPickerPreview(visible: Bool, lines: [Wire.PickerPreviewLine])
    case guiAgentChat(visible: Bool, status: UInt8, model: String, thinkingLevel: String, prompt: String, promptLineCount: UInt8, promptCursorLine: UInt16, promptCursorCol: UInt16, promptVimMode: UInt8, promptVisibleRows: UInt8, promptCompletion: Wire.PromptCompletion?, pendingToolName: String?, pendingToolSummary: String, helpVisible: Bool, helpGroups: [Wire.HelpGroup], messages: [Wire.ChatMessage])
    /// Resident agent-chat transcript stream (0x86, #2654). `mode` is 0=full_replace, 1=append.
    /// `truncated` marks older messages sitting outside the resident byte-cap window. On append,
    /// `trimFront` messages are first evicted from the store front, then over the remainder
    /// `baseCount` unchanged-leading messages are kept and the `count` entries are upserted;
    /// `baseCount` is the content-hash prefix of the remainder, NOT the client's resident count.
    /// full_replace carries `trimFront`/`baseCount` as 0. Each message carries its stable id in
    /// `beamId`; bodies use the shared 0x78 codec.
    case guiAgentTranscript(mode: UInt8, epoch: UInt32, truncated: Bool, trimFront: UInt32, baseCount: UInt32, messages: [Wire.ChatMessage])
    case guiGutterSeparator(col: UInt16, r: UInt8, g: UInt8, b: UInt8)
    case guiCursorline(row: UInt16, r: UInt8, g: UInt8, b: UInt8)
    case guiGutter(data: Wire.WindowGutter)
    case guiBottomPanel(visible: Bool, activeTabIndex: UInt8, heightPercent: UInt8,
                         filterPreset: UInt8, tabs: [Wire.BottomPanelTab],
                         entries: [Wire.MessageEntry])
    case guiWindowContent(data: GUIWindowContent)
    case guiWindowOverlayDelta(data: GUIWindowOverlayDelta)
    case guiWindowViewportDelta(data: GUIWindowRowsDelta)
    case guiWindowRowsDelta(data: GUIWindowRowsDelta)
    case guiToolManager(visible: Bool, filter: UInt8, selectedIndex: UInt16, tools: [Wire.ToolEntry])
    case guiMinibuffer(visible: Bool, mode: UInt8, cursorPos: UInt16, prompt: String, input: String, context: String, selectedIndex: UInt16, totalCandidates: UInt16, candidates: [Wire.MinibufferCandidate])
    case guiHoverPopup(visible: Bool, anchorRow: UInt16, anchorCol: UInt16, focused: Bool, scrollOffset: UInt16, lines: [Wire.HoverLine])
    case guiHoverAction(visible: Bool, actionName: String)
    case guiSignatureHelp(visible: Bool, anchorRow: UInt16, anchorCol: UInt16, activeSignature: UInt8, activeParameter: UInt8, signatures: [Wire.Signature])
    case guiFloatPopup(visible: Bool, width: UInt16, height: UInt16, title: String, lines: [String])
    case clipboardWrite(target: UInt8, text: String)
    case guiIndentGuides(data: IndentGuideData)
    case guiLineSpacing(spacing: Float)
    case guiCursorAnimation(enabled: Bool)
    case guiSplitSeparators(borderColor: UInt32, verticals: [Wire.VerticalSeparator], horizontals: [Wire.HorizontalSeparator])
    case guiGitStatus(repoState: UInt8, syncing: Bool, ahead: UInt16, behind: UInt16, branchName: String, entries: [Wire.GitStatusEntry], toast: (message: String, level: UInt8, action: UInt8)?, entryBasePath: String, lastCommitMessage: String, stashCount: UInt16)
    case guiWorkspaces(version: UInt8, activeWorkspaceId: UInt16, mode: UInt8, flags: UInt8, workspaces: [Wire.WorkspaceEntry], visibleTabs: [Wire.WorkspaceTabEntry])
    case guiAgentContext(visible: Bool, task: String, dispatchTimestamp: Date, status: CardStatus, canApprove: Bool, progress: Wire.AgentProgress, todos: [Wire.AgentTodo])
    case guiChangeSummary(visible: Bool, entries: [ChangeSummaryEntry], selectedIndex: Int)
    case guiConfigState(Wire.ConfigState)
    case guiNotifications([Wire.EditorNotification])
    case guiEditTimeline(visible: Bool, viewingIndex: UInt16, entries: [Wire.TimelineEntry], files: [Wire.TimelineFile])
    case guiExtensionOverlay([Wire.ExtensionOverlayEntry])
    case guiExtensionPanel([Wire.ExtensionPanelEntry])
    case guiExtensionRuntime(FrontendExtensionRuntimeMessage)
    case guiSearchState(active: Bool, matchCount: UInt16, currentIndex: UInt16, flags: UInt8)
    case guiSidebars(version: UInt8, activeId: String, sidebars: [Wire.SidebarMetadata])
    /// gui_empty_state (0xA5): the launchpad shown when zero buffers are open.
    /// `visible` false means the launchpad is hidden (payload is a single byte);
    /// `crashed` marks an unclean previous shutdown. Static, data-driven sections
    /// (session/recent/start/footer) carry semantic rows the frontend lays out.
    case guiEmptyState(visible: Bool, crashed: Bool, version: String, focusedId: String, sections: [Wire.EmptyStateSection])
}

// MARK: - Decoder

indirect enum ProtocolDecodeError: Error, CustomStringConvertible, Sendable {
    case malformed
    case unknownOpcode(UInt8)
    case insufficientData
    case outOfBounds(offset: Int, required: Int, remaining: Int)
    case resource(FrameResourceError)
    case frameFailure(cause: ProtocolDecodeError, envelope: FrameEnvelope?)
    case commandFailed(opcode: UInt8, offset: Int, remaining: Int, cause: ProtocolDecodeError)

    var description: String {
        switch self {
        case .malformed:
            return "malformed"
        case .unknownOpcode(let opcode):
            return String(format: "unknown opcode 0x%02X", opcode)
        case .insufficientData:
            return "insufficient data"
        case .outOfBounds(let offset, let required, let remaining):
            return "out of bounds at offset \(offset) (required=\(required), remaining=\(remaining))"
        case .resource(let error):
            return "frame resource policy: \(error)"
        case .frameFailure(let cause, _):
            return cause.description
        case .commandFailed(let opcode, let offset, let remaining, let cause):
            return String(format: "opcode 0x%02X at offset %d failed with %@ (remaining=%d)", opcode, offset, String(describing: cause), remaining)
        }
    }

    var isResourceFailure: Bool {
        switch self {
        case .resource: true
        case .frameFailure(let cause, _), .commandFailed(_, _, _, let cause): cause.isResourceFailure
        default: false
        }
    }

    var frameEnvelope: FrameEnvelope? {
        if case .frameFailure(_, let envelope) = self { return envelope }
        return nil
    }

    var unwrappedFrameFailure: ProtocolDecodeError {
        if case .frameFailure(let cause, _) = self { return cause }
        return self
    }

    func contextualized(opcode: UInt8, offset: Int, remaining: Int) -> ProtocolDecodeError {
        switch self {
        case .commandFailed, .frameFailure:
            return self
        case .malformed, .unknownOpcode, .insufficientData, .outOfBounds, .resource:
            return .commandFailed(opcode: opcode, offset: offset, remaining: remaining, cause: self)
        }
    }
}

/// Decodes and validates one complete `{:packet, 4}` payload transactionally.
///
/// Command values are accumulated locally and become observable only after the
/// final byte succeeds. This prevents partial frame application when a later
/// command is malformed or unknown.
func decodeFrame(
    from data: Data,
    collectOwnedMetrics: Bool = false,
    policy: FrameResourcePolicy = .default,
    reservationProbe: FrameResourceUsageBuilder.ReservationProbe? = nil
) throws -> DecodedFrame {
    guard data.count <= policy.wire.payloadBytes else {
        throw ProtocolDecodeError.frameFailure(
            cause: .resource(.wirePayloadLimitExceeded(
                requested: data.count, limit: policy.wire.payloadBytes
            )),
            envelope: nil
        )
    }

    let usage = FrameResourceUsageBuilder(
        limit: policy.decode.weight, reservationProbe: reservationProbe
    )
    var envelope: FrameEnvelope?
    do {
        return try FrameDecodeAccounting.withUsage(
            usage, residentLimit: policy.resident.weightPerWindow
        ) {
            let clock = ContinuousClock()
            let started = clock.now
            var cursor = ByteCursor(data)
            var commands: [DecodedCommand] = []
            var ownedMetrics = DecoderOwnedMetrics()

            while !cursor.isAtEnd {
                let commandOffset = cursor.offset
                let opcode: UInt8
                do {
                    opcode = try cursor.readUInt8()
                    // Admission precedes command decoding and all command-owned materialization.
                    try usage.reserve(.commands, 1)
                } catch let error as FrameResourceError {
                    throw ProtocolDecodeError.resource(error)
                } catch let error as ByteCursor.BoundsError {
                    throw ProtocolDecodeError.outOfBounds(
                        offset: error.offset, required: error.required, remaining: error.remaining
                    )
                }

                let commandAndSize: (RenderCommand?, Int)
                do {
                    commandAndSize = try decodeCommand(data: data, offset: commandOffset)
                } catch let error as ProtocolDecodeError {
                    throw error.contextualized(
                        opcode: opcode, offset: commandOffset,
                        remaining: data.count - commandOffset
                    )
                } catch let error as FrameResourceError {
                    throw ProtocolDecodeError.resource(error).contextualized(
                        opcode: opcode, offset: commandOffset,
                        remaining: data.count - commandOffset
                    )
                }

                let (command, size) = commandAndSize
                guard size > 0 else { throw ProtocolDecodeError.malformed }
                do {
                    try cursor.advance(by: size - 1)
                } catch let error as ByteCursor.BoundsError {
                    throw ProtocolDecodeError.outOfBounds(
                        offset: error.offset, required: error.required, remaining: error.remaining
                    ).contextualized(
                        opcode: opcode, offset: commandOffset,
                        remaining: data.count - commandOffset
                    )
                }
                if let command {
                    if commandOffset == 0,
                       case .beginFrame(let frameSeq, let baseFrameSeq, let generation) = command {
                        envelope = FrameEnvelope(
                            generation: generation, frameSeq: frameSeq,
                            baseFrameSeq: baseFrameSeq
                        )
                    }
                    if collectOwnedMetrics { ownedMetrics.record(command) }
                    // Child-local scratch is published only after the complete command validated.
                    try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                    commands.append(DecodedCommand(command: command, opcode: opcode))
                }
            }

            if collectOwnedMetrics { ownedMetrics.recordFrameCommandStorage(count: commands.count) }
            return DecodedFrame(
                commands: commands,
                envelope: envelope,
                resourceWeight: usage.weight,
                metrics: FrameDecodeMetrics(
                    packetBytes: data.count,
                    bytesCopied: collectOwnedMetrics ? ownedMetrics.bytesCopied : -1,
                    allocations: collectOwnedMetrics ? ownedMetrics.allocations : -1,
                    decodeDuration: started.duration(to: clock.now),
                    actorHopCount: 0
                )
            )
        }
    } catch let error as ProtocolDecodeError {
        throw ProtocolDecodeError.frameFailure(cause: error, envelope: envelope)
    } catch let error as FrameResourceError {
        throw ProtocolDecodeError.frameFailure(cause: .resource(error), envelope: envelope)
    }
}

/// Compatibility adapter for tests and harness clients. Delivery is atomic:
/// handlers run only after the entire packet has decoded successfully.
func decodeCommands(from data: Data, handler: (RenderCommand) -> Void) throws {
    let frame = try decodeCompatibilityFrame(from: data)
    for decoded in frame.commands {
        handler(decoded.command)
    }
}

/// Compatibility adapter that also reports command wire opcodes.
func decodeCommands(from data: Data, handler: (RenderCommand, UInt8) -> Void) throws {
    let frame = try decodeCompatibilityFrame(from: data)
    for decoded in frame.commands {
        handler(decoded.command, decoded.opcode)
    }
}

private func decodeCompatibilityFrame(from data: Data) throws -> DecodedFrame {
    do {
        return try decodeFrame(from: data)
    } catch let error as ProtocolDecodeError {
        throw error.unwrappedFrameFailure
    }
}

/// Decodes a single known command at the given offset.
/// Returns the decoded command (nil for known non-rendering opcodes) and bytes consumed.
/// Unknown commands always fail closed, including size-framed high opcodes.
func decodeCommand(data: Data, offset: Int) throws -> (RenderCommand?, Int) {
    guard offset >= data.startIndex, offset < data.endIndex else {
        throw ProtocolDecodeError.insufficientData
    }

    var packetCursor = try ByteCursor(data, range: offset..<data.endIndex)
    let opcode = try packetCursor.readUInt8()

    // Data slicing is a bounded view. Unlike Array(data[offset...]), this does
    // not materialize the unconsumed packet tail.
    switch commandSize(data[offset...]) {
    case .sized(let size):
        do {
            let (command, decodedSize) = try decodeCommandForRenderingChecked(data: data, offset: offset)
            guard decodedSize == size else { throw ProtocolDecodeError.malformed }
            return (command, size)
        } catch ProtocolDecodeError.unknownOpcode {
            // The generated schema knows this opcode and its exact framing, but
            // this renderer intentionally has no semantic command for it.
            return (nil, size)
        }
    case .custom:
        return try decodeCommandForRenderingChecked(data: data, offset: offset)
    case .incomplete:
        throw ProtocolDecodeError.insufficientData
    case .unknown:
        throw ProtocolDecodeError.unknownOpcode(opcode)
    }
}

private func decodeCommandForRenderingChecked(data: Data, offset: Int) throws -> (RenderCommand?, Int) {
    do {
        return try decodeCommandForRendering(data: data, offset: offset)
    } catch let error as ByteCursor.BoundsError {
        throw ProtocolDecodeError.outOfBounds(
            offset: error.offset,
            required: error.required,
            remaining: error.remaining
        )
    }
}

private func decodeCommandForRendering(data: Data, offset: Int) throws -> (RenderCommand?, Int) {
    guard offset < data.count else {
        throw ProtocolDecodeError.insufficientData
    }

    let opcode = data[offset]
    let rest = offset + 1

    switch opcode {
    case 0x20: // set_language: buffer_id:4, name_len:2, name
        guard data.count >= rest + 6 else { throw ProtocolDecodeError.malformed }
        let nameLen = Int(try readU16(data, rest + 4))
        guard data.count >= rest + 6 + nameLen else { throw ProtocolDecodeError.malformed }
        return (nil, 1 + 6 + nameLen)

    case 0x21: // parse_buffer: buffer_id:4, version:4, source_len:4, source
        guard data.count >= rest + 12 else { throw ProtocolDecodeError.malformed }
        let sourceLen = Int(try readU32(data, rest + 8))
        guard data.count >= rest + 12 + sourceLen else { throw ProtocolDecodeError.malformed }
        return (nil, 1 + 12 + sourceLen)

    case 0x22, 0x24, 0x28, 0x29, 0x2B, 0x40: // query commands: buffer_id:4, query_len:4, query
        guard data.count >= rest + 8 else { throw ProtocolDecodeError.malformed }
        let queryLen = Int(try readU32(data, rest + 4))
        guard data.count >= rest + 8 + queryLen else { throw ProtocolDecodeError.malformed }
        return (nil, 1 + 8 + queryLen)

    case 0x23: // load_grammar: name_len:2, name, path_len:2, path
        guard data.count >= rest + 2 else { throw ProtocolDecodeError.malformed }
        let nameLen = Int(try readU16(data, rest))
        guard data.count >= rest + 2 + nameLen + 2 else { throw ProtocolDecodeError.malformed }
        let pathLen = Int(try readU16(data, rest + 2 + nameLen))
        guard data.count >= rest + 2 + nameLen + 2 + pathLen else { throw ProtocolDecodeError.malformed }
        return (nil, 1 + 2 + nameLen + 2 + pathLen)

    case 0x25: // query_language_at: buffer_id:4, request_id:4, byte_offset:4
        guard data.count >= rest + 12 else { throw ProtocolDecodeError.malformed }
        return (nil, 13)

    case 0x26: // edit_buffer: buffer_id:4, version:4, edit_count:2, edits
        guard data.count >= rest + 10 else { throw ProtocolDecodeError.malformed }
        let editCount = Int(try readU16(data, rest + 8))
        var pos = rest + 10
        for _ in 0..<editCount {
            guard data.count >= pos + 40 else { throw ProtocolDecodeError.malformed }
            let textLen = Int(try readU32(data, pos + 36))
            guard data.count >= pos + 40 + textLen else { throw ProtocolDecodeError.malformed }
            pos += 40 + textLen
        }
        return (nil, pos - offset)

    case 0x27: // measure_text: request_id:4, text_len:2, text
        guard data.count >= rest + 6 else { throw ProtocolDecodeError.malformed }
        let textLen = Int(try readU16(data, rest + 4))
        guard data.count >= rest + 6 + textLen else { throw ProtocolDecodeError.malformed }
        return (nil, 1 + 6 + textLen)

    case 0x2A: // request_indent: buffer_id:4, request_id:4, line:4
        guard data.count >= rest + 12 else { throw ProtocolDecodeError.malformed }
        return (nil, 13)

    case 0x2C: // request_textobject: buffer_id:4, request_id:4, row:4, col:4, name_len:2, name
        guard data.count >= rest + 18 else { throw ProtocolDecodeError.malformed }
        let nameLen = Int(try readU16(data, rest + 16))
        guard data.count >= rest + 18 + nameLen else { throw ProtocolDecodeError.malformed }
        return (nil, 1 + 18 + nameLen)

    case 0x2D: // close_buffer: buffer_id:4
        guard data.count >= rest + 4 else { throw ProtocolDecodeError.malformed }
        return (nil, 5)

    case 0x2E: // request_match_item: buffer_id:4, request_id:4, row:4, col:4
        guard data.count >= rest + 16 else { throw ProtocolDecodeError.malformed }
        return (nil, 17)

    case 0x2F: // request_structural_nav: buffer_id:4, request_id:4, row:4, col:4, action:1
        guard data.count >= rest + 17 else { throw ProtocolDecodeError.malformed }
        return (nil, 18)

    case OP_BEGIN_FRAME:
        // begin_frame (#2739): <opcode, frame_seq:u32, base_frame_seq:u32, generation:u32>.
        guard data.count >= rest + 12 else { throw ProtocolDecodeError.malformed }
        let frameSeq = try readU32(data, rest)
        let baseFrameSeq = try readU32(data, rest + 4)
        let generation = try readU32(data, rest + 8)
        return (.beginFrame(frameSeq: frameSeq, baseFrameSeq: baseFrameSeq, generation: generation), 13)

    case OP_COMMIT_FRAME:
        // commit_frame (#2219): <opcode, frame_seq:u32, input_seq:u32>. input_seq is
        // the echoed input correlation sequence (ticket #2215, formerly batch_end).
        guard data.count >= rest + 8 else { throw ProtocolDecodeError.malformed }
        let frameSeq = try readU32(data, rest)
        let seq = try readU32(data, rest + 4)
        return (.commitFrame(frameSeq: frameSeq, seq: seq), 9)

    case OP_SET_CURSOR_SHAPE:
        guard data.count >= rest + 1 else { throw ProtocolDecodeError.malformed }
        let shape = CursorShape(rawValue: data[rest]) ?? .block
        return (.setCursorShape(shape), 2)

    case OP_SET_TITLE:
        guard data.count >= rest + 2 else { throw ProtocolDecodeError.malformed }
        let titleLen = Int(try readU16(data, rest))
        guard data.count >= rest + 2 + titleLen else { throw ProtocolDecodeError.malformed }
        let titleData = data[(rest + 2)..<(rest + 2 + titleLen)]
        let title = try decodeUTF8(titleData) ?? ""
        return (.setTitle(title), 1 + 2 + titleLen)

    case OP_SET_WINDOW_BG:
        guard data.count >= rest + 3 else { throw ProtocolDecodeError.malformed }
        return (.setWindowBg(r: data[rest], g: data[rest + 1], b: data[rest + 2]), 4)

    case OP_SET_LINK_CURSOR:
        guard data.count >= rest + 1 else { throw ProtocolDecodeError.malformed }
        return (.setLinkCursor(active: data[rest] != 0), 2)

    // Config commands.
    case OP_SET_FONT:
        // size:2, weight:1, ligatures:1, name_len:2 = 6 bytes after opcode
        guard data.count >= rest + 6 else { throw ProtocolDecodeError.malformed }
        let fontSize = try readU16(data, rest)
        let weight = data[rest + 2]
        let ligatures = data[rest + 3] != 0
        let nameLen = Int(try readU16(data, rest + 4))
        guard data.count >= rest + 6 + nameLen else { throw ProtocolDecodeError.malformed }
        let nameData = data[(rest + 6)..<(rest + 6 + nameLen)]
        let family = try decodeUTF8(nameData) ?? "Menlo"
        return (.setFont(family: family, size: fontSize, ligatures: ligatures, weight: weight), 1 + 6 + nameLen)

    case OP_SET_FONT_FALLBACK:
        // count:1, then count * (name_len:2, name:bytes)
        guard data.count >= rest + 1 else { throw ProtocolDecodeError.malformed }
        let count = Int(data[rest])
        var families: [String] = []
        var offset = rest + 1
        for _ in 0..<count {
            guard data.count >= offset + 2 else { throw ProtocolDecodeError.malformed }
            let nameLen = Int(try readU16(data, offset))
            offset += 2
            guard data.count >= offset + nameLen else { throw ProtocolDecodeError.malformed }
            let nameData = data[offset..<(offset + nameLen)]
            let name = try decodeUTF8(nameData) ?? ""
            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            families.append(name)
            offset += nameLen
        }
        return (.setFontFallback(families: families), offset - rest + 1)

    case OP_REGISTER_FONT:
        // font_id:1, name_len:2, name:bytes
        guard data.count >= rest + 3 else { throw ProtocolDecodeError.malformed }
        let fontId = data[rest]
        let nameLen = Int(try readU16(data, rest + 1))
        guard data.count >= rest + 3 + nameLen else { throw ProtocolDecodeError.malformed }
        let nameData = data[(rest + 3)..<(rest + 3 + nameLen)]
        let family = try decodeUTF8(nameData) ?? "Menlo"
        return (.registerFont(id: fontId, family: family), 1 + 3 + nameLen)

    case OP_GUI_CONFIG_STATE:
        guard data.count >= rest + 2 else { throw ProtocolDecodeError.malformed }
        let payloadLen = Int(try readU16(data, rest))
        let payloadStart = rest + 2
        guard data.count >= payloadStart + payloadLen else { throw ProtocolDecodeError.malformed }
        let state = try decodeConfigState(data: data, start: payloadStart, end: payloadStart + payloadLen)
        return (.guiConfigState(state), 1 + 2 + payloadLen)

    case OP_GUI_NOTIFICATIONS:
        guard data.count >= rest + 2 else { throw ProtocolDecodeError.malformed }
        let payloadLen = Int(try readU16(data, rest))
        let payloadStart = rest + 2
        guard data.count >= payloadStart + payloadLen else { throw ProtocolDecodeError.malformed }
        let notifications = try decodeNotifications(data: data, start: payloadStart, end: payloadStart + payloadLen)
        return (.guiNotifications(notifications), 1 + 2 + payloadLen)

    case OP_GUI_EMPTY_STATE:
        // len16 framed. Payload: visible(1). When visible: flags(1, bit0=crashed),
        // version:string8, focused_id:string8, section_count(1), then per section:
        // section_id(1), title:string8, item_count(1), then per item:
        // kind(1), id:string8, label:string16, detail:string16, jump_key:string8,
        // chord:string8, icon:string8, icon_color(u32 0xRRGGBB).
        guard data.count >= rest + 2 else { throw ProtocolDecodeError.malformed }
        let payloadLen = Int(try readU16(data, rest))
        let payloadStart = rest + 2
        let payloadEnd = payloadStart + payloadLen
        guard data.count >= payloadEnd, payloadLen >= 1 else { throw ProtocolDecodeError.malformed }
        var pos = payloadStart
        let visible = data[pos] != 0
        pos += 1
        guard visible else {
            return (.guiEmptyState(visible: false, crashed: false, version: "", focusedId: "", sections: []), 1 + 2 + payloadLen)
        }
        guard pos + 1 <= payloadEnd else { throw ProtocolDecodeError.malformed }
        let esFlags = data[pos]
        pos += 1
        let esCrashed = esFlags & 0x01 != 0
        let esVersion = try readString8(data: data, pos: &pos, end: payloadEnd)
        let esFocusedId = try readString8(data: data, pos: &pos, end: payloadEnd)
        guard pos + 1 <= payloadEnd else { throw ProtocolDecodeError.malformed }
        let esSectionCount = Int(data[pos])
        pos += 1
        var esSections: [Wire.EmptyStateSection] = []
        try FrameDecodeAccounting.reserve(.arrayEntries, esSectionCount)
        esSections.reserveCapacity(esSectionCount)
        for _ in 0..<esSectionCount {
            guard pos + 1 <= payloadEnd else { throw ProtocolDecodeError.malformed }
            let sectionId = data[pos]
            pos += 1
            let title = try readString8(data: data, pos: &pos, end: payloadEnd)
            guard pos + 1 <= payloadEnd else { throw ProtocolDecodeError.malformed }
            let itemCount = Int(data[pos])
            pos += 1
            var items: [Wire.EmptyStateItem] = []
            try FrameDecodeAccounting.reserve(.arrayEntries, itemCount)
            items.reserveCapacity(itemCount)
            for _ in 0..<itemCount {
                guard pos + 1 <= payloadEnd else { throw ProtocolDecodeError.malformed }
                let kind = data[pos]
                pos += 1
                let itemId = try readString8(data: data, pos: &pos, end: payloadEnd)
                let label = try readString16(data: data, pos: &pos, end: payloadEnd)
                let detail = try readString16(data: data, pos: &pos, end: payloadEnd)
                let jumpKey = try readString8(data: data, pos: &pos, end: payloadEnd)
                let chord = try readString8(data: data, pos: &pos, end: payloadEnd)
                let icon = try readString8(data: data, pos: &pos, end: payloadEnd)
                guard pos + 4 <= payloadEnd else { throw ProtocolDecodeError.malformed }
                let iconColor = try readU32(data, pos)
                pos += 4
                try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                items.append(Wire.EmptyStateItem(kind: kind, id: itemId, label: label, detail: detail, jumpKey: jumpKey, chord: chord, icon: icon, iconColorRGB: iconColor))
            }
            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            esSections.append(Wire.EmptyStateSection(sectionId: sectionId, title: title, items: items))
        }
        return (.guiEmptyState(visible: true, crashed: esCrashed, version: esVersion, focusedId: esFocusedId, sections: esSections), 1 + 2 + payloadLen)

    // GUI chrome commands.
    case OP_GUI_FILE_TREE:
        // Semantic file tree uses a 32-bit payload length because expanded project trees can exceed 64KB.
        // v1: opcode(1) + payload_len(4) + version(1) + tree_flags(1) + selected_id + root + tree_width(2) + row_count(2) + rows...
        // v2: adds tree_state(1) after tree_flags and error_reason after row_count.
        guard data.count >= rest + 4 else { throw ProtocolDecodeError.malformed }
        let payloadLen = Int(try readU32(data, rest))
        let payloadStart = rest + 4
        guard data.count >= payloadStart + payloadLen else { throw ProtocolDecodeError.malformed }
        guard payloadLen >= 6 else { throw ProtocolDecodeError.malformed }

        let version = data[payloadStart]
        let treeFlags = data[payloadStart + 1]
        var pos = payloadStart + 2
        let treeState: UInt8
        if version >= 2 {
            guard pos + 1 <= payloadStart + payloadLen else { throw ProtocolDecodeError.malformed }
            treeState = data[pos]
            pos += 1
        } else {
            treeState = legacyFileTreeState(treeFlags: treeFlags)
        }

        guard pos + 2 <= payloadStart + payloadLen else { throw ProtocolDecodeError.malformed }
        let selectedIdLen = Int(try readU16(data, pos)); pos += 2
        guard pos + selectedIdLen <= payloadStart + payloadLen else { throw ProtocolDecodeError.malformed }
        let selectedId = try decodeUTF8(data[pos..<(pos + selectedIdLen)]) ?? ""
        pos += selectedIdLen

        guard pos + 2 <= payloadStart + payloadLen else { throw ProtocolDecodeError.malformed }
        let rootLen = Int(try readU16(data, pos)); pos += 2
        guard pos + rootLen <= payloadStart + payloadLen else { throw ProtocolDecodeError.malformed }
        let rootPath = try decodeUTF8(data[pos..<(pos + rootLen)]) ?? ""
        pos += rootLen

        guard pos + 4 <= payloadStart + payloadLen else { throw ProtocolDecodeError.malformed }
        let treeWidth = try readU16(data, pos); pos += 2
        let rowCount = Int(try readU16(data, pos)); pos += 2

        let errorReason: String
        if version >= 2 {
            guard pos + 2 <= payloadStart + payloadLen else { throw ProtocolDecodeError.malformed }
            let errorReasonLen = Int(try readU16(data, pos)); pos += 2
            guard pos + errorReasonLen <= payloadStart + payloadLen else { throw ProtocolDecodeError.malformed }
            errorReason = try decodeUTF8(data[pos..<(pos + errorReasonLen)]) ?? ""
            pos += errorReasonLen
        } else {
            errorReason = ""
        }

        var entries: [Wire.FileTreeEntry] = []
        try FrameDecodeAccounting.reserve(.arrayEntries, rowCount)
        entries.reserveCapacity(rowCount)

        for _ in 0..<rowCount {
            guard pos + 17 <= payloadStart + payloadLen else { throw ProtocolDecodeError.malformed }
            let pathHash = try readU32(data, pos); pos += 4
            let flags = try readU16(data, pos); pos += 2
            let depth = data[pos]; pos += 1
            let gitStatus = data[pos]; pos += 1
            let diagnosticErrorCount = try readU16(data, pos); pos += 2
            let diagnosticWarningCount = try readU16(data, pos); pos += 2
            let diagnosticInfoCount = try readU16(data, pos); pos += 2
            let diagnosticHintCount = try readU16(data, pos); pos += 2
            let guideCount = Int(data[pos]); pos += 1
            guard pos + guideCount <= payloadStart + payloadLen else { throw ProtocolDecodeError.malformed }
            try FrameDecodeAccounting.reserve(.arrayEntries, guideCount)
            let guides = (0..<guideCount).map { index in data[pos + index] != 0 }
            pos += guideCount

            guard pos + 2 <= payloadStart + payloadLen else { throw ProtocolDecodeError.malformed }
            let idLen = Int(try readU16(data, pos)); pos += 2
            guard pos + idLen <= payloadStart + payloadLen else { throw ProtocolDecodeError.malformed }
            let id = try decodeUTF8(data[pos..<(pos + idLen)]) ?? ""
            pos += idLen

            guard pos + 2 <= payloadStart + payloadLen else { throw ProtocolDecodeError.malformed }
            let pathLen = Int(try readU16(data, pos)); pos += 2
            guard pos + pathLen <= payloadStart + payloadLen else { throw ProtocolDecodeError.malformed }
            let path = try decodeUTF8(data[pos..<(pos + pathLen)]) ?? ""
            pos += pathLen

            guard pos + 2 <= payloadStart + payloadLen else { throw ProtocolDecodeError.malformed }
            let relPathLen = Int(try readU16(data, pos)); pos += 2
            guard pos + relPathLen <= payloadStart + payloadLen else { throw ProtocolDecodeError.malformed }
            let relPath = try decodeUTF8(data[pos..<(pos + relPathLen)]) ?? ""
            pos += relPathLen

            guard pos + 2 <= payloadStart + payloadLen else { throw ProtocolDecodeError.malformed }
            let nameLen = Int(try readU16(data, pos)); pos += 2
            guard pos + nameLen <= payloadStart + payloadLen else { throw ProtocolDecodeError.malformed }
            let name = try decodeUTF8(data[pos..<(pos + nameLen)]) ?? ""
            pos += nameLen

            guard pos + 1 <= payloadStart + payloadLen else { throw ProtocolDecodeError.malformed }
            let iconLen = Int(data[pos]); pos += 1
            guard pos + iconLen <= payloadStart + payloadLen else { throw ProtocolDecodeError.malformed }
            let icon = try decodeUTF8(data[pos..<(pos + iconLen)]) ?? ""
            pos += iconLen

            guard pos + 3 <= payloadStart + payloadLen else { throw ProtocolDecodeError.malformed }
            let editingType = data[pos]; pos += 1
            let editingTextLen = Int(try readU16(data, pos)); pos += 2
            guard pos + editingTextLen <= payloadStart + payloadLen else { throw ProtocolDecodeError.malformed }
            let editingText = try decodeUTF8(data[pos..<(pos + editingTextLen)]) ?? ""
            pos += editingTextLen

            guard pos + 3 <= payloadStart + payloadLen else { throw ProtocolDecodeError.malformed }
            let iconColorR = data[pos]; pos += 1
            let iconColorG = data[pos]; pos += 1
            let iconColorB = data[pos]; pos += 1

            guard pos + 1 <= payloadStart + payloadLen else { throw ProtocolDecodeError.malformed }
            let heatLevel = data[pos]; pos += 1

            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            entries.append(Wire.FileTreeEntry(
                pathHash: pathHash,
                id: id,
                path: path,
                isDir: flags & 0x0001 != 0,
                isExpanded: flags & 0x0002 != 0,
                isSelected: flags & 0x0004 != 0,
                isFocused: flags & 0x0008 != 0,
                isActive: flags & 0x0010 != 0,
                isDirty: flags & 0x0020 != 0,
                isEditing: flags & 0x0040 != 0,
                isLastChild: flags & 0x0080 != 0,
                depth: depth,
                gitStatus: gitStatus,
                diagnosticErrorCount: diagnosticErrorCount,
                diagnosticWarningCount: diagnosticWarningCount,
                diagnosticInfoCount: diagnosticInfoCount,
                diagnosticHintCount: diagnosticHintCount,
                guides: guides,
                icon: icon,
                iconColorR: iconColorR,
                iconColorG: iconColorG,
                iconColorB: iconColorB,
                name: name,
                relPath: relPath,
                editingType: editingType,
                editingText: editingText,
                heatLevel: heatLevel
            ))
        }

        guard pos == payloadStart + payloadLen else { throw ProtocolDecodeError.malformed }
        return (.guiFileTree(version: version, treeFlags: treeFlags, treeState: treeState, selectedId: selectedId, treeWidth: treeWidth, rootPath: rootPath, errorReason: errorReason, entries: entries), 5 + payloadLen)

    case OP_GUI_OBSERVATORY:
        guard data.count >= rest + 4 else { throw ProtocolDecodeError.malformed }
        let payloadLen = Int(try readU32(data, rest))
        let payloadStart = rest + 4
        guard data.count >= payloadStart + payloadLen else { throw ProtocolDecodeError.malformed }
        let payloadEnd = payloadStart + payloadLen
        var pos = payloadStart
        var visible = false
        var nodeCount: UInt16 = 0
        var nodeEntries: [Wire.ObservatoryNode] = []
        var sparklinesByPid: [String: [Float]] = [:]

        while pos < payloadEnd {
            let section = try readSection16(data, at: pos, containingEnd: payloadEnd)
            let sectionId = section.id
            let sectionLen = section.end - section.start
            let sectionStart = section.start
            let sectionEnd = section.end

            switch sectionId {
            case 0x01:
                guard sectionLen >= 3 else { break }
                visible = data[sectionStart] != 0
                nodeCount = try readU16(data, sectionStart + 1)

            case 0x02:
                var nodePos = sectionStart
                while nodePos < sectionEnd {
                    guard nodePos + 1 <= sectionEnd else { throw ProtocolDecodeError.malformed }
                    let pidLen = Int(data[nodePos]); nodePos += 1
                    guard nodePos + pidLen + 1 <= sectionEnd else { throw ProtocolDecodeError.malformed }
                    let pid = try decodeUTF8(data[nodePos..<(nodePos + pidLen)]) ?? ""
                    nodePos += pidLen
                    let parentLen = Int(data[nodePos]); nodePos += 1
                    guard nodePos + parentLen + 2 <= sectionEnd else { throw ProtocolDecodeError.malformed }
                    let parentPid = try decodeUTF8(data[nodePos..<(nodePos + parentLen)]) ?? ""
                    nodePos += parentLen
                    let nameLen = Int(try readU16(data, nodePos)); nodePos += 2
                    guard nodePos + nameLen + 12 <= sectionEnd else { throw ProtocolDecodeError.malformed }
                    let name = try decodeUTF8(data[nodePos..<(nodePos + nameLen)]) ?? ""
                    nodePos += nameLen
                    let processClass = data[nodePos]; nodePos += 1
                    let depth = data[nodePos]; nodePos += 1
                    let memory = try readU32(data, nodePos); nodePos += 4
                    let messageQueueLen = try readU16(data, nodePos); nodePos += 2
                    let reductions = try readU32(data, nodePos); nodePos += 4
                    try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                    nodeEntries.append(Wire.ObservatoryNode(pid: pid, parentPid: parentPid, name: name, processClass: processClass, depth: depth, memory: memory, messageQueueLen: messageQueueLen, reductions: reductions, sparkline: []))
                }

            case 0x03:
                var sparkPos = sectionStart
                while sparkPos < sectionEnd {
                    guard sparkPos + 2 <= sectionEnd else { throw ProtocolDecodeError.malformed }
                    let pidLen = Int(data[sparkPos]); sparkPos += 1
                    guard sparkPos + pidLen + 1 <= sectionEnd else { throw ProtocolDecodeError.malformed }
                    let pid = try decodeUTF8(data[sparkPos..<(sparkPos + pidLen)]) ?? ""
                    sparkPos += pidLen
                    let sampleCount = Int(data[sparkPos]); sparkPos += 1
                    guard sparkPos + sampleCount * 2 <= sectionEnd else { throw ProtocolDecodeError.malformed }
                    var samples: [Float] = []
                    try FrameDecodeAccounting.reserve(.arrayEntries, sampleCount)
                    samples.reserveCapacity(sampleCount)
                    for _ in 0..<sampleCount {
                        let raw = try readU16(data, sparkPos)
                        try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                        samples.append(Float(raw) / 65535.0)
                        sparkPos += 2
                    }
                    sparklinesByPid[pid] = samples
                }

            default:
                break
            }

            pos = sectionEnd
        }

        try FrameDecodeAccounting.reserve(.arrayEntries, nodeEntries.count)
        let nodes = nodeEntries.map { node in
            Wire.ObservatoryNode(pid: node.pid, parentPid: node.parentPid, name: node.name, processClass: node.processClass, depth: node.depth, memory: node.memory, messageQueueLen: node.messageQueueLen, reductions: node.reductions, sparkline: sparklinesByPid[node.pid] ?? [])
        }
        guard nodeCount == nodes.count else { throw ProtocolDecodeError.malformed }

        return (.guiObservatory(visible: visible, nodeCount: nodeCount, nodes: nodes), 5 + payloadLen)

    case OP_GUI_FILE_TREE_SELECTION:
        guard data.count >= rest + 2 else { throw ProtocolDecodeError.malformed }
        let payloadLen = Int(try readU16(data, rest))
        let payloadStart = rest + 2
        guard data.count >= payloadStart + payloadLen else { throw ProtocolDecodeError.malformed }
        guard payloadLen >= 3 else { throw ProtocolDecodeError.malformed }
        let flags = data[payloadStart]
        var pos = payloadStart + 1
        let selectedIdLen = Int(try readU16(data, pos)); pos += 2
        guard pos + selectedIdLen == payloadStart + payloadLen else { throw ProtocolDecodeError.malformed }
        let selectedId = try decodeUTF8(data[pos..<(pos + selectedIdLen)]) ?? ""
        return (.guiFileTreeSelection(selectedId: selectedId, focused: flags & 0x01 != 0), 3 + payloadLen)

    case OP_GUI_TAB_BAR:
        // active_index:1 (255 means the active tab is hidden from the visible tab list), tab_count:1, then per tab: flags:1, id:4, group_id:2, icon_len:1, icon, label_len:2, label, tint_color_rgb:4
        guard data.count >= rest + 2 else { throw ProtocolDecodeError.malformed }
        let activeIndex = data[rest]
        let tabCount = Int(data[rest + 1])
        var tabs: [Wire.TabEntry] = []
        try FrameDecodeAccounting.reserve(.arrayEntries, tabCount)
        tabs.reserveCapacity(tabCount)
        var pos = rest + 2
        for _ in 0..<tabCount {
            guard data.count >= pos + 8 else { throw ProtocolDecodeError.malformed }
            let flags = data[pos]
            let tabId = try readU32(data, pos + 1)
            let groupId = try readU16(data, pos + 5)
            let iconLen = Int(data[pos + 7])
            guard data.count >= pos + 8 + iconLen + 2 else { throw ProtocolDecodeError.malformed }
            let iconData = data[(pos + 8)..<(pos + 8 + iconLen)]
            let icon = try decodeUTF8(iconData) ?? ""
            let labelLen = Int(try readU16(data, pos + 8 + iconLen))
            guard data.count >= pos + 8 + iconLen + 2 + labelLen + 4 else { throw ProtocolDecodeError.malformed }
            let labelData = data[(pos + 10 + iconLen)..<(pos + 10 + iconLen + labelLen)]
            let label = try decodeUTF8(labelData) ?? ""
            let tintColorRGB = try readU32(data, pos + 10 + iconLen + labelLen)
            // Bits 4-6 are kind-scoped: agent status for agent tabs,
            // ephemeral (not-on-disk) marker in bit 4 for file tabs.
            let isAgent = flags & 0x04 != 0
            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            tabs.append(Wire.TabEntry(
                id: tabId,
                groupId: groupId,
                isActive: flags & 0x01 != 0,
                isDirty: flags & 0x02 != 0,
                isAgent: isAgent,
                hasAttention: flags & 0x08 != 0,
                agentStatus: isAgent ? (flags >> 4) & 0x07 : 0,
                isPinned: flags & 0x80 != 0,
                isEphemeral: !isAgent && flags & 0x10 != 0,
                tintColorRGB: tintColorRGB,
                icon: icon,
                label: label
            ))
            pos += 14 + iconLen + labelLen
        }
        return (.guiTabBar(activeIndex: activeIndex, tabs: tabs), pos - offset)

    case OP_GUI_THEME:
        // count:1, then count × (slot_id:1, r:1, g:1, b:1)
        guard data.count >= rest + 1 else { throw ProtocolDecodeError.malformed }
        let count = Int(data[rest])
        guard data.count >= rest + 1 + count * 4 else { throw ProtocolDecodeError.malformed }
        var slots: [(slotId: UInt8, r: UInt8, g: UInt8, b: UInt8)] = []
        try FrameDecodeAccounting.reserve(.arrayEntries, count)
        slots.reserveCapacity(count)
        for i in 0..<count {
            let base = rest + 1 + i * 4
            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            slots.append((data[base], data[base + 1], data[base + 2], data[base + 3]))
        }
        return (.guiTheme(slots: slots), 1 + 1 + count * 4)

    case OP_GUI_COMPLETION:
        // Schema-generated decoder (gui_completion command_fields). The generated
        // GuiCompletionFields mirrors the Go decoder's field order and conditional
        // tail; we map it into the existing RenderCommand shape. CompletionKind's
        // raw value matches the UInt8 kind the hand-written decoder produced.
        do {
            let (fields, nextPos) = try GeneratedProtocol.decodeGuiCompletionFields(data, rest, data.count)
            try FrameDecodeAccounting.reserve(.arrayEntries, fields.items.count)
            let items = fields.items.map {
                Wire.CompletionItem(kind: $0.kind.rawValue, label: $0.label, detail: $0.detail)
            }
            return (.guiCompletion(
                visible: fields.visible != 0,
                anchorRow: fields.cursorRow,
                anchorCol: fields.cursorCol,
                selectedIndex: fields.selectedOffset,
                items: items,
                documentation: fields.documentation
            ), nextPos - offset)
        } catch let error as FrameResourceError {
            throw error
        } catch {
            throw ProtocolDecodeError.malformed
        }

    case OP_GUI_WHICH_KEY:
        guard data.count >= rest + 1 else { throw ProtocolDecodeError.malformed }
        let visible = data[rest] != 0
        if !visible {
            return (.guiWhichKey(visible: false, prefix: "", page: 0, pageCount: 0, bindings: []), 2)
        }
        guard data.count >= rest + 3 else { throw ProtocolDecodeError.malformed }
        let prefixLen = Int(try readU16(data, rest + 1))
        guard data.count >= rest + 3 + prefixLen + 4 else { throw ProtocolDecodeError.malformed }
        let prefix = try decodeUTF8(data[(rest + 3)..<(rest + 3 + prefixLen)]) ?? ""
        let page = data[rest + 3 + prefixLen]
        let pageCount = data[rest + 4 + prefixLen]
        let bindingCount = Int(try readU16(data, rest + 5 + prefixLen))
        var bindings: [Wire.WhichKeyBinding] = []
        try FrameDecodeAccounting.reserve(.arrayEntries, bindingCount)
        bindings.reserveCapacity(bindingCount)
        var pos = rest + 7 + prefixLen
        for _ in 0..<bindingCount {
            guard data.count >= pos + 2 else { throw ProtocolDecodeError.malformed }
            let bKind = data[pos]
            let keyLen = Int(data[pos + 1])
            guard data.count >= pos + 2 + keyLen + 2 else { throw ProtocolDecodeError.malformed }
            let key = try decodeUTF8(data[(pos + 2)..<(pos + 2 + keyLen)]) ?? ""
            let descLen = Int(try readU16(data, pos + 2 + keyLen))
            guard data.count >= pos + 4 + keyLen + descLen + 1 else { throw ProtocolDecodeError.malformed }
            let desc = try decodeUTF8(data[(pos + 4 + keyLen)..<(pos + 4 + keyLen + descLen)]) ?? ""
            let iconLen = Int(data[pos + 4 + keyLen + descLen])
            guard data.count >= pos + 5 + keyLen + descLen + iconLen else { throw ProtocolDecodeError.malformed }
            let icon = try decodeUTF8(data[(pos + 5 + keyLen + descLen)..<(pos + 5 + keyLen + descLen + iconLen)]) ?? ""
            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            bindings.append(Wire.WhichKeyBinding(kind: bKind, key: key, description: desc, icon: icon))
            pos += 5 + keyLen + descLen + iconLen
        }
        return (.guiWhichKey(visible: true, prefix: prefix, page: page, pageCount: pageCount, bindings: bindings), pos - offset)

    case OP_GUI_BREADCRUMB:
        // Schema-generated decoder (gui_breadcrumb command_fields): a u8-counted
        // list of string16 segments, mirroring the Go decoder.
        do {
            let (fields, nextPos) = try GeneratedProtocol.decodeGuiBreadcrumbFields(data, rest, data.count)
            return (.guiBreadcrumb(segments: fields.segments), nextPos - offset)
        } catch let error as FrameResourceError {
            throw error
        } catch {
            throw ProtocolDecodeError.malformed
        }

    case OP_GUI_STATUS_BAR:
        // Sectioned wire format: opcode(1) + section_count(1) + sections...
        // Each section: section_id(1) + section_len(2) + payload(section_len)
        // Unknown sections are skipped (forward compatibility).
        guard data.count >= rest + 1 else { throw ProtocolDecodeError.malformed }
        let sectionCount = Int(data[rest])
        var pos = rest + 1

        // Defaults for all fields (sections may be absent or in any order)
        var contentKind: UInt8 = 0
        var mode: UInt8 = 0
        var flags: UInt8 = 0
        var cursorLine: UInt32 = 0
        var cursorCol: UInt32 = 0
        var lineCount: UInt32 = 0
        var errorCount: UInt16 = 0
        var warningCount: UInt16 = 0
        var infoCount: UInt16 = 0
        var hintCount: UInt16 = 0
        var diagnosticHint = ""
        var backgroundSubagentCount: UInt16 = 0
        var backgroundSubagentLabel = ""
        var lspStatus: UInt8 = 0
        var parserStatus: UInt8 = 0
        var gitBranch = ""
        var gitAdded: UInt16 = 0
        var gitModified: UInt16 = 0
        var gitDeleted: UInt16 = 0
        var icon = ""
        var iconColorR: UInt8 = 0
        var iconColorG: UInt8 = 0
        var iconColorB: UInt8 = 0
        var filename = ""
        var filetype = ""
        var message = ""
        var macroRecording: UInt8 = 0
        var modelName = ""
        var messageCount: UInt32 = 0
        var sessionStatus: UInt8 = 0
        var agentStatus: UInt8 = 0
        var activeToolName = ""
        var agentSectionRange: Range<Int>? = nil
        var indent = StatusBarUpdate.IndentInfo(kind: 0, size: 2)
        var modelineSegmentsPresent = false
        var modelineLeftSegments: [Wire.StatusBarSegment] = []
        var modelineRightSegments: [Wire.StatusBarSegment] = []
        var selection = StatusBarUpdate.SelectionInfo(mode: 0, size: 0)
        var workspace: StatusBarUpdate.WorkspaceInfo? = nil
        var pendingKeys = ""

        for _ in 0..<sectionCount {
            let section = try readSection16(data, at: pos, containingEnd: data.endIndex)
            let sectionId = section.id
            let sectionLen = section.end - section.start
            let sStart = section.start

            switch sectionId {
            case 0x01: // Identity: content_kind(1) + mode(1) + flags(1)
                guard sectionLen >= 3 else { break }
                contentKind = data[sStart]
                mode = data[sStart + 1]
                flags = data[sStart + 2]

            case 0x02: // Cursor: cursor_line(4) + cursor_col(4) + line_count(4)
                guard sectionLen >= 12 else { break }
                cursorLine = try readU32(data, sStart)
                cursorCol = try readU32(data, sStart + 4)
                lineCount = try readU32(data, sStart + 8)

            case 0x03: // Diagnostics: error(2) + warning(2) + info(2) + hint(2) + diag_hint_len(2) + diag_hint
                guard sectionLen >= 8 else { break }
                errorCount = try readU16(data, sStart)
                warningCount = try readU16(data, sStart + 2)
                infoCount = try readU16(data, sStart + 4)
                hintCount = try readU16(data, sStart + 6)
                if sectionLen >= 10 {
                    let dhLen = Int(try readU16(data, sStart + 8))
                    guard sectionLen >= 10 + dhLen else { throw ProtocolDecodeError.malformed }
                    if dhLen > 0 {
                        diagnosticHint = try decodeUTF8(data[(sStart + 10)..<(sStart + 10 + dhLen)]) ?? ""
                    }
                }

            case 0x04: // Language: lsp_status(1) + parser_status(1)
                guard sectionLen >= 2 else { break }
                lspStatus = data[sStart]
                parserStatus = data[sStart + 1]

            case 0x05: // Git: branch_len(1) + branch + added(2) + modified(2) + deleted(2)
                guard sectionLen >= 1 else { break }
                let brLen = Int(data[sStart])
                guard sectionLen >= 1 + brLen + 6 else { break }
                gitBranch = try decodeUTF8(data[(sStart + 1)..<(sStart + 1 + brLen)]) ?? ""
                gitAdded = try readU16(data, sStart + 1 + brLen)
                gitModified = try readU16(data, sStart + 3 + brLen)
                gitDeleted = try readU16(data, sStart + 5 + brLen)

            case 0x06: // File: icon_len(1) + icon + r(1) + g(1) + b(1) + filename_len(2) + filename + filetype_len(1) + filetype
                guard sectionLen >= 1 else { break }
                let iLen = Int(data[sStart])
                guard sectionLen >= 1 + iLen + 3 + 2 else { break }
                icon = try decodeUTF8(data[(sStart + 1)..<(sStart + 1 + iLen)]) ?? ""
                iconColorR = data[sStart + 1 + iLen]
                iconColorG = data[sStart + 2 + iLen]
                iconColorB = data[sStart + 3 + iLen]
                let fnLen = Int(try readU16(data, sStart + 4 + iLen))
                guard sectionLen >= 6 + iLen + fnLen + 1 else { break }
                filename = try decodeUTF8(data[(sStart + 6 + iLen)..<(sStart + 6 + iLen + fnLen)]) ?? ""
                let ftLen = Int(data[sStart + 6 + iLen + fnLen])
                guard sectionLen >= 7 + iLen + fnLen + ftLen else { break }
                filetype = try decodeUTF8(data[(sStart + 7 + iLen + fnLen)..<(sStart + 7 + iLen + fnLen + ftLen)]) ?? ""

            case 0x07: // Message: msg_len(2) + msg
                guard sectionLen >= 2 else { break }
                let mLen = Int(try readU16(data, sStart))
                if sectionLen >= 2 + mLen, mLen > 0 {
                    message = try decodeUTF8(data[(sStart + 2)..<(sStart + 2 + mLen)]) ?? ""
                }

            case 0x08: // Recording: macro_recording(1)
                guard sectionLen >= 1 else { break }
                macroRecording = data[sStart]

            case 0x09: // Agent: varies by content_kind
                agentSectionRange = sStart..<(sStart + sectionLen)

            case 0x0A: // Indent: indent_type(1) + indent_size(1)
                guard sectionLen >= 2 else { break }
                indent = StatusBarUpdate.IndentInfo(kind: data[sStart], size: data[sStart + 1])

            case 0x0B: // ModelineSegments: version(1) + left_count(2) + right_count(2) + segments...
                guard sectionLen >= 5 else { throw ProtocolDecodeError.malformed }
                let version = data[sStart]
                guard version == 1 || version == 2 else { break }
                modelineSegmentsPresent = true
                let leftCount = Int(try readU16(data, sStart + 1))
                let rightCount = Int(try readU16(data, sStart + 3))
                var segmentPos = sStart + 5
                let sectionEnd = sStart + sectionLen
                modelineLeftSegments = try decodeStatusBarSegments(data: data, pos: &segmentPos, count: leftCount, end: sectionEnd, version: version)
                modelineRightSegments = try decodeStatusBarSegments(data: data, pos: &segmentPos, count: rightCount, end: sectionEnd, version: version)
                guard segmentPos == sectionEnd else { throw ProtocolDecodeError.malformed }

            case 0x0C: // Selection: selection_mode(1) + selection_size(4)
                guard sectionLen >= 5 else { break }
                selection = StatusBarUpdate.SelectionInfo(mode: data[sStart], size: try readU32(data, sStart + 1))

            case 0x0D: // Workspace: active workspace summary
                guard sectionLen >= 15 else { break }
                let workspaceId = try readU16(data, sStart)
                let workspaceKind = data[sStart + 2]
                let workspaceStatus = data[sStart + 3]
                let workspaceFlags = try readU16(data, sStart + 4)
                let draftCount = try readU16(data, sStart + 6)
                let conflictCount = try readU16(data, sStart + 8)
                let backgroundCount = try readU16(data, sStart + 10)
                let attentionCount = try readU16(data, sStart + 12)
                let labelLen = Int(data[sStart + 14])
                guard sectionLen >= 15 + labelLen + 1 else { break }
                let label = try decodeUTF8(data[(sStart + 15)..<(sStart + 15 + labelLen)]) ?? ""
                let iconLenPos = sStart + 15 + labelLen
                let iconLen = Int(data[iconLenPos])
                guard sectionLen >= 16 + labelLen + iconLen else { break }
                let icon = try decodeUTF8(data[(iconLenPos + 1)..<(iconLenPos + 1 + iconLen)]) ?? ""
                workspace = StatusBarUpdate.WorkspaceInfo(
                    id: workspaceId,
                    kind: workspaceKind,
                    status: workspaceStatus,
                    flags: workspaceFlags,
                    draftCount: draftCount,
                    conflictCount: conflictCount,
                    backgroundCount: backgroundCount,
                    attentionCount: attentionCount,
                    label: label,
                    icon: icon
                )

            case 0x0E: // PendingKeys (showcmd): keys_len(2) + keys
                guard sectionLen >= 2 else { break }
                let pkLen = Int(try readU16(data, sStart))
                if sectionLen >= 2 + pkLen, pkLen > 0 {
                    pendingKeys = try decodeUTF8(data[(sStart + 2)..<(sStart + 2 + pkLen)]) ?? ""
                }

            default:
                break // Skip unknown sections (forward compatibility)
            }

            pos = sStart + sectionLen
        }

        if let agentSectionRange {
            let sStart = agentSectionRange.lowerBound
            let sectionLen = agentSectionRange.count
            let sectionEnd = sStart + sectionLen

            if contentKind == 0 {
                guard sectionLen >= 1 else { throw ProtocolDecodeError.malformed }
                guard sectionLen >= 5 else { throw ProtocolDecodeError.malformed }
                var pos = sStart
                agentStatus = data[pos]
                pos += 1
                backgroundSubagentCount = try readU16(data, pos)
                pos += 2
                let labelLen = Int(try readU16(data, pos))
                pos += 2
                guard sectionLen >= (pos - sStart) + labelLen else { throw ProtocolDecodeError.malformed }
                backgroundSubagentLabel = try decodeUTF8(data[pos..<(pos + labelLen)]) ?? ""
                pos += labelLen
                if pos < sectionEnd {
                    let toolLen = Int(data[pos])
                    pos += 1
                    guard sectionLen >= (pos - sStart) + toolLen else { throw ProtocolDecodeError.malformed }
                    activeToolName = try decodeUTF8(data[pos..<(pos + toolLen)]) ?? ""
                }
            } else {
                guard sectionLen >= 1 else { throw ProtocolDecodeError.malformed }
                var pos = sStart
                let mnLen = Int(data[pos])
                guard sectionLen >= 11 + mnLen else { throw ProtocolDecodeError.malformed }
                pos += 1
                modelName = try decodeUTF8(data[pos..<(pos + mnLen)]) ?? ""
                pos += mnLen
                messageCount = try readU32(data, pos)
                pos += 4
                sessionStatus = data[pos]
                pos += 1
                agentStatus = data[pos]
                pos += 1
                backgroundSubagentCount = try readU16(data, pos)
                pos += 2
                let labelLen = Int(try readU16(data, pos))
                pos += 2
                guard sectionLen >= (pos - sStart) + labelLen else { throw ProtocolDecodeError.malformed }
                backgroundSubagentLabel = try decodeUTF8(data[pos..<(pos + labelLen)]) ?? ""
                pos += labelLen
                if pos < sectionEnd {
                    let toolLen = Int(data[pos])
                    pos += 1
                    guard sectionLen >= (pos - sStart) + toolLen else { throw ProtocolDecodeError.malformed }
                    activeToolName = try decodeUTF8(data[pos..<(pos + toolLen)]) ?? ""
                }
            }
        }

        let update = StatusBarUpdate(
            contentKind: contentKind, mode: mode,
            cursorLine: cursorLine, cursorCol: cursorCol, lineCount: lineCount,
            flags: flags, safeMode: (flags & 0x08) != 0,
            lspStatus: lspStatus, gitBranch: gitBranch,
            message: message, filetype: filetype,
            errorCount: errorCount, warningCount: warningCount,
            modelName: modelName, messageCount: messageCount, sessionStatus: sessionStatus,
            infoCount: infoCount, hintCount: hintCount, macroRecording: macroRecording,
            parserStatus: parserStatus, agentStatus: agentStatus,
            activeToolName: activeToolName,
            gitAdded: gitAdded, gitModified: gitModified, gitDeleted: gitDeleted,
            icon: icon, iconColorR: iconColorR, iconColorG: iconColorG, iconColorB: iconColorB,
            filename: filename, diagnosticHint: diagnosticHint,
            backgroundSubagentCount: backgroundSubagentCount,
            backgroundSubagentLabel: backgroundSubagentLabel,
            indent: indent,
            modelineSegmentsPresent: modelineSegmentsPresent,
            modelineLeftSegments: modelineLeftSegments,
            modelineRightSegments: modelineRightSegments,
            selection: selection,
            workspace: workspace,
            pendingKeys: pendingKeys
        )
        return (.guiStatusBar(update), pos - offset)

    case OP_GUI_PICKER:
        // Sectioned format: opcode(1) + section_count(1) + sections...
        // Hidden picker: opcode(1) + 0(1) (zero sections, visible defaults to false)
        guard data.count >= rest + 1 else { throw ProtocolDecodeError.malformed }
        let pickerSectionCount = Int(data[rest])
        if pickerSectionCount == 0 {
            return (.guiPicker(visible: false, selectedIndex: 0, filteredCount: 0, totalCount: 0, markedCount: 0, title: "", query: "", hasPreview: false, items: [], actionMenu: nil, modePrefix: "", loadStatus: .ready), 2)
        }
        var pickerPos = rest + 1
        var pkVisible = false
        var pkSelectedIndex: UInt16 = 0
        var pkFilteredCount: UInt16 = 0
        var pkTotalCount: UInt16 = 0
        var pkMarkedCount: UInt16 = 0
        var pkHasPreview = false
        var pkTitle = ""
        var pkQuery = ""
        var pkItems: [Wire.PickerItem] = []
        var pkActionMenu: Wire.PickerActionMenu? = nil
        var pkModePrefix = ""
        var pkLoadStatus: Wire.PickerLoadStatus = .ready

        // The section-dispatch loop stays hand-written (it owns the outer framing);
        // each section body is decoded by the schema-generated, window-aware
        // decoder. `psEnd = psStart + psLen` is the section window: every generated
        // read bounds against it, and the header's optional title/marked_count tail
        // degrades to its zero value when the window is short, reproducing the old
        // `if psLen >= 10` ladder. A truncated section throws, which the caller maps
        // to .malformed exactly as before.
        for _ in 0..<pickerSectionCount {
            guard data.count >= pickerPos + 3 else { throw ProtocolDecodeError.malformed }
            let psId = data[pickerPos]
            let psLen = Int(try readU16(data, pickerPos + 1))
            let psStart = pickerPos + 3
            guard data.count >= psStart + psLen else { throw ProtocolDecodeError.malformed }
            let psEnd = psStart + psLen

            do {
                switch psId {
                case 0x01: // Header
                    let (h, _) = try GeneratedProtocol.decodeGuiPickerHeader(data, psStart, psEnd)
                    pkVisible = h.visible != 0
                    pkSelectedIndex = h.selectedIndex
                    pkFilteredCount = h.filteredCount
                    pkTotalCount = h.totalCount
                    pkHasPreview = h.hasPreview != 0
                    pkTitle = h.title
                    pkMarkedCount = h.markedCount

                case 0x02: // Query
                    let (q, _) = try GeneratedProtocol.decodeGuiPickerQuery(data, psStart, psEnd)
                    pkQuery = q.text

                case 0x05: // Mode prefix
                    let (m, _) = try GeneratedProtocol.decodeGuiPickerModePrefix(data, psStart, psEnd)
                    pkModePrefix = m.text

                case 0x03: // Items
                    let (items, _) = try GeneratedProtocol.decodeGuiPickerItems(data, psStart, psEnd)
                    try FrameDecodeAccounting.reserve(.arrayEntries, items.count)
                    pkItems = items.map {
                        Wire.PickerItem(
                            iconColor: $0.iconColor, flags: $0.flags, label: $0.label,
                            description: $0.description, annotation: $0.annotation,
                            matchPositions: $0.matchPositions
                        )
                    }

                case 0x04: // Action menu
                    let (m, _) = try GeneratedProtocol.decodeGuiPickerActionMenu(data, psStart, psEnd)
                    if m.visible != 0 {
                        pkActionMenu = Wire.PickerActionMenu(selectedIndex: m.selectedIndex, actions: m.actions)
                    }

                case 0x06: // LoadStatus
                    let (s, _) = try GeneratedProtocol.decodeGuiPickerLoadStatus(data, psStart, psEnd)
                    switch s.status {
                    case 1: pkLoadStatus = .loading
                    // The encoder always writes a (valid-UTF-8) message for status 2,
                    // so the generated decoder reproduces it exactly; the old
                    // `?? "Unknown error"` fallback only covered invalid UTF-8, which
                    // the wire never carries.
                    case 2: pkLoadStatus = .error(s.message)
                    default: pkLoadStatus = .ready
                    }

                default: break
                }
            } catch let error as FrameResourceError {
                throw error
            } catch {
                throw ProtocolDecodeError.malformed
            }

            pickerPos = psEnd
        }

        return (.guiPicker(visible: pkVisible, selectedIndex: pkSelectedIndex, filteredCount: pkFilteredCount, totalCount: pkTotalCount, markedCount: pkMarkedCount, title: pkTitle, query: pkQuery, hasPreview: pkHasPreview, items: pkItems, actionMenu: pkActionMenu, modePrefix: pkModePrefix, loadStatus: pkLoadStatus), pickerPos - offset)

    case OP_GUI_PICKER_PREVIEW:
        guard data.count >= rest + 1 else { throw ProtocolDecodeError.malformed }
        let visible = data[rest] != 0
        if !visible {
            return (.guiPickerPreview(visible: false, lines: []), 2)
        }
        guard data.count >= rest + 3 else { throw ProtocolDecodeError.malformed }
        let lineCount = Int(try readU16(data, rest + 1))
        var lines: [Wire.PickerPreviewLine] = []
        try FrameDecodeAccounting.reserve(.arrayEntries, lineCount)
        lines.reserveCapacity(lineCount)
        var pos2 = rest + 3
        for _ in 0..<lineCount {
            guard data.count >= pos2 + 1 else { throw ProtocolDecodeError.malformed }
            let segCount = Int(data[pos2])
            pos2 += 1
            var segments: Wire.PickerPreviewLine = []
            try FrameDecodeAccounting.reserve(.arrayEntries, segCount)
            segments.reserveCapacity(segCount)
            for _ in 0..<segCount {
                guard data.count >= pos2 + 6 else { throw ProtocolDecodeError.malformed }
                let fgColor = try readU24(data, pos2)
                let segFlags = data[pos2 + 3]
                let textLen = Int(try readU16(data, pos2 + 4))
                guard data.count >= pos2 + 6 + textLen else { throw ProtocolDecodeError.malformed }
                let text = try decodeUTF8(data[(pos2 + 6)..<(pos2 + 6 + textLen)]) ?? ""
                try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                segments.append(Wire.PickerPreviewSegment(fgColor: UInt32(fgColor), bold: segFlags & 0x01 != 0, text: text))
                pos2 += 6 + textLen
            }
            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            lines.append(segments)
        }
        return (.guiPickerPreview(visible: true, lines: lines), pos2 - offset)

    case OP_GUI_AGENT_CHAT:
        // Sectioned format: opcode(1) + section_count(1) + sections...
        // Hidden: opcode(1) + 0(1)
        guard data.count >= rest + 1 else { throw ProtocolDecodeError.malformed }
        let chatSectionCount = Int(data[rest])
        if chatSectionCount == 0 {
            return (.guiAgentChat(visible: false, status: 0, model: "", thinkingLevel: "", prompt: "", promptLineCount: 1, promptCursorLine: 0, promptCursorCol: 0, promptVimMode: 0, promptVisibleRows: 1, promptCompletion: nil, pendingToolName: nil, pendingToolSummary: "", helpVisible: false, helpGroups: [], messages: []), 2)
        }
        var chatPos = rest + 1
        var chatVisible = false
        var chatStatus: UInt8 = 0
        var chatModel = ""
        var chatThinkingLevel = ""
        var chatPrompt = ""
        var promptLineCount: UInt8 = 1
        var promptCursorLine: UInt16 = 0
        var promptCursorCol: UInt16 = 0
        var promptVimMode: UInt8 = 0
        var promptVisibleRows: UInt8 = 1
        var promptCompletion: Wire.PromptCompletion? = nil
        var pendingToolName: String? = nil
        var pendingToolSummary: String = ""
        var helpVisible = false
        var helpGroups: [Wire.HelpGroup] = []
        var messages: [Wire.ChatMessage] = []

        for _ in 0..<chatSectionCount {
            guard data.count >= chatPos + 3 else { throw ProtocolDecodeError.malformed }
            let csId = data[chatPos]
            let csLen = Int(try readU16(data, chatPos + 1))
            let csStart = chatPos + 3
            guard data.count >= csStart + csLen else { throw ProtocolDecodeError.malformed }

            switch csId {
            case 0x01: // Header: visible(1) + status(1)
                guard csLen >= 2 else { break }
                chatVisible = data[csStart] != 0
                chatStatus = data[csStart + 1]

            case 0x02: // Model: model_len(2) + model
                guard csLen >= 2 else { break }
                let mLen = Int(try readU16(data, csStart))
                if csLen >= 2 + mLen { chatModel = try decodeUTF8(data[(csStart + 2)..<(csStart + 2 + mLen)]) ?? "" }

            case 0x03: // Prompt: prompt_len(2) + prompt + line_count(1) + cursor_line(2) + cursor_col(2) + vim_mode(1) + visible_rows(1)
                guard csLen >= 2 else { break }
                let pLen = Int(try readU16(data, csStart))
                if csLen >= 2 + pLen { chatPrompt = try decodeUTF8(data[(csStart + 2)..<(csStart + 2 + pLen)]) ?? "" }
                let metaStart = csStart + 2 + pLen
                if csLen >= 2 + pLen + 7 {
                    promptLineCount = data[metaStart]
                    promptCursorLine = try readU16(data, metaStart + 1)
                    promptCursorCol = try readU16(data, metaStart + 3)
                    promptVimMode = data[metaStart + 5]
                    promptVisibleRows = data[metaStart + 6]
                }

            case 0x08: // Thinking level: level_len(2) + level
                guard csLen >= 2 else { break }
                let tLen = Int(try readU16(data, csStart))
                if csLen >= 2 + tLen { chatThinkingLevel = try decodeUTF8(data[(csStart + 2)..<(csStart + 2 + tLen)]) ?? "" }

            case 0x07: // Completion: visible(1) [type(1) selected(1) anchor_line(2) anchor_col(2) count(1) candidates...]
                guard csLen >= 1 else { break }
                let hasCompletion = data[csStart] != 0
                if hasCompletion, csLen >= 8 {
                    let compType = data[csStart + 1]
                    let compSelected = data[csStart + 2]
                    let compAnchorLine = try readU16(data, csStart + 3)
                    let compAnchorCol = try readU16(data, csStart + 5)
                    let compCount = Int(data[csStart + 7])
                    var candidates: [(name: String, description: String)] = []
                    var cp = csStart + 8
                    for _ in 0..<compCount {
                        guard cp + 2 <= csStart + csLen else { break }
                        let nLen = Int(try readU16(data, cp)); cp += 2
                        guard cp + nLen + 2 <= csStart + csLen else { break }
                        let name = try decodeUTF8(data[cp..<(cp + nLen)]) ?? ""; cp += nLen
                        let dLen = Int(try readU16(data, cp)); cp += 2
                        guard cp + dLen <= csStart + csLen else { break }
                        let desc = try decodeUTF8(data[cp..<(cp + dLen)]) ?? ""; cp += dLen
                        try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                        candidates.append((name: name, description: desc))
                    }
                    promptCompletion = Wire.PromptCompletion(type: compType, selected: compSelected, anchorLine: compAnchorLine, anchorCol: compAnchorCol, candidates: candidates)
                }

            case 0x04: // Pending: same format as before (has_pending(1) [name_len(2) name summary_len(2) summary])
                guard csLen >= 1 else { break }
                let hasPending = data[csStart] != 0
                if hasPending, csLen >= 3 {
                    var pp = csStart + 1
                    let pnLen = Int(try readU16(data, pp)); pp += 2
                    guard pp + pnLen + 2 <= csStart + csLen else { break }
                    pendingToolName = try decodeUTF8(data[pp..<(pp + pnLen)]) ?? ""
                    pp += pnLen
                    let psLen = Int(try readU16(data, pp)); pp += 2
                    guard pp + psLen <= csStart + csLen else { break }
                    pendingToolSummary = try decodeUTF8(data[pp..<(pp + psLen)]) ?? ""
                }

            case 0x05: // Help: same format as before (visible(1) [group_count(1) ...])
                guard csLen >= 1 else { break }
                helpVisible = data[csStart] != 0
                if helpVisible, csLen >= 2 {
                    let groupCount = Int(data[csStart + 1])
                    var hp = csStart + 2
                    for _ in 0..<groupCount {
                        guard hp + 2 <= csStart + csLen else { break }
                        let tLen = Int(try readU16(data, hp)); hp += 2
                        guard hp + tLen + 1 <= csStart + csLen else { break }
                        let title = try decodeUTF8(data[hp..<(hp + tLen)]) ?? ""
                        hp += tLen
                        let bCount = Int(data[hp]); hp += 1
                        var bindings: [(key: String, description: String)] = []
                        for _ in 0..<bCount {
                            guard hp + 1 <= csStart + csLen else { break }
                            let kLen = Int(data[hp]); hp += 1
                            guard hp + kLen + 2 <= csStart + csLen else { break }
                            let key = try decodeUTF8(data[hp..<(hp + kLen)]) ?? ""
                            hp += kLen
                            let dLen = Int(try readU16(data, hp)); hp += 2
                            guard hp + dLen <= csStart + csLen else { break }
                            let desc = try decodeUTF8(data[hp..<(hp + dLen)]) ?? ""
                            hp += dLen
                            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                            bindings.append((key: key, description: desc))
                        }
                        try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                        helpGroups.append(Wire.HelpGroup(title: title, bindings: bindings))
                    }
                }

            case 0x06: // Messages: framed v1 payload, with legacy unframed fallback
                guard csLen >= 2 else { break }
                let messagesEnd = csStart + csLen
                if data[csStart] == 0xFF {
                    guard csLen >= 4 else { throw ProtocolDecodeError.malformed }
                    let version = data[csStart + 1]
                    guard version == 1 else { throw ProtocolDecodeError.malformed }
                    let msgCount = Int(try readU16(data, csStart + 2))
                    let decodedMessages = try decodeFramedChatMessages(
                        data: data,
                        start: csStart + 4,
                        end: messagesEnd,
                        count: msgCount
                    )
                    try FrameDecodeAccounting.reserve(.arrayEntries, decodedMessages.count)
                    messages.append(contentsOf: decodedMessages)
                } else {
                    let msgCount = Int(try readU16(data, csStart))
                    let messagesStart = csStart + 2
                    let (decodedMessages, decodedEnd) = try decodeLegacyChatMessages(
                        data: data,
                        start: messagesStart,
                        end: messagesEnd,
                        remaining: msgCount
                    )
                    try FrameDecodeAccounting.reserve(.arrayEntries, decodedMessages.count)
                    messages.append(contentsOf: decodedMessages)
                    guard decodedEnd == messagesEnd else { throw ProtocolDecodeError.malformed }
                }

            default: break
            }

            chatPos = csStart + csLen
        }

        return (.guiAgentChat(visible: chatVisible, status: chatStatus, model: chatModel, thinkingLevel: chatThinkingLevel, prompt: chatPrompt, promptLineCount: promptLineCount, promptCursorLine: promptCursorLine, promptCursorCol: promptCursorCol, promptVimMode: promptVimMode, promptVisibleRows: promptVisibleRows, promptCompletion: promptCompletion, pendingToolName: pendingToolName, pendingToolSummary: pendingToolSummary, helpVisible: helpVisible, helpGroups: helpGroups, messages: messages), chatPos - offset)

    case OP_GUI_AGENT_TRANSCRIPT:
        // len32 framing: opcode(1) + payload_len(4) + payload (GUI_PROTOCOL.md 0x86).
        //   header: version(1)=1 + mode(1) + epoch(4) + truncated(1)
        //   full_replace (mode 0): count(4)
        //   append (mode 1): trim_front(4) + base_count(4) + count(4)
        //   both: count * [ id(4), body_len(4), body ]. Body is the shared 0x78 codec.
        guard data.count >= rest + 4 else { throw ProtocolDecodeError.malformed }
        let transcriptPayloadLen = Int(try readU32(data, rest))
        let transcriptPayloadStart = rest + 4
        let transcriptEnd = transcriptPayloadStart + transcriptPayloadLen
        guard data.count >= transcriptEnd else { throw ProtocolDecodeError.malformed }
        // Minimum: 7-byte header + full_replace count(4).
        guard transcriptPayloadLen >= 11 else { throw ProtocolDecodeError.malformed }

        let transcriptVersion = data[transcriptPayloadStart]
        guard transcriptVersion == 1 else { throw ProtocolDecodeError.malformed }
        let transcriptMode = data[transcriptPayloadStart + 1]
        // Only full_replace (0) and append (1) exist. Rejecting anything else here is
        // load-bearing: the layout branch below is mode==1-shaped while the consumer's
        // apply branch is mode==0-shaped, so an unknown mode passed through would be
        // parsed with one layout and applied with the other (split-brain).
        guard transcriptMode <= 1 else { throw ProtocolDecodeError.malformed }
        let transcriptEpoch = try readU32(data, transcriptPayloadStart + 2)
        let transcriptTruncated = data[transcriptPayloadStart + 6] != 0

        let transcriptTrimFront: UInt32
        let transcriptBaseCount: UInt32
        let transcriptCount: Int
        var transcriptPos: Int
        if transcriptMode == 1 {
            // append: trim_front(4) + base_count(4) + count(4) after the 7-byte header.
            guard transcriptPayloadLen >= 19 else { throw ProtocolDecodeError.malformed }
            transcriptTrimFront = try readU32(data, transcriptPayloadStart + 7)
            transcriptBaseCount = try readU32(data, transcriptPayloadStart + 11)
            transcriptCount = Int(try readU32(data, transcriptPayloadStart + 15))
            transcriptPos = transcriptPayloadStart + 19
        } else {
            // full_replace: count(4) after the 7-byte header.
            transcriptTrimFront = 0
            transcriptBaseCount = 0
            transcriptCount = Int(try readU32(data, transcriptPayloadStart + 7))
            transcriptPos = transcriptPayloadStart + 11
        }

        // A corrupt count must fail as .malformed, not as a giant allocation: each entry
        // needs at least its 8-byte id+body_len header, so count is bounded by the payload.
        guard transcriptCount <= (transcriptEnd - transcriptPos) / 8 else {
            throw ProtocolDecodeError.malformed
        }
        var transcriptMessages: [Wire.ChatMessage] = []
        try FrameDecodeAccounting.reserve(.arrayEntries, transcriptCount)
        transcriptMessages.reserveCapacity(transcriptCount)
        for _ in 0..<transcriptCount {
            guard transcriptPos + 8 <= transcriptEnd else { throw ProtocolDecodeError.malformed }
            let entryId = try readU32(data, transcriptPos)
            let bodyLen = Int(try readU32(data, transcriptPos + 4))
            let bodyStart = transcriptPos + 8
            let bodyEnd = bodyStart + bodyLen
            guard bodyEnd <= transcriptEnd else { throw ProtocolDecodeError.malformed }

            let candidates = try decodeChatMessageBodyCandidates(data: data, beamId: entryId, bodyStart: bodyStart, end: bodyEnd)
            guard let candidate = candidates.first(where: { $0.nextOffset == bodyEnd }) else {
                throw ProtocolDecodeError.malformed
            }
            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            transcriptMessages.append(candidate.message)
            transcriptPos = bodyEnd
        }

        guard transcriptPos == transcriptEnd else { throw ProtocolDecodeError.malformed }
        return (.guiAgentTranscript(mode: transcriptMode, epoch: transcriptEpoch, truncated: transcriptTruncated, trimFront: transcriptTrimFront, baseCount: transcriptBaseCount, messages: transcriptMessages), 1 + 4 + transcriptPayloadLen)

    case OP_GUI_GUTTER_SEP:
        // col:2, r:1, g:1, b:1 = 5 bytes after opcode
        guard data.count >= rest + 5 else { throw ProtocolDecodeError.malformed }
        let col = try readU16(data, rest)
        return (.guiGutterSeparator(col: col, r: data[rest + 2], g: data[rest + 3], b: data[rest + 4]), 6)

    case OP_GUI_CURSORLINE:
        // row:2, r:1, g:1, b:1 = 5 bytes after opcode
        guard data.count >= rest + 5 else { throw ProtocolDecodeError.malformed }
        let row = try readU16(data, rest)
        return (.guiCursorline(row: row, r: data[rest + 2], g: data[rest + 3], b: data[rest + 4]), 6)

    case OP_GUI_GUTTER:
        // Sectioned format: opcode(1) + section_count(1) + sections...
        guard data.count >= rest + 1 else { throw ProtocolDecodeError.malformed }
        let gutterSectionCount = Int(data[rest])
        var gutterPos = rest + 1

        var windowId: UInt16 = 0
        var contentRow: UInt16 = 0
        var contentCol: UInt16 = 0
        var contentHeight: UInt16 = 0
        var contentWidth: UInt16 = 0
        var isActive = false
        var cursorLine: UInt32 = 0
        var style: Wire.LineNumberStyle = .hybrid
        var lnWidth: UInt8 = 0
        var signWidth: UInt8 = 0
        var entries: [Wire.GutterEntry] = []

        for _ in 0..<gutterSectionCount {
            guard data.count >= gutterPos + 3 else { throw ProtocolDecodeError.malformed }
            let gsId = data[gutterPos]
            let gsLen = Int(try readU16(data, gutterPos + 1))
            let gsStart = gutterPos + 3
            let gsEnd = gsStart + gsLen
            guard data.count >= gsEnd else { throw ProtocolDecodeError.malformed }

            switch gsId {
            case 0x01: // Window: window_id(2) + row(2) + col(2) + height(2) + is_active(1) [+ width(2)]
                guard gsLen >= 9 else { break }
                windowId = try readU16(data, gsStart)
                contentRow = try readU16(data, gsStart + 2)
                contentCol = try readU16(data, gsStart + 4)
                contentHeight = try readU16(data, gsStart + 6)
                isActive = data[gsStart + 8] != 0
                contentWidth = gsLen >= 11 ? try readU16(data, gsStart + 9) : 0

            case 0x02: // Config: cursor_line(4) + style(1) + ln_width(1) + sign_width(1)
                guard gsLen >= 7 else { break }
                cursorLine = try readU32(data, gsStart)
                style = Wire.LineNumberStyle(rawValue: data[gsStart + 4]) ?? .hybrid
                lnWidth = data[gsStart + 5]
                signWidth = data[gsStart + 6]

            case 0x03: // Entries: count(2) + entries...
                guard gsLen >= 2 else { throw ProtocolDecodeError.malformed }
                let lineCount = Int(try readU16(data, gsStart))
                try FrameDecodeAccounting.reserve(.arrayEntries, lineCount)
                entries.reserveCapacity(lineCount)
                var ePos = gsStart + 2
                for _ in 0..<lineCount {
                    guard gsEnd >= ePos + 10 else { throw ProtocolDecodeError.malformed }
                    let bufLine = try readU32(data, ePos)
                    let dt = Wire.GutterDisplayType(rawValue: data[ePos + 4]) ?? .normal
                    let st = Wire.GutterSignType(rawValue: data[ePos + 5]) ?? .none
                    let rawFoldEndLine = try readU32(data, ePos + 6)
                    let foldEndLine: UInt32? = rawFoldEndLine == UInt32.max ? nil : rawFoldEndLine
                    ePos += 10
                    if st == .annotation {
                        guard gsEnd >= ePos + 4 else { throw ProtocolDecodeError.malformed }
                        let fg = try readU24(data, ePos)
                        let textLen = Int(data[ePos + 3])
                        ePos += 4
                        guard gsEnd >= ePos + textLen else { throw ProtocolDecodeError.malformed }
                        let text = try decodeUTF8(data[ePos..<(ePos + textLen)]) ?? ""
                        ePos += textLen
                        try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                        entries.append(Wire.GutterEntry(bufLine: bufLine, displayType: dt, signType: st, foldEndLine: foldEndLine, signFg: fg, signText: text))
                    } else {
                        try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                        entries.append(Wire.GutterEntry(bufLine: bufLine, displayType: dt, signType: st, foldEndLine: foldEndLine))
                    }
                }

            default: break
            }

            gutterPos = gsStart + gsLen
        }

        let windowGutter = Wire.WindowGutter(
            windowId: windowId, contentRow: contentRow, contentCol: contentCol,
            contentHeight: contentHeight, isActive: isActive, contentWidth: contentWidth,
            cursorLine: cursorLine, lineNumberStyle: style, lineNumberWidth: lnWidth,
            signColWidth: signWidth, entries: entries
        )
        return (.guiGutter(data: windowGutter), gutterPos - offset)

    case OP_GUI_BOTTOM_PANEL:
        // visible(1)
        guard data.count >= rest + 1 else { throw ProtocolDecodeError.malformed }
        let visible = data[rest] != 0
        guard visible else {
            return (.guiBottomPanel(visible: false, activeTabIndex: 0, heightPercent: 30,
                                     filterPreset: 0, tabs: [], entries: []), 2)
        }
        // visible=1(1) + active_tab_index(1) + height_percent(1) + filter_preset(1) + tab_count(1) = 5 bytes
        guard data.count >= rest + 5 else { throw ProtocolDecodeError.malformed }
        let activeTabIndex = data[rest + 1]
        let heightPercent = data[rest + 2]
        let filterPreset = data[rest + 3]
        let tabCount = Int(data[rest + 4])
        var pos = rest + 5
        var tabs: [Wire.BottomPanelTab] = []
        for _ in 0..<tabCount {
            guard data.count >= pos + 2 else { throw ProtocolDecodeError.malformed }
            let tabType = data[pos]
            let nameLen = Int(data[pos + 1])
            pos += 2
            guard data.count >= pos + nameLen else { throw ProtocolDecodeError.malformed }
            let name = try decodeUTF8(data[pos..<(pos + nameLen)]) ?? ""
            pos += nameLen
            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            tabs.append(Wire.BottomPanelTab(tabType: tabType, name: name))
        }
        // Messages content payload: stream_instance(4) + entry_count(2) + entries...
        var entries: [Wire.MessageEntry] = []
        guard data.count >= pos + 6 else {
            return (.guiBottomPanel(visible: true, activeTabIndex: activeTabIndex,
                                     heightPercent: heightPercent, filterPreset: filterPreset,
                                     tabs: tabs, entries: []), pos - offset)
        }
        let streamInstance = try readU32(data, pos)
        let entryCount = Int(try readU16(data, pos + 4))
        pos += 6
        for _ in 0..<entryCount {
            // id(4) + level(1) + subsystem(1) + timestamp_secs(4) + path_len(2)
            guard data.count >= pos + 12 else { break }
            let entryId = try readU32(data, pos)
            let level = data[pos + 4]
            let subsystem = data[pos + 5]
            let tsSecs = try readU32(data, pos + 6)
            let pathLen = Int(try readU16(data, pos + 10))
            pos += 12
            guard data.count >= pos + pathLen else { break }
            let filePath = try decodeUTF8(data[pos..<(pos + pathLen)]) ?? ""
            pos += pathLen
            // text_len(2) + text
            guard data.count >= pos + 2 else { break }
            let textLen = Int(try readU16(data, pos))
            pos += 2
            guard data.count >= pos + textLen else { break }
            let text = try decodeUTF8(data[pos..<(pos + textLen)]) ?? ""
            pos += textLen
            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            entries.append(Wire.MessageEntry(streamInstance: streamInstance, id: entryId, level: level, subsystem: subsystem,
                                            timestampSecs: tsSecs, filePath: filePath, text: text))
        }
        return (.guiBottomPanel(visible: true, activeTabIndex: activeTabIndex,
                                 heightPercent: heightPercent, filterPreset: filterPreset,
                                 tabs: tabs, entries: entries), pos - offset)

    case OP_GUI_WINDOW_CONTENT:
        // len32 command framing plus u32 section lengths:
        // opcode(1) + payload_len(4) + section_count(1) + sections...
        guard data.count >= rest + 4 else { throw ProtocolDecodeError.malformed }
        let wcPayloadLen = Int(try readU32(data, rest))
        let wcPayloadStart = rest + 4
        let wcPayloadEnd = wcPayloadStart + wcPayloadLen
        guard wcPayloadLen >= 1, data.count >= wcPayloadEnd else { throw ProtocolDecodeError.malformed }
        let wcSectionCount = Int(data[wcPayloadStart])
        var wcPos = wcPayloadStart + 1

        var wcWindowId: UInt16 = 0
        var wcFlags: UInt8 = 0
        var wcCursorRow: UInt16 = 0
        var wcCursorCol: UInt16 = 0
        var wcCursorShape: CursorShape = .block
        var wcScrollLeft: UInt16 = 0
        var wcContentEpoch: UInt32 = 0
        var wcRows: [GUIVisualRow] = []
        var wcOverlays = DecodedOverlaySections()
        var wcSawHeader = false
        var wcSawRows = false

        for _ in 0..<wcSectionCount {
            guard wcPayloadEnd >= wcPos + 5 else { throw ProtocolDecodeError.malformed }
            let wcSId = data[wcPos]
            let wcSLen = Int(try readU32(data, wcPos + 1))
            let wcSStart = wcPos + 5
            guard wcPayloadEnd >= wcSStart + wcSLen else { throw ProtocolDecodeError.malformed }

            switch wcSId {
            case 0x01: // Header: window_id(2) + flags(1) + cursor_row(2) + cursor_col(2) + cursor_shape(1) + scroll_left(2) + optional content_epoch(4)
                guard !wcSawHeader, wcSLen >= 10 else { throw ProtocolDecodeError.malformed }
                wcSawHeader = true
                wcWindowId = try readU16(data, wcSStart)
                wcFlags = data[wcSStart + 2]
                wcCursorRow = try readU16(data, wcSStart + 3)
                wcCursorCol = try readU16(data, wcSStart + 5)
                wcCursorShape = CursorShape(rawValue: data[wcSStart + 7]) ?? .block
                wcScrollLeft = try readU16(data, wcSStart + 8)
                if wcSLen >= 14 {
                    wcContentEpoch = try readU32(data, wcSStart + 10)
                }

            case 0x02: // Rows: row_count(4) + rows...
                guard !wcSawRows else { throw ProtocolDecodeError.malformed }
                wcSawRows = true
                wcRows = try decodeWindowContentRows(data: data, start: wcSStart, end: wcSStart + wcSLen)

            case 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A:
                _ = try decodeOverlaySection(id: wcSId, data: data, start: wcSStart, length: wcSLen, end: wcSStart + wcSLen, into: &wcOverlays)

            default: break
            }

            wcPos = wcSStart + wcSLen
        }
        guard wcPos == wcPayloadEnd, wcSawHeader, wcSawRows else { throw ProtocolDecodeError.malformed }

        let scrollPresentation = try validatedScrollPresentation(wcOverlays.scrollPresentation, windowId: wcWindowId, contentEpoch: wcContentEpoch)

        let content = try GUIWindowContent(
            windowId: wcWindowId,
            fullRefresh: (wcFlags & 0x01) != 0,
            contentEpoch: wcContentEpoch,
            cursorVisible: (wcFlags & 0x02) != 0,
            cursorRow: wcCursorRow,
            cursorCol: wcCursorCol,
            cursorShape: wcCursorShape,
            scrollLeft: wcScrollLeft,
            rows: wcRows,
            selection: wcOverlays.selection,
            searchMatches: wcOverlays.searchMatches,
            diagnosticUnderlines: wcOverlays.diagnosticUnderlines,
            documentHighlights: wcOverlays.documentHighlights,
            lineAnnotations: wcOverlays.lineAnnotations,
            paneGeometry: wcOverlays.paneGeometry,
            cursorline: wcOverlays.cursorline,
            scrollPresentation: scrollPresentation,
            residentLimit: FrameDecodeAccounting.residentLimit
        )
        return (.guiWindowContent(data: content), 1 + 4 + wcPayloadLen)

    case OP_GUI_WINDOW_OVERLAY_DELTA:
        guard data.count >= rest + 12 else { throw ProtocolDecodeError.malformed }
        let windowId = try readU16(data, rest)
        let contentEpoch = try readU32(data, rest + 2)
        let flags = data[rest + 6]
        let cursorRow = try readU16(data, rest + 7)
        let cursorCol = try readU16(data, rest + 9)
        let cursorShape = CursorShape(rawValue: data[rest + 11]) ?? .block
        let hasCursorline = flags & 0x02 != 0
        let cursorVisible = flags & 0x01 != 0

        if hasCursorline {
            guard data.count >= rest + 17 else { throw ProtocolDecodeError.malformed }
            let cursorline = GUICursorline(row: try readU16(data, rest + 12), bg: try readU24(data, rest + 14))
            let delta = GUIWindowOverlayDelta(windowId: windowId, contentEpoch: contentEpoch,
                                             cursorVisible: cursorVisible, cursorRow: cursorRow,
                                             cursorCol: cursorCol, cursorShape: cursorShape,
                                             cursorline: cursorline)
            return (.guiWindowOverlayDelta(data: delta), 18)
        } else {
            let delta = GUIWindowOverlayDelta(windowId: windowId, contentEpoch: contentEpoch,
                                             cursorVisible: cursorVisible, cursorRow: cursorRow,
                                             cursorCol: cursorCol, cursorShape: cursorShape,
                                             cursorline: nil)
            return (.guiWindowOverlayDelta(data: delta), 13)
        }

    case OP_GUI_WINDOW_VIEWPORT_DELTA:
        let (delta, consumed) = try decodeWindowRowsDelta(data: data, offset: offset, allowsRowSplices: false)
        return (.guiWindowViewportDelta(data: delta), consumed)

    case OP_GUI_WINDOW_ROWS_DELTA:
        let (delta, consumed) = try decodeWindowRowsDelta(data: data, offset: offset, allowsRowSplices: true)
        return (.guiWindowRowsDelta(data: delta), consumed)

    case OP_GUI_TOOL_MANAGER:
        // visible(1)
        guard data.count >= rest + 1 else { throw ProtocolDecodeError.malformed }
        let visible = data[rest] != 0
        guard visible else {
            return (.guiToolManager(visible: false, filter: 0, selectedIndex: 0, tools: []), 2)
        }
        // filter(1) + selected_index(2) + tool_count(2)
        guard data.count >= rest + 6 else { throw ProtocolDecodeError.malformed }
        let tmFilter = data[rest + 1]
        let tmSelectedIndex = try readU16(data, rest + 2)
        let toolCount = Int(try readU16(data, rest + 4))
        var pos = rest + 6
        var tools: [Wire.ToolEntry] = []
        try FrameDecodeAccounting.reserve(.arrayEntries, toolCount)
        tools.reserveCapacity(toolCount)
        for _ in 0..<toolCount {
            // name_len(1) + name
            guard data.count >= pos + 1 else { break }
            let nameLen = Int(data[pos]); pos += 1
            guard data.count >= pos + nameLen else { break }
            let name = try decodeUTF8(data[pos..<(pos + nameLen)]) ?? ""
            pos += nameLen
            // label_len(1) + label
            guard data.count >= pos + 1 else { break }
            let labelLen = Int(data[pos]); pos += 1
            guard data.count >= pos + labelLen else { break }
            let toolLabel = try decodeUTF8(data[pos..<(pos + labelLen)]) ?? ""
            pos += labelLen
            // desc_len(2) + desc
            guard data.count >= pos + 2 else { break }
            let descLen = Int(try readU16(data, pos)); pos += 2
            guard data.count >= pos + descLen else { break }
            let desc = try decodeUTF8(data[pos..<(pos + descLen)]) ?? ""
            pos += descLen
            // category(1) + status(1) + method(1) + language_count(1)
            guard data.count >= pos + 4 else { break }
            let cat = data[pos]
            let stat = data[pos + 1]
            let meth = data[pos + 2]
            let langCount = Int(data[pos + 3])
            pos += 4
            var langs: [String] = []
            for _ in 0..<langCount {
                guard data.count >= pos + 1 else { break }
                let lLen = Int(data[pos]); pos += 1
                guard data.count >= pos + lLen else { break }
                let lang = try decodeUTF8(data[pos..<(pos + lLen)]) ?? ""
                pos += lLen
                try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                langs.append(lang)
            }
            // version_len(1) + version
            guard data.count >= pos + 1 else { break }
            let verLen = Int(data[pos]); pos += 1
            guard data.count >= pos + verLen else { break }
            let version = try decodeUTF8(data[pos..<(pos + verLen)]) ?? ""
            pos += verLen
            // homepage_len(2) + homepage
            guard data.count >= pos + 2 else { break }
            let hpLen = Int(try readU16(data, pos)); pos += 2
            guard data.count >= pos + hpLen else { break }
            let homepage = try decodeUTF8(data[pos..<(pos + hpLen)]) ?? ""
            pos += hpLen
            // provides_count(1) + provides
            guard data.count >= pos + 1 else { break }
            let provCount = Int(data[pos]); pos += 1
            var provides: [String] = []
            for _ in 0..<provCount {
                guard data.count >= pos + 1 else { break }
                let cLen = Int(data[pos]); pos += 1
                guard data.count >= pos + cLen else { break }
                let cmd = try decodeUTF8(data[pos..<(pos + cLen)]) ?? ""
                pos += cLen
                try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                provides.append(cmd)
            }
            // error_reason_len(2) + error_reason
            guard data.count >= pos + 2 else { throw ProtocolDecodeError.malformed }
            let errLen = Int(try readU16(data, pos)); pos += 2
            guard data.count >= pos + errLen else { throw ProtocolDecodeError.malformed }
            let errorReason = errLen > 0
                ? (try decodeUTF8(data[pos..<(pos + errLen)]) ?? "")
                : ""
            pos += errLen
            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            tools.append(Wire.ToolEntry(
                name: name, label: toolLabel, description: desc,
                category: cat, status: stat, method: meth,
                languages: langs, version: version,
                homepage: homepage, provides: provides,
                errorReason: errorReason
            ))
        }
        return (.guiToolManager(visible: true, filter: tmFilter,
                                 selectedIndex: tmSelectedIndex, tools: tools), pos - offset)

    case OP_GUI_MINIBUFFER:
        // visible(1)
        guard data.count >= rest + 1 else { throw ProtocolDecodeError.malformed }
        let mbVisible = data[rest] != 0
        guard mbVisible else {
            return (.guiMinibuffer(visible: false, mode: 0, cursorPos: 0xFFFF, prompt: "",
                                    input: "", context: "", selectedIndex: 0, totalCandidates: 0, candidates: []), 2)
        }
        // mode(1) + cursor_pos(2) + prompt_len(1)
        guard data.count >= rest + 5 else { throw ProtocolDecodeError.malformed }
        let mbMode = data[rest + 1]
        let mbCursorPos = try readU16(data, rest + 2)
        let mbPromptLen = Int(data[rest + 4])
        var mbPos = rest + 5
        // prompt
        guard data.count >= mbPos + mbPromptLen else { throw ProtocolDecodeError.malformed }
        let mbPrompt = try decodeUTF8(data[mbPos..<(mbPos + mbPromptLen)]) ?? ""
        mbPos += mbPromptLen
        // input_len(2) + input
        guard data.count >= mbPos + 2 else { throw ProtocolDecodeError.malformed }
        let mbInputLen = Int(try readU16(data, mbPos)); mbPos += 2
        guard data.count >= mbPos + mbInputLen else { throw ProtocolDecodeError.malformed }
        let mbInput = try decodeUTF8(data[mbPos..<(mbPos + mbInputLen)]) ?? ""
        mbPos += mbInputLen
        // context_len(2) + context
        guard data.count >= mbPos + 2 else { throw ProtocolDecodeError.malformed }
        let mbContextLen = Int(try readU16(data, mbPos)); mbPos += 2
        guard data.count >= mbPos + mbContextLen else { throw ProtocolDecodeError.malformed }
        let mbContext = try decodeUTF8(data[mbPos..<(mbPos + mbContextLen)]) ?? ""
        mbPos += mbContextLen
        // selected_index(2) + candidate_count(2) + total_candidates(2)
        guard data.count >= mbPos + 6 else { throw ProtocolDecodeError.malformed }
        let mbSelIndex = try readU16(data, mbPos); mbPos += 2
        let mbCandCount = Int(try readU16(data, mbPos)); mbPos += 2
        let mbTotalCandidates = try readU16(data, mbPos); mbPos += 2
        // candidates
        var mbCandidates: [Wire.MinibufferCandidate] = []
        try FrameDecodeAccounting.reserve(.arrayEntries, mbCandCount)
        mbCandidates.reserveCapacity(mbCandCount)
        for _ in 0..<mbCandCount {
            // match_score(1) + label_len(2)
            guard data.count >= mbPos + 3 else { break }
            let score = data[mbPos]; mbPos += 1
            let candLabelLen = Int(try readU16(data, mbPos)); mbPos += 2
            guard data.count >= mbPos + candLabelLen else { break }
            let candLabel = try decodeUTF8(data[mbPos..<(mbPos + candLabelLen)]) ?? ""
            mbPos += candLabelLen
            // desc_len(2) + desc
            guard data.count >= mbPos + 2 else { break }
            let candDescLen = Int(try readU16(data, mbPos)); mbPos += 2
            guard data.count >= mbPos + candDescLen else { break }
            let candDesc = try decodeUTF8(data[mbPos..<(mbPos + candDescLen)]) ?? ""
            mbPos += candDescLen
            // annotation_len(2) + annotation
            guard data.count >= mbPos + 2 else { break }
            let candAnnotLen = Int(try readU16(data, mbPos)); mbPos += 2
            guard data.count >= mbPos + candAnnotLen else { break }
            let candAnnot = try decodeUTF8(data[mbPos..<(mbPos + candAnnotLen)]) ?? ""
            mbPos += candAnnotLen
            // match_pos_count(1) + match_positions(count * 2)
            guard data.count >= mbPos + 1 else { break }
            let matchPosCount = Int(data[mbPos]); mbPos += 1
            var matchPositions: [UInt16] = []
            try FrameDecodeAccounting.reserve(.arrayEntries, matchPosCount)
            matchPositions.reserveCapacity(matchPosCount)
            for _ in 0..<matchPosCount {
                guard data.count >= mbPos + 2 else { break }
                try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                matchPositions.append(try readU16(data, mbPos)); mbPos += 2
            }
            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            mbCandidates.append(Wire.MinibufferCandidate(matchScore: score, label: candLabel, description: candDesc, annotation: candAnnot, matchPositions: matchPositions))
        }
        return (.guiMinibuffer(visible: true, mode: mbMode, cursorPos: mbCursorPos,
                                prompt: mbPrompt, input: mbInput, context: mbContext,
                                selectedIndex: mbSelIndex, totalCandidates: mbTotalCandidates,
                                candidates: mbCandidates), mbPos - offset)

    case OP_GUI_HOVER_POPUP:
        // visible(1)
        guard data.count >= rest + 1 else { throw ProtocolDecodeError.malformed }
        let hVisible = data[rest] != 0
        guard hVisible else {
            return (.guiHoverPopup(visible: false, anchorRow: 0, anchorCol: 0,
                                    focused: false, scrollOffset: 0, lines: []), 2)
        }
        // anchor_row(2) + anchor_col(2) + focused(1) + scroll_offset(2) + line_count(2)
        guard data.count >= rest + 10 else { throw ProtocolDecodeError.malformed }
        let hAnchorRow = try readU16(data, rest + 1)
        let hAnchorCol = try readU16(data, rest + 3)
        let hFocused = data[rest + 5] != 0
        let hScrollOffset = try readU16(data, rest + 6)
        let hLineCount = Int(try readU16(data, rest + 8))
        var hPos = rest + 10
        var hLines: [Wire.HoverLine] = []
        try FrameDecodeAccounting.reserve(.arrayEntries, hLineCount)
        hLines.reserveCapacity(hLineCount)
        for _ in 0..<hLineCount {
            // line_type(1) + segment_count(2)
            guard data.count >= hPos + 3 else { throw ProtocolDecodeError.malformed }
            let lineType = Wire.HoverLineType(rawValue: data[hPos]) ?? .text
            let segCount = Int(try readU16(data, hPos + 1))
            hPos += 3
            var segments: [Wire.HoverSegment] = []
            try FrameDecodeAccounting.reserve(.arrayEntries, segCount)
            segments.reserveCapacity(segCount)
            for _ in 0..<segCount {
                // standard: style(1) + text_len(2) + text
                // syntaxHighlighted: style(1=13) + fg_rgb(3) + flags(1) + text_len(2) + text
                guard data.count >= hPos + 1 else { throw ProtocolDecodeError.malformed }
                let style = Wire.HoverStyle(rawValue: data[hPos]) ?? .plain
                hPos += 1
                let fgColor: UInt32?
                let flags: UInt8
                let textLen: Int
                if style == .syntaxHighlighted {
                    guard data.count >= hPos + 6 else { throw ProtocolDecodeError.malformed }
                    fgColor = UInt32(try readU24(data, hPos))
                    flags = data[hPos + 3]
                    textLen = Int(try readU16(data, hPos + 4))
                    hPos += 6
                } else {
                    guard data.count >= hPos + 2 else { throw ProtocolDecodeError.malformed }
                    fgColor = nil
                    flags = 0
                    textLen = Int(try readU16(data, hPos))
                    hPos += 2
                }
                guard data.count >= hPos + textLen else { throw ProtocolDecodeError.malformed }
                let text = try decodeUTF8(data[hPos..<(hPos + textLen)]) ?? ""
                hPos += textLen
                try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                segments.append(Wire.HoverSegment(style: style, fgColor: fgColor, flags: flags, text: text))
            }
            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            hLines.append(Wire.HoverLine(lineType: lineType, segments: segments))
        }
        return (.guiHoverPopup(visible: true, anchorRow: hAnchorRow, anchorCol: hAnchorCol,
                                focused: hFocused, scrollOffset: hScrollOffset, lines: hLines),
                hPos - offset)

    case OP_GUI_HOVER_ACTION:
        guard data.count >= rest + 3 else { throw ProtocolDecodeError.malformed }
        let payloadLen = Int(try readU16(data, rest))
        guard data.count >= rest + 2 + payloadLen else { throw ProtocolDecodeError.malformed }
        let payloadStart = rest + 2
        let visible = data[payloadStart] != 0
        guard visible else { return (.guiHoverAction(visible: false, actionName: ""), 3 + payloadLen) }
        guard payloadLen >= 3 else { throw ProtocolDecodeError.malformed }
        let actionLen = Int(try readU16(data, payloadStart + 1))
        guard payloadLen >= 3 + actionLen else { throw ProtocolDecodeError.malformed }
        let actionStart = payloadStart + 3
        let actionData = data[actionStart..<(actionStart + actionLen)]
        let actionName = try decodeUTF8(actionData) ?? ""
        return (.guiHoverAction(visible: true, actionName: actionName), 3 + payloadLen)

    case OP_GUI_SIGNATURE_HELP:
        // visible(1)
        guard data.count >= rest + 1 else { throw ProtocolDecodeError.malformed }
        let shVisible = data[rest] != 0
        guard shVisible else {
            return (.guiSignatureHelp(visible: false, anchorRow: 0, anchorCol: 0,
                                      activeSignature: 0, activeParameter: 0, signatures: []), 2)
        }
        // anchor_row(2) + anchor_col(2) + active_signature(1) + active_parameter(1) + signature_count(1)
        guard data.count >= rest + 8 else { throw ProtocolDecodeError.malformed }
        let shAnchorRow = try readU16(data, rest + 1)
        let shAnchorCol = try readU16(data, rest + 3)
        let shActiveSig = data[rest + 5]
        let shActiveParam = data[rest + 6]
        let shSigCount = Int(data[rest + 7])
        var shPos = rest + 8
        var signatures: [Wire.Signature] = []
        try FrameDecodeAccounting.reserve(.arrayEntries, shSigCount)
        signatures.reserveCapacity(shSigCount)
        for _ in 0..<shSigCount {
            // label_len(2) + label
            guard data.count >= shPos + 2 else { break }
            let labelLen = Int(try readU16(data, shPos)); shPos += 2
            guard data.count >= shPos + labelLen else { break }
            let label = try decodeUTF8(data[shPos..<(shPos + labelLen)]) ?? ""
            shPos += labelLen
            // doc_len(2) + doc
            guard data.count >= shPos + 2 else { break }
            let docLen = Int(try readU16(data, shPos)); shPos += 2
            guard data.count >= shPos + docLen else { break }
            let doc = try decodeUTF8(data[shPos..<(shPos + docLen)]) ?? ""
            shPos += docLen
            // param_count(1)
            guard data.count >= shPos + 1 else { break }
            let paramCount = Int(data[shPos]); shPos += 1
            var params: [Wire.SignatureParameter] = []
            try FrameDecodeAccounting.reserve(.arrayEntries, paramCount)
            params.reserveCapacity(paramCount)
            for _ in 0..<paramCount {
                // label_len(2) + label + doc_len(2) + doc
                guard data.count >= shPos + 2 else { break }
                let pLabelLen = Int(try readU16(data, shPos)); shPos += 2
                guard data.count >= shPos + pLabelLen else { break }
                let pLabel = try decodeUTF8(data[shPos..<(shPos + pLabelLen)]) ?? ""
                shPos += pLabelLen
                guard data.count >= shPos + 2 else { break }
                let pDocLen = Int(try readU16(data, shPos)); shPos += 2
                guard data.count >= shPos + pDocLen else { break }
                let pDoc = try decodeUTF8(data[shPos..<(shPos + pDocLen)]) ?? ""
                shPos += pDocLen
                try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                params.append(Wire.SignatureParameter(label: pLabel, documentation: pDoc))
            }
            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            signatures.append(Wire.Signature(label: label, documentation: doc, parameters: params))
        }
        return (.guiSignatureHelp(visible: true, anchorRow: shAnchorRow, anchorCol: shAnchorCol,
                                   activeSignature: shActiveSig, activeParameter: shActiveParam,
                                   signatures: signatures), shPos - offset)

    case OP_GUI_FLOAT_POPUP:
        // visible(1)
        guard data.count >= rest + 1 else { throw ProtocolDecodeError.malformed }
        let fpVisible = data[rest] != 0
        guard fpVisible else {
            return (.guiFloatPopup(visible: false, width: 0, height: 0, title: "", lines: []), 2)
        }
        // width(2) + height(2) + title_len(2)
        guard data.count >= rest + 7 else { throw ProtocolDecodeError.malformed }
        let fpWidth = try readU16(data, rest + 1)
        let fpHeight = try readU16(data, rest + 3)
        let fpTitleLen = Int(try readU16(data, rest + 5))
        var fpPos = rest + 7
        guard data.count >= fpPos + fpTitleLen else { throw ProtocolDecodeError.malformed }
        let fpTitle = try decodeUTF8(data[fpPos..<(fpPos + fpTitleLen)]) ?? ""
        fpPos += fpTitleLen
        // line_count(2)
        guard data.count >= fpPos + 2 else { throw ProtocolDecodeError.malformed }
        let fpLineCount = Int(try readU16(data, fpPos)); fpPos += 2
        var fpLines: [String] = []
        try FrameDecodeAccounting.reserve(.arrayEntries, fpLineCount)
        fpLines.reserveCapacity(fpLineCount)
        for _ in 0..<fpLineCount {
            guard data.count >= fpPos + 2 else { throw ProtocolDecodeError.malformed }
            let lineLen = Int(try readU16(data, fpPos)); fpPos += 2
            guard data.count >= fpPos + lineLen else { throw ProtocolDecodeError.malformed }
            let line = try decodeUTF8(data[fpPos..<(fpPos + lineLen)]) ?? ""
            fpPos += lineLen
            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            fpLines.append(line)
        }
        return (.guiFloatPopup(visible: true, width: fpWidth, height: fpHeight,
                                title: fpTitle, lines: fpLines), fpPos - offset)

    case OP_GUI_SPLIT_SEPARATORS:
        // border_color_rgb(3) + vertical_count(1)
        guard data.count >= rest + 4 else { throw ProtocolDecodeError.malformed }
        let sepR = data[rest]
        let sepG = data[rest + 1]
        let sepB = data[rest + 2]
        let sepColor: UInt32 = (UInt32(sepR) << 16) | (UInt32(sepG) << 8) | UInt32(sepB)
        let vertCount = Int(data[rest + 3])
        var sepPos = rest + 4
        var verts: [Wire.VerticalSeparator] = []
        try FrameDecodeAccounting.reserve(.arrayEntries, vertCount)
        verts.reserveCapacity(vertCount)
        for _ in 0..<vertCount {
            // col(2) + start_row(2) + end_row(2)
            guard data.count >= sepPos + 6 else { throw ProtocolDecodeError.malformed }
            let col = try readU16(data, sepPos)
            let startRow = try readU16(data, sepPos + 2)
            let endRow = try readU16(data, sepPos + 4)
            sepPos += 6
            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            verts.append(Wire.VerticalSeparator(col: col, startRow: startRow, endRow: endRow))
        }
        // horizontal_count(1)
        guard data.count >= sepPos + 1 else { throw ProtocolDecodeError.malformed }
        let horizCount = Int(data[sepPos]); sepPos += 1
        var horizs: [Wire.HorizontalSeparator] = []
        try FrameDecodeAccounting.reserve(.arrayEntries, horizCount)
        horizs.reserveCapacity(horizCount)
        for _ in 0..<horizCount {
            // row(2) + col(2) + width(2) + filename_len(2)
            guard data.count >= sepPos + 8 else { throw ProtocolDecodeError.malformed }
            let hRow = try readU16(data, sepPos)
            let hCol = try readU16(data, sepPos + 2)
            let hWidth = try readU16(data, sepPos + 4)
            let fnLen = Int(try readU16(data, sepPos + 6))
            sepPos += 8
            guard data.count >= sepPos + fnLen else { throw ProtocolDecodeError.malformed }
            let fn = try decodeUTF8(data[sepPos..<(sepPos + fnLen)]) ?? ""
            sepPos += fnLen
            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            horizs.append(Wire.HorizontalSeparator(row: hRow, col: hCol, width: hWidth, filename: fn))
        }
        return (.guiSplitSeparators(borderColor: sepColor, verticals: verts, horizontals: horizs),
                sepPos - offset)

    case OP_GUI_GIT_STATUS:
        // Header: repo_state:1, syncing:1, ahead:2, behind:2, branch_len:2, branch, entry_count:2
        //
        // gui_git_status stays hand-written (ticket #2225 ruling): this decoder is
        // strict where the generated one is lenient. It range-validates repo_state
        // (<= 2), syncing (0/1), entry section (<= 3) and status (<= 7) and rejects
        // invalid UTF-8 via readRequiredUTF8, throwing .malformed. The generated
        // GuiGitStatusFields decoder maps unknown enum bytes to a default and
        // coalesces invalid UTF-8 to "", so swapping it would silently accept
        // payloads this path rejects. Strict IS the byte-neutral outcome here, so
        // it is intentionally not migrated.
        guard data.count >= rest + 10 else { throw ProtocolDecodeError.malformed }
        let gsRepoState = data[rest]
        guard gsRepoState <= 2 else { throw ProtocolDecodeError.malformed }
        let gsSyncingByte = data[rest + 1]
        guard gsSyncingByte == 0 || gsSyncingByte == 1 else { throw ProtocolDecodeError.malformed }
        let gsSyncing = gsSyncingByte == 1
        let gsAhead = try readU16(data, rest + 2)
        let gsBehind = try readU16(data, rest + 4)
        let gsBranchLen = Int(try readU16(data, rest + 6))
        guard data.count >= rest + 8 + gsBranchLen + 2 else { throw ProtocolDecodeError.malformed }
        let gsBranchData = data[(rest + 8)..<(rest + 8 + gsBranchLen)]
        let gsBranchName = try readRequiredUTF8(gsBranchData)
        let gsEntryCount = Int(try readU16(data, rest + 8 + gsBranchLen))
        var gsEntries: [Wire.GitStatusEntry] = []
        try FrameDecodeAccounting.reserve(.arrayEntries, gsEntryCount)
        gsEntries.reserveCapacity(gsEntryCount)
        var gsPos = rest + 10 + gsBranchLen
        for _ in 0..<gsEntryCount {
            // path_hash:4, section:1, status:1, path_len:2, path
            guard data.count >= gsPos + 8 else { throw ProtocolDecodeError.malformed }
            let gsPathHash = try readU32(data, gsPos)
            let gsSection = data[gsPos + 4]
            guard gsSection <= 3 else { throw ProtocolDecodeError.malformed }
            let gsStatus = data[gsPos + 5]
            guard gsStatus <= 7 else { throw ProtocolDecodeError.malformed }
            let gsPathLen = Int(try readU16(data, gsPos + 6))
            guard data.count >= gsPos + 8 + gsPathLen else { throw ProtocolDecodeError.malformed }
            let gsPathData = data[(gsPos + 8)..<(gsPos + 8 + gsPathLen)]
            let gsPath = try readRequiredUTF8(gsPathData)
            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            gsEntries.append(Wire.GitStatusEntry(pathHash: gsPathHash, section: gsSection, status: gsStatus, path: gsPath))
            gsPos += 8 + gsPathLen
        }
        // Toast section: toast_present:1, [toast_level:1, action:1, msg_len:2, msg]
        var gsToast: (message: String, level: UInt8, action: UInt8)? = nil
        guard data.count >= gsPos + 1 else { throw ProtocolDecodeError.malformed }
        let gsToastPresent = data[gsPos]
        gsPos += 1
        guard gsToastPresent == 0 || gsToastPresent == 1 else { throw ProtocolDecodeError.malformed }
        if gsToastPresent == 1 {
            guard data.count >= gsPos + 4 else { throw ProtocolDecodeError.malformed }
            let gsToastLevel = data[gsPos]
            let gsToastAction = data[gsPos + 1]
            let gsToastMsgLen = Int(try readU16(data, gsPos + 2))
            gsPos += 4
            guard data.count >= gsPos + gsToastMsgLen else { throw ProtocolDecodeError.malformed }
            let gsToastMsgData = data[gsPos..<(gsPos + gsToastMsgLen)]
            let gsToastMsg = try readRequiredUTF8(gsToastMsgData)
            gsPos += gsToastMsgLen
            gsToast = (message: gsToastMsg, level: gsToastLevel, action: gsToastAction)
        }

        guard data.count >= gsPos + 2 else { throw ProtocolDecodeError.malformed }
        let gsEntryBasePathLen = Int(try readU16(data, gsPos))
        gsPos += 2
        guard data.count >= gsPos + gsEntryBasePathLen + 2 else { throw ProtocolDecodeError.malformed }
        let gsEntryBasePathData = data[gsPos..<(gsPos + gsEntryBasePathLen)]
        let gsEntryBasePath = try readRequiredUTF8(gsEntryBasePathData)
        gsPos += gsEntryBasePathLen

        let gsLastCommitMessageLen = Int(try readU16(data, gsPos))
        gsPos += 2
        guard data.count >= gsPos + gsLastCommitMessageLen else { throw ProtocolDecodeError.malformed }
        let gsLastCommitMessageData = data[gsPos..<(gsPos + gsLastCommitMessageLen)]
        let gsLastCommitMessage = try readRequiredUTF8(gsLastCommitMessageData)
        gsPos += gsLastCommitMessageLen
        guard data.count >= gsPos + 2 else { throw ProtocolDecodeError.malformed }
        let gsStashCount = try readU16(data, gsPos)
        gsPos += 2
        return (.guiGitStatus(repoState: gsRepoState, syncing: gsSyncing, ahead: gsAhead, behind: gsBehind, branchName: gsBranchName, entries: gsEntries, toast: gsToast, entryBasePath: gsEntryBasePath, lastCommitMessage: gsLastCommitMessage, stashCount: gsStashCount),
                gsPos - offset)

    case OP_GUI_WORKSPACES:
        // Canonical length-prefixed workspace payload.
        // opcode(1) + payload_len(2) + version(1) + active_workspace_id(2) + mode(1) + flags(1)
        // + workspace_count(1) + workspaces... + visible_tab_count(2) + visible_tabs...
        guard data.count >= rest + 2 else { throw ProtocolDecodeError.malformed }
        let payloadLen = Int(try readU16(data, rest))
        let payloadStart = rest + 2
        let payloadEnd = payloadStart + payloadLen
        guard data.count >= payloadEnd else { throw ProtocolDecodeError.malformed }
        guard payloadLen >= 6 else { throw ProtocolDecodeError.malformed }

        let version = data[payloadStart]
        let activeGId = try readU16(data, payloadStart + 1)
        let mode = data[payloadStart + 3]
        let workspaceFlags = data[payloadStart + 4]
        let workspaceCount = Int(data[payloadStart + 5])
        var workspaces: [Wire.WorkspaceEntry] = []
        try FrameDecodeAccounting.reserve(.arrayEntries, workspaceCount)
        workspaces.reserveCapacity(workspaceCount)
        var pos = payloadStart + 6

        for _ in 0..<workspaceCount {
            guard pos + 18 <= payloadEnd else { throw ProtocolDecodeError.malformed }
            let id = try readU16(data, pos)
            let kind = data[pos + 2]
            let status = data[pos + 3]
            let flags = try readU16(data, pos + 4)
            let colorR = data[pos + 6]
            let colorG = data[pos + 7]
            let colorB = data[pos + 8]
            let tabCount = try readU16(data, pos + 9)
            let draftCount = try readU16(data, pos + 11)
            let conflictCount = try readU16(data, pos + 13)
            let runningBackgroundCount = try readU16(data, pos + 15)
            let labelLen = Int(data[pos + 17])
            guard pos + 18 + labelLen + 1 <= payloadEnd else { throw ProtocolDecodeError.malformed }
            let label = try readRequiredUTF8(data[(pos + 18)..<(pos + 18 + labelLen)])
            let iconLenPos = pos + 18 + labelLen
            let iconLen = Int(data[iconLenPos])
            guard iconLenPos + 1 + iconLen <= payloadEnd else { throw ProtocolDecodeError.malformed }
            let icon = try readRequiredUTF8(data[(iconLenPos + 1)..<(iconLenPos + 1 + iconLen)])

            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            workspaces.append(Wire.WorkspaceEntry(
                id: id,
                kind: kind,
                status: status,
                flags: flags,
                colorR: colorR,
                colorG: colorG,
                colorB: colorB,
                tabCount: tabCount,
                draftCount: draftCount,
                conflictCount: conflictCount,
                runningBackgroundCount: runningBackgroundCount,
                label: label,
                icon: icon
            ))
            pos = iconLenPos + 1 + iconLen
        }

        guard pos + 2 <= payloadEnd else { throw ProtocolDecodeError.malformed }
        let visibleTabCount = Int(try readU16(data, pos))
        pos += 2
        var visibleTabs: [Wire.WorkspaceTabEntry] = []
        try FrameDecodeAccounting.reserve(.arrayEntries, visibleTabCount)
        visibleTabs.reserveCapacity(visibleTabCount)

        for _ in 0..<visibleTabCount {
            guard pos + 14 <= payloadEnd else { throw ProtocolDecodeError.malformed }
            let id = try readU32(data, pos)
            let workspaceId = try readU16(data, pos + 4)
            let kind = data[pos + 6]
            let flags = try readU16(data, pos + 7)
            let pathHash = try readU32(data, pos + 9)
            let iconLen = Int(data[pos + 13])
            guard pos + 14 + iconLen + 2 <= payloadEnd else { throw ProtocolDecodeError.malformed }
            let icon = try readRequiredUTF8(data[(pos + 14)..<(pos + 14 + iconLen)])
            let labelLenPos = pos + 14 + iconLen
            let labelLen = Int(try readU16(data, labelLenPos))
            guard labelLenPos + 2 + labelLen + 2 <= payloadEnd else { throw ProtocolDecodeError.malformed }
            let label = try readRequiredUTF8(data[(labelLenPos + 2)..<(labelLenPos + 2 + labelLen)])
            let pathLenPos = labelLenPos + 2 + labelLen
            let pathLen = Int(try readU16(data, pathLenPos))
            let tintBytes = version >= 2 ? 4 : 0
            guard pathLenPos + 2 + pathLen + tintBytes <= payloadEnd else { throw ProtocolDecodeError.malformed }
            let path = try readRequiredUTF8(data[(pathLenPos + 2)..<(pathLenPos + 2 + pathLen)])
            let tintColorRGB = version >= 2 ? try readU32(data, pathLenPos + 2 + pathLen) : 0

            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            visibleTabs.append(Wire.WorkspaceTabEntry(
                id: id,
                workspaceId: workspaceId,
                kind: kind,
                flags: flags,
                pathHash: pathHash,
                tintColorRGB: tintColorRGB,
                icon: icon,
                label: label,
                path: path
            ))
            pos = pathLenPos + 2 + pathLen + tintBytes
        }

        guard pos == payloadEnd else { throw ProtocolDecodeError.malformed }
        return (.guiWorkspaces(version: version, activeWorkspaceId: activeGId, mode: mode, flags: workspaceFlags, workspaces: workspaces, visibleTabs: visibleTabs),
                payloadEnd - offset)

    case OP_GUI_AGENT_CONTEXT:
        var payloadStart = rest
        var payloadEnd: Int? = nil
        var framedSize: Int? = nil

        if data.count >= rest + 2 {
            let payloadLen = Int(try readU16(data, rest))
            let end = rest + 2 + payloadLen
            if payloadLen >= 12 && data.count >= end {
                payloadStart = rest + 2
                payloadEnd = end
                framedSize = 1 + 2 + payloadLen
            }
        }

        // Payload: visible(1) + task_len(2) + task + dispatch_timestamp(8) + status(1) + can_approve(1)
        guard data.count >= payloadStart + 3 else { throw ProtocolDecodeError.malformed }
        let contextVisible = data[payloadStart] != 0
        let taskLen = Int(try readU16(data, payloadStart + 1))
        guard data.count >= payloadStart + 3 + taskLen + 10 else { throw ProtocolDecodeError.malformed }
        let taskData = data[(payloadStart + 3)..<(payloadStart + 3 + taskLen)]
        let task = try decodeUTF8(taskData) ?? ""
        let timestampPos = payloadStart + 3 + taskLen
        let timestampSeconds = try readU64(data, timestampPos)
        let dispatchTimestamp = Date(timeIntervalSince1970: TimeInterval(timestampSeconds))
        let statusRaw = data[timestampPos + 8]
        let canApprove = data[timestampPos + 9] != 0
        var progress = Wire.AgentProgress(activeAction: "", toolCount: 0, fileCount: 0, reviewHint: "")
        var todos: [Wire.AgentTodo] = []
        var contextPos = timestampPos + 10

        if let payloadEnd {
            if contextPos + 2 <= payloadEnd {
                let actionLen = Int(try readU16(data, contextPos))
                if contextPos + 2 + actionLen + 4 <= payloadEnd {
                    let actionStart = contextPos + 2
                    let activeAction = try decodeUTF8(data[actionStart..<(actionStart + actionLen)]) ?? ""
                    contextPos = actionStart + actionLen
                    let toolCount = try readU16(data, contextPos)
                    let fileCount = try readU16(data, contextPos + 2)
                    contextPos += 4

                    if contextPos + 2 <= payloadEnd {
                        let hintLen = Int(try readU16(data, contextPos))
                        if contextPos + 2 + hintLen <= payloadEnd {
                            let hintStart = contextPos + 2
                            let reviewHint = try decodeUTF8(data[hintStart..<(hintStart + hintLen)]) ?? ""
                            contextPos = hintStart + hintLen
                            progress = Wire.AgentProgress(activeAction: activeAction, toolCount: toolCount, fileCount: fileCount, reviewHint: reviewHint)
                        }
                    }
                }
            }

            if contextPos < payloadEnd {
                let todoCount = Int(data[contextPos])
                contextPos += 1
                try FrameDecodeAccounting.reserve(.arrayEntries, todoCount)
                todos.reserveCapacity(todoCount)

                for _ in 0..<todoCount {
                    guard contextPos + 3 <= payloadEnd else { break }
                    let status = data[contextPos]
                    let descriptionLen = Int(try readU16(data, contextPos + 1))
                    guard contextPos + 3 + descriptionLen <= payloadEnd else { break }
                    let descriptionStart = contextPos + 3
                    let description = try decodeUTF8(data[descriptionStart..<(descriptionStart + descriptionLen)]) ?? ""
                    try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                    todos.append(Wire.AgentTodo(status: status, description: description))
                    contextPos = descriptionStart + descriptionLen
                }
            }
        }

        let consumed = framedSize ?? (timestampPos + 10 - offset)
        return (.guiAgentContext(visible: contextVisible, task: task, dispatchTimestamp: dispatchTimestamp,
                                 status: CardStatus(rawValue: statusRaw) ?? .idle, canApprove: canApprove,
                                 progress: progress, todos: todos),
                consumed)
    case OP_GUI_CHANGE_SUMMARY:
        // visible(1) + selected_index(2) + entry_count(2)
        guard data.count >= rest + 5 else { throw ProtocolDecodeError.malformed }
        let csVisible = data[rest] != 0
        let csSelectedIndex = Int(try readU16(data, rest + 1))
        let entryCount = Int(try readU16(data, rest + 3))
        var csEntries: [ChangeSummaryEntry] = []
        try FrameDecodeAccounting.reserve(.arrayEntries, entryCount)
        csEntries.reserveCapacity(entryCount)
        var csPos = rest + 5
        for idx in 0..<entryCount {
            // path_len(2) + path + action(1) + lines_added(4) + lines_removed(4)
            guard data.count >= csPos + 2 else { throw ProtocolDecodeError.malformed }
            let pathLen = Int(try readU16(data, csPos))
            guard data.count >= csPos + 2 + pathLen + 1 + 4 + 4 else { throw ProtocolDecodeError.malformed }
            let pathData = data[(csPos + 2)..<(csPos + 2 + pathLen)]
            let path = try decodeUTF8(pathData) ?? ""
            let actionByte = data[csPos + 2 + pathLen]
            let linesAdded = try readU32(data, csPos + 2 + pathLen + 1)
            let linesRemoved = try readU32(data, csPos + 2 + pathLen + 5)
            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            csEntries.append(ChangeSummaryEntry(
                id: idx,
                path: path,
                action: ChangeSummaryEntry.FileAction(rawValue: actionByte) ?? .modified,
                linesAdded: linesAdded,
                linesRemoved: linesRemoved
            ))
            csPos += 2 + pathLen + 1 + 4 + 4
        }
        return (.guiChangeSummary(visible: csVisible, entries: csEntries, selectedIndex: csSelectedIndex),
                csPos - offset)

    case OP_GUI_INDENT_GUIDES:
        // Forward-compatible format: opcode(1) + payload_length(2) + payload
        // Payload: window_id(2) + tab_width(1) + active_guide_col(2) + guide_count(1) + guide_cols(2 each)
        guard data.count >= rest + 2 else { throw ProtocolDecodeError.malformed }
        let igPayloadLen = Int(try readU16(data, rest))
        guard data.count >= rest + 2 + igPayloadLen, igPayloadLen >= 6 else {
            throw ProtocolDecodeError.malformed
        }
        let igStart = rest + 2
        let igWinId = try readU16(data, igStart)
        let igTabWidth = data[igStart + 2]
        let igActiveCol = try readU16(data, igStart + 3)
        let igGuideCount = Int(data[igStart + 5])
        var igCols: [UInt16] = []
        try FrameDecodeAccounting.reserve(.arrayEntries, igGuideCount)
        igCols.reserveCapacity(igGuideCount)
        var igPos = igStart + 6
        for _ in 0..<igGuideCount {
            guard igPos + 2 <= rest + 2 + igPayloadLen else { break }
            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            igCols.append(try readU16(data, igPos))
            igPos += 2
        }
        var igLineLevels: [UInt8] = []
        let igEnd = rest + 2 + igPayloadLen
        if igPos + 2 <= igEnd {
            let igLineCount = Int(try readU16(data, igPos))
            igPos += 2
            try FrameDecodeAccounting.reserve(.arrayEntries, igLineCount)
            igLineLevels.reserveCapacity(igLineCount)
            for _ in 0..<igLineCount {
                guard igPos < igEnd else { break }
                try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                igLineLevels.append(data[igPos])
                igPos += 1
            }
        }
        let igData = IndentGuideData(windowId: igWinId, tabWidth: igTabWidth,
                                     activeGuideCol: igActiveCol, guideCols: igCols,
                                     lineIndentLevels: igLineLevels)
        return (.guiIndentGuides(data: igData), 1 + 2 + igPayloadLen)

    case OP_GUI_LINE_SPACING:
        // Forward-compatible format: opcode(1) + payload_length(2) + spacing_x100(2)
        guard data.count >= rest + 2 else { throw ProtocolDecodeError.malformed }
        let lsPayloadLen = Int(try readU16(data, rest))
        guard data.count >= rest + 2 + lsPayloadLen, lsPayloadLen >= 2 else {
            throw ProtocolDecodeError.malformed
        }
        let spacingX100 = try readU16(data, rest + 2)
        let spacing = Float(spacingX100) / 100.0
        return (.guiLineSpacing(spacing: spacing), 1 + 2 + lsPayloadLen)

    case OP_GUI_CURSOR_ANIMATION:
        // Forward-compatible format: opcode(1) + payload_length(2) + enabled(1)
        guard data.count >= rest + 2 else { throw ProtocolDecodeError.malformed }
        let caPayloadLen = Int(try readU16(data, rest))
        guard data.count >= rest + 2 + caPayloadLen, caPayloadLen >= 1 else {
            throw ProtocolDecodeError.malformed
        }
        return (.guiCursorAnimation(enabled: data[rest + 2] != 0), 1 + 2 + caPayloadLen)

    case OP_GUI_EDIT_TIMELINE:
        guard data.count >= rest + 2 else { throw ProtocolDecodeError.malformed }
        let payloadLen = Int(try readU16(data, rest))
        guard data.count >= rest + 2 + payloadLen, payloadLen >= 4 else {
            throw ProtocolDecodeError.malformed
        }
        let pStart = rest + 2
        let visible = data[pStart] != 0
        let viewingIndex = try readU16(data, pStart + 1)
        let entryCount = Int(data[pStart + 3])
        var entries: [Wire.TimelineEntry] = []
        var ePos = pStart + 4
        for _ in 0..<entryCount {
            guard ePos + 2 <= pStart + payloadLen else { break }
            let idx = data[ePos]
            let nameLen = Int(data[ePos + 1])
            ePos += 2
            guard ePos + nameLen + 4 <= pStart + payloadLen else { break }
            let toolName = try decodeUTF8(data[ePos..<(ePos + nameLen)]) ?? ""
            ePos += nameLen
            let tsDelta = try readU32(data, ePos)
            ePos += 4
            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            entries.append(Wire.TimelineEntry(index: idx, toolName: toolName, timestampDelta: tsDelta))
        }
        var files: [Wire.TimelineFile] = []
        if ePos < pStart + payloadLen {
            let fileCount = Int(data[ePos])
            ePos += 1
            try FrameDecodeAccounting.reserve(.arrayEntries, fileCount)
            files.reserveCapacity(fileCount)

            for _ in 0..<fileCount {
                guard ePos + 2 <= pStart + payloadLen else { break }
                let pathLen = Int(try readU16(data, ePos))
                guard ePos + 2 + pathLen + 10 <= pStart + payloadLen else { break }
                let pathStart = ePos + 2
                let path = try decodeUTF8(data[pathStart..<(pathStart + pathLen)]) ?? ""
                ePos = pathStart + pathLen
                let entryCount = data[ePos]
                let linesAdded = try readU32(data, ePos + 1)
                let linesRemoved = try readU32(data, ePos + 5)
                let reviewStatus = data[ePos + 9]
                ePos += 10
                try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                files.append(Wire.TimelineFile(path: path, entryCount: entryCount, linesAdded: linesAdded, linesRemoved: linesRemoved, reviewStatus: reviewStatus))
            }
        }
        return (.guiEditTimeline(visible: visible, viewingIndex: viewingIndex, entries: entries, files: files), 1 + 2 + payloadLen)

    case OP_GUI_EXTENSION_OVERLAY:
        guard data.count >= rest + 2 else { throw ProtocolDecodeError.malformed }
        let eoPayloadLen = Int(try readU16(data, rest))
        guard data.count >= rest + 2 + eoPayloadLen, eoPayloadLen >= 1 else {
            throw ProtocolDecodeError.malformed
        }
        let eoStart = rest + 2
        let eoCount = Int(data[eoStart])
        var eoEntries: [Wire.ExtensionOverlayEntry] = []
        var eoPos = eoStart + 1
        let eoEnd = eoStart + eoPayloadLen
        for _ in 0..<eoCount {
            guard eoPos + 1 <= eoEnd else { break }
            let extNameLen = Int(data[eoPos]); eoPos += 1
            guard eoPos + extNameLen + 1 <= eoEnd else { break }
            let extName = try decodeUTF8(data[eoPos..<(eoPos + extNameLen)]) ?? ""
            eoPos += extNameLen
            let oidLen = Int(data[eoPos]); eoPos += 1
            guard eoPos + oidLen + 11 <= eoEnd else { break }
            let oid = try decodeUTF8(data[eoPos..<(eoPos + oidLen)]) ?? ""
            eoPos += oidLen
            let winId = try readU16(data, eoPos)
            let row = try readU16(data, eoPos + 2)
            let col = try readU16(data, eoPos + 4)
            let shape = data[eoPos + 6]
            let cr = data[eoPos + 7]
            let cg = data[eoPos + 8]
            let cb = data[eoPos + 9]
            let opacity = data[eoPos + 10]
            eoPos += 11
            guard eoPos + 2 <= eoEnd else { break }
            let contentLen = Int(try readU16(data, eoPos)); eoPos += 2
            guard eoPos + contentLen <= eoEnd else { break }
            let content = try decodeUTF8(data[eoPos..<(eoPos + contentLen)]) ?? ""
            eoPos += contentLen
            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            eoEntries.append(Wire.ExtensionOverlayEntry(
                extensionName: extName, overlayID: oid, windowID: winId,
                row: row, col: col, shape: shape,
                colorR: cr, colorG: cg, colorB: cb, opacity: opacity,
                content: content
            ))
        }
        return (.guiExtensionOverlay(eoEntries), 1 + 2 + eoPayloadLen)

    case OP_GUI_EXTENSION_PANEL:
        guard data.count >= rest + 2 else { throw ProtocolDecodeError.malformed }
        let epPayloadLen = Int(try readU16(data, rest))
        guard data.count >= rest + 2 + epPayloadLen, epPayloadLen >= 1 else {
            throw ProtocolDecodeError.malformed
        }
        let epStart = rest + 2
        let epEnd = epStart + epPayloadLen
        let panelCount = Int(data[epStart])
        var epPanels: [Wire.ExtensionPanelEntry] = []
        var epPos = epStart + 1
        for _ in 0..<panelCount {
            guard epPos + 1 <= epEnd else { break }
            let extLen = Int(data[epPos]); epPos += 1
            guard epPos + extLen <= epEnd else { break }
            let extName = try decodeUTF8(data[epPos..<(epPos + extLen)]) ?? ""
            epPos += extLen
            guard epPos + 1 <= epEnd else { break }
            let pidLen = Int(data[epPos]); epPos += 1
            guard epPos + pidLen <= epEnd else { break }
            let panelId = try decodeUTF8(data[epPos..<(epPos + pidLen)]) ?? ""
            epPos += pidLen
            guard epPos + 1 <= epEnd else { break }
            let titleLen = Int(data[epPos]); epPos += 1
            guard epPos + titleLen + 4 <= epEnd else { break }
            let title = try decodeUTF8(data[epPos..<(epPos + titleLen)]) ?? ""
            epPos += titleLen
            let pos = data[epPos]
            let sizeType = data[epPos + 1]
            let sizeVal = data[epPos + 2]
            let vis = data[epPos + 3] != 0
            epPos += 4
            guard epPos + 1 <= epEnd else { break }
            let blockCount = Int(data[epPos]); epPos += 1
            var blocks: [Wire.PanelContentBlock] = []
            for _ in 0..<blockCount {
                guard epPos + 1 <= epEnd else { break }
                let blockType = data[epPos]; epPos += 1
                switch blockType {
                case 0: // text
                    guard epPos + 2 <= epEnd else { break }
                    let tLen = Int(try readU16(data, epPos)); epPos += 2
                    guard epPos + tLen <= epEnd else { break }
                    let t = try decodeUTF8(data[epPos..<(epPos + tLen)]) ?? ""
                    epPos += tLen
                    try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                    blocks.append(.text(t))
                case 1: // styled_text
                    guard epPos + 1 <= epEnd else { break }
                    let runCount = Int(data[epPos]); epPos += 1
                    var runs: [(text: String, r: UInt8, g: UInt8, b: UInt8, bold: Bool, italic: Bool)] = []
                    for _ in 0..<runCount {
                        guard epPos + 2 <= epEnd else { break }
                        let stLen = Int(try readU16(data, epPos)); epPos += 2
                        guard epPos + stLen + 5 <= epEnd else { break }
                        let stText = try decodeUTF8(data[epPos..<(epPos + stLen)]) ?? ""
                        epPos += stLen
                        let stR = data[epPos]; let stG = data[epPos + 1]; let stB = data[epPos + 2]
                        let stBold = data[epPos + 3] != 0; let stItalic = data[epPos + 4] != 0
                        epPos += 5
                        try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                        runs.append((text: stText, r: stR, g: stG, b: stB, bold: stBold, italic: stItalic))
                    }
                    try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                    blocks.append(.styledText(runs: runs))
                case 2: // table
                    guard epPos + 5 <= epEnd else { break }
                    let colCount = Int(data[epPos])
                    let rowCount = Int(try readU16(data, epPos + 1))
                    let selected = try readU16(data, epPos + 3)
                    epPos += 5
                    var columns: [String] = []
                    for _ in 0..<colCount {
                        guard epPos + 2 <= epEnd else { break }
                        let cLen = Int(try readU16(data, epPos)); epPos += 2
                        guard epPos + cLen <= epEnd else { break }
                        try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                        columns.append(try decodeUTF8(data[epPos..<(epPos + cLen)]) ?? "")
                        epPos += cLen
                    }
                    var rows: [[String]] = []
                    for _ in 0..<rowCount {
                        var row: [String] = []
                        for _ in 0..<colCount {
                            guard epPos + 2 <= epEnd else { break }
                            let cellLen = Int(try readU16(data, epPos)); epPos += 2
                            guard epPos + cellLen <= epEnd else { break }
                            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                            row.append(try decodeUTF8(data[epPos..<(epPos + cellLen)]) ?? "")
                            epPos += cellLen
                        }
                        try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                        rows.append(row)
                    }
                    try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                    blocks.append(.table(columns: columns, rows: rows, selected: selected))
                case 3: // key_value
                    guard epPos + 1 <= epEnd else { break }
                    let pairCount = Int(data[epPos]); epPos += 1
                    var pairs: [(key: String, value: String)] = []
                    for _ in 0..<pairCount {
                        guard epPos + 2 <= epEnd else { break }
                        let kLen = Int(try readU16(data, epPos)); epPos += 2
                        guard epPos + kLen + 2 <= epEnd else { break }
                        let k = try decodeUTF8(data[epPos..<(epPos + kLen)]) ?? ""
                        epPos += kLen
                        let vLen = Int(try readU16(data, epPos)); epPos += 2
                        guard epPos + vLen <= epEnd else { break }
                        let v = try decodeUTF8(data[epPos..<(epPos + vLen)]) ?? ""
                        epPos += vLen
                        try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                        pairs.append((key: k, value: v))
                    }
                    try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                    blocks.append(.keyValue(pairs: pairs))
                case 4: // separator
                    try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                    blocks.append(.separator)
                case 5: // progress
                    guard epPos + 4 <= epEnd else { break }
                    let labelLen = Int(try readU16(data, epPos)); epPos += 2
                    guard epPos + labelLen + 2 <= epEnd else { break }
                    let label = try decodeUTF8(data[epPos..<(epPos + labelLen)]) ?? ""
                    epPos += labelLen
                    let pctInt = try readU16(data, epPos); epPos += 2
                    try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                    blocks.append(.progress(label: label, percent: Float(pctInt) / 100.0))
                case 6: // tree (length-prefixed, skip payload)
                    guard epPos + 2 <= epEnd else { break }
                    let treeLen = Int(try readU16(data, epPos)); epPos += 2
                    guard epPos + treeLen <= epEnd else { break }
                    epPos += treeLen
                    try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                    blocks.append(.unknown)
                default:
                    try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                    blocks.append(.unknown)
                    break
                }
            }
            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            epPanels.append(Wire.ExtensionPanelEntry(
                extensionName: extName, panelID: panelId, title: title,
                position: pos, sizeType: sizeType, sizeValue: sizeVal,
                visible: vis, blocks: blocks
            ))
        }
        return (.guiExtensionPanel(epPanels), 1 + 2 + epPayloadLen)

    case OP_GUI_EXTENSION_RUNTIME:
        guard data.count >= rest + 4 else { throw ProtocolDecodeError.malformed }
        let payloadLen = Int(try readU32(data, rest))
        let payloadStart = rest + 4
        let payloadEnd = payloadStart + payloadLen
        guard data.count >= payloadEnd else { throw ProtocolDecodeError.malformed }
        var pos = payloadStart
        let extensionID = try readString16(data: data, pos: &pos, end: payloadEnd)
        let channel = try readString16(data: data, pos: &pos, end: payloadEnd)
        let payload = data[pos..<payloadEnd]
        return (.guiExtensionRuntime(FrontendExtensionRuntimeMessage(extensionID: extensionID, channel: channel, payload: Data(payload))), 1 + 4 + payloadLen)

    case OP_GUI_SEARCH_STATE:
        // Forward-compatible format: opcode(1) + payload_len(2) + active(1) + match_count(2) + current_index(2) + flags(1)
        guard data.count >= rest + 2 else { throw ProtocolDecodeError.malformed }
        let ssPayloadLen = Int(try readU16(data, rest))
        guard data.count >= rest + 2 + ssPayloadLen, ssPayloadLen >= 6 else {
            throw ProtocolDecodeError.malformed
        }
        let ssStart = rest + 2
        let ssActive = data[ssStart] != 0
        let ssMatchCount = try readU16(data, ssStart + 1)
        let ssCurrentIndex = try readU16(data, ssStart + 3)
        let ssFlags = data[ssStart + 5]
        return (.guiSearchState(active: ssActive, matchCount: ssMatchCount, currentIndex: ssCurrentIndex, flags: ssFlags), 1 + 2 + ssPayloadLen)

    case OP_GUI_SIDEBARS:
        guard data.count >= rest + 4 else { throw ProtocolDecodeError.malformed }
        let payloadLen = Int(try readU32(data, rest))
        let payloadStart = rest + 4
        let payloadEnd = payloadStart + payloadLen
        guard data.count >= payloadEnd, payloadLen >= 5 else { throw ProtocolDecodeError.malformed }

        var pos = payloadStart
        let version = data[pos]; pos += 1
        let count = Int(try readU16(data, pos)); pos += 2
        let activeId = try readString16(data: data, pos: &pos, end: payloadEnd)
        var sidebars: [Wire.SidebarMetadata] = []
        try FrameDecodeAccounting.reserve(.arrayEntries, count)
        sidebars.reserveCapacity(count)

        for _ in 0..<count {
            let id = try readString16(data: data, pos: &pos, end: payloadEnd)
            let displayName = try readString16(data: data, pos: &pos, end: payloadEnd)
            let semanticKind = try readString16(data: data, pos: &pos, end: payloadEnd)
            let icon = try readString16(data: data, pos: &pos, end: payloadEnd)
            guard pos + 7 <= payloadEnd else { throw ProtocolDecodeError.malformed }
            let order = try readU16(data, pos); pos += 2
            let flags = data[pos]; pos += 1
            let preferredWidth = try readU16(data, pos); pos += 2
            let rawBadgeCount = try readU16(data, pos); pos += 2
            let badgeCount: UInt16? = rawBadgeCount == UInt16.max ? nil : rawBadgeCount

            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            sidebars.append(Wire.SidebarMetadata(
                id: id,
                displayName: displayName,
                semanticKind: semanticKind,
                icon: icon,
                order: order,
                visible: flags & 0x01 != 0,
                focused: flags & 0x02 != 0,
                preferredWidth: preferredWidth,
                badgeCount: badgeCount
            ))
        }

        guard pos == payloadEnd else { throw ProtocolDecodeError.malformed }
        return (.guiSidebars(version: version, activeId: activeId, sidebars: sidebars), 5 + payloadLen)

    case OP_CLIPBOARD_WRITE:
        // Forward-compatible format: opcode(1) + payload_length(4) + target(1) + text_len(4) + text
        guard data.count >= rest + 4 else { throw ProtocolDecodeError.malformed }
        let payloadLen = Int(try readU32(data, rest))
        guard payloadLen >= 5, data.count >= rest + 4 + payloadLen else { throw ProtocolDecodeError.malformed }
        let payloadStart = rest + 4
        let target = data[payloadStart]
        let textLen = Int(try readU32(data, payloadStart + 1))
        guard payloadLen == 5 + textLen else { throw ProtocolDecodeError.malformed }
        let textData = data[(payloadStart + 5)..<(payloadStart + 5 + textLen)]
        let text = try decodeUTF8(textData) ?? ""
        return (.clipboardWrite(target: target, text: text), 1 + 4 + payloadLen)

    case OP_PROTOCOL_ERROR:
        // protocol_error: opcode(1) + message_len(2) + UTF-8 message. The BEAM
        // emits it when this frontend's handshake protocol_version does not match
        // the BEAM's, so the frontend shows a blocking error instead of decoding
        // a stream it cannot parse (ticket #2237).
        guard data.count >= rest + 2 else { throw ProtocolDecodeError.malformed }
        let messageLen = Int(try readU16(data, rest))
        guard data.count >= rest + 2 + messageLen else { throw ProtocolDecodeError.malformed }
        let messageData = data[(rest + 2)..<(rest + 2 + messageLen)]
        let message = try decodeUTF8(messageData) ?? ""
        return (.protocolError(message: message), 1 + 2 + messageLen)

    default:
        throw ProtocolDecodeError.unknownOpcode(opcode)
    }
}

// MARK: - Notification decoder

private func decodeNotifications(data: Data, start: Int, end: Int) throws -> [Wire.EditorNotification] {
    var pos = start
    guard pos + 3 <= end else { throw ProtocolDecodeError.malformed }
    let version = data[pos]
    pos += 1
    guard version == 1 else { throw ProtocolDecodeError.malformed }

    let count = Int(try readU16(data, pos))
    pos += 2

    var notifications: [Wire.EditorNotification] = []
    try FrameDecodeAccounting.reserve(.arrayEntries, count)
    notifications.reserveCapacity(count)

    for _ in 0..<count {
        let id = try readString16(data: data, pos: &pos, end: end)
        guard pos + 22 <= end else { throw ProtocolDecodeError.malformed }
        let level = data[pos]
        pos += 1
        let flags = data[pos]
        pos += 1
        let createdAt = try readU64(data, pos)
        pos += 8
        let updatedAt = try readU64(data, pos)
        pos += 8
        let rawAutoDismiss = try readU32(data, pos)
        pos += 4
        let title = try readString16(data: data, pos: &pos, end: end)
        let body = try readString16(data: data, pos: &pos, end: end)
        let source = try readString16(data: data, pos: &pos, end: end)

        guard pos + 1 <= end else { throw ProtocolDecodeError.malformed }
        let actionCount = Int(data[pos])
        pos += 1

        var actions: [Wire.NotificationAction] = []
        try FrameDecodeAccounting.reserve(.arrayEntries, actionCount)
        actions.reserveCapacity(actionCount)
        for _ in 0..<actionCount {
            let actionId = try readString16(data: data, pos: &pos, end: end)
            let label = try readString16(data: data, pos: &pos, end: end)
            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            actions.append(Wire.NotificationAction(id: actionId, label: label))
        }

        try FrameDecodeAccounting.reserve(.arrayEntries, 1)
        notifications.append(Wire.EditorNotification(
            id: id,
            level: NotificationLevel(rawValue: level),
            flags: flags,
            createdAt: createdAt,
            updatedAt: updatedAt,
            autoDismissMs: rawAutoDismiss == UInt32.max ? nil : rawAutoDismiss,
            title: title,
            body: body,
            source: source,
            actions: actions
        ))
    }

    guard pos == end else { throw ProtocolDecodeError.malformed }
    return notifications
}

// MARK: - Config state decoder

private func decodeConfigState(data: Data, start: Int, end: Int) throws -> Wire.ConfigState {
    var pos = start
    guard pos + 2 <= end else { throw ProtocolDecodeError.malformed }
    let optionCount = Int(try readU16(data, pos))
    pos += 2

    var options: [String: SettingValue] = [:]
    for _ in 0..<optionCount {
        let key = try readString8(data: data, pos: &pos, end: end)
        let value = try readSettingValue(data: data, pos: &pos, end: end)
        options[key] = value
    }

    guard pos + 2 <= end else { throw ProtocolDecodeError.malformed }
    let previewCount = Int(try readU16(data, pos))
    pos += 2

    var previews: [Wire.ThemePreview] = []
    try FrameDecodeAccounting.reserve(.arrayEntries, previewCount)
    previews.reserveCapacity(previewCount)
    for _ in 0..<previewCount {
        let name = try readString8(data: data, pos: &pos, end: end)
        let atom = try readString8(data: data, pos: &pos, end: end)
        guard pos + 9 <= end else { throw ProtocolDecodeError.malformed }
        let editorBg = try readU24(data, pos)
        let editorFg = try readU24(data, pos + 3)
        let accent = try readU24(data, pos + 6)
        pos += 9
        try FrameDecodeAccounting.reserve(.arrayEntries, 1)
        previews.append(Wire.ThemePreview(name: name, atom: atom, editorBg: editorBg, editorFg: editorFg, accent: accent))
    }

    guard pos + 2 <= end else { throw ProtocolDecodeError.malformed }
    let bindingCount = Int(try readU16(data, pos))
    pos += 2

    var bindings: [Wire.KeybindingEntry] = []
    try FrameDecodeAccounting.reserve(.arrayEntries, bindingCount)
    bindings.reserveCapacity(bindingCount)
    for _ in 0..<bindingCount {
        let mode = try readString8(data: data, pos: &pos, end: end)
        let key = try readString16(data: data, pos: &pos, end: end)
        let command = try readString16(data: data, pos: &pos, end: end)
        let description = try readString16(data: data, pos: &pos, end: end)
        try FrameDecodeAccounting.reserve(.arrayEntries, 1)
        bindings.append(Wire.KeybindingEntry(mode: mode, key: key, command: command, description: description))
    }

    guard pos == end else { throw ProtocolDecodeError.malformed }
    return Wire.ConfigState(options: options, themePreviews: previews, keybindings: bindings)
}

private func readSettingValue(data: Data, pos: inout Int, end: Int) throws -> SettingValue {
    guard pos < end else { throw ProtocolDecodeError.malformed }
    let tag = data[pos]
    pos += 1

    switch tag {
    case SETTING_VALUE_BOOL:
        guard pos + 1 <= end else { throw ProtocolDecodeError.malformed }
        let enabled = data[pos] != 0
        pos += 1
        return .bool(enabled)
    case SETTING_VALUE_INT:
        guard pos + 4 <= end else { throw ProtocolDecodeError.malformed }
        let value = Int(Int32(bitPattern: try readU32(data, pos)))
        pos += 4
        return .int(value)
    case SETTING_VALUE_STRING:
        return .string(try readString16(data: data, pos: &pos, end: end))
    case SETTING_VALUE_ATOM:
        return .atom(try readString16(data: data, pos: &pos, end: end))
    case SETTING_VALUE_FLOAT:
        guard pos + 8 <= end else { throw ProtocolDecodeError.malformed }
        let bits = try readU64(data, pos)
        pos += 8
        return .float(Double(bitPattern: bits))
    default:
        throw ProtocolDecodeError.malformed
    }
}

private func readString8(data: Data, pos: inout Int, end: Int) throws -> String {
    guard pos + 1 <= end else { throw ProtocolDecodeError.malformed }
    let len = Int(data[pos])
    pos += 1
    guard pos + len <= end else { throw ProtocolDecodeError.malformed }
    let string = try readRequiredUTF8(data[pos..<(pos + len)])
    pos += len
    return string
}

private func readString16(data: Data, pos: inout Int, end: Int) throws -> String {
    guard pos + 2 <= end else { throw ProtocolDecodeError.malformed }
    let len = Int(try readU16(data, pos))
    pos += 2
    guard pos + len <= end else { throw ProtocolDecodeError.malformed }
    let string = try readRequiredUTF8(data[pos..<(pos + len)])
    pos += len
    return string
}

// MARK: - Binary helpers

private func legacyFileTreeState(treeFlags: UInt8) -> UInt8 {
    if treeFlags & 0x01 == 0 { return 0 }
    if treeFlags & 0x10 != 0 { return 2 }
    return 3
}

private func readRequiredUTF8(_ data: Data.SubSequence) throws -> String {
    guard let string = try decodeUTF8(data) else {
        throw ProtocolDecodeError.malformed
    }
    return string
}

private func decodeStatusBarSegments(data: Data, pos: inout Int, count: Int, end: Int, version: UInt8) throws -> [Wire.StatusBarSegment] {
    var segments: [Wire.StatusBarSegment] = []
    try FrameDecodeAccounting.reserve(.arrayEntries, count)
    segments.reserveCapacity(count)

    for index in 0..<count {
        var kind = "custom"
        if version >= 2 {
            guard pos + 1 <= end else { throw ProtocolDecodeError.malformed }
            let kindLen = Int(data[pos]); pos += 1
            guard pos + kindLen <= end else { throw ProtocolDecodeError.malformed }
            guard let decodedKind = try decodeUTF8(data[pos..<(pos + kindLen)]) else { throw ProtocolDecodeError.malformed }
            kind = decodedKind
            pos += kindLen
        }

        guard pos + 9 <= end else { throw ProtocolDecodeError.malformed }
        let fg = try readU24(data, pos); pos += 3
        let bg = try readU24(data, pos); pos += 3
        let attrs = data[pos]; pos += 1
        let textLen = Int(try readU16(data, pos)); pos += 2
        guard pos + textLen + 2 <= end else { throw ProtocolDecodeError.malformed }
        guard let text = try decodeUTF8(data[pos..<(pos + textLen)]) else { throw ProtocolDecodeError.malformed }
        pos += textLen
        let commandLen = Int(try readU16(data, pos)); pos += 2
        guard pos + commandLen <= end else { throw ProtocolDecodeError.malformed }
        guard let command = try decodeUTF8(data[pos..<(pos + commandLen)]) else { throw ProtocolDecodeError.malformed }
        pos += commandLen
        try FrameDecodeAccounting.reserve(.arrayEntries, 1)
        segments.append(Wire.StatusBarSegment(id: index, kind: kind, text: text, fgColor: fg, bgColor: bg, attrs: attrs, command: command))
    }

    return segments
}

// MARK: - Shared overlay section decoding

/// Accumulator for overlay sections 0x03-0x0A shared by OP_GUI_WINDOW_CONTENT
/// and the window-rows-delta decoder.
private struct DecodedOverlaySections {
    var selection: GUISelectionOverlay? = nil
    var searchMatches: [GUISearchMatch] = []
    var diagnosticUnderlines: [GUIDiagnosticUnderline] = []
    var documentHighlights: [GUIDocumentHighlight] = []
    var lineAnnotations: [GUILineAnnotation] = []
    var paneGeometry: GUIPaneGeometry? = nil
    var cursorline: GUICursorline? = nil
    var scrollPresentation: GUIScrollPresentation? = nil
}

/// Decodes a single overlay section (IDs 0x03-0x0A) into `sections`.
/// Returns true if the section ID was handled, false otherwise.
private func decodeOverlaySection(id: UInt8, data: Data, start: Int, length: Int, end: Int, into sections: inout DecodedOverlaySections) throws -> Bool {
    switch id {
    case 0x03: // Selection
        guard length >= 1 else { break }
        let selType = data[start]
        if selType != 0, length >= 9 {
            sections.selection = GUISelectionOverlay(
                type: GUISelectionType(rawValue: selType) ?? .char,
                startRow: try readU16(data, start + 1), startCol: try readU16(data, start + 3),
                endRow: try readU16(data, start + 5), endCol: try readU16(data, start + 7)
            )
        }
        return true

    case 0x04: // Search matches
        guard length >= 2 else { break }
        let count = Int(try readU16(data, start))
        try FrameDecodeAccounting.reserve(.overlays, count)
        try FrameDecodeAccounting.reserve(.arrayEntries, count)
        sections.searchMatches.reserveCapacity(count)
        var pos = start + 2
        for _ in 0..<count {
            guard pos + 7 <= end else { break }
            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            sections.searchMatches.append(GUISearchMatch(
                row: try readU16(data, pos), startCol: try readU16(data, pos + 2),
                endCol: try readU16(data, pos + 4), isCurrent: data[pos + 6] != 0
            ))
            pos += 7
        }
        return true

    case 0x05: // Diagnostics
        guard length >= 2 else { break }
        let count = Int(try readU16(data, start))
        try FrameDecodeAccounting.reserve(.overlays, count)
        try FrameDecodeAccounting.reserve(.arrayEntries, count)
        sections.diagnosticUnderlines.reserveCapacity(count)
        var pos = start + 2
        for _ in 0..<count {
            guard pos + 9 <= end else { break }
            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            sections.diagnosticUnderlines.append(GUIDiagnosticUnderline(
                startRow: try readU16(data, pos), startCol: try readU16(data, pos + 2),
                endRow: try readU16(data, pos + 4), endCol: try readU16(data, pos + 6),
                severity: GUIDiagnosticSeverity(rawValue: data[pos + 8]) ?? .error
            ))
            pos += 9
        }
        return true

    case 0x06: // Document highlights
        guard length >= 2 else { break }
        let count = Int(try readU16(data, start))
        try FrameDecodeAccounting.reserve(.overlays, count)
        try FrameDecodeAccounting.reserve(.arrayEntries, count)
        sections.documentHighlights.reserveCapacity(count)
        var pos = start + 2
        for _ in 0..<count {
            guard pos + 9 <= end else { break }
            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            sections.documentHighlights.append(GUIDocumentHighlight(
                startRow: try readU16(data, pos), startCol: try readU16(data, pos + 2),
                endRow: try readU16(data, pos + 4), endCol: try readU16(data, pos + 6),
                kind: GUIDocumentHighlightKind(rawValue: data[pos + 8]) ?? .text
            ))
            pos += 9
        }
        return true

    case 0x07: // Line annotations
        guard length >= 2 else { break }
        let count = Int(try readU16(data, start))
        try FrameDecodeAccounting.reserve(.overlays, count)
        try FrameDecodeAccounting.reserve(.arrayEntries, count)
        sections.lineAnnotations.reserveCapacity(count)
        var pos = start + 2
        for _ in 0..<count {
            guard pos + 11 <= end else { break }
            let annRow = try readU16(data, pos)
            let annKind = GUILineAnnotationKind(rawValue: data[pos + 2]) ?? .inlinePill
            let annFg = try readU24(data, pos + 3)
            let annBg = try readU24(data, pos + 6)
            let annTextLen = Int(try readU16(data, pos + 9))
            pos += 11
            guard pos + annTextLen <= end else { break }
            let annText = try decodeUTF8(data[pos..<(pos + annTextLen)]) ?? ""
            pos += annTextLen
            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            sections.lineAnnotations.append(GUILineAnnotation(row: annRow, kind: annKind, fg: annFg, bg: annBg, text: annText))
        }
        return true

    case 0x08: // Pane geometry
        sections.paneGeometry = try decodePaneGeometry(data: data, start: start, end: end)
        return true

    case 0x09: // Cursorline
        guard length >= 5 else { break }
        sections.cursorline = GUICursorline(row: try readU16(data, start), bg: try readU24(data, start + 2))
        return true

    case 0x0A: // ScrollPresentation
        sections.scrollPresentation = try decodeScrollPresentation(data: data, start: start, end: end)
        return true

    default:
        return false
    }
    return true
}

private func decodeWindowRowsDelta(data: Data, offset: Int,
                                   allowsRowSplices: Bool) throws -> (GUIWindowRowsDelta, Int) {
    let rest = offset + 1
    guard data.count >= rest + 1 else { throw ProtocolDecodeError.malformed }
    let sectionCount = Int(data[rest])
    var pos = rest + 1

    var windowId: UInt16 = 0
    var contentEpoch: UInt32 = 0
    var cursorVisible = true
    var cursorRow: UInt16 = 0
    var cursorCol: UInt16 = 0
    var cursorShape: CursorShape = .block
    var scrollLeft: UInt16 = 0
    var rows: [GUIWindowRowDeltaEntry] = []
    var baseRowCount: UInt32?
    var resultRowCount: UInt32?
    var rowSplices: [GUIWindowRowSplice]?
    var overlays = DecodedOverlaySections()
    var sawHeader = false
    var sawRows = false
    var sawRowSplices = false

    for _ in 0..<sectionCount {
        let section = try readSection32(data, at: pos, containingEnd: data.endIndex)
        let sectionId = section.id
        let sectionStart = section.start
        let sectionEnd = section.end
        let sectionLen = sectionEnd - sectionStart

        switch sectionId {
        case 0x01:
            guard !sawHeader, sectionLen >= 14 else { throw ProtocolDecodeError.malformed }
            sawHeader = true
            windowId = try readU16(data, sectionStart)
            contentEpoch = try readU32(data, sectionStart + 2)
            cursorVisible = data[sectionStart + 6] & 0x01 != 0
            cursorRow = try readU16(data, sectionStart + 7)
            cursorCol = try readU16(data, sectionStart + 9)
            cursorShape = CursorShape(rawValue: data[sectionStart + 11]) ?? .block
            scrollLeft = try readU16(data, sectionStart + 12)

        case 0x02:
            guard !sawRows, !sawRowSplices else { throw ProtocolDecodeError.malformed }
            sawRows = true
            rows = try decodeWindowDeltaRows(data: data, start: sectionStart, end: sectionEnd)

        case 0x0B:
            guard allowsRowSplices, !sawRows, !sawRowSplices else {
                throw ProtocolDecodeError.malformed
            }
            sawRowSplices = true
            (baseRowCount, resultRowCount, rowSplices) = try decodeWindowRowSplices(
                data: data, start: sectionStart, end: sectionEnd
            )

        case 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A:
            _ = try decodeOverlaySection(id: sectionId, data: data, start: sectionStart, length: sectionLen, end: sectionEnd, into: &overlays)

        default:
            break
        }

        pos = sectionEnd
    }

    guard sawHeader, sawRows != sawRowSplices else { throw ProtocolDecodeError.malformed }
    let scrollPresentation = try validatedScrollPresentation(overlays.scrollPresentation, windowId: windowId, contentEpoch: contentEpoch)

    let delta: GUIWindowRowsDelta
    if let baseRowCount, let resultRowCount, let rowSplices {
        delta = GUIWindowRowsDelta(
            windowId: windowId, contentEpoch: contentEpoch, cursorVisible: cursorVisible,
            cursorRow: cursorRow, cursorCol: cursorCol, cursorShape: cursorShape,
            scrollLeft: scrollLeft, baseRowCount: baseRowCount,
            resultRowCount: resultRowCount, rowSplices: rowSplices,
            selection: overlays.selection, searchMatches: overlays.searchMatches,
            diagnosticUnderlines: overlays.diagnosticUnderlines,
            documentHighlights: overlays.documentHighlights,
            lineAnnotations: overlays.lineAnnotations, paneGeometry: overlays.paneGeometry,
            cursorline: overlays.cursorline, scrollPresentation: scrollPresentation
        )
    } else {
        delta = GUIWindowRowsDelta(
            windowId: windowId, contentEpoch: contentEpoch, cursorVisible: cursorVisible,
            cursorRow: cursorRow, cursorCol: cursorCol, cursorShape: cursorShape,
            scrollLeft: scrollLeft, rows: rows, selection: overlays.selection,
            searchMatches: overlays.searchMatches,
            diagnosticUnderlines: overlays.diagnosticUnderlines,
            documentHighlights: overlays.documentHighlights,
            lineAnnotations: overlays.lineAnnotations, paneGeometry: overlays.paneGeometry,
            cursorline: overlays.cursorline, scrollPresentation: scrollPresentation
        )
    }

    return (delta, pos - offset)
}

private func decodeWindowRowSplices(data: Data, start: Int, end: Int) throws ->
    (UInt32, UInt32, [GUIWindowRowSplice]) {
    guard start + 12 <= end else { throw ProtocolDecodeError.malformed }
    let baseCount = try readU32(data, start)
    let resultCount = try readU32(data, start + 4)
    let spliceCount = Int(try readU32(data, start + 8))
    var pos = start + 12
    guard spliceCount <= (end - pos) / 12 else { throw ProtocolDecodeError.malformed }
    try FrameDecodeAccounting.reserve(.spliceEntries, spliceCount)
    var splices: [GUIWindowRowSplice] = []
    try FrameDecodeAccounting.reserve(.arrayEntries, spliceCount)
    splices.reserveCapacity(spliceCount)
    var previousStart: UInt32?
    var previousEnd: UInt64 = 0
    var computedCount = Int64(baseCount)

    for _ in 0..<spliceCount {
        guard pos + 12 <= end else { throw ProtocolDecodeError.malformed }
        let spliceStart = try readU32(data, pos)
        let deleteCount = try readU32(data, pos + 4)
        let insertCount = Int(try readU32(data, pos + 8))
        pos += 12
        let deleteEnd = UInt64(spliceStart) + UInt64(deleteCount)
        guard deleteEnd <= UInt64(baseCount),
              previousStart.map({ spliceStart > $0 }) ?? true,
              UInt64(spliceStart) >= previousEnd,
              deleteCount > 0 || insertCount > 0,
              insertCount <= (end - pos) / 13 else {
            throw ProtocolDecodeError.malformed
        }

        try FrameDecodeAccounting.reserve(.locatorEntries, insertCount)
        var entries: [GUIWindowRowDeltaEntry] = []
        try FrameDecodeAccounting.reserve(.arrayEntries, insertCount)
        entries.reserveCapacity(insertCount)
        for _ in 0..<insertCount {
            guard pos < end else { throw ProtocolDecodeError.malformed }
            let kind = data[pos]
            pos += 1
            switch kind {
            case 0:
                guard pos + 12 <= end else { throw ProtocolDecodeError.malformed }
                try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                entries.append(.reference(
                    rowId: try readU64(data, pos),
                    contentHash: try readU32(data, pos + 8)
                ))
                pos += 12
            case 1:
                try FrameDecodeAccounting.reserve(.rows, 1)
                try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                entries.append(.full(try decodeWindowContentRow(data: data, pos: &pos, end: end)))
            default:
                throw ProtocolDecodeError.malformed
            }
        }
        previousStart = spliceStart
        previousEnd = deleteEnd
        computedCount = computedCount - Int64(deleteCount) + Int64(insertCount)
        guard computedCount >= 0, computedCount <= Int64(UInt32.max) else {
            throw ProtocolDecodeError.malformed
        }
        try FrameDecodeAccounting.reserve(.arrayEntries, 1)
        splices.append(GUIWindowRowSplice(
            startIndex: spliceStart, deleteCount: deleteCount, insertEntries: entries
        ))
    }

    guard pos == end, computedCount == Int64(resultCount) else {
        throw ProtocolDecodeError.malformed
    }
    return (baseCount, resultCount, splices)
}

private func decodeWindowDeltaRows(data: Data, start: Int, end: Int) throws -> [GUIWindowRowDeltaEntry] {
    guard start + 4 <= end else { throw ProtocolDecodeError.malformed }
    let rowCount = Int(try readU32(data, start))
    var pos = start + 4
    guard rowCount <= (end - pos) / 13 else { throw ProtocolDecodeError.malformed }
    try FrameDecodeAccounting.reserve(.locatorEntries, rowCount)
    var rows: [GUIWindowRowDeltaEntry] = []
    try FrameDecodeAccounting.reserve(.arrayEntries, rowCount)
    rows.reserveCapacity(rowCount)

    for _ in 0..<rowCount {
        guard pos + 1 <= end else { throw ProtocolDecodeError.malformed }
        let entryKind = data[pos]
        pos += 1

        switch entryKind {
        case 0:
            guard pos + 12 <= end else { throw ProtocolDecodeError.malformed }
            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            rows.append(.reference(rowId: try readU64(data, pos), contentHash: try readU32(data, pos + 8)))
            pos += 12
        case 1:
            try FrameDecodeAccounting.reserve(.rows, 1)
            let row = try decodeWindowContentRow(data: data, pos: &pos, end: end)
            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            rows.append(.full(row))
        default:
            throw ProtocolDecodeError.malformed
        }
    }

    guard pos == end else { throw ProtocolDecodeError.malformed }
    return rows
}

private func decodeWindowContentRows(data: Data, start: Int, end: Int) throws -> [GUIVisualRow] {
    guard start + 4 <= end else { throw ProtocolDecodeError.malformed }
    let rowCount = Int(try readU32(data, start))
    var pos = start + 4
    guard rowCount <= (end - pos) / 23 else { throw ProtocolDecodeError.malformed }
    try FrameDecodeAccounting.reserve(.rows, rowCount)
    try FrameDecodeAccounting.reserve(.locatorEntries, rowCount)
    var rows: [GUIVisualRow] = []
    try FrameDecodeAccounting.reserve(.arrayEntries, rowCount)
    rows.reserveCapacity(rowCount)

    for _ in 0..<rowCount {
        let row = try decodeWindowContentRow(data: data, pos: &pos, end: end)
        try FrameDecodeAccounting.reserve(.arrayEntries, 1)
        rows.append(row)
    }

    guard pos == end else { throw ProtocolDecodeError.malformed }
    return rows
}

private func decodeWindowContentRow(data: Data, pos: inout Int, end: Int) throws -> GUIVisualRow {
    guard pos + 21 <= end else { throw ProtocolDecodeError.malformed }
    let rowType = GUIVisualRowType(rawValue: data[pos]) ?? .normal
    let rowId = try readU64(data, pos + 1)
    let bufLine = try readU32(data, pos + 9)
    let contentHash = try readU32(data, pos + 13)
    let textLen = Int(try readU32(data, pos + 17))
    pos += 21

    guard pos + textLen <= end else { throw ProtocolDecodeError.malformed }
    let text = try decodeUTF8(data[pos..<(pos + textLen)]) ?? ""
    pos += textLen

    guard pos + 2 <= end else { throw ProtocolDecodeError.malformed }
    let spanCount = Int(try readU16(data, pos))
    pos += 2

    try FrameDecodeAccounting.reserve(.spans, spanCount)
    var spans: [GUIHighlightSpan] = []
    try FrameDecodeAccounting.reserve(.arrayEntries, spanCount)
    spans.reserveCapacity(spanCount)

    for _ in 0..<spanCount {
        guard pos + 13 <= end else { throw ProtocolDecodeError.malformed }
        try FrameDecodeAccounting.reserve(.arrayEntries, 1)
        spans.append(GUIHighlightSpan(
            startCol: try readU16(data, pos), endCol: try readU16(data, pos + 2),
            fg: try readU24(data, pos + 4), bg: try readU24(data, pos + 7),
            attrs: data[pos + 10], fontWeight: data[pos + 11], fontId: data[pos + 12]
        ))
        pos += 13
    }

    return GUIVisualRow(rowType: rowType, rowId: rowId, bufLine: bufLine, contentHash: contentHash, text: text, spans: spans)
}

private struct DecodedChatMessageCandidate {
    let message: Wire.ChatMessage
    let nextOffset: Int
}

private struct DecodedToolPreview {
    let kind: UInt8
    let lines: [String]
    let nextOffset: Int
}

private func decodeToolPreview(data: Data, start: Int, end: Int) throws -> DecodedToolPreview {
    guard end >= start + 3 else { throw ProtocolDecodeError.malformed }
    let previewKind = data[start]
    let lineCount = Int(try readU16(data, start + 1))
    var pos = start + 3
    var previewLines: [String] = []
    try FrameDecodeAccounting.reserve(.arrayEntries, lineCount)
    previewLines.reserveCapacity(lineCount)
    for _ in 0..<lineCount {
        guard end >= pos + 2 else { throw ProtocolDecodeError.malformed }
        let lineLen = Int(try readU16(data, pos))
        guard end >= pos + 2 + lineLen else { throw ProtocolDecodeError.malformed }
        let line = try decodeUTF8(data[(pos + 2)..<(pos + 2 + lineLen)]) ?? ""
        try FrameDecodeAccounting.reserve(.arrayEntries, 1)
        previewLines.append(line)
        pos += 2 + lineLen
    }
    return DecodedToolPreview(kind: previewKind, lines: previewLines, nextOffset: pos)
}

private func decodeFramedChatMessages(data: Data, start: Int, end: Int, count: Int) throws -> [Wire.ChatMessage] {
    var messages: [Wire.ChatMessage] = []
    try FrameDecodeAccounting.reserve(.arrayEntries, count)
    messages.reserveCapacity(count)
    var pos = start

    for _ in 0..<count {
        guard pos + 4 <= end else { throw ProtocolDecodeError.malformed }
        let messageLen = Int(try readU32(data, pos))
        let messageStart = pos + 4
        let messageEnd = messageStart + messageLen
        guard messageEnd <= end else { throw ProtocolDecodeError.malformed }

        let candidates = try decodeChatMessageCandidates(data: data, start: messageStart, end: messageEnd)
        guard let candidate = candidates.first(where: { $0.nextOffset == messageEnd }) else {
            throw ProtocolDecodeError.malformed
        }

        try FrameDecodeAccounting.reserve(.arrayEntries, 1)
        messages.append(candidate.message)
        pos = messageEnd
    }

    guard pos == end else { throw ProtocolDecodeError.malformed }
    return messages
}

private func decodeLegacyChatMessages(data: Data, start: Int, end: Int, remaining: Int) throws -> ([Wire.ChatMessage], Int) {
    if remaining == 0 {
        guard start == end else { throw ProtocolDecodeError.malformed }
        return ([], start)
    }

    let candidates = try decodeChatMessageCandidates(data: data, start: start, end: end)

    for candidate in candidates {
        if let (rest, decodedEnd) = try? FrameDecodeAccounting.withCheckpoint({
            try decodeLegacyChatMessages(
                data: data,
                start: candidate.nextOffset,
                end: end,
                remaining: remaining - 1
            )
        }) {
            let (combinedCount, overflow) = rest.count.addingReportingOverflow(1)
            guard !overflow else { throw FrameResourceError.arithmeticOverflow }
            try FrameDecodeAccounting.reserve(.arrayEntries, combinedCount)
            return ([candidate.message] + rest, decodedEnd)
        }
    }

    throw ProtocolDecodeError.malformed
}

private func decodeAgentStyledLines(data: Data, start: Int, end: Int) throws -> ([[Wire.StyledTextRun]], Int) {
    guard end >= start + 2 else { throw ProtocolDecodeError.malformed }
    let lineCount = Int(try readU16(data, start))
    var lines: [[Wire.StyledTextRun]] = []
    try FrameDecodeAccounting.reserve(.arrayEntries, lineCount)
    lines.reserveCapacity(lineCount)
    var pos = start + 2
    for _ in 0..<lineCount {
        guard end >= pos + 2 else { throw ProtocolDecodeError.malformed }
        let runCount = Int(try readU16(data, pos))
        var runs: [Wire.StyledTextRun] = []
        try FrameDecodeAccounting.reserve(.arrayEntries, runCount)
        runs.reserveCapacity(runCount)
        pos += 2
        for _ in 0..<runCount {
            guard end >= pos + 9 else { throw ProtocolDecodeError.malformed }
            let textLen = Int(try readU16(data, pos))
            guard end >= pos + 2 + textLen + 7 else { throw ProtocolDecodeError.malformed }
            let runText = try decodeUTF8(data[(pos + 2)..<(pos + 2 + textLen)]) ?? ""
            let fgOff = pos + 2 + textLen
            let flags = data[fgOff + 6]
            var nextRunPos = fgOff + 7
            var linkURL: String? = nil
            if (flags & 0x08) != 0 {
                guard end >= nextRunPos + 2 else { throw ProtocolDecodeError.malformed }
                let urlLen = Int(try readU16(data, nextRunPos))
                guard end >= nextRunPos + 2 + urlLen else { throw ProtocolDecodeError.malformed }
                guard let decodedLinkURL = try decodeUTF8(data[(nextRunPos + 2)..<(nextRunPos + 2 + urlLen)]) else { throw ProtocolDecodeError.malformed }
                linkURL = decodedLinkURL
                nextRunPos += 2 + urlLen
            }
            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            runs.append(Wire.StyledTextRun(
                text: runText,
                fgR: data[fgOff], fgG: data[fgOff + 1], fgB: data[fgOff + 2],
                bgR: data[fgOff + 3], bgG: data[fgOff + 4], bgB: data[fgOff + 5],
                bold: (flags & 0x01) != 0,
                italic: (flags & 0x02) != 0,
                underline: (flags & 0x04) != 0,
                code: (flags & 0x10) != 0,
                linkURL: linkURL
            ))
            pos = nextRunPos
        }
        try FrameDecodeAccounting.reserve(.arrayEntries, 1)
        lines.append(runs)
    }
    return (lines, pos)
}

private func decodeAgentMarkdownBlocks(data: Data, start: Int, end: Int) throws -> ([Wire.AgentMarkdownBlock], Int) {
    guard end >= start + 2 else { throw ProtocolDecodeError.malformed }
    let blockCount = Int(try readU16(data, start))
    var blocks: [Wire.AgentMarkdownBlock] = []
    try FrameDecodeAccounting.reserve(.arrayEntries, blockCount)
    blocks.reserveCapacity(blockCount)
    var pos = start + 2
    for _ in 0..<blockCount {
        guard end >= pos + 6 else { throw ProtocolDecodeError.malformed }
        let blockID = try readU32(data, pos)
        let rawKind = data[pos + 4]
        let flags = data[pos + 5]
        guard let kind = Wire.AgentMarkdownBlockKind(rawValue: rawKind) else { throw ProtocolDecodeError.malformed }
        pos += 6
        var lines: [[Wire.StyledTextRun]] = []
        var level: UInt8 = 0
        var indent: UInt8 = 0
        var ordered = false
        var ordinal: UInt32 = 0
        var height: UInt8 = 1
        var language = ""
        var label = ""
        var targetPath = ""
        var capabilityFlags: UInt8 = 0

        switch kind {
        case .paragraph, .blockquote:
            (lines, pos) = try decodeAgentStyledLines(data: data, start: pos, end: end)
        case .heading:
            guard end >= pos + 1 else { throw ProtocolDecodeError.malformed }
            level = data[pos]
            (lines, pos) = try decodeAgentStyledLines(data: data, start: pos + 1, end: end)
        case .listItem:
            guard end >= pos + 6 else { throw ProtocolDecodeError.malformed }
            indent = data[pos]
            ordered = data[pos + 1] != 0
            ordinal = try readU32(data, pos + 2)
            (lines, pos) = try decodeAgentStyledLines(data: data, start: pos + 6, end: end)
        case .rule:
            break
        case .spacer:
            guard end >= pos + 1 else { throw ProtocolDecodeError.malformed }
            height = data[pos]
            pos += 1
        case .codeBlock:
            language = try readRequiredString16(data: data, pos: &pos, end: end)
            label = try readRequiredString16(data: data, pos: &pos, end: end)
            targetPath = try readRequiredString16(data: data, pos: &pos, end: end)
            guard end >= pos + 1 else { throw ProtocolDecodeError.malformed }
            capabilityFlags = data[pos]
            pos += 1
            (lines, pos) = try decodeAgentStyledLines(data: data, start: pos, end: end)
        }

        try FrameDecodeAccounting.reserve(.arrayEntries, 1)
        blocks.append(Wire.AgentMarkdownBlock(id: blockID, kind: kind, flags: flags, lines: lines, level: level, indent: indent, ordered: ordered, ordinal: ordinal, height: height, language: language, label: label, targetPath: targetPath, capabilityFlags: capabilityFlags))
    }
    return (blocks, pos)
}

private func readRequiredString16(data: Data, pos: inout Int, end: Int) throws -> String {
    guard end >= pos + 2 else { throw ProtocolDecodeError.malformed }
    let length = Int(try readU16(data, pos))
    guard end >= pos + 2 + length else { throw ProtocolDecodeError.malformed }
    let value = try decodeUTF8(data[(pos + 2)..<(pos + 2 + length)]) ?? ""
    pos += 2 + length
    return value
}

private func decodeChatMessageCandidates(data: Data, start: Int, end: Int) throws -> [DecodedChatMessageCandidate] {
    guard start + 4 <= end else { throw ProtocolDecodeError.malformed }

    let beamId = try readU32(data, start)
    return try decodeChatMessageBodyCandidates(data: data, beamId: beamId, bodyStart: start + 4, end: end)
}

/// Decodes a single chat-message body (no leading id) with an externally supplied
/// `beamId`. The 0x78 `gui_agent_chat` messages section frames each message as
/// `<<id::32, body>>`, so `decodeChatMessageCandidates` reads the id then calls
/// this. The 0x86 `gui_agent_transcript` stream frames each entry as
/// `<<id::32, body_len::32, body>>`, carrying the id and length separately, so it
/// calls this directly with the pre-read id. Both share the exact same body codec.
private func decodeChatMessageBodyCandidates(data: Data, beamId: UInt32, bodyStart: Int, end: Int) throws -> [DecodedChatMessageCandidate] {
    guard bodyStart + 1 <= end else { throw ProtocolDecodeError.malformed }

    let msgType = data[bodyStart]
    let pos = bodyStart

    switch msgType {
    case 0x01: // user
        guard end >= pos + 5 else { throw ProtocolDecodeError.malformed }
        let tLen = Int(try readU32(data, pos + 1))
        guard end >= pos + 5 + tLen else { throw ProtocolDecodeError.malformed }
        let t = try decodeUTF8(data[(pos + 5)..<(pos + 5 + tLen)]) ?? ""
        return [DecodedChatMessageCandidate(message: Wire.ChatMessage(beamId: beamId, content: .user(text: t)), nextOffset: pos + 5 + tLen)]

    case 0x02: // assistant
        guard end >= pos + 5 else { throw ProtocolDecodeError.malformed }
        let tLen = Int(try readU32(data, pos + 1))
        guard end >= pos + 5 + tLen else { throw ProtocolDecodeError.malformed }
        let t = try decodeUTF8(data[(pos + 5)..<(pos + 5 + tLen)]) ?? ""
        return [DecodedChatMessageCandidate(message: Wire.ChatMessage(beamId: beamId, content: .assistant(text: t)), nextOffset: pos + 5 + tLen)]

    case 0x03: // thinking
        guard end >= pos + 6 else { throw ProtocolDecodeError.malformed }
        let collapsed = data[pos + 1] != 0
        let tLen = Int(try readU32(data, pos + 2))
        guard end >= pos + 6 + tLen else { throw ProtocolDecodeError.malformed }
        let t = try decodeUTF8(data[(pos + 6)..<(pos + 6 + tLen)]) ?? ""
        return [DecodedChatMessageCandidate(message: Wire.ChatMessage(beamId: beamId, content: .thinking(text: t, collapsed: collapsed)), nextOffset: pos + 6 + tLen)]

    case 0x04: // tool_call
        guard end >= pos + 10 else { throw ProtocolDecodeError.malformed }
        let tcStatus = data[pos + 1]
        let isError = data[pos + 2] != 0
        let tcCollapsed = data[pos + 3] != 0
        let duration = try readU32(data, pos + 4)
        let nameLen = Int(try readU16(data, pos + 8))
        guard end >= pos + 10 + nameLen + 2 else { throw ProtocolDecodeError.malformed }
        let name = try decodeUTF8(data[(pos + 10)..<(pos + 10 + nameLen)]) ?? ""
        let summaryLen = Int(try readU16(data, pos + 10 + nameLen))
        guard end >= pos + 12 + nameLen + summaryLen + 4 else { throw ProtocolDecodeError.malformed }
        let summary = try decodeUTF8(data[(pos + 12 + nameLen)..<(pos + 12 + nameLen + summaryLen)]) ?? ""
        let resultLen = Int(try readU32(data, pos + 12 + nameLen + summaryLen))
        let baseOffset = pos + 16 + nameLen + summaryLen + resultLen
        guard end >= baseOffset else { throw ProtocolDecodeError.malformed }
        let result = try decodeUTF8(data[(pos + 16 + nameLen + summaryLen)..<(pos + 16 + nameLen + summaryLen + resultLen)]) ?? ""
        var candidates: [DecodedChatMessageCandidate] = []
        if end > baseOffset {
            let autoApprovedScope = data[baseOffset]
            if autoApprovedScope <= 2 {
                let messageWithAuto = Wire.ChatMessage(beamId: beamId, content: .toolCall(name: name, summary: summary, status: tcStatus, isError: isError, collapsed: tcCollapsed, autoApprovedScope: autoApprovedScope, durationMs: duration, result: result, previewKind: 0, previewLines: []))
                try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                candidates.append(DecodedChatMessageCandidate(message: messageWithAuto, nextOffset: baseOffset + 1))
                if end > baseOffset + 1,
                   let preview = try? FrameDecodeAccounting.withCheckpoint({
                       try decodeToolPreview(data: data, start: baseOffset + 1, end: end)
                   }) {
                    let messageWithPreview = Wire.ChatMessage(beamId: beamId, content: .toolCall(name: name, summary: summary, status: tcStatus, isError: isError, collapsed: tcCollapsed, autoApprovedScope: autoApprovedScope, durationMs: duration, result: result, previewKind: preview.kind, previewLines: preview.lines))
                    try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                    candidates.append(DecodedChatMessageCandidate(message: messageWithPreview, nextOffset: preview.nextOffset))
                }
            }
        }
        let messageWithoutAuto = Wire.ChatMessage(beamId: beamId, content: .toolCall(name: name, summary: summary, status: tcStatus, isError: isError, collapsed: tcCollapsed, autoApprovedScope: 0, durationMs: duration, result: result, previewKind: 0, previewLines: []))
        try FrameDecodeAccounting.reserve(.arrayEntries, 1)
        candidates.append(DecodedChatMessageCandidate(message: messageWithoutAuto, nextOffset: baseOffset))
        return candidates

    case 0x05: // system
        guard end >= pos + 6 else { throw ProtocolDecodeError.malformed }
        let isError = data[pos + 1] != 0
        let tLen = Int(try readU32(data, pos + 2))
        guard end >= pos + 6 + tLen else { throw ProtocolDecodeError.malformed }
        let t = try decodeUTF8(data[(pos + 6)..<(pos + 6 + tLen)]) ?? ""
        return [DecodedChatMessageCandidate(message: Wire.ChatMessage(beamId: beamId, content: .system(text: t, isError: isError)), nextOffset: pos + 6 + tLen)]

    case 0x06: // usage
        guard end >= pos + 21 else { throw ProtocolDecodeError.malformed }
        let inp = try readU32(data, pos + 1)
        let outp = try readU32(data, pos + 5)
        let cacheR = try readU32(data, pos + 9)
        let cacheW = try readU32(data, pos + 13)
        let costM = try readU32(data, pos + 17)
        return [DecodedChatMessageCandidate(message: Wire.ChatMessage(beamId: beamId, content: .usage(input: inp, output: outp, cacheRead: cacheR, cacheWrite: cacheW, costMicros: costM)), nextOffset: pos + 21)]

    case 0x07: // styled_assistant
        guard end >= pos + 3 else { throw ProtocolDecodeError.malformed }
        let lineCount = Int(try readU16(data, pos + 1))
        var lines: [[Wire.StyledTextRun]] = []
        try FrameDecodeAccounting.reserve(.arrayEntries, lineCount)
        lines.reserveCapacity(lineCount)
        var rPos = pos + 3
        for _ in 0..<lineCount {
            guard end >= rPos + 2 else { throw ProtocolDecodeError.malformed }
            let runCount = Int(try readU16(data, rPos))
            var runs: [Wire.StyledTextRun] = []
            try FrameDecodeAccounting.reserve(.arrayEntries, runCount)
            runs.reserveCapacity(runCount)
            rPos += 2
            for _ in 0..<runCount {
                guard end >= rPos + 9 else { throw ProtocolDecodeError.malformed }
                let textLen = Int(try readU16(data, rPos))
                guard end >= rPos + 2 + textLen + 7 else { throw ProtocolDecodeError.malformed }
                let runText = try decodeUTF8(data[(rPos + 2)..<(rPos + 2 + textLen)]) ?? ""
                let fgOff = rPos + 2 + textLen
                let fgR = data[fgOff]
                let fgG = data[fgOff + 1]
                let fgB = data[fgOff + 2]
                let bgR = data[fgOff + 3]
                let bgG = data[fgOff + 4]
                let bgB = data[fgOff + 5]
                let flags = data[fgOff + 6]
                var nextRunPos = fgOff + 7
                var linkURL: String? = nil
                if (flags & 0x08) != 0 {
                    guard end >= nextRunPos + 2 else { throw ProtocolDecodeError.malformed }
                    let urlLen = Int(try readU16(data, nextRunPos))
                    guard end >= nextRunPos + 2 + urlLen else { throw ProtocolDecodeError.malformed }
                    guard let decodedLinkURL = try decodeUTF8(data[(nextRunPos + 2)..<(nextRunPos + 2 + urlLen)]) else { throw ProtocolDecodeError.malformed }
                    linkURL = decodedLinkURL
                    nextRunPos += 2 + urlLen
                }
                try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                runs.append(Wire.StyledTextRun(
                    text: runText,
                    fgR: fgR, fgG: fgG, fgB: fgB,
                    bgR: bgR, bgG: bgG, bgB: bgB,
                    bold: (flags & 0x01) != 0,
                    italic: (flags & 0x02) != 0,
                    underline: (flags & 0x04) != 0,
                    code: (flags & 0x10) != 0,
                    linkURL: linkURL
                ))
                rPos = nextRunPos
            }
            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            lines.append(runs)
        }
        return [DecodedChatMessageCandidate(message: Wire.ChatMessage(beamId: beamId, content: .styledAssistant(lines: lines)), nextOffset: rPos)]

    case 0x08: // styled_tool_call
        guard end >= pos + 10 else { throw ProtocolDecodeError.malformed }
        let stcStatus = data[pos + 1]
        let stcIsError = data[pos + 2] != 0
        let stcCollapsed = data[pos + 3] != 0
        let stcDuration = try readU32(data, pos + 4)
        let stcNameLen = Int(try readU16(data, pos + 8))
        guard end >= pos + 10 + stcNameLen + 2 else { throw ProtocolDecodeError.malformed }
        let stcName = try decodeUTF8(data[(pos + 10)..<(pos + 10 + stcNameLen)]) ?? ""
        let stcSummaryLen = Int(try readU16(data, pos + 10 + stcNameLen))
        guard end >= pos + 12 + stcNameLen + stcSummaryLen + 2 else { throw ProtocolDecodeError.malformed }
        let stcSummary = try decodeUTF8(data[(pos + 12 + stcNameLen)..<(pos + 12 + stcNameLen + stcSummaryLen)]) ?? ""
        let stcLineCount = Int(try readU16(data, pos + 12 + stcNameLen + stcSummaryLen))
        var stcLines: [[Wire.StyledTextRun]] = []
        try FrameDecodeAccounting.reserve(.arrayEntries, stcLineCount)
        stcLines.reserveCapacity(stcLineCount)
        var stcPos = pos + 14 + stcNameLen + stcSummaryLen
        for _ in 0..<stcLineCount {
            guard end >= stcPos + 2 else { throw ProtocolDecodeError.malformed }
            let runCount = Int(try readU16(data, stcPos))
            var runs: [Wire.StyledTextRun] = []
            try FrameDecodeAccounting.reserve(.arrayEntries, runCount)
            runs.reserveCapacity(runCount)
            stcPos += 2
            for _ in 0..<runCount {
                guard end >= stcPos + 9 else { throw ProtocolDecodeError.malformed }
                let textLen = Int(try readU16(data, stcPos))
                guard end >= stcPos + 2 + textLen + 7 else { throw ProtocolDecodeError.malformed }
                let runText = try decodeUTF8(data[(stcPos + 2)..<(stcPos + 2 + textLen)]) ?? ""
                let fgOff = stcPos + 2 + textLen
                let flags = data[fgOff + 6]
                var nextRunPos = fgOff + 7
                var linkURL: String? = nil
                if (flags & 0x08) != 0 {
                    guard end >= nextRunPos + 2 else { throw ProtocolDecodeError.malformed }
                    let urlLen = Int(try readU16(data, nextRunPos))
                    guard end >= nextRunPos + 2 + urlLen else { throw ProtocolDecodeError.malformed }
                    guard let decodedLinkURL = try decodeUTF8(data[(nextRunPos + 2)..<(nextRunPos + 2 + urlLen)]) else { throw ProtocolDecodeError.malformed }
                    linkURL = decodedLinkURL
                    nextRunPos += 2 + urlLen
                }
                try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                runs.append(Wire.StyledTextRun(
                    text: runText,
                    fgR: data[fgOff], fgG: data[fgOff + 1], fgB: data[fgOff + 2],
                    bgR: data[fgOff + 3], bgG: data[fgOff + 4], bgB: data[fgOff + 5],
                    bold: (flags & 0x01) != 0,
                    italic: (flags & 0x02) != 0,
                    underline: (flags & 0x04) != 0,
                    code: (flags & 0x10) != 0,
                    linkURL: linkURL
                ))
                stcPos = nextRunPos
            }
            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            stcLines.append(runs)
        }
        let stcBaseOffset = stcPos
        guard end >= stcBaseOffset else { throw ProtocolDecodeError.malformed }
        var stcCandidates: [DecodedChatMessageCandidate] = []
        if end > stcBaseOffset {
            let stcAutoApprovedScope = data[stcBaseOffset]
            if stcAutoApprovedScope <= 2 {
                let stcMessageWithAuto = Wire.ChatMessage(beamId: beamId, content: .styledToolCall(name: stcName, summary: stcSummary, status: stcStatus, isError: stcIsError, collapsed: stcCollapsed, autoApprovedScope: stcAutoApprovedScope, durationMs: stcDuration, resultLines: stcLines, previewKind: 0, previewLines: []))
                try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                stcCandidates.append(DecodedChatMessageCandidate(message: stcMessageWithAuto, nextOffset: stcBaseOffset + 1))
                if end > stcBaseOffset + 1,
                   let stcPreview = try? FrameDecodeAccounting.withCheckpoint({
                       try decodeToolPreview(data: data, start: stcBaseOffset + 1, end: end)
                   }) {
                    let stcMessageWithPreview = Wire.ChatMessage(beamId: beamId, content: .styledToolCall(name: stcName, summary: stcSummary, status: stcStatus, isError: stcIsError, collapsed: stcCollapsed, autoApprovedScope: stcAutoApprovedScope, durationMs: stcDuration, resultLines: stcLines, previewKind: stcPreview.kind, previewLines: stcPreview.lines))
                    try FrameDecodeAccounting.reserve(.arrayEntries, 1)
                    stcCandidates.append(DecodedChatMessageCandidate(message: stcMessageWithPreview, nextOffset: stcPreview.nextOffset))
                }
            }
        }
        let stcMessageWithoutAuto = Wire.ChatMessage(beamId: beamId, content: .styledToolCall(name: stcName, summary: stcSummary, status: stcStatus, isError: stcIsError, collapsed: stcCollapsed, autoApprovedScope: 0, durationMs: stcDuration, resultLines: stcLines, previewKind: 0, previewLines: []))
        try FrameDecodeAccounting.reserve(.arrayEntries, 1)
        stcCandidates.append(DecodedChatMessageCandidate(message: stcMessageWithoutAuto, nextOffset: stcBaseOffset))
        return stcCandidates

    case 0x0A: // assistant_markdown
        let (blocks, next) = try decodeAgentMarkdownBlocks(data: data, start: pos + 1, end: end)
        return [DecodedChatMessageCandidate(message: Wire.ChatMessage(beamId: beamId, content: .assistantMarkdown(blocks: blocks)), nextOffset: next)]

    case 0x09: // approval_tool_call
        guard end >= pos + 8 else { throw ProtocolDecodeError.malformed }
        let nameLen = Int(try readU16(data, pos + 2))
        guard end >= pos + 4 + nameLen + 2 else { throw ProtocolDecodeError.malformed }
        let name = try decodeUTF8(data[(pos + 4)..<(pos + 4 + nameLen)]) ?? ""
        let summaryLen = Int(try readU16(data, pos + 4 + nameLen))
        guard end >= pos + 6 + nameLen + summaryLen + 2 else { throw ProtocolDecodeError.malformed }
        let summary = try decodeUTF8(data[(pos + 6 + nameLen)..<(pos + 6 + nameLen + summaryLen)]) ?? ""
        let idLen = Int(try readU16(data, pos + 6 + nameLen + summaryLen))
        guard end >= pos + 8 + nameLen + summaryLen + idLen + 3 else { throw ProtocolDecodeError.malformed }
        let toolCallId = try decodeUTF8(data[(pos + 8 + nameLen + summaryLen)..<(pos + 8 + nameLen + summaryLen + idLen)]) ?? ""
        let previewKind = data[pos + 8 + nameLen + summaryLen + idLen]
        let lineCount = Int(try readU16(data, pos + 9 + nameLen + summaryLen + idLen))
        var approvalPos = pos + 11 + nameLen + summaryLen + idLen
        var previewLines: [String] = []
        try FrameDecodeAccounting.reserve(.arrayEntries, lineCount)
        previewLines.reserveCapacity(lineCount)
        for _ in 0..<lineCount {
            guard end >= approvalPos + 2 else { throw ProtocolDecodeError.malformed }
            let lineLen = Int(try readU16(data, approvalPos))
            guard end >= approvalPos + 2 + lineLen else { throw ProtocolDecodeError.malformed }
            let line = try decodeUTF8(data[(approvalPos + 2)..<(approvalPos + 2 + lineLen)]) ?? ""
            try FrameDecodeAccounting.reserve(.arrayEntries, 1)
            previewLines.append(line)
            approvalPos += 2 + lineLen
        }
        return [DecodedChatMessageCandidate(message: Wire.ChatMessage(beamId: beamId, content: .approvalToolCall(name: name, summary: summary, toolCallId: toolCallId, previewKind: previewKind, previewLines: previewLines)), nextOffset: approvalPos)]

    default:
        throw ProtocolDecodeError.malformed
    }
}

private func validatedScrollPresentation(_ presentation: GUIScrollPresentation?, windowId: UInt16, contentEpoch: UInt32) throws -> GUIScrollPresentation? {
    guard let presentation else { return nil }
    guard presentation.belongsTo(windowId: windowId, contentEpoch: contentEpoch) else {
        throw ProtocolDecodeError.malformed
    }
    return presentation
}

private func decodeScrollPresentation(data: Data, start: Int, end: Int) throws -> GUIScrollPresentation {
    guard start + 39 <= end else { throw ProtocolDecodeError.malformed }

    return GUIScrollPresentation(
        windowId: try readU16(data, start),
        resetRequired: data[start + 2] & 0x01 != 0,
        anchorTop: try readU32(data, start + 3),
        anchorLeft: try readU16(data, start + 7),
        anchorVisualRowOffset: try readU16(data, start + 9),
        visibleStartLine: try readU32(data, start + 11),
        visibleEndLine: try readU32(data, start + 15),
        overscanStartLine: try readU32(data, start + 19),
        overscanEndLine: try readU32(data, start + 23),
        contentEpoch: try readU32(data, start + 27),
        layoutGeneration: try readU32(data, start + 31),
        scrollSeq: try readU32(data, start + 35)
    )
}

private func decodePaneGeometry(data: Data, start: Int, end: Int) throws -> GUIPaneGeometry {
    var pos = start
    guard pos + 2 <= end else { throw ProtocolDecodeError.malformed }
    let windowId = try readU16(data, pos)
    pos += 2

    let totalRect = try readCellRect(data, pos, end)
    pos += 8
    let contentRect = try readCellRect(data, pos, end)
    pos += 8
    let textRect = try readCellRect(data, pos, end)
    pos += 8
    let gutterRect = try readCellRect(data, pos, end)
    pos += 8
    let clipRect = try readCellRect(data, pos, end)
    pos += 8

    guard pos + 20 <= end else { throw ProtocolDecodeError.malformed }
    let viewport = GUIViewportSummary(
        top: try readU32(data, pos),
        left: try readU16(data, pos + 4),
        rows: try readU16(data, pos + 6),
        cols: try readU16(data, pos + 8),
        totalLines: try readU32(data, pos + 10),
        visualRowOffset: try readU16(data, pos + 14),
        totalVisualRows: try readU32(data, pos + 16)
    )
    pos += 20

    guard pos + 5 <= end else { throw ProtocolDecodeError.malformed }
    let metrics = GUIGutterMetrics(lineNumberWidth: try readU16(data, pos), signColWidth: try readU16(data, pos + 2))
    let hitCount = Int(data[pos + 4])
    pos += 5

    var hitRegions: [GUIHitRegion] = []
    try FrameDecodeAccounting.reserve(.arrayEntries, hitCount)
    hitRegions.reserveCapacity(hitCount)
    for _ in 0..<hitCount {
        guard pos + 11 <= end else { throw ProtocolDecodeError.malformed }
        let kind = GUIHitRegion.Kind(rawValue: data[pos]) ?? .text
        let rect = try readCellRect(data, pos + 1, end)
        let regionWindowId = try readU16(data, pos + 9)
        try FrameDecodeAccounting.reserve(.arrayEntries, 1)
        hitRegions.append(GUIHitRegion(kind: kind, rect: rect, windowId: regionWindowId))
        pos += 11
    }

    return GUIPaneGeometry(
        windowId: windowId,
        totalRect: totalRect,
        contentRect: contentRect,
        textRect: textRect,
        gutterRect: gutterRect,
        clipRect: clipRect,
        viewport: viewport,
        gutterMetrics: metrics,
        hitRegions: hitRegions
    )
}

private func readCellRect(_ data: Data, _ offset: Int, _ end: Int) throws -> GUICellRect {
    guard offset + 8 <= end else { throw ProtocolDecodeError.malformed }
    return GUICellRect(
        row: try readU16(data, offset),
        col: try readU16(data, offset + 2),
        width: try readU16(data, offset + 4),
        height: try readU16(data, offset + 6)
    )
}

private struct BoundedSection {
    let id: UInt8
    let start: Int
    let end: Int
}

private func readSection16(_ data: Data, at offset: Int, containingEnd: Int) throws -> BoundedSection {
    var container = try ByteCursor(data, range: offset..<containingEnd)
    let id = try container.readUInt8()
    let length = Int(try container.readUInt16())
    let payload = try container.readSubcursor(count: length)
    return BoundedSection(id: id, start: payload.offset, end: payload.offset + payload.remaining)
}

private func readSection32(_ data: Data, at offset: Int, containingEnd: Int) throws -> BoundedSection {
    var container = try ByteCursor(data, range: offset..<containingEnd)
    let id = try container.readUInt8()
    let length = Int(try container.readUInt32())
    let payload = try container.readSubcursor(count: length)
    return BoundedSection(id: id, start: payload.offset, end: payload.offset + payload.remaining)
}

private func decodeUTF8(_ data: Data) throws -> String? {
    var cursor = ByteCursor(data)
    try FrameDecodeAccounting.reserve(.ownedUTF8Bytes, cursor.remaining)
    let bytes = try cursor.readSlice(count: cursor.remaining)
    return String(bytes: bytes, encoding: .utf8)
}

private func readU16(_ data: Data, _ offset: Int) throws -> UInt16 {
    var cursor = try checkedCursor(data, offset: offset, count: 2)
    return try cursor.readUInt16()
}

private func readU24(_ data: Data, _ offset: Int) throws -> UInt32 {
    var cursor = try checkedCursor(data, offset: offset, count: 3)
    return UInt32(try cursor.readUInt8()) << 16 |
           UInt32(try cursor.readUInt8()) << 8 |
           UInt32(try cursor.readUInt8())
}

private func readU32(_ data: Data, _ offset: Int) throws -> UInt32 {
    var cursor = try checkedCursor(data, offset: offset, count: 4)
    return try cursor.readUInt32()
}

private func readU64(_ data: Data, _ offset: Int) throws -> UInt64 {
    var cursor = try checkedCursor(data, offset: offset, count: 8)
    return try cursor.readUInt64()
}

private func checkedCursor(_ data: Data, offset: Int, count: Int) throws -> ByteCursor {
    guard offset >= data.startIndex,
          count >= 0,
          offset <= data.endIndex,
          count <= data.endIndex - offset else {
        throw ProtocolDecodeError.outOfBounds(
            offset: max(data.startIndex, min(offset, data.endIndex)),
            required: max(count, 0),
            remaining: offset <= data.endIndex ? max(data.endIndex - max(offset, data.startIndex), 0) : 0
        )
    }
    return try ByteCursor(data, range: offset..<(offset + count))
}
