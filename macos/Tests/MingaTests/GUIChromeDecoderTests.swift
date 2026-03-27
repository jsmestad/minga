/// Protocol decoder tests for all GUI chrome opcodes (0x70-0x7E).
///
/// These verify that the Swift decoder correctly parses binary payloads
/// matching the BEAM's wire format. Each test builds a binary payload,
/// decodes it, and asserts field values.
///
/// Pattern follows WindowContentTests.swift. No @testable import needed
/// because Sources are compiled directly into the test target.

import Testing
import Foundation

// MARK: - Binary builder helpers

/// Appends a big-endian UInt16 to a Data buffer.
private func appendU16(_ data: inout Data, _ value: UInt16) {
    data.append(UInt8(value >> 8))
    data.append(UInt8(value & 0xFF))
}

/// Appends a big-endian UInt32 to a Data buffer.
private func appendU32(_ data: inout Data, _ value: UInt32) {
    data.append(UInt8((value >> 24) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
}

/// Appends a length-prefixed UTF-8 string with a UInt16 length prefix.
private func appendString16(_ data: inout Data, _ string: String) {
    let utf8 = Array(string.utf8)
    appendU16(&data, UInt16(utf8.count))
    data.append(contentsOf: utf8)
}

/// Appends a length-prefixed UTF-8 string with a UInt8 length prefix.
private func appendString8(_ data: inout Data, _ string: String) {
    let utf8 = Array(string.utf8)
    data.append(UInt8(utf8.count))
    data.append(contentsOf: utf8)
}

/// Appends 3 bytes of RGB color.
private func appendRGB(_ data: inout Data, _ r: UInt8, _ g: UInt8, _ b: UInt8) {
    data.append(r)
    data.append(g)
    data.append(b)
}

// MARK: - Section builder helper (shared by all sectioned format tests)

/// Builds a section envelope: id(1) + len(2, big-endian) + payload
private func buildSectionData(_ id: UInt8, _ payload: Data) -> Data {
    var section = Data()
    section.append(id)
    appendU16(&section, UInt16(payload.count))
    section.append(payload)
    return section
}

// MARK: - gui_theme (0x74)

@Suite("GUI Theme Decoder")
struct GUIThemeDecoderTests {
    @Test("Decode gui_theme with 3 color slots")
    func decodeThemeSlots() throws {
        var data = Data()
        data.append(OP_GUI_THEME)
        data.append(3) // count
        // Slot 0x01 (editor_bg): r=0x28, g=0x2C, b=0x34
        data.append(contentsOf: [0x01, 0x28, 0x2C, 0x34])
        // Slot 0x02 (editor_fg): r=0xBB, g=0xC2, b=0xCF
        data.append(contentsOf: [0x02, 0xBB, 0xC2, 0xCF])
        // Slot 0x40 (accent): r=0x51, g=0xAF, b=0xEF
        data.append(contentsOf: [0x40, 0x51, 0xAF, 0xEF])

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 1 + 1 + 3 * 4)

        guard case .guiTheme(let slots) = cmd else {
            Issue.record("Expected .guiTheme, got \(String(describing: cmd))")
            return
        }

        #expect(slots.count == 3)
        #expect(slots[0].slotId == 0x01)
        #expect(slots[0].r == 0x28)
        #expect(slots[0].g == 0x2C)
        #expect(slots[0].b == 0x34)
        #expect(slots[1].slotId == 0x02)
        #expect(slots[2].slotId == 0x40)
        #expect(slots[2].r == 0x51)
    }

    @Test("Decode gui_theme with zero slots")
    func decodeThemeEmpty() throws {
        var data = Data()
        data.append(OP_GUI_THEME)
        data.append(0) // count

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 2)

        guard case .guiTheme(let slots) = cmd else {
            Issue.record("Expected .guiTheme"); return
        }
        #expect(slots.isEmpty)
    }
}

// MARK: - gui_tab_bar (0x71)

@Suite("GUI Tab Bar Decoder")
struct GUITabBarDecoderTests {
    @Test("Decode gui_tab_bar with 2 tabs")
    func decodeTwoTabs() throws {
        var data = Data()
        data.append(OP_GUI_TAB_BAR)
        data.append(0) // active_index
        data.append(2) // tab_count

        // Tab 1: active, dirty, file tab, workspace 0
        let flags1: UInt8 = 0x01 | 0x02 // active + dirty
        data.append(flags1)
        appendU32(&data, 42) // id
        appendU16(&data, 0) // group_id (manual workspace)
        appendString8(&data, "") // icon (Nerd Font, can be multi-byte)
        appendString16(&data, "editor.ex")

        // Tab 2: agent tab, has attention, workspace 1
        let flags2: UInt8 = 0x04 | 0x08 | (1 << 4) // agent + attention + agentStatus=1
        data.append(flags2)
        appendU32(&data, 99) // id
        appendU16(&data, 1) // group_id (agent workspace)
        appendString8(&data, "")
        appendString16(&data, "Agent")

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiTabBar(let activeIndex, let tabs) = cmd else {
            Issue.record("Expected .guiTabBar, got \(String(describing: cmd))")
            return
        }

        #expect(activeIndex == 0)
        #expect(tabs.count == 2)
        #expect(tabs[0].id == 42)
        #expect(tabs[0].groupId == 0)
        #expect(tabs[0].isActive == true)
        #expect(tabs[0].isDirty == true)
        #expect(tabs[0].isAgent == false)
        #expect(tabs[0].label == "editor.ex")
        #expect(tabs[1].id == 99)
        #expect(tabs[1].groupId == 1)
        #expect(tabs[1].isAgent == true)
        #expect(tabs[1].hasAttention == true)
        #expect(tabs[1].agentStatus == 1)
        #expect(tabs[1].label == "Agent")
    }

    @Test("Decode gui_tab_bar with zero tabs")
    func decodeEmptyTabBar() throws {
        var data = Data()
        data.append(OP_GUI_TAB_BAR)
        data.append(0) // active_index
        data.append(0) // tab_count

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 3)

        guard case .guiTabBar(_, let tabs) = cmd else {
            Issue.record("Expected .guiTabBar"); return
        }
        #expect(tabs.isEmpty)
    }
}

// MARK: - gui_completion (0x73)

@Suite("GUI Completion Decoder")
struct GUICompletionDecoderTests {
    @Test("Decode gui_completion visible with items")
    func decodeVisible() throws {
        var data = Data()
        data.append(OP_GUI_COMPLETION)
        data.append(1) // visible
        appendU16(&data, 5) // anchorRow
        appendU16(&data, 10) // anchorCol
        appendU16(&data, 0) // selectedIndex
        appendU16(&data, 2) // itemCount

        // Item 1
        data.append(1) // kind
        appendString16(&data, "def") // label
        appendString16(&data, "keyword") // detail

        // Item 2
        data.append(6) // kind (variable)
        appendString16(&data, "my_var") // label
        appendString16(&data, "String.t()") // detail

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiCompletion(let visible, let anchorRow, let anchorCol, let selectedIndex, let items) = cmd else {
            Issue.record("Expected .guiCompletion"); return
        }

        #expect(visible == true)
        #expect(anchorRow == 5)
        #expect(anchorCol == 10)
        #expect(selectedIndex == 0)
        #expect(items.count == 2)
        #expect(items[0].kind == 1)
        #expect(items[0].label == "def")
        #expect(items[0].detail == "keyword")
        #expect(items[1].label == "my_var")
        #expect(items[1].detail == "String.t()")
    }

    @Test("Decode gui_completion hidden")
    func decodeHidden() throws {
        let data = Data([OP_GUI_COMPLETION, 0])

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 2)

        guard case .guiCompletion(let visible, _, _, _, let items) = cmd else {
            Issue.record("Expected .guiCompletion"); return
        }
        #expect(visible == false)
        #expect(items.isEmpty)
    }
}

// MARK: - gui_which_key (0x72)

@Suite("GUI Which Key Decoder")
struct GUIWhichKeyDecoderTests {
    @Test("Decode gui_which_key visible with bindings")
    func decodeVisible() throws {
        var data = Data()
        data.append(OP_GUI_WHICH_KEY)
        data.append(1) // visible
        appendString16(&data, "SPC") // prefix
        data.append(0) // page
        data.append(2) // pageCount
        appendU16(&data, 2) // bindingCount

        // Binding 1: command
        data.append(0) // kind=command
        appendString8(&data, "f") // key
        appendString16(&data, "Find file") // description
        appendString8(&data, "🔍") // icon

        // Binding 2: group
        data.append(1) // kind=group
        appendString8(&data, "b") // key
        appendString16(&data, "Buffers") // description
        appendString8(&data, "") // icon (empty)

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiWhichKey(let visible, let prefix, let page, let pageCount, let bindings) = cmd else {
            Issue.record("Expected .guiWhichKey"); return
        }

        #expect(visible == true)
        #expect(prefix == "SPC")
        #expect(page == 0)
        #expect(pageCount == 2)
        #expect(bindings.count == 2)
        #expect(bindings[0].kind == 0) // command
        #expect(bindings[0].key == "f")
        #expect(bindings[0].description == "Find file")
        #expect(bindings[1].kind == 1) // group
        #expect(bindings[1].key == "b")
        #expect(bindings[1].description == "Buffers")
    }

    @Test("Decode gui_which_key hidden")
    func decodeHidden() throws {
        let data = Data([OP_GUI_WHICH_KEY, 0])

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 2)

        guard case .guiWhichKey(let visible, _, _, _, let bindings) = cmd else {
            Issue.record("Expected .guiWhichKey"); return
        }
        #expect(visible == false)
        #expect(bindings.isEmpty)
    }
}

// MARK: - gui_breadcrumb (0x75)

@Suite("GUI Breadcrumb Decoder")
struct GUIBreadcrumbDecoderTests {
    @Test("Decode gui_breadcrumb with path segments")
    func decodeSegments() throws {
        var data = Data()
        data.append(OP_GUI_BREADCRUMB)
        data.append(3) // segCount
        appendString16(&data, "lib")
        appendString16(&data, "minga")
        appendString16(&data, "editor.ex")

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiBreadcrumb(let segments) = cmd else {
            Issue.record("Expected .guiBreadcrumb"); return
        }
        #expect(segments == ["lib", "minga", "editor.ex"])
    }

    @Test("Decode gui_breadcrumb with zero segments")
    func decodeEmpty() throws {
        let data = Data([OP_GUI_BREADCRUMB, 0])

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 2)

        guard case .guiBreadcrumb(let segments) = cmd else {
            Issue.record("Expected .guiBreadcrumb"); return
        }
        #expect(segments.isEmpty)
    }
}

// MARK: - gui_status_bar (0x76)

@Suite("GUI Status Bar Decoder")
struct GUIStatusBarDecoderTests {

    /// Builds a section: id(1) + len(2) + payload
    private func buildSection(_ id: UInt8, _ payload: Data) -> Data {
        var section = Data()
        section.append(id)
        appendU16(&section, UInt16(payload.count))
        section.append(payload)
        return section
    }

    @Test("Decode gui_status_bar buffer variant (sectioned format)")
    func decodeBufferVariant() throws {
        var identity = Data()
        identity.append(0) // contentKind = buffer
        identity.append(1) // mode = insert
        identity.append(0x03) // flags

        var cursor = Data()
        appendU32(&cursor, 42) // cursorLine
        appendU32(&cursor, 9) // cursorCol
        appendU32(&cursor, 500) // lineCount

        var diagnostics = Data()
        appendU16(&diagnostics, 3) // errorCount
        appendU16(&diagnostics, 7) // warningCount
        appendU16(&diagnostics, 1) // infoCount
        appendU16(&diagnostics, 2) // hintCount
        appendString16(&diagnostics, "") // diagnosticHint

        var language = Data()
        language.append(1) // lspStatus = ready
        language.append(1) // parserStatus

        var git = Data()
        appendString8(&git, "main") // gitBranch
        appendU16(&git, 5) // gitAdded
        appendU16(&git, 3) // gitModified
        appendU16(&git, 1) // gitDeleted

        var file = Data()
        appendString8(&file, "") // icon
        file.append(0); file.append(0); file.append(0) // icon color
        appendString16(&file, "editor.ex") // filename
        appendString8(&file, "elixir") // filetype

        var msg = Data()
        appendString16(&msg, "-- INSERT --")

        var recording = Data()
        recording.append(0) // macroRecording

        var agent = Data()
        agent.append(0) // agentStatus (buffer variant: just 1 byte)

        let sections = [
            buildSection(SECTION_IDENTITY, identity),
            buildSection(SECTION_CURSOR, cursor),
            buildSection(SECTION_DIAGNOSTICS, diagnostics),
            buildSection(SECTION_LANGUAGE, language),
            buildSection(SECTION_GIT, git),
            buildSection(SECTION_FILE, file),
            buildSection(SECTION_MESSAGE, msg),
            buildSection(SECTION_RECORDING, recording),
            buildSection(SECTION_AGENT, agent),
        ]

        var data = Data()
        data.append(OP_GUI_STATUS_BAR)
        data.append(UInt8(sections.count)) // section_count
        for s in sections { data.append(s) }

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiStatusBar(let contentKind, let mode, let cursorLine, let cursorCol,
                                  let lineCount, let flags, let lspStatus, let gitBranch,
                                  let message, let filetype, let errorCount, let warningCount,
                                  _, _, _,
                                  let infoCount, let hintCount, let macroRecording,
                                  let parserStatus, let agentStatus,
                                  let gitAdded, let gitModified, let gitDeleted,
                                  _, _, _, _, let filename, _) = cmd else {
            Issue.record("Expected .guiStatusBar"); return
        }

        #expect(contentKind == 0)
        #expect(mode == 1)
        #expect(cursorLine == 42)
        #expect(cursorCol == 9)
        #expect(lineCount == 500)
        #expect(flags == 0x03)
        #expect(lspStatus == 1)
        #expect(gitBranch == "main")
        #expect(message == "-- INSERT --")
        #expect(filetype == "elixir")
        #expect(errorCount == 3)
        #expect(warningCount == 7)
        #expect(infoCount == 1)
        #expect(hintCount == 2)
        #expect(macroRecording == 0)
        #expect(parserStatus == 1)
        #expect(agentStatus == 0)
        #expect(gitAdded == 5)
        #expect(gitModified == 3)
        #expect(gitDeleted == 1)
        #expect(filename == "editor.ex")
    }

    @Test("Decode gui_status_bar agent variant (sectioned format)")
    func decodeAgentVariant() throws {
        var identity = Data()
        identity.append(1) // contentKind = agent
        identity.append(0) // mode = normal
        identity.append(0x03) // flags

        var cursor = Data()
        appendU32(&cursor, 11)
        appendU32(&cursor, 6)
        appendU32(&cursor, 100)

        var diagnostics = Data()
        appendU16(&diagnostics, 1) // errorCount
        appendU16(&diagnostics, 2) // warningCount
        appendU16(&diagnostics, 0) // infoCount
        appendU16(&diagnostics, 1) // hintCount
        appendString16(&diagnostics, "")

        var language = Data()
        language.append(1) // lspStatus
        language.append(0) // parserStatus

        var git = Data()
        appendString8(&git, "feat/agent")
        appendU16(&git, 3)
        appendU16(&git, 2)
        appendU16(&git, 0)

        var file = Data()
        appendString8(&file, "")
        file.append(0); file.append(0); file.append(0)
        appendString16(&file, "editor.ex")
        appendString8(&file, "elixir")

        var msg = Data()
        appendString16(&msg, "")

        var recording = Data()
        recording.append(0)

        // Agent section: model_name_len(1) + model_name + message_count(4) + session_status(1) + agent_status(1)
        var agent = Data()
        appendString8(&agent, "claude-3-5-sonnet")
        appendU32(&agent, 12) // messageCount
        agent.append(1) // sessionStatus
        agent.append(1) // agentStatus

        let sections = [
            buildSection(SECTION_IDENTITY, identity),
            buildSection(SECTION_CURSOR, cursor),
            buildSection(SECTION_DIAGNOSTICS, diagnostics),
            buildSection(SECTION_LANGUAGE, language),
            buildSection(SECTION_GIT, git),
            buildSection(SECTION_FILE, file),
            buildSection(SECTION_MESSAGE, msg),
            buildSection(SECTION_RECORDING, recording),
            buildSection(SECTION_AGENT, agent),
        ]

        var data = Data()
        data.append(OP_GUI_STATUS_BAR)
        data.append(UInt8(sections.count))
        for s in sections { data.append(s) }

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiStatusBar(let contentKind, _, let cursorLine, _, let lineCount, _, _, let gitBranch, _, let filetype, let errorCount, _, let modelName, let messageCount, let sessionStatus, _, let hintCount, _, _, let agentStatus, let gitAdded, let gitModified, _, _, _, _, _, let filename, _) = cmd else {
            Issue.record("Expected .guiStatusBar"); return
        }

        #expect(contentKind == 1)
        #expect(modelName == "claude-3-5-sonnet")
        #expect(messageCount == 12)
        #expect(sessionStatus == 1)
        #expect(cursorLine == 11)
        #expect(lineCount == 100)
        #expect(gitBranch == "feat/agent")
        #expect(filetype == "elixir")
        #expect(errorCount == 1)
        #expect(hintCount == 1)
        #expect(agentStatus == 1)
        #expect(gitAdded == 3)
        #expect(gitModified == 2)
        #expect(filename == "editor.ex")
    }

    @Test("Unknown sections are skipped (forward compatibility)")
    func skipUnknownSections() throws {
        // Build a status bar with an unknown section 0xFF between known sections
        var identity = Data()
        identity.append(0); identity.append(0); identity.append(0)

        var unknown = Data([0xDE, 0xAD, 0xBE, 0xEF])

        var cursor = Data()
        appendU32(&cursor, 10)
        appendU32(&cursor, 5)
        appendU32(&cursor, 200)

        let sections = [
            buildSection(SECTION_IDENTITY, identity),
            buildSection(0xFF, unknown), // unknown section
            buildSection(SECTION_CURSOR, cursor),
        ]

        var data = Data()
        data.append(OP_GUI_STATUS_BAR)
        data.append(UInt8(sections.count))
        for s in sections { data.append(s) }

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiStatusBar(_, _, let cursorLine, let cursorCol, let lineCount, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _) = cmd else {
            Issue.record("Expected .guiStatusBar"); return
        }

        #expect(cursorLine == 10)
        #expect(cursorCol == 5)
        #expect(lineCount == 200)
    }

    @Test("Missing sections use defaults")
    func missingSectionsDefaults() throws {
        // Only send identity section, all others missing
        var identity = Data()
        identity.append(0); identity.append(2); identity.append(0) // mode=visual

        var data = Data()
        data.append(OP_GUI_STATUS_BAR)
        data.append(1) // only 1 section
        data.append(contentsOf: buildSection(SECTION_IDENTITY, identity))

        let (cmd, _) = try decodeCommand(data: data, offset: 0)

        guard case .guiStatusBar(let contentKind, let mode, let cursorLine, _, _, _, _, let gitBranch, _, _, let errorCount, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _) = cmd else {
            Issue.record("Expected .guiStatusBar"); return
        }

        #expect(contentKind == 0)
        #expect(mode == 2) // visual
        #expect(cursorLine == 0) // default
        #expect(gitBranch == "") // default
        #expect(errorCount == 0) // default
    }
}

// MARK: - gui_gutter_sep (0x79)

@Suite("GUI Gutter Separator Decoder")
struct GUIGutterSepDecoderTests {
    @Test("Decode gui_gutter_sep")
    func decodeGutterSep() throws {
        var data = Data()
        data.append(OP_GUI_GUTTER_SEP)
        appendU16(&data, 4) // col
        appendRGB(&data, 0x3F, 0x44, 0x4A)

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 6)

        guard case .guiGutterSeparator(let col, let r, let g, let b) = cmd else {
            Issue.record("Expected .guiGutterSeparator"); return
        }
        #expect(col == 4)
        #expect(r == 0x3F)
        #expect(g == 0x44)
        #expect(b == 0x4A)
    }
}

// MARK: - gui_cursorline (0x7A)

@Suite("GUI Cursorline Decoder")
struct GUICursorlineDecoderTests {
    @Test("Decode gui_cursorline")
    func decodeCursorline() throws {
        var data = Data()
        data.append(OP_GUI_CURSORLINE)
        appendU16(&data, 12) // row
        appendRGB(&data, 0x2C, 0x32, 0x3C)

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 6)

        guard case .guiCursorline(let row, let r, let g, let b) = cmd else {
            Issue.record("Expected .guiCursorline"); return
        }
        #expect(row == 12)
        #expect(r == 0x2C)
        #expect(g == 0x32)
        #expect(b == 0x3C)
    }
}

// MARK: - gui_file_tree (0x70)

@Suite("GUI File Tree Decoder")
struct GUIFileTreeDecoderTests {
    @Test("Decode gui_file_tree with entries")
    func decodeWithEntries() throws {
        var data = Data()
        data.append(OP_GUI_FILE_TREE)
        appendU16(&data, 1) // selectedIndex
        appendU16(&data, 30) // treeWidth
        appendU16(&data, 2) // entryCount
        appendString16(&data, "/home/user/project") // rootPath

        // Entry 1: directory, expanded, selected
        appendU32(&data, 0xAABBCCDD) // pathHash
        data.append(0x01 | 0x02 | 0x04) // flags: isDir + isExpanded + isSelected
        data.append(0) // depth
        data.append(0) // gitStatus
        appendString8(&data, "") // icon
        appendString16(&data, "lib") // name
        appendString16(&data, "lib") // relPath

        // Entry 2: file, git modified
        appendU32(&data, 0x11223344) // pathHash
        data.append(0) // flags: none
        data.append(1) // depth
        data.append(1) // gitStatus = modified
        appendString8(&data, "") // icon
        appendString16(&data, "editor.ex") // name
        appendString16(&data, "lib/editor.ex") // relPath

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiFileTree(let selectedIndex, let treeWidth, let rootPath, let entries) = cmd else {
            Issue.record("Expected .guiFileTree"); return
        }

        #expect(selectedIndex == 1)
        #expect(treeWidth == 30)
        #expect(rootPath == "/home/user/project")
        #expect(entries.count == 2)
        #expect(entries[0].pathHash == 0xAABBCCDD)
        #expect(entries[0].isDir == true)
        #expect(entries[0].isExpanded == true)
        #expect(entries[0].isSelected == true)
        #expect(entries[0].name == "lib")
        #expect(entries[1].depth == 1)
        #expect(entries[1].gitStatus == 1)
        #expect(entries[1].name == "editor.ex")
        #expect(entries[1].relPath == "lib/editor.ex")
    }

    @Test("Decode gui_file_tree empty (hide)")
    func decodeEmpty() throws {
        var data = Data()
        data.append(OP_GUI_FILE_TREE)
        appendU16(&data, 0)
        appendU16(&data, 0)
        appendU16(&data, 0)
        appendString16(&data, "")

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiFileTree(_, _, _, let entries) = cmd else {
            Issue.record("Expected .guiFileTree"); return
        }
        #expect(entries.isEmpty)
    }
}

// MARK: - gui_gutter (0x7B)

@Suite("GUI Gutter Decoder")
struct GUIGutterDecoderTests {
    @Test("Decode gui_gutter with entries (sectioned)")
    func decodeGutter() throws {
        // Section 0x01: Window
        var window = Data()
        appendU16(&window, 1) // windowId
        appendU16(&window, 0) // contentRow
        appendU16(&window, 5) // contentCol
        appendU16(&window, 24) // contentHeight
        window.append(1) // isActive

        // Section 0x02: Config
        var config = Data()
        appendU32(&config, 10) // cursorLine
        config.append(0) // lineNumberStyle = hybrid
        config.append(4) // lineNumberWidth
        config.append(1) // signColWidth

        // Section 0x03: Entries
        var entries = Data()
        appendU16(&entries, 3) // entry count
        // Entry 1
        appendU32(&entries, 8); entries.append(0); entries.append(1) // normal, gitAdded
        // Entry 2
        appendU32(&entries, 9); entries.append(1); entries.append(0) // foldStart, none
        // Entry 3
        appendU32(&entries, 10); entries.append(3); entries.append(4) // wrapContinuation, diagError

        var data = Data()
        data.append(OP_GUI_GUTTER)
        data.append(3) // section_count
        data.append(contentsOf: buildSectionData(0x01, window))
        data.append(contentsOf: buildSectionData(0x02, config))
        data.append(contentsOf: buildSectionData(0x03, entries))

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiGutter(let gutterData) = cmd else {
            Issue.record("Expected .guiGutter"); return
        }

        #expect(gutterData.windowId == 1)
        #expect(gutterData.contentCol == 5)
        #expect(gutterData.contentHeight == 24)
        #expect(gutterData.isActive == true)
        #expect(gutterData.cursorLine == 10)
        #expect(gutterData.lineNumberStyle == .hybrid)
        #expect(gutterData.lineNumberWidth == 4)
        #expect(gutterData.signColWidth == 1)
        #expect(gutterData.entries.count == 3)
        #expect(gutterData.entries[0].bufLine == 8)
        #expect(gutterData.entries[0].signType == .gitAdded)
        #expect(gutterData.entries[1].displayType == .foldStart)
        #expect(gutterData.entries[2].displayType == .wrapContinuation)
        #expect(gutterData.entries[2].signType == .diagError)
    }
}

// MARK: - gui_bottom_panel (0x7C)

@Suite("GUI Bottom Panel Decoder")
struct GUIBottomPanelDecoderTests {
    @Test("Decode gui_bottom_panel visible with tabs and entries")
    func decodeVisible() throws {
        var data = Data()
        data.append(OP_GUI_BOTTOM_PANEL)
        data.append(1) // visible
        data.append(0) // activeTabIndex
        data.append(30) // heightPercent
        data.append(0) // filterPreset
        data.append(1) // tabCount

        // Tab: Messages
        data.append(0) // tabType
        appendString8(&data, "Messages")

        // Entries
        appendU16(&data, 1) // entryCount

        // Entry 1
        appendU32(&data, 42) // id
        data.append(1) // level = info
        data.append(0) // subsystem = editor
        appendU32(&data, 3661) // timestampSecs (1:01:01)
        appendString16(&data, "lib/minga/editor.ex") // filePath
        appendString16(&data, "File opened: editor.ex") // text

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiBottomPanel(let visible, let activeTabIndex, let heightPercent, let filterPreset, let tabs, let entries) = cmd else {
            Issue.record("Expected .guiBottomPanel"); return
        }

        #expect(visible == true)
        #expect(activeTabIndex == 0)
        #expect(heightPercent == 30)
        #expect(filterPreset == 0)
        #expect(tabs.count == 1)
        #expect(tabs[0].name == "Messages")
        #expect(entries.count == 1)
        #expect(entries[0].id == 42)
        #expect(entries[0].level == 1)
        #expect(entries[0].subsystem == 0)
        #expect(entries[0].timestampSecs == 3661)
        #expect(entries[0].text == "File opened: editor.ex")
    }

    @Test("Decode gui_bottom_panel hidden")
    func decodeHidden() throws {
        let data = Data([OP_GUI_BOTTOM_PANEL, 0])

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 2)

        guard case .guiBottomPanel(let visible, _, _, _, _, _) = cmd else {
            Issue.record("Expected .guiBottomPanel"); return
        }
        #expect(visible == false)
    }
}

// MARK: - gui_picker (0x77)

@Suite("GUI Picker Decoder")
struct GUIPickerDecoderTests {
    @Test("Decode gui_picker visible with items and action menu (sectioned)")
    func decodeVisible() throws {
        // Section 0x01: Header
        var header = Data()
        header.append(1) // visible
        appendU16(&header, 0) // selectedIndex
        appendU16(&header, 5) // filteredCount
        appendU16(&header, 100) // totalCount
        header.append(1) // hasPreview
        appendString16(&header, "Find File") // title

        // Section 0x02: Query
        var query = Data()
        appendString16(&query, "edi")

        // Section 0x03: Items
        var items = Data()
        appendU16(&items, 2) // itemCount
        // Item 1
        appendRGB(&items, 0x51, 0xAF, 0xEF)
        items.append(0x01) // two_line
        appendString16(&items, "editor.ex")
        appendString16(&items, "lib/minga/editor.ex")
        appendString16(&items, "500 lines")
        items.append(2); appendU16(&items, 0); appendU16(&items, 1)
        // Item 2
        appendRGB(&items, 0x98, 0xBE, 0x65)
        items.append(0x02) // marked
        appendString16(&items, "edit_delta.ex")
        appendString16(&items, "lib/minga/buffer/edit_delta.ex")
        appendString16(&items, "")
        items.append(0)

        // Section 0x04: Action menu
        var actionMenu = Data()
        actionMenu.append(1) // visible
        actionMenu.append(0) // selected
        actionMenu.append(2) // count
        appendString16(&actionMenu, "Open")
        appendString16(&actionMenu, "Split Right")

        var data = Data()
        data.append(OP_GUI_PICKER)
        data.append(4) // section_count
        data.append(contentsOf: buildSectionData(0x01, header))
        data.append(contentsOf: buildSectionData(0x02, query))
        data.append(contentsOf: buildSectionData(0x03, items))
        data.append(contentsOf: buildSectionData(0x04, actionMenu))

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiPicker(let visible, let selectedIndex, let filteredCount, let totalCount, let title, let q, let hasPreview, let decodedItems, let decodedMenu) = cmd else {
            Issue.record("Expected .guiPicker"); return
        }

        #expect(visible == true)
        #expect(selectedIndex == 0)
        #expect(filteredCount == 5)
        #expect(totalCount == 100)
        #expect(title == "Find File")
        #expect(q == "edi")
        #expect(hasPreview == true)
        #expect(decodedItems.count == 2)
        #expect(decodedItems[0].label == "editor.ex")
        #expect(decodedItems[0].isTwoLine == true)
        #expect(decodedItems[0].matchPositions == [0, 1])
        #expect(decodedItems[1].label == "edit_delta.ex")
        #expect(decodedItems[1].isMarked == true)

        #expect(decodedMenu != nil)
        #expect(decodedMenu?.actions == ["Open", "Split Right"])
    }

    @Test("Decode gui_picker hidden")
    func decodeHidden() throws {
        let data = Data([OP_GUI_PICKER, 0])

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 2)

        guard case .guiPicker(let visible, _, _, _, _, _, _, let items, let actionMenu) = cmd else {
            Issue.record("Expected .guiPicker"); return
        }
        #expect(visible == false)
        #expect(items.isEmpty)
        #expect(actionMenu == nil)
    }

    @Test("Decode gui_picker visible without action menu (sectioned)")
    func decodeNoActionMenu() throws {
        var header = Data()
        header.append(1) // visible
        appendU16(&header, 0); appendU16(&header, 0); appendU16(&header, 0)
        header.append(0) // hasPreview
        appendString16(&header, "")

        var query = Data()
        appendString16(&query, "")

        var items = Data()
        appendU16(&items, 0)

        var actionMenu = Data()
        actionMenu.append(0) // not visible

        var data = Data()
        data.append(OP_GUI_PICKER)
        data.append(4)
        data.append(contentsOf: buildSectionData(0x01, header))
        data.append(contentsOf: buildSectionData(0x02, query))
        data.append(contentsOf: buildSectionData(0x03, items))
        data.append(contentsOf: buildSectionData(0x04, actionMenu))

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiPicker(let visible, _, _, _, _, _, _, _, let am) = cmd else {
            Issue.record("Expected .guiPicker"); return
        }
        #expect(visible == true)
        #expect(am == nil)
    }
}

// MARK: - gui_picker_preview (0x7D)

@Suite("GUI Picker Preview Decoder")
struct GUIPickerPreviewDecoderTests {
    @Test("Decode gui_picker_preview visible with styled lines")
    func decodeVisible() throws {
        var data = Data()
        data.append(OP_GUI_PICKER_PREVIEW)
        data.append(1) // visible
        appendU16(&data, 2) // lineCount

        // Line 1: 2 segments
        data.append(2) // segCount
        appendRGB(&data, 0x51, 0xAF, 0xEF) // fgColor
        data.append(0x01) // flags = bold
        appendString16(&data, "def ") // text
        appendRGB(&data, 0xEC, 0xBE, 0x7B) // fgColor
        data.append(0x00) // flags
        appendString16(&data, "hello") // text

        // Line 2: 1 segment
        data.append(1) // segCount
        appendRGB(&data, 0xBB, 0xC2, 0xCF)
        data.append(0x00)
        appendString16(&data, "  :ok")

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiPickerPreview(let visible, let lines) = cmd else {
            Issue.record("Expected .guiPickerPreview"); return
        }

        #expect(visible == true)
        #expect(lines.count == 2)
        #expect(lines[0].count == 2) // 2 segments
        #expect(lines[0][0].text == "def ")
        #expect(lines[0][0].bold == true)
        #expect(lines[0][0].fgColor == 0x51AFEF)
        #expect(lines[0][1].text == "hello")
        #expect(lines[0][1].bold == false)
        #expect(lines[1].count == 1)
        #expect(lines[1][0].text == "  :ok")
    }

    @Test("Decode gui_picker_preview hidden")
    func decodeHidden() throws {
        let data = Data([OP_GUI_PICKER_PREVIEW, 0])

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 2)

        guard case .guiPickerPreview(let visible, let lines) = cmd else {
            Issue.record("Expected .guiPickerPreview"); return
        }
        #expect(visible == false)
        #expect(lines.isEmpty)
    }
}

// MARK: - gui_agent_chat (0x78)

@Suite("GUI Agent Chat Decoder")
struct GUIAgentChatDecoderTests {

    /// Builds a sectioned agent chat command from individual section payloads.
    private func buildChatData(status: UInt8 = 0, model: String = "", prompt: String = "",
                                pending: Data? = nil, help: Data? = nil, messages: Data? = nil) -> Data {
        var headerPayload = Data()
        headerPayload.append(1) // visible
        headerPayload.append(status)

        var modelPayload = Data()
        appendString16(&modelPayload, model)

        var promptPayload = Data()
        appendString16(&promptPayload, prompt)

        let pendingPayload = pending ?? Data([0]) // no pending
        let helpPayload = help ?? Data([0]) // no help
        let messagesPayload = messages ?? Data([0, 0]) // 0 messages

        var data = Data()
        data.append(OP_GUI_AGENT_CHAT)
        data.append(6) // 6 sections
        data.append(contentsOf: buildSectionData(0x01, headerPayload))
        data.append(contentsOf: buildSectionData(0x02, modelPayload))
        data.append(contentsOf: buildSectionData(0x03, promptPayload))
        data.append(contentsOf: buildSectionData(0x04, pendingPayload))
        data.append(contentsOf: buildSectionData(0x05, helpPayload))
        data.append(contentsOf: buildSectionData(0x06, messagesPayload))
        return data
    }

    /// Builds a messages section payload with the given raw message data.
    private func buildMessagesPayload(count: Int, _ rawMessages: Data) -> Data {
        var payload = Data()
        appendU16(&payload, UInt16(count))
        payload.append(rawMessages)
        return payload
    }

    @Test("Decode gui_agent_chat hidden")
    func decodeHidden() throws {
        let data = Data([OP_GUI_AGENT_CHAT, 0])

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 2)

        guard case .guiAgentChat(let visible, _, _, _, _, _, _, _, _, _, _, _, _, _, _) = cmd else {
            Issue.record("Expected .guiAgentChat"); return
        }
        #expect(visible == false)
    }

    @Test("Decode gui_agent_chat with user and assistant messages (sectioned)")
    func decodeUserAndAssistant() throws {
        // Build message payloads
        var msgs = Data()
        // User message (beam_id=1)
        appendU32(&msgs, 1)
        msgs.append(0x01)
        appendU32(&msgs, UInt32("hello".utf8.count))
        msgs.append(contentsOf: "hello".utf8)
        // Assistant message (beam_id=2)
        appendU32(&msgs, 2)
        msgs.append(0x02)
        appendU32(&msgs, UInt32("hi there".utf8.count))
        msgs.append(contentsOf: "hi there".utf8)

        let data = buildChatData(status: 1, model: "claude-3", prompt: "Fix this bug",
                                  messages: buildMessagesPayload(count: 2, msgs))

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiAgentChat(let visible, let status, let model, let prompt, _, _, _, _, _, _, let pendingToolName, _, _, _, let messages) = cmd else {
            Issue.record("Expected .guiAgentChat"); return
        }

        #expect(visible == true)
        #expect(status == 1)
        #expect(model == "claude-3")
        #expect(prompt == "Fix this bug")
        #expect(pendingToolName == nil)
        guard messages.count == 2 else { Issue.record("Expected 2 messages, got \(messages.count)"); return }

        guard case .user(let userText) = messages[0].content else { Issue.record("Expected .user"); return }
        #expect(userText == "hello")
        guard case .assistant(let assistantText) = messages[1].content else { Issue.record("Expected .assistant"); return }
        #expect(assistantText == "hi there")
    }

    @Test("Decode gui_agent_chat with thinking message (sectioned)")
    func decodeThinking() throws {
        var msgs = Data()
        appendU32(&msgs, 10)
        msgs.append(0x03) // thinking
        msgs.append(1) // collapsed
        let thinkText = "Let me analyze..."
        appendU32(&msgs, UInt32(thinkText.utf8.count))
        msgs.append(contentsOf: thinkText.utf8)

        let data = buildChatData(status: 1, model: "claude", messages: buildMessagesPayload(count: 1, msgs))
        let (cmd, _) = try decodeCommand(data: data, offset: 0)
        guard case .guiAgentChat(_, _, _, _, _, _, _, _, _, _, _, _, _, _, let messages) = cmd else { Issue.record("Expected .guiAgentChat"); return }
        guard messages.count == 1 else { Issue.record("Expected 1 message"); return }
        guard case .thinking(let text, let collapsed) = messages[0].content else { Issue.record("Expected .thinking"); return }
        #expect(text == "Let me analyze...")
        #expect(collapsed == true)
    }

    @Test("Decode gui_agent_chat with tool_call message (sectioned)")
    func decodeToolCall() throws {
        var msgs = Data()
        appendU32(&msgs, 5) // beam_id
        msgs.append(0x04) // tool_call
        msgs.append(1); msgs.append(0); msgs.append(1) // status, isError, collapsed
        appendU32(&msgs, 1234) // durationMs
        appendString16(&msgs, "read_file")
        appendString16(&msgs, "lib/minga.ex")
        let result = "file contents here"
        appendU32(&msgs, UInt32(result.utf8.count))
        msgs.append(contentsOf: result.utf8)

        let data = buildChatData(status: 2, model: "claude", messages: buildMessagesPayload(count: 1, msgs))
        let (cmd, _) = try decodeCommand(data: data, offset: 0)
        guard case .guiAgentChat(_, _, _, _, _, _, _, _, _, _, _, _, _, _, let messages) = cmd else { Issue.record("Expected .guiAgentChat"); return }
        guard messages.count == 1 else { Issue.record("Expected 1 message"); return }
        guard case .toolCall(let name, _, let tcStatus, let isError, let collapsed, let duration, let tcResult) = messages[0].content else { Issue.record("Expected .toolCall"); return }
        #expect(name == "read_file")
        #expect(tcStatus == 1)
        #expect(isError == false)
        #expect(collapsed == true)
        #expect(duration == 1234)
        #expect(tcResult == "file contents here")
    }

    @Test("Decode gui_agent_chat with system message (sectioned)")
    func decodeSystem() throws {
        var msgs = Data()
        appendU32(&msgs, 1)
        msgs.append(0x05) // system
        msgs.append(1) // isError
        let sysText = "Session terminated"
        appendU32(&msgs, UInt32(sysText.utf8.count))
        msgs.append(contentsOf: sysText.utf8)

        let data = buildChatData(messages: buildMessagesPayload(count: 1, msgs))
        let (cmd, _) = try decodeCommand(data: data, offset: 0)
        guard case .guiAgentChat(_, _, _, _, _, _, _, _, _, _, _, _, _, _, let messages) = cmd else { Issue.record("Expected .guiAgentChat"); return }
        guard messages.count == 1 else { Issue.record("Expected 1 message"); return }
        guard case .system(let text, let isError) = messages[0].content else { Issue.record("Expected .system"); return }
        #expect(text == "Session terminated")
        #expect(isError == true)
    }

    @Test("Decode gui_agent_chat with usage message (sectioned)")
    func decodeUsage() throws {
        var msgs = Data()
        appendU32(&msgs, 1)
        msgs.append(0x06) // usage
        appendU32(&msgs, 1000); appendU32(&msgs, 500); appendU32(&msgs, 800)
        appendU32(&msgs, 200); appendU32(&msgs, 15000)

        let data = buildChatData(messages: buildMessagesPayload(count: 1, msgs))
        let (cmd, _) = try decodeCommand(data: data, offset: 0)
        guard case .guiAgentChat(_, _, _, _, _, _, _, _, _, _, _, _, _, _, let messages) = cmd else { Issue.record("Expected .guiAgentChat"); return }
        guard messages.count == 1 else { Issue.record("Expected 1 message"); return }
        guard case .usage(let input, let output, let cacheRead, let cacheWrite, let costMicros) = messages[0].content else { Issue.record("Expected .usage"); return }
        #expect(input == 1000)
        #expect(output == 500)
        #expect(cacheRead == 800)
        #expect(cacheWrite == 200)
        #expect(costMicros == 15000)
    }

    @Test("Decode gui_agent_chat with pending approval (sectioned)")
    func decodePendingApproval() throws {
        var pendingPayload = Data()
        pendingPayload.append(1) // has pending
        appendString16(&pendingPayload, "write_file")
        appendString16(&pendingPayload, "Writing to config.toml")

        let data = buildChatData(status: 2, model: "claude", pending: pendingPayload)
        let (cmd, _) = try decodeCommand(data: data, offset: 0)
        guard case .guiAgentChat(_, _, _, _, _, _, _, _, _, _, let pendingToolName, let pendingToolSummary, _, _, _) = cmd else { Issue.record("Expected .guiAgentChat"); return }
        #expect(pendingToolName == "write_file")
        #expect(pendingToolSummary == "Writing to config.toml")
    }

    @Test("Decode gui_agent_chat with styled_assistant message (sectioned)")
    func decodeStyledAssistant() throws {
        var msgs = Data()
        appendU32(&msgs, 42) // beam_id
        msgs.append(0x07) // type=styled_assistant
        appendU16(&msgs, 2) // 2 lines
        // Line 1: 2 runs
        appendU16(&msgs, 2)
        appendString16(&msgs, "def ")
        appendRGB(&msgs, 0x51, 0xAF, 0xEF); appendRGB(&msgs, 0x28, 0x2C, 0x34); msgs.append(0x01) // bold
        appendString16(&msgs, "hello")
        appendRGB(&msgs, 0x98, 0xBE, 0x65); appendRGB(&msgs, 0x28, 0x2C, 0x34); msgs.append(0x02) // italic
        // Line 2: 1 run
        appendU16(&msgs, 1)
        appendString16(&msgs, "  :ok")
        appendRGB(&msgs, 0xBB, 0xC2, 0xCF); appendRGB(&msgs, 0x28, 0x2C, 0x34); msgs.append(0x04) // underline

        let data = buildChatData(model: "claude", messages: buildMessagesPayload(count: 1, msgs))
        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiAgentChat(_, _, _, _, _, _, _, _, _, _, _, _, _, _, let messages) = cmd else { Issue.record("Expected .guiAgentChat"); return }
        guard messages.count == 1 else { Issue.record("Expected 1 message"); return }
        guard case .styledAssistant(let lines) = messages[0].content else { Issue.record("Expected .styledAssistant"); return }
        #expect(lines.count == 2)
        #expect(lines[0][0].text == "def ")
        #expect(lines[0][0].bold == true)
        #expect(lines[0][1].text == "hello")
        #expect(lines[0][1].italic == true)
        #expect(lines[1][0].text == "  :ok")
        #expect(lines[1][0].underline == true)
    }
}

// MARK: - gui_tool_manager (0x7E)

@Suite("GUI Tool Manager Decoder")
struct GUIToolManagerDecoderTests {
    @Test("Decode gui_tool_manager visible with tools")
    func decodeVisible() throws {
        var data = Data()
        data.append(OP_GUI_TOOL_MANAGER)
        data.append(1) // visible
        data.append(0) // filter = all
        appendU16(&data, 0) // selectedIndex
        appendU16(&data, 1) // toolCount

        // Tool entry
        appendString8(&data, "elixir_ls") // name
        appendString8(&data, "ElixirLS") // label
        appendString16(&data, "Elixir Language Server") // description
        data.append(0) // category = lspServer
        data.append(1) // status = installed
        data.append(0) // method = npm
        data.append(1) // languageCount
        appendString8(&data, "elixir") // language
        appendString8(&data, "0.22.1") // version
        appendString16(&data, "https://github.com/elixir-lsp/elixir-ls") // homepage
        data.append(1) // providesCount
        appendString8(&data, "elixir-ls") // provides
        appendString16(&data, "") // errorReason (empty for installed)

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiToolManager(let visible, let filter, let selectedIndex, let tools) = cmd else {
            Issue.record("Expected .guiToolManager"); return
        }

        #expect(visible == true)
        #expect(filter == 0)
        #expect(selectedIndex == 0)
        #expect(tools.count == 1)
        #expect(tools[0].name == "elixir_ls")
        #expect(tools[0].label == "ElixirLS")
        #expect(tools[0].description == "Elixir Language Server")
        #expect(tools[0].category == 0)
        #expect(tools[0].status == 1)
        #expect(tools[0].languages == ["elixir"])
        #expect(tools[0].version == "0.22.1")
        #expect(tools[0].provides == ["elixir-ls"])
        #expect(tools[0].errorReason == "")
    }

    @Test("Decode gui_tool_manager hidden")
    func decodeHidden() throws {
        let data = Data([OP_GUI_TOOL_MANAGER, 0])

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 2)

        guard case .guiToolManager(let visible, _, _, let tools) = cmd else {
            Issue.record("Expected .guiToolManager"); return
        }
        #expect(visible == false)
        #expect(tools.isEmpty)
    }
}

// MARK: - gui_agent_groups (0x86)

@Suite("GUI Agent Groups Decoder")
struct GUIAgentGroupsDecoderTests {
    @Test("Decode agent groups with one group")
    func decodeOneGroup() throws {
        var data = Data()
        data.append(OP_GUI_AGENT_GROUPS)
        appendU16(&data, 1) // active_group_id
        data.append(1) // group_count

        // Agent group (no kind byte, all groups are agents)
        appendU16(&data, 1) // id
        data.append(1) // agent_status = thinking
        appendRGB(&data, 0xC6, 0x78, 0xDD) // color
        appendU16(&data, 2) // tab_count
        appendString8(&data, "Research") // label
        appendString8(&data, "cpu") // icon

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiAgentGroups(let activeId, let groups) = cmd else {
            Issue.record("Expected .guiAgentGroups, got \(String(describing: cmd))")
            return
        }

        #expect(activeId == 1)
        #expect(groups.count == 1)
        #expect(groups[0].id == 1)
        #expect(groups[0].agentStatus == 1)
        #expect(groups[0].colorR == 0xC6)
        #expect(groups[0].colorG == 0x78)
        #expect(groups[0].colorB == 0xDD)
        #expect(groups[0].tabCount == 2)
        #expect(groups[0].label == "Research")
        #expect(groups[0].icon == "cpu")
    }

    @Test("Decode agent groups with zero groups")
    func decodeEmpty() throws {
        var data = Data()
        data.append(OP_GUI_AGENT_GROUPS)
        appendU16(&data, 0) // active_group_id
        data.append(0) // group_count

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 4)

        guard case .guiAgentGroups(_, let groups) = cmd else {
            Issue.record("Expected .guiAgentGroups"); return
        }
        #expect(groups.isEmpty)
    }

    @Test("Decode agent group with long label")
    func decodeLongLabel() throws {
        var data = Data()
        data.append(OP_GUI_AGENT_GROUPS)
        appendU16(&data, 1) // active_group_id
        data.append(1) // group_count

        let longLabel = String(repeating: "A", count: 200)
        appendU16(&data, 1) // id
        data.append(2) // agent_status = tool_executing
        appendRGB(&data, 0x98, 0xBE, 0x65) // color
        appendU16(&data, 0) // tab_count
        appendString8(&data, longLabel) // label
        appendString8(&data, "hammer") // icon

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiAgentGroups(let activeId, let groups) = cmd else {
            Issue.record("Expected .guiAgentGroups"); return
        }

        #expect(activeId == 1)
        #expect(groups[0].label == longLabel)
        #expect(groups[0].icon == "hammer")
    }
}

// MARK: - draw_styled_text (0x1C)

@Suite("Draw Styled Text Decoder")
struct DrawStyledTextDecoderTests {
    @Test("Decode draw_styled_text with all attributes")
    func decodeStyledText() throws {
        var data = Data()
        data.append(OP_DRAW_STYLED_TEXT)
        appendU16(&data, 5) // row
        appendU16(&data, 10) // col
        appendRGB(&data, 0xFF, 0x6C, 0x6B) // fg
        appendRGB(&data, 0x28, 0x2C, 0x34) // bg
        // attrs16: bold(0x01) + underline(0x04) + curl style(1) at bits 5-7
        let attrs16: UInt16 = 0x05 | (1 << 5)  // bold + underline + curl style
        data.append(UInt8(attrs16 >> 8))
        data.append(UInt8(attrs16 & 0xFF))
        appendRGB(&data, 0xFF, 0x00, 0x00) // underlineColor
        data.append(128) // blend
        data.append(5) // fontWeight = bold
        data.append(2) // fontId
        appendString16(&data, "hello world")

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .drawStyledText(let row, let col, let fg, let bg, let attrs, let underlineColor, let blend, let fontWeight, let fontId, let text) = cmd else {
            Issue.record("Expected .drawStyledText"); return
        }

        #expect(row == 5)
        #expect(col == 10)
        #expect(fg == 0xFF6C6B)
        #expect(bg == 0x282C34)
        #expect(attrs == attrs16)
        #expect(underlineColor == 0xFF0000)
        #expect(blend == 128)
        #expect(fontWeight == 5)
        #expect(fontId == 2)
        #expect(text == "hello world")
    }
}
