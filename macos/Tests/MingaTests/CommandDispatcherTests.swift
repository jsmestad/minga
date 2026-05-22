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

        let gutter = Wire.WindowGutter(
            windowId: 1, contentRow: 0, contentCol: 5, contentHeight: 24,
            isActive: true, contentWidth: 80, cursorLine: 10, lineNumberStyle: .hybrid,
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
        #expect(dispatcher.currentFrameGutterWindowIds.isEmpty)
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
            Wire.TabEntry(id: 1, groupId: 0, isActive: true, isDirty: false, isAgent: false,
                       hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "", label: "test.ex")
        ]
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: tabs))

        #expect(gui.tabBarState.tabs.count == 1)
        #expect(gui.tabBarState.tabs[0].label == "test.ex")
        #expect(gui.tabBarState.activeIndex == 0)
    }

    @Test("guiFileTree updates fileTreeState when entries present")
    @MainActor func guiFileTreeRouting() {
        let (dispatcher, gui) = makeDispatcher()
        let entries = [wireFileTreeEntry(pathHash: 123, isDir: true, isExpanded: true, id: "/project/lib", path: "/project/lib", name: "lib", relPath: "lib")]
        dispatcher.dispatch(.guiFileTree(version: 2, treeFlags: 0x03, treeState: 3, selectedId: "/project/lib", treeWidth: 30,
                                          rootPath: "/project", errorReason: "", entries: entries))

        #expect(gui.fileTreeState.visible == true)
        #expect(gui.fileTreeState.focused == true)
        #expect(gui.fileTreeState.treeState == .ready)
        #expect(gui.fileTreeState.entries.count == 1)
        #expect(gui.fileTreeState.entries[0].name == "lib")
        #expect(gui.fileTreeState.projectRoot == "/project")
    }

    @Test("guiFileTreeSelection updates selection and focus without replacing entries")
    @MainActor func guiFileTreeSelectionRouting() {
        let (dispatcher, gui) = makeDispatcher()
        let entries = [
            wireFileTreeEntry(pathHash: 1, isSelected: true, isFocused: true, id: "/project/a", path: "/project/a", name: "a", relPath: "a"),
            wireFileTreeEntry(pathHash: 2, id: "/project/b", path: "/project/b", name: "b", relPath: "b")
        ]
        dispatcher.dispatch(.guiFileTree(version: 2, treeFlags: 0x03, treeState: 3, selectedId: "/project/a", treeWidth: 30,
                                          rootPath: "/project", errorReason: "", entries: entries))

        dispatcher.dispatch(.guiFileTreeSelection(selectedId: "/project/b", focused: false))

        #expect(gui.fileTreeState.entries.count == 2)
        #expect(gui.fileTreeState.entries[0].id == "/project/a")
        #expect(gui.fileTreeState.entries[1].id == "/project/b")
        #expect(gui.fileTreeState.selectedId == "/project/b")
        #expect(gui.fileTreeState.selectedIndex == 1)
        #expect(gui.fileTreeState.focused == false)
        #expect(gui.fileTreeState.entries[0].isSelected == false)
        #expect(gui.fileTreeState.entries[1].isSelected == true)
        #expect(gui.fileTreeState.entries.allSatisfy { $0.isFocused == false })
    }

    @Test("guiFileTreeSelection ignores unknown selected id without clearing selection")
    @MainActor func guiFileTreeSelectionIgnoresUnknownId() {
        let (dispatcher, gui) = makeDispatcher()
        let entries = [
            wireFileTreeEntry(pathHash: 1, isSelected: true, isFocused: true, id: "/project/a", path: "/project/a", name: "a", relPath: "a")
        ]
        dispatcher.dispatch(.guiFileTree(version: 2, treeFlags: 0x03, treeState: 3, selectedId: "/project/a", treeWidth: 30,
                                          rootPath: "/project", errorReason: "", entries: entries))

        dispatcher.dispatch(.guiFileTreeSelection(selectedId: "/project/missing", focused: false))

        #expect(gui.fileTreeState.selectedId == "/project/a")
        #expect(gui.fileTreeState.selectedIndex == 0)
        #expect(gui.fileTreeState.focused == false)
        #expect(gui.fileTreeState.entries[0].isSelected == true)
        #expect(gui.fileTreeState.entries[0].isFocused == false)
    }

    @Test("guiFileTree hides when explicit tree state is hidden")
    @MainActor func guiFileTreeHidesOnHiddenState() {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.dispatch(.guiFileTree(version: 2, treeFlags: 0x01, treeState: 3, selectedId: "/project/a", treeWidth: 30,
                                          rootPath: "/project", errorReason: "",
                                          entries: [wireFileTreeEntry(pathHash: 1, id: "/project/a", path: "/project/a", name: "a", relPath: "a")]))
        #expect(gui.fileTreeState.visible == true)

        dispatcher.dispatch(.guiFileTree(version: 2, treeFlags: 0x00, treeState: 0, selectedId: "", treeWidth: 0,
                                          rootPath: "/project", errorReason: "", entries: []))
        #expect(gui.fileTreeState.visible == false)
        #expect(gui.fileTreeState.projectRoot == "/project")
    }

    @Test("guiFileTree clears project root when hidden payload has no root")
    @MainActor func guiFileTreeClearsRootOnHiddenPayload() {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.dispatch(.guiFileTree(version: 2, treeFlags: 0x01, treeState: 3, selectedId: "/project/a", treeWidth: 30,
                                          rootPath: "/project", errorReason: "",
                                          entries: [wireFileTreeEntry(pathHash: 1, id: "/project/a", path: "/project/a", name: "a", relPath: "a")]))

        dispatcher.dispatch(.guiFileTree(version: 2, treeFlags: 0x00, treeState: 0, selectedId: "", treeWidth: 0,
                                          rootPath: "", errorReason: "", entries: []))

        #expect(gui.fileTreeState.visible == false)
        #expect(gui.fileTreeState.projectRoot == "")
    }

    @Test("guiFileTree keeps an empty visible tree open")
    @MainActor func guiFileTreeKeepsEmptyVisibleTreeOpen() {
        let (dispatcher, gui) = makeDispatcher()

        dispatcher.dispatch(.guiFileTree(version: 2, treeFlags: 0x11, treeState: 2, selectedId: "", treeWidth: 30,
                                          rootPath: "/empty-project", errorReason: "", entries: []))

        #expect(gui.fileTreeState.visible == true)
        #expect(gui.fileTreeState.treeState == .empty)
        #expect(gui.fileTreeState.entries.isEmpty)
        #expect(gui.fileTreeState.projectRoot == "/empty-project")
    }

    @Test("guiFileTree preserves loading and error states with empty entries")
    @MainActor func guiFileTreePreservesLoadingAndErrorStates() {
        let (dispatcher, gui) = makeDispatcher()

        dispatcher.dispatch(.guiFileTree(version: 2, treeFlags: 0x01, treeState: 1, selectedId: "", treeWidth: 30,
                                          rootPath: "/project", errorReason: "", entries: []))
        #expect(gui.fileTreeState.visible == true)
        #expect(gui.fileTreeState.treeState == .loading)

        dispatcher.dispatch(.guiFileTree(version: 2, treeFlags: 0x01, treeState: 4, selectedId: "", treeWidth: 30,
                                          rootPath: "/project", errorReason: "permission denied", entries: []))
        #expect(gui.fileTreeState.visible == true)
        #expect(gui.fileTreeState.treeState == .error)
        #expect(gui.fileTreeState.errorReason == "permission denied")
    }

    @Test("guiGitStatus updates state when repo has entries")
    @MainActor func guiGitStatusRouting() {
        let (dispatcher, gui) = makeDispatcher()
        let rawEntries = [
            Wire.GitStatusEntry(pathHash: 12345, section: 1, status: 1, path: "lib/editor.ex")
        ]
        dispatcher.dispatch(.guiGitStatus(repoState: 0, syncing: false, ahead: 2, behind: 0,
                                           branchName: "main", entries: rawEntries, toast: nil, entryBasePath: "", lastCommitMessage: ""))

        #expect(gui.gitStatusState.visible == true)
        #expect(gui.gitStatusState.branchName == "main")
        #expect(gui.gitStatusState.ahead == 2)
        #expect(gui.gitStatusState.changedEntries.count == 1)
        #expect(gui.gitStatusState.changedEntries[0].path == "lib/editor.ex")
    }

    @Test("guiGitStatus hides when notARepo with empty entries (panel closed signal)")
    @MainActor func guiGitStatusHidesOnClearSignal() {
        let (dispatcher, gui) = makeDispatcher()
        // First show it with real data
        let rawEntries = [
            Wire.GitStatusEntry(pathHash: 12345, section: 1, status: 1, path: "lib/editor.ex")
        ]
        dispatcher.dispatch(.guiGitStatus(repoState: 0, syncing: false, ahead: 0, behind: 0,
                                           branchName: "main", entries: rawEntries, toast: nil, entryBasePath: "", lastCommitMessage: ""))
        #expect(gui.gitStatusState.visible == true)

        // Then send the "panel closed" sentinel: notARepo (1) + empty entries. Syncing and toast still update because remote operations can finish while the panel is hidden.
        dispatcher.dispatch(.guiGitStatus(repoState: 1, syncing: true, ahead: 0, behind: 0,
                                           branchName: "", entries: [], toast: (message: "Push failed", level: 1, action: 1), entryBasePath: "", lastCommitMessage: ""))
        #expect(gui.gitStatusState.visible == false)
        #expect(gui.gitStatusState.syncing == true)
        #expect(gui.gitStatusState.toastMessage == "Push failed")
        #expect(gui.gitStatusState.toastAction == .pullAndRetry)
    }

    @Test("guiGitStatus keeps unknown git status entries")
    @MainActor func guiGitStatusKeepsUnknownStatus() {
        let (dispatcher, gui) = makeDispatcher()
        let rawEntries = [
            Wire.GitStatusEntry(pathHash: 12345, section: 1, status: 0, path: "lib/unknown.ex"),
            Wire.GitStatusEntry(pathHash: 12346, section: 1, status: 99, path: "lib/invalid-status.ex")
        ]
        dispatcher.dispatch(.guiGitStatus(repoState: 0, syncing: false, ahead: 0, behind: 0,
                                           branchName: "main", entries: rawEntries, toast: nil, entryBasePath: "", lastCommitMessage: ""))

        #expect(gui.gitStatusState.changedEntries.count == 2)
        #expect(gui.gitStatusState.changedEntries[0].status == .unknown)
        #expect(gui.gitStatusState.changedEntries[1].status == .unknown)
    }

    @Test("guiGitStatus drops entries with invalid sections")
    @MainActor func guiGitStatusDropsInvalidSections() {
        let (dispatcher, gui) = makeDispatcher()
        let rawEntries = [
            Wire.GitStatusEntry(pathHash: 12345, section: 99, status: 1, path: "lib/bad-section.ex")
        ]
        dispatcher.dispatch(.guiGitStatus(repoState: 0, syncing: false, ahead: 0, behind: 0,
                                           branchName: "main", entries: rawEntries, toast: nil, entryBasePath: "", lastCommitMessage: ""))

        #expect(gui.gitStatusState.totalCount == 0)
    }

    @Test("guiGitStatus shows not-a-repo panel when BEAM sends a project root")
    @MainActor func guiGitStatusShowsNotARepoPanel() {
        let (dispatcher, gui) = makeDispatcher()

        dispatcher.dispatch(.guiGitStatus(repoState: 1, syncing: false, ahead: 0, behind: 0,
                                           branchName: "", entries: [], toast: nil, entryBasePath: "/project", lastCommitMessage: ""))

        #expect(gui.gitStatusState.visible == true)
        #expect(gui.gitStatusState.repoState == .notARepo)
        #expect(gui.gitStatusState.entryBasePath == "/project")
    }

    @Test("guiGitStatus shows panel for normal repo with clean working tree")
    @MainActor func guiGitStatusShowsCleanRepo() {
        let (dispatcher, gui) = makeDispatcher()
        // Normal repo (0) with zero entries is a clean working tree, NOT
        // a hide signal. Only notARepo + empty triggers hide.
        dispatcher.dispatch(.guiGitStatus(repoState: 0, syncing: false, ahead: 0, behind: 0,
                                           branchName: "main", entries: [], toast: nil, entryBasePath: "", lastCommitMessage: ""))
        #expect(gui.gitStatusState.visible == true)
        #expect(gui.gitStatusState.branchName == "main")
    }

    @Test("guiGitStatus preserves toast message when metadata is unknown")
    @MainActor func guiGitStatusToastFallback() {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.dispatch(.guiGitStatus(repoState: 0, syncing: false, ahead: 0, behind: 0,
                                           branchName: "main", entries: [], toast: (message: "Remote failed", level: 99, action: 99), entryBasePath: "", lastCommitMessage: ""))

        #expect(gui.gitStatusState.toastMessage == "Remote failed")
        #expect(gui.gitStatusState.toastLevel == .error)
        #expect(gui.gitStatusState.toastAction == .none)

        dispatcher.dispatch(.guiGitStatus(repoState: 0, syncing: false, ahead: 0, behind: 0,
                                           branchName: "main", entries: [], toast: nil, entryBasePath: "", lastCommitMessage: ""))

        #expect(gui.gitStatusState.toastMessage == nil)
        #expect(gui.gitStatusState.toastLevel == .success)
        #expect(gui.gitStatusState.toastAction == .none)
    }

    @Test("guiCompletion visible updates completionState")
    @MainActor func guiCompletionVisible() {
        let (dispatcher, gui) = makeDispatcher()
        let items = [Wire.CompletionItem(kind: 1, label: "def", detail: "keyword")]
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
        let items = [Wire.CompletionItem(kind: 1, label: "def", detail: "keyword")]
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
        let bindings = [Wire.WhichKeyBinding(kind: 0, key: "f", description: "Find file", icon: "")]
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
        dispatcher.dispatch(.guiStatusBar(StatusBarUpdate(contentKind: 0, mode: 1, cursorLine: 42,
                                           cursorCol: 9, lineCount: 500, flags: 0x03,
                                           lspStatus: 1, gitBranch: "main",
                                           message: "-- INSERT --", filetype: "elixir",
                                           errorCount: 3, warningCount: 7,
                                           modelName: "", messageCount: 0, sessionStatus: 0,
                                           infoCount: 1, hintCount: 2,
                                           macroRecording: 0, parserStatus: 0, agentStatus: 0,
                                           gitAdded: 5, gitModified: 3, gitDeleted: 1,
                                           icon: "", iconColorR: 0, iconColorG: 0, iconColorB: 0,
                                           filename: "editor.ex", diagnosticHint: "",
                                           backgroundSubagentCount: 0, backgroundSubagentLabel: "",
                                           indent: .init(kind: 1, size: 4),
                                           modelineLeftSegments: [Wire.StatusBarSegment(id: 0, text: " NORMAL ", fgColor: 0xFFFFFF, bgColor: 0x000000, attrs: 1, command: "")],
                                           modelineRightSegments: [],
                                           selection: .init(mode: 2, size: 3))))

        #expect(gui.statusBarState.mode == 1)
        #expect(gui.statusBarState.cursorLine == 42)
        #expect(gui.statusBarState.gitBranch == "main")
        #expect(gui.statusBarState.filetype == "elixir")
        #expect(gui.statusBarState.errorCount == 3)
        #expect(gui.statusBarState.indent.kind == 1)
        #expect(gui.statusBarState.indent.size == 4)
        #expect(gui.statusBarState.modelineLeftSegments.count == 1)
        #expect(gui.statusBarState.modelineLeftSegments[0].text == " NORMAL ")
        #expect(gui.statusBarState.selection.mode == 2)
        #expect(gui.statusBarState.selection.size == 3)
    }

    @Test("guiStatusBar agent variant populates background buffer fields")
    @MainActor func guiStatusBarAgentRouting() {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.dispatch(.guiStatusBar(StatusBarUpdate(contentKind: 1, mode: 0, cursorLine: 11,
                                           cursorCol: 6, lineCount: 100, flags: 0x03,
                                           lspStatus: 1, gitBranch: "feat/agent",
                                           message: "", filetype: "elixir",
                                           errorCount: 1, warningCount: 2,
                                           modelName: "claude-3-5-sonnet", messageCount: 7, sessionStatus: 1,
                                           infoCount: 0, hintCount: 1,
                                           macroRecording: 0, parserStatus: 0, agentStatus: 1,
                                           gitAdded: 3, gitModified: 2, gitDeleted: 0,
                                           icon: "", iconColorR: 0, iconColorG: 0, iconColorB: 0,
                                           filename: "editor.ex", diagnosticHint: "",
                                           backgroundSubagentCount: 2, backgroundSubagentLabel: "session-2: tests",
                                           modelineLeftSegments: [], modelineRightSegments: [])))

        #expect(gui.statusBarState.contentKind == 1)
        #expect(gui.statusBarState.isAgentWindow == true)
        #expect(gui.statusBarState.modelName == "claude-3-5-sonnet")
        #expect(gui.statusBarState.messageCount == 7)
        // Background buffer fields populated
        #expect(gui.statusBarState.cursorLine == 11)
        #expect(gui.statusBarState.gitBranch == "feat/agent")
        #expect(gui.statusBarState.filetype == "elixir")
        #expect(gui.statusBarState.errorCount == 1)
        #expect(gui.statusBarState.gitAdded == 3)
        #expect(gui.statusBarState.backgroundSubagentCount == 2)
        #expect(gui.statusBarState.backgroundSubagentLabel == "session-2: tests")
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
                                        hasPreview: false, items: [], actionMenu: nil, modePrefix: ">"))

        #expect(gui.pickerState.visible == true)
        #expect(gui.pickerState.title == "Find File")
        #expect(gui.pickerState.query == "edi")
        #expect(gui.pickerState.modePrefix == ">")
    }

    @Test("guiPicker hidden clears pickerState")
    @MainActor func guiPickerHidden() {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.dispatch(.guiPicker(visible: true, selectedIndex: 0, filteredCount: 5,
                                        totalCount: 100, title: "Find File", query: "edi",
                                        hasPreview: false, items: [], actionMenu: nil, modePrefix: ">"))
        dispatcher.dispatch(.guiPicker(visible: false, selectedIndex: 0, filteredCount: 0,
                                        totalCount: 0, title: "", query: "",
                                        hasPreview: false, items: [], actionMenu: nil, modePrefix: ""))

        #expect(gui.pickerState.visible == false)
        #expect(gui.pickerState.items.isEmpty)
        #expect(gui.pickerState.modePrefix.isEmpty)
    }

    @Test("guiAgentChat visible updates agentChatState")
    @MainActor func guiAgentChatVisible() {
        let (dispatcher, gui) = makeDispatcher()
        let messages: [Wire.ChatMessage] = [Wire.ChatMessage(beamId: 1, content: .user(text: "hello"))]
        dispatcher.dispatch(.guiAgentChat(visible: true, status: 1, model: "claude",
                                           thinkingLevel: "medium", prompt: "Fix this", promptLineCount: 1,
                                           promptCursorLine: 0, promptCursorCol: 0,
                                           promptVimMode: 1, promptVisibleRows: 1,
                                           promptCompletion: nil, pendingToolName: nil,
                                           pendingToolSummary: "", helpVisible: false, helpGroups: [], messages: messages))

        #expect(gui.agentChatState.visible == true)
        #expect(gui.agentChatState.model == "claude")
        #expect(gui.agentChatState.thinkingLevel == "medium")
        #expect(gui.agentChatState.messages.count == 1)
    }

    @Test("guiAgentChat hidden clears agentChatState")
    @MainActor func guiAgentChatHidden() {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.dispatch(.guiAgentChat(visible: false, status: 0, model: "",
                                           thinkingLevel: "", prompt: "", promptLineCount: 1,
                                           promptCursorLine: 0, promptCursorCol: 0,
                                           promptVimMode: 0, promptVisibleRows: 1,
                                           promptCompletion: nil, pendingToolName: nil,
                                           pendingToolSummary: "", helpVisible: false, helpGroups: [], messages: []))

        #expect(gui.agentChatState.visible == false)
        #expect(gui.agentChatState.messages.isEmpty)
    }

    @Test("guiBottomPanel visible updates bottomPanelState and appends entries")
    @MainActor func guiBottomPanelVisible() {
        let (dispatcher, gui) = makeDispatcher()
        let tabs = [Wire.BottomPanelTab(tabType: 0, name: "Messages")]
        let entries = [Wire.MessageEntry(id: 1, level: 1, subsystem: 0,
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
        let tools = [Wire.ToolEntry(name: "elixir_ls", label: "ElixirLS",
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
        let gutter = Wire.WindowGutter(
            windowId: 1, contentRow: 0, contentCol: 5, contentHeight: 24,
            isActive: true, contentWidth: 80, cursorLine: 10, lineNumberStyle: .hybrid,
            lineNumberWidth: 4, signColWidth: 1, entries: []
        )
        dispatcher.dispatch(.guiGutter(data: gutter))

        #expect(dispatcher.frameState.windowGutters[1] != nil)
        #expect(dispatcher.currentFrameGutterWindowIds.contains(1))
        // Active window gutter syncs gutterCol
        #expect(dispatcher.frameState.gutterCol == 5) // 4 + 1
    }

    @Test("guiHoverPopup exposes lines after scroll offset")
    @MainActor func guiHoverPopupScrollOffset() {
        let (dispatcher, gui) = makeDispatcher()
        let lines = [
            Wire.HoverLine(lineType: .text, segments: [Wire.HoverSegment(style: .plain, fgColor: nil, flags: 0, text: "one")]),
            Wire.HoverLine(lineType: .text, segments: [Wire.HoverSegment(style: .plain, fgColor: nil, flags: 0, text: "two")]),
            Wire.HoverLine(lineType: .text, segments: [Wire.HoverSegment(style: .plain, fgColor: nil, flags: 0, text: "three")])
        ]

        dispatcher.dispatch(.guiHoverPopup(visible: true, anchorRow: 4, anchorCol: 8, focused: true, scrollOffset: 1, lines: lines))

        #expect(gui.hoverPopupState.visible == true)
        #expect(gui.hoverPopupState.scrollOffset == 1)
        #expect(gui.hoverPopupState.visibleLines.map { $0.segments.first?.text } == ["two", "three"])
    }

    // MARK: - Batch lifecycle

    @Test("batchEnd fires onFirstRender once then clears it")
    @MainActor func batchEndFiresFirstRenderOnce() {
        let (dispatcher, _) = makeDispatcher()
        var callCount = 0
        dispatcher.onFirstRender = { callCount += 1 }

        dispatcher.dispatch(.batchEnd)
        #expect(callCount == 1)
        #expect(dispatcher.onFirstRender == nil)

        dispatcher.dispatch(.batchEnd)
        #expect(callCount == 1)
    }

    // MARK: - Theme

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

private func wireFileTreeEntry(
    pathHash: UInt32,
    isDir: Bool = false,
    isExpanded: Bool = false,
    isSelected: Bool = false,
    isFocused: Bool = false,
    isActive: Bool = false,
    isDirty: Bool = false,
    isEditing: Bool = false,
    isLastChild: Bool = false,
    id: String,
    path: String,
    name: String,
    relPath: String,
    editingType: UInt8 = 0xFF,
    editingText: String = ""
) -> Wire.FileTreeEntry {
    Wire.FileTreeEntry(
        pathHash: pathHash,
        id: id,
        path: path,
        isDir: isDir,
        isExpanded: isExpanded,
        isSelected: isSelected,
        isFocused: isFocused,
        isActive: isActive,
        isDirty: isDirty,
        isEditing: isEditing,
        isLastChild: isLastChild,
        depth: 0,
        gitStatus: 0,
        diagnosticErrorCount: 0,
        diagnosticWarningCount: 0,
        diagnosticInfoCount: 0,
        diagnosticHintCount: 0,
        guides: [],
        icon: "",
        name: name,
        relPath: relPath,
        editingType: editingType,
        editingText: editingText
    )
}
