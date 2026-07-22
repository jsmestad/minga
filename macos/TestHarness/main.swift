/// Headless Swift test harness for GUI protocol integration testing.
///
/// Reads {:packet, 4} framed protocol data from stdin, decodes all GUI
/// chrome opcodes, and reports decoded data on stdout as {:packet, 4}
/// framed JSON (one message per opcode received). Can also send synthetic
/// input events (gui_action, key_press) back to the BEAM.
///
/// No Metal, SwiftUI, or UI framework needed. Purely a command-line tool
/// for CI-friendly protocol round-trip testing.

import Foundation

// MARK: - I/O helpers

let stdin = FileHandle.standardInput
let stdout = FileHandle.standardOutput
let lock = NSLock()
let emitSelectTab = CommandLine.arguments.contains("--emit-select-tab")

/// Writes a {:packet, 4} framed message to stdout.
func writeFramed(_ data: Data) {
    var header = Data(count: 4)
    let len = UInt32(data.count)
    header[0] = UInt8((len >> 24) & 0xFF)
    header[1] = UInt8((len >> 16) & 0xFF)
    header[2] = UInt8((len >> 8) & 0xFF)
    header[3] = UInt8(len & 0xFF)
    lock.lock()
    stdout.write(header)
    stdout.write(data)
    lock.unlock()
}

/// Writes a JSON object as a {:packet, 4} framed message.
func writeJSON(_ dict: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: dict) {
        writeFramed(data)
    }
}

/// Sends a gui_action: select_tab back to the BEAM.
/// Layout: opcode(1) + action_type(1) + tab_id(4) = 6 bytes.
func sendSelectTab(id: UInt32) {
    var buf = Data(count: 6)
    buf[0] = OP_GUI_ACTION
    buf[1] = GUI_ACTION_SELECT_TAB
    buf[2] = UInt8((id >> 24) & 0xFF)
    buf[3] = UInt8((id >> 16) & 0xFF)
    buf[4] = UInt8((id >> 8) & 0xFF)
    buf[5] = UInt8(id & 0xFF)
    writeFramed(buf)
}

// MARK: - Command to JSON conversion

func jsonUInt64(_ value: UInt64) -> Any {
    if value <= UInt64(Int.max) {
        return Int(value)
    }
    return String(value)
}

func highlightSpanJSON(_ span: GUIHighlightSpan) -> [String: Any] {
    var result: [String: Any] = [:]
    result["start_col"] = Int(span.startCol)
    result["end_col"] = Int(span.endCol)
    result["fg"] = Int(span.fg)
    result["bg"] = Int(span.bg)
    result["attrs"] = Int(span.attrs)
    result["font_weight"] = Int(span.fontWeight)
    result["font_id"] = Int(span.fontId)
    return result
}

func visualRowJSON(_ row: GUIVisualRow) -> [String: Any] {
    let spans: [[String: Any]] = row.spans.map { span in
        highlightSpanJSON(span)
    }
    var result: [String: Any] = [:]
    result["row_type"] = Int(row.rowType.rawValue)
    result["row_id"] = jsonUInt64(row.rowId)
    result["buf_line"] = Int(row.bufLine)
    result["content_hash"] = Int(row.contentHash)
    result["text"] = row.text
    result["spans"] = spans
    return result
}

func windowRowsDeltaResult(type: String, delta: GUIWindowRowsDelta) -> [String: Any] {
    func entryJSON(_ entry: GUIWindowRowDeltaEntry) -> [String: Any] {
        switch entry {
        case .reference(let rowId, let contentHash):
            return ["entry_type": "ref", "row_id": jsonUInt64(rowId), "content_hash": Int(contentHash)]
        case .full(let row):
            return ["entry_type": "full", "row_id": jsonUInt64(row.rowId), "content_hash": Int(row.contentHash), "text": row.text]
        }
    }

    var result: [String: Any] = [
        "type": type,
        "window_id": Int(delta.windowId),
        "content_epoch": Int(delta.contentEpoch),
        "cursor_visible": delta.cursorVisible,
        "cursor_row": Int(delta.cursorRow),
        "cursor_col": Int(delta.cursorCol),
        "scroll_left": Int(delta.scrollLeft),
        "rows": delta.rows.map(entryJSON)
    ]
    if let splices = delta.rowSplices, let base = delta.baseRowCount, let final = delta.resultRowCount {
        result["base_row_count"] = Int(base)
        result["result_row_count"] = Int(final)
        result["row_splices"] = splices.map { splice in
            ["start_index": Int(splice.startIndex),
             "delete_count": Int(splice.deleteCount),
             "insert_entries": splice.insertEntries.map(entryJSON)] as [String: Any]
        }
    }
    return result
}

func commandToJSON(_ command: RenderCommand) -> [String: Any]? {
    switch command {
    case .guiTheme(let slots):
        let slotArray = slots.map { ["slot": Int($0.slotId), "r": Int($0.r), "g": Int($0.g), "b": Int($0.b)] }
        return ["type": "gui_theme", "slots": slotArray]

    case .guiTabBar(let activeIndex, let tabs):
        let tabArray = tabs.map { tab -> [String: Any] in
            ["id": Int(tab.id), "label": tab.label, "icon": tab.icon,
             "is_active": tab.isActive, "is_dirty": tab.isDirty,
             "is_agent": tab.isAgent, "has_attention": tab.hasAttention,
             "agent_status": Int(tab.agentStatus)]
        }
        // The bidirectional protocol test explicitly opts in to this synthetic action.
        // Ordinary decode tests must leave no input event for a later response to consume.
        if emitSelectTab && tabs.count >= 2 {
            let secondTabId = tabs[1].id
            sendSelectTab(id: secondTabId)
        }
        return ["type": "gui_tab_bar", "active_index": Int(activeIndex), "tabs": tabArray]

    case .guiFileTree(let version, let treeFlags, let treeState, let selectedId, let treeWidth, let rootPath, let errorReason, let entries):
        let entryArray = entries.map { e -> [String: Any] in
            ["id": e.id, "path": e.path, "name": e.name, "relative_path": e.relPath, "depth": Int(e.depth),
             "is_dir": e.isDir, "is_expanded": e.isExpanded, "is_selected": e.isSelected, "is_focused": e.isFocused,
             "is_active": e.isActive, "is_dirty": e.isDirty, "is_editing": e.isEditing,
             "git_status": Int(e.gitStatus), "icon": e.icon]
        }
        return ["type": "gui_file_tree", "version": Int(version), "tree_flags": Int(treeFlags), "tree_state": Int(treeState), "selected_id": selectedId, "tree_width": Int(treeWidth), "root_path": rootPath, "error_reason": errorReason, "entries": entryArray]

    case .guiCompletion(let visible, let anchorRow, let anchorCol, let selectedIndex, let items, let documentation):
        let itemArray = items.map { i -> [String: Any] in
            ["label": i.label, "detail": i.detail, "kind": Int(i.kind)]
        }
        return ["type": "gui_completion", "visible": visible, "anchor_row": Int(anchorRow), "anchor_col": Int(anchorCol), "selected_index": Int(selectedIndex), "items": itemArray, "documentation": documentation]

    case .guiWhichKey(let visible, let prefix, let page, let pageCount, let bindings):
        let bindingArray = bindings.map { b -> [String: Any] in
            ["key": b.key, "description": b.description, "icon": b.icon, "kind": Int(b.kind)]
        }
        return ["type": "gui_which_key", "visible": visible, "prefix": prefix, "page": Int(page), "page_count": Int(pageCount), "bindings": bindingArray]

    case .guiBreadcrumb(let segments):
        return ["type": "gui_breadcrumb", "segments": segments]

    case .guiStatusBar(let update):
        var result: [String: Any] = [:]
        result["type"] = "gui_status_bar"
        result["content_kind"] = Int(update.contentKind)
        result["mode"] = Int(update.mode)
        result["cursor_line"] = Int(update.cursorLine)
        result["cursor_col"] = Int(update.cursorCol)
        result["line_count"] = Int(update.lineCount)
        result["flags"] = Int(update.flags)
        result["safe_mode"] = update.safeMode
        result["lsp_status"] = Int(update.lspStatus)
        result["git_branch"] = update.gitBranch
        result["message"] = update.message
        result["filetype"] = update.filetype
        result["error_count"] = Int(update.errorCount)
        result["warning_count"] = Int(update.warningCount)
        result["model_name"] = update.modelName
        result["message_count"] = Int(update.messageCount)
        result["session_status"] = Int(update.sessionStatus)
        result["info_count"] = Int(update.infoCount)
        result["hint_count"] = Int(update.hintCount)
        result["macro_recording"] = Int(update.macroRecording)
        result["parser_status"] = Int(update.parserStatus)
        result["agent_status"] = Int(update.agentStatus)
        result["active_tool_name"] = update.activeToolName
        result["git_added"] = Int(update.gitAdded)
        result["git_modified"] = Int(update.gitModified)
        result["git_deleted"] = Int(update.gitDeleted)
        result["icon"] = update.icon
        result["icon_color_r"] = Int(update.iconColorR)
        result["icon_color_g"] = Int(update.iconColorG)
        result["icon_color_b"] = Int(update.iconColorB)
        result["filename"] = update.filename
        result["diagnostic_hint"] = update.diagnosticHint
        result["background_subagent_count"] = Int(update.backgroundSubagentCount)
        result["background_subagent_label"] = update.backgroundSubagentLabel
        result["indent_type"] = Int(update.indent.kind)
        result["indent_size"] = Int(update.indent.size)
        result["modeline_left_segments"] = statusBarSegmentsToJSON(update.modelineLeftSegments)
        result["modeline_right_segments"] = statusBarSegmentsToJSON(update.modelineRightSegments)
        result["selection_mode"] = Int(update.selection.mode)
        result["selection_size"] = Int(update.selection.size)
        return result

    case .guiPicker(let visible, let selectedIndex, let filteredCount, let totalCount, let markedCount, let title, let query, let hasPreview, let items, let actionMenu, let modePrefix, let loadStatus, let queryGeneration, let acknowledgedQueryEditSeq):
        let itemArray = items.map { i -> [String: Any] in
            ["label": i.label, "description": i.description, "icon_color": Int(i.iconColor), "annotation": i.annotation, "flags": Int(i.flags), "match_positions": i.matchPositions.map { Int($0) }]
        }
        var result: [String: Any] = ["type": "gui_picker", "visible": visible, "selected_index": Int(selectedIndex), "filtered_count": Int(filteredCount), "total_count": Int(totalCount), "marked_count": Int(markedCount), "title": title, "query": query, "query_generation": Int(queryGeneration), "acknowledged_query_edit_seq": Int(acknowledgedQueryEditSeq), "mode_prefix": modePrefix, "has_preview": hasPreview, "items": itemArray]
        if let am = actionMenu {
            result["action_menu"] = ["selected_index": Int(am.selectedIndex), "actions": am.actions]
        }
        switch loadStatus {
        case .ready: result["load_status"] = "ready"
        case .loading: result["load_status"] = "loading"
        case .error(let msg): result["load_status"] = "error"; result["load_status_error"] = msg
        }
        return result

    case .guiPickerPreview(let visible, let lines):
        let lineArray = lines.map { segments -> [[String: Any]] in
            segments.map { seg in
                ["text": seg.text, "fg_color": Int(seg.fgColor), "bold": seg.bold]
            }
        }
        return ["type": "gui_picker_preview", "visible": visible, "lines": lineArray]

    case .guiAgentChat(let visible, let status, let model, let thinkingLevel, let prompt, let promptLineCount, let promptCursorLine, let promptCursorCol, let promptVimMode, let promptVisibleRows, let promptCompletion, let pendingToolName, let pendingToolSummary, let helpVisible, let helpGroups):
        let helpGroupArray = helpGroups.map { group -> [String: Any] in
            let bindings = group.bindings.map { ["key": $0.key, "description": $0.description] }
            return ["title": group.title, "bindings": bindings]
        }
        var result: [String: Any] = [
            "type": "gui_agent_chat",
            "visible": visible,
            "status": Int(status),
            "model": model,
            "thinking_level": thinkingLevel,
            "prompt": prompt,
            "prompt_line_count": Int(promptLineCount),
            "prompt_cursor_line": Int(promptCursorLine),
            "prompt_cursor_col": Int(promptCursorCol),
            "prompt_vim_mode": Int(promptVimMode),
            "prompt_visible_rows": Int(promptVisibleRows),
            "has_completion": promptCompletion != nil,
            "pending_tool_name": pendingToolName ?? "",
            "pending_tool_summary": pendingToolSummary,
            "help_visible": helpVisible,
            "help_groups": helpGroupArray
        ]
        _ = result // suppress unused warning
        return result

    case .guiGutterSeparator(let col, let r, let g, let b):
        return ["type": "gui_gutter_separator", "col": Int(col), "r": Int(r), "g": Int(g), "b": Int(b)]

    case .guiCursorline(let row, let r, let g, let b):
        return ["type": "gui_cursorline", "row": Int(row), "r": Int(r), "g": Int(g), "b": Int(b)]

    case .guiBottomPanel(let visible, let activeTabIndex, let heightPercent, let filterPreset, let tabs, let entries):
        var tabList: [[String: Any]] = []
        for tab in tabs {
            tabList.append(["tab_type": Int(tab.tabType), "name": tab.name])
        }
        var entryList: [[String: Any]] = []
        for entry in entries {
            entryList.append(["id": Int(entry.id), "level": Int(entry.level), "subsystem": Int(entry.subsystem),
                              "timestamp_secs": Int(entry.timestampSecs), "file_path": entry.filePath, "text": entry.text])
        }
        return ["type": "gui_bottom_panel", "visible": visible, "active_tab_index": Int(activeTabIndex),
                "height_percent": Int(heightPercent), "filter_preset": Int(filterPreset),
                "tabs": tabList, "entries": entryList]

    case .beginFrame(let frameSeq, let baseFrameSeq, let generation):
        return ["type": "begin_frame", "frame_seq": Int(frameSeq), "base_frame_seq": Int(baseFrameSeq), "generation": Int(generation)]

    case .commitFrame(let frameSeq, let seq):
        return ["type": "commit_frame", "frame_seq": Int(frameSeq), "input_seq": Int(seq)]


    case .guiGutter(let data):
        let entries = data.entries.map { e -> [String: Any] in
            ["buf_line": Int(e.bufLine),
             "display_type": Int(e.displayType.rawValue),
             "sign_type": Int(e.signType.rawValue),
             "fold_end_line": e.foldEndLine.map { Int($0) } ?? NSNull()]
        }
        return ["type": "gui_gutter", "window_id": Int(data.windowId),
                "content_row": Int(data.contentRow), "content_col": Int(data.contentCol),
                "content_height": Int(data.contentHeight),
                "content_width": Int(data.contentWidth), "is_active": data.isActive,
                "cursor_line": Int(data.cursorLine),
                "line_number_style": Int(data.lineNumberStyle.rawValue),
                "line_number_width": Int(data.lineNumberWidth),
                "sign_col_width": Int(data.signColWidth),
                "entries": entries]

    case .guiWindowContent(let data):
        let decodedRows = data.rowStore.rows(in: 0..<data.rowStore.count).rows
        let rows: [[String: Any]] = decodedRows.map { row in
            visualRowJSON(row)
        }
        var result: [String: Any] = [
            "type": "gui_window_content", "window_id": Int(data.windowId),
            "full_refresh": data.fullRefresh,
            "cursor_row": Int(data.cursorRow), "cursor_col": Int(data.cursorCol),
            "cursor_shape": Int(data.cursorShape.rawValue),
            "rows": rows,
            "search_match_count": data.searchMatches.count,
            "diagnostic_count": data.diagnosticUnderlines.count
        ]
        if let sel = data.selection {
            result["selection"] = ["type": Int(sel.type.rawValue),
                                   "start_row": Int(sel.startRow), "start_col": Int(sel.startCol),
                                   "end_row": Int(sel.endRow), "end_col": Int(sel.endCol)]
        }
        return result

    case .guiWindowOverlayDelta(let delta):
        var result: [String: Any] = [
            "type": "gui_window_overlay_delta",
            "window_id": Int(delta.windowId),
            "content_epoch": Int(delta.contentEpoch),
            "cursor_visible": delta.cursorVisible,
            "cursor_row": Int(delta.cursorRow),
            "cursor_col": Int(delta.cursorCol),
            "cursor_shape": Int(delta.cursorShape.rawValue)
        ]
        if let cursorline = delta.cursorline {
            result["cursorline"] = ["row": Int(cursorline.row), "bg": Int(cursorline.bg)]
        }
        return result

    case .guiWindowViewportDelta(let delta):
        return windowRowsDeltaResult(type: "gui_window_viewport_delta", delta: delta)

    case .guiWindowRowsDelta(let delta):
        return windowRowsDeltaResult(type: "gui_window_rows_delta", delta: delta)

    case .guiMinibuffer(let visible, let mode, let cursorPos, let prompt,
                         let input, let context, let selectedIndex,
                         let totalCandidates, let candidates):
        var result: [String: Any] = [:]
        result["type"] = "gui_minibuffer"
        result["visible"] = visible
        result["mode"] = Int(mode)
        result["cursor_pos"] = Int(cursorPos)
        result["prompt"] = prompt
        result["input"] = input
        result["context"] = context
        result["selected_index"] = Int(selectedIndex)
        result["total_candidates"] = Int(totalCandidates)
        result["candidates"] = candidates.map { c in
            ["match_score": Int(c.matchScore), "label": c.label, "description": c.description] as [String: Any]
        }
        return result

    default:
        return nil
    }
}

func statusBarSegmentsToJSON(_ segments: [Wire.StatusBarSegment]) -> [[String: Any]] {
    return segments.map { segment in
        [
            "text": segment.text,
            "fg_color": Int(segment.fgColor),
            "bg_color": Int(segment.bgColor),
            "attrs": Int(segment.attrs),
            "command": segment.command
        ]
    }
}


// MARK: - Main loop

/// Send a ready signal so the BEAM knows we're alive.
func sendReady() {
    writeJSON(["type": "ready"])
}

func makeDecodeBenchmarkPacket(size: Int) -> Data {
    // set_title is a real rendering command and forces construction of the
    // immutable String values published in DecodedFrame. Chunking at u16.max
    // keeps the packet protocol-compatible while exercising owned-copy metrics.
    var packet = Data(capacity: size)
    var remaining = size
    while remaining > 65_538 {
        let commandSize = remaining - 65_538 == 1 ? 65_537 : 65_538
        let textSize = commandSize - 3
        packet.append(OP_SET_TITLE)
        packet.append(UInt8((textSize >> 8) & 0xFF))
        packet.append(UInt8(textSize & 0xFF))
        packet.append(Data(repeating: 0x61, count: textSize))
        remaining -= commandSize
    }
    if remaining == 2 {
        packet.append(contentsOf: [OP_SET_CURSOR_SHAPE, CURSOR_BLOCK])
    } else if remaining >= 3 {
        let textSize = remaining - 3
        packet.append(OP_SET_TITLE)
        packet.append(UInt8((textSize >> 8) & 0xFF))
        packet.append(UInt8(textSize & 0xFF))
        packet.append(Data(repeating: 0x61, count: textSize))
    }
    return packet
}

func decodeBenchmarkNanoseconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1_000_000_000 + Double(components.attoseconds) / 1_000_000_000
}

func runDecodeBenchmark() throws {
    let sizes = [64 * 1024, 1024 * 1024, 16 * 1024 * 1024, 64 * 1024 * 1024]
    var measurements: [[String: Any]] = []
    var baselineNanoseconds = 0.0

    // Keep one-time Swift/Foundation initialization out of the linear baseline.
    _ = try decodeFrame(from: makeDecodeBenchmarkPacket(size: sizes[0]))

    for size in sizes {
        let decodedFrame = try decodeFrame(from: makeDecodeBenchmarkPacket(size: size), collectOwnedMetrics: true)
        let handoff = ProtocolEventHandoff()
        let frame = handoff.deliver(decodedFrame)
        let nanoseconds = decodeBenchmarkNanoseconds(frame.metrics.decodeDuration)
        if baselineNanoseconds == 0 { baselineNanoseconds = max(nanoseconds, 1_000) }
        let linearBudget = max(1_000_000, baselineNanoseconds * Double(size / sizes[0]) * 4)
        let expectedOwnedBytes = size - frame.commands.count * 3
        let expectedOwnedAllocations = frame.commands.count + 1
        guard frame.metrics.bytesCopied == expectedOwnedBytes,
              frame.metrics.allocations == expectedOwnedAllocations,
              frame.metrics.actorHopCount == 1,
              nanoseconds <= linearBudget else {
            throw ProtocolDecodeError.malformed
        }
        measurements.append(["packet_bytes": size, "bytes_copied": frame.metrics.bytesCopied, "allocations": frame.metrics.allocations, "decode_nanoseconds": nanoseconds, "actor_hop_count": frame.metrics.actorHopCount, "linear_budget_nanoseconds": linearBudget])
    }

    let output = try JSONSerialization.data(withJSONObject: ["configuration": "release", "measurements": measurements], options: [.sortedKeys])
    stdout.write(output)
    stdout.write(Data([0x0A]))
}

if CommandLine.arguments.contains("--decode-benchmark") {
    do {
        try runDecodeBenchmark()
        exit(EXIT_SUCCESS)
    } catch {
        FileHandle.standardError.write(Data("decode benchmark failed: \(error)\n".utf8))
        exit(EXIT_FAILURE)
    }
}

sendReady()

// Read {:packet, 4} framed messages from stdin.
while true {
    // Read 4-byte length header.
    let headerData = stdin.readData(ofLength: 4)
    if headerData.count < 4 {
        break // stdin closed
    }

    let len = Int(headerData[0]) << 24
        | Int(headerData[1]) << 16
        | Int(headerData[2]) << 8
        | Int(headerData[3])

    if len == 0 { continue }

    // Read the payload.
    var payload = Data()
    while payload.count < len {
        let chunk = stdin.readData(ofLength: len - payload.count)
        if chunk.isEmpty { break }
        payload.append(chunk)
    }

    if payload.count < len { break }

    // Decode and report.
    do {
        try decodeCommands(from: payload) { command in
            if let json = commandToJSON(command) {
                writeJSON(json)
            }
        }
    } catch {
        writeJSON(["type": "error", "message": "\(error)"])
    }
}
