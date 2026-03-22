/// Tests for CommandDispatcher routing logic.
///
/// Verifies that each RenderCommand type updates the correct GUIState
/// sub-state when dispatched. Catches wiring bugs where a command is
/// routed to the wrong state or not routed at all.

import Testing
import Foundation

@Suite("CommandDispatcher Routing")
struct CommandDispatcherRoutingTests {

    @MainActor
    private func makeDispatcher() -> (CommandDispatcher, GUIState) {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 80, rows: 24, guiState: gui)
        return (dispatcher, gui)
    }

    // MARK: - Basic commands

    @Test("clear marks dirty but preserves windowContents and windowGutters")
    @MainActor func clearCommand() {
        let (dispatcher, gui) = makeDispatcher()
        // Seed window content and gutter data
        let content = GUIWindowContent(
            windowId: 1, fullRefresh: true,
            cursorRow: 0, cursorCol: 0, cursorShape: .block,
            rows: [], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: []
        )
        gui.windowContents[1] = content

        let gutter = GUIWindowGutter(
            windowId: 1, contentRow: 0, contentCol: 5, contentHeight: 24,
            isActive: true, cursorLine: 10, lineNumberStyle: .hybrid,
            lineNumberWidth: 4, signColWidth: 1, entries: []
        )
        dispatcher.dispatch(.guiGutter(data: gutter))
        dispatcher.frameState.dirty = false

        dispatcher.dispatch(.clear)

        // FrameState is marked dirty
        #expect(dispatcher.frameState.dirty == true)
        // windowContents persists through clear (defense-in-depth:
        // stale content is better than a blank viewport flash)
        #expect(gui.windowContents.count == 1)
        // windowGutters persists through clear (gutter positions are
        // stable between frames, only change on resize/split)
        #expect(dispatcher.frameState.windowGutters[1] != nil)
    }

    @Test("setCursor updates frameState cursor position")
    @MainActor func setCursorCommand() {
        let (dispatcher, _) = makeDispatcher()
        dispatcher.dispatch(.setCursor(row: 10, col: 20))
        #expect(dispatcher.frameState.cursorRow == 10)
        #expect(dispatcher.frameState.cursorCol == 20)
    }

    @Test("setCursorShape updates frameState cursor shape")
    @MainActor func setCursorShapeCommand() {
        let (dispatcher, _) = makeDispatcher()
        dispatcher.dispatch(.setCursorShape(.beam))
        #expect(dispatcher.frameState.cursorShape == .beam)
    }

    @Test("setWindowBg updates frameState defaultBg")
    @MainActor func setWindowBgCommand() {
        let (dispatcher, _) = makeDispatcher()
        dispatcher.dispatch(.setWindowBg(r: 0x28, g: 0x2C, b: 0x34))
        let expected: UInt32 = (0x28 << 16) | (0x2C << 8) | 0x34
        #expect(dispatcher.frameState.defaultBg == expected)
    }

    // MARK: - GUI chrome routing

    @Test("guiTabBar updates tabBarState")
    @MainActor func guiTabBarRouting() {
        let (dispatcher, gui) = makeDispatcher()
        let tabs = [
            GUITabEntry(id: 1, isActive: true, isDirty: false, isAgent: false,
                       hasAttention: false, agentStatus: 0, icon: "", label: "test.ex")
        ]
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: tabs))

        #expect(gui.tabBarState.tabs.count == 1)
        #expect(gui.tabBarState.tabs[0].label == "test.ex")
        #expect(gui.tabBarState.activeIndex == 0)
    }

    @Test("guiFileTree updates fileTreeState when entries present")
    @MainActor func guiFileTreeRouting() {
        let (dispatcher, gui) = makeDispatcher()
        let entries = [
            GUIFileTreeEntry(pathHash: 123, isDir: true, isExpanded: true,
                           isSelected: false, depth: 0, gitStatus: 0,
                           icon: "", name: "lib", relPath: "lib")
        ]
        dispatcher.dispatch(.guiFileTree(selectedIndex: 0, treeWidth: 30,
                                          rootPath: "/project", entries: entries))

        #expect(gui.fileTreeState.visible == true)
        #expect(gui.fileTreeState.entries.count == 1)
        #expect(gui.fileTreeState.entries[0].name == "lib")
        #expect(gui.fileTreeState.projectRoot == "/project")
    }

    @Test("guiFileTree hides when entries are empty")
    @MainActor func guiFileTreeHidesOnEmpty() {
        let (dispatcher, gui) = makeDispatcher()
        // First show it
        dispatcher.dispatch(.guiFileTree(selectedIndex: 0, treeWidth: 30,
                                          rootPath: "/project",
                                          entries: [GUIFileTreeEntry(pathHash: 1, isDir: false,
                                                                     isExpanded: false, isSelected: false,
                                                                     depth: 0, gitStatus: 0,
                                                                     icon: "", name: "a", relPath: "a")]))
        #expect(gui.fileTreeState.visible == true)

        // Then hide with empty entries
        dispatcher.dispatch(.guiFileTree(selectedIndex: 0, treeWidth: 0,
                                          rootPath: "", entries: []))
        #expect(gui.fileTreeState.visible == false)
    }

    @Test("guiCompletion visible updates completionState")
    @MainActor func guiCompletionVisible() {
        let (dispatcher, gui) = makeDispatcher()
        let items = [GUICompletionItem(kind: 1, label: "def", detail: "keyword")]
        dispatcher.dispatch(.guiCompletion(visible: true, anchorRow: 5, anchorCol: 10,
                                            selectedIndex: 0, items: items))

        #expect(gui.completionState.visible == true)
        #expect(gui.completionState.items.count == 1)
        #expect(gui.completionState.anchorRow == 5)
    }

    @Test("guiCompletion hidden clears completionState")
    @MainActor func guiCompletionHidden() {
        let (dispatcher, gui) = makeDispatcher()
        // Show then hide
        let items = [GUICompletionItem(kind: 1, label: "def", detail: "keyword")]
        dispatcher.dispatch(.guiCompletion(visible: true, anchorRow: 5, anchorCol: 10,
                                            selectedIndex: 0, items: items))
        dispatcher.dispatch(.guiCompletion(visible: false, anchorRow: 0, anchorCol: 0,
                                            selectedIndex: 0, items: []))

        #expect(gui.completionState.visible == false)
        #expect(gui.completionState.items.isEmpty)
    }

    @Test("guiWhichKey visible updates whichKeyState")
    @MainActor func guiWhichKeyVisible() {
        let (dispatcher, gui) = makeDispatcher()
        let bindings = [GUIWhichKeyBinding(kind: 0, key: "f", description: "Find file", icon: "")]
        dispatcher.dispatch(.guiWhichKey(visible: true, prefix: "SPC",
                                          page: 0, pageCount: 1, bindings: bindings))

        #expect(gui.whichKeyState.visible == true)
        #expect(gui.whichKeyState.prefix == "SPC")
        #expect(gui.whichKeyState.bindings.count == 1)
    }

    @Test("guiWhichKey hidden clears whichKeyState")
    @MainActor func guiWhichKeyHidden() {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.dispatch(.guiWhichKey(visible: false, prefix: "", page: 0,
                                          pageCount: 0, bindings: []))
        #expect(gui.whichKeyState.visible == false)
    }

    @Test("guiStatusBar updates statusBarState")
    @MainActor func guiStatusBarRouting() {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.dispatch(.guiStatusBar(contentKind: 0, mode: 1, cursorLine: 42,
                                           cursorCol: 9, lineCount: 500, flags: 0x03,
                                           lspStatus: 1, gitBranch: "main",
                                           message: "-- INSERT --", filetype: "elixir",
                                           errorCount: 3, warningCount: 7,
                                           modelName: "", messageCount: 0, sessionStatus: 0,
                                           infoCount: 1, hintCount: 2,
                                           macroRecording: 0, parserStatus: 0, agentStatus: 0,
                                           gitAdded: 5, gitModified: 3, gitDeleted: 1,
                                           icon: "", iconColorR: 0, iconColorG: 0, iconColorB: 0,
                                           filename: "editor.ex", diagnosticHint: ""))

        #expect(gui.statusBarState.mode == 1)
        #expect(gui.statusBarState.cursorLine == 42)
        #expect(gui.statusBarState.gitBranch == "main")
        #expect(gui.statusBarState.filetype == "elixir")
        #expect(gui.statusBarState.errorCount == 3)
    }

    @Test("guiBreadcrumb updates breadcrumbState")
    @MainActor func guiBreadcrumbRouting() {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.dispatch(.guiBreadcrumb(segments: ["lib", "minga", "editor.ex"]))

        #expect(gui.breadcrumbState.segments == ["lib", "minga", "editor.ex"])
    }

    @Test("guiPicker visible updates pickerState")
    @MainActor func guiPickerVisible() {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.dispatch(.guiPicker(visible: true, selectedIndex: 0, filteredCount: 5,
                                        totalCount: 100, title: "Find File", query: "edi",
                                        hasPreview: false, items: [], actionMenu: nil))

        #expect(gui.pickerState.visible == true)
        #expect(gui.pickerState.title == "Find File")
        #expect(gui.pickerState.query == "edi")
    }

    @Test("guiPicker hidden clears pickerState")
    @MainActor func guiPickerHidden() {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.dispatch(.guiPicker(visible: true, selectedIndex: 0, filteredCount: 5,
                                        totalCount: 100, title: "Find File", query: "edi",
                                        hasPreview: false, items: [], actionMenu: nil))
        dispatcher.dispatch(.guiPicker(visible: false, selectedIndex: 0, filteredCount: 0,
                                        totalCount: 0, title: "", query: "",
                                        hasPreview: false, items: [], actionMenu: nil))

        #expect(gui.pickerState.visible == false)
        #expect(gui.pickerState.items.isEmpty)
    }

    @Test("guiAgentChat visible updates agentChatState")
    @MainActor func guiAgentChatVisible() {
        let (dispatcher, gui) = makeDispatcher()
        let messages: [GUIChatMessage] = [.user(text: "hello")]
        dispatcher.dispatch(.guiAgentChat(visible: true, status: 1, model: "claude",
                                           prompt: "Fix this", pendingToolName: nil,
                                           pendingToolSummary: "", messages: messages))

        #expect(gui.agentChatState.visible == true)
        #expect(gui.agentChatState.model == "claude")
        #expect(gui.agentChatState.messages.count == 1)
    }

    @Test("guiAgentChat hidden clears agentChatState")
    @MainActor func guiAgentChatHidden() {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.dispatch(.guiAgentChat(visible: false, status: 0, model: "",
                                           prompt: "", pendingToolName: nil,
                                           pendingToolSummary: "", messages: []))

        #expect(gui.agentChatState.visible == false)
        #expect(gui.agentChatState.messages.isEmpty)
    }

    @Test("guiBottomPanel visible updates bottomPanelState and appends entries")
    @MainActor func guiBottomPanelVisible() {
        let (dispatcher, gui) = makeDispatcher()
        let tabs = [GUIBottomPanelTab(tabType: 0, name: "Messages")]
        let entries = [GUIMessageEntry(id: 1, level: 1, subsystem: 0,
                                       timestampSecs: 3600, filePath: "", text: "test")]
        dispatcher.dispatch(.guiBottomPanel(visible: true, activeTabIndex: 0,
                                             heightPercent: 30, filterPreset: 0,
                                             tabs: tabs, entries: entries))

        #expect(gui.bottomPanelState.visible == true)
        #expect(gui.bottomPanelState.tabs.count == 1)
        #expect(gui.bottomPanelState.messagesState.entries.count == 1)
    }

    @Test("guiBottomPanel hidden hides bottomPanelState")
    @MainActor func guiBottomPanelHidden() {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.dispatch(.guiBottomPanel(visible: false, activeTabIndex: 0,
                                             heightPercent: 30, filterPreset: 0,
                                             tabs: [], entries: []))
        #expect(gui.bottomPanelState.visible == false)
    }

    @Test("guiToolManager visible updates toolManagerState")
    @MainActor func guiToolManagerVisible() {
        let (dispatcher, gui) = makeDispatcher()
        let tools = [GUIToolEntry(name: "elixir_ls", label: "ElixirLS",
                                  description: "LSP", category: 0, status: 1,
                                  method: 0, languages: ["elixir"], version: "0.22",
                                  homepage: "", provides: ["elixir-ls"],
                                  errorReason: "")]
        dispatcher.dispatch(.guiToolManager(visible: true, filter: 0,
                                             selectedIndex: 0, tools: tools))

        #expect(gui.toolManagerState.visible == true)
        #expect(gui.toolManagerState.tools.count == 1)
        #expect(gui.toolManagerState.tools[0].name == "elixir_ls")
    }

    @Test("guiToolManager hidden clears toolManagerState")
    @MainActor func guiToolManagerHidden() {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.dispatch(.guiToolManager(visible: false, filter: 0,
                                             selectedIndex: 0, tools: []))
        #expect(gui.toolManagerState.visible == false)
        #expect(gui.toolManagerState.tools.isEmpty)
    }

    @Test("guiWindowContent stores content in guiState")
    @MainActor func guiWindowContentRouting() {
        let (dispatcher, gui) = makeDispatcher()
        let content = GUIWindowContent(
            windowId: 7, fullRefresh: true,
            cursorRow: 5, cursorCol: 10, cursorShape: .beam,
            rows: [], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: []
        )
        dispatcher.dispatch(.guiWindowContent(data: content))

        #expect(gui.windowContents[7] != nil)
        #expect(gui.windowContents[7]?.cursorRow == 5)
    }

    @Test("guiGutterSeparator updates frameState gutter state")
    @MainActor func guiGutterSepRouting() {
        let (dispatcher, _) = makeDispatcher()
        dispatcher.dispatch(.guiGutterSeparator(col: 4, r: 0x3F, g: 0x44, b: 0x4A))

        #expect(dispatcher.frameState.gutterCol == 4)
        let expected: UInt32 = (0x3F << 16) | (0x44 << 8) | 0x4A
        #expect(dispatcher.frameState.gutterSeparatorColor == expected)
    }

    @Test("guiCursorline updates frameState cursorline state")
    @MainActor func guiCursorlineRouting() {
        let (dispatcher, _) = makeDispatcher()
        dispatcher.dispatch(.guiCursorline(row: 12, r: 0x2C, g: 0x32, b: 0x3C))

        #expect(dispatcher.frameState.cursorlineRow == 12)
        let expected: UInt32 = (0x2C << 16) | (0x32 << 8) | 0x3C
        #expect(dispatcher.frameState.cursorlineBg == expected)
    }

    @Test("guiGutter stores gutter data in frameState")
    @MainActor func guiGutterRouting() {
        let (dispatcher, _) = makeDispatcher()
        let gutter = GUIWindowGutter(
            windowId: 1, contentRow: 0, contentCol: 5, contentHeight: 24,
            isActive: true, cursorLine: 10, lineNumberStyle: .hybrid,
            lineNumberWidth: 4, signColWidth: 1, entries: []
        )
        dispatcher.dispatch(.guiGutter(data: gutter))

        #expect(dispatcher.frameState.windowGutters[1] != nil)
        // Active window gutter syncs gutterCol
        #expect(dispatcher.frameState.gutterCol == 5) // 4 + 1
    }

    @Test("guiTheme updates themeColors and syncs to frameState")
    @MainActor func guiThemeRouting() {
        let (dispatcher, gui) = makeDispatcher()
        let slots: [(slotId: UInt8, r: UInt8, g: UInt8, b: UInt8)] = [
            (GUI_COLOR_GUTTER_FG, 0xAA, 0xBB, 0xCC)
        ]
        dispatcher.dispatch(.guiTheme(slots: slots))

        // Check frameState got the RGB value synced
        let expected: UInt32 = (0xAA << 16) | (0xBB << 8) | 0xCC
        #expect(dispatcher.frameState.gutterColors.fg == expected)
        #expect(gui.themeColors.gutterFgRGB == expected)
    }
}
