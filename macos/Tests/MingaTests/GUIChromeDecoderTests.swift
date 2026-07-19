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
import MingaProtocol

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

/// Appends a 24-bit big-endian integer to a Data buffer.
private func appendU24(_ data: inout Data, _ value: UInt32) {
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
        appendU32(&data, 0) // tint_color_rgb

        // Tab 2: pinned agent tab, has attention, workspace 1
        let flags2: UInt8 = 0x04 | 0x08 | (1 << 4) | 0x80 // agent + attention + agentStatus=1 + pinned
        data.append(flags2)
        appendU32(&data, 99) // id
        appendU16(&data, 1) // group_id (agent workspace)
        appendString8(&data, "")
        appendString16(&data, "Agent")
        appendU32(&data, 0x7AA2F7) // tint_color_rgb

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
        #expect(tabs[1].isPinned == true)
        #expect(tabs[1].tintColorRGB == 0x7AA2F7)
        #expect(tabs[1].label == "Agent")
    }

    @Test("Decode gui_tab_bar with hidden active index sentinel")
    func decodeHiddenActiveIndex() throws {
        var data = Data()
        data.append(OP_GUI_TAB_BAR)
        data.append(255) // active_index sentinel for hidden active tab
        data.append(1) // tab_count

        data.append(0) // flags: inactive file tab
        appendU32(&data, 7)
        appendU16(&data, 1)
        appendString8(&data, "")
        appendString16(&data, "hidden.ex")
        appendU32(&data, 0) // tint_color_rgb

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiTabBar(let activeIndex, let tabs) = cmd else {
            Issue.record("Expected .guiTabBar, got \(String(describing: cmd))")
            return
        }

        #expect(activeIndex == 255)
        #expect(tabs.count == 1)
        #expect(tabs[0].isActive == false)
        #expect(tabs[0].label == "hidden.ex")
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

        appendString16(&data, "Defines a function.") // documentation (selected item's doc preview)

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiCompletion(let visible, let anchorRow, let anchorCol, let selectedIndex, let items, let documentation) = cmd else {
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
        #expect(documentation == "Defines a function.")
    }

    @Test("Decode gui_completion hidden")
    func decodeHidden() throws {
        let data = Data([OP_GUI_COMPLETION, 0])

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 2)

        guard case .guiCompletion(let visible, _, _, _, let items, let documentation) = cmd else {
            Issue.record("Expected .guiCompletion"); return
        }
        #expect(visible == false)
        #expect(items.isEmpty)
        #expect(documentation.isEmpty)
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

    private func appendStatusBarSegment(_ data: inout Data, kind: String? = nil, text: String, fg: UInt32, bg: UInt32, attrs: UInt8, command: String) {
        if let kind {
            appendString8(&data, kind)
        }
        appendU24(&data, fg)
        appendU24(&data, bg)
        data.append(attrs)
        appendString16(&data, text)
        appendString16(&data, command)
    }

    @Test("Decode gui_status_bar buffer variant (sectioned format)")
    func decodeBufferVariant() throws {
        var identity = Data()
        identity.append(0) // contentKind = buffer
        identity.append(1) // mode = insert
        identity.append(0x0B) // flags: has_lsp + has_git + is_dirty + safe_mode

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

        var indent = Data()
        indent.append(1) // tabs
        indent.append(4) // size

        var selection = Data()
        selection.append(2) // line selection
        appendU32(&selection, 3) // size

        var msg = Data()
        appendString16(&msg, "-- INSERT --")

        var recording = Data()
        recording.append(0) // macroRecording

        var agent = Data()
        agent.append(0) // agentStatus
        appendU16(&agent, 2) // backgroundSubagentCount
        appendString16(&agent, "session-2: tests") // backgroundSubagentLabel
        appendString8(&agent, "read_file") // activeToolName

        let sections = [
            buildSection(SECTION_IDENTITY, identity),
            buildSection(SECTION_CURSOR, cursor),
            buildSection(SECTION_DIAGNOSTICS, diagnostics),
            buildSection(SECTION_LANGUAGE, language),
            buildSection(SECTION_GIT, git),
            buildSection(SECTION_FILE, file),
            buildSection(0x0A, indent),
            buildSection(0x0C, selection),
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

        guard case .guiStatusBar(let update) = cmd else {
            Issue.record("Expected .guiStatusBar"); return
        }

        #expect(update.contentKind == 0)
        #expect(update.mode == 1)
        #expect(update.cursorLine == 42)
        #expect(update.cursorCol == 9)
        #expect(update.lineCount == 500)
        #expect(update.flags == 0x0B)
        #expect(update.safeMode == true)
        #expect(update.lspStatus == 1)
        #expect(update.gitBranch == "main")
        #expect(update.message == "-- INSERT --")
        #expect(update.filetype == "elixir")
        #expect(update.errorCount == 3)
        #expect(update.warningCount == 7)
        #expect(update.infoCount == 1)
        #expect(update.hintCount == 2)
        #expect(update.macroRecording == 0)
        #expect(update.parserStatus == 1)
        #expect(update.agentStatus == 0)
        #expect(update.activeToolName == "read_file")
        #expect(update.gitAdded == 5)
        #expect(update.gitModified == 3)
        #expect(update.gitDeleted == 1)
        #expect(update.filename == "editor.ex")
        #expect(update.indent.kind == 1)
        #expect(update.indent.size == 4)
        #expect(update.selection.mode == 2)
        #expect(update.selection.size == 3)
        #expect(update.backgroundSubagentCount == 2)
        #expect(update.backgroundSubagentLabel == "session-2: tests")

    }

    @Test("Decode gui_status_bar empty agent section throws malformed")
    func decodeEmptyAgentSectionThrows() throws {
        var identity = Data()
        identity.append(1) // contentKind = agent
        identity.append(0) // mode = normal
        identity.append(0x03) // flags

        let sections = [
            buildSection(SECTION_IDENTITY, identity),
            buildSection(SECTION_AGENT, Data()),
        ]

        var data = Data()
        data.append(OP_GUI_STATUS_BAR)
        data.append(UInt8(sections.count))
        for section in sections { data.append(section) }

        #expect(throws: ProtocolDecodeError.self) {
            _ = try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("Decode gui_status_bar agent section before identity")
    func decodeAgentSectionBeforeIdentity() throws {
        var identity = Data()
        identity.append(1) // contentKind = agent
        identity.append(0) // mode = normal
        identity.append(0x03) // flags

        var agent = Data()
        appendString8(&agent, "claude-3-5-sonnet")
        appendU32(&agent, 12) // messageCount
        agent.append(1) // sessionStatus
        agent.append(1) // agentStatus
        appendU16(&agent, 3) // backgroundSubagentCount
        appendString16(&agent, "session-3: agent tests") // backgroundSubagentLabel
        appendString8(&agent, "shell") // activeToolName

        let sections = [
            buildSection(SECTION_AGENT, agent),
            buildSection(SECTION_IDENTITY, identity),
        ]

        var data = Data()
        data.append(OP_GUI_STATUS_BAR)
        data.append(UInt8(sections.count))
        for section in sections { data.append(section) }

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiStatusBar(let update) = cmd else {
            Issue.record("Expected .guiStatusBar")
            return
        }

        #expect(update.contentKind == 1)
        #expect(update.modelName == "claude-3-5-sonnet")
        #expect(update.messageCount == 12)
        #expect(update.sessionStatus == 1)
        #expect(update.agentStatus == 1)
        #expect(update.activeToolName == "shell")
        #expect(update.backgroundSubagentCount == 3)
        #expect(update.backgroundSubagentLabel == "session-3: agent tests")
    }

    @Test("Decode gui_status_bar workspace section")
    func decodeWorkspaceSection() throws {
        var identity = Data()
        identity.append(0) // contentKind = buffer
        identity.append(0) // mode = normal
        identity.append(0) // flags

        var workspace = Data()
        appendU16(&workspace, 7) // id
        workspace.append(1) // kind = agent
        workspace.append(2) // status = tool_executing
        appendU16(&workspace, 0x0003) // flags
        appendU16(&workspace, 4) // draft count
        appendU16(&workspace, 1) // conflict count
        appendU16(&workspace, 2) // background count
        appendU16(&workspace, 3) // attention count
        appendString8(&workspace, "Review")
        appendString8(&workspace, "cpu")

        let sections = [
            buildSection(SECTION_IDENTITY, identity),
            buildSection(SECTION_WORKSPACE, workspace),
        ]

        var data = Data()
        data.append(OP_GUI_STATUS_BAR)
        data.append(UInt8(sections.count))
        for section in sections { data.append(section) }

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiStatusBar(let update) = cmd else {
            Issue.record("Expected .guiStatusBar")
            return
        }

        #expect(update.workspace?.id == 7)
        #expect(update.workspace?.kind == 1)
        #expect(update.workspace?.status == 2)
        #expect(update.workspace?.flags == 0x0003)
        #expect(update.workspace?.draftCount == 4)
        #expect(update.workspace?.conflictCount == 1)
        #expect(update.workspace?.backgroundCount == 2)
        #expect(update.workspace?.attentionCount == 3)
        #expect(update.workspace?.label == "Review")
        #expect(update.workspace?.icon == "cpu")
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

        // Agent section: model_name_len(1) + model_name + message_count(4) + session_status(1) + agent_status(1) + background count/label + active_tool_name
        var agent = Data()
        appendString8(&agent, "claude-3-5-sonnet")
        appendU32(&agent, 12) // messageCount
        agent.append(1) // sessionStatus
        agent.append(1) // agentStatus
        appendU16(&agent, 3) // backgroundSubagentCount
        appendString16(&agent, "session-3: agent tests") // backgroundSubagentLabel
        appendString8(&agent, "shell") // activeToolName

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

        guard case .guiStatusBar(let update) = cmd else {

            Issue.record("Expected .guiStatusBar"); return
        }

        #expect(update.contentKind == 1)
        #expect(update.modelName == "claude-3-5-sonnet")
        #expect(update.messageCount == 12)
        #expect(update.sessionStatus == 1)
        #expect(update.cursorLine == 11)
        #expect(update.lineCount == 100)
        #expect(update.gitBranch == "feat/agent")
        #expect(update.filetype == "elixir")
        #expect(update.errorCount == 1)
        #expect(update.hintCount == 1)
        #expect(update.agentStatus == 1)
        #expect(update.activeToolName == "shell")
        #expect(update.gitAdded == 3)
        #expect(update.gitModified == 2)
        #expect(update.filename == "editor.ex")
        #expect(update.backgroundSubagentCount == 3)
        #expect(update.backgroundSubagentLabel == "session-3: agent tests")
    }

    @Test("Decode gui_status_bar agent variant without appended active tool name")
    func decodeAgentVariantWithoutActiveToolName() throws {
        var identity = Data()
        identity.append(1) // contentKind = agent
        identity.append(0) // mode = normal
        identity.append(0x03) // flags

        var agent = Data()
        appendString8(&agent, "claude-3-5-sonnet")
        appendU32(&agent, 12) // messageCount
        agent.append(1) // sessionStatus
        agent.append(1) // agentStatus
        appendU16(&agent, 3) // backgroundSubagentCount
        appendString16(&agent, "session-3: agent tests") // backgroundSubagentLabel

        let sections = [
            buildSection(SECTION_IDENTITY, identity),
            buildSection(SECTION_AGENT, agent),
        ]

        var data = Data()
        data.append(OP_GUI_STATUS_BAR)
        data.append(UInt8(sections.count))
        for section in sections { data.append(section) }

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiStatusBar(let update) = cmd else {
            Issue.record("Expected .guiStatusBar")
            return
        }

        #expect(update.activeToolName.isEmpty)
        #expect(update.backgroundSubagentCount == 3)
        #expect(update.backgroundSubagentLabel == "session-3: agent tests")
    }

    @Test("Decode configured modeline segments section")
    func decodeModelineSegmentsSection() throws {
        var identity = Data()
        identity.append(0); identity.append(0); identity.append(0)

        var modelineSegments = Data()
        modelineSegments.append(2) // version
        appendU16(&modelineSegments, 1) // left count
        appendU16(&modelineSegments, 1) // right count
        appendStatusBarSegment(&modelineSegments, kind: "mode", text: " NORMAL ", fg: 0xBBC2CF, bg: 0x51AFEF, attrs: 0x01, command: "")
        appendStatusBarSegment(&modelineSegments, kind: "filetype", text: " Elixir ", fg: 0xC678DD, bg: 0x282C34, attrs: 0x00, command: "set_language")

        let sections = [
            buildSection(SECTION_IDENTITY, identity),
            buildSection(SECTION_MODELINE_SEGMENTS, modelineSegments),
        ]

        var data = Data()
        data.append(OP_GUI_STATUS_BAR)
        data.append(UInt8(sections.count))
        for s in sections { data.append(s) }

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiStatusBar(let update) = cmd else {
            Issue.record("Expected .guiStatusBar"); return
        }

        #expect(update.modelineSegmentsPresent)
        #expect(update.modelineLeftSegments.count == 1)
        #expect(update.modelineLeftSegments[0].kind == "mode")
        #expect(update.modelineLeftSegments[0].text == " NORMAL ")
        #expect(update.modelineLeftSegments[0].fgColor == 0xBBC2CF)
        #expect(update.modelineLeftSegments[0].bgColor == 0x51AFEF)
        #expect(update.modelineLeftSegments[0].isBold)
        #expect(update.modelineRightSegments.count == 1)
        #expect(update.modelineRightSegments[0].kind == "filetype")
        #expect(update.modelineRightSegments[0].text == " Elixir ")
        #expect(update.modelineRightSegments[0].command == "set_language")
    }

    @Test("Decode pending_keys (showcmd) section")
    func decodePendingKeysSection() throws {
        var identity = Data()
        identity.append(0); identity.append(0); identity.append(0)

        var pendingKeys = Data()
        appendString16(&pendingKeys, "\"a2d")

        let sections = [
            buildSection(SECTION_IDENTITY, identity),
            buildSection(SECTION_PENDING_KEYS, pendingKeys),
        ]

        var data = Data()
        data.append(OP_GUI_STATUS_BAR)
        data.append(UInt8(sections.count))
        for s in sections { data.append(s) }

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiStatusBar(let update) = cmd else {
            Issue.record("Expected .guiStatusBar"); return
        }

        #expect(update.pendingKeys == "\"a2d")
    }

    @Test("Pending keys default to empty when section absent")
    func pendingKeysDefaultEmpty() throws {
        var identity = Data()
        identity.append(0); identity.append(0); identity.append(0)

        let sections = [buildSection(SECTION_IDENTITY, identity)]

        var data = Data()
        data.append(OP_GUI_STATUS_BAR)
        data.append(UInt8(sections.count))
        for s in sections { data.append(s) }

        let (cmd, _) = try decodeCommand(data: data, offset: 0)
        guard case .guiStatusBar(let update) = cmd else {
            Issue.record("Expected .guiStatusBar"); return
        }
        #expect(update.pendingKeys == "")
    }

    @Test("Decode legacy v1 modeline segments as custom kind")
    func decodeLegacyV1ModelineSegmentsSection() throws {
        var identity = Data()
        identity.append(0); identity.append(0); identity.append(0)

        var modelineSegments = Data()
        modelineSegments.append(1) // legacy version without segment names
        appendU16(&modelineSegments, 1) // left count
        appendU16(&modelineSegments, 1) // right count
        appendStatusBarSegment(&modelineSegments, text: " LEGACY ", fg: 0xBBC2CF, bg: 0x51AFEF, attrs: 0x01, command: "")
        appendStatusBarSegment(&modelineSegments, text: " Click ", fg: 0xC678DD, bg: 0x282C34, attrs: 0x00, command: "buffer_list")

        let sections = [
            buildSection(SECTION_IDENTITY, identity),
            buildSection(SECTION_MODELINE_SEGMENTS, modelineSegments),
        ]

        var data = Data()
        data.append(OP_GUI_STATUS_BAR)
        data.append(UInt8(sections.count))
        for s in sections { data.append(s) }

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiStatusBar(let update) = cmd else {
            Issue.record("Expected .guiStatusBar"); return
        }

        #expect(update.modelineSegmentsPresent)
        #expect(update.modelineLeftSegments.count == 1)
        #expect(update.modelineLeftSegments[0].kind == "custom")
        #expect(update.modelineLeftSegments[0].text == " LEGACY ")
        #expect(update.modelineLeftSegments[0].isBold)
        #expect(update.modelineRightSegments.count == 1)
        #expect(update.modelineRightSegments[0].kind == "custom")
        #expect(update.modelineRightSegments[0].command == "buffer_list")
    }

    @Test("Unsupported modeline segment section version is ignored")
    func unsupportedModelineSegmentVersionIsIgnored() throws {
        var identity = Data()
        identity.append(0); identity.append(0); identity.append(0)

        var modelineSegments = Data()
        modelineSegments.append(3) // unsupported version
        appendU16(&modelineSegments, 1)
        appendU16(&modelineSegments, 0)
        appendStatusBarSegment(&modelineSegments, text: " HIDDEN ", fg: 0xBBC2CF, bg: 0x51AFEF, attrs: 0x00, command: "")

        let sections = [
            buildSection(SECTION_IDENTITY, identity),
            buildSection(SECTION_MODELINE_SEGMENTS, modelineSegments),
        ]

        var data = Data()
        data.append(OP_GUI_STATUS_BAR)
        data.append(UInt8(sections.count))
        for s in sections { data.append(s) }

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiStatusBar(let update) = cmd else {
            Issue.record("Expected .guiStatusBar"); return
        }

        #expect(update.modelineLeftSegments.isEmpty)
        #expect(update.modelineRightSegments.isEmpty)
    }

    @Test("Invalid UTF-8 modeline segment text throws malformed")
    func invalidUTF8ModelineSegmentTextThrows() throws {
        var identity = Data()
        identity.append(0); identity.append(0); identity.append(0)

        var modelineSegments = Data()
        modelineSegments.append(1)
        appendU16(&modelineSegments, 1)
        appendU16(&modelineSegments, 0)
        appendU24(&modelineSegments, 0xBBC2CF)
        appendU24(&modelineSegments, 0x51AFEF)
        modelineSegments.append(0x00)
        appendU16(&modelineSegments, 1)
        modelineSegments.append(0xFF)
        appendU16(&modelineSegments, 0)

        let sections = [
            buildSection(SECTION_IDENTITY, identity),
            buildSection(SECTION_MODELINE_SEGMENTS, modelineSegments),
        ]

        var data = Data()
        data.append(OP_GUI_STATUS_BAR)
        data.append(UInt8(sections.count))
        for s in sections { data.append(s) }

        #expect(throws: ProtocolDecodeError.self) {
            _ = try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("Invalid UTF-8 modeline segment command throws malformed")
    func invalidUTF8ModelineSegmentCommandThrows() throws {
        var identity = Data()
        identity.append(0); identity.append(0); identity.append(0)

        var modelineSegments = Data()
        modelineSegments.append(1)
        appendU16(&modelineSegments, 1)
        appendU16(&modelineSegments, 0)
        appendU24(&modelineSegments, 0xBBC2CF)
        appendU24(&modelineSegments, 0x51AFEF)
        modelineSegments.append(0x00)
        appendString16(&modelineSegments, " OK ")
        appendU16(&modelineSegments, 1)
        modelineSegments.append(0xFF)

        let sections = [
            buildSection(SECTION_IDENTITY, identity),
            buildSection(SECTION_MODELINE_SEGMENTS, modelineSegments),
        ]

        var data = Data()
        data.append(OP_GUI_STATUS_BAR)
        data.append(UInt8(sections.count))
        for s in sections { data.append(s) }

        #expect(throws: ProtocolDecodeError.self) {
            _ = try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("Truncated modeline segment throws malformed")
    func truncatedModelineSegmentThrows() throws {
        var identity = Data()
        identity.append(0); identity.append(0); identity.append(0)

        var modelineSegments = Data()
        modelineSegments.append(1) // version
        appendU16(&modelineSegments, 1) // left count
        appendU16(&modelineSegments, 0) // right count
        appendU24(&modelineSegments, 0xBBC2CF)
        appendU24(&modelineSegments, 0x51AFEF)
        modelineSegments.append(0x00)
        appendU16(&modelineSegments, 12) // text length, but text is missing
        modelineSegments.append(contentsOf: Data("short".utf8))

        let sections = [
            buildSection(SECTION_IDENTITY, identity),
            buildSection(SECTION_MODELINE_SEGMENTS, modelineSegments),
        ]

        var data = Data()
        data.append(OP_GUI_STATUS_BAR)
        data.append(UInt8(sections.count))
        for s in sections { data.append(s) }

        #expect(throws: ProtocolDecodeError.self) {
            _ = try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("Modeline segment count mismatch throws malformed")
    func modelineSegmentCountMismatchThrows() throws {
        var identity = Data()
        identity.append(0); identity.append(0); identity.append(0)

        var modelineSegments = Data()
        modelineSegments.append(1) // version
        appendU16(&modelineSegments, 2) // left count declares two segments
        appendU16(&modelineSegments, 0)
        appendStatusBarSegment(&modelineSegments, text: " ONLY ", fg: 0xBBC2CF, bg: 0x51AFEF, attrs: 0x00, command: "")

        let sections = [
            buildSection(SECTION_IDENTITY, identity),
            buildSection(SECTION_MODELINE_SEGMENTS, modelineSegments),
        ]

        var data = Data()
        data.append(OP_GUI_STATUS_BAR)
        data.append(UInt8(sections.count))
        for s in sections { data.append(s) }

        #expect(throws: ProtocolDecodeError.self) {
            _ = try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("Unknown sections are skipped (forward compatibility)")
    func skipUnknownSections() throws {
        // Build a status bar with an unknown section 0xFF between known sections
        var identity = Data()
        identity.append(0); identity.append(0); identity.append(0)

        let unknown = Data([0xDE, 0xAD, 0xBE, 0xEF])

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

        guard case .guiStatusBar(let update) = cmd else {

            Issue.record("Expected .guiStatusBar"); return
        }

        #expect(update.cursorLine == 10)
        #expect(update.cursorCol == 5)
        #expect(update.lineCount == 200)
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

        guard case .guiStatusBar(let update) = cmd else {

            Issue.record("Expected .guiStatusBar"); return
        }

        #expect(update.contentKind == 0)
        #expect(update.mode == 2) // visual
        #expect(update.cursorLine == 0) // default
        #expect(update.gitBranch == "") // default
        #expect(update.errorCount == 0) // default
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

// MARK: - gui_observatory (semantic, length-prefixed)

@Suite("GUI Observatory Decoder")
struct GUIObservatoryDecoderTests {
    @Test("Decode hidden gui_observatory payload")
    func decodeHiddenPayload() throws {
        var header = Data()
        header.append(0)
        appendU16(&header, 0)

        let payload = buildSectionData(0x01, header)
        var data = Data()
        data.append(OP_GUI_OBSERVATORY)
        appendU32(&data, UInt32(payload.count))
        data.append(payload)

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiObservatory(let visible, let nodeCount, let decodedNodes) = cmd else {
            Issue.record("Expected .guiObservatory"); return
        }
        #expect(visible == false)
        #expect(nodeCount == 0)
        #expect(decodedNodes.isEmpty)
    }

    @Test("Reject truncated gui_observatory 32-bit payload")
    func rejectTruncatedPayload() throws {
        var data = Data()
        data.append(OP_GUI_OBSERVATORY)
        appendU32(&data, 4)
        data.append(0x01)
        data.append(0x00)

        #expect(throws: ProtocolDecodeError.self) {
            _ = try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("Decode semantic gui_observatory with tree order and sparklines")
    func decodeWithNodesAndSparklines() throws {
        var payload = Data()

        var header = Data()
        header.append(1)
        appendU16(&header, 2)
        payload.append(buildSectionData(0x01, header))
        payload.append(buildSectionData(0x7F, Data([0xAA, 0xBB])))

        var rootNode = Data()
        appendNode(&rootNode, pid: "<0.1.0>", parentPid: "", name: "Elixir.Minga.Supervisor", processClass: 0, depth: 0, memory: 1024, messageQueueLen: 0, reductions: 10)
        payload.append(buildSectionData(0x02, rootNode))

        var childNode = Data()
        appendNode(&childNode, pid: "<0.2.0>", parentPid: "<0.1.0>", name: "Elixir.Minga.Buffer.Process", processClass: 1, depth: 1, memory: 2048, messageQueueLen: 2, reductions: 20)
        payload.append(buildSectionData(0x02, childNode))

        var emptyRootSparkline = Data()
        appendString8(&emptyRootSparkline, "<0.1.0>")
        emptyRootSparkline.append(0)
        payload.append(buildSectionData(0x03, emptyRootSparkline))

        var childSparkline = Data()
        appendString8(&childSparkline, "<0.2.0>")
        childSparkline.append(2)
        appendU16(&childSparkline, 0)
        appendU16(&childSparkline, 32768)
        payload.append(buildSectionData(0x03, childSparkline))

        var data = Data()
        data.append(OP_GUI_OBSERVATORY)
        appendU32(&data, UInt32(payload.count))
        data.append(payload)

        let defaults = FrameResourcePolicy.default
        let mapConstrained = FrameResourcePolicy(
            wire: defaults.wire,
            decode: .init(weight: .init(
                commands: 1, ownedUTF8Bytes: .max, arrayEntries: 8,
                rows: .max, spans: .max, overlays: .max,
                spliceEntries: .max, locatorEntries: .max
            )),
            staging: defaults.staging,
            resident: defaults.resident
        )
        #expect(throws: ProtocolDecodeError.self) {
            _ = try decodeFrame(from: data, policy: mapConstrained)
        }

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiObservatory(let visible, let nodeCount, let decodedNodes) = cmd else {
            Issue.record("Expected .guiObservatory"); return
        }
        #expect(visible == true)
        #expect(nodeCount == 2)
        #expect(decodedNodes.map(\.pid) == ["<0.1.0>", "<0.2.0>"])
        #expect(decodedNodes[1].parentPid == "<0.1.0>")
        #expect(decodedNodes[1].processClass == 1)
        #expect(decodedNodes[1].sparkline.count == 2)
        #expect(decodedNodes[1].sparkline[0] == 0)
        #expect(decodedNodes[1].sparkline[1] > 0.49)
    }

    private func appendNode(_ data: inout Data, pid: String, parentPid: String, name: String, processClass: UInt8, depth: UInt8, memory: UInt32, messageQueueLen: UInt16, reductions: UInt32) {
        appendString8(&data, pid)
        appendString8(&data, parentPid)
        appendString16(&data, name)
        data.append(processClass)
        data.append(depth)
        appendU32(&data, memory)
        appendU16(&data, messageQueueLen)
        appendU32(&data, reductions)
    }
}

// MARK: - gui_file_tree (semantic, length-prefixed)

@Suite("GUI File Tree Decoder")
struct GUIFileTreeDecoderTests {
    @Test("Decode semantic gui_file_tree with entries")
    func decodeWithEntries() throws {
        var payload = Data()
        payload.append(2) // version
        payload.append(0x03) // visible + focused
        payload.append(3) // ready tree state
        appendString16(&payload, "/home/user/project/lib") // selectedId
        appendString16(&payload, "/home/user/project") // rootPath
        appendU16(&payload, 30) // treeWidth
        appendU16(&payload, 2) // rowCount
        appendString16(&payload, "") // errorReason

        appendSemanticRow(
            &payload,
            hash: 0xAABBCCDD,
            flags: 0x0001 | 0x0002 | 0x0004 | 0x0008 | 0x0080,
            depth: 0,
            gitStatus: 0,
            guides: [],
            id: "/home/user/project/lib",
            path: "/home/user/project/lib",
            relPath: "lib",
            name: "lib",
            icon: "󰉋",
            editingType: 0xFF,
            editingText: ""
        )

        appendSemanticRow(
            &payload,
            hash: 0x11223344,
            flags: 0x0010 | 0x0020,
            depth: 1,
            gitStatus: 1,
            diagnosticErrorCount: 1,
            diagnosticWarningCount: 2,
            diagnosticInfoCount: 3,
            diagnosticHintCount: 4,
            guides: [true],
            id: "/home/user/project/lib/editor.ex",
            path: "/home/user/project/lib/editor.ex",
            relPath: "lib/editor.ex",
            name: "editor.ex",
            icon: "",
            editingType: 0xFF,
            editingText: "",
            heatLevel: 4
        )

        var data = Data()
        data.append(OP_GUI_FILE_TREE)
        appendU32(&data, UInt32(payload.count))
        data.append(payload)

        let defaults = FrameResourcePolicy.default
        let guideConstrained = FrameResourcePolicy(
            wire: defaults.wire,
            decode: .init(weight: .init(
                commands: 1, ownedUTF8Bytes: .max, arrayEntries: 5,
                rows: .max, spans: .max, overlays: .max,
                spliceEntries: .max, locatorEntries: .max
            )),
            staging: defaults.staging,
            resident: defaults.resident
        )
        #expect(throws: ProtocolDecodeError.self) {
            _ = try decodeFrame(from: data, policy: guideConstrained)
        }

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiFileTree(let version, let treeFlags, let treeState, let selectedId, let treeWidth, let rootPath, let errorReason, let entries) = cmd else {
            Issue.record("Expected .guiFileTree"); return
        }

        #expect(version == 2)
        #expect(treeFlags & 0x01 != 0)
        #expect(treeFlags & 0x02 != 0)
        #expect(treeState == 3)
        #expect(selectedId == "/home/user/project/lib")
        #expect(treeWidth == 30)
        #expect(rootPath == "/home/user/project")
        #expect(errorReason == "")
        #expect(entries.count == 2)
        #expect(entries[0].pathHash == 0xAABBCCDD)
        #expect(entries[0].isDir == true)
        #expect(entries[0].isExpanded == true)
        #expect(entries[0].isSelected == true)
        #expect(entries[0].isFocused == true)
        #expect(entries[0].isLastChild == true)
        #expect(entries[0].id == "/home/user/project/lib")
        #expect(entries[0].path == "/home/user/project/lib")
        #expect(entries[1].depth == 1)
        #expect(entries[1].gitStatus == 1)
        #expect(entries[1].diagnosticErrorCount == 1)
        #expect(entries[1].diagnosticWarningCount == 2)
        #expect(entries[1].diagnosticInfoCount == 3)
        #expect(entries[1].diagnosticHintCount == 4)
        #expect(entries[1].isActive == true)
        #expect(entries[1].isDirty == true)
        #expect(entries[1].guides == [true])
        #expect(entries[1].name == "editor.ex")
        #expect(entries[1].relPath == "lib/editor.ex")
        // Per-row icon color (3 bytes after the editing payload) round-trips through the decoder.
        #expect(entries[0].iconColorR == 0x6D)
        #expect(entries[0].iconColorG == 0x80)
        #expect(entries[0].iconColorB == 0x86)
        #expect(entries[0].heatLevel == 0xFF)
        #expect(entries[1].heatLevel == 4)
    }

    @Test("Decode lightweight gui_file_tree_selection")
    func decodeSelectionUpdate() throws {
        var payload = Data()
        payload.append(0x01)
        appendString16(&payload, "/home/user/project/lib/editor.ex")

        var data = Data()
        data.append(OP_GUI_FILE_TREE_SELECTION)
        appendU16(&data, UInt16(payload.count))
        data.append(payload)

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiFileTreeSelection(let selectedId, let focused) = cmd else {
            Issue.record("Expected .guiFileTreeSelection"); return
        }

        #expect(selectedId == "/home/user/project/lib/editor.ex")
        #expect(focused == true)
    }

    @Test("Decode semantic gui_file_tree hidden")
    func decodeHidden() throws {
        var payload = Data()
        payload.append(2) // version
        payload.append(0x00) // not visible
        payload.append(0) // hidden tree state
        appendString16(&payload, "")
        appendString16(&payload, "/home/user/project")
        appendU16(&payload, 0)
        appendU16(&payload, 0)
        appendString16(&payload, "")

        var data = Data()
        data.append(OP_GUI_FILE_TREE)
        appendU32(&data, UInt32(payload.count))
        data.append(payload)

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiFileTree(_, let treeFlags, let treeState, _, let treeWidth, let rootPath, _, let entries) = cmd else {
            Issue.record("Expected .guiFileTree"); return
        }
        #expect(treeFlags & 0x01 == 0)
        #expect(treeFlags & 0x10 == 0)
        #expect(treeState == 0)
        #expect(treeWidth == 0)
        #expect(rootPath == "/home/user/project")
        #expect(entries.isEmpty)
    }

    @Test("Decode semantic gui_file_tree loading empty and error states")
    func decodeExplicitEmptyStates() throws {
        for (state, flags, reason) in [(UInt8(1), UInt8(0x01), ""), (UInt8(2), UInt8(0x11), ""), (UInt8(4), UInt8(0x01), "permission denied")] {
            var payload = Data()
            payload.append(2)
            payload.append(flags)
            payload.append(state)
            appendString16(&payload, "")
            appendString16(&payload, "/project")
            appendU16(&payload, 30)
            appendU16(&payload, 0)
            appendString16(&payload, reason)

            var data = Data()
            data.append(OP_GUI_FILE_TREE)
            appendU32(&data, UInt32(payload.count))
            data.append(payload)

            let (cmd, size) = try decodeCommand(data: data, offset: 0)
            #expect(size == data.count)

            guard case .guiFileTree(_, let treeFlags, let treeState, _, let treeWidth, let rootPath, let errorReason, let entries) = cmd else {
                Issue.record("Expected .guiFileTree"); return
            }
            #expect(treeFlags == flags)
            #expect(treeState == state)
            #expect(treeWidth == 30)
            #expect(rootPath == "/project")
            #expect(errorReason == reason)
            #expect(entries.isEmpty)
        }
    }

    @Test("Decode semantic gui_file_tree editing row")
    func decodeEditingRow() throws {
        var payload = Data()
        payload.append(2)
        payload.append(0x03)
        payload.append(3)
        appendString16(&payload, "/project/ñ📄.txt")
        appendString16(&payload, "/project")
        appendU16(&payload, 30)
        appendU16(&payload, 1)
        appendString16(&payload, "")
        appendSemanticRow(
            &payload,
            hash: 1,
            flags: 0x0004 | 0x0040 | 0x0080,
            depth: 0,
            gitStatus: 0,
            guides: [],
            id: "/project/ñ📄.txt",
            path: "/project/ñ📄.txt",
            relPath: "ñ📄.txt",
            name: "ñ📄.txt",
            icon: "📄",
            editingType: 2,
            editingText: "renombré📄.txt"
        )

        var data = Data()
        data.append(OP_GUI_FILE_TREE)
        appendU32(&data, UInt32(payload.count))
        data.append(payload)

        let (cmd, _) = try decodeCommand(data: data, offset: 0)
        guard case .guiFileTree(_, _, _, _, _, _, _, let entries) = cmd else {
            Issue.record("Expected .guiFileTree"); return
        }
        #expect(entries.count == 1)
        #expect(entries[0].id == "/project/ñ📄.txt")
        #expect(entries[0].name == "ñ📄.txt")
        #expect(entries[0].icon == "📄")
        #expect(entries[0].isEditing == true)
        #expect(entries[0].editingType == 2)
        #expect(entries[0].editingText == "renombré📄.txt")
    }

    @Test("Decode semantic gui_file_tree rejects truncated row")
    func decodeMalformedRow() throws {
        var payload = Data()
        payload.append(1)
        payload.append(0x03)
        appendString16(&payload, "")
        appendString16(&payload, "/project")
        appendU16(&payload, 30)
        appendU16(&payload, 1)
        payload.append(0xAA) // incomplete row

        var data = Data()
        data.append(OP_GUI_FILE_TREE)
        appendU32(&data, UInt32(payload.count))
        data.append(payload)

        #expect(throws: ProtocolDecodeError.self) {
            _ = try decodeCommand(data: data, offset: 0)
        }
    }

    private func appendSemanticRow(
        _ data: inout Data,
        hash: UInt32,
        flags: UInt16,
        depth: UInt8,
        gitStatus: UInt8,
        diagnosticErrorCount: UInt16 = 0,
        diagnosticWarningCount: UInt16 = 0,
        diagnosticInfoCount: UInt16 = 0,
        diagnosticHintCount: UInt16 = 0,
        guides: [Bool],
        id: String,
        path: String,
        relPath: String,
        name: String,
        icon: String,
        iconColorR: UInt8 = 0x6D,
        iconColorG: UInt8 = 0x80,
        iconColorB: UInt8 = 0x86,
        editingType: UInt8,
        editingText: String,
        heatLevel: UInt8 = 0xFF
    ) {
        appendU32(&data, hash)
        appendU16(&data, flags)
        data.append(depth)
        data.append(gitStatus)
        appendU16(&data, diagnosticErrorCount)
        appendU16(&data, diagnosticWarningCount)
        appendU16(&data, diagnosticInfoCount)
        appendU16(&data, diagnosticHintCount)
        data.append(UInt8(guides.count))
        for guide in guides { data.append(guide ? 1 : 0) }
        appendString16(&data, id)
        appendString16(&data, path)
        appendString16(&data, relPath)
        appendString16(&data, name)
        appendString8(&data, icon)
        data.append(editingType)
        appendString16(&data, editingText)
        data.append(iconColorR)
        data.append(iconColorG)
        data.append(iconColorB)
        data.append(heatLevel)
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
        appendU16(&window, 80) // contentWidth

        // Section 0x02: Config
        var config = Data()
        appendU32(&config, 10) // cursorLine
        config.append(0) // lineNumberStyle = hybrid
        config.append(4) // lineNumberWidth
        config.append(1) // signColWidth

        // Section 0x03: Entries
        var entries = Data()
        appendU16(&entries, 4) // entry count
        // Entry 1
        appendU32(&entries, 8); entries.append(0); entries.append(1); appendU32(&entries, UInt32.max) // normal, gitAdded, no fold range
        // Entry 2
        appendU32(&entries, 9); entries.append(1); entries.append(0); appendU32(&entries, 14) // foldStart, none, fold end
        // Entry 3
        appendU32(&entries, 10); entries.append(3); entries.append(4); appendU32(&entries, UInt32.max) // wrapContinuation, diagError, no fold range
        // Entry 4
        appendU32(&entries, 11); entries.append(5); entries.append(9); appendU32(&entries, UInt32.max) // blank, gitRemoved, no fold range

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
        #expect(gutterData.contentWidth == 80)
        #expect(gutterData.cursorLine == 10)
        #expect(gutterData.lineNumberStyle == .hybrid)
        #expect(gutterData.lineNumberWidth == 4)
        #expect(gutterData.signColWidth == 1)
        #expect(gutterData.entries.count == 4)
        #expect(gutterData.entries[0].bufLine == 8)
        #expect(gutterData.entries[0].signType == .gitAdded)
        #expect(gutterData.entries[1].displayType == .foldStart)
        #expect(gutterData.entries[1].foldEndLine == 14)
        #expect(gutterData.entries[2].displayType == .wrapContinuation)
        #expect(gutterData.entries[2].signType == .diagError)
        #expect(gutterData.entries[3].displayType == .blank)
        #expect(gutterData.entries[3].signType == .gitRemoved)
    }

    @Test("Decode gui_gutter with legacy window section layout")
    func decodeGutterLegacyWindowSection() throws {
        var window = Data()
        appendU16(&window, 1)
        appendU16(&window, 0)
        appendU16(&window, 5)
        appendU16(&window, 24)
        window.append(1)

        var config = Data()
        appendU32(&config, 10)
        config.append(0)
        config.append(4)
        config.append(1)

        var entries = Data()
        appendU16(&entries, 1)
        appendU32(&entries, 8); entries.append(0); entries.append(1); appendU32(&entries, UInt32.max)

        var data = Data()
        data.append(OP_GUI_GUTTER)
        data.append(3)
        data.append(contentsOf: buildSectionData(0x01, window))
        data.append(contentsOf: buildSectionData(0x02, config))
        data.append(contentsOf: buildSectionData(0x03, entries))

        let (cmd, _) = try decodeCommand(data: data, offset: 0)
        guard case .guiGutter(let gutterData) = cmd else {
            Issue.record("Expected .guiGutter"); return
        }

        #expect(gutterData.windowId == 1)
        #expect(gutterData.contentHeight == 24)
        #expect(gutterData.isActive == true)
        #expect(gutterData.contentWidth == 0)
        #expect(gutterData.entries.count == 1)
    }

    @Test("Truncated gui_gutter entry throws malformed")
    func decodeGutterTruncatedEntryThrows() throws {
        var entries = Data()
        appendU16(&entries, 1)
        appendU32(&entries, 8)
        entries.append(0)
        entries.append(1)
        // Missing fold_end_line u32.

        var data = Data()
        data.append(OP_GUI_GUTTER)
        data.append(1)
        data.append(contentsOf: buildSectionData(0x03, entries))

        #expect(throws: ProtocolDecodeError.self) {
            _ = try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("Truncated gui_gutter annotation text throws malformed")
    func decodeGutterTruncatedAnnotationThrows() throws {
        var entries = Data()
        appendU16(&entries, 1)
        appendU32(&entries, 8)
        entries.append(0)
        entries.append(8)
        appendU32(&entries, UInt32.max)
        entries.append(contentsOf: [0xAA, 0xBB, 0xCC])
        entries.append(4)
        entries.append(contentsOf: [0xF0, 0x9F])

        var data = Data()
        data.append(OP_GUI_GUTTER)
        data.append(1)
        data.append(contentsOf: buildSectionData(0x03, entries))

        #expect(throws: ProtocolDecodeError.self) {
            _ = try decodeCommand(data: data, offset: 0)
        }
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
        appendU32(&data, 7) // streamInstance
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
        #expect(entries[0].streamInstance == 7)
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
        appendU16(&header, 3) // markedCount

        // Section 0x02: Query
        var query = Data()
        appendString16(&query, "edi")
        appendU32(&query, 7)
        appendU32(&query, 11)

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

        // Section 0x05: Mode prefix
        var modePrefix = Data()
        appendString16(&modePrefix, ">")

        var data = Data()
        data.append(OP_GUI_PICKER)
        data.append(5) // section_count
        data.append(contentsOf: buildSectionData(0x01, header))
        data.append(contentsOf: buildSectionData(0x02, query))
        data.append(contentsOf: buildSectionData(0x03, items))
        data.append(contentsOf: buildSectionData(0x04, actionMenu))
        data.append(contentsOf: buildSectionData(0x05, modePrefix))

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiPicker(let visible, let selectedIndex, let filteredCount, let totalCount, let markedCount, let title, let q, let hasPreview, let decodedItems, let decodedMenu, let modePrefix, _, let queryGeneration, let acknowledgedQueryEditSeq) = cmd else {
            Issue.record("Expected .guiPicker"); return
        }

        #expect(visible == true)
        #expect(selectedIndex == 0)
        #expect(filteredCount == 5)
        #expect(totalCount == 100)
        #expect(markedCount == 3)
        #expect(title == "Find File")
        #expect(q == "edi")
        #expect(queryGeneration == 7)
        #expect(acknowledgedQueryEditSeq == 11)
        #expect(modePrefix == ">")
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

        guard case .guiPicker(let visible, _, _, _, let markedCount, _, _, _, let items, let actionMenu, let modePrefix, _, _, _) = cmd else {
            Issue.record("Expected .guiPicker"); return
        }
        #expect(visible == false)
        #expect(modePrefix.isEmpty)
        #expect(markedCount == 0)
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
        appendU16(&header, 0) // markedCount

        var query = Data()
        appendString16(&query, "")

        var modePrefix = Data()
        appendString16(&modePrefix, "")

        var items = Data()
        appendU16(&items, 0)

        var actionMenu = Data()
        actionMenu.append(0) // not visible

        var data = Data()
        data.append(OP_GUI_PICKER)
        data.append(5)
        data.append(contentsOf: buildSectionData(0x01, header))
        data.append(contentsOf: buildSectionData(0x02, query))
        data.append(contentsOf: buildSectionData(0x05, modePrefix))
        data.append(contentsOf: buildSectionData(0x03, items))
        data.append(contentsOf: buildSectionData(0x04, actionMenu))

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiPicker(let visible, _, _, _, _, _, _, _, _, let am, let modePrefix, _, _, _) = cmd else {
            Issue.record("Expected .guiPicker"); return
        }
        #expect(visible == true)
        #expect(modePrefix == "")
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
    private func buildChatData(status: UInt8 = 0, model: String = "", thinkingLevel: String = "", prompt: String = "",
                                promptLineCount: UInt8 = 1, promptCursorLine: UInt16 = 0, promptCursorCol: UInt16 = 0,
                                promptVimMode: UInt8 = 0, promptVisibleRows: UInt8 = 1,
                                pending: Data? = nil, help: Data? = nil, completion: Data? = nil, includeThinking: Bool = true) -> Data {
        var headerPayload = Data()
        headerPayload.append(1) // visible
        headerPayload.append(status)

        var modelPayload = Data()
        appendString16(&modelPayload, model)

        var promptPayload = Data()
        appendString16(&promptPayload, prompt)
        promptPayload.append(promptLineCount)
        appendU16(&promptPayload, promptCursorLine)
        appendU16(&promptPayload, promptCursorCol)
        promptPayload.append(promptVimMode)
        promptPayload.append(promptVisibleRows)

        let pendingPayload = pending ?? Data([0]) // no pending
        let helpPayload = help ?? Data([0]) // no help
        var thinkingPayload = Data()
        appendString16(&thinkingPayload, thinkingLevel)
        let completionPayload = completion ?? Data([0])

        var data = Data()
        data.append(OP_GUI_AGENT_CHAT)
        data.append(includeThinking ? 8 : 7)
        data.append(contentsOf: buildSectionData(0x01, headerPayload))
        data.append(contentsOf: buildSectionData(0x02, modelPayload))
        data.append(contentsOf: buildSectionData(0x03, promptPayload))
        data.append(contentsOf: buildSectionData(0x04, pendingPayload))
        data.append(contentsOf: buildSectionData(0x05, helpPayload))
        data.append(contentsOf: buildSectionData(0x07, completionPayload))
        if includeThinking {
            data.append(contentsOf: buildSectionData(0x08, thinkingPayload))
        }
        data.append(contentsOf: buildSectionData(0x09, Data([0])))
        return data
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


    @Test("Decode gui_agent_chat ordinary frame with all retained sections")
    func decodeOrdinaryFrameWithAllRetainedSections() throws {
        var help = Data([1, 1])
        appendString16(&help, "Prompt")
        help.append(1)
        appendString8(&help, "C-j")
        appendString16(&help, "accept")
        var completion = Data([1, 2, 1])
        appendU16(&completion, 3)
        appendU16(&completion, 7)
        completion.append(1)
        appendString16(&completion, "write")
        appendString16(&completion, "run command")
        let data = buildChatData(status: 1, model: "claude", thinkingLevel: "high", prompt: "fix",
                                 promptLineCount: 4, promptCursorLine: 2, promptCursorCol: 5,
                                 promptVimMode: 1, promptVisibleRows: 3,
                                 help: help, completion: completion)
        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)
        #expect(data[1] == 8)
        guard case .guiAgentChat(let visible, let status, let model, let thinkingLevel, let prompt, let promptLineCount, let promptCursorLine, let promptCursorCol, let promptVimMode, let promptVisibleRows, let promptCompletion, _, _, let helpVisible, let helpGroups) = cmd else { Issue.record("Expected .guiAgentChat"); return }
        #expect(visible == true)
        #expect(status == 1)
        #expect(model == "claude")
        #expect(thinkingLevel == "high")
        #expect(prompt == "fix")
        #expect(promptLineCount == 4)
        #expect(promptCursorLine == 2)
        #expect(promptCursorCol == 5)
        #expect(promptVimMode == 1)
        #expect(promptVisibleRows == 3)
        #expect(promptCompletion?.type == 2)
        #expect(promptCompletion?.selected == 1)
        #expect(promptCompletion?.anchorLine == 3)
        #expect(promptCompletion?.anchorCol == 7)
        #expect(promptCompletion?.candidates.first?.name == "write")
        #expect(promptCompletion?.candidates.first?.description == "run command")
        #expect(helpVisible == true)
        #expect(helpGroups.first?.title == "Prompt")
        #expect(helpGroups.first?.bindings.first?.key == "C-j")
        #expect(helpGroups.first?.bindings.first?.description == "accept")
    }


    @Test("Decode gui_agent_chat skips retired section 0x06")
    func decodeSkipsRetiredMessagesSection() throws {
        var data = buildChatData(status: 0, model: "claude", thinkingLevel: "later")
        var retiredPayload = Data([0xFF, 1, 0, 1])
        let body = Data([0x01, 0, 0, 0, 2, 0x68, 0x69])
        appendU32(&retiredPayload, UInt32(4 + body.count))
        appendU32(&retiredPayload, 1)
        retiredPayload.append(body)
        let retired = buildSectionData(0x06, retiredPayload)
        data.insert(contentsOf: retired, at: 2 + buildSectionData(0x01, Data([1, 0])).count)
        data[1] += 1
        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        guard case .guiAgentChat(let visible, _, let model, let thinkingLevel, let prompt, _, _, _, _, _, let promptCompletion, let pendingToolName, let pendingToolSummary, let helpVisible, let helpGroups) = cmd else { Issue.record("Expected .guiAgentChat"); return }
        #expect(size == data.count)
        #expect(visible == true)
        #expect(model == "claude")
        #expect(thinkingLevel == "later")
        #expect(prompt == "")
        #expect(promptCompletion == nil)
        #expect(pendingToolName == nil)
        #expect(pendingToolSummary == "")
        #expect(helpVisible == false)
        #expect(helpGroups.isEmpty)
    }


    @Test("Decode gui_agent_chat with pending approval (sectioned)")
    func decodePendingApproval() throws {
        var pendingPayload = Data()
        pendingPayload.append(1) // has pending
        appendString16(&pendingPayload, "write_file")
        appendString16(&pendingPayload, "Writing to config.toml")

        let data = buildChatData(status: 2, model: "claude", pending: pendingPayload)
        let (cmd, _) = try decodeCommand(data: data, offset: 0)
        guard case .guiAgentChat(_, _, _, _, _, _, _, _, _, _, _, let pendingToolName, let pendingToolSummary, _, _) = cmd else { Issue.record("Expected .guiAgentChat"); return }
        #expect(pendingToolName == "write_file")
        #expect(pendingToolSummary == "Writing to config.toml")
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

// MARK: - gui_workspaces (0x98)

@Suite("GUI Workspaces Decoder")
struct GUIWorkspacesDecoderTests {
    @Test("Decode canonical workspaces with visible tabs")
    func decodeCanonicalWorkspaces() throws {
        var payload = Data()
        payload.append(2) // version
        appendU16(&payload, 1) // active_workspace_id
        payload.append(1) // mode = agent
        payload.append(1) // flags = has attention
        payload.append(2) // workspace_count

        appendWorkspace(&payload, id: 0, kind: 0, status: 0, flags: 0, r: 0x51, g: 0xAF, b: 0xEF, tabCount: 2, draftCount: 0, conflictCount: 0, runningBackgroundCount: 0, label: "minga", icon: "folder")
        appendWorkspace(&payload, id: 1, kind: 1, status: 2, flags: 0x0003, r: 0xC6, g: 0x78, b: 0xDD, tabCount: 1, draftCount: 4, conflictCount: 2, runningBackgroundCount: 1, label: "Review", icon: "cpu")

        appendU16(&payload, 1) // visible_tab_count
        appendVisibleTab(&payload, id: 42, workspaceId: 1, kind: 0, flags: 0x0013, pathHash: 0x12345678, icon: "", label: "agent.ex", path: "/tmp/agent.ex")

        var data = Data([OP_GUI_WORKSPACES])
        appendU16(&data, UInt16(payload.count))
        data.append(payload)

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiWorkspaces(let version, let activeId, let mode, let flags, let workspaces, let visibleTabs) = cmd else {
            Issue.record("Expected .guiWorkspaces, got \(String(describing: cmd))")
            return
        }

        #expect(version == 2)
        #expect(activeId == 1)
        #expect(mode == 1)
        #expect(flags == 1)
        #expect(workspaces.count == 2)
        #expect(workspaces[0].kind == 0)
        #expect(workspaces[0].label == "minga")
        #expect(workspaces[1].id == 1)
        #expect(workspaces[1].kind == 1)
        #expect(workspaces[1].agentStatus == 2)
        #expect(workspaces[1].flags == 0x0003)
        #expect(workspaces[1].draftCount == 4)
        #expect(workspaces[1].conflictCount == 2)
        #expect(workspaces[1].runningBackgroundCount == 1)
        #expect(workspaces[1].icon == "cpu")
        #expect(visibleTabs.count == 1)
        #expect(visibleTabs[0].id == 42)
        #expect(visibleTabs[0].workspaceId == 1)
        #expect(visibleTabs[0].flags == 0x0013)
        #expect(visibleTabs[0].pathHash == 0x12345678)
        #expect(visibleTabs[0].tintColorRGB == 0x7AA2F7)
        #expect(visibleTabs[0].label == "agent.ex")
        #expect(visibleTabs[0].path == "/tmp/agent.ex")
    }

    @Test("Decode legacy version 1 workspaces without tint color")
    func decodeLegacyVersion1() throws {
        var payload = Data()
        payload.append(1) // version
        appendU16(&payload, 1) // active_workspace_id
        payload.append(0) // mode = editor
        payload.append(0) // flags
        payload.append(1) // workspace_count

        appendWorkspace(&payload, id: 1, kind: 0, status: 0, flags: 0, r: 0x51, g: 0xAF, b: 0xEF, tabCount: 1, draftCount: 0, conflictCount: 0, runningBackgroundCount: 0, label: "minga", icon: "folder")

        appendU16(&payload, 1) // visible_tab_count
        appendVisibleTab(&payload, id: 42, workspaceId: 1, kind: 0, flags: 0x0013, pathHash: 0x12345678, icon: "", label: "agent.ex", path: "/tmp/agent.ex", tintColorRGB: nil)

        var data = Data([OP_GUI_WORKSPACES])
        appendU16(&data, UInt16(payload.count))
        data.append(payload)

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiWorkspaces(let version, _, _, _, _, let visibleTabs) = cmd else {
            Issue.record("Expected .guiWorkspaces, got \(String(describing: cmd))")
            return
        }

        #expect(version == 1)
        #expect(visibleTabs.count == 1)
        #expect(visibleTabs[0].id == 42)
        #expect(visibleTabs[0].tintColorRGB == 0)
    }

    @Test("Decode canonical workspaces with zero workspaces and tabs")
    func decodeEmpty() throws {
        var payload = Data()
        payload.append(2) // version
        appendU16(&payload, 0) // active_workspace_id
        payload.append(0) // mode = editor
        payload.append(0) // flags
        payload.append(0) // workspace_count
        appendU16(&payload, 0) // visible_tab_count

        var data = Data([OP_GUI_WORKSPACES])
        appendU16(&data, UInt16(payload.count))
        data.append(payload)

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiWorkspaces(_, _, _, _, let workspaces, let visibleTabs) = cmd else {
            Issue.record("Expected .guiWorkspaces")
            return
        }
        #expect(workspaces.isEmpty)
        #expect(visibleTabs.isEmpty)
    }

    @Test("Truncated canonical workspace payload throws malformed")
    func truncatedPayloadThrows() {
        let data = Data([OP_GUI_WORKSPACES, 0, 8, 1, 0, 0, 0])

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("Invalid UTF-8 in canonical workspace payload throws malformed")
    func invalidUTF8Throws() {
        var payload = Data()
        payload.append(2) // version
        appendU16(&payload, 1) // active_workspace_id
        payload.append(1) // mode = agent
        payload.append(0) // flags
        payload.append(1) // workspace_count
        appendU16(&payload, 1) // id
        payload.append(1) // kind = agent
        payload.append(0) // status = idle
        appendU16(&payload, 0) // flags
        appendRGB(&payload, 0xC6, 0x78, 0xDD)
        appendU16(&payload, 1) // tab_count
        appendU16(&payload, 0) // draft_count
        appendU16(&payload, 0) // conflict_count
        appendU16(&payload, 0) // running_background_count
        payload.append(1) // label_len
        payload.append(0xFF) // invalid UTF-8 label
        payload.append(0) // icon_len
        appendU16(&payload, 0) // visible_tab_count

        var data = Data([OP_GUI_WORKSPACES])
        appendU16(&data, UInt16(payload.count))
        data.append(payload)

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    private func appendWorkspace(_ data: inout Data, id: UInt16, kind: UInt8, status: UInt8, flags: UInt16, r: UInt8, g: UInt8, b: UInt8, tabCount: UInt16, draftCount: UInt16, conflictCount: UInt16, runningBackgroundCount: UInt16, label: String, icon: String) {
        appendU16(&data, id)
        data.append(kind)
        data.append(status)
        appendU16(&data, flags)
        appendRGB(&data, r, g, b)
        appendU16(&data, tabCount)
        appendU16(&data, draftCount)
        appendU16(&data, conflictCount)
        appendU16(&data, runningBackgroundCount)
        appendString8(&data, label)
        appendString8(&data, icon)
    }

    private func appendVisibleTab(_ data: inout Data, id: UInt32, workspaceId: UInt16, kind: UInt8, flags: UInt16, pathHash: UInt32, icon: String, label: String, path: String, tintColorRGB: UInt32? = 0x7AA2F7) {
        appendU32(&data, id)
        appendU16(&data, workspaceId)
        data.append(kind)
        appendU16(&data, flags)
        appendU32(&data, pathHash)
        appendString8(&data, icon)
        appendString16(&data, label)
        appendString16(&data, path)
        if let tintColorRGB {
            appendU32(&data, tintColorRGB)
        }
    }
}

// MARK: - gui_hover_popup (0x81)

@Suite("GUI Hover Popup Decoder")
struct GUIHoverPopupDecoderTests {
    @Test("Decode syntax highlighted hover segment")
    func decodeSyntaxHighlightedSegment() throws {
        var data = Data()
        data.append(OP_GUI_HOVER_POPUP)
        data.append(1) // visible
        appendU16(&data, 10) // anchor_row
        appendU16(&data, 5) // anchor_col
        data.append(0) // focused
        appendU16(&data, 0) // scroll_offset
        appendU16(&data, 1) // line_count
        data.append(1) // line_type = code
        appendU16(&data, 1) // segment_count
        data.append(13) // syntaxHighlighted
        appendRGB(&data, 0xC6, 0x78, 0xDD)
        data.append(0x07) // bold + italic + underline
        appendString16(&data, "def")

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiHoverPopup(let visible, let anchorRow, let anchorCol, let focused, let scrollOffset, let lines) = cmd else {
            Issue.record("Expected .guiHoverPopup"); return
        }

        #expect(visible)
        #expect(anchorRow == 10)
        #expect(anchorCol == 5)
        #expect(!focused)
        #expect(scrollOffset == 0)
        #expect(lines.count == 1)
        #expect(lines[0].lineType == .code)
        #expect(lines[0].segments.count == 1)
        #expect(lines[0].segments[0].style == .syntaxHighlighted)
        #expect(lines[0].segments[0].fgColor == 0xC678DD)
        #expect(lines[0].segments[0].flags == 0x07)
        #expect(lines[0].segments[0].text == "def")
    }

    @Test("Truncated syntax metadata throws malformed")
    func truncatedSyntaxMetadataThrows() {
        var data = hoverHeader(lineCount: 1)
        data.append(1) // line_type = code
        appendU16(&data, 1) // segment_count
        data.append(13) // syntaxHighlighted, missing RGB + flags + len
        data.append(0xC6)

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("Truncated syntax text throws malformed")
    func truncatedSyntaxTextThrows() {
        var data = hoverHeader(lineCount: 1)
        data.append(1) // line_type = code
        appendU16(&data, 1) // segment_count
        data.append(13) // syntaxHighlighted
        appendRGB(&data, 0xC6, 0x78, 0xDD)
        data.append(0x00)
        appendU16(&data, 5)
        data.append(contentsOf: Array("de".utf8))

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    private func hoverHeader(lineCount: UInt16) -> Data {
        var data = Data()
        data.append(OP_GUI_HOVER_POPUP)
        data.append(1) // visible
        appendU16(&data, 10) // anchor_row
        appendU16(&data, 5) // anchor_col
        data.append(0) // focused
        appendU16(&data, 0) // scroll_offset
        appendU16(&data, lineCount)
        return data
    }
}


// MARK: - gui_git_status (0x85)

@Suite("GUI Git Status Decoder")
struct GUIGitStatusDecoderTests {
    @Test("Decode gui_git_status with syncing, entries, and toast")
    func decodeGitStatusWithToast() throws {
        var data = Data()
        data.append(OP_GUI_GIT_STATUS)
        data.append(0) // normal repo
        data.append(1) // syncing
        appendU16(&data, 2) // ahead
        appendU16(&data, 1) // behind
        appendString16(&data, "feature/git")
        appendU16(&data, 1) // entry_count
        appendU32(&data, 0x01020304) // path_hash
        data.append(1) // changed section
        data.append(1) // modified status
        appendString16(&data, "lib/editor.ex")
        data.append(1) // toast_present
        data.append(1) // error level
        data.append(1) // pull_and_retry action
        appendString16(&data, "Push failed: fetch first")
        appendString16(&data, "/repo")
        appendString16(&data, "feat: previous commit")
        appendU16(&data, 3) // stash_count

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiGitStatus(let repoState, let syncing, let ahead, let behind, let branchName, let entries, let toast, let entryBasePath, let lastCommitMessage, let stashCount) = cmd else {
            Issue.record("Expected .guiGitStatus"); return
        }

        #expect(repoState == 0)
        #expect(syncing == true)
        #expect(ahead == 2)
        #expect(behind == 1)
        #expect(branchName == "feature/git")
        #expect(entries.count == 1)
        #expect(entries[0].pathHash == 0x01020304)
        #expect(entries[0].section == 1)
        #expect(entries[0].status == 1)
        #expect(entries[0].path == "lib/editor.ex")
        #expect(toast?.message == "Push failed: fetch first")
        #expect(toast?.level == 1)
        #expect(toast?.action == 1)
        #expect(entryBasePath == "/repo")
        #expect(lastCommitMessage == "feat: previous commit")
        #expect(stashCount == 3)
    }

    @Test("Invalid repo state in gui_git_status throws malformed")
    func invalidGitStatusRepoStateThrows() {
        var data = Data()
        data.append(OP_GUI_GIT_STATUS)
        data.append(99) // invalid repo_state
        data.append(0) // not syncing
        appendU16(&data, 0) // ahead
        appendU16(&data, 0) // behind
        appendString16(&data, "main")
        appendU16(&data, 0) // entry_count
        data.append(0) // toast_present

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("Invalid syncing byte in gui_git_status throws malformed")
    func invalidGitStatusSyncingThrows() {
        var data = Data()
        data.append(OP_GUI_GIT_STATUS)
        data.append(0) // normal repo
        data.append(2) // invalid syncing
        appendU16(&data, 0) // ahead
        appendU16(&data, 0) // behind
        appendString16(&data, "main")
        appendU16(&data, 0) // entry_count
        data.append(0) // toast_present

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("Invalid UTF-8 branch in gui_git_status throws malformed")
    func invalidGitStatusBranchUTF8Throws() {
        var data = Data()
        data.append(OP_GUI_GIT_STATUS)
        data.append(0) // normal repo
        data.append(0) // not syncing
        appendU16(&data, 0) // ahead
        appendU16(&data, 0) // behind
        appendU16(&data, 1) // branch_len
        data.append(0xFF) // invalid UTF-8
        appendU16(&data, 0) // entry_count
        data.append(0) // toast_present

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("Invalid entry section in gui_git_status throws malformed")
    func invalidGitStatusEntrySectionThrows() {
        var data = Data()
        data.append(OP_GUI_GIT_STATUS)
        data.append(0) // normal repo
        data.append(0) // not syncing
        appendU16(&data, 0) // ahead
        appendU16(&data, 0) // behind
        appendString16(&data, "main")
        appendU16(&data, 1) // entry_count
        appendU32(&data, 0x01020304)
        data.append(99) // invalid section
        data.append(1) // modified status
        appendString16(&data, "lib/editor.ex")
        data.append(0) // toast_present

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("Invalid entry status in gui_git_status throws malformed")
    func invalidGitStatusEntryStatusThrows() {
        var data = Data()
        data.append(OP_GUI_GIT_STATUS)
        data.append(0) // normal repo
        data.append(0) // not syncing
        appendU16(&data, 0) // ahead
        appendU16(&data, 0) // behind
        appendString16(&data, "main")
        appendU16(&data, 1) // entry_count
        appendU32(&data, 0x01020304)
        data.append(1) // changed section
        data.append(99) // invalid status
        appendString16(&data, "lib/editor.ex")
        data.append(0) // toast_present

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("Invalid UTF-8 path in gui_git_status throws malformed")
    func invalidGitStatusPathUTF8Throws() {
        var data = Data()
        data.append(OP_GUI_GIT_STATUS)
        data.append(0) // normal repo
        data.append(0) // not syncing
        appendU16(&data, 0) // ahead
        appendU16(&data, 0) // behind
        appendString16(&data, "main")
        appendU16(&data, 1) // entry_count
        appendU32(&data, 0x01020304)
        data.append(1) // changed section
        data.append(1) // modified status
        appendU16(&data, 1) // path_len
        data.append(0xFF) // invalid UTF-8
        data.append(0) // toast_present

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("Invalid UTF-8 toast in gui_git_status throws malformed")
    func invalidGitStatusToastUTF8Throws() {
        var data = Data()
        data.append(OP_GUI_GIT_STATUS)
        data.append(0) // normal repo
        data.append(0) // not syncing
        appendU16(&data, 0) // ahead
        appendU16(&data, 0) // behind
        appendString16(&data, "main")
        appendU16(&data, 0) // entry_count
        data.append(1) // toast_present
        data.append(1) // error level
        data.append(1) // pull_and_retry action
        appendU16(&data, 1) // msg_len
        data.append(0xFF) // invalid UTF-8

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("Invalid toast presence byte in gui_git_status throws malformed")
    func invalidGitStatusToastPresenceThrows() {
        var data = Data()
        data.append(OP_GUI_GIT_STATUS)
        data.append(0) // normal repo
        data.append(0) // not syncing
        appendU16(&data, 0) // ahead
        appendU16(&data, 0) // behind
        appendString16(&data, "main")
        appendU16(&data, 0) // entry_count
        data.append(2) // invalid toast_present

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }
}

// MARK: - gui_agent_transcript (0x86) decode

/// Decoder tests for the resident agent-chat transcript stream (#2654 slice 2).
/// The per-message body reuses the shared AgentChatMessageCodec contract, so these fixtures
/// build bodies without the leading id (which 0x86 carries in its entry header).
@Suite("gui_agent_transcript decode (0x86)")
struct AgentTranscriptDecoderTests {
    /// Builds a full_replace 0x86 frame: opcode + payload_len(4) + header
    /// (version(1)=1 + mode(1)=0 + epoch(4) + truncated(1)) + count(4) + entries.
    private func buildFullReplace(epoch: UInt32, truncated: Bool = false,
                                  entries: [(id: UInt32, body: Data)]) -> Data {
        var payload = Data()
        payload.append(1) // version
        payload.append(0) // mode = full_replace
        appendU32(&payload, epoch)
        payload.append(truncated ? 1 : 0)
        appendU32(&payload, UInt32(entries.count))
        appendEntries(&payload, entries)
        return frame(payload)
    }

    /// Builds an append 0x86 frame: header + trim_front(4) + base_count(4) + count(4) + entries.
    private func buildAppend(epoch: UInt32, truncated: Bool = false, trimFront: UInt32,
                             baseCount: UInt32, entries: [(id: UInt32, body: Data)]) -> Data {
        var payload = Data()
        payload.append(1) // version
        payload.append(1) // mode = append
        appendU32(&payload, epoch)
        payload.append(truncated ? 1 : 0)
        appendU32(&payload, trimFront)
        appendU32(&payload, baseCount)
        appendU32(&payload, UInt32(entries.count))
        appendEntries(&payload, entries)
        return frame(payload)
    }

    private func appendEntries(_ payload: inout Data, _ entries: [(id: UInt32, body: Data)]) {
        for entry in entries {
            appendU32(&payload, entry.id)
            appendU32(&payload, UInt32(entry.body.count))
            payload.append(entry.body)
        }
    }

    private func frame(_ payload: Data) -> Data {
        var data = Data()
        data.append(OP_GUI_AGENT_TRANSCRIPT)
        appendU32(&data, UInt32(payload.count))
        data.append(payload)
        return data
    }

    /// user message body (sub-opcode 0x01), matching the shared codec minus the id.
    private func userBody(_ text: String) -> Data {
        var d = Data()
        d.append(0x01)
        appendU32(&d, UInt32(text.utf8.count))
        d.append(contentsOf: text.utf8)
        return d
    }

    /// assistant message body (sub-opcode 0x02).
    private func assistantBody(_ text: String) -> Data {
        var d = Data()
        d.append(0x02)
        appendU32(&d, UInt32(text.utf8.count))
        d.append(contentsOf: text.utf8)
        return d
    }

    @Test("full_replace decodes header and messages")
    func fullReplace() throws {
        let data = buildFullReplace(epoch: 7, truncated: true, entries: [
            (id: 1, body: userBody("hello")),
            (id: 2, body: assistantBody("hi there"))
        ])

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiAgentTranscript(let mode, let epoch, let truncated, let trimFront, let baseCount, let messages) = cmd else {
            Issue.record("Expected .guiAgentTranscript"); return
        }
        #expect(mode == 0)
        #expect(epoch == 7)
        #expect(truncated == true)
        #expect(trimFront == 0)
        #expect(baseCount == 0)
        guard messages.count == 2 else { Issue.record("Expected 2 messages"); return }
        #expect(messages[0].beamId == 1)
        guard case .user(let t0) = messages[0].content else { Issue.record("Expected .user"); return }
        #expect(t0 == "hello")
        #expect(messages[1].beamId == 2)
        guard case .assistant(let t1) = messages[1].content else { Issue.record("Expected .assistant"); return }
        #expect(t1 == "hi there")
    }

    @Test("append decodes trim_front, base_count, and the suffix entries")
    func appendSuffix() throws {
        let data = buildAppend(epoch: 7, trimFront: 1, baseCount: 2, entries: [
            (id: 3, body: assistantBody("streaming..."))
        ])

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiAgentTranscript(let mode, let epoch, let truncated, let trimFront, let baseCount, let messages) = cmd else {
            Issue.record("Expected .guiAgentTranscript"); return
        }
        #expect(mode == 1)
        #expect(epoch == 7)
        #expect(truncated == false)
        #expect(trimFront == 1)
        #expect(baseCount == 2)
        #expect(messages.count == 1)
        #expect(messages[0].beamId == 3)
    }

    @Test("append with eviction only (zero entries) decodes trim_front")
    func appendEvictionOnly() throws {
        let data = buildAppend(epoch: 4, trimFront: 3, baseCount: 5, entries: [])

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiAgentTranscript(let mode, _, _, let trimFront, let baseCount, let messages) = cmd else {
            Issue.record("Expected .guiAgentTranscript"); return
        }
        #expect(mode == 1)
        #expect(trimFront == 3)
        #expect(baseCount == 5)
        #expect(messages.isEmpty)
    }

    @Test("empty full_replace decodes to zero messages")
    func emptyTranscript() throws {
        let data = buildFullReplace(epoch: 1, entries: [])
        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)
        guard case .guiAgentTranscript(_, _, _, _, _, let messages) = cmd else {
            Issue.record("Expected .guiAgentTranscript"); return
        }
        #expect(messages.isEmpty)
    }

    @Test("unknown version throws malformed")
    func unknownVersionThrows() {
        var data = buildFullReplace(epoch: 1, entries: [(id: 1, body: userBody("x"))])
        // version byte is at offset 5 (opcode + 4-byte len).
        data[5] = 2
        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("append payload too short for its header throws malformed")
    func appendHeaderTooShortThrows() {
        // A valid full_replace-length payload (11 bytes) but mode=append needs 19.
        var payload = Data()
        payload.append(1) // version
        payload.append(1) // mode = append
        appendU32(&payload, 1) // epoch
        payload.append(0) // truncated
        appendU32(&payload, 0) // only 4 more bytes; append needs trim_front+base+count

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: frame(payload), offset: 0)
        }
    }

    @Test("count larger than entries throws malformed")
    func countOverrunThrows() {
        // Hand-build a full_replace frame claiming 2 entries but supplying one.
        var payload = Data()
        payload.append(1) // version
        payload.append(0) // mode full_replace
        appendU32(&payload, 1) // epoch
        payload.append(0) // truncated
        appendU32(&payload, 2) // count = 2 (lie)
        appendU32(&payload, 1) // id
        let body = userBody("x")
        appendU32(&payload, UInt32(body.count))
        payload.append(body)

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: frame(payload), offset: 0)
        }
    }

    @Test("truncated body length throws malformed")
    func truncatedBodyThrows() {
        var payload = Data()
        payload.append(1) // version
        payload.append(0) // mode
        appendU32(&payload, 1) // epoch
        payload.append(0) // truncated
        appendU32(&payload, 1) // count
        appendU32(&payload, 1) // id
        appendU32(&payload, 99) // body_len larger than actual body
        payload.append(0x01) // partial body

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: frame(payload), offset: 0)
        }
    }

    @Test("malformed UTF8 body throws malformed")
    func malformedUTF8BodyThrows() {
        var body = Data([0x01])
        appendU32(&body, 1)
        body.append(0xFF)
        let data = buildFullReplace(epoch: 1, entries: [(id: 1, body: body)])

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("body-local overrun throws malformed")
    func bodyLocalOverrunThrows() {
        var body = userBody("x")
        body.append(0xAA)
        let data = buildFullReplace(epoch: 1, entries: [(id: 1, body: body)])

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("unknown mode throws malformed instead of a split-brain parse")
    func unknownModeThrows() {
        // Only modes 0/1 exist. An unknown mode must be rejected at decode: the
        // decoder's layout branch is append-shaped (mode == 1) while the consumer's
        // apply branch is full_replace-shaped (mode == 0), so a mode that passed
        // through would be parsed with one layout and applied with the other.
        var payload = Data()
        payload.append(1) // version
        payload.append(2) // mode = unknown
        appendU32(&payload, 1) // epoch
        payload.append(0) // truncated
        appendU32(&payload, 0) // count

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: frame(payload), offset: 0)
        }
    }

    @Test("a corrupt huge count throws malformed instead of a giant allocation")
    func hugeCountThrows() {
        var payload = Data()
        payload.append(1) // version
        payload.append(0) // mode full_replace
        appendU32(&payload, 1) // epoch
        payload.append(0) // truncated
        appendU32(&payload, 0xFFFF_FFFF) // count far beyond the payload

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: frame(payload), offset: 0)
        }
    }

    private func styledRun(_ text: String, flags: UInt8 = 0x00, linkURL: String? = nil) -> Data {
        var d = Data()
        appendString16(&d, text)
        d.append(contentsOf: [0x61, 0xAF, 0xFE, 0x21, 0x24, 0x2B, flags])
        if let linkURL {
            appendString16(&d, linkURL)
        }
        return d
    }

    private func styledLines(_ runs: [Data]) -> Data {
        var d = Data()
        appendU16(&d, 1)
        appendU16(&d, UInt16(runs.count))
        for run in runs {
            d.append(run)
        }
        return d
    }

    private func thinkingBody(_ text: String, collapsed: Bool) -> Data {
        var d = Data([0x03, collapsed ? UInt8(1) : UInt8(0)])
        appendU32(&d, UInt32(text.utf8.count))
        d.append(contentsOf: text.utf8)
        return d
    }

    private func systemBody(_ text: String, isError: Bool) -> Data {
        var d = Data([0x05, isError ? UInt8(1) : UInt8(0)])
        appendU32(&d, UInt32(text.utf8.count))
        d.append(contentsOf: text.utf8)
        return d
    }

    private func usageBody() -> Data {
        var d = Data([0x06])
        appendU32(&d, 1)
        appendU32(&d, 2)
        appendU32(&d, 3)
        appendU32(&d, 4)
        appendU32(&d, 5)
        return d
    }

    private func styledAssistantBody() -> Data {
        var d = Data([0x07])
        d.append(styledLines([styledRun("docs", flags: 0x08, linkURL: "https://example.test")]))
        return d
    }

    private func styledToolBody() -> Data {
        var d = Data([0x08, 2, 1, 0])
        appendU32(&d, 42)
        appendString16(&d, "shell")
        appendString16(&d, "ran")
        d.append(styledLines([styledRun("ok", flags: 0x10)]))
        d.append(1)
        d.append(3)
        appendU16(&d, 1)
        appendString16(&d, "scope")
        return d
    }

    private func approvalBody() -> Data {
        var d = Data([0x09, 0])
        appendString16(&d, "edit")
        appendString16(&d, "needs ok")
        appendString16(&d, "tc")
        d.append(2)
        appendU16(&d, 1)
        appendString16(&d, "mix test")
        return d
    }

    private func markdownBody() -> Data {
        var d = Data([0x0A])
        appendU16(&d, 1)
        appendU32(&d, 99)
        d.append(0x01)
        d.append(0x01)
        d.append(styledLines([styledRun("paragraph")]))
        return d
    }

    @Test("retained body kinds decode representative fields")
    func retainedBodyKindsDecodeRepresentativeFields() throws {
        let data = buildFullReplace(epoch: 8, entries: [
            (id: 1, body: thinkingBody("thought", collapsed: true)),
            (id: 2, body: systemBody("system", isError: true)),
            (id: 3, body: usageBody()),
            (id: 4, body: styledAssistantBody()),
            (id: 5, body: styledToolBody()),
            (id: 6, body: approvalBody()),
            (id: 7, body: markdownBody())
        ])

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)
        guard case .guiAgentTranscript(_, _, _, _, _, let messages) = cmd else { Issue.record("Expected .guiAgentTranscript"); return }
        guard case .thinking("thought", true) = messages[0].content else { Issue.record("Expected thinking"); return }
        guard case .system("system", true) = messages[1].content else { Issue.record("Expected system"); return }
        guard case .usage(1, 2, 3, 4, 5) = messages[2].content else { Issue.record("Expected usage"); return }
        guard case .styledAssistant(let lines) = messages[3].content else { Issue.record("Expected styled assistant"); return }
        #expect(lines[0][0].linkURL == "https://example.test")
        guard case .styledToolCall("shell", "ran", 2, true, false, 1, 42, let resultLines, 3, let previewLines) = messages[4].content else { Issue.record("Expected styled tool"); return }
        #expect(resultLines[0][0].code)
        #expect(previewLines == ["scope"])
        guard case .approvalToolCall("edit", "needs ok", "tc", 2, let approvalPreview) = messages[5].content else { Issue.record("Expected approval"); return }
        #expect(approvalPreview == ["mix test"])
        guard case .assistantMarkdown(let blocks) = messages[6].content else { Issue.record("Expected markdown"); return }
        #expect(blocks[0].isComplete)
    }

    @Test("invalid UTF8 link URL throws malformed")
    func invalidUTF8LinkURLThrows() {
        var body = Data([0x07])
        var run = styledRun("docs", flags: 0x08)
        appendU16(&run, 1)
        run.append(0xFF)
        body.append(styledLines([run]))
        let data = buildFullReplace(epoch: 1, entries: [(id: 1, body: body)])

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    @Test("body-local string overrun throws malformed")
    func bodyLocalStringOverrunThrows() {
        var body = Data([0x05, 0])
        appendU32(&body, 9)
        body.append(contentsOf: "short".utf8)
        let data = buildFullReplace(epoch: 1, entries: [(id: 1, body: body)])

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommand(data: data, offset: 0)
        }
    }

    /// tool_call message body (sub-opcode 0x04) with an optional preview section.
    /// This is the one body kind that yields MULTIPLE decode candidates (with and
    /// without the preview), so it is what actually exercises the 0x86 path's
    /// exact-consumption disambiguation.
    private func toolCallBody(withPreview: Bool) -> Data {
        var d = Data()
        d.append(0x04) // tool_call
        d.append(1) // status
        d.append(0) // isError
        d.append(1) // collapsed
        appendU32(&d, 1234) // durationMs
        appendString16(&d, "read_file")
        appendString16(&d, "lib/minga.ex")
        let result = "file contents here"
        appendU32(&d, UInt32(result.utf8.count))
        d.append(contentsOf: result.utf8)
        d.append(2) // autoApprovedScope
        if withPreview {
            d.append(1) // previewKind diff
            appendU16(&d, 2)
            appendString16(&d, "-old")
            appendString16(&d, "+new")
        }
        return d
    }

    @Test("tool_call bodies disambiguate via exact consumption", arguments: [true, false])
    func toolCallExactConsumption(withPreview: Bool) throws {
        let data = buildFullReplace(epoch: 3, entries: [
            (id: 5, body: toolCallBody(withPreview: withPreview))
        ])

        let (cmd, _) = try decodeCommand(data: data, offset: 0)
        guard case .guiAgentTranscript(_, _, _, _, _, let messages) = cmd else {
            Issue.record("Expected .guiAgentTranscript"); return
        }
        guard messages.count == 1,
              case .toolCall(let name, _, _, _, _, _, _, _, _, let previewLines) = messages[0].content else {
            Issue.record("Expected one toolCall message"); return
        }
        #expect(name == "read_file")
        #expect(previewLines.isEmpty == !withPreview)
    }

}
