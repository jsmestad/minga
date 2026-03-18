/// Decodes binary render commands from the BEAM into Swift enums.
///
/// Each command starts with a 1-byte opcode followed by opcode-specific
/// fields. Multi-byte integers are big-endian. See `docs/PROTOCOL.md`.

import Foundation

// MARK: - Render command types

/// A decoded render command from the BEAM.
enum RenderCommand: Sendable {
    case clear
    case batchEnd
    case drawText(row: UInt16, col: UInt16, fg: UInt32, bg: UInt32, attrs: UInt8, text: String)
    case drawStyledText(row: UInt16, col: UInt16, fg: UInt32, bg: UInt32, attrs: UInt16, underlineColor: UInt32, blend: UInt8, text: String)
    case setCursor(row: UInt16, col: UInt16)
    case setCursorShape(CursorShape)
    case setTitle(String)
    case setWindowBg(r: UInt8, g: UInt8, b: UInt8)
    case defineRegion(id: UInt16, parentId: UInt16, role: UInt8, row: UInt16, col: UInt16, width: UInt16, height: UInt16, zOrder: UInt8)
    case clearRegion(id: UInt16)
    case destroyRegion(id: UInt16)
    case setActiveRegion(id: UInt16)
    case setFont(family: String, size: UInt16, ligatures: Bool, weight: UInt8)
    case guiTheme(slots: [(slotId: UInt8, r: UInt8, g: UInt8, b: UInt8)])
    case guiTabBar(activeIndex: UInt8, tabs: [GUITabEntry])
    case guiFileTree(selectedIndex: UInt16, treeWidth: UInt16, entries: [GUIFileTreeEntry])
    case guiCompletion(visible: Bool, anchorRow: UInt16, anchorCol: UInt16, selectedIndex: UInt16, items: [GUICompletionItem])
    case guiWhichKey(visible: Bool, prefix: String, page: UInt8, pageCount: UInt8, bindings: [GUIWhichKeyBinding])
    case guiBreadcrumb(segments: [String])
    case guiStatusBar(mode: UInt8, cursorLine: UInt32, cursorCol: UInt32, lineCount: UInt32, flags: UInt8, lspStatus: UInt8, gitBranch: String, message: String, filetype: String, errorCount: UInt16, warningCount: UInt16)
    case guiPicker(visible: Bool, selectedIndex: UInt16, title: String, query: String, items: [GUIPickerItem])
    case guiAgentChat(visible: Bool, status: UInt8, model: String, prompt: String, pendingToolName: String?, pendingToolSummary: String, messages: [GUIChatMessage])
    case guiGutterSeparator(col: UInt16, r: UInt8, g: UInt8, b: UInt8)
}

/// A styled text run for GUI rendering. Carries pre-computed colors from the BEAM.
struct StyledTextRun: Sendable {
    let text: String
    let fgR: UInt8
    let fgG: UInt8
    let fgB: UInt8
    let bgR: UInt8
    let bgG: UInt8
    let bgB: UInt8
    let bold: Bool
    let italic: Bool
    let underline: Bool
}

/// A chat message from gui_agent_chat.
enum GUIChatMessage: Sendable {
    case user(text: String)
    case assistant(text: String)
    /// Assistant message with pre-styled text runs from tree-sitter.
    case styledAssistant(lines: [[StyledTextRun]])
    case thinking(text: String, collapsed: Bool)
    case toolCall(name: String, status: UInt8, isError: Bool, collapsed: Bool, durationMs: UInt32, result: String)
    case system(text: String, isError: Bool)
    case usage(input: UInt32, output: UInt32, cacheRead: UInt32, cacheWrite: UInt32, costMicros: UInt32)
}

/// A picker item from gui_picker.
struct GUIPickerItem: Sendable {
    let iconColor: UInt32  // 24-bit RGB
    let label: String
    let description: String
}

/// A completion item from gui_completion.
struct GUICompletionItem: Sendable {
    let kind: UInt8
    let label: String
    let detail: String
}

/// A which-key binding from gui_which_key.
struct GUIWhichKeyBinding: Sendable {
    let kind: UInt8  // 0 = command, 1 = group
    let key: String
    let description: String
    let icon: String
}

/// A single file tree entry decoded from the gui_file_tree protocol message.
struct GUIFileTreeEntry: Sendable {
    let isDir: Bool
    let isExpanded: Bool
    let isSelected: Bool
    let depth: UInt8
    let gitStatus: UInt8
    let icon: String
    let name: String
}

/// A single tab entry decoded from the gui_tab_bar protocol message.
struct GUITabEntry: Sendable {
    let id: UInt32
    let isActive: Bool
    let isDirty: Bool
    let isAgent: Bool
    let hasAttention: Bool
    let agentStatus: UInt8
    let icon: String
    let label: String
}

/// Cursor shape matching the protocol constants.
enum CursorShape: UInt8, Sendable {
    case block = 0x00
    case beam = 0x01
    case underline = 0x02
}

// MARK: - Decoder

enum ProtocolDecodeError: Error {
    case malformed
    case unknownOpcode(UInt8)
    case insufficientData
}

/// Decodes all commands from a single `{:packet, 4}` payload.
///
/// A payload may contain multiple concatenated commands (the BEAM batches
/// an entire frame into one message). This function iterates through the
/// payload, decoding each command and calling the handler.
func decodeCommands(from data: Data, handler: (RenderCommand) -> Void) throws {
    var offset = 0
    while offset < data.count {
        let (command, size) = try decodeCommand(data: data, offset: offset)
        if let command {
            handler(command)
        }
        offset += size
    }
}

/// Decodes a single command at the given offset.
/// Returns the decoded command (nil for ignored opcodes) and the number of bytes consumed.
func decodeCommand(data: Data, offset: Int) throws -> (RenderCommand?, Int) {
    guard offset < data.count else {
        throw ProtocolDecodeError.insufficientData
    }

    let opcode = data[offset]
    let rest = offset + 1

    switch opcode {
    case OP_CLEAR:
        return (.clear, 1)

    case OP_BATCH_END:
        return (.batchEnd, 1)

    case OP_DRAW_TEXT:
        // row:2, col:2, fg:3, bg:3, attrs:1, text_len:2 = 13 bytes after opcode
        guard data.count >= rest + 13 else { throw ProtocolDecodeError.malformed }
        let row = readU16(data, rest)
        let col = readU16(data, rest + 2)
        let fg = readU24(data, rest + 4)
        let bg = readU24(data, rest + 7)
        let attrs = data[rest + 10]
        let textLen = Int(readU16(data, rest + 11))
        guard data.count >= rest + 13 + textLen else { throw ProtocolDecodeError.malformed }
        let textData = data[(rest + 13)..<(rest + 13 + textLen)]
        let text = String(data: textData, encoding: .utf8) ?? ""
        return (.drawText(row: row, col: col, fg: fg, bg: bg, attrs: attrs, text: text), 1 + 13 + textLen)

    case OP_DRAW_STYLED_TEXT:
        // row:2, col:2, fg:3, bg:3, attrs:2(16-bit), ul_color:3, blend:1, text_len:2 = 18 bytes after opcode
        guard data.count >= rest + 18 else { throw ProtocolDecodeError.malformed }
        let row = readU16(data, rest)
        let col = readU16(data, rest + 2)
        let fg = readU24(data, rest + 4)
        let bg = readU24(data, rest + 7)
        let attrs16 = UInt16(data[rest + 10]) << 8 | UInt16(data[rest + 11])
        let ulColor = readU24(data, rest + 12)
        let blend = data[rest + 15]
        let textLen = Int(readU16(data, rest + 16))
        guard data.count >= rest + 18 + textLen else { throw ProtocolDecodeError.malformed }
        let textData = data[(rest + 18)..<(rest + 18 + textLen)]
        let text = String(data: textData, encoding: .utf8) ?? ""
        return (.drawStyledText(row: row, col: col, fg: fg, bg: bg, attrs: attrs16, underlineColor: ulColor, blend: blend, text: text), 1 + 18 + textLen)

    case OP_SET_CURSOR:
        guard data.count >= rest + 4 else { throw ProtocolDecodeError.malformed }
        let row = readU16(data, rest)
        let col = readU16(data, rest + 2)
        return (.setCursor(row: row, col: col), 5)

    case OP_SET_CURSOR_SHAPE:
        guard data.count >= rest + 1 else { throw ProtocolDecodeError.malformed }
        let shape = CursorShape(rawValue: data[rest]) ?? .block
        return (.setCursorShape(shape), 2)

    case OP_SET_TITLE:
        guard data.count >= rest + 2 else { throw ProtocolDecodeError.malformed }
        let titleLen = Int(readU16(data, rest))
        guard data.count >= rest + 2 + titleLen else { throw ProtocolDecodeError.malformed }
        let titleData = data[(rest + 2)..<(rest + 2 + titleLen)]
        let title = String(data: titleData, encoding: .utf8) ?? ""
        return (.setTitle(title), 1 + 2 + titleLen)

    case OP_SET_WINDOW_BG:
        guard data.count >= rest + 3 else { throw ProtocolDecodeError.malformed }
        return (.setWindowBg(r: data[rest], g: data[rest + 1], b: data[rest + 2]), 4)

    case OP_DEFINE_REGION:
        // id:2, parent_id:2, role:1, row:2, col:2, width:2, height:2, z_order:1 = 14
        guard data.count >= rest + 14 else { throw ProtocolDecodeError.malformed }
        let id = readU16(data, rest)
        let parentId = readU16(data, rest + 2)
        let role = data[rest + 4]
        let row = readU16(data, rest + 5)
        let col = readU16(data, rest + 7)
        let width = readU16(data, rest + 9)
        let height = readU16(data, rest + 11)
        let zOrder = data[rest + 13]
        return (.defineRegion(id: id, parentId: parentId, role: role, row: row, col: col, width: width, height: height, zOrder: zOrder), 15)

    case OP_CLEAR_REGION:
        guard data.count >= rest + 2 else { throw ProtocolDecodeError.malformed }
        return (.clearRegion(id: readU16(data, rest)), 3)

    case OP_DESTROY_REGION:
        guard data.count >= rest + 2 else { throw ProtocolDecodeError.malformed }
        return (.destroyRegion(id: readU16(data, rest)), 3)

    case OP_SET_ACTIVE_REGION:
        guard data.count >= rest + 2 else { throw ProtocolDecodeError.malformed }
        return (.setActiveRegion(id: readU16(data, rest)), 3)

    // Config commands.
    case OP_SET_FONT:
        // size:2, weight:1, ligatures:1, name_len:2 = 6 bytes after opcode
        guard data.count >= rest + 6 else { throw ProtocolDecodeError.malformed }
        let fontSize = readU16(data, rest)
        let weight = data[rest + 2]
        let ligatures = data[rest + 3] != 0
        let nameLen = Int(readU16(data, rest + 4))
        guard data.count >= rest + 6 + nameLen else { throw ProtocolDecodeError.malformed }
        let nameData = data[(rest + 6)..<(rest + 6 + nameLen)]
        let family = String(data: nameData, encoding: .utf8) ?? "Menlo"
        return (.setFont(family: family, size: fontSize, ligatures: ligatures, weight: weight), 1 + 6 + nameLen)

    // Highlight and parser opcodes: skip them (variable length).
    case OP_SET_LANGUAGE:
        guard data.count >= rest + 2 else { throw ProtocolDecodeError.malformed }
        let nameLen = Int(readU16(data, rest))
        return (nil, 1 + 2 + nameLen)

    case OP_PARSE_BUFFER:
        guard data.count >= rest + 8 else { throw ProtocolDecodeError.malformed }
        let sourceLen = Int(readU32(data, rest + 4))
        return (nil, 1 + 8 + sourceLen)

    case OP_SET_HIGHLIGHT_QUERY, OP_SET_INJECTION_QUERY:
        guard data.count >= rest + 4 else { throw ProtocolDecodeError.malformed }
        let queryLen = Int(readU32(data, rest))
        return (nil, 1 + 4 + queryLen)

    case OP_LOAD_GRAMMAR:
        guard data.count >= rest + 2 else { throw ProtocolDecodeError.malformed }
        let nameLen = Int(readU16(data, rest))
        guard data.count >= rest + 2 + nameLen + 2 else { throw ProtocolDecodeError.malformed }
        let pathLen = Int(readU16(data, rest + 2 + nameLen))
        return (nil, 1 + 2 + nameLen + 2 + pathLen)

    case OP_QUERY_LANGUAGE_AT:
        return (nil, 9) // opcode + request_id:4 + byte_offset:4

    case OP_EDIT_BUFFER:
        // Variable length; we need to skip the whole thing.
        // version:4, edit_count:2, then each edit is variable.
        // For safety, skip based on remaining payload (the BEAM batches one command per edit_buffer).
        guard data.count >= rest + 6 else { throw ProtocolDecodeError.malformed }
        let editCount = Int(readU16(data, rest + 4))
        var pos = rest + 6
        for _ in 0..<editCount {
            guard data.count >= pos + 12 else { throw ProtocolDecodeError.malformed }
            let textLen = Int(readU32(data, pos + 8))
            pos += 12 + textLen
        }
        return (nil, pos - offset)

    case OP_MEASURE_TEXT:
        guard data.count >= rest + 6 else { throw ProtocolDecodeError.malformed }
        let textLen = Int(readU16(data, rest + 4))
        return (nil, 1 + 6 + textLen)

    // GUI chrome commands.
    case OP_GUI_FILE_TREE:
        // selected_index:2, tree_width:2, entry_count:2, then per entry:
        // flags:1, depth:1, git_status:1, icon_len:1, icon, name_len:2, name
        guard data.count >= rest + 6 else { throw ProtocolDecodeError.malformed }
        let selectedIndex = readU16(data, rest)
        let treeWidth = readU16(data, rest + 2)
        let entryCount = Int(readU16(data, rest + 4))
        var entries: [GUIFileTreeEntry] = []
        entries.reserveCapacity(entryCount)
        var pos = rest + 6
        for _ in 0..<entryCount {
            guard data.count >= pos + 4 else { throw ProtocolDecodeError.malformed }
            let flags = data[pos]
            let depth = data[pos + 1]
            let gitStatus = data[pos + 2]
            let iconLen = Int(data[pos + 3])
            guard data.count >= pos + 4 + iconLen + 2 else { throw ProtocolDecodeError.malformed }
            let iconData = data[(pos + 4)..<(pos + 4 + iconLen)]
            let icon = String(data: iconData, encoding: .utf8) ?? ""
            let nameLen = Int(readU16(data, pos + 4 + iconLen))
            guard data.count >= pos + 6 + iconLen + nameLen else { throw ProtocolDecodeError.malformed }
            let nameData = data[(pos + 6 + iconLen)..<(pos + 6 + iconLen + nameLen)]
            let name = String(data: nameData, encoding: .utf8) ?? ""
            entries.append(GUIFileTreeEntry(
                isDir: flags & 0x01 != 0,
                isExpanded: flags & 0x02 != 0,
                isSelected: flags & 0x04 != 0,
                depth: depth,
                gitStatus: gitStatus,
                icon: icon,
                name: name
            ))
            pos += 6 + iconLen + nameLen
        }
        return (.guiFileTree(selectedIndex: selectedIndex, treeWidth: treeWidth, entries: entries), pos - offset)

    case OP_GUI_TAB_BAR:
        // active_index:1, tab_count:1, then per tab: flags:1, id:4, icon_len:1, icon, label_len:2, label
        guard data.count >= rest + 2 else { throw ProtocolDecodeError.malformed }
        let activeIndex = data[rest]
        let tabCount = Int(data[rest + 1])
        var tabs: [GUITabEntry] = []
        tabs.reserveCapacity(tabCount)
        var pos = rest + 2
        for _ in 0..<tabCount {
            guard data.count >= pos + 6 else { throw ProtocolDecodeError.malformed }
            let flags = data[pos]
            let tabId = readU32(data, pos + 1)
            let iconLen = Int(data[pos + 5])
            guard data.count >= pos + 6 + iconLen + 2 else { throw ProtocolDecodeError.malformed }
            let iconData = data[(pos + 6)..<(pos + 6 + iconLen)]
            let icon = String(data: iconData, encoding: .utf8) ?? ""
            let labelLen = Int(readU16(data, pos + 6 + iconLen))
            guard data.count >= pos + 6 + iconLen + 2 + labelLen else { throw ProtocolDecodeError.malformed }
            let labelData = data[(pos + 8 + iconLen)..<(pos + 8 + iconLen + labelLen)]
            let label = String(data: labelData, encoding: .utf8) ?? ""
            tabs.append(GUITabEntry(
                id: tabId,
                isActive: flags & 0x01 != 0,
                isDirty: flags & 0x02 != 0,
                isAgent: flags & 0x04 != 0,
                hasAttention: flags & 0x08 != 0,
                agentStatus: (flags >> 4) & 0x0F,
                icon: icon,
                label: label
            ))
            pos += 8 + iconLen + labelLen
        }
        return (.guiTabBar(activeIndex: activeIndex, tabs: tabs), pos - offset)

    case OP_GUI_THEME:
        // count:1, then count × (slot_id:1, r:1, g:1, b:1)
        guard data.count >= rest + 1 else { throw ProtocolDecodeError.malformed }
        let count = Int(data[rest])
        guard data.count >= rest + 1 + count * 4 else { throw ProtocolDecodeError.malformed }
        var slots: [(slotId: UInt8, r: UInt8, g: UInt8, b: UInt8)] = []
        slots.reserveCapacity(count)
        for i in 0..<count {
            let base = rest + 1 + i * 4
            slots.append((data[base], data[base + 1], data[base + 2], data[base + 3]))
        }
        return (.guiTheme(slots: slots), 1 + 1 + count * 4)

    case OP_GUI_COMPLETION:
        guard data.count >= rest + 1 else { throw ProtocolDecodeError.malformed }
        let visible = data[rest] != 0
        if !visible {
            return (.guiCompletion(visible: false, anchorRow: 0, anchorCol: 0, selectedIndex: 0, items: []), 2)
        }
        guard data.count >= rest + 9 else { throw ProtocolDecodeError.malformed }
        let anchorRow = readU16(data, rest + 1)
        let anchorCol = readU16(data, rest + 3)
        let selectedIndex = readU16(data, rest + 5)
        let itemCount = Int(readU16(data, rest + 7))
        var items: [GUICompletionItem] = []
        items.reserveCapacity(itemCount)
        var pos = rest + 9
        for _ in 0..<itemCount {
            guard data.count >= pos + 5 else { throw ProtocolDecodeError.malformed }
            let kind = data[pos]
            let labelLen = Int(readU16(data, pos + 1))
            guard data.count >= pos + 3 + labelLen + 2 else { throw ProtocolDecodeError.malformed }
            let label = String(data: data[(pos + 3)..<(pos + 3 + labelLen)], encoding: .utf8) ?? ""
            let detailLen = Int(readU16(data, pos + 3 + labelLen))
            guard data.count >= pos + 5 + labelLen + detailLen else { throw ProtocolDecodeError.malformed }
            let detail = String(data: data[(pos + 5 + labelLen)..<(pos + 5 + labelLen + detailLen)], encoding: .utf8) ?? ""
            items.append(GUICompletionItem(kind: kind, label: label, detail: detail))
            pos += 5 + labelLen + detailLen
        }
        return (.guiCompletion(visible: true, anchorRow: anchorRow, anchorCol: anchorCol, selectedIndex: selectedIndex, items: items), pos - offset)

    case OP_GUI_WHICH_KEY:
        guard data.count >= rest + 1 else { throw ProtocolDecodeError.malformed }
        let visible = data[rest] != 0
        if !visible {
            return (.guiWhichKey(visible: false, prefix: "", page: 0, pageCount: 0, bindings: []), 2)
        }
        guard data.count >= rest + 3 else { throw ProtocolDecodeError.malformed }
        let prefixLen = Int(readU16(data, rest + 1))
        guard data.count >= rest + 3 + prefixLen + 4 else { throw ProtocolDecodeError.malformed }
        let prefix = String(data: data[(rest + 3)..<(rest + 3 + prefixLen)], encoding: .utf8) ?? ""
        let page = data[rest + 3 + prefixLen]
        let pageCount = data[rest + 4 + prefixLen]
        let bindingCount = Int(readU16(data, rest + 5 + prefixLen))
        var bindings: [GUIWhichKeyBinding] = []
        bindings.reserveCapacity(bindingCount)
        var pos = rest + 7 + prefixLen
        for _ in 0..<bindingCount {
            guard data.count >= pos + 2 else { throw ProtocolDecodeError.malformed }
            let bKind = data[pos]
            let keyLen = Int(data[pos + 1])
            guard data.count >= pos + 2 + keyLen + 2 else { throw ProtocolDecodeError.malformed }
            let key = String(data: data[(pos + 2)..<(pos + 2 + keyLen)], encoding: .utf8) ?? ""
            let descLen = Int(readU16(data, pos + 2 + keyLen))
            guard data.count >= pos + 4 + keyLen + descLen + 1 else { throw ProtocolDecodeError.malformed }
            let desc = String(data: data[(pos + 4 + keyLen)..<(pos + 4 + keyLen + descLen)], encoding: .utf8) ?? ""
            let iconLen = Int(data[pos + 4 + keyLen + descLen])
            guard data.count >= pos + 5 + keyLen + descLen + iconLen else { throw ProtocolDecodeError.malformed }
            let icon = String(data: data[(pos + 5 + keyLen + descLen)..<(pos + 5 + keyLen + descLen + iconLen)], encoding: .utf8) ?? ""
            bindings.append(GUIWhichKeyBinding(kind: bKind, key: key, description: desc, icon: icon))
            pos += 5 + keyLen + descLen + iconLen
        }
        return (.guiWhichKey(visible: true, prefix: prefix, page: page, pageCount: pageCount, bindings: bindings), pos - offset)

    case OP_GUI_BREADCRUMB:
        guard data.count >= rest + 1 else { throw ProtocolDecodeError.malformed }
        let segCount = Int(data[rest])
        var segments: [String] = []
        segments.reserveCapacity(segCount)
        var pos = rest + 1
        for _ in 0..<segCount {
            guard data.count >= pos + 2 else { throw ProtocolDecodeError.malformed }
            let segLen = Int(readU16(data, pos))
            guard data.count >= pos + 2 + segLen else { throw ProtocolDecodeError.malformed }
            let seg = String(data: data[(pos + 2)..<(pos + 2 + segLen)], encoding: .utf8) ?? ""
            segments.append(seg)
            pos += 2 + segLen
        }
        return (.guiBreadcrumb(segments: segments), pos - offset)

    case OP_GUI_STATUS_BAR:
        // mode:1 cursor_line:4 cursor_col:4 line_count:4 flags:1 lsp:1 git_len:1 git message_len:2 message filetype_len:1 filetype
        guard data.count >= rest + 16 else { throw ProtocolDecodeError.malformed }
        let mode = data[rest]
        let cursorLine = readU32(data, rest + 1)
        let cursorCol = readU32(data, rest + 5)
        let lineCount = readU32(data, rest + 9)
        let flags = data[rest + 13]
        let lspStatus = data[rest + 14]
        let gitLen = Int(data[rest + 15])
        guard data.count >= rest + 16 + gitLen + 2 else { throw ProtocolDecodeError.malformed }
        let gitBranch = String(data: data[(rest + 16)..<(rest + 16 + gitLen)], encoding: .utf8) ?? ""
        let msgLen = Int(readU16(data, rest + 16 + gitLen))
        guard data.count >= rest + 18 + gitLen + msgLen + 1 else { throw ProtocolDecodeError.malformed }
        let message = String(data: data[(rest + 18 + gitLen)..<(rest + 18 + gitLen + msgLen)], encoding: .utf8) ?? ""
        let ftLen = Int(data[rest + 18 + gitLen + msgLen])
        guard data.count >= rest + 19 + gitLen + msgLen + ftLen else { throw ProtocolDecodeError.malformed }
        let filetype = String(data: data[(rest + 19 + gitLen + msgLen)..<(rest + 19 + gitLen + msgLen + ftLen)], encoding: .utf8) ?? ""
        let diagBase = rest + 19 + gitLen + msgLen + ftLen
        let errorCount: UInt16 = data.count >= diagBase + 4 ? readU16(data, diagBase) : 0
        let warningCount: UInt16 = data.count >= diagBase + 4 ? readU16(data, diagBase + 2) : 0
        let totalConsumed = data.count >= diagBase + 4 ? diagBase + 4 : diagBase
        return (.guiStatusBar(mode: mode, cursorLine: cursorLine, cursorCol: cursorCol, lineCount: lineCount, flags: flags, lspStatus: lspStatus, gitBranch: gitBranch, message: message, filetype: filetype, errorCount: errorCount, warningCount: warningCount), totalConsumed - offset)

    case OP_GUI_PICKER:
        guard data.count >= rest + 1 else { throw ProtocolDecodeError.malformed }
        let visible = data[rest] != 0
        if !visible {
            return (.guiPicker(visible: false, selectedIndex: 0, title: "", query: "", items: []), 2)
        }
        guard data.count >= rest + 3 else { throw ProtocolDecodeError.malformed }
        let selectedIndex = readU16(data, rest + 1)
        let titleLen = Int(readU16(data, rest + 3))
        guard data.count >= rest + 5 + titleLen + 2 else { throw ProtocolDecodeError.malformed }
        let title = String(data: data[(rest + 5)..<(rest + 5 + titleLen)], encoding: .utf8) ?? ""
        let queryLen = Int(readU16(data, rest + 5 + titleLen))
        guard data.count >= rest + 7 + titleLen + queryLen + 2 else { throw ProtocolDecodeError.malformed }
        let query = String(data: data[(rest + 7 + titleLen)..<(rest + 7 + titleLen + queryLen)], encoding: .utf8) ?? ""
        let itemCount = Int(readU16(data, rest + 7 + titleLen + queryLen))
        var items: [GUIPickerItem] = []
        items.reserveCapacity(itemCount)
        var pos = rest + 9 + titleLen + queryLen
        for _ in 0..<itemCount {
            guard data.count >= pos + 7 else { throw ProtocolDecodeError.malformed }
            let iconColor = readU24(data, pos)
            let labelLen = Int(readU16(data, pos + 3))
            guard data.count >= pos + 5 + labelLen + 2 else { throw ProtocolDecodeError.malformed }
            let label = String(data: data[(pos + 5)..<(pos + 5 + labelLen)], encoding: .utf8) ?? ""
            let descLen = Int(readU16(data, pos + 5 + labelLen))
            guard data.count >= pos + 7 + labelLen + descLen else { throw ProtocolDecodeError.malformed }
            let desc = String(data: data[(pos + 7 + labelLen)..<(pos + 7 + labelLen + descLen)], encoding: .utf8) ?? ""
            items.append(GUIPickerItem(iconColor: UInt32(iconColor), label: label, description: desc))
            pos += 7 + labelLen + descLen
        }
        return (.guiPicker(visible: true, selectedIndex: selectedIndex, title: title, query: query, items: items), pos - offset)

    case OP_GUI_AGENT_CHAT:
        guard data.count >= rest + 1 else { throw ProtocolDecodeError.malformed }
        let visible = data[rest] != 0
        if !visible {
            return (.guiAgentChat(visible: false, status: 0, model: "", prompt: "", pendingToolName: nil, pendingToolSummary: "", messages: []), 2)
        }
        guard data.count >= rest + 4 else { throw ProtocolDecodeError.malformed }
        let status = data[rest + 1]
        let modelLen = Int(readU16(data, rest + 2))
        guard data.count >= rest + 4 + modelLen + 2 else { throw ProtocolDecodeError.malformed }
        let model = String(data: data[(rest + 4)..<(rest + 4 + modelLen)], encoding: .utf8) ?? ""
        let promptLen = Int(readU16(data, rest + 4 + modelLen))
        guard data.count >= rest + 6 + modelLen + promptLen + 2 else { throw ProtocolDecodeError.malformed }
        let prompt = String(data: data[(rest + 6 + modelLen)..<(rest + 6 + modelLen + promptLen)], encoding: .utf8) ?? ""
        // Parse pending_approval: 0 = none, 1 = has approval
        var pendingPos = rest + 6 + modelLen + promptLen
        guard data.count >= pendingPos + 1 else { throw ProtocolDecodeError.malformed }
        let hasPending = data[pendingPos] != 0
        pendingPos += 1
        var pendingToolName: String? = nil
        var pendingToolSummary: String = ""
        if hasPending {
            guard data.count >= pendingPos + 2 else { throw ProtocolDecodeError.malformed }
            let pNameLen = Int(readU16(data, pendingPos))
            guard data.count >= pendingPos + 2 + pNameLen + 2 else { throw ProtocolDecodeError.malformed }
            pendingToolName = String(data: data[(pendingPos + 2)..<(pendingPos + 2 + pNameLen)], encoding: .utf8) ?? ""
            let pSummaryLen = Int(readU16(data, pendingPos + 2 + pNameLen))
            guard data.count >= pendingPos + 4 + pNameLen + pSummaryLen else { throw ProtocolDecodeError.malformed }
            pendingToolSummary = String(data: data[(pendingPos + 4 + pNameLen)..<(pendingPos + 4 + pNameLen + pSummaryLen)], encoding: .utf8) ?? ""
            pendingPos += 4 + pNameLen + pSummaryLen
        }
        guard data.count >= pendingPos + 2 else { throw ProtocolDecodeError.malformed }
        let msgCount = Int(readU16(data, pendingPos))
        var messages: [GUIChatMessage] = []
        messages.reserveCapacity(msgCount)
        var pos = pendingPos + 2
        for _ in 0..<msgCount {
            guard data.count >= pos + 1 else { throw ProtocolDecodeError.malformed }
            let msgType = data[pos]
            switch msgType {
            case 0x01: // user
                guard data.count >= pos + 5 else { throw ProtocolDecodeError.malformed }
                let tLen = Int(readU32(data, pos + 1))
                guard data.count >= pos + 5 + tLen else { throw ProtocolDecodeError.malformed }
                let t = String(data: data[(pos + 5)..<(pos + 5 + tLen)], encoding: .utf8) ?? ""
                messages.append(.user(text: t))
                pos += 5 + tLen
            case 0x02: // assistant
                guard data.count >= pos + 5 else { throw ProtocolDecodeError.malformed }
                let tLen = Int(readU32(data, pos + 1))
                guard data.count >= pos + 5 + tLen else { throw ProtocolDecodeError.malformed }
                let t = String(data: data[(pos + 5)..<(pos + 5 + tLen)], encoding: .utf8) ?? ""
                messages.append(.assistant(text: t))
                pos += 5 + tLen
            case 0x03: // thinking
                guard data.count >= pos + 6 else { throw ProtocolDecodeError.malformed }
                let collapsed = data[pos + 1] != 0
                let tLen = Int(readU32(data, pos + 2))
                guard data.count >= pos + 6 + tLen else { throw ProtocolDecodeError.malformed }
                let t = String(data: data[(pos + 6)..<(pos + 6 + tLen)], encoding: .utf8) ?? ""
                messages.append(.thinking(text: t, collapsed: collapsed))
                pos += 6 + tLen
            case 0x04: // tool_call
                guard data.count >= pos + 10 else { throw ProtocolDecodeError.malformed }
                let tcStatus = data[pos + 1]
                let isError = data[pos + 2] != 0
                let tcCollapsed = data[pos + 3] != 0
                let duration = readU32(data, pos + 4)
                let nameLen = Int(readU16(data, pos + 8))
                guard data.count >= pos + 10 + nameLen + 4 else { throw ProtocolDecodeError.malformed }
                let name = String(data: data[(pos + 10)..<(pos + 10 + nameLen)], encoding: .utf8) ?? ""
                let resultLen = Int(readU32(data, pos + 10 + nameLen))
                guard data.count >= pos + 14 + nameLen + resultLen else { throw ProtocolDecodeError.malformed }
                let result = String(data: data[(pos + 14 + nameLen)..<(pos + 14 + nameLen + resultLen)], encoding: .utf8) ?? ""
                messages.append(.toolCall(name: name, status: tcStatus, isError: isError, collapsed: tcCollapsed, durationMs: duration, result: result))
                pos += 14 + nameLen + resultLen
            case 0x05: // system
                guard data.count >= pos + 6 else { throw ProtocolDecodeError.malformed }
                let isError = data[pos + 1] != 0
                let tLen = Int(readU32(data, pos + 2))
                guard data.count >= pos + 6 + tLen else { throw ProtocolDecodeError.malformed }
                let t = String(data: data[(pos + 6)..<(pos + 6 + tLen)], encoding: .utf8) ?? ""
                messages.append(.system(text: t, isError: isError))
                pos += 6 + tLen
            case 0x06: // usage
                guard data.count >= pos + 21 else { throw ProtocolDecodeError.malformed }
                let inp = readU32(data, pos + 1)
                let outp = readU32(data, pos + 5)
                let cacheR = readU32(data, pos + 9)
                let cacheW = readU32(data, pos + 13)
                let costM = readU32(data, pos + 17)
                messages.append(.usage(input: inp, output: outp, cacheRead: cacheR, cacheWrite: cacheW, costMicros: costM))
                pos += 21
            case 0x07: // styled_assistant
                // Format: 0x07, line_count::16, then per line:
                //   run_count::16, then per run: text_len::16, text, fg::24, bg::24, flags::8
                guard data.count >= pos + 3 else { throw ProtocolDecodeError.malformed }
                let lineCount = Int(readU16(data, pos + 1))
                var lines: [[StyledTextRun]] = []
                lines.reserveCapacity(lineCount)
                var rPos = pos + 3
                for _ in 0..<lineCount {
                    guard data.count >= rPos + 2 else { throw ProtocolDecodeError.malformed }
                    let runCount = Int(readU16(data, rPos))
                    var runs: [StyledTextRun] = []
                    runs.reserveCapacity(runCount)
                    rPos += 2
                    for _ in 0..<runCount {
                        guard data.count >= rPos + 9 else { throw ProtocolDecodeError.malformed }
                        let textLen = Int(readU16(data, rPos))
                        guard data.count >= rPos + 2 + textLen + 7 else { throw ProtocolDecodeError.malformed }
                        let runText = String(data: data[(rPos + 2)..<(rPos + 2 + textLen)], encoding: .utf8) ?? ""
                        let fgOff = rPos + 2 + textLen
                        let fgR = data[fgOff]
                        let fgG = data[fgOff + 1]
                        let fgB = data[fgOff + 2]
                        let bgR = data[fgOff + 3]
                        let bgG = data[fgOff + 4]
                        let bgB = data[fgOff + 5]
                        let flags = data[fgOff + 6]
                        runs.append(StyledTextRun(
                            text: runText,
                            fgR: fgR, fgG: fgG, fgB: fgB,
                            bgR: bgR, bgG: bgG, bgB: bgB,
                            bold: (flags & 0x01) != 0,
                            italic: (flags & 0x02) != 0,
                            underline: (flags & 0x04) != 0
                        ))
                        rPos = fgOff + 7
                    }
                    lines.append(runs)
                }
                messages.append(.styledAssistant(lines: lines))
                pos = rPos
            default:
                break
            }
        }
        return (.guiAgentChat(visible: true, status: status, model: model, prompt: prompt, pendingToolName: pendingToolName, pendingToolSummary: pendingToolSummary, messages: messages), pos - offset)

    case OP_GUI_GUTTER_SEP:
        // col:2, r:1, g:1, b:1 = 5 bytes after opcode
        guard data.count >= rest + 5 else { throw ProtocolDecodeError.malformed }
        let col = readU16(data, rest)
        return (.guiGutterSeparator(col: col, r: data[rest + 2], g: data[rest + 3], b: data[rest + 4]), 6)

    default:
        throw ProtocolDecodeError.unknownOpcode(opcode)
    }
}

// MARK: - Binary helpers

private func readU16(_ data: Data, _ offset: Int) -> UInt16 {
    return UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
}

private func readU24(_ data: Data, _ offset: Int) -> UInt32 {
    return UInt32(data[offset]) << 16 | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2])
}

private func readU32(_ data: Data, _ offset: Int) -> UInt32 {
    return UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 |
           UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
}
