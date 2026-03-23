/// Tests for GUI state object lifecycle: update(), hide(), and
/// raw-to-view-model conversion correctness.
///
/// Every state object that has a hide() method should clear all its
/// data. Every update() should correctly convert from protocol types
/// to view model types.

import Testing
import Foundation

// MARK: - CompletionState

@Suite("CompletionState Lifecycle")
struct CompletionStateLifecycleTests {
    @Test("update() converts raw items to view model")
    @MainActor func updateConverts() {
        let state = CompletionState()
        let raw = [
            GUICompletionItem(kind: 1, label: "def", detail: "keyword"),
            GUICompletionItem(kind: 6, label: "my_var", detail: "String.t()")
        ]
        state.update(visible: true, anchorRow: 5, anchorCol: 10,
                     selectedIndex: 1, rawItems: raw)

        #expect(state.visible == true)
        #expect(state.anchorRow == 5)
        #expect(state.anchorCol == 10)
        #expect(state.selectedIndex == 1)
        #expect(state.items.count == 2)
        #expect(state.items[0].label == "def")
        #expect(state.items[0].kind == 1)
        #expect(state.items[1].label == "my_var")
        #expect(state.items[1].detail == "String.t()")
    }

    @Test("hide() clears all state")
    @MainActor func hideClearsAll() {
        let state = CompletionState()
        state.update(visible: true, anchorRow: 5, anchorCol: 10,
                     selectedIndex: 0,
                     rawItems: [GUICompletionItem(kind: 1, label: "x", detail: "")])
        state.hide()

        #expect(state.visible == false)
        #expect(state.items.isEmpty)
    }
}

// MARK: - WhichKeyState

@Suite("WhichKeyState Lifecycle")
struct WhichKeyStateLifecycleTests {
    @Test("update() converts raw bindings to view model")
    @MainActor func updateConverts() {
        let state = WhichKeyState()
        let raw = [
            GUIWhichKeyBinding(kind: 0, key: "f", description: "Find file", icon: "🔍"),
            GUIWhichKeyBinding(kind: 1, key: "b", description: "Buffers", icon: "")
        ]
        state.update(visible: true, prefix: "SPC", page: 0, pageCount: 2,
                     rawBindings: raw)

        #expect(state.visible == true)
        #expect(state.prefix == "SPC")
        #expect(state.page == 0)
        #expect(state.pageCount == 2)
        #expect(state.bindings.count == 2)
        #expect(state.bindings[0].key == "f")
        #expect(state.bindings[0].isGroup == false)
        #expect(state.bindings[1].key == "b")
        #expect(state.bindings[1].isGroup == true)
    }

    @Test("hide() clears all state")
    @MainActor func hideClearsAll() {
        let state = WhichKeyState()
        state.update(visible: true, prefix: "SPC", page: 0, pageCount: 1,
                     rawBindings: [GUIWhichKeyBinding(kind: 0, key: "f",
                                                      description: "Find", icon: "")])
        state.hide()

        #expect(state.visible == false)
        #expect(state.bindings.isEmpty)
    }
}

// MARK: - PickerState

@Suite("PickerState Lifecycle")
struct PickerStateLifecycleTests {
    @Test("update() converts raw items with match positions and flags")
    @MainActor func updateConverts() {
        let state = PickerState()
        let raw = [
            GUIPickerItem(iconColor: 0x51AFEF, flags: 0x01, label: "editor.ex",
                         description: "lib/minga/editor.ex", annotation: "500 lines",
                         matchPositions: [0, 3]),
            GUIPickerItem(iconColor: 0x98BE65, flags: 0x02, label: "test.ex",
                         description: "test/test.ex", annotation: "",
                         matchPositions: [])
        ]
        let actionMenu = GUIPickerActionMenu(selectedIndex: 0, actions: ["Open", "Split"])

        state.update(visible: true, selectedIndex: 0, filteredCount: 2,
                     totalCount: 50, title: "Find File", query: "edi",
                     hasPreview: true, rawItems: raw, actionMenu: actionMenu)

        #expect(state.visible == true)
        #expect(state.title == "Find File")
        #expect(state.query == "edi")
        #expect(state.hasPreview == true)
        #expect(state.filteredCount == 2)
        #expect(state.totalCount == 50)
        #expect(state.items.count == 2)
        #expect(state.items[0].isTwoLine == true)
        #expect(state.items[0].isMarked == false)
        #expect(state.items[0].matchPositions == [0, 3])
        #expect(state.items[1].isMarked == true)
        #expect(state.actionMenu != nil)
        #expect(state.actionMenu?.actions == ["Open", "Split"])
    }

    @Test("updatePreview() converts styled segments")
    @MainActor func updatePreviewConverts() {
        let state = PickerState()
        let lines: [GUIPickerPreviewLine] = [
            [GUIPickerPreviewSegment(fgColor: 0xFF0000, bold: true, text: "def ")],
            [GUIPickerPreviewSegment(fgColor: 0x00FF00, bold: false, text: "  :ok")]
        ]
        state.updatePreview(lines: lines)

        #expect(state.previewLines.count == 2)
        #expect(state.previewLines[0].segments[0].text == "def ")
        #expect(state.previewLines[0].segments[0].bold == true)
    }

    @Test("hide() clears items, preview, and action menu")
    @MainActor func hideClearsAll() {
        let state = PickerState()
        state.update(visible: true, selectedIndex: 0, filteredCount: 1,
                     totalCount: 1, title: "Test", query: "q",
                     hasPreview: true,
                     rawItems: [GUIPickerItem(iconColor: 0, flags: 0, label: "x",
                                             description: "", annotation: "",
                                             matchPositions: [])],
                     actionMenu: GUIPickerActionMenu(selectedIndex: 0, actions: ["A"]))
        state.updatePreview(lines: [[GUIPickerPreviewSegment(fgColor: 0, bold: false, text: "x")]])

        state.hide()

        #expect(state.visible == false)
        #expect(state.items.isEmpty)
        #expect(state.previewLines.isEmpty)
        #expect(state.hasPreview == false)
        #expect(state.actionMenu == nil)
    }
}

// MARK: - FileTreeState

@Suite("FileTreeState Lifecycle")
struct FileTreeStateLifecycleTests {
    @Test("update() converts raw entries and sets projectRoot")
    @MainActor func updateConverts() {
        let state = FileTreeState()
        let raw = [
            GUIFileTreeEntry(pathHash: 0xAABB, isDir: true, isExpanded: true,
                           isSelected: false, depth: 0, gitStatus: 0,
                           icon: "", name: "lib", relPath: "lib"),
            GUIFileTreeEntry(pathHash: 0xCCDD, isDir: false, isExpanded: false,
                           isSelected: true, depth: 1, gitStatus: 1,
                           icon: "", name: "editor.ex", relPath: "lib/editor.ex")
        ]
        state.update(selectedIndex: 1, treeWidth: 30, rootPath: "/project", rawEntries: raw)

        #expect(state.visible == true)
        #expect(state.selectedIndex == 1)
        #expect(state.projectRoot == "/project")
        #expect(state.entries.count == 2)
        #expect(state.entries[0].isDir == true)
        #expect(state.entries[0].name == "lib")
        #expect(state.entries[1].isSelected == true)
        #expect(state.entries[1].relPath == "lib/editor.ex")
    }

    @Test("fullPath() computes correct absolute path")
    @MainActor func fullPathComputation() {
        let state = FileTreeState()
        state.update(selectedIndex: 0, treeWidth: 30, rootPath: "/home/user/project",
                     rawEntries: [GUIFileTreeEntry(pathHash: 1, isDir: false,
                                                   isExpanded: false, isSelected: false,
                                                   depth: 1, gitStatus: 0, icon: "",
                                                   name: "editor.ex",
                                                   relPath: "lib/editor.ex")])

        let path = state.fullPath(for: state.entries[0])
        #expect(path == "/home/user/project/lib/editor.ex")
    }

    @Test("hide() clears entries and projectRoot")
    @MainActor func hideClearsAll() {
        let state = FileTreeState()
        state.update(selectedIndex: 0, treeWidth: 30, rootPath: "/project",
                     rawEntries: [GUIFileTreeEntry(pathHash: 1, isDir: false,
                                                   isExpanded: false, isSelected: false,
                                                   depth: 0, gitStatus: 0, icon: "",
                                                   name: "a", relPath: "a")])
        state.hide()

        #expect(state.visible == false)
        #expect(state.entries.isEmpty)
        #expect(state.projectRoot == "")
    }
}

// MARK: - TabBarState

@Suite("TabBarState Lifecycle")
struct TabBarStateLifecycleTests {
    @Test("update() converts raw tab entries")
    @MainActor func updateConverts() {
        let state = TabBarState()
        let raw = [
            GUITabEntry(id: 42, isActive: true, isDirty: true, isAgent: false,
                       hasAttention: false, agentStatus: 0, icon: "", label: "editor.ex"),
            GUITabEntry(id: 99, isActive: false, isDirty: false, isAgent: true,
                       hasAttention: true, agentStatus: 1, icon: "", label: "Agent")
        ]
        state.update(activeIndex: 0, entries: raw)

        #expect(state.activeIndex == 0)
        #expect(state.tabs.count == 2)
        #expect(state.tabs[0].id == 42)
        #expect(state.tabs[0].isActive == true)
        #expect(state.tabs[0].isDirty == true)
        #expect(state.tabs[0].label == "editor.ex")
        #expect(state.tabs[1].isAgent == true)
        #expect(state.tabs[1].hasAttention == true)
    }

    @Test("hide() clears all tab state")
    @MainActor func hideClearsAll() {
        let state = TabBarState()
        state.update(activeIndex: 1, entries: [
            GUITabEntry(id: 1, isActive: true, isDirty: false, isAgent: false,
                       hasAttention: false, agentStatus: 0, icon: "", label: "a")
        ])
        state.hide()

        #expect(state.tabs.isEmpty)
        #expect(state.activeIndex == 0)
    }
}

// MARK: - BreadcrumbState

@Suite("BreadcrumbState Lifecycle")
struct BreadcrumbStateLifecycleTests {
    @Test("update() sets segments")
    @MainActor func updateSetsSegments() {
        let state = BreadcrumbState()
        state.update(segments: ["lib", "minga", "editor.ex"])
        #expect(state.segments == ["lib", "minga", "editor.ex"])
    }

    @Test("hide() clears segments")
    @MainActor func hideClearsAll() {
        let state = BreadcrumbState()
        state.update(segments: ["lib", "minga", "editor.ex"])
        state.hide()
        #expect(state.segments.isEmpty)
    }
}

// MARK: - AgentChatState

@Suite("AgentChatState Lifecycle")
struct AgentChatStateLifecycleTests {
    @Test("update() converts all message types")
    @MainActor func updateConvertsMessages() {
        let state = AgentChatState()
        let raw: [GUIChatMessage] = [
            GUIChatMessage(beamId: 1, content: .user(text: "hello")),
            GUIChatMessage(beamId: 2, content: .assistant(text: "hi")),
            GUIChatMessage(beamId: 3, content: .thinking(text: "analyzing...", collapsed: false)),
            GUIChatMessage(beamId: 4, content: .toolCall(name: "read_file", status: 1, isError: false,
                     collapsed: true, durationMs: 500, result: "contents")),
            GUIChatMessage(beamId: 5, content: .system(text: "session started", isError: false)),
            GUIChatMessage(beamId: 6, content: .usage(input: 100, output: 50, cacheRead: 80, cacheWrite: 20, costMicros: 5000))
        ]
        state.update(visible: true, status: 1, model: "claude", prompt: "fix bug",
                     pendingToolName: "write_file",
                     pendingToolSummary: "Writing config.toml",
                     rawMessages: raw)

        #expect(state.visible == true)
        #expect(state.status == 1)
        #expect(state.model == "claude")
        #expect(state.prompt == "fix bug")
        #expect(state.pendingApproval?.toolName == "write_file")
        #expect(state.pendingApproval?.summary == "Writing config.toml")
        #expect(state.messages.count == 6)
        #expect(state.isThinking == true)
        #expect(state.statusLabel == "thinking")
    }

    @Test("hide() clears all state")
    @MainActor func hideClearsAll() {
        let state = AgentChatState()
        state.update(visible: true, status: 1, model: "claude", prompt: "test",
                     pendingToolName: nil, pendingToolSummary: "",
                     rawMessages: [GUIChatMessage(beamId: 1, content: .user(text: "hi"))])
        state.hide()

        #expect(state.visible == false)
        #expect(state.messages.isEmpty)
    }

    @Test("statusLabel maps all status values")
    @MainActor func statusLabels() {
        let state = AgentChatState()
        state.status = 0; #expect(state.statusLabel == "idle")
        state.status = 1; #expect(state.statusLabel == "thinking")
        state.status = 2; #expect(state.statusLabel == "running tool")
        state.status = 3; #expect(state.statusLabel == "error")
        state.status = 255; #expect(state.statusLabel == "idle")
    }
}

// MARK: - ToolManagerState

@Suite("ToolManagerState Lifecycle")
struct ToolManagerStateLifecycleTests {
    @Test("computed counts are correct")
    @MainActor func computedCounts() {
        let state = ToolManagerState()
        state.tools = [
            ToolEntry(id: "a", name: "a", label: "A", description: "", category: .lspServer,
                     status: .installed, method: .npm, languages: [], version: "", homepage: "", provides: [], errorReason: ""),
            ToolEntry(id: "b", name: "b", label: "B", description: "", category: .formatter,
                     status: .notInstalled, method: .pip, languages: [], version: "", homepage: "", provides: [], errorReason: ""),
            ToolEntry(id: "c", name: "c", label: "C", description: "", category: .linter,
                     status: .installing, method: .cargo, languages: [], version: "", homepage: "", provides: [], errorReason: ""),
            ToolEntry(id: "d", name: "d", label: "D", description: "", category: .debugger,
                     status: .updateAvailable, method: .goInstall, languages: [], version: "", homepage: "", provides: [], errorReason: "")
        ]

        #expect(state.installedCount == 2) // installed + updateAvailable
        #expect(state.availableCount == 1) // notInstalled
        #expect(state.installingCount == 1) // installing
    }

    @Test("hide() clears tools")
    @MainActor func hideClearsAll() {
        let state = ToolManagerState()
        state.tools = [
            ToolEntry(id: "a", name: "a", label: "A", description: "", category: .lspServer,
                     status: .installed, method: .npm, languages: [], version: "", homepage: "", provides: [], errorReason: "")
        ]
        state.hide()

        #expect(state.visible == false)
        #expect(state.tools.isEmpty)
    }
}

// MARK: - BottomPanelState

@Suite("BottomPanelState Lifecycle")
struct BottomPanelStateLifecycleTests {
    @Test("update() sets filter preset on visibility transition")
    @MainActor func filterPresetOnShow() {
        let state = BottomPanelState()
        // Hidden -> visible with filter preset 1 should set activeLevels
        state.update(visible: true, activeTabIndex: 0, heightPercent: 30,
                     filterPreset: 1, tabs: [BottomPanelTab(id: 0, tabType: 0, name: "Messages")])

        #expect(state.visible == true)
        #expect(state.messagesState.activeLevels == [2, 3]) // warning + error
    }

    @Test("hide() only hides, keeps messages")
    @MainActor func hideKeepsMessages() {
        let state = BottomPanelState()
        state.messagesState.appendEntries([
            GUIMessageEntry(id: 1, level: 1, subsystem: 0,
                           timestampSecs: 0, filePath: "", text: "test")
        ])
        state.hide()

        #expect(state.visible == false)
        #expect(state.messagesState.entries.count == 1) // preserved
    }
}

// MARK: - MessagesContentState

@Suite("MessagesContentState Lifecycle")
struct MessagesContentStateLifecycleTests {
    @Test("appendEntries adds and caps at 1000")
    @MainActor func appendAndCap() {
        let state = MessagesContentState()

        // Add 5 entries
        let entries = (0..<5).map {
            GUIMessageEntry(id: UInt32($0), level: 1, subsystem: 0,
                           timestampSecs: UInt32($0), filePath: "", text: "msg \($0)")
        }
        state.appendEntries(entries)
        #expect(state.entries.count == 5)
    }

    @Test("filteredEntries respects level and subsystem filters")
    @MainActor func filteringWorks() {
        let state = MessagesContentState()
        state.appendEntries([
            GUIMessageEntry(id: 0, level: 0, subsystem: 0, timestampSecs: 0,
                           filePath: "", text: "debug msg"),
            GUIMessageEntry(id: 1, level: 1, subsystem: 0, timestampSecs: 0,
                           filePath: "", text: "info msg"),
            GUIMessageEntry(id: 2, level: 3, subsystem: 1, timestampSecs: 0,
                           filePath: "", text: "error in LSP"),
        ])

        // Default levels are [1, 2, 3] (no debug)
        #expect(state.filteredEntries.count == 2) // info + error

        // Filter to only LSP subsystem
        state.activeSubsystems = [1]
        #expect(state.filteredEntries.count == 1)
        #expect(state.filteredEntries[0].text == "error in LSP")
    }

    @Test("searchText filters by substring")
    @MainActor func searchFilters() {
        let state = MessagesContentState()
        state.appendEntries([
            GUIMessageEntry(id: 0, level: 1, subsystem: 0, timestampSecs: 0,
                           filePath: "", text: "File opened: editor.ex"),
            GUIMessageEntry(id: 1, level: 1, subsystem: 0, timestampSecs: 0,
                           filePath: "", text: "File saved: buffer.ex"),
        ])

        state.searchText = "editor"
        #expect(state.filteredEntries.count == 1)
        #expect(state.filteredEntries[0].text.contains("editor"))
    }

    @Test("toggleLevel and toggleSubsystem work correctly")
    @MainActor func toggleFunctions() {
        let state = MessagesContentState()

        // Default has level 1 (info) active
        #expect(state.activeLevels.contains(1))
        state.toggleLevel(1)
        #expect(!state.activeLevels.contains(1))
        state.toggleLevel(1)
        #expect(state.activeLevels.contains(1))

        // Toggle subsystem
        #expect(state.activeSubsystems.contains(0))
        state.toggleSubsystem(0)
        #expect(!state.activeSubsystems.contains(0))
    }

    @Test("resetFilters restores defaults")
    @MainActor func resetFilters() {
        let state = MessagesContentState()
        state.activeLevels = [3]
        state.activeSubsystems = [1]
        state.searchText = "foo"

        state.resetFilters()
        #expect(state.activeLevels == MessagesContentState.defaultLevels)
        #expect(state.activeSubsystems == MessagesContentState.allSubsystems)
        #expect(state.searchText == "")
    }

    @Test("auto-scroll state tracking")
    @MainActor func autoScrollTracking() {
        let state = MessagesContentState()
        #expect(state.isAutoScrolling == true)

        state.scrolledUp()
        #expect(state.isAutoScrolling == false)

        // New entries while scrolled up show "new entries" indicator
        state.appendEntries([
            GUIMessageEntry(id: 0, level: 1, subsystem: 0, timestampSecs: 0,
                           filePath: "", text: "new")
        ])
        #expect(state.hasNewEntries == true)

        state.jumpToLatest()
        #expect(state.isAutoScrolling == true)
        #expect(state.hasNewEntries == false)
    }

    @Test("MessageEntry timestamp formatting")
    @MainActor func timestampFormatting() {
        let entry = MessageEntry(id: 1, level: 1, subsystem: 0,
                                timestampSecs: 3661, filePath: "", text: "")
        #expect(entry.timestamp == "01:01:01")
    }

    @Test("MessageEntry level and subsystem names")
    @MainActor func levelAndSubsystemNames() {
        let entry = MessageEntry(id: 1, level: 2, subsystem: 5,
                                timestampSecs: 0, filePath: "", text: "")
        #expect(entry.levelName == "WARN")
        #expect(entry.subsystemName == "AGENT")
    }
}

// MARK: - StatusBarState

@Suite("StatusBarState Lifecycle")
struct StatusBarStateLifecycleTests {
    @Test("modeName maps all mode values")
    @MainActor func modeNames() {
        let state = StatusBarState()
        state.mode = 0; #expect(state.modeName == "NORMAL")
        state.mode = 1; #expect(state.modeName == "INSERT")
        state.mode = 2; #expect(state.modeName == "VISUAL")
        state.mode = 3; #expect(state.modeName == "COMMAND")
        state.mode = 4; #expect(state.modeName == "O-PENDING")
        state.mode = 5; #expect(state.modeName == "SEARCH")
        state.mode = 6; #expect(state.modeName == "REPLACE")
        state.mode = 255; #expect(state.modeName == "NORMAL")
    }

    @Test("computed flags work correctly")
    @MainActor func computedFlags() {
        let state = StatusBarState()
        state.flags = 0x03 // has_lsp + has_git
        #expect(state.hasLsp == true)
        #expect(state.hasGit == true)

        state.flags = 0x00
        #expect(state.hasLsp == false)
        #expect(state.hasGit == false)
    }

    @Test("isInsertMode and isAgentWindow")
    @MainActor func computedBooleans() {
        let state = StatusBarState()
        state.mode = 1; #expect(state.isInsertMode == true)
        state.mode = 0; #expect(state.isInsertMode == false)
        state.contentKind = 1; #expect(state.isAgentWindow == true)
        state.contentKind = 0; #expect(state.isAgentWindow == false)
    }
}
