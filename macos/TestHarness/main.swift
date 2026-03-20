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
        // If there are 2+ tabs, auto-send a select_tab gui_action for the
        // second tab. This enables round-trip testing: BEAM sends gui_tab_bar,
        // harness decodes it and sends gui_action select_tab back.
        if tabs.count >= 2 {
            let secondTabId = tabs[1].id
            sendSelectTab(id: secondTabId)
        }
        return ["type": "gui_tab_bar", "active_index": Int(activeIndex), "tabs": tabArray]

    case .guiFileTree(let selectedIndex, let treeWidth, let rootPath, let entries):
        let entryArray = entries.map { e -> [String: Any] in
            ["name": e.name, "depth": Int(e.depth),
             "is_dir": e.isDir, "is_expanded": e.isExpanded, "is_selected": e.isSelected,
             "git_status": Int(e.gitStatus), "icon": e.icon]
        }
        return ["type": "gui_file_tree", "selected_index": Int(selectedIndex), "tree_width": Int(treeWidth), "root_path": rootPath, "entries": entryArray]

    case .guiCompletion(let visible, let anchorRow, let anchorCol, let selectedIndex, let items):
        let itemArray = items.map { i -> [String: Any] in
            ["label": i.label, "detail": i.detail, "kind": Int(i.kind)]
        }
        return ["type": "gui_completion", "visible": visible, "anchor_row": Int(anchorRow), "anchor_col": Int(anchorCol), "selected_index": Int(selectedIndex), "items": itemArray]

    case .guiWhichKey(let visible, let prefix, let page, let pageCount, let bindings):
        let bindingArray = bindings.map { b -> [String: Any] in
            ["key": b.key, "description": b.description, "icon": b.icon, "kind": Int(b.kind)]
        }
        return ["type": "gui_which_key", "visible": visible, "prefix": prefix, "page": Int(page), "page_count": Int(pageCount), "bindings": bindingArray]

    case .guiBreadcrumb(let segments):
        return ["type": "gui_breadcrumb", "segments": segments]

    case .guiStatusBar(let contentKind, let mode, let cursorLine, let cursorCol, let lineCount, let flags, let lspStatus, let gitBranch, let message, let filetype, let errorCount, let warningCount, let modelName, let messageCount, let sessionStatus):
        return ["type": "gui_status_bar", "content_kind": Int(contentKind), "mode": Int(mode), "cursor_line": Int(cursorLine), "cursor_col": Int(cursorCol), "line_count": Int(lineCount), "flags": Int(flags), "lsp_status": Int(lspStatus), "git_branch": gitBranch, "message": message, "filetype": filetype, "error_count": Int(errorCount), "warning_count": Int(warningCount), "model_name": modelName, "message_count": Int(messageCount), "session_status": Int(sessionStatus)]

    case .guiPicker(let visible, let selectedIndex, let filteredCount, let totalCount, let title, let query, let hasPreview, let items, let actionMenu):
        let itemArray = items.map { i -> [String: Any] in
            ["label": i.label, "description": i.description, "icon_color": Int(i.iconColor), "annotation": i.annotation, "flags": Int(i.flags), "match_positions": i.matchPositions.map { Int($0) }]
        }
        var result: [String: Any] = ["type": "gui_picker", "visible": visible, "selected_index": Int(selectedIndex), "filtered_count": Int(filteredCount), "total_count": Int(totalCount), "title": title, "query": query, "has_preview": hasPreview, "items": itemArray]
        if let am = actionMenu {
            result["action_menu"] = ["selected_index": Int(am.selectedIndex), "actions": am.actions]
        }
        return result

    case .guiPickerPreview(let visible, let lines):
        let lineArray = lines.map { segments -> [[String: Any]] in
            segments.map { seg in
                ["text": seg.text, "fg_color": Int(seg.fgColor), "bold": seg.bold]
            }
        }
        return ["type": "gui_picker_preview", "visible": visible, "lines": lineArray]

    case .guiAgentChat(let visible, let status, let model, let prompt, let pendingToolName, let pendingToolSummary, let messages):
        let msgArray = messages.map { chatMessageToJSON($0) }
        return ["type": "gui_agent_chat", "visible": visible, "status": Int(status), "model": model, "prompt": prompt, "pending_tool_name": pendingToolName ?? "", "pending_tool_summary": pendingToolSummary, "messages": msgArray]

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

    case .batchEnd:
        return ["type": "batch_end"]

    case .clear:
        return ["type": "clear"]

    case .guiToolManager(let visible, let filter, let selectedIndex, let tools):
        let toolArray = tools.map { t -> [String: Any] in
            ["name": t.name, "label": t.label, "description": t.description,
             "category": Int(t.category), "status": Int(t.status), "method": Int(t.method),
             "languages": t.languages, "version": t.version, "homepage": t.homepage,
             "provides": t.provides]
        }
        return ["type": "gui_tool_manager", "visible": visible, "filter": Int(filter),
                "selected_index": Int(selectedIndex), "tools": toolArray]

    case .guiGutter(let data):
        let entries = data.entries.map { e -> [String: Any] in
            ["buf_line": Int(e.bufLine),
             "display_type": Int(e.displayType.rawValue),
             "sign_type": Int(e.signType.rawValue)]
        }
        return ["type": "gui_gutter", "window_id": Int(data.windowId),
                "content_row": Int(data.contentRow), "content_col": Int(data.contentCol),
                "content_height": Int(data.contentHeight), "is_active": data.isActive,
                "cursor_line": Int(data.cursorLine),
                "line_number_style": Int(data.lineNumberStyle.rawValue),
                "line_number_width": Int(data.lineNumberWidth),
                "sign_col_width": Int(data.signColWidth),
                "entries": entries]

    case .guiWindowContent(let data):
        let rows = data.rows.map { row -> [String: Any] in
            let spans = row.spans.map { s -> [String: Any] in
                ["start_col": Int(s.startCol), "end_col": Int(s.endCol),
                 "fg": Int(s.fg), "bg": Int(s.bg), "attrs": Int(s.attrs),
                 "font_weight": Int(s.fontWeight), "font_id": Int(s.fontId)]
            }
            return ["row_type": Int(row.rowType.rawValue), "buf_line": Int(row.bufLine),
                    "content_hash": Int(row.contentHash), "text": row.text, "spans": spans]
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

    default:
        return nil
    }
}

func chatMessageToJSON(_ msg: GUIChatMessage) -> [String: Any] {
    switch msg {
    case .user(let text):
        return ["kind": "user", "text": text]
    case .assistant(let text):
        return ["kind": "assistant", "text": text]
    case .styledAssistant(let lines):
        let linesJSON: [[Any]] = lines.map { runs in
            runs.map { run -> [String: Any] in
                return [
                    "text": run.text,
                    "fg": [Int(run.fgR), Int(run.fgG), Int(run.fgB)],
                    "bg": [Int(run.bgR), Int(run.bgG), Int(run.bgB)],
                    "bold": run.bold,
                    "italic": run.italic,
                    "underline": run.underline
                ]
            }
        }
        return ["kind": "styled_assistant", "lines": linesJSON]
    case .thinking(let text, let collapsed):
        return ["kind": "thinking", "text": text, "collapsed": collapsed]
    case .toolCall(let name, let status, let isError, let collapsed, let durationMs, let result):
        return ["kind": "tool_call", "name": name, "status": Int(status), "is_error": isError, "collapsed": collapsed, "duration_ms": Int(durationMs), "result": result]
    case .system(let text, let isError):
        return ["kind": "system", "text": text, "is_error": isError]
    case .usage(let input, let output, let cacheRead, let cacheWrite, let costMicros):
        return ["kind": "usage", "input": Int(input), "output": Int(output), "cache_read": Int(cacheRead), "cache_write": Int(cacheWrite), "cost_micros": Int(costMicros)]
    }
}

// MARK: - Main loop

/// Send a ready signal so the BEAM knows we're alive.
func sendReady() {
    writeJSON(["type": "ready"])
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
