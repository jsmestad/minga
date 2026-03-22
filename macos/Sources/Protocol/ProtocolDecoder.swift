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
    case guiTabBar(activeIndex: UInt8, tabs: [GUITabEntry])
    case guiFileTree(selectedIndex: UInt16, treeWidth: UInt16, rootPath: String, entries: [GUIFileTreeEntry])
    case guiCompletion(visible: Bool, anchorRow: UInt16, anchorCol: UInt16, selectedIndex: UInt16, items: [GUICompletionItem])
    case guiWhichKey(visible: Bool, prefix: String, page: UInt8, pageCount: UInt8, bindings: [GUIWhichKeyBinding])
    case guiBreadcrumb(segments: [String])
    case guiStatusBar(contentKind: UInt8, mode: UInt8, cursorLine: UInt32, cursorCol: UInt32, lineCount: UInt32, flags: UInt8, lspStatus: UInt8, gitBranch: String, message: String, filetype: String, errorCount: UInt16, warningCount: UInt16, modelName: String, messageCount: UInt32, sessionStatus: UInt8, infoCount: UInt16, hintCount: UInt16, macroRecording: UInt8, parserStatus: UInt8, agentStatus: UInt8, gitAdded: UInt16, gitModified: UInt16, gitDeleted: UInt16, icon: String, iconColorR: UInt8, iconColorG: UInt8, iconColorB: UInt8, filename: String, diagnosticHint: String)
    case guiPicker(visible: Bool, selectedIndex: UInt16, filteredCount: UInt16, totalCount: UInt16, title: String, query: String, hasPreview: Bool, items: [GUIPickerItem], actionMenu: GUIPickerActionMenu?)
    case guiPickerPreview(visible: Bool, lines: [GUIPickerPreviewLine])
    case guiAgentChat(visible: Bool, status: UInt8, model: String, prompt: String, pendingToolName: String?, pendingToolSummary: String, messages: [GUIChatMessage])
    case guiGutterSeparator(col: UInt16, r: UInt8, g: UInt8, b: UInt8)
    case guiCursorline(row: UInt16, r: UInt8, g: UInt8, b: UInt8)
    case guiGutter(data: GUIWindowGutter)
    case guiBottomPanel(visible: Bool, activeTabIndex: UInt8, heightPercent: UInt8,
                         filterPreset: UInt8, tabs: [GUIBottomPanelTab],
                         entries: [GUIMessageEntry])
    case guiWindowContent(data: GUIWindowContent)
    case guiToolManager(visible: Bool, filter: UInt8, selectedIndex: UInt16, tools: [GUIToolEntry])
    case guiMinibuffer(visible: Bool, mode: UInt8, cursorPos: UInt16, prompt: String, input: String, context: String, selectedIndex: UInt16, candidates: [GUIMinibufferCandidate])
    case guiHoverPopup(visible: Bool, anchorRow: UInt16, anchorCol: UInt16, focused: Bool, scrollOffset: UInt16, lines: [GUIHoverLine])
    case guiSignatureHelp(visible: Bool, anchorRow: UInt16, anchorCol: UInt16, activeSignature: UInt8, activeParameter: UInt8, signatures: [GUISignature])
    case guiFloatPopup(visible: Bool, width: UInt16, height: UInt16, title: String, lines: [String])
    case guiSplitSeparators(borderColor: UInt32, verticals: [GUIVerticalSeparator], horizontals: [GUIHorizontalSeparator])
}

// MARK: - Minibuffer data types

struct GUIMinibufferCandidate: Sendable {
    let matchScore: UInt8
    let label: String
    let description: String
}

// MARK: - Hover popup data types

/// Markdown style for a hover text segment.
enum GUIHoverStyle: UInt8, Sendable {
    case plain = 0
    case bold = 1
    case italic = 2
    case boldItalic = 3
    case code = 4
    case codeBlock = 5
    case codeContent = 6
    case header1 = 7
    case header2 = 8
    case header3 = 9
    case blockquote = 10
    case listBullet = 11
    case rule = 12
}

/// Line type for hover content (block context).
enum GUIHoverLineType: UInt8, Sendable {
    case text = 0
    case code = 1
    case codeHeader = 2
    case header = 3
    case blockquote = 4
    case listItem = 5
    case rule = 6
    case empty = 7
}

/// A styled text segment within a hover line.
struct GUIHoverSegment: Sendable {
    let style: GUIHoverStyle
    let text: String
}

/// A line of hover content with its block type and styled segments.
struct GUIHoverLine: Sendable {
    let lineType: GUIHoverLineType
    let segments: [GUIHoverSegment]
}

// MARK: - Signature help data types

/// A parameter in a function signature.
struct GUISignatureParameter: Sendable {
    let label: String
    let documentation: String
}

/// A function signature with its parameters.
struct GUISignature: Sendable {
    let label: String
    let documentation: String
    let parameters: [GUISignatureParameter]
}

// MARK: - Split separator data types

/// A vertical split separator line.
struct GUIVerticalSeparator: Sendable {
    let col: UInt16
    let startRow: UInt16
    let endRow: UInt16
}

/// A horizontal split separator with a centered filename.
struct GUIHorizontalSeparator: Sendable {
    let row: UInt16
    let col: UInt16
    let width: UInt16
    let filename: String
}

// MARK: - Tool Manager data types

struct GUIToolEntry {
    let name: String
    let label: String
    let description: String
    let category: UInt8
    let status: UInt8
    let method: UInt8
    let languages: [String]
    let version: String
    let homepage: String
    let provides: [String]
    let errorReason: String
}

/// Line number display style from the BEAM.
enum GUILineNumberStyle: UInt8, Sendable {
    case hybrid = 0
    case absolute = 1
    case relative = 2
    case none = 3
}

/// Display type for a gutter row.
enum GUIGutterDisplayType: UInt8, Sendable {
    case normal = 0
    case foldStart = 1
    case foldContinuation = 2
    case wrapContinuation = 3
}

/// Sign type for the gutter sign column.
enum GUIGutterSignType: UInt8, Sendable {
    case none = 0
    case gitAdded = 1
    case gitModified = 2
    case gitDeleted = 3
    case diagError = 4
    case diagWarning = 5
    case diagInfo = 6
    case diagHint = 7
}

/// A single gutter entry for one visible line.
struct GUIGutterEntry: Sendable {
    let bufLine: UInt32
    let displayType: GUIGutterDisplayType
    let signType: GUIGutterSignType
}

/// Gutter data for one window, including its screen position.
/// One message per window arrives each frame.
struct GUIWindowGutter: Sendable {
    /// Window ID matching the gui_window_content (0x80) windowId.
    let windowId: UInt16
    /// Screen row where this window's content area begins.
    let contentRow: UInt16
    /// Screen column where this window's content area begins.
    let contentCol: UInt16
    /// Height of this window's content area in rows.
    let contentHeight: UInt16
    /// Whether this is the active (focused) window.
    let isActive: Bool

    let cursorLine: UInt32
    let lineNumberStyle: GUILineNumberStyle
    let lineNumberWidth: UInt8
    let signColWidth: UInt8
    var entries: [GUIGutterEntry]
}

/// A tab definition from gui_bottom_panel.
struct GUIBottomPanelTab: Sendable {
    let tabType: UInt8
    let name: String
}

/// A structured log entry from the Messages tab content.
struct GUIMessageEntry: Sendable {
    let id: UInt32
    let level: UInt8
    let subsystem: UInt8
    let timestampSecs: UInt32
    let filePath: String
    let text: String
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
    /// Tool call with pre-styled result runs from tree-sitter.
    case styledToolCall(name: String, status: UInt8, isError: Bool, collapsed: Bool, durationMs: UInt32, resultLines: [[StyledTextRun]])
    case system(text: String, isError: Bool)
    case usage(input: UInt32, output: UInt32, cacheRead: UInt32, cacheWrite: UInt32, costMicros: UInt32)
}

/// A picker item from gui_picker (v2 extended format).
struct GUIPickerItem: Sendable {
    let iconColor: UInt32  // 24-bit RGB
    let flags: UInt8       // bit 0: two_line, bit 1: marked
    let label: String
    let description: String
    let annotation: String
    let matchPositions: [UInt16]  // 0-based character indices of matched chars in label

    var isTwoLine: Bool { flags & 0x01 != 0 }
    var isMarked: Bool { flags & 0x02 != 0 }
}

/// An action menu for the picker (C-o menu).
struct GUIPickerActionMenu: Sendable {
    let selectedIndex: UInt8
    let actions: [String]
}

/// A styled text segment for picker preview content.
struct GUIPickerPreviewSegment: Sendable {
    let fgColor: UInt32   // 24-bit RGB
    let bold: Bool
    let text: String
}

/// A line of preview content (array of styled segments).
typealias GUIPickerPreviewLine = [GUIPickerPreviewSegment]

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
    let pathHash: UInt32
    let isDir: Bool
    let isExpanded: Bool
    let isSelected: Bool
    let depth: UInt8
    let gitStatus: UInt8
    let icon: String
    let name: String
    let relPath: String
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
        var entries: [GUIFileTreeEntry] = []
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
            entries.append(GUIFileTreeEntry(
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
        // Shared header (both variants):
        //   content_kind:1 mode:1 cursor_line:4 cursor_col:4 line_count:4
        //   flags:1 lsp:1 git_len:1 git(:git_len) msg_len:2 msg(:msg_len) ft_len:1 ft(:ft_len)
        //   error_count:2 warning_count:2
        // Agent-only fields (content_kind == 1), appended after the shared header:
        //   model_name_len:1 model_name(:model_name_len) message_count:4 session_status:1
        guard data.count >= rest + 17 else { throw ProtocolDecodeError.malformed }
        let contentKind = data[rest]
        let mode = data[rest + 1]
        let cursorLine = readU32(data, rest + 2)
        let cursorCol = readU32(data, rest + 6)
        let lineCount = readU32(data, rest + 10)
        let flags = data[rest + 14]
        let lspStatus = data[rest + 15]
        let gitLen = Int(data[rest + 16])
        guard data.count >= rest + 17 + gitLen + 2 else { throw ProtocolDecodeError.malformed }
        let gitBranch = String(data: data[(rest + 17)..<(rest + 17 + gitLen)], encoding: .utf8) ?? ""
        let msgLen = Int(readU16(data, rest + 17 + gitLen))
        guard data.count >= rest + 19 + gitLen + msgLen + 1 else { throw ProtocolDecodeError.malformed }
        let message = String(data: data[(rest + 19 + gitLen)..<(rest + 19 + gitLen + msgLen)], encoding: .utf8) ?? ""
        let ftLen = Int(data[rest + 19 + gitLen + msgLen])
        guard data.count >= rest + 20 + gitLen + msgLen + ftLen + 4 else { throw ProtocolDecodeError.malformed }
        let filetype = String(data: data[(rest + 20 + gitLen + msgLen)..<(rest + 20 + gitLen + msgLen + ftLen)], encoding: .utf8) ?? ""
        let diagBase = rest + 20 + gitLen + msgLen + ftLen
        let errorCount: UInt16 = readU16(data, diagBase)
        let warningCount: UInt16 = readU16(data, diagBase + 2)
        var totalConsumed = diagBase + 4

        // Agent-only fields: explicit message_count and session_status after model_name.
        var modelName = ""
        var messageCount: UInt32 = 0
        var sessionStatus: UInt8 = 0

        // Extended buffer fields (TUI modeline parity)
        var infoCount: UInt16 = 0
        var hintCount: UInt16 = 0
        var macroRecording: UInt8 = 0
        var parserStatus: UInt8 = 0
        var agentStatus: UInt8 = 0
        var gitAdded: UInt16 = 0
        var gitModified: UInt16 = 0
        var gitDeleted: UInt16 = 0
        var icon = ""
        var iconColorR: UInt8 = 0
        var iconColorG: UInt8 = 0
        var iconColorB: UInt8 = 0
        var filename = ""
        var diagnosticHint = ""

        if contentKind == 1 && data.count >= totalConsumed + 1 {
            let modelNameLen = Int(data[totalConsumed])
            totalConsumed += 1
            // 4 bytes message_count + 1 byte session_status follow the model name
            guard data.count >= totalConsumed + modelNameLen + 5 else { throw ProtocolDecodeError.malformed }
            modelName = String(data: data[totalConsumed..<(totalConsumed + modelNameLen)], encoding: .utf8) ?? ""
            totalConsumed += modelNameLen
            messageCount = readU32(data, totalConsumed)
            sessionStatus = data[totalConsumed + 4]
            totalConsumed += 5
        } else if contentKind == 0 {
            // Extended buffer fields after warning_count:
            // info_count:2 hint_count:2 macro_recording:1 parser_status:1 agent_status:1
            // git_added:2 git_modified:2 git_deleted:2
            // icon_len:1 icon:N icon_color_r:1 icon_color_g:1 icon_color_b:1
            // filename_len:2 filename:N
            // 2+2+1+1+1+2+2+2 = 13 bytes of fixed fields before icon
            guard data.count >= totalConsumed + 13 else { throw ProtocolDecodeError.malformed }
            infoCount = readU16(data, totalConsumed)
            hintCount = readU16(data, totalConsumed + 2)
            macroRecording = data[totalConsumed + 4]
            parserStatus = data[totalConsumed + 5]
            agentStatus = data[totalConsumed + 6]
            gitAdded = readU16(data, totalConsumed + 7)
            gitModified = readU16(data, totalConsumed + 9)
            gitDeleted = readU16(data, totalConsumed + 11)
            totalConsumed += 13
            // icon: len:1 + data + color:3
            guard data.count >= totalConsumed + 1 else { throw ProtocolDecodeError.malformed }
            let iconLen = Int(data[totalConsumed])
            totalConsumed += 1
            guard data.count >= totalConsumed + iconLen + 3 else { throw ProtocolDecodeError.malformed }
            icon = String(data: data[totalConsumed..<(totalConsumed + iconLen)], encoding: .utf8) ?? ""
            totalConsumed += iconLen
            iconColorR = data[totalConsumed]
            iconColorG = data[totalConsumed + 1]
            iconColorB = data[totalConsumed + 2]
            totalConsumed += 3
            // filename: len:2 + data
            guard data.count >= totalConsumed + 2 else { throw ProtocolDecodeError.malformed }
            let filenameLen = Int(readU16(data, totalConsumed))
            totalConsumed += 2
            guard data.count >= totalConsumed + filenameLen else { throw ProtocolDecodeError.malformed }
            filename = String(data: data[totalConsumed..<(totalConsumed + filenameLen)], encoding: .utf8) ?? ""
            totalConsumed += filenameLen
            // diagnostic_hint_len:2 + diagnostic_hint:N (backward-compatible: may be absent)
            if data.count >= totalConsumed + 2 {
                let diagHintLen = Int(readU16(data, totalConsumed))
                totalConsumed += 2
                if data.count >= totalConsumed + diagHintLen, diagHintLen > 0 {
                    diagnosticHint = String(data: data[totalConsumed..<(totalConsumed + diagHintLen)], encoding: .utf8) ?? ""
                    totalConsumed += diagHintLen
                }
            }
        }
        return (.guiStatusBar(contentKind: contentKind, mode: mode, cursorLine: cursorLine, cursorCol: cursorCol, lineCount: lineCount, flags: flags, lspStatus: lspStatus, gitBranch: gitBranch, message: message, filetype: filetype, errorCount: errorCount, warningCount: warningCount, modelName: modelName, messageCount: messageCount, sessionStatus: sessionStatus, infoCount: infoCount, hintCount: hintCount, macroRecording: macroRecording, parserStatus: parserStatus, agentStatus: agentStatus, gitAdded: gitAdded, gitModified: gitModified, gitDeleted: gitDeleted, icon: icon, iconColorR: iconColorR, iconColorG: iconColorG, iconColorB: iconColorB, filename: filename, diagnosticHint: diagnosticHint), totalConsumed - offset)

    case OP_GUI_PICKER:
        guard data.count >= rest + 1 else { throw ProtocolDecodeError.malformed }
        let visible = data[rest] != 0
        if !visible {
            return (.guiPicker(visible: false, selectedIndex: 0, filteredCount: 0, totalCount: 0, title: "", query: "", hasPreview: false, items: [], actionMenu: nil), 2)
        }
        // v2 header: selected(2) + filtered_count(2) + total_count(2) + title_len(2) + title + query_len(2) + query + has_preview(1) + item_count(2)
        guard data.count >= rest + 7 else { throw ProtocolDecodeError.malformed }
        let selectedIndex = readU16(data, rest + 1)
        let filteredCount = readU16(data, rest + 3)
        let totalCount = readU16(data, rest + 5)
        let titleLen = Int(readU16(data, rest + 7))
        guard data.count >= rest + 9 + titleLen + 2 else { throw ProtocolDecodeError.malformed }
        let title = String(data: data[(rest + 9)..<(rest + 9 + titleLen)], encoding: .utf8) ?? ""
        let queryLen = Int(readU16(data, rest + 9 + titleLen))
        guard data.count >= rest + 11 + titleLen + queryLen + 3 else { throw ProtocolDecodeError.malformed }
        let query = String(data: data[(rest + 11 + titleLen)..<(rest + 11 + titleLen + queryLen)], encoding: .utf8) ?? ""
        let hasPreview = data[rest + 11 + titleLen + queryLen] != 0
        let itemCount = Int(readU16(data, rest + 12 + titleLen + queryLen))
        var items: [GUIPickerItem] = []
        items.reserveCapacity(itemCount)
        var pos = rest + 14 + titleLen + queryLen
        for _ in 0..<itemCount {
            // Per item: icon_color(3) + flags(1) + label_len(2) + label + desc_len(2) + desc + annotation_len(2) + annotation + match_pos_count(1) + positions
            guard data.count >= pos + 6 else { throw ProtocolDecodeError.malformed }
            let iconColor = readU24(data, pos)
            let itemFlags = data[pos + 3]
            let labelLen = Int(readU16(data, pos + 4))
            guard data.count >= pos + 6 + labelLen + 2 else { throw ProtocolDecodeError.malformed }
            let label = String(data: data[(pos + 6)..<(pos + 6 + labelLen)], encoding: .utf8) ?? ""
            let descLen = Int(readU16(data, pos + 6 + labelLen))
            guard data.count >= pos + 8 + labelLen + descLen + 2 else { throw ProtocolDecodeError.malformed }
            let desc = String(data: data[(pos + 8 + labelLen)..<(pos + 8 + labelLen + descLen)], encoding: .utf8) ?? ""
            let annotationLen = Int(readU16(data, pos + 8 + labelLen + descLen))
            guard data.count >= pos + 10 + labelLen + descLen + annotationLen + 1 else { throw ProtocolDecodeError.malformed }
            let annotation = String(data: data[(pos + 10 + labelLen + descLen)..<(pos + 10 + labelLen + descLen + annotationLen)], encoding: .utf8) ?? ""
            let matchPosCount = Int(data[pos + 10 + labelLen + descLen + annotationLen])
            guard data.count >= pos + 11 + labelLen + descLen + annotationLen + matchPosCount * 2 else { throw ProtocolDecodeError.malformed }
            var matchPositions: [UInt16] = []
            matchPositions.reserveCapacity(matchPosCount)
            var mpos = pos + 11 + labelLen + descLen + annotationLen
            for _ in 0..<matchPosCount {
                matchPositions.append(readU16(data, mpos))
                mpos += 2
            }
            items.append(GUIPickerItem(iconColor: UInt32(iconColor), flags: itemFlags, label: label, description: desc, annotation: annotation, matchPositions: matchPositions))
            pos = mpos
        }
        // Parse action menu: visible(1), if visible: selected(1) + count(1) + actions
        var actionMenu: GUIPickerActionMenu? = nil
        guard data.count >= pos + 1 else { throw ProtocolDecodeError.malformed }
        let actionMenuVisible = data[pos] != 0
        pos += 1
        if actionMenuVisible {
            guard data.count >= pos + 2 else { throw ProtocolDecodeError.malformed }
            let actionSelected = data[pos]
            let actionCount = Int(data[pos + 1])
            pos += 2
            var actionNames: [String] = []
            actionNames.reserveCapacity(actionCount)
            for _ in 0..<actionCount {
                guard data.count >= pos + 2 else { throw ProtocolDecodeError.malformed }
                let nameLen = Int(readU16(data, pos))
                guard data.count >= pos + 2 + nameLen else { throw ProtocolDecodeError.malformed }
                let name = String(data: data[(pos + 2)..<(pos + 2 + nameLen)], encoding: .utf8) ?? ""
                actionNames.append(name)
                pos += 2 + nameLen
            }
            actionMenu = GUIPickerActionMenu(selectedIndex: actionSelected, actions: actionNames)
        }
        return (.guiPicker(visible: true, selectedIndex: selectedIndex, filteredCount: filteredCount, totalCount: totalCount, title: title, query: query, hasPreview: hasPreview, items: items, actionMenu: actionMenu), pos - offset)

    case OP_GUI_PICKER_PREVIEW:
        guard data.count >= rest + 1 else { throw ProtocolDecodeError.malformed }
        let visible = data[rest] != 0
        if !visible {
            return (.guiPickerPreview(visible: false, lines: []), 2)
        }
        guard data.count >= rest + 3 else { throw ProtocolDecodeError.malformed }
        let lineCount = Int(readU16(data, rest + 1))
        var lines: [GUIPickerPreviewLine] = []
        lines.reserveCapacity(lineCount)
        var pos2 = rest + 3
        for _ in 0..<lineCount {
            guard data.count >= pos2 + 1 else { throw ProtocolDecodeError.malformed }
            let segCount = Int(data[pos2])
            pos2 += 1
            var segments: GUIPickerPreviewLine = []
            segments.reserveCapacity(segCount)
            for _ in 0..<segCount {
                guard data.count >= pos2 + 6 else { throw ProtocolDecodeError.malformed }
                let fgColor = readU24(data, pos2)
                let segFlags = data[pos2 + 3]
                let textLen = Int(readU16(data, pos2 + 4))
                guard data.count >= pos2 + 6 + textLen else { throw ProtocolDecodeError.malformed }
                let text = String(data: data[(pos2 + 6)..<(pos2 + 6 + textLen)], encoding: .utf8) ?? ""
                segments.append(GUIPickerPreviewSegment(fgColor: UInt32(fgColor), bold: segFlags & 0x01 != 0, text: text))
                pos2 += 6 + textLen
            }
            lines.append(segments)
        }
        return (.guiPickerPreview(visible: true, lines: lines), pos2 - offset)

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
            case 0x08: // styled_tool_call
                // Same header as tool_call (0x04) but result is styled runs instead of plain text.
                // Format: 0x08, status::8, error::8, collapsed::8, duration::32,
                //   name_len::16, name, line_count::16, then per line:
                //   run_count::16, then per run: text_len::16, text, fg::24, bg::24, flags::8
                guard data.count >= pos + 10 else { throw ProtocolDecodeError.malformed }
                let stcStatus = data[pos + 1]
                let stcIsError = data[pos + 2] != 0
                let stcCollapsed = data[pos + 3] != 0
                let stcDuration = readU32(data, pos + 4)
                let stcNameLen = Int(readU16(data, pos + 8))
                guard data.count >= pos + 10 + stcNameLen + 2 else { throw ProtocolDecodeError.malformed }
                let stcName = String(data: data[(pos + 10)..<(pos + 10 + stcNameLen)], encoding: .utf8) ?? ""
                let stcLineCount = Int(readU16(data, pos + 10 + stcNameLen))
                var stcLines: [[StyledTextRun]] = []
                stcLines.reserveCapacity(stcLineCount)
                var stcPos = pos + 12 + stcNameLen
                for _ in 0..<stcLineCount {
                    guard data.count >= stcPos + 2 else { throw ProtocolDecodeError.malformed }
                    let runCount = Int(readU16(data, stcPos))
                    var runs: [StyledTextRun] = []
                    runs.reserveCapacity(runCount)
                    stcPos += 2
                    for _ in 0..<runCount {
                        guard data.count >= stcPos + 9 else { throw ProtocolDecodeError.malformed }
                        let textLen = Int(readU16(data, stcPos))
                        guard data.count >= stcPos + 2 + textLen + 7 else { throw ProtocolDecodeError.malformed }
                        let runText = String(data: data[(stcPos + 2)..<(stcPos + 2 + textLen)], encoding: .utf8) ?? ""
                        let fgOff = stcPos + 2 + textLen
                        runs.append(StyledTextRun(
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
                messages.append(.styledToolCall(name: stcName, status: stcStatus, isError: stcIsError, collapsed: stcCollapsed, durationMs: stcDuration, resultLines: stcLines))
                pos = stcPos
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

    case OP_GUI_CURSORLINE:
        // row:2, r:1, g:1, b:1 = 5 bytes after opcode
        guard data.count >= rest + 5 else { throw ProtocolDecodeError.malformed }
        let row = readU16(data, rest)
        return (.guiCursorline(row: row, r: data[rest + 2], g: data[rest + 3], b: data[rest + 4]), 6)

    case OP_GUI_GUTTER:
        // Per-window format: window_id:2 + content_row:2 + content_col:2 + content_height:2
        // + is_active:1 + cursor_line:4 + style:1 + ln_width:1 + sign_width:1 + line_count:2 = 18 bytes header
        guard data.count >= rest + 18 else { throw ProtocolDecodeError.malformed }
        let windowId = readU16(data, rest)
        let contentRow = readU16(data, rest + 2)
        let contentCol = readU16(data, rest + 4)
        let contentHeight = readU16(data, rest + 6)
        let isActive = data[rest + 8] != 0
        let cursorLine = readU32(data, rest + 9)
        let styleRaw = data[rest + 13]
        let lnWidth = data[rest + 14]
        let signWidth = data[rest + 15]
        let lineCount = Int(readU16(data, rest + 16))
        let style = GUILineNumberStyle(rawValue: styleRaw) ?? .hybrid

        // Each entry is 6 bytes: buf_line:4 + display_type:1 + sign_type:1
        guard data.count >= rest + 18 + lineCount * 6 else { throw ProtocolDecodeError.malformed }
        var entries: [GUIGutterEntry] = []
        entries.reserveCapacity(lineCount)
        for i in 0..<lineCount {
            let base = rest + 18 + i * 6
            let bufLine = readU32(data, base)
            let dt = GUIGutterDisplayType(rawValue: data[base + 4]) ?? .normal
            let st = GUIGutterSignType(rawValue: data[base + 5]) ?? .none
            entries.append(GUIGutterEntry(bufLine: bufLine, displayType: dt, signType: st))
        }
        let windowGutter = GUIWindowGutter(
            windowId: windowId,
            contentRow: contentRow, contentCol: contentCol, contentHeight: contentHeight,
            isActive: isActive, cursorLine: cursorLine, lineNumberStyle: style,
            lineNumberWidth: lnWidth, signColWidth: signWidth, entries: entries
        )
        return (.guiGutter(data: windowGutter), 1 + 18 + lineCount * 6)

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
        var tabs: [GUIBottomPanelTab] = []
        for _ in 0..<tabCount {
            guard data.count >= pos + 2 else { throw ProtocolDecodeError.malformed }
            let tabType = data[pos]
            let nameLen = Int(data[pos + 1])
            pos += 2
            guard data.count >= pos + nameLen else { throw ProtocolDecodeError.malformed }
            let name = String(data: data[pos..<(pos + nameLen)], encoding: .utf8) ?? ""
            pos += nameLen
            tabs.append(GUIBottomPanelTab(tabType: tabType, name: name))
        }
        // Content payload: entry_count(2) + entries...
        var entries: [GUIMessageEntry] = []
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
            entries.append(GUIMessageEntry(id: entryId, level: level, subsystem: subsystem,
                                            timestampSecs: tsSecs, filePath: filePath, text: text))
        }
        return (.guiBottomPanel(visible: true, activeTabIndex: activeTabIndex,
                                 heightPercent: heightPercent, filterPreset: filterPreset,
                                 tabs: tabs, entries: entries), pos - offset)

    case OP_GUI_WINDOW_CONTENT:
        // Header: window_id:2 + flags:1 + cursor_row:2 + cursor_col:2 + cursor_shape:1 + scroll_left:2 + row_count:2 = 12
        guard data.count >= rest + 12 else { throw ProtocolDecodeError.malformed }
        let windowId = readU16(data, rest)
        let flags = data[rest + 2]
        let cursorRow = readU16(data, rest + 3)
        let cursorCol = readU16(data, rest + 5)
        let cursorShape = CursorShape(rawValue: data[rest + 7]) ?? .block
        let scrollLeft = readU16(data, rest + 8)
        let rowCount = Int(readU16(data, rest + 10))
        var pos = rest + 12

        // Decode rows
        var rows: [GUIVisualRow] = []
        rows.reserveCapacity(rowCount)
        for _ in 0..<rowCount {
            // row_type:1 + buf_line:4 + content_hash:4 + text_len:4 = 13
            guard data.count >= pos + 13 else { throw ProtocolDecodeError.malformed }
            let rowType = GUIVisualRowType(rawValue: data[pos]) ?? .normal
            let bufLine = readU32(data, pos + 1)
            let contentHash = readU32(data, pos + 5)
            let textLen = Int(readU32(data, pos + 9))
            pos += 13
            guard data.count >= pos + textLen else { throw ProtocolDecodeError.malformed }
            let text = String(data: data[pos..<(pos + textLen)], encoding: .utf8) ?? ""
            pos += textLen

            // span_count:2
            guard data.count >= pos + 2 else { throw ProtocolDecodeError.malformed }
            let spanCount = Int(readU16(data, pos))
            pos += 2

            // Each span: start_col:2 + end_col:2 + fg:3 + bg:3 + attrs:1 + font_weight:1 + font_id:1 = 13
            var spans: [GUIHighlightSpan] = []
            spans.reserveCapacity(spanCount)
            for _ in 0..<spanCount {
                guard data.count >= pos + 13 else { throw ProtocolDecodeError.malformed }
                let startCol = readU16(data, pos)
                let endCol = readU16(data, pos + 2)
                let fg = readU24(data, pos + 4)
                let bg = readU24(data, pos + 7)
                let attrs = data[pos + 10]
                let fontWeight = data[pos + 11]
                let fontId = data[pos + 12]
                spans.append(GUIHighlightSpan(
                    startCol: startCol, endCol: endCol,
                    fg: fg, bg: bg, attrs: attrs,
                    fontWeight: fontWeight, fontId: fontId
                ))
                pos += 13
            }

            rows.append(GUIVisualRow(
                rowType: rowType, bufLine: bufLine,
                contentHash: contentHash, text: text, spans: spans
            ))
        }

        // Selection: type:1, then if type != 0: start_row:2 + start_col:2 + end_row:2 + end_col:2
        guard data.count >= pos + 1 else { throw ProtocolDecodeError.malformed }
        let selType = data[pos]
        pos += 1
        var selection: GUISelectionOverlay? = nil
        if selType != 0 {
            guard data.count >= pos + 8 else { throw ProtocolDecodeError.malformed }
            selection = GUISelectionOverlay(
                type: GUISelectionType(rawValue: selType) ?? .char,
                startRow: readU16(data, pos),
                startCol: readU16(data, pos + 2),
                endRow: readU16(data, pos + 4),
                endCol: readU16(data, pos + 6)
            )
            pos += 8
        }

        // Search matches: count:2, then per match: row:2 + start_col:2 + end_col:2 + is_current:1 = 7
        guard data.count >= pos + 2 else { throw ProtocolDecodeError.malformed }
        let matchCount = Int(readU16(data, pos))
        pos += 2
        var matches: [GUISearchMatch] = []
        matches.reserveCapacity(matchCount)
        for _ in 0..<matchCount {
            guard data.count >= pos + 7 else { throw ProtocolDecodeError.malformed }
            matches.append(GUISearchMatch(
                row: readU16(data, pos),
                startCol: readU16(data, pos + 2),
                endCol: readU16(data, pos + 4),
                isCurrent: data[pos + 6] != 0
            ))
            pos += 7
        }

        // Diagnostic ranges: count:2, then per range: start_row:2 + start_col:2 + end_row:2 + end_col:2 + severity:1 = 9
        guard data.count >= pos + 2 else { throw ProtocolDecodeError.malformed }
        let diagCount = Int(readU16(data, pos))
        pos += 2
        var diags: [GUIDiagnosticUnderline] = []
        diags.reserveCapacity(diagCount)
        for _ in 0..<diagCount {
            guard data.count >= pos + 9 else { throw ProtocolDecodeError.malformed }
            diags.append(GUIDiagnosticUnderline(
                startRow: readU16(data, pos),
                startCol: readU16(data, pos + 2),
                endRow: readU16(data, pos + 4),
                endCol: readU16(data, pos + 6),
                severity: GUIDiagnosticSeverity(rawValue: data[pos + 8]) ?? .error
            ))
            pos += 9
        }

        // Document highlights: count:2, then per highlight: start_row:2 + start_col:2 + end_row:2 + end_col:2 + kind:1 = 9
        var docHighlights: [GUIDocumentHighlight] = []
        if data.count >= pos + 2 {
            let highlightCount = Int(readU16(data, pos))
            pos += 2
            docHighlights.reserveCapacity(highlightCount)
            for _ in 0..<highlightCount {
                guard data.count >= pos + 9 else { throw ProtocolDecodeError.malformed }
                docHighlights.append(GUIDocumentHighlight(
                    startRow: readU16(data, pos),
                    startCol: readU16(data, pos + 2),
                    endRow: readU16(data, pos + 4),
                    endCol: readU16(data, pos + 6),
                    kind: GUIDocumentHighlightKind(rawValue: data[pos + 8]) ?? .text
                ))
                pos += 9
            }
        }

        let content = GUIWindowContent(
            windowId: windowId,
            fullRefresh: (flags & 0x01) != 0,
            cursorRow: cursorRow,
            cursorCol: cursorCol,
            cursorShape: cursorShape,
            scrollLeft: scrollLeft,
            rows: rows,
            selection: selection,
            searchMatches: matches,
            diagnosticUnderlines: diags,
            documentHighlights: docHighlights
        )
        return (.guiWindowContent(data: content), pos - offset)

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
        var tools: [GUIToolEntry] = []
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
            tools.append(GUIToolEntry(
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
                                    input: "", context: "", selectedIndex: 0, candidates: []), 2)
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
        // selected_index(2) + candidate_count(2)
        guard data.count >= mbPos + 4 else { throw ProtocolDecodeError.malformed }
        let mbSelIndex = readU16(data, mbPos); mbPos += 2
        let mbCandCount = Int(readU16(data, mbPos)); mbPos += 2
        // candidates
        var mbCandidates: [GUIMinibufferCandidate] = []
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
            mbCandidates.append(GUIMinibufferCandidate(matchScore: score, label: candLabel, description: candDesc))
        }
        return (.guiMinibuffer(visible: true, mode: mbMode, cursorPos: mbCursorPos,
                                prompt: mbPrompt, input: mbInput, context: mbContext,
                                selectedIndex: mbSelIndex, candidates: mbCandidates), mbPos - offset)

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
        var hLines: [GUIHoverLine] = []
        hLines.reserveCapacity(hLineCount)
        for _ in 0..<hLineCount {
            // line_type(1) + segment_count(2)
            guard data.count >= hPos + 3 else { break }
            let lineType = GUIHoverLineType(rawValue: data[hPos]) ?? .text
            let segCount = Int(readU16(data, hPos + 1))
            hPos += 3
            var segments: [GUIHoverSegment] = []
            segments.reserveCapacity(segCount)
            for _ in 0..<segCount {
                // style(1) + text_len(2) + text
                guard data.count >= hPos + 3 else { break }
                let style = GUIHoverStyle(rawValue: data[hPos]) ?? .plain
                let textLen = Int(readU16(data, hPos + 1))
                hPos += 3
                guard data.count >= hPos + textLen else { break }
                let text = String(data: data[hPos..<(hPos + textLen)], encoding: .utf8) ?? ""
                hPos += textLen
                segments.append(GUIHoverSegment(style: style, text: text))
            }
            hLines.append(GUIHoverLine(lineType: lineType, segments: segments))
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
        var signatures: [GUISignature] = []
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
            var params: [GUISignatureParameter] = []
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
                params.append(GUISignatureParameter(label: pLabel, documentation: pDoc))
            }
            signatures.append(GUISignature(label: label, documentation: doc, parameters: params))
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
        var verts: [GUIVerticalSeparator] = []
        verts.reserveCapacity(vertCount)
        for _ in 0..<vertCount {
            // col(2) + start_row(2) + end_row(2)
            guard data.count >= sepPos + 6 else { throw ProtocolDecodeError.malformed }
            let col = readU16(data, sepPos)
            let startRow = readU16(data, sepPos + 2)
            let endRow = readU16(data, sepPos + 4)
            sepPos += 6
            verts.append(GUIVerticalSeparator(col: col, startRow: startRow, endRow: endRow))
        }
        // horizontal_count(1)
        guard data.count >= sepPos + 1 else { throw ProtocolDecodeError.malformed }
        let horizCount = Int(data[sepPos]); sepPos += 1
        var horizs: [GUIHorizontalSeparator] = []
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
            horizs.append(GUIHorizontalSeparator(row: hRow, col: hCol, width: hWidth, filename: fn))
        }
        return (.guiSplitSeparators(borderColor: sepColor, verticals: verts, horizontals: horizs),
                sepPos - offset)

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
