/// Decodes binary render commands from the BEAM into Swift enums.
///
/// Each command starts with a 1-byte opcode followed by opcode-specific
/// fields. Multi-byte integers are big-endian. See `docs/PROTOCOL.md`.
///
/// Data types live in `ProtocolTypes.swift` under the `Wire` namespace.
/// This file contains only the `RenderCommand` enum, decode functions,
/// and private helpers.

import Foundation

// MARK: - Render command types

/// A decoded render command from the BEAM.
enum RenderCommand: Sendable {
    case clear
    case batchEnd
    /// Legacy cell-grid text commands. Decoded but discarded by CommandDispatcher.
    /// Kept in the enum so the decoder can skip the bytes without crashing.
    case drawText(row: UInt16, col: UInt16, fg: UInt32, bg: UInt32, attrs: UInt8, text: String)
    case drawStyledText(row: UInt16, col: UInt16, fg: UInt32, bg: UInt32, attrs: UInt16, underlineColor: UInt32, blend: UInt8, fontWeight: UInt8, fontId: UInt8, text: String)
    case setCursor(row: UInt16, col: UInt16)
    case setCursorShape(CursorShape)
    case setTitle(String)
    case setWindowBg(r: UInt8, g: UInt8, b: UInt8)
    case defineRegion(id: UInt16, parentId: UInt16, role: UInt8, row: UInt16, col: UInt16, width: UInt16, height: UInt16, zOrder: UInt8)
    case clearRegion(id: UInt16)
    case destroyRegion(id: UInt16)
    case setActiveRegion(id: UInt16)
    case setFont(family: String, size: UInt16, ligatures: Bool, weight: UInt8)
    case setFontFallback(families: [String])
    case registerFont(id: UInt8, family: String)
    case guiTheme(slots: [(slotId: UInt8, r: UInt8, g: UInt8, b: UInt8)])
    case guiTabBar(activeIndex: UInt8, tabs: [Wire.TabEntry])
    case guiFileTree(selectedIndex: UInt16, treeWidth: UInt16, rootPath: String, entries: [Wire.FileTreeEntry])
    case guiCompletion(visible: Bool, anchorRow: UInt16, anchorCol: UInt16, selectedIndex: UInt16, items: [Wire.CompletionItem])
    case guiWhichKey(visible: Bool, prefix: String, page: UInt8, pageCount: UInt8, bindings: [Wire.WhichKeyBinding])
    case guiBreadcrumb(segments: [String])
    case guiStatusBar(contentKind: UInt8, mode: UInt8, cursorLine: UInt32, cursorCol: UInt32, lineCount: UInt32, flags: UInt8, lspStatus: UInt8, gitBranch: String, message: String, filetype: String, errorCount: UInt16, warningCount: UInt16, modelName: String, messageCount: UInt32, sessionStatus: UInt8, infoCount: UInt16, hintCount: UInt16, macroRecording: UInt8, parserStatus: UInt8, agentStatus: UInt8, gitAdded: UInt16, gitModified: UInt16, gitDeleted: UInt16, icon: String, iconColorR: UInt8, iconColorG: UInt8, iconColorB: UInt8, filename: String, diagnosticHint: String)
    case guiPicker(visible: Bool, selectedIndex: UInt16, filteredCount: UInt16, totalCount: UInt16, title: String, query: String, hasPreview: Bool, items: [Wire.PickerItem], actionMenu: Wire.PickerActionMenu?)
    case guiPickerPreview(visible: Bool, lines: [Wire.PickerPreviewLine])
    case guiAgentChat(visible: Bool, status: UInt8, model: String, prompt: String, promptLineCount: UInt8, promptCursorLine: UInt16, promptCursorCol: UInt16, promptVimMode: UInt8, promptVisibleRows: UInt8, promptCompletion: Wire.PromptCompletion?, pendingToolName: String?, pendingToolSummary: String, helpVisible: Bool, helpGroups: [Wire.HelpGroup], messages: [Wire.ChatMessage])
    case guiGutterSeparator(col: UInt16, r: UInt8, g: UInt8, b: UInt8)
    case guiCursorline(row: UInt16, r: UInt8, g: UInt8, b: UInt8)
    case guiGutter(data: Wire.WindowGutter)
    case guiBottomPanel(visible: Bool, activeTabIndex: UInt8, heightPercent: UInt8,
                         filterPreset: UInt8, tabs: [Wire.BottomPanelTab],
                         entries: [Wire.MessageEntry])
    case guiWindowContent(data: GUIWindowContent)
    case guiToolManager(visible: Bool, filter: UInt8, selectedIndex: UInt16, tools: [Wire.ToolEntry])
    case guiMinibuffer(visible: Bool, mode: UInt8, cursorPos: UInt16, prompt: String, input: String, context: String, selectedIndex: UInt16, totalCandidates: UInt16, candidates: [Wire.MinibufferCandidate])
    case guiHoverPopup(visible: Bool, anchorRow: UInt16, anchorCol: UInt16, focused: Bool, scrollOffset: UInt16, lines: [Wire.HoverLine])
    case guiSignatureHelp(visible: Bool, anchorRow: UInt16, anchorCol: UInt16, activeSignature: UInt8, activeParameter: UInt8, signatures: [Wire.Signature])
    case guiFloatPopup(visible: Bool, width: UInt16, height: UInt16, title: String, lines: [String])
    case clipboardWrite(target: UInt8, text: String)
    case guiSplitSeparators(borderColor: UInt32, verticals: [Wire.VerticalSeparator], horizontals: [Wire.HorizontalSeparator])
    case guiGitStatus(repoState: UInt8, ahead: UInt16, behind: UInt16, branchName: String, entries: [Wire.GitStatusEntry])
    case guiAgentGroups(activeGroupId: UInt16, agentGroups: [Wire.AgentGroupEntry])
    case guiBoard(visible: Bool, focusedCardId: UInt32, cards: [BoardCard], filterMode: Bool, filterText: String)
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
        // row:2, col:2, fg:3, bg:3, attrs:2(16-bit), ul_color:3, blend:1, font_weight:1, font_id:1, text_len:2 = 20 bytes after opcode
        guard data.count >= rest + 20 else { throw ProtocolDecodeError.malformed }
        let row = readU16(data, rest)
        let col = readU16(data, rest + 2)
        let fg = readU24(data, rest + 4)
        let bg = readU24(data, rest + 7)
        let attrs16 = UInt16(data[rest + 10]) << 8 | UInt16(data[rest + 11])
        let ulColor = readU24(data, rest + 12)
        let blend = data[rest + 15]
        let fontWeight = data[rest + 16]
        let fontId = data[rest + 17]
        let textLen = Int(readU16(data, rest + 18))
        guard data.count >= rest + 20 + textLen else { throw ProtocolDecodeError.malformed }
        let textData = data[(rest + 20)..<(rest + 20 + textLen)]
        let text = String(data: textData, encoding: .utf8) ?? ""
        return (.drawStyledText(row: row, col: col, fg: fg, bg: bg, attrs: attrs16, underlineColor: ulColor, blend: blend, fontWeight: fontWeight, fontId: fontId, text: text), 1 + 20 + textLen)

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

    case OP_SET_FONT_FALLBACK:
        // count:1, then count * (name_len:2, name:bytes)
        guard data.count >= rest + 1 else { throw ProtocolDecodeError.malformed }
        let count = Int(data[rest])
        var families: [String] = []
        var offset = rest + 1
        for _ in 0..<count {
            guard data.count >= offset + 2 else { throw ProtocolDecodeError.malformed }
            let nameLen = Int(readU16(data, offset))
            offset += 2
            guard data.count >= offset + nameLen else { throw ProtocolDecodeError.malformed }
            let nameData = data[offset..<(offset + nameLen)]
            let name = String(data: nameData, encoding: .utf8) ?? ""
            families.append(name)
            offset += nameLen
        }
        return (.setFontFallback(families: families), offset - rest + 1)

    case OP_REGISTER_FONT:
        // font_id:1, name_len:2, name:bytes
        guard data.count >= rest + 3 else { throw ProtocolDecodeError.malformed }
        let fontId = data[rest]
        let nameLen = Int(readU16(data, rest + 1))
        guard data.count >= rest + 3 + nameLen else { throw ProtocolDecodeError.malformed }
        let nameData = data[(rest + 3)..<(rest + 3 + nameLen)]
        let family = String(data: nameData, encoding: .utf8) ?? "Menlo"
        return (.registerFont(id: fontId, family: family), 1 + 3 + nameLen)

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
        // Header: selected_index:2, tree_width:2, entry_count:2, root_len:2, root
        // Per entry: path_hash:4, flags:1, depth:1, git_status:1, icon_len:1, icon,
        //            name_len:2, name, rel_path_len:2, rel_path
        guard data.count >= rest + 8 else { throw ProtocolDecodeError.malformed }
        let selectedIndex = readU16(data, rest)
        let treeWidth = readU16(data, rest + 2)
        let entryCount = Int(readU16(data, rest + 4))
        let rootLen = Int(readU16(data, rest + 6))
        guard data.count >= rest + 8 + rootLen else { throw ProtocolDecodeError.malformed }
        let rootData = data[(rest + 8)..<(rest + 8 + rootLen)]
        let rootPath = String(data: rootData, encoding: .utf8) ?? ""
        var entries: [Wire.FileTreeEntry] = []
        entries.reserveCapacity(entryCount)
        var pos = rest + 8 + rootLen
        for _ in 0..<entryCount {
            guard data.count >= pos + 8 else { throw ProtocolDecodeError.malformed }
            let pathHash = readU32(data, pos)
            let flags = data[pos + 4]
            let depth = data[pos + 5]
            let gitStatus = data[pos + 6]
            let iconLen = Int(data[pos + 7])
            guard data.count >= pos + 8 + iconLen + 2 else { throw ProtocolDecodeError.malformed }
            let iconData = data[(pos + 8)..<(pos + 8 + iconLen)]
            let icon = String(data: iconData, encoding: .utf8) ?? ""
            let nameLen = Int(readU16(data, pos + 8 + iconLen))
            guard data.count >= pos + 10 + iconLen + nameLen + 2 else { throw ProtocolDecodeError.malformed }
            let nameData = data[(pos + 10 + iconLen)..<(pos + 10 + iconLen + nameLen)]
            let name = String(data: nameData, encoding: .utf8) ?? ""
            let relPathLen = Int(readU16(data, pos + 10 + iconLen + nameLen))
            guard data.count >= pos + 12 + iconLen + nameLen + relPathLen else { throw ProtocolDecodeError.malformed }
            let relPathData = data[(pos + 12 + iconLen + nameLen)..<(pos + 12 + iconLen + nameLen + relPathLen)]
            let relPath = String(data: relPathData, encoding: .utf8) ?? ""
            entries.append(Wire.FileTreeEntry(
                pathHash: pathHash,
                isDir: flags & 0x01 != 0,
                isExpanded: flags & 0x02 != 0,
                isSelected: flags & 0x04 != 0,
                depth: depth,
                gitStatus: gitStatus,
                icon: icon,
                name: name,
                relPath: relPath
            ))
            pos += 12 + iconLen + nameLen + relPathLen
        }
        return (.guiFileTree(selectedIndex: selectedIndex, treeWidth: treeWidth, rootPath: rootPath, entries: entries), pos - offset)

    case OP_GUI_TAB_BAR:
        // active_index:1, tab_count:1, then per tab: flags:1, id:4, group_id:2, icon_len:1, icon, label_len:2, label
        guard data.count >= rest + 2 else { throw ProtocolDecodeError.malformed }
        let activeIndex = data[rest]
        let tabCount = Int(data[rest + 1])
        var tabs: [Wire.TabEntry] = []
        tabs.reserveCapacity(tabCount)
        var pos = rest + 2
        for _ in 0..<tabCount {
            guard data.count >= pos + 8 else { throw ProtocolDecodeError.malformed }
            let flags = data[pos]
            let tabId = readU32(data, pos + 1)
            let groupId = readU16(data, pos + 5)
            let iconLen = Int(data[pos + 7])
            guard data.count >= pos + 8 + iconLen + 2 else { throw ProtocolDecodeError.malformed }
            let iconData = data[(pos + 8)..<(pos + 8 + iconLen)]
            let icon = String(data: iconData, encoding: .utf8) ?? ""
            let labelLen = Int(readU16(data, pos + 8 + iconLen))
            guard data.count >= pos + 8 + iconLen + 2 + labelLen else { throw ProtocolDecodeError.malformed }
            let labelData = data[(pos + 10 + iconLen)..<(pos + 10 + iconLen + labelLen)]
            let label = String(data: labelData, encoding: .utf8) ?? ""
            tabs.append(Wire.TabEntry(
                id: tabId,
                groupId: groupId,
                isActive: flags & 0x01 != 0,
                isDirty: flags & 0x02 != 0,
                isAgent: flags & 0x04 != 0,
                hasAttention: flags & 0x08 != 0,
                agentStatus: (flags >> 4) & 0x0F,
                icon: icon,
                label: label
            ))
            pos += 10 + iconLen + labelLen
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
        var items: [Wire.CompletionItem] = []
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
            items.append(Wire.CompletionItem(kind: kind, label: label, detail: detail))
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
        var bindings: [Wire.WhichKeyBinding] = []
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
            bindings.append(Wire.WhichKeyBinding(kind: bKind, key: key, description: desc, icon: icon))
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

        for _ in 0..<sectionCount {
            guard data.count >= pos + 3 else { throw ProtocolDecodeError.malformed }
            let sectionId = data[pos]
            let sectionLen = Int(readU16(data, pos + 1))
            let sStart = pos + 3
            guard data.count >= sStart + sectionLen else { throw ProtocolDecodeError.malformed }

            switch sectionId {
            case 0x01: // Identity: content_kind(1) + mode(1) + flags(1)
                guard sectionLen >= 3 else { break }
                contentKind = data[sStart]
                mode = data[sStart + 1]
                flags = data[sStart + 2]

            case 0x02: // Cursor: cursor_line(4) + cursor_col(4) + line_count(4)
                guard sectionLen >= 12 else { break }
                cursorLine = readU32(data, sStart)
                cursorCol = readU32(data, sStart + 4)
                lineCount = readU32(data, sStart + 8)

            case 0x03: // Diagnostics: error(2) + warning(2) + info(2) + hint(2) + diag_hint_len(2) + diag_hint
                guard sectionLen >= 8 else { break }
                errorCount = readU16(data, sStart)
                warningCount = readU16(data, sStart + 2)
                infoCount = readU16(data, sStart + 4)
                hintCount = readU16(data, sStart + 6)
                if sectionLen >= 10 {
                    let dhLen = Int(readU16(data, sStart + 8))
                    if sectionLen >= 10 + dhLen, dhLen > 0 {
                        diagnosticHint = String(data: data[(sStart + 10)..<(sStart + 10 + dhLen)], encoding: .utf8) ?? ""
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
                gitBranch = String(data: data[(sStart + 1)..<(sStart + 1 + brLen)], encoding: .utf8) ?? ""
                gitAdded = readU16(data, sStart + 1 + brLen)
                gitModified = readU16(data, sStart + 3 + brLen)
                gitDeleted = readU16(data, sStart + 5 + brLen)

            case 0x06: // File: icon_len(1) + icon + r(1) + g(1) + b(1) + filename_len(2) + filename + filetype_len(1) + filetype
                guard sectionLen >= 1 else { break }
                let iLen = Int(data[sStart])
                guard sectionLen >= 1 + iLen + 3 + 2 else { break }
                icon = String(data: data[(sStart + 1)..<(sStart + 1 + iLen)], encoding: .utf8) ?? ""
                iconColorR = data[sStart + 1 + iLen]
                iconColorG = data[sStart + 2 + iLen]
                iconColorB = data[sStart + 3 + iLen]
                let fnLen = Int(readU16(data, sStart + 4 + iLen))
                guard sectionLen >= 6 + iLen + fnLen + 1 else { break }
                filename = String(data: data[(sStart + 6 + iLen)..<(sStart + 6 + iLen + fnLen)], encoding: .utf8) ?? ""
                let ftLen = Int(data[sStart + 6 + iLen + fnLen])
                guard sectionLen >= 7 + iLen + fnLen + ftLen else { break }
                filetype = String(data: data[(sStart + 7 + iLen + fnLen)..<(sStart + 7 + iLen + fnLen + ftLen)], encoding: .utf8) ?? ""

            case 0x07: // Message: msg_len(2) + msg
                guard sectionLen >= 2 else { break }
                let mLen = Int(readU16(data, sStart))
                if sectionLen >= 2 + mLen, mLen > 0 {
                    message = String(data: data[(sStart + 2)..<(sStart + 2 + mLen)], encoding: .utf8) ?? ""
                }

            case 0x08: // Recording: macro_recording(1)
                guard sectionLen >= 1 else { break }
                macroRecording = data[sStart]

            case 0x09: // Agent: varies by content_kind
                if sectionLen >= 1 {
                    // Buffer variant: just agent_status(1)
                    // Agent variant: model_name_len(1) + model_name + message_count(4) + session_status(1) + agent_status(1)
                    if sectionLen == 1 {
                        agentStatus = data[sStart]
                    } else {
                        let mnLen = Int(data[sStart])
                        guard sectionLen >= 1 + mnLen + 6 else { break }
                        modelName = String(data: data[(sStart + 1)..<(sStart + 1 + mnLen)], encoding: .utf8) ?? ""
                        messageCount = readU32(data, sStart + 1 + mnLen)
                        sessionStatus = data[sStart + 5 + mnLen]
                        agentStatus = data[sStart + 6 + mnLen]
                    }
                }

            default:
                break // Skip unknown sections (forward compatibility)
            }

            pos = sStart + sectionLen
        }

        return (.guiStatusBar(contentKind: contentKind, mode: mode, cursorLine: cursorLine, cursorCol: cursorCol, lineCount: lineCount, flags: flags, lspStatus: lspStatus, gitBranch: gitBranch, message: message, filetype: filetype, errorCount: errorCount, warningCount: warningCount, modelName: modelName, messageCount: messageCount, sessionStatus: sessionStatus, infoCount: infoCount, hintCount: hintCount, macroRecording: macroRecording, parserStatus: parserStatus, agentStatus: agentStatus, gitAdded: gitAdded, gitModified: gitModified, gitDeleted: gitDeleted, icon: icon, iconColorR: iconColorR, iconColorG: iconColorG, iconColorB: iconColorB, filename: filename, diagnosticHint: diagnosticHint), pos - offset)

    case OP_GUI_PICKER:
        // Sectioned format: opcode(1) + section_count(1) + sections...
        // Hidden picker: opcode(1) + 0(1) (zero sections, visible defaults to false)
        guard data.count >= rest + 1 else { throw ProtocolDecodeError.malformed }
        let pickerSectionCount = Int(data[rest])
        if pickerSectionCount == 0 {
            return (.guiPicker(visible: false, selectedIndex: 0, filteredCount: 0, totalCount: 0, title: "", query: "", hasPreview: false, items: [], actionMenu: nil), 2)
        }
        var pickerPos = rest + 1
        var pkVisible = false
        var pkSelectedIndex: UInt16 = 0
        var pkFilteredCount: UInt16 = 0
        var pkTotalCount: UInt16 = 0
        var pkHasPreview = false
        var pkTitle = ""
        var pkQuery = ""
        var pkItems: [Wire.PickerItem] = []
        var pkActionMenu: Wire.PickerActionMenu? = nil

        for _ in 0..<pickerSectionCount {
            guard data.count >= pickerPos + 3 else { throw ProtocolDecodeError.malformed }
            let psId = data[pickerPos]
            let psLen = Int(readU16(data, pickerPos + 1))
            let psStart = pickerPos + 3
            guard data.count >= psStart + psLen else { throw ProtocolDecodeError.malformed }

            switch psId {
            case 0x01: // Header: visible(1) + selected(2) + filtered(2) + total(2) + has_preview(1) + title_len(2) + title
                guard psLen >= 8 else { break }
                pkVisible = data[psStart] != 0
                pkSelectedIndex = readU16(data, psStart + 1)
                pkFilteredCount = readU16(data, psStart + 3)
                pkTotalCount = readU16(data, psStart + 5)
                pkHasPreview = data[psStart + 7] != 0
                if psLen >= 10 {
                    let tLen = Int(readU16(data, psStart + 8))
                    if psLen >= 10 + tLen {
                        pkTitle = String(data: data[(psStart + 10)..<(psStart + 10 + tLen)], encoding: .utf8) ?? ""
                    }
                }

            case 0x02: // Query: query_len(2) + query
                guard psLen >= 2 else { break }
                let qLen = Int(readU16(data, psStart))
                if psLen >= 2 + qLen {
                    pkQuery = String(data: data[(psStart + 2)..<(psStart + 2 + qLen)], encoding: .utf8) ?? ""
                }

            case 0x03: // Items: item_count(2) + items...
                guard psLen >= 2 else { break }
                let itemCount = Int(readU16(data, psStart))
                pkItems.reserveCapacity(itemCount)
                var iPos = psStart + 2
                let sectionEnd = psStart + psLen
                for _ in 0..<itemCount {
                    guard iPos + 6 <= sectionEnd else { break }
                    let iconColor = readU24(data, iPos)
                    let itemFlags = data[iPos + 3]
                    let labelLen = Int(readU16(data, iPos + 4))
                    iPos += 6
                    guard iPos + labelLen + 2 <= sectionEnd else { break }
                    let label = String(data: data[iPos..<(iPos + labelLen)], encoding: .utf8) ?? ""
                    iPos += labelLen
                    let descLen = Int(readU16(data, iPos)); iPos += 2
                    guard iPos + descLen + 2 <= sectionEnd else { break }
                    let desc = String(data: data[iPos..<(iPos + descLen)], encoding: .utf8) ?? ""
                    iPos += descLen
                    let annotLen = Int(readU16(data, iPos)); iPos += 2
                    guard iPos + annotLen + 1 <= sectionEnd else { break }
                    let annot = String(data: data[iPos..<(iPos + annotLen)], encoding: .utf8) ?? ""
                    iPos += annotLen
                    let mpc = Int(data[iPos]); iPos += 1
                    guard iPos + mpc * 2 <= sectionEnd else { break }
                    var matchPos: [UInt16] = []
                    for _ in 0..<mpc { matchPos.append(readU16(data, iPos)); iPos += 2 }
                    pkItems.append(Wire.PickerItem(iconColor: UInt32(iconColor), flags: itemFlags, label: label, description: desc, annotation: annot, matchPositions: matchPos))
                }

            case 0x04: // Action menu: visible(1), if visible: selected(1) + count(1) + actions
                guard psLen >= 1 else { break }
                let amVisible = data[psStart] != 0
                if amVisible, psLen >= 3 {
                    let amSelected = data[psStart + 1]
                    let amCount = Int(data[psStart + 2])
                    var amPos = psStart + 3
                    var amNames: [String] = []
                    for _ in 0..<amCount {
                        guard amPos + 2 <= psStart + psLen else { break }
                        let nLen = Int(readU16(data, amPos)); amPos += 2
                        guard amPos + nLen <= psStart + psLen else { break }
                        amNames.append(String(data: data[amPos..<(amPos + nLen)], encoding: .utf8) ?? "")
                        amPos += nLen
                    }
                    pkActionMenu = Wire.PickerActionMenu(selectedIndex: amSelected, actions: amNames)
                }

            default: break
            }

            pickerPos = psStart + psLen
        }

        return (.guiPicker(visible: pkVisible, selectedIndex: pkSelectedIndex, filteredCount: pkFilteredCount, totalCount: pkTotalCount, title: pkTitle, query: pkQuery, hasPreview: pkHasPreview, items: pkItems, actionMenu: pkActionMenu), pickerPos - offset)

    case OP_GUI_PICKER_PREVIEW:
        guard data.count >= rest + 1 else { throw ProtocolDecodeError.malformed }
        let visible = data[rest] != 0
        if !visible {
            return (.guiPickerPreview(visible: false, lines: []), 2)
        }
        guard data.count >= rest + 3 else { throw ProtocolDecodeError.malformed }
        let lineCount = Int(readU16(data, rest + 1))
        var lines: [Wire.PickerPreviewLine] = []
        lines.reserveCapacity(lineCount)
        var pos2 = rest + 3
        for _ in 0..<lineCount {
            guard data.count >= pos2 + 1 else { throw ProtocolDecodeError.malformed }
            let segCount = Int(data[pos2])
            pos2 += 1
            var segments: Wire.PickerPreviewLine = []
            segments.reserveCapacity(segCount)
            for _ in 0..<segCount {
                guard data.count >= pos2 + 6 else { throw ProtocolDecodeError.malformed }
                let fgColor = readU24(data, pos2)
                let segFlags = data[pos2 + 3]
                let textLen = Int(readU16(data, pos2 + 4))
                guard data.count >= pos2 + 6 + textLen else { throw ProtocolDecodeError.malformed }
                let text = String(data: data[(pos2 + 6)..<(pos2 + 6 + textLen)], encoding: .utf8) ?? ""
                segments.append(Wire.PickerPreviewSegment(fgColor: UInt32(fgColor), bold: segFlags & 0x01 != 0, text: text))
                pos2 += 6 + textLen
            }
            lines.append(segments)
        }
        return (.guiPickerPreview(visible: true, lines: lines), pos2 - offset)

    case OP_GUI_AGENT_CHAT:
        // Sectioned format: opcode(1) + section_count(1) + sections...
        // Hidden: opcode(1) + 0(1)
        guard data.count >= rest + 1 else { throw ProtocolDecodeError.malformed }
        let chatSectionCount = Int(data[rest])
        if chatSectionCount == 0 {
            return (.guiAgentChat(visible: false, status: 0, model: "", prompt: "", promptLineCount: 1, promptCursorLine: 0, promptCursorCol: 0, promptVimMode: 0, promptVisibleRows: 1, promptCompletion: nil, pendingToolName: nil, pendingToolSummary: "", helpVisible: false, helpGroups: [], messages: []), 2)
        }
        var chatPos = rest + 1
        var chatVisible = false
        var chatStatus: UInt8 = 0
        var chatModel = ""
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
            let csLen = Int(readU16(data, chatPos + 1))
            let csStart = chatPos + 3
            guard data.count >= csStart + csLen else { throw ProtocolDecodeError.malformed }

            switch csId {
            case 0x01: // Header: visible(1) + status(1)
                guard csLen >= 2 else { break }
                chatVisible = data[csStart] != 0
                chatStatus = data[csStart + 1]

            case 0x02: // Model: model_len(2) + model
                guard csLen >= 2 else { break }
                let mLen = Int(readU16(data, csStart))
                if csLen >= 2 + mLen { chatModel = String(data: data[(csStart + 2)..<(csStart + 2 + mLen)], encoding: .utf8) ?? "" }

            case 0x03: // Prompt: prompt_len(2) + prompt + line_count(1) + cursor_line(2) + cursor_col(2) + vim_mode(1) + visible_rows(1)
                guard csLen >= 2 else { break }
                let pLen = Int(readU16(data, csStart))
                if csLen >= 2 + pLen { chatPrompt = String(data: data[(csStart + 2)..<(csStart + 2 + pLen)], encoding: .utf8) ?? "" }
                let metaStart = csStart + 2 + pLen
                if csLen >= 2 + pLen + 7 {
                    promptLineCount = data[metaStart]
                    promptCursorLine = readU16(data, metaStart + 1)
                    promptCursorCol = readU16(data, metaStart + 3)
                    promptVimMode = data[metaStart + 5]
                    promptVisibleRows = data[metaStart + 6]
                }

            case 0x07: // Completion: visible(1) [type(1) selected(1) anchor_line(2) anchor_col(2) count(1) candidates...]
                guard csLen >= 1 else { break }
                let hasCompletion = data[csStart] != 0
                if hasCompletion, csLen >= 8 {
                    let compType = data[csStart + 1]
                    let compSelected = data[csStart + 2]
                    let compAnchorLine = readU16(data, csStart + 3)
                    let compAnchorCol = readU16(data, csStart + 5)
                    let compCount = Int(data[csStart + 7])
                    var candidates: [(name: String, description: String)] = []
                    var cp = csStart + 8
                    for _ in 0..<compCount {
                        guard cp + 2 <= csStart + csLen else { break }
                        let nLen = Int(readU16(data, cp)); cp += 2
                        guard cp + nLen + 2 <= csStart + csLen else { break }
                        let name = String(data: data[cp..<(cp + nLen)], encoding: .utf8) ?? ""; cp += nLen
                        let dLen = Int(readU16(data, cp)); cp += 2
                        guard cp + dLen <= csStart + csLen else { break }
                        let desc = String(data: data[cp..<(cp + dLen)], encoding: .utf8) ?? ""; cp += dLen
                        candidates.append((name: name, description: desc))
                    }
                    promptCompletion = Wire.PromptCompletion(type: compType, selected: compSelected, anchorLine: compAnchorLine, anchorCol: compAnchorCol, candidates: candidates)
                }

            case 0x04: // Pending: same format as before (has_pending(1) [name_len(2) name summary_len(2) summary])
                guard csLen >= 1 else { break }
                let hasPending = data[csStart] != 0
                if hasPending, csLen >= 3 {
                    var pp = csStart + 1
                    let pnLen = Int(readU16(data, pp)); pp += 2
                    guard pp + pnLen + 2 <= csStart + csLen else { break }
                    pendingToolName = String(data: data[pp..<(pp + pnLen)], encoding: .utf8) ?? ""
                    pp += pnLen
                    let psLen = Int(readU16(data, pp)); pp += 2
                    guard pp + psLen <= csStart + csLen else { break }
                    pendingToolSummary = String(data: data[pp..<(pp + psLen)], encoding: .utf8) ?? ""
                }

            case 0x05: // Help: same format as before (visible(1) [group_count(1) ...])
                guard csLen >= 1 else { break }
                helpVisible = data[csStart] != 0
                if helpVisible, csLen >= 2 {
                    let groupCount = Int(data[csStart + 1])
                    var hp = csStart + 2
                    for _ in 0..<groupCount {
                        guard hp + 2 <= csStart + csLen else { break }
                        let tLen = Int(readU16(data, hp)); hp += 2
                        guard hp + tLen + 1 <= csStart + csLen else { break }
                        let title = String(data: data[hp..<(hp + tLen)], encoding: .utf8) ?? ""
                        hp += tLen
                        let bCount = Int(data[hp]); hp += 1
                        var bindings: [(key: String, description: String)] = []
                        for _ in 0..<bCount {
                            guard hp + 1 <= csStart + csLen else { break }
                            let kLen = Int(data[hp]); hp += 1
                            guard hp + kLen + 2 <= csStart + csLen else { break }
                            let key = String(data: data[hp..<(hp + kLen)], encoding: .utf8) ?? ""
                            hp += kLen
                            let dLen = Int(readU16(data, hp)); hp += 2
                            guard hp + dLen <= csStart + csLen else { break }
                            let desc = String(data: data[hp..<(hp + dLen)], encoding: .utf8) ?? ""
                            hp += dLen
                            bindings.append((key: key, description: desc))
                        }
                        helpGroups.append(Wire.HelpGroup(title: title, bindings: bindings))
                    }
                }

            case 0x06: // Messages: msg_count(2) + messages... (same internal format as before)
                guard csLen >= 2 else { break }
                let msgCount = Int(readU16(data, csStart))
                messages.reserveCapacity(msgCount)
                var pos = csStart + 2
        for _ in 0..<msgCount {
            // Each message is prefixed with a stable uint32 ID from the BEAM
            guard data.count >= pos + 5 else { throw ProtocolDecodeError.malformed }
            let beamId = readU32(data, pos)
            pos += 4
            let msgType = data[pos]
            switch msgType {
            case 0x01: // user
                guard data.count >= pos + 5 else { throw ProtocolDecodeError.malformed }
                let tLen = Int(readU32(data, pos + 1))
                guard data.count >= pos + 5 + tLen else { throw ProtocolDecodeError.malformed }
                let t = String(data: data[(pos + 5)..<(pos + 5 + tLen)], encoding: .utf8) ?? ""
                messages.append(Wire.ChatMessage(beamId: beamId, content: .user(text: t)))
                pos += 5 + tLen
            case 0x02: // assistant
                guard data.count >= pos + 5 else { throw ProtocolDecodeError.malformed }
                let tLen = Int(readU32(data, pos + 1))
                guard data.count >= pos + 5 + tLen else { throw ProtocolDecodeError.malformed }
                let t = String(data: data[(pos + 5)..<(pos + 5 + tLen)], encoding: .utf8) ?? ""
                messages.append(Wire.ChatMessage(beamId: beamId, content: .assistant(text: t)))
                pos += 5 + tLen
            case 0x03: // thinking
                guard data.count >= pos + 6 else { throw ProtocolDecodeError.malformed }
                let collapsed = data[pos + 1] != 0
                let tLen = Int(readU32(data, pos + 2))
                guard data.count >= pos + 6 + tLen else { throw ProtocolDecodeError.malformed }
                let t = String(data: data[(pos + 6)..<(pos + 6 + tLen)], encoding: .utf8) ?? ""
                messages.append(Wire.ChatMessage(beamId: beamId, content: .thinking(text: t, collapsed: collapsed)))
                pos += 6 + tLen
            case 0x04: // tool_call
                guard data.count >= pos + 10 else { throw ProtocolDecodeError.malformed }
                let tcStatus = data[pos + 1]
                let isError = data[pos + 2] != 0
                let tcCollapsed = data[pos + 3] != 0
                let duration = readU32(data, pos + 4)
                let nameLen = Int(readU16(data, pos + 8))
                guard data.count >= pos + 10 + nameLen + 2 else { throw ProtocolDecodeError.malformed }
                let name = String(data: data[(pos + 10)..<(pos + 10 + nameLen)], encoding: .utf8) ?? ""
                let summaryLen = Int(readU16(data, pos + 10 + nameLen))
                guard data.count >= pos + 12 + nameLen + summaryLen + 4 else { throw ProtocolDecodeError.malformed }
                let summary = String(data: data[(pos + 12 + nameLen)..<(pos + 12 + nameLen + summaryLen)], encoding: .utf8) ?? ""
                let resultLen = Int(readU32(data, pos + 12 + nameLen + summaryLen))
                guard data.count >= pos + 16 + nameLen + summaryLen + resultLen else { throw ProtocolDecodeError.malformed }
                let result = String(data: data[(pos + 16 + nameLen + summaryLen)..<(pos + 16 + nameLen + summaryLen + resultLen)], encoding: .utf8) ?? ""
                messages.append(Wire.ChatMessage(beamId: beamId, content: .toolCall(name: name, summary: summary, status: tcStatus, isError: isError, collapsed: tcCollapsed, durationMs: duration, result: result)))
                pos += 16 + nameLen + summaryLen + resultLen
            case 0x05: // system
                guard data.count >= pos + 6 else { throw ProtocolDecodeError.malformed }
                let isError = data[pos + 1] != 0
                let tLen = Int(readU32(data, pos + 2))
                guard data.count >= pos + 6 + tLen else { throw ProtocolDecodeError.malformed }
                let t = String(data: data[(pos + 6)..<(pos + 6 + tLen)], encoding: .utf8) ?? ""
                messages.append(Wire.ChatMessage(beamId: beamId, content: .system(text: t, isError: isError)))
                pos += 6 + tLen
            case 0x06: // usage
                guard data.count >= pos + 21 else { throw ProtocolDecodeError.malformed }
                let inp = readU32(data, pos + 1)
                let outp = readU32(data, pos + 5)
                let cacheR = readU32(data, pos + 9)
                let cacheW = readU32(data, pos + 13)
                let costM = readU32(data, pos + 17)
                messages.append(Wire.ChatMessage(beamId: beamId, content: .usage(input: inp, output: outp, cacheRead: cacheR, cacheWrite: cacheW, costMicros: costM)))
                pos += 21
            case 0x07: // styled_assistant
                // Format: 0x07, line_count::16, then per line:
                //   run_count::16, then per run: text_len::16, text, fg::24, bg::24, flags::8
                guard data.count >= pos + 3 else { throw ProtocolDecodeError.malformed }
                let lineCount = Int(readU16(data, pos + 1))
                var lines: [[Wire.StyledTextRun]] = []
                lines.reserveCapacity(lineCount)
                var rPos = pos + 3
                for _ in 0..<lineCount {
                    guard data.count >= rPos + 2 else { throw ProtocolDecodeError.malformed }
                    let runCount = Int(readU16(data, rPos))
                    var runs: [Wire.StyledTextRun] = []
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
                        runs.append(Wire.StyledTextRun(
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
                messages.append(Wire.ChatMessage(beamId: beamId, content: .styledAssistant(lines: lines)))
                pos = rPos
            case 0x08: // styled_tool_call
                // Same header as tool_call (0x04) but result is styled runs instead of plain text.
                // Format: 0x08, status::8, error::8, collapsed::8, duration::32,
                //   name_len::16, name, summary_len::16, summary, line_count::16, then per line:
                //   run_count::16, then per run: text_len::16, text, fg::24, bg::24, flags::8
                guard data.count >= pos + 10 else { throw ProtocolDecodeError.malformed }
                let stcStatus = data[pos + 1]
                let stcIsError = data[pos + 2] != 0
                let stcCollapsed = data[pos + 3] != 0
                let stcDuration = readU32(data, pos + 4)
                let stcNameLen = Int(readU16(data, pos + 8))
                guard data.count >= pos + 10 + stcNameLen + 2 else { throw ProtocolDecodeError.malformed }
                let stcName = String(data: data[(pos + 10)..<(pos + 10 + stcNameLen)], encoding: .utf8) ?? ""
                let stcSummaryLen = Int(readU16(data, pos + 10 + stcNameLen))
                guard data.count >= pos + 12 + stcNameLen + stcSummaryLen + 2 else { throw ProtocolDecodeError.malformed }
                let stcSummary = String(data: data[(pos + 12 + stcNameLen)..<(pos + 12 + stcNameLen + stcSummaryLen)], encoding: .utf8) ?? ""
                let stcLineCount = Int(readU16(data, pos + 12 + stcNameLen + stcSummaryLen))
                var stcLines: [[Wire.StyledTextRun]] = []
                stcLines.reserveCapacity(stcLineCount)
                var stcPos = pos + 14 + stcNameLen + stcSummaryLen
                for _ in 0..<stcLineCount {
                    guard data.count >= stcPos + 2 else { throw ProtocolDecodeError.malformed }
                    let runCount = Int(readU16(data, stcPos))
                    var runs: [Wire.StyledTextRun] = []
                    runs.reserveCapacity(runCount)
                    stcPos += 2
                    for _ in 0..<runCount {
                        guard data.count >= stcPos + 9 else { throw ProtocolDecodeError.malformed }
                        let textLen = Int(readU16(data, stcPos))
                        guard data.count >= stcPos + 2 + textLen + 7 else { throw ProtocolDecodeError.malformed }
                        let runText = String(data: data[(stcPos + 2)..<(stcPos + 2 + textLen)], encoding: .utf8) ?? ""
                        let fgOff = stcPos + 2 + textLen
                        runs.append(Wire.StyledTextRun(
                            text: runText,
                            fgR: data[fgOff], fgG: data[fgOff + 1], fgB: data[fgOff + 2],
                            bgR: data[fgOff + 3], bgG: data[fgOff + 4], bgB: data[fgOff + 5],
                            bold: (data[fgOff + 6] & 0x01) != 0,
                            italic: (data[fgOff + 6] & 0x02) != 0,
                            underline: (data[fgOff + 6] & 0x04) != 0
                        ))
                        stcPos = fgOff + 7
                    }
                    stcLines.append(runs)
                }
                messages.append(Wire.ChatMessage(beamId: beamId, content: .styledToolCall(name: stcName, summary: stcSummary, status: stcStatus, isError: stcIsError, collapsed: stcCollapsed, durationMs: stcDuration, resultLines: stcLines)))
                pos = stcPos
            default:
                break
            }
        }

            default: break
            }

            chatPos = csStart + csLen
        }

        return (.guiAgentChat(visible: chatVisible, status: chatStatus, model: chatModel, prompt: chatPrompt, promptLineCount: promptLineCount, promptCursorLine: promptCursorLine, promptCursorCol: promptCursorCol, promptVimMode: promptVimMode, promptVisibleRows: promptVisibleRows, promptCompletion: promptCompletion, pendingToolName: pendingToolName, pendingToolSummary: pendingToolSummary, helpVisible: helpVisible, helpGroups: helpGroups, messages: messages), chatPos - offset)

    case OP_GUI_GUTTER_SEP:
        // col:2, r:1, g:1, b:1 = 5 bytes after opcode
        guard data.count >= rest + 5 else { throw ProtocolDecodeError.malformed }
        let col = readU16(data, rest)
        return (.guiGutterSeparator(col: col, r: data[rest + 2], g: data[rest + 3], b: data[rest + 4]), 6)

    case OP_GUI_CURSORLINE:
        // row:2, r:1, g:1, b:1 = 5 bytes after opcode
        guard data.count >= rest + 5 else { throw ProtocolDecodeError.malformed }
        let row = readU16(data, rest)
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
        var isActive = false
        var cursorLine: UInt32 = 0
        var style: Wire.LineNumberStyle = .hybrid
        var lnWidth: UInt8 = 0
        var signWidth: UInt8 = 0
        var entries: [Wire.GutterEntry] = []

        for _ in 0..<gutterSectionCount {
            guard data.count >= gutterPos + 3 else { throw ProtocolDecodeError.malformed }
            let gsId = data[gutterPos]
            let gsLen = Int(readU16(data, gutterPos + 1))
            let gsStart = gutterPos + 3
            guard data.count >= gsStart + gsLen else { throw ProtocolDecodeError.malformed }

            switch gsId {
            case 0x01: // Window: window_id(2) + row(2) + col(2) + height(2) + is_active(1)
                guard gsLen >= 9 else { break }
                windowId = readU16(data, gsStart)
                contentRow = readU16(data, gsStart + 2)
                contentCol = readU16(data, gsStart + 4)
                contentHeight = readU16(data, gsStart + 6)
                isActive = data[gsStart + 8] != 0

            case 0x02: // Config: cursor_line(4) + style(1) + ln_width(1) + sign_width(1)
                guard gsLen >= 7 else { break }
                cursorLine = readU32(data, gsStart)
                style = Wire.LineNumberStyle(rawValue: data[gsStart + 4]) ?? .hybrid
                lnWidth = data[gsStart + 5]
                signWidth = data[gsStart + 6]

            case 0x03: // Entries: count(2) + entries...
                guard gsLen >= 2 else { break }
                let lineCount = Int(readU16(data, gsStart))
                entries.reserveCapacity(lineCount)
                var ePos = gsStart + 2
                for _ in 0..<lineCount {
                    guard data.count >= ePos + 6 else { break }
                    let bufLine = readU32(data, ePos)
                    let dt = Wire.GutterDisplayType(rawValue: data[ePos + 4]) ?? .normal
                    let st = Wire.GutterSignType(rawValue: data[ePos + 5]) ?? .none
                    ePos += 6
                    if st == .annotation {
                        guard data.count >= ePos + 4 else { break }
                        let fg = readU24(data, ePos)
                        let textLen = Int(data[ePos + 3])
                        ePos += 4
                        guard data.count >= ePos + textLen else { break }
                        let text = String(data: Data(data[ePos..<(ePos + textLen)]), encoding: .utf8) ?? ""
                        ePos += textLen
                        entries.append(Wire.GutterEntry(bufLine: bufLine, displayType: dt, signType: st, signFg: fg, signText: text))
                    } else {
                        entries.append(Wire.GutterEntry(bufLine: bufLine, displayType: dt, signType: st))
                    }
                }

            default: break
            }

            gutterPos = gsStart + gsLen
        }

        let windowGutter = Wire.WindowGutter(
            windowId: windowId, contentRow: contentRow, contentCol: contentCol,
            contentHeight: contentHeight, isActive: isActive, cursorLine: cursorLine,
            lineNumberStyle: style, lineNumberWidth: lnWidth, signColWidth: signWidth,
            entries: entries
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
            let name = String(data: data[pos..<(pos + nameLen)], encoding: .utf8) ?? ""
            pos += nameLen
            tabs.append(Wire.BottomPanelTab(tabType: tabType, name: name))
        }
        // Content payload: entry_count(2) + entries...
        var entries: [Wire.MessageEntry] = []
        guard data.count >= pos + 2 else {
            return (.guiBottomPanel(visible: true, activeTabIndex: activeTabIndex,
                                     heightPercent: heightPercent, filterPreset: filterPreset,
                                     tabs: tabs, entries: []), pos - offset)
        }
        let entryCount = Int(readU16(data, pos))
        pos += 2
        for _ in 0..<entryCount {
            // id(4) + level(1) + subsystem(1) + timestamp_secs(4) + path_len(2)
            guard data.count >= pos + 12 else { break }
            let entryId = readU32(data, pos)
            let level = data[pos + 4]
            let subsystem = data[pos + 5]
            let tsSecs = readU32(data, pos + 6)
            let pathLen = Int(readU16(data, pos + 10))
            pos += 12
            guard data.count >= pos + pathLen else { break }
            let filePath = String(data: data[pos..<(pos + pathLen)], encoding: .utf8) ?? ""
            pos += pathLen
            // text_len(2) + text
            guard data.count >= pos + 2 else { break }
            let textLen = Int(readU16(data, pos))
            pos += 2
            guard data.count >= pos + textLen else { break }
            let text = String(data: data[pos..<(pos + textLen)], encoding: .utf8) ?? ""
            pos += textLen
            entries.append(Wire.MessageEntry(id: entryId, level: level, subsystem: subsystem,
                                            timestampSecs: tsSecs, filePath: filePath, text: text))
        }
        return (.guiBottomPanel(visible: true, activeTabIndex: activeTabIndex,
                                 heightPercent: heightPercent, filterPreset: filterPreset,
                                 tabs: tabs, entries: entries), pos - offset)

    case OP_GUI_WINDOW_CONTENT:
        // Sectioned format: opcode(1) + section_count(1) + sections...
        guard data.count >= rest + 1 else { throw ProtocolDecodeError.malformed }
        let wcSectionCount = Int(data[rest])
        var wcPos = rest + 1

        var wcWindowId: UInt16 = 0
        var wcFlags: UInt8 = 0
        var wcCursorRow: UInt16 = 0
        var wcCursorCol: UInt16 = 0
        var wcCursorShape: CursorShape = .block
        var wcScrollLeft: UInt16 = 0
        var wcRows: [GUIVisualRow] = []
        var wcSelection: GUISelectionOverlay? = nil
        var wcMatches: [GUISearchMatch] = []
        var wcDiags: [GUIDiagnosticUnderline] = []
        var wcHighlights: [GUIDocumentHighlight] = []
        var wcAnnotations: [GUILineAnnotation] = []

        for _ in 0..<wcSectionCount {
            guard data.count >= wcPos + 3 else { throw ProtocolDecodeError.malformed }
            let wcSId = data[wcPos]
            let wcSLen = Int(readU16(data, wcPos + 1))
            let wcSStart = wcPos + 3
            guard data.count >= wcSStart + wcSLen else { throw ProtocolDecodeError.malformed }

            switch wcSId {
            case 0x01: // Header: window_id(2) + flags(1) + cursor_row(2) + cursor_col(2) + cursor_shape(1) + scroll_left(2)
                guard wcSLen >= 10 else { break }
                wcWindowId = readU16(data, wcSStart)
                wcFlags = data[wcSStart + 2]
                wcCursorRow = readU16(data, wcSStart + 3)
                wcCursorCol = readU16(data, wcSStart + 5)
                wcCursorShape = CursorShape(rawValue: data[wcSStart + 7]) ?? .block
                wcScrollLeft = readU16(data, wcSStart + 8)

            case 0x02: // Rows: row_count(2) + rows...
                guard wcSLen >= 2 else { break }
                let rowCount = Int(readU16(data, wcSStart))
                wcRows.reserveCapacity(rowCount)
                var rp = wcSStart + 2
                for _ in 0..<rowCount {
                    guard rp + 13 <= wcSStart + wcSLen else { break }
                    let rowType = GUIVisualRowType(rawValue: data[rp]) ?? .normal
                    let bufLine = readU32(data, rp + 1)
                    let contentHash = readU32(data, rp + 5)
                    let textLen = Int(readU32(data, rp + 9))
                    rp += 13
                    guard rp + textLen <= wcSStart + wcSLen else { break }
                    let text = String(data: data[rp..<(rp + textLen)], encoding: .utf8) ?? ""
                    rp += textLen
                    guard rp + 2 <= wcSStart + wcSLen else { break }
                    let spanCount = Int(readU16(data, rp)); rp += 2
                    var spans: [GUIHighlightSpan] = []
                    spans.reserveCapacity(spanCount)
                    for _ in 0..<spanCount {
                        guard rp + 13 <= wcSStart + wcSLen else { break }
                        spans.append(GUIHighlightSpan(
                            startCol: readU16(data, rp), endCol: readU16(data, rp + 2),
                            fg: readU24(data, rp + 4), bg: readU24(data, rp + 7),
                            attrs: data[rp + 10], fontWeight: data[rp + 11], fontId: data[rp + 12]
                        ))
                        rp += 13
                    }
                    wcRows.append(GUIVisualRow(rowType: rowType, bufLine: bufLine, contentHash: contentHash, text: text, spans: spans))
                }

            case 0x03: // Selection: type(1), if != 0: start_row(2) + start_col(2) + end_row(2) + end_col(2)
                guard wcSLen >= 1 else { break }
                let selType = data[wcSStart]
                if selType != 0, wcSLen >= 9 {
                    wcSelection = GUISelectionOverlay(
                        type: GUISelectionType(rawValue: selType) ?? .char,
                        startRow: readU16(data, wcSStart + 1), startCol: readU16(data, wcSStart + 3),
                        endRow: readU16(data, wcSStart + 5), endCol: readU16(data, wcSStart + 7)
                    )
                }

            case 0x04: // Search matches: count(2) + matches...
                guard wcSLen >= 2 else { break }
                let mc = Int(readU16(data, wcSStart))
                wcMatches.reserveCapacity(mc)
                var mp = wcSStart + 2
                for _ in 0..<mc {
                    guard mp + 7 <= wcSStart + wcSLen else { break }
                    wcMatches.append(GUISearchMatch(
                        row: readU16(data, mp), startCol: readU16(data, mp + 2),
                        endCol: readU16(data, mp + 4), isCurrent: data[mp + 6] != 0
                    ))
                    mp += 7
                }

            case 0x05: // Diagnostics: count(2) + ranges...
                guard wcSLen >= 2 else { break }
                let dc = Int(readU16(data, wcSStart))
                wcDiags.reserveCapacity(dc)
                var dp = wcSStart + 2
                for _ in 0..<dc {
                    guard dp + 9 <= wcSStart + wcSLen else { break }
                    wcDiags.append(GUIDiagnosticUnderline(
                        startRow: readU16(data, dp), startCol: readU16(data, dp + 2),
                        endRow: readU16(data, dp + 4), endCol: readU16(data, dp + 6),
                        severity: GUIDiagnosticSeverity(rawValue: data[dp + 8]) ?? .error
                    ))
                    dp += 9
                }

            case 0x06: // Document highlights: count(2) + highlights...
                guard wcSLen >= 2 else { break }
                let hc = Int(readU16(data, wcSStart))
                wcHighlights.reserveCapacity(hc)
                var hp = wcSStart + 2
                for _ in 0..<hc {
                    guard hp + 9 <= wcSStart + wcSLen else { break }
                    wcHighlights.append(GUIDocumentHighlight(
                        startRow: readU16(data, hp), startCol: readU16(data, hp + 2),
                        endRow: readU16(data, hp + 4), endCol: readU16(data, hp + 6),
                        kind: GUIDocumentHighlightKind(rawValue: data[hp + 8]) ?? .text
                    ))
                    hp += 9
                }

            case 0x07: // Line annotations: count(2) + annotations...
                guard wcSLen >= 2 else { break }
                let ac = Int(readU16(data, wcSStart))
                wcAnnotations.reserveCapacity(ac)
                var ap = wcSStart + 2
                for _ in 0..<ac {
                    guard ap + 11 <= wcSStart + wcSLen else { break }
                    let annRow = readU16(data, ap)
                    let annKind = GUILineAnnotationKind(rawValue: data[ap + 2]) ?? .inlinePill
                    let annFg = readU24(data, ap + 3)
                    let annBg = readU24(data, ap + 6)
                    let annTextLen = Int(readU16(data, ap + 9))
                    ap += 11
                    guard ap + annTextLen <= wcSStart + wcSLen else { break }
                    let annText = String(data: Data(data[ap..<(ap + annTextLen)]), encoding: .utf8) ?? ""
                    ap += annTextLen
                    wcAnnotations.append(GUILineAnnotation(row: annRow, kind: annKind, fg: annFg, bg: annBg, text: annText))
                }

            default: break
            }

            wcPos = wcSStart + wcSLen
        }

        let content = GUIWindowContent(
            windowId: wcWindowId,
            fullRefresh: (wcFlags & 0x01) != 0,
            cursorVisible: (wcFlags & 0x02) != 0,
            cursorRow: wcCursorRow,
            cursorCol: wcCursorCol,
            cursorShape: wcCursorShape,
            scrollLeft: wcScrollLeft,
            rows: wcRows,
            selection: wcSelection,
            searchMatches: wcMatches,
            diagnosticUnderlines: wcDiags,
            documentHighlights: wcHighlights,
            lineAnnotations: wcAnnotations
        )
        return (.guiWindowContent(data: content), wcPos - offset)

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
        let tmSelectedIndex = readU16(data, rest + 2)
        let toolCount = Int(readU16(data, rest + 4))
        var pos = rest + 6
        var tools: [Wire.ToolEntry] = []
        tools.reserveCapacity(toolCount)
        for _ in 0..<toolCount {
            // name_len(1) + name
            guard data.count >= pos + 1 else { break }
            let nameLen = Int(data[pos]); pos += 1
            guard data.count >= pos + nameLen else { break }
            let name = String(data: data[pos..<(pos + nameLen)], encoding: .utf8) ?? ""
            pos += nameLen
            // label_len(1) + label
            guard data.count >= pos + 1 else { break }
            let labelLen = Int(data[pos]); pos += 1
            guard data.count >= pos + labelLen else { break }
            let toolLabel = String(data: data[pos..<(pos + labelLen)], encoding: .utf8) ?? ""
            pos += labelLen
            // desc_len(2) + desc
            guard data.count >= pos + 2 else { break }
            let descLen = Int(readU16(data, pos)); pos += 2
            guard data.count >= pos + descLen else { break }
            let desc = String(data: data[pos..<(pos + descLen)], encoding: .utf8) ?? ""
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
                let lang = String(data: data[pos..<(pos + lLen)], encoding: .utf8) ?? ""
                pos += lLen
                langs.append(lang)
            }
            // version_len(1) + version
            guard data.count >= pos + 1 else { break }
            let verLen = Int(data[pos]); pos += 1
            guard data.count >= pos + verLen else { break }
            let version = String(data: data[pos..<(pos + verLen)], encoding: .utf8) ?? ""
            pos += verLen
            // homepage_len(2) + homepage
            guard data.count >= pos + 2 else { break }
            let hpLen = Int(readU16(data, pos)); pos += 2
            guard data.count >= pos + hpLen else { break }
            let homepage = String(data: data[pos..<(pos + hpLen)], encoding: .utf8) ?? ""
            pos += hpLen
            // provides_count(1) + provides
            guard data.count >= pos + 1 else { break }
            let provCount = Int(data[pos]); pos += 1
            var provides: [String] = []
            for _ in 0..<provCount {
                guard data.count >= pos + 1 else { break }
                let cLen = Int(data[pos]); pos += 1
                guard data.count >= pos + cLen else { break }
                let cmd = String(data: data[pos..<(pos + cLen)], encoding: .utf8) ?? ""
                pos += cLen
                provides.append(cmd)
            }
            // error_reason_len(2) + error_reason
            guard data.count >= pos + 2 else { throw ProtocolDecodeError.malformed }
            let errLen = Int(readU16(data, pos)); pos += 2
            guard data.count >= pos + errLen else { throw ProtocolDecodeError.malformed }
            let errorReason = errLen > 0
                ? (String(data: data[pos..<(pos + errLen)], encoding: .utf8) ?? "")
                : ""
            pos += errLen
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
        let mbCursorPos = readU16(data, rest + 2)
        let mbPromptLen = Int(data[rest + 4])
        var mbPos = rest + 5
        // prompt
        guard data.count >= mbPos + mbPromptLen else { throw ProtocolDecodeError.malformed }
        let mbPrompt = String(data: data[mbPos..<(mbPos + mbPromptLen)], encoding: .utf8) ?? ""
        mbPos += mbPromptLen
        // input_len(2) + input
        guard data.count >= mbPos + 2 else { throw ProtocolDecodeError.malformed }
        let mbInputLen = Int(readU16(data, mbPos)); mbPos += 2
        guard data.count >= mbPos + mbInputLen else { throw ProtocolDecodeError.malformed }
        let mbInput = String(data: data[mbPos..<(mbPos + mbInputLen)], encoding: .utf8) ?? ""
        mbPos += mbInputLen
        // context_len(2) + context
        guard data.count >= mbPos + 2 else { throw ProtocolDecodeError.malformed }
        let mbContextLen = Int(readU16(data, mbPos)); mbPos += 2
        guard data.count >= mbPos + mbContextLen else { throw ProtocolDecodeError.malformed }
        let mbContext = String(data: data[mbPos..<(mbPos + mbContextLen)], encoding: .utf8) ?? ""
        mbPos += mbContextLen
        // selected_index(2) + candidate_count(2) + total_candidates(2)
        guard data.count >= mbPos + 6 else { throw ProtocolDecodeError.malformed }
        let mbSelIndex = readU16(data, mbPos); mbPos += 2
        let mbCandCount = Int(readU16(data, mbPos)); mbPos += 2
        let mbTotalCandidates = readU16(data, mbPos); mbPos += 2
        // candidates
        var mbCandidates: [Wire.MinibufferCandidate] = []
        mbCandidates.reserveCapacity(mbCandCount)
        for _ in 0..<mbCandCount {
            // match_score(1) + label_len(2)
            guard data.count >= mbPos + 3 else { break }
            let score = data[mbPos]; mbPos += 1
            let candLabelLen = Int(readU16(data, mbPos)); mbPos += 2
            guard data.count >= mbPos + candLabelLen else { break }
            let candLabel = String(data: data[mbPos..<(mbPos + candLabelLen)], encoding: .utf8) ?? ""
            mbPos += candLabelLen
            // desc_len(2) + desc
            guard data.count >= mbPos + 2 else { break }
            let candDescLen = Int(readU16(data, mbPos)); mbPos += 2
            guard data.count >= mbPos + candDescLen else { break }
            let candDesc = String(data: data[mbPos..<(mbPos + candDescLen)], encoding: .utf8) ?? ""
            mbPos += candDescLen
            // annotation_len(2) + annotation
            guard data.count >= mbPos + 2 else { break }
            let candAnnotLen = Int(readU16(data, mbPos)); mbPos += 2
            guard data.count >= mbPos + candAnnotLen else { break }
            let candAnnot = String(data: data[mbPos..<(mbPos + candAnnotLen)], encoding: .utf8) ?? ""
            mbPos += candAnnotLen
            // match_pos_count(1) + match_positions(count * 2)
            guard data.count >= mbPos + 1 else { break }
            let matchPosCount = Int(data[mbPos]); mbPos += 1
            var matchPositions: [UInt16] = []
            matchPositions.reserveCapacity(matchPosCount)
            for _ in 0..<matchPosCount {
                guard data.count >= mbPos + 2 else { break }
                matchPositions.append(readU16(data, mbPos)); mbPos += 2
            }
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
        let hAnchorRow = readU16(data, rest + 1)
        let hAnchorCol = readU16(data, rest + 3)
        let hFocused = data[rest + 5] != 0
        let hScrollOffset = readU16(data, rest + 6)
        let hLineCount = Int(readU16(data, rest + 8))
        var hPos = rest + 10
        var hLines: [Wire.HoverLine] = []
        hLines.reserveCapacity(hLineCount)
        for _ in 0..<hLineCount {
            // line_type(1) + segment_count(2)
            guard data.count >= hPos + 3 else { break }
            let lineType = Wire.HoverLineType(rawValue: data[hPos]) ?? .text
            let segCount = Int(readU16(data, hPos + 1))
            hPos += 3
            var segments: [Wire.HoverSegment] = []
            segments.reserveCapacity(segCount)
            for _ in 0..<segCount {
                // style(1) + text_len(2) + text
                guard data.count >= hPos + 3 else { break }
                let style = Wire.HoverStyle(rawValue: data[hPos]) ?? .plain
                let textLen = Int(readU16(data, hPos + 1))
                hPos += 3
                guard data.count >= hPos + textLen else { break }
                let text = String(data: data[hPos..<(hPos + textLen)], encoding: .utf8) ?? ""
                hPos += textLen
                segments.append(Wire.HoverSegment(style: style, text: text))
            }
            hLines.append(Wire.HoverLine(lineType: lineType, segments: segments))
        }
        return (.guiHoverPopup(visible: true, anchorRow: hAnchorRow, anchorCol: hAnchorCol,
                                focused: hFocused, scrollOffset: hScrollOffset, lines: hLines),
                hPos - offset)

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
        let shAnchorRow = readU16(data, rest + 1)
        let shAnchorCol = readU16(data, rest + 3)
        let shActiveSig = data[rest + 5]
        let shActiveParam = data[rest + 6]
        let shSigCount = Int(data[rest + 7])
        var shPos = rest + 8
        var signatures: [Wire.Signature] = []
        signatures.reserveCapacity(shSigCount)
        for _ in 0..<shSigCount {
            // label_len(2) + label
            guard data.count >= shPos + 2 else { break }
            let labelLen = Int(readU16(data, shPos)); shPos += 2
            guard data.count >= shPos + labelLen else { break }
            let label = String(data: data[shPos..<(shPos + labelLen)], encoding: .utf8) ?? ""
            shPos += labelLen
            // doc_len(2) + doc
            guard data.count >= shPos + 2 else { break }
            let docLen = Int(readU16(data, shPos)); shPos += 2
            guard data.count >= shPos + docLen else { break }
            let doc = String(data: data[shPos..<(shPos + docLen)], encoding: .utf8) ?? ""
            shPos += docLen
            // param_count(1)
            guard data.count >= shPos + 1 else { break }
            let paramCount = Int(data[shPos]); shPos += 1
            var params: [Wire.SignatureParameter] = []
            params.reserveCapacity(paramCount)
            for _ in 0..<paramCount {
                // label_len(2) + label + doc_len(2) + doc
                guard data.count >= shPos + 2 else { break }
                let pLabelLen = Int(readU16(data, shPos)); shPos += 2
                guard data.count >= shPos + pLabelLen else { break }
                let pLabel = String(data: data[shPos..<(shPos + pLabelLen)], encoding: .utf8) ?? ""
                shPos += pLabelLen
                guard data.count >= shPos + 2 else { break }
                let pDocLen = Int(readU16(data, shPos)); shPos += 2
                guard data.count >= shPos + pDocLen else { break }
                let pDoc = String(data: data[shPos..<(shPos + pDocLen)], encoding: .utf8) ?? ""
                shPos += pDocLen
                params.append(Wire.SignatureParameter(label: pLabel, documentation: pDoc))
            }
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
        let fpWidth = readU16(data, rest + 1)
        let fpHeight = readU16(data, rest + 3)
        let fpTitleLen = Int(readU16(data, rest + 5))
        var fpPos = rest + 7
        guard data.count >= fpPos + fpTitleLen else { throw ProtocolDecodeError.malformed }
        let fpTitle = String(data: data[fpPos..<(fpPos + fpTitleLen)], encoding: .utf8) ?? ""
        fpPos += fpTitleLen
        // line_count(2)
        guard data.count >= fpPos + 2 else { throw ProtocolDecodeError.malformed }
        let fpLineCount = Int(readU16(data, fpPos)); fpPos += 2
        var fpLines: [String] = []
        fpLines.reserveCapacity(fpLineCount)
        for _ in 0..<fpLineCount {
            guard data.count >= fpPos + 2 else { throw ProtocolDecodeError.malformed }
            let lineLen = Int(readU16(data, fpPos)); fpPos += 2
            guard data.count >= fpPos + lineLen else { throw ProtocolDecodeError.malformed }
            let line = String(data: data[fpPos..<(fpPos + lineLen)], encoding: .utf8) ?? ""
            fpPos += lineLen
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
        verts.reserveCapacity(vertCount)
        for _ in 0..<vertCount {
            // col(2) + start_row(2) + end_row(2)
            guard data.count >= sepPos + 6 else { throw ProtocolDecodeError.malformed }
            let col = readU16(data, sepPos)
            let startRow = readU16(data, sepPos + 2)
            let endRow = readU16(data, sepPos + 4)
            sepPos += 6
            verts.append(Wire.VerticalSeparator(col: col, startRow: startRow, endRow: endRow))
        }
        // horizontal_count(1)
        guard data.count >= sepPos + 1 else { throw ProtocolDecodeError.malformed }
        let horizCount = Int(data[sepPos]); sepPos += 1
        var horizs: [Wire.HorizontalSeparator] = []
        horizs.reserveCapacity(horizCount)
        for _ in 0..<horizCount {
            // row(2) + col(2) + width(2) + filename_len(2)
            guard data.count >= sepPos + 8 else { throw ProtocolDecodeError.malformed }
            let hRow = readU16(data, sepPos)
            let hCol = readU16(data, sepPos + 2)
            let hWidth = readU16(data, sepPos + 4)
            let fnLen = Int(readU16(data, sepPos + 6))
            sepPos += 8
            guard data.count >= sepPos + fnLen else { throw ProtocolDecodeError.malformed }
            let fn = String(data: data[sepPos..<(sepPos + fnLen)], encoding: .utf8) ?? ""
            sepPos += fnLen
            horizs.append(Wire.HorizontalSeparator(row: hRow, col: hCol, width: hWidth, filename: fn))
        }
        return (.guiSplitSeparators(borderColor: sepColor, verticals: verts, horizontals: horizs),
                sepPos - offset)

    case OP_GUI_GIT_STATUS:
        // Header: repo_state:1, ahead:2, behind:2, branch_len:2, branch, entry_count:2
        guard data.count >= rest + 9 else { throw ProtocolDecodeError.malformed }
        let gsRepoState = data[rest]
        let gsAhead = readU16(data, rest + 1)
        let gsBehind = readU16(data, rest + 3)
        let gsBranchLen = Int(readU16(data, rest + 5))
        guard data.count >= rest + 7 + gsBranchLen + 2 else { throw ProtocolDecodeError.malformed }
        let gsBranchData = data[(rest + 7)..<(rest + 7 + gsBranchLen)]
        let gsBranchName = String(data: gsBranchData, encoding: .utf8) ?? ""
        let gsEntryCount = Int(readU16(data, rest + 7 + gsBranchLen))
        var gsEntries: [Wire.GitStatusEntry] = []
        gsEntries.reserveCapacity(gsEntryCount)
        var gsPos = rest + 9 + gsBranchLen
        for _ in 0..<gsEntryCount {
            // path_hash:4, section:1, status:1, path_len:2, path
            guard data.count >= gsPos + 8 else { throw ProtocolDecodeError.malformed }
            let gsPathHash = readU32(data, gsPos)
            let gsSection = data[gsPos + 4]
            let gsStatus = data[gsPos + 5]
            let gsPathLen = Int(readU16(data, gsPos + 6))
            guard data.count >= gsPos + 8 + gsPathLen else { throw ProtocolDecodeError.malformed }
            let gsPathData = data[(gsPos + 8)..<(gsPos + 8 + gsPathLen)]
            let gsPath = String(data: gsPathData, encoding: .utf8) ?? ""
            gsEntries.append(Wire.GitStatusEntry(pathHash: gsPathHash, section: gsSection, status: gsStatus, path: gsPath))
            gsPos += 8 + gsPathLen
        }
        return (.guiGitStatus(repoState: gsRepoState, ahead: gsAhead, behind: gsBehind, branchName: gsBranchName, entries: gsEntries),
                gsPos - offset)

    case OP_GUI_AGENT_GROUPS:
        // active_group_id:2, group_count:1, then per group:
        // id:2, agent_status:1, r:1, g:1, b:1, tab_count:2, label_len:1, label, icon_len:1, icon
        guard data.count >= rest + 3 else { throw ProtocolDecodeError.malformed }
        let activeGId = readU16(data, rest)
        let groupCount = Int(data[rest + 2])
        var groups: [Wire.AgentGroupEntry] = []
        groups.reserveCapacity(groupCount)
        var gPos = rest + 3
        for _ in 0..<groupCount {
            guard data.count >= gPos + 9 else { throw ProtocolDecodeError.malformed }
            let gId = readU16(data, gPos)
            let gStatus = data[gPos + 2]
            let gR = data[gPos + 3]
            let gG = data[gPos + 4]
            let gB = data[gPos + 5]
            let gTabCount = readU16(data, gPos + 6)
            let gLabelLen = Int(data[gPos + 8])
            guard data.count >= gPos + 9 + gLabelLen else { throw ProtocolDecodeError.malformed }
            let gLabelData = data[(gPos + 9)..<(gPos + 9 + gLabelLen)]
            let gLabel = String(data: gLabelData, encoding: .utf8) ?? ""
            let gIconBase = gPos + 9 + gLabelLen
            guard data.count >= gIconBase + 1 else { throw ProtocolDecodeError.malformed }
            let gIconLen = Int(data[gIconBase])
            guard data.count >= gIconBase + 1 + gIconLen else { throw ProtocolDecodeError.malformed }
            let gIconData = data[(gIconBase + 1)..<(gIconBase + 1 + gIconLen)]
            let gIcon = String(data: gIconData, encoding: .utf8) ?? "cpu"
            groups.append(Wire.AgentGroupEntry(
                id: gId,
                agentStatus: gStatus,
                colorR: gR,
                colorG: gG,
                colorB: gB,
                tabCount: gTabCount,
                label: gLabel,
                icon: gIcon
            ))
            gPos += 9 + gLabelLen + 1 + gIconLen
        }
        return (.guiAgentGroups(activeGroupId: activeGId, agentGroups: groups),
                gPos - offset)

    case OP_GUI_BOARD:
        // visible(1) + focused_card_id(4) + card_count(2) + filter_mode(1) + filter_len(2) + filter
        guard data.count >= rest + 10 else { throw ProtocolDecodeError.malformed }
        let boardVisible = data[rest] != 0
        let focusedId = readU32(data, rest + 1)
        let cardCount = Int(readU16(data, rest + 5))
        let boardFilterMode = data[rest + 7] != 0
        let filterLen = Int(readU16(data, rest + 8))
        guard data.count >= rest + 10 + filterLen else { throw ProtocolDecodeError.malformed }
        let filterData = data[(rest + 10)..<(rest + 10 + filterLen)]
        let boardFilterText = String(data: filterData, encoding: .utf8) ?? ""
        var boardCards: [BoardCard] = []
        boardCards.reserveCapacity(cardCount)
        var bPos = rest + 10 + filterLen
        for _ in 0..<cardCount {
            // card_id(4) + status(1) + flags(1) + task_len(2) + task + model_len(1) + model + elapsed(4) + file_count(1) + files
            guard data.count >= bPos + 8 else { throw ProtocolDecodeError.malformed }
            let cardId = readU32(data, bPos)
            let statusRaw = data[bPos + 4]
            let flags = data[bPos + 5]
            let taskLen = Int(readU16(data, bPos + 6))
            guard data.count >= bPos + 8 + taskLen else { throw ProtocolDecodeError.malformed }
            let taskData = data[(bPos + 8)..<(bPos + 8 + taskLen)]
            let task = String(data: taskData, encoding: .utf8) ?? ""
            var cPos = bPos + 8 + taskLen
            guard data.count >= cPos + 1 else { throw ProtocolDecodeError.malformed }
            let modelLen = Int(data[cPos])
            cPos += 1
            guard data.count >= cPos + modelLen else { throw ProtocolDecodeError.malformed }
            let modelData = data[cPos..<(cPos + modelLen)]
            let model = String(data: modelData, encoding: .utf8) ?? ""
            cPos += modelLen
            guard data.count >= cPos + 5 else { throw ProtocolDecodeError.malformed }
            let elapsed = readU32(data, cPos)
            let fileCount = Int(data[cPos + 4])
            cPos += 5
            var recentFiles: [String] = []
            for _ in 0..<fileCount {
                guard data.count >= cPos + 2 else { throw ProtocolDecodeError.malformed }
                let pathLen = Int(readU16(data, cPos))
                cPos += 2
                guard data.count >= cPos + pathLen else { throw ProtocolDecodeError.malformed }
                let pathData = data[cPos..<(cPos + pathLen)]
                recentFiles.append(String(data: pathData, encoding: .utf8) ?? "")
                cPos += pathLen
            }
            let isYou = (flags & 0x01) != 0
            let isFocused = (flags & 0x02) != 0
            boardCards.append(BoardCard(
                id: cardId,
                status: CardStatus(rawValue: statusRaw) ?? .idle,
                isYouCard: isYou,
                isFocused: isFocused,
                task: task,
                model: model,
                dispatchTimestamp: elapsed,  // Now treated as Unix timestamp, not elapsed seconds
                recentFiles: recentFiles
            ))
            bPos = cPos
        }
        return (.guiBoard(visible: boardVisible, focusedCardId: focusedId, cards: boardCards,
                         filterMode: boardFilterMode, filterText: boardFilterText),
                bPos - offset)

    case OP_CLIPBOARD_WRITE:
        // Forward-compatible format: opcode(1) + payload_length(2) + target(1) + text_len(2) + text
        guard data.count >= rest + 2 else { throw ProtocolDecodeError.malformed }
        let payloadLen = Int(readU16(data, rest))
        guard data.count >= rest + 2 + payloadLen else { throw ProtocolDecodeError.malformed }
        let payloadStart = rest + 2
        let target = data[payloadStart]
        let textLen = Int(readU16(data, payloadStart + 1))
        guard payloadLen >= 3 + textLen else { throw ProtocolDecodeError.malformed }
        let textData = data[(payloadStart + 3)..<(payloadStart + 3 + textLen)]
        let text = String(data: textData, encoding: .utf8) ?? ""
        return (.clipboardWrite(target: target, text: text), 1 + 2 + payloadLen)

    default:
        // Forward-compatibility: opcodes 0x90+ use a 2-byte length prefix
        // so we can skip unknown opcodes without crashing. Opcodes below
        // 0x90 without a length prefix are truly unknown and we must abort
        // (we can't determine their size).
        if opcode >= 0x90 {
            guard data.count >= rest + 2 else { throw ProtocolDecodeError.malformed }
            let payloadLen = Int(readU16(data, rest))
            let totalSize = 1 + 2 + payloadLen  // opcode + length + payload
            guard data.count >= offset + totalSize else { throw ProtocolDecodeError.malformed }
            // Skip the unknown opcode silently. The BEAM may be newer than
            // this frontend; crashing would be worse than ignoring.
            return (nil, totalSize)
        }
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
