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

        // Tab 1: active, dirty, file tab
        let flags1: UInt8 = 0x01 | 0x02 // active + dirty
        data.append(flags1)
        appendU32(&data, 42) // id
        appendString8(&data, "") // icon (Nerd Font, can be multi-byte)
        appendString16(&data, "editor.ex")

        // Tab 2: agent tab, has attention
        let flags2: UInt8 = 0x04 | 0x08 | (1 << 4) // agent + attention + agentStatus=1
        data.append(flags2)
        appendU32(&data, 99) // id
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
        #expect(tabs[0].isActive == true)
        #expect(tabs[0].isDirty == true)
        #expect(tabs[0].isAgent == false)
        #expect(tabs[0].label == "editor.ex")
        #expect(tabs[1].id == 99)
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
    @Test("Decode gui_status_bar buffer variant")
    func decodeBufferVariant() throws {
        var data = Data()
        data.append(OP_GUI_STATUS_BAR)
        data.append(0) // contentKind = buffer
        data.append(1) // mode = insert
        appendU32(&data, 42) // cursorLine
        appendU32(&data, 9) // cursorCol
        appendU32(&data, 500) // lineCount
        data.append(0x03) // flags (has_lsp + has_git)
        data.append(1) // lspStatus = ready
        appendString8(&data, "main") // gitBranch
        appendString16(&data, "-- INSERT --") // message
        appendString8(&data, "elixir") // filetype
        appendU16(&data, 3) // errorCount
        appendU16(&data, 7) // warningCount
        // Extended buffer fields
        appendU16(&data, 1) // infoCount
        appendU16(&data, 2) // hintCount
        data.append(0) // macroRecording
        data.append(1) // parserStatus
        data.append(0) // agentStatus
        appendU16(&data, 5) // gitAdded
        appendU16(&data, 3) // gitModified
        appendU16(&data, 1) // gitDeleted
        appendString8(&data, "") // icon
        data.append(0); data.append(0); data.append(0) // icon color RGB
        appendString16(&data, "editor.ex") // filename

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiStatusBar(let contentKind, let mode, let cursorLine, let cursorCol,
                                  let lineCount, let flags, let lspStatus, let gitBranch,
                                  let message, let filetype, let errorCount, let warningCount,
                                  _, _, _,
                                  let infoCount, let hintCount, let macroRecording,
                                  let parserStatus, let agentStatus,
                                  let gitAdded, let gitModified, let gitDeleted,
                                  _, _, _, _, let filename) = cmd else {
            Issue.record("Expected .guiStatusBar"); return
        }

        #expect(contentKind == 0)
        #expect(mode == 1) // insert
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

    @Test("Decode gui_status_bar agent variant with model and session status")
    func decodeAgentVariant() throws {
        var data = Data()
        data.append(OP_GUI_STATUS_BAR)
        data.append(1) // contentKind = agent
        data.append(0) // mode = normal
        appendU32(&data, 0) // cursorLine
        appendU32(&data, 0) // cursorCol
        appendU32(&data, 0) // lineCount
        data.append(0) // flags
        data.append(0) // lspStatus
        appendString8(&data, "") // gitBranch (empty)
        appendString16(&data, "") // message (empty)
        appendString8(&data, "") // filetype (empty)
        appendU16(&data, 0) // errorCount
        appendU16(&data, 0) // warningCount
        // Agent-only fields
        appendString8(&data, "claude-3-5-sonnet") // modelName
        appendU32(&data, 12) // messageCount
        data.append(1) // sessionStatus = thinking

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiStatusBar(let contentKind, _, _, _, _, _, _, _, _, _, _, _, let modelName, let messageCount, let sessionStatus, _, _, _, _, _, _, _, _, _, _, _, _, _) = cmd else {
            Issue.record("Expected .guiStatusBar"); return
        }

        #expect(contentKind == 1)
        #expect(modelName == "claude-3-5-sonnet")
        #expect(messageCount == 12)
        #expect(sessionStatus == 1) // thinking
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
    @Test("Decode gui_gutter with entries")
    func decodeGutter() throws {
        var data = Data()
        data.append(OP_GUI_GUTTER)
        appendU16(&data, 1) // windowId
        appendU16(&data, 0) // contentRow
        appendU16(&data, 5) // contentCol
        appendU16(&data, 24) // contentHeight
        data.append(1) // isActive
        appendU32(&data, 10) // cursorLine
        data.append(0) // lineNumberStyle = hybrid
        data.append(4) // lineNumberWidth
        data.append(1) // signColWidth
        appendU16(&data, 3) // lineCount (entry count)

        // Entry 1: normal line
        appendU32(&data, 8) // bufLine
        data.append(0) // displayType = normal
        data.append(1) // signType = gitAdded

        // Entry 2: fold start
        appendU32(&data, 9) // bufLine
        data.append(1) // displayType = foldStart
        data.append(0) // signType = none

        // Entry 3: wrap continuation
        appendU32(&data, 10) // bufLine
        data.append(3) // displayType = wrapContinuation
        data.append(4) // signType = diagError

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
        #expect(gutterData.entries[0].displayType == .normal)
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
    @Test("Decode gui_picker visible with items and action menu")
    func decodeVisible() throws {
        var data = Data()
        data.append(OP_GUI_PICKER)
        data.append(1) // visible
        appendU16(&data, 0) // selectedIndex
        appendU16(&data, 5) // filteredCount
        appendU16(&data, 100) // totalCount
        appendString16(&data, "Find File") // title
        appendString16(&data, "edi") // query
        data.append(1) // hasPreview
        appendU16(&data, 2) // itemCount

        // Item 1
        appendRGB(&data, 0x51, 0xAF, 0xEF) // iconColor
        data.append(0x01) // flags = two_line
        appendString16(&data, "editor.ex") // label
        appendString16(&data, "lib/minga/editor.ex") // description
        appendString16(&data, "500 lines") // annotation
        data.append(2) // matchPosCount
        appendU16(&data, 0) // match pos 0
        appendU16(&data, 1) // match pos 1

        // Item 2
        appendRGB(&data, 0x98, 0xBE, 0x65) // iconColor
        data.append(0x02) // flags = marked
        appendString16(&data, "edit_delta.ex") // label
        appendString16(&data, "lib/minga/buffer/edit_delta.ex") // description
        appendString16(&data, "") // annotation
        data.append(0) // matchPosCount

        // Action menu: visible
        data.append(1) // actionMenuVisible
        data.append(0) // actionSelected
        data.append(2) // actionCount
        appendString16(&data, "Open") // action 1
        appendString16(&data, "Split Right") // action 2

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiPicker(let visible, let selectedIndex, let filteredCount, let totalCount, let title, let query, let hasPreview, let items, let actionMenu) = cmd else {
            Issue.record("Expected .guiPicker"); return
        }

        #expect(visible == true)
        #expect(selectedIndex == 0)
        #expect(filteredCount == 5)
        #expect(totalCount == 100)
        #expect(title == "Find File")
        #expect(query == "edi")
        #expect(hasPreview == true)
        #expect(items.count == 2)
        #expect(items[0].label == "editor.ex")
        #expect(items[0].description == "lib/minga/editor.ex")
        #expect(items[0].annotation == "500 lines")
        #expect(items[0].isTwoLine == true)
        #expect(items[0].isMarked == false)
        #expect(items[0].matchPositions == [0, 1])
        #expect(items[1].label == "edit_delta.ex")
        #expect(items[1].isMarked == true)
        #expect(items[1].matchPositions.isEmpty)

        #expect(actionMenu != nil)
        #expect(actionMenu?.selectedIndex == 0)
        #expect(actionMenu?.actions == ["Open", "Split Right"])
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

    @Test("Decode gui_picker visible without action menu")
    func decodeNoActionMenu() throws {
        var data = Data()
        data.append(OP_GUI_PICKER)
        data.append(1) // visible
        appendU16(&data, 0)
        appendU16(&data, 0)
        appendU16(&data, 0)
        appendString16(&data, "")
        appendString16(&data, "")
        data.append(0) // hasPreview
        appendU16(&data, 0) // itemCount
        data.append(0) // actionMenuVisible = false

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiPicker(let visible, _, _, _, _, _, _, _, let actionMenu) = cmd else {
            Issue.record("Expected .guiPicker"); return
        }
        #expect(visible == true)
        #expect(actionMenu == nil)
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
    @Test("Decode gui_agent_chat hidden")
    func decodeHidden() throws {
        let data = Data([OP_GUI_AGENT_CHAT, 0])

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 2)

        guard case .guiAgentChat(let visible, _, _, _, _, _, _) = cmd else {
            Issue.record("Expected .guiAgentChat"); return
        }
        #expect(visible == false)
    }

    @Test("Decode gui_agent_chat with user and assistant messages")
    func decodeUserAndAssistant() throws {
        var data = Data()
        data.append(OP_GUI_AGENT_CHAT)
        data.append(1) // visible
        data.append(1) // status = thinking
        appendString16(&data, "claude-3") // model
        appendString16(&data, "Fix this bug") // prompt
        data.append(0) // no pending approval
        appendU16(&data, 2) // messageCount

        // Message 1: user
        data.append(0x01) // type=user
        appendU32(&data, UInt32("hello".utf8.count))
        data.append(contentsOf: "hello".utf8)

        // Message 2: assistant
        data.append(0x02) // type=assistant
        appendU32(&data, UInt32("hi there".utf8.count))
        data.append(contentsOf: "hi there".utf8)

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiAgentChat(let visible, let status, let model, let prompt, let pendingToolName, _, let messages) = cmd else {
            Issue.record("Expected .guiAgentChat"); return
        }

        #expect(visible == true)
        #expect(status == 1)
        #expect(model == "claude-3")
        #expect(prompt == "Fix this bug")
        #expect(pendingToolName == nil)
        #expect(messages.count == 2)

        guard case .user(let userText) = messages[0] else {
            Issue.record("Expected .user message"); return
        }
        #expect(userText == "hello")

        guard case .assistant(let assistantText) = messages[1] else {
            Issue.record("Expected .assistant message"); return
        }
        #expect(assistantText == "hi there")
    }

    @Test("Decode gui_agent_chat with thinking message")
    func decodeThinking() throws {
        var data = Data()
        data.append(OP_GUI_AGENT_CHAT)
        data.append(1) // visible
        data.append(1) // status
        appendString16(&data, "claude") // model
        appendString16(&data, "") // prompt
        data.append(0) // no pending approval
        appendU16(&data, 1) // messageCount

        // Thinking message
        data.append(0x03) // type=thinking
        data.append(1) // collapsed
        let thinkText = "Let me analyze..."
        appendU32(&data, UInt32(thinkText.utf8.count))
        data.append(contentsOf: thinkText.utf8)

        let (cmd, _) = try decodeCommand(data: data, offset: 0)
        guard case .guiAgentChat(_, _, _, _, _, _, let messages) = cmd else {
            Issue.record("Expected .guiAgentChat"); return
        }

        guard case .thinking(let text, let collapsed) = messages[0] else {
            Issue.record("Expected .thinking message"); return
        }
        #expect(text == "Let me analyze...")
        #expect(collapsed == true)
    }

    @Test("Decode gui_agent_chat with tool_call message")
    func decodeToolCall() throws {
        var data = Data()
        data.append(OP_GUI_AGENT_CHAT)
        data.append(1); data.append(2) // visible, status=running tool
        appendString16(&data, "claude"); appendString16(&data, "")
        data.append(0) // no pending
        appendU16(&data, 1)

        // Tool call message
        data.append(0x04) // type=tool_call
        data.append(1) // status
        data.append(0) // isError
        data.append(1) // collapsed
        appendU32(&data, 1234) // durationMs
        appendString16(&data, "read_file") // name
        let result = "file contents here"
        appendU32(&data, UInt32(result.utf8.count))
        data.append(contentsOf: result.utf8)

        let (cmd, _) = try decodeCommand(data: data, offset: 0)
        guard case .guiAgentChat(_, _, _, _, _, _, let messages) = cmd else {
            Issue.record("Expected .guiAgentChat"); return
        }

        guard case .toolCall(let name, let tcStatus, let isError, let collapsed, let duration, let tcResult) = messages[0] else {
            Issue.record("Expected .toolCall message"); return
        }
        #expect(name == "read_file")
        #expect(tcStatus == 1)
        #expect(isError == false)
        #expect(collapsed == true)
        #expect(duration == 1234)
        #expect(tcResult == "file contents here")
    }

    @Test("Decode gui_agent_chat with system message")
    func decodeSystem() throws {
        var data = Data()
        data.append(OP_GUI_AGENT_CHAT)
        data.append(1); data.append(0)
        appendString16(&data, "claude"); appendString16(&data, "")
        data.append(0)
        appendU16(&data, 1)

        data.append(0x05) // type=system
        data.append(1) // isError
        let sysText = "Session terminated"
        appendU32(&data, UInt32(sysText.utf8.count))
        data.append(contentsOf: sysText.utf8)

        let (cmd, _) = try decodeCommand(data: data, offset: 0)
        guard case .guiAgentChat(_, _, _, _, _, _, let messages) = cmd else {
            Issue.record("Expected .guiAgentChat"); return
        }

        guard case .system(let text, let isError) = messages[0] else {
            Issue.record("Expected .system message"); return
        }
        #expect(text == "Session terminated")
        #expect(isError == true)
    }

    @Test("Decode gui_agent_chat with usage message")
    func decodeUsage() throws {
        var data = Data()
        data.append(OP_GUI_AGENT_CHAT)
        data.append(1); data.append(0)
        appendString16(&data, "claude"); appendString16(&data, "")
        data.append(0)
        appendU16(&data, 1)

        data.append(0x06) // type=usage
        appendU32(&data, 1000) // input
        appendU32(&data, 500) // output
        appendU32(&data, 800) // cacheRead
        appendU32(&data, 200) // cacheWrite
        appendU32(&data, 15000) // costMicros

        let (cmd, _) = try decodeCommand(data: data, offset: 0)
        guard case .guiAgentChat(_, _, _, _, _, _, let messages) = cmd else {
            Issue.record("Expected .guiAgentChat"); return
        }

        guard case .usage(let input, let output, let cacheRead, let cacheWrite, let costMicros) = messages[0] else {
            Issue.record("Expected .usage message"); return
        }
        #expect(input == 1000)
        #expect(output == 500)
        #expect(cacheRead == 800)
        #expect(cacheWrite == 200)
        #expect(costMicros == 15000)
    }

    @Test("Decode gui_agent_chat with pending approval")
    func decodePendingApproval() throws {
        var data = Data()
        data.append(OP_GUI_AGENT_CHAT)
        data.append(1); data.append(2) // visible, status=running tool
        appendString16(&data, "claude"); appendString16(&data, "")
        data.append(1) // has pending approval
        appendString16(&data, "write_file") // pending tool name
        appendString16(&data, "Writing to config.toml") // pending summary
        appendU16(&data, 0) // no messages

        let (cmd, _) = try decodeCommand(data: data, offset: 0)
        guard case .guiAgentChat(_, _, _, _, let pendingToolName, let pendingToolSummary, _) = cmd else {
            Issue.record("Expected .guiAgentChat"); return
        }
        #expect(pendingToolName == "write_file")
        #expect(pendingToolSummary == "Writing to config.toml")
    }

    @Test("Decode gui_agent_chat with styled_assistant message")
    func decodeStyledAssistant() throws {
        var data = Data()
        data.append(OP_GUI_AGENT_CHAT)
        data.append(1); data.append(0)
        appendString16(&data, "claude"); appendString16(&data, "")
        data.append(0) // no pending
        appendU16(&data, 1) // 1 message

        // styled_assistant: 0x07, line_count::16, then per line:
        //   run_count::16, then per run: text_len::16, text, fg::24, bg::24, flags::8
        data.append(0x07) // type=styled_assistant
        appendU16(&data, 2) // 2 lines

        // Line 1: 2 runs
        appendU16(&data, 2) // run_count
        // Run 1: "def " bold, fg=blue, bg=dark
        appendString16(&data, "def ")
        appendRGB(&data, 0x51, 0xAF, 0xEF) // fg
        appendRGB(&data, 0x28, 0x2C, 0x34) // bg
        data.append(0x01) // flags: bold

        // Run 2: "hello" italic, fg=green
        appendString16(&data, "hello")
        appendRGB(&data, 0x98, 0xBE, 0x65) // fg
        appendRGB(&data, 0x28, 0x2C, 0x34) // bg
        data.append(0x02) // flags: italic

        // Line 2: 1 run
        appendU16(&data, 1) // run_count
        appendString16(&data, "  :ok")
        appendRGB(&data, 0xBB, 0xC2, 0xCF)
        appendRGB(&data, 0x28, 0x2C, 0x34)
        data.append(0x04) // flags: underline

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiAgentChat(_, _, _, _, _, _, let messages) = cmd else {
            Issue.record("Expected .guiAgentChat"); return
        }

        guard case .styledAssistant(let lines) = messages[0] else {
            Issue.record("Expected .styledAssistant message"); return
        }
        #expect(lines.count == 2)
        #expect(lines[0].count == 2) // 2 runs on line 1
        #expect(lines[0][0].text == "def ")
        #expect(lines[0][0].fgR == 0x51)
        #expect(lines[0][0].fgG == 0xAF)
        #expect(lines[0][0].fgB == 0xEF)
        #expect(lines[0][0].bold == true)
        #expect(lines[0][0].italic == false)
        #expect(lines[0][1].text == "hello")
        #expect(lines[0][1].italic == true)
        #expect(lines[0][1].bold == false)
        #expect(lines[1].count == 1)
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
