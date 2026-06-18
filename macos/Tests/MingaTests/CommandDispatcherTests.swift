/// Tests for CommandDispatcher routing logic.
///
/// Verifies that each RenderCommand type updates the correct GUIState
/// sub-state when dispatched. Catches wiring bugs where a command is
/// routed to the wrong state or not routed at all.

import Testing
import Foundation

@MainActor
fileprivate func completeThemeSlots() -> [(UInt8, UInt8, UInt8, UInt8)] {
    CommandDispatcher.requiredThemeSlots.map { slot in
        (slot, slot, slot, slot)
    }
}

@Suite("CommandDispatcher Routing")
struct CommandDispatcherRoutingTests {

    @MainActor
    private func makeDispatcher() -> (CommandDispatcher, GUIState) {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 80, rows: 24, guiState: gui)
        return (dispatcher, gui)
    }

    // MARK: - Basic commands

    @Test("commitFrame preserves retained windows (no cell-grid clear/prune path)")
    @MainActor func commitFramePreservesRetainedWindows() {
        let (dispatcher, gui) = makeDispatcher()
        gui.windowContents[1] = GUIWindowContent(
            windowId: 1, fullRefresh: false,
            cursorRow: 0, cursorCol: 0, cursorShape: .block,
            rows: [], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: []
        )

        // A keyframe transaction (base 0) opened then committed.
        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))

        #expect(gui.windowContents[1] != nil)
    }

    @Test("setCursorShape updates frameState cursor shape")
    @MainActor func setCursorShapeCommand() {
        let (dispatcher, _) = makeDispatcher()
        dispatcher.applyForTesting(.setCursorShape(.beam))
        #expect(dispatcher.frameState.cursorShape == .beam)
    }

    @Test("protocolError latches a blocking message on protocolErrorState")
    @MainActor func protocolErrorRouting() {
        let (dispatcher, gui) = makeDispatcher()
        #expect(gui.protocolErrorState.isPresented == false)

        dispatcher.applyForTesting(.protocolError(message: "protocol_version mismatch: frontend 1, beam 2"))

        #expect(gui.protocolErrorState.isPresented == true)
        #expect(gui.protocolErrorState.message == "protocol_version mismatch: frontend 1, beam 2")
    }

    @Test("setWindowBg updates frameState defaultBg")
    @MainActor func setWindowBgCommand() {
        let (dispatcher, _) = makeDispatcher()
        dispatcher.applyForTesting(.setWindowBg(r: 0x28, g: 0x2C, b: 0x34))
        let expected: UInt32 = (0x28 << 16) | (0x2C << 8) | 0x34
        #expect(dispatcher.frameState.defaultBg == expected)
    }

    // MARK: - View-driven FrameState mutations

    @Test("applyViewportResize writes grid dimensions and marks dirty")
    @MainActor func applyViewportResizeUpdatesGrid() {
        let (dispatcher, _) = makeDispatcher()
        // Clear the dirty flag set at init so we can assert the resize sets it.
        dispatcher.markRendered()
        #expect(dispatcher.frameState.dirty == false)

        // A view-driven resize (e.g. font change) funnels through the dispatcher.
        dispatcher.applyViewportResize(newCols: 120, newRows: 40)

        #expect(dispatcher.frameState.cols == 120)
        #expect(dispatcher.frameState.rows == 40)
        #expect(dispatcher.frameState.dirty == true)
    }

    @Test("applyViewportResize is a no-op when dimensions are unchanged")
    @MainActor func applyViewportResizeNoOp() {
        let (dispatcher, _) = makeDispatcher()
        // Dispatcher starts at 80x24 (see makeDispatcher).
        dispatcher.markRendered()
        #expect(dispatcher.frameState.dirty == false)

        dispatcher.applyViewportResize(newCols: 80, newRows: 24)

        #expect(dispatcher.frameState.cols == 80)
        #expect(dispatcher.frameState.rows == 24)
        #expect(dispatcher.frameState.dirty == false)
    }

    @Test("markRendered clears the dirty flag the view consumed")
    @MainActor func markRenderedClearsDirty() {
        let (dispatcher, _) = makeDispatcher()
        dispatcher.applyViewportResize(newCols: 100, newRows: 30)
        #expect(dispatcher.frameState.dirty == true)

        dispatcher.markRendered()

        #expect(dispatcher.frameState.dirty == false)
    }

    // MARK: - GUI chrome routing

    @Test("guiTabBar updates tabBarState")
    @MainActor func guiTabBarRouting() {
        let (dispatcher, gui) = makeDispatcher()
        let tabs = [
            Wire.TabEntry(id: 1, groupId: 0, isActive: true, isDirty: false, isAgent: false,
                       hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "", label: "test.ex")
        ]
        dispatcher.applyForTesting(.guiTabBar(activeIndex: 0, tabs: tabs))

        #expect(gui.tabBarState.tabs.count == 1)
        #expect(gui.tabBarState.tabs[0].label == "test.ex")
        #expect(gui.tabBarState.activeIndex == 0)
    }

    @Test("guiObservatory updates observatoryState")
    @MainActor func guiObservatoryRouting() {
        let (dispatcher, gui) = makeDispatcher()
        let nodes = [Wire.ObservatoryNode(pid: "<0.1.0>", parentPid: "", name: "Minga.Supervisor", processClass: 0, depth: 0, memory: 1024, messageQueueLen: 0, reductions: 10, sparkline: [0, 0.5])]

        dispatcher.applyForTesting(.guiObservatory(visible: true, nodeCount: 1, nodes: nodes))

        #expect(gui.observatoryState.visible == true)
        #expect(gui.observatoryState.nodes.count == 1)
        #expect(gui.observatoryState.nodes[0].pid == "<0.1.0>")
        #expect(gui.observatoryState.nodes[0].sparkline == [0, 0.5])
    }

    @Test("guiObservatory hidden payload hides observatoryState")
    @MainActor func guiObservatoryHiddenRouting() {
        let (dispatcher, gui) = makeDispatcher()
        let nodes = [Wire.ObservatoryNode(pid: "<0.1.0>", parentPid: "", name: "Minga.Supervisor", processClass: 0, depth: 0, memory: 1024, messageQueueLen: 0, reductions: 10, sparkline: [])]
        dispatcher.applyForTesting(.guiObservatory(visible: true, nodeCount: 1, nodes: nodes))

        dispatcher.applyForTesting(.guiObservatory(visible: false, nodeCount: 0, nodes: []))

        #expect(gui.observatoryState.visible == false)
        #expect(gui.observatoryState.nodes.isEmpty)
    }

    @Test("guiFileTree updates fileTreeState when entries present")
    @MainActor func guiFileTreeRouting() {
        let (dispatcher, gui) = makeDispatcher()
        let entries = [wireFileTreeEntry(pathHash: 123, isDir: true, isExpanded: true, id: "/project/lib", path: "/project/lib", name: "lib", relPath: "lib")]
        dispatcher.applyForTesting(.guiFileTree(version: 2, treeFlags: 0x03, treeState: 3, selectedId: "/project/lib", treeWidth: 30,
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
        dispatcher.applyForTesting(.guiFileTree(version: 2, treeFlags: 0x03, treeState: 3, selectedId: "/project/a", treeWidth: 30,
                                          rootPath: "/project", errorReason: "", entries: entries))

        dispatcher.applyForTesting(.guiFileTreeSelection(selectedId: "/project/b", focused: false))

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
        dispatcher.applyForTesting(.guiFileTree(version: 2, treeFlags: 0x03, treeState: 3, selectedId: "/project/a", treeWidth: 30,
                                          rootPath: "/project", errorReason: "", entries: entries))

        dispatcher.applyForTesting(.guiFileTreeSelection(selectedId: "/project/missing", focused: false))

        #expect(gui.fileTreeState.selectedId == "/project/a")
        #expect(gui.fileTreeState.selectedIndex == 0)
        #expect(gui.fileTreeState.focused == false)
        #expect(gui.fileTreeState.entries[0].isSelected == true)
        #expect(gui.fileTreeState.entries[0].isFocused == false)
    }

    @Test("guiFileTree hides when explicit tree state is hidden")
    @MainActor func guiFileTreeHidesOnHiddenState() {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.applyForTesting(.guiFileTree(version: 2, treeFlags: 0x01, treeState: 3, selectedId: "/project/a", treeWidth: 30,
                                          rootPath: "/project", errorReason: "",
                                          entries: [wireFileTreeEntry(pathHash: 1, id: "/project/a", path: "/project/a", name: "a", relPath: "a")]))
        #expect(gui.fileTreeState.visible == true)

        dispatcher.applyForTesting(.guiFileTree(version: 2, treeFlags: 0x00, treeState: 0, selectedId: "", treeWidth: 0,
                                          rootPath: "/project", errorReason: "", entries: []))
        #expect(gui.fileTreeState.visible == false)
        #expect(gui.fileTreeState.projectRoot == "/project")
    }

    @Test("guiFileTree clears project root when hidden payload has no root")
    @MainActor func guiFileTreeClearsRootOnHiddenPayload() {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.applyForTesting(.guiFileTree(version: 2, treeFlags: 0x01, treeState: 3, selectedId: "/project/a", treeWidth: 30,
                                          rootPath: "/project", errorReason: "",
                                          entries: [wireFileTreeEntry(pathHash: 1, id: "/project/a", path: "/project/a", name: "a", relPath: "a")]))

        dispatcher.applyForTesting(.guiFileTree(version: 2, treeFlags: 0x00, treeState: 0, selectedId: "", treeWidth: 0,
                                          rootPath: "", errorReason: "", entries: []))

        #expect(gui.fileTreeState.visible == false)
        #expect(gui.fileTreeState.projectRoot == "")
    }

    @Test("guiFileTree keeps an empty visible tree open")
    @MainActor func guiFileTreeKeepsEmptyVisibleTreeOpen() {
        let (dispatcher, gui) = makeDispatcher()

        dispatcher.applyForTesting(.guiFileTree(version: 2, treeFlags: 0x11, treeState: 2, selectedId: "", treeWidth: 30,
                                          rootPath: "/empty-project", errorReason: "", entries: []))

        #expect(gui.fileTreeState.visible == true)
        #expect(gui.fileTreeState.treeState == .empty)
        #expect(gui.fileTreeState.entries.isEmpty)
        #expect(gui.fileTreeState.projectRoot == "/empty-project")
    }

    @Test("guiFileTree preserves loading and error states with empty entries")
    @MainActor func guiFileTreePreservesLoadingAndErrorStates() {
        let (dispatcher, gui) = makeDispatcher()

        dispatcher.applyForTesting(.guiFileTree(version: 2, treeFlags: 0x01, treeState: 1, selectedId: "", treeWidth: 30,
                                          rootPath: "/project", errorReason: "", entries: []))
        #expect(gui.fileTreeState.visible == true)
        #expect(gui.fileTreeState.treeState == .loading)

        dispatcher.applyForTesting(.guiFileTree(version: 2, treeFlags: 0x01, treeState: 4, selectedId: "", treeWidth: 30,
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
        dispatcher.applyForTesting(.guiGitStatus(repoState: 0, syncing: false, ahead: 2, behind: 0,
                                           branchName: "main", entries: rawEntries, toast: nil, entryBasePath: "", lastCommitMessage: "", stashCount: 4))

        #expect(gui.gitStatusState.visible == true)
        #expect(gui.gitStatusState.branchName == "main")
        #expect(gui.gitStatusState.ahead == 2)
        #expect(gui.gitStatusState.stashCount == 4)
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
        dispatcher.applyForTesting(.guiGitStatus(repoState: 0, syncing: false, ahead: 0, behind: 0,
                                           branchName: "main", entries: rawEntries, toast: nil, entryBasePath: "", lastCommitMessage: "", stashCount: 0))
        #expect(gui.gitStatusState.visible == true)

        // Then send the "panel closed" sentinel: notARepo (1) + empty entries. Syncing and toast still update because remote operations can finish while the panel is hidden.
        dispatcher.applyForTesting(.guiGitStatus(repoState: 1, syncing: true, ahead: 0, behind: 0,
                                           branchName: "", entries: [], toast: (message: "Push failed", level: 1, action: 1), entryBasePath: "", lastCommitMessage: "", stashCount: 0))
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
        dispatcher.applyForTesting(.guiGitStatus(repoState: 0, syncing: false, ahead: 0, behind: 0,
                                           branchName: "main", entries: rawEntries, toast: nil, entryBasePath: "", lastCommitMessage: "", stashCount: 0))

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
        dispatcher.applyForTesting(.guiGitStatus(repoState: 0, syncing: false, ahead: 0, behind: 0,
                                           branchName: "main", entries: rawEntries, toast: nil, entryBasePath: "", lastCommitMessage: "", stashCount: 0))

        #expect(gui.gitStatusState.totalCount == 0)
    }

    @Test("guiGitStatus shows not-a-repo panel when BEAM sends a project root")
    @MainActor func guiGitStatusShowsNotARepoPanel() {
        let (dispatcher, gui) = makeDispatcher()

        dispatcher.applyForTesting(.guiGitStatus(repoState: 1, syncing: false, ahead: 0, behind: 0,
                                           branchName: "", entries: [], toast: nil, entryBasePath: "/project", lastCommitMessage: "", stashCount: 0))

        #expect(gui.gitStatusState.visible == true)
        #expect(gui.gitStatusState.repoState == .notARepo)
        #expect(gui.gitStatusState.entryBasePath == "/project")
    }

    @Test("guiGitStatus shows panel for normal repo with clean working tree")
    @MainActor func guiGitStatusShowsCleanRepo() {
        let (dispatcher, gui) = makeDispatcher()
        // Normal repo (0) with zero entries is a clean working tree, NOT
        // a hide signal. Only notARepo + empty triggers hide.
        dispatcher.applyForTesting(.guiGitStatus(repoState: 0, syncing: false, ahead: 0, behind: 0,
                                           branchName: "main", entries: [], toast: nil, entryBasePath: "", lastCommitMessage: "", stashCount: 0))
        #expect(gui.gitStatusState.visible == true)
        #expect(gui.gitStatusState.branchName == "main")
    }

    @Test("guiGitStatus preserves toast message when metadata is unknown")
    @MainActor func guiGitStatusToastFallback() {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.applyForTesting(.guiGitStatus(repoState: 0, syncing: false, ahead: 0, behind: 0,
                                           branchName: "main", entries: [], toast: (message: "Remote failed", level: 99, action: 99), entryBasePath: "", lastCommitMessage: "", stashCount: 0))

        #expect(gui.gitStatusState.toastMessage == "Remote failed")
        #expect(gui.gitStatusState.toastLevel == .error)
        #expect(gui.gitStatusState.toastAction == .none)

        dispatcher.applyForTesting(.guiGitStatus(repoState: 0, syncing: false, ahead: 0, behind: 0,
                                           branchName: "main", entries: [], toast: nil, entryBasePath: "", lastCommitMessage: "", stashCount: 0))

        #expect(gui.gitStatusState.toastMessage == nil)
        #expect(gui.gitStatusState.toastLevel == .success)
        #expect(gui.gitStatusState.toastAction == .none)
    }

    @Test("guiCompletion visible updates completionState")
    @MainActor func guiCompletionVisible() {
        let (dispatcher, gui) = makeDispatcher()
        let items = [Wire.CompletionItem(kind: 1, label: "def", detail: "keyword")]
        dispatcher.applyForTesting(.guiCompletion(visible: true, anchorRow: 5, anchorCol: 10,
                                            selectedIndex: 0, items: items, documentation: "Defines a function."))

        #expect(gui.completionState.visible == true)
        #expect(gui.completionState.items.count == 1)
        #expect(gui.completionState.anchorRow == 5)
        #expect(gui.completionState.documentation == "Defines a function.")
    }

    @Test("guiCompletion hidden clears completionState")
    @MainActor func guiCompletionHidden() {
        let (dispatcher, gui) = makeDispatcher()
        // Show then hide
        let items = [Wire.CompletionItem(kind: 1, label: "def", detail: "keyword")]
        dispatcher.applyForTesting(.guiCompletion(visible: true, anchorRow: 5, anchorCol: 10,
                                            selectedIndex: 0, items: items, documentation: "doc"))
        dispatcher.applyForTesting(.guiCompletion(visible: false, anchorRow: 0, anchorCol: 0,
                                            selectedIndex: 0, items: [], documentation: ""))

        #expect(gui.completionState.visible == false)
        #expect(gui.completionState.items.isEmpty)
        #expect(gui.completionState.documentation.isEmpty)
    }

    @Test("guiWhichKey visible updates whichKeyState")
    @MainActor func guiWhichKeyVisible() {
        let (dispatcher, gui) = makeDispatcher()
        let bindings = [Wire.WhichKeyBinding(kind: 0, key: "f", description: "Find file", icon: "")]
        dispatcher.applyForTesting(.guiWhichKey(visible: true, prefix: "SPC",
                                          page: 0, pageCount: 1, bindings: bindings))

        #expect(gui.whichKeyState.visible == true)
        #expect(gui.whichKeyState.prefix == "SPC")
        #expect(gui.whichKeyState.bindings.count == 1)
    }

    @Test("guiWhichKey hidden clears whichKeyState")
    @MainActor func guiWhichKeyHidden() {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.applyForTesting(.guiWhichKey(visible: false, prefix: "", page: 0,
                                          pageCount: 0, bindings: []))
        #expect(gui.whichKeyState.visible == false)
    }

    @Test("guiStatusBar updates statusBarState and clears safeMode")
    @MainActor func guiStatusBarRouting() {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.applyForTesting(.guiStatusBar(StatusBarUpdate(contentKind: 0, mode: 1, cursorLine: 42,
                                           cursorCol: 9, lineCount: 500, flags: 0x0B, safeMode: true,
                                           lspStatus: 1, gitBranch: "main",
                                           message: "-- INSERT --", filetype: "elixir",
                                           errorCount: 3, warningCount: 7,
                                           modelName: "", messageCount: 0, sessionStatus: 0,
                                           infoCount: 1, hintCount: 2,
                                           macroRecording: 0, parserStatus: 0, agentStatus: 0,
                                           activeToolName: "",
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
        #expect(gui.statusBarState.safeMode == true)
        #expect(gui.statusBarState.gitBranch == "main")
        #expect(gui.statusBarState.filetype == "elixir")
        #expect(gui.statusBarState.errorCount == 3)
        #expect(gui.statusBarState.indent.kind == 1)
        #expect(gui.statusBarState.indent.size == 4)
        #expect(gui.statusBarState.modelineLeftSegments.count == 1)
        #expect(gui.statusBarState.modelineLeftSegments[0].text == " NORMAL ")
        #expect(gui.statusBarState.selection.mode == 2)
        #expect(gui.statusBarState.selection.size == 3)
        #expect(gui.statusBarState.activeToolName.isEmpty)

        dispatcher.applyForTesting(.guiStatusBar(StatusBarUpdate(contentKind: 0, mode: 1, cursorLine: 42,
                                           cursorCol: 9, lineCount: 500, flags: 0x03, safeMode: false,
                                           lspStatus: 1, gitBranch: "main",
                                           message: "-- INSERT --", filetype: "elixir",
                                           errorCount: 3, warningCount: 7,
                                           modelName: "", messageCount: 0, sessionStatus: 0,
                                           infoCount: 1, hintCount: 2,
                                           macroRecording: 0, parserStatus: 0, agentStatus: 0,
                                           activeToolName: "",
                                           gitAdded: 5, gitModified: 3, gitDeleted: 1,
                                           icon: "", iconColorR: 0, iconColorG: 0, iconColorB: 0,
                                           filename: "editor.ex", diagnosticHint: "",
                                           backgroundSubagentCount: 0, backgroundSubagentLabel: "",
                                           indent: .init(kind: 1, size: 4),
                                           modelineLeftSegments: [Wire.StatusBarSegment(id: 0, text: " NORMAL ", fgColor: 0xFFFFFF, bgColor: 0x000000, attrs: 1, command: "")],
                                           modelineRightSegments: [],
                                           selection: .init(mode: 2, size: 3))))

        #expect(gui.statusBarState.safeMode == false)
    }

    @Test("guiStatusBar agent variant populates background buffer fields")
    @MainActor func guiStatusBarAgentRouting() {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.applyForTesting(.guiStatusBar(StatusBarUpdate(contentKind: 1, mode: 0, cursorLine: 11,
                                           cursorCol: 6, lineCount: 100, flags: 0x03,
                                           lspStatus: 1, gitBranch: "feat/agent",
                                           message: "", filetype: "elixir",
                                           errorCount: 1, warningCount: 2,
                                           modelName: "claude-3-5-sonnet", messageCount: 7, sessionStatus: 1,
                                           infoCount: 0, hintCount: 1,
                                           macroRecording: 0, parserStatus: 0, agentStatus: 1,
                                           activeToolName: "read_file",
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
        #expect(gui.statusBarState.activeToolName == "read_file")
        #expect(gui.statusBarState.backgroundSubagentCount == 2)
        #expect(gui.statusBarState.backgroundSubagentLabel == "session-2: tests")
    }

    @Test("guiBreadcrumb updates breadcrumbState")
    @MainActor func guiBreadcrumbRouting() {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.applyForTesting(.guiBreadcrumb(segments: ["lib", "minga", "editor.ex"]))

        #expect(gui.breadcrumbState.segments == ["lib", "minga", "editor.ex"])
    }

    @Test("guiPicker visible updates pickerState")
    @MainActor func guiPickerVisible() {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.applyForTesting(.guiPicker(visible: true, selectedIndex: 0, filteredCount: 5,
                                        totalCount: 100, markedCount: 2, title: "Find File", query: "edi",
                                        hasPreview: false, items: [], actionMenu: nil, modePrefix: ">", loadStatus: .ready))

        #expect(gui.pickerState.visible == true)
        #expect(gui.pickerState.title == "Find File")
        #expect(gui.pickerState.query == "edi")
        #expect(gui.pickerState.modePrefix == ">")
        #expect(gui.pickerState.markedCount == 2)
    }

    @Test("guiPicker hidden clears pickerState")
    @MainActor func guiPickerHidden() {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.applyForTesting(.guiPicker(visible: true, selectedIndex: 0, filteredCount: 5,
                                        totalCount: 100, markedCount: 2, title: "Find File", query: "edi",
                                        hasPreview: false, items: [], actionMenu: nil, modePrefix: ">", loadStatus: .ready))
        dispatcher.applyForTesting(.guiPicker(visible: false, selectedIndex: 0, filteredCount: 0,
                                        totalCount: 0, markedCount: 0, title: "", query: "",
                                        hasPreview: false, items: [], actionMenu: nil, modePrefix: "", loadStatus: .ready))

        #expect(gui.pickerState.visible == false)
        #expect(gui.pickerState.items.isEmpty)
        #expect(gui.pickerState.modePrefix.isEmpty)
        #expect(gui.pickerState.markedCount == 0)
    }

    @Test("guiAgentChat visible updates agentChatState")
    @MainActor func guiAgentChatVisible() {
        let (dispatcher, gui) = makeDispatcher()
        let messages: [Wire.ChatMessage] = [Wire.ChatMessage(beamId: 1, content: .user(text: "hello"))]
        dispatcher.applyForTesting(.guiAgentChat(visible: true, status: 1, model: "claude",
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
        dispatcher.applyForTesting(.guiAgentChat(visible: false, status: 0, model: "",
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
        dispatcher.applyForTesting(.guiBottomPanel(visible: true, activeTabIndex: 0,
                                             heightPercent: 30, filterPreset: 0,
                                             tabs: tabs, entries: entries))

        #expect(gui.bottomPanelState.visible == true)
        #expect(gui.bottomPanelState.tabs.count == 1)
        #expect(gui.bottomPanelState.messagesState.entries.count == 1)
    }

    @Test("guiBottomPanel hidden hides bottomPanelState")
    @MainActor func guiBottomPanelHidden() {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.applyForTesting(.guiBottomPanel(visible: false, activeTabIndex: 0,
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
        dispatcher.applyForTesting(.guiToolManager(visible: true, filter: 0,
                                             selectedIndex: 0, tools: tools))

        #expect(gui.toolManagerState.visible == true)
        #expect(gui.toolManagerState.tools.count == 1)
        #expect(gui.toolManagerState.tools[0].name == "elixir_ls")
    }

    @Test("guiToolManager hidden clears toolManagerState")
    @MainActor func guiToolManagerHidden() {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.applyForTesting(.guiToolManager(visible: false, filter: 0,
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
        dispatcher.applyForTesting(.guiWindowContent(data: content))

        #expect(gui.windowContents[7] != nil)
        #expect(gui.windowContents[7]?.cursorRow == 5)
    }

    @Test("guiWindowOverlayDelta updates matching retained content")
    @MainActor func guiWindowOverlayDeltaRouting() {
        let (dispatcher, gui) = makeDispatcher()
        gui.windowContents[7] = GUIWindowContent(
            windowId: 7, fullRefresh: false, contentEpoch: 42,
            cursorRow: 5, cursorCol: 10, cursorShape: .block,
            rows: [], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: []
        )

        dispatcher.applyForTesting(.guiWindowOverlayDelta(data: GUIWindowOverlayDelta(
            windowId: 7, contentEpoch: 42, cursorVisible: false,
            cursorRow: 6, cursorCol: 11, cursorShape: .beam,
            cursorline: GUICursorline(row: 6, bg: 0x112233)
        )))

        #expect(gui.windowContents[7]?.cursorVisible == false)
        #expect(gui.windowContents[7]?.cursorRow == 6)
        #expect(gui.windowContents[7]?.cursorCol == 11)
        #expect(gui.windowContents[7]?.cursorShape == .beam)
        #expect(gui.windowContents[7]?.cursorline == GUICursorline(row: 6, bg: 0x112233))
        #expect(dispatcher.currentFrameWindowIds.contains(7))
        #expect(dispatcher.frameState.cursorVisible == false)
    }

    @Test("guiWindowOverlayDelta clears retained cursorline when cursorline is omitted")
    @MainActor func guiWindowOverlayDeltaClearsRetainedCursorline() {
        let (dispatcher, gui) = makeDispatcher()
        gui.windowContents[7] = GUIWindowContent(
            windowId: 7, fullRefresh: false, contentEpoch: 42,
            cursorRow: 5, cursorCol: 10, cursorShape: .block,
            rows: [], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: [],
            cursorline: GUICursorline(row: 5, bg: 0x112233)
        )

        dispatcher.applyForTesting(.guiWindowOverlayDelta(data: GUIWindowOverlayDelta(
            windowId: 7, contentEpoch: 42, cursorVisible: true,
            cursorRow: 6, cursorCol: 11, cursorShape: .beam,
            cursorline: nil
        )))

        #expect(gui.windowContents[7]?.cursorline == nil)
        #expect(gui.windowContents[7]?.cursorRow == 6)
        #expect(gui.windowContents[7]?.cursorCol == 11)
        #expect(gui.windowContents[7]?.cursorShape == .beam)
        #expect(dispatcher.currentFrameWindowIds.contains(7))
    }

    @Test("stale guiWindowOverlayDelta is ignored without marking the window live")
    @MainActor func staleGuiWindowOverlayDeltaIgnored() {
        let (dispatcher, gui) = makeDispatcher()
        let content = GUIWindowContent(
            windowId: 7, fullRefresh: false, contentEpoch: 42,
            cursorRow: 5, cursorCol: 10, cursorShape: .block,
            rows: [], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: []
        )
        gui.windowContents[7] = content
        dispatcher.frameState.cursorVisible = true

        dispatcher.applyForTesting(.guiWindowOverlayDelta(data: GUIWindowOverlayDelta(
            windowId: 7, contentEpoch: 41, cursorVisible: false,
            cursorRow: 6, cursorCol: 11, cursorShape: .beam,
            cursorline: nil
        )))

        #expect(gui.windowContents[7] === content)
        #expect(dispatcher.currentFrameWindowIds.contains(7) == false)
        #expect(dispatcher.frameState.cursorVisible == true)
    }

    @Test("guiWindowOverlayDelta without retained content is ignored")
    @MainActor func missingGuiWindowOverlayDeltaIgnored() {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.frameState.cursorVisible = true

        dispatcher.applyForTesting(.guiWindowOverlayDelta(data: GUIWindowOverlayDelta(
            windowId: 7, contentEpoch: 42, cursorVisible: false,
            cursorRow: 6, cursorCol: 11, cursorShape: .beam,
            cursorline: nil
        )))

        #expect(gui.windowContents[7] == nil)
        #expect(dispatcher.currentFrameWindowIds.contains(7) == false)
        #expect(dispatcher.frameState.cursorVisible == true)
    }

    @Test("guiWindowRowsDelta updates retained rows and marks window live")
    @MainActor func guiWindowRowsDeltaRouting() {
        let (dispatcher, gui) = makeDispatcher()
        let retained = GUIVisualRow(rowType: .normal, rowId: 1, bufLine: 0, contentHash: 11, text: "old", spans: [])
        let replacement = GUIVisualRow(rowType: .normal, rowId: 2, bufLine: 1, contentHash: 22, text: "new", spans: [])
        gui.windowContents[7] = GUIWindowContent(
            windowId: 7, fullRefresh: false, contentEpoch: 42,
            cursorRow: 5, cursorCol: 10, cursorShape: .block,
            rows: [retained], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: []
        )

        dispatcher.applyForTesting(.guiWindowRowsDelta(data: GUIWindowRowsDelta(
            windowId: 7,
            contentEpoch: 42,
            cursorVisible: true,
            cursorRow: 6,
            cursorCol: 11,
            cursorShape: .beam,
            scrollLeft: 2,
            rows: [.reference(rowId: 1, contentHash: 11), .full(replacement)],
            selection: nil,
            searchMatches: [],
            diagnosticUnderlines: [],
            documentHighlights: [],
            lineAnnotations: [],
            paneGeometry: nil,
            cursorline: nil
        )))

        #expect(gui.windowContents[7]?.rows.map(\.text) == ["old", "new"])
        #expect(gui.windowContents[7]?.scrollLeft == 2)
        #expect(gui.windowContents[7]?.cursorShape == .beam)
        #expect(dispatcher.currentFrameWindowIds.contains(7))
    }

    @Test("guiWindowViewportDelta updates retained rows and marks window live")
    @MainActor func guiWindowViewportDeltaRouting() {
        let (dispatcher, gui) = makeDispatcher()
        let retained = GUIVisualRow(rowType: .normal, rowId: 1, bufLine: 0, contentHash: 11, text: "old", spans: [])
        gui.windowContents[7] = GUIWindowContent(
            windowId: 7, fullRefresh: false, contentEpoch: 42,
            cursorRow: 5, cursorCol: 10, cursorShape: .block,
            rows: [retained], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: []
        )

        dispatcher.applyForTesting(.guiWindowViewportDelta(data: GUIWindowRowsDelta(
            windowId: 7,
            contentEpoch: 42,
            cursorVisible: true,
            cursorRow: 6,
            cursorCol: 11,
            cursorShape: .beam,
            scrollLeft: 2,
            rows: [.reference(rowId: 1, contentHash: 11)],
            selection: nil,
            searchMatches: [],
            diagnosticUnderlines: [],
            documentHighlights: [],
            lineAnnotations: [],
            paneGeometry: nil,
            cursorline: nil
        )))

        #expect(gui.windowContents[7]?.rows.map(\.text) == ["old"])
        #expect(gui.windowContents[7]?.scrollLeft == 2)
        #expect(gui.windowContents[7]?.cursorShape == .beam)
        #expect(dispatcher.currentFrameWindowIds.contains(7))
    }

    @Test("stale guiWindowRowsDelta is ignored without clearing current content")
    @MainActor func staleGuiWindowRowsDeltaIgnored() {
        let (dispatcher, gui) = makeDispatcher()
        let retained = GUIVisualRow(rowType: .normal, rowId: 1, bufLine: 0, contentHash: 11, text: "old", spans: [])
        let content = GUIWindowContent(
            windowId: 7, fullRefresh: false, contentEpoch: 42,
            cursorRow: 5, cursorCol: 10, cursorShape: .block,
            rows: [retained], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: []
        )
        gui.windowContents[7] = content

        dispatcher.applyForTesting(.guiWindowRowsDelta(data: GUIWindowRowsDelta(
            windowId: 7,
            contentEpoch: 41,
            cursorVisible: true,
            cursorRow: 6,
            cursorCol: 11,
            cursorShape: .beam,
            scrollLeft: 0,
            rows: [.reference(rowId: 1, contentHash: 11)],
            selection: nil,
            searchMatches: [],
            diagnosticUnderlines: [],
            documentHighlights: [],
            lineAnnotations: [],
            paneGeometry: nil,
            cursorline: nil
        )))

        #expect(gui.windowContents[7] === content)
        #expect(dispatcher.currentFrameWindowIds.contains(7) == false)
    }

    @Test("guiWindowRowsDelta missing retained ref clears content for full-refresh recovery")
    @MainActor func guiWindowRowsDeltaMissingRefClearsContent() {
        let (dispatcher, gui) = makeDispatcher()
        let retained = GUIVisualRow(rowType: .normal, rowId: 1, bufLine: 0, contentHash: 11, text: "old", spans: [])
        gui.windowContents[7] = GUIWindowContent(
            windowId: 7, fullRefresh: false, contentEpoch: 42,
            cursorRow: 5, cursorCol: 10, cursorShape: .block,
            rows: [retained], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: []
        )

        dispatcher.applyForTesting(.guiWindowRowsDelta(data: GUIWindowRowsDelta(
            windowId: 7,
            contentEpoch: 42,
            cursorVisible: true,
            cursorRow: 6,
            cursorCol: 11,
            cursorShape: .beam,
            scrollLeft: 0,
            rows: [.reference(rowId: 999, contentHash: 11)],
            selection: nil,
            searchMatches: [],
            diagnosticUnderlines: [],
            documentHighlights: [],
            lineAnnotations: [],
            paneGeometry: nil,
            cursorline: nil
        )))

        #expect(gui.windowContents[7] == nil)
        #expect(dispatcher.currentFrameWindowIds.contains(7) == false)
    }

    @Test("guiGutterSeparator updates frameState gutter state")
    @MainActor func guiGutterSepRouting() {
        let (dispatcher, _) = makeDispatcher()
        dispatcher.applyForTesting(.guiGutterSeparator(col: 4, r: 0x3F, g: 0x44, b: 0x4A))

        #expect(dispatcher.frameState.gutterCol == 4)
        let expected: UInt32 = (0x3F << 16) | (0x44 << 8) | 0x4A
        #expect(dispatcher.frameState.gutterSeparatorColor == expected)
    }

    @Test("guiCursorline updates frameState cursorline state")
    @MainActor func guiCursorlineRouting() {
        let (dispatcher, _) = makeDispatcher()
        dispatcher.applyForTesting(.guiCursorline(row: 12, r: 0x2C, g: 0x32, b: 0x3C))

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
        dispatcher.applyForTesting(.guiGutter(data: gutter))

        #expect(dispatcher.frameState.windowGutters[1] != nil)
        #expect(dispatcher.currentFrameWindowIds.contains(1))
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

        dispatcher.applyForTesting(.guiHoverPopup(visible: true, anchorRow: 4, anchorCol: 8, focused: true, scrollOffset: 1, lines: lines))

        #expect(gui.hoverPopupState.visible == true)
        #expect(gui.hoverPopupState.scrollOffset == 1)
        #expect(gui.hoverPopupState.visibleLines.map { $0.segments.first?.text } == ["two", "three"])
    }

    // MARK: - Batch lifecycle

    @Test("commitFrame fires onFirstRender once then clears it")
    @MainActor func commitFrameFiresFirstRenderOnce() {
        let (dispatcher, _) = makeDispatcher()
        var callCount = 0
        dispatcher.onFirstRender = { callCount += 1 }

        // Two well-formed keyframe transactions; onFirstRender fires only once.
        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))
        #expect(callCount == 1)
        #expect(dispatcher.onFirstRender == nil)

        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 0))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.commitFrame(frameSeq: 2, seq: 0))
        #expect(callCount == 1)
    }

    // MARK: - Theme

    @Test("guiTheme updates themeColors and syncs to frameState")
    @MainActor func guiThemeRouting() {
        let (dispatcher, gui) = makeDispatcher()
        let slots: [(slotId: UInt8, r: UInt8, g: UInt8, b: UInt8)] = [
            (GUI_COLOR_GUTTER_FG, 0xAA, 0xBB, 0xCC)
        ]
        dispatcher.applyForTesting(.guiTheme(slots: slots))

        // Check frameState got the RGB value synced
        let expected: UInt32 = (0xAA << 16) | (0xBB << 8) | 0xCC
        #expect(dispatcher.frameState.gutterColors.fg == expected)
        #expect(gui.themeColors.gutterFgRGB == expected)
        #expect(gui.themeColors.hasAppliedTheme)
    }

    @Test("keyframe with content but no guiTheme presents protocol error")
    @MainActor func keyframeWithoutThemeErrors() {
        let (dispatcher, gui) = makeDispatcher()

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [Wire.TabEntry(id: 1, groupId: 0, isActive: true, isDirty: false, isAgent: false, hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "", label: "unthemed.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))

        #expect(gui.protocolErrorState.isPresented)
        #expect(gui.protocolErrorState.message == "missing gui_theme in keyframe")
        #expect(gui.tabBarState.tabs.isEmpty)
    }

    @Test("keyframe with empty guiTheme rejects promotion")
    @MainActor func keyframeWithEmptyThemeErrors() {
        let (dispatcher, gui) = makeDispatcher()

        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 0))
        dispatcher.dispatch(.guiTheme(slots: []))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [Wire.TabEntry(id: 1, groupId: 0, isActive: true, isDirty: false, isAgent: false, hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "", label: "empty.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 2, seq: 0))

        #expect(gui.protocolErrorState.isPresented)
        #expect(gui.protocolErrorState.message?.contains("missing gui_theme slots in keyframe") == true)
        #expect(gui.protocolErrorState.message?.contains("0x01") == true)
        #expect(gui.themeColors.hasAppliedTheme == false)
        #expect(gui.tabBarState.tabs.isEmpty)
    }

    @Test("keyframe with partial guiTheme rejects promotion")
    @MainActor func keyframeWithPartialThemeErrors() {
        let (dispatcher, gui) = makeDispatcher()

        dispatcher.dispatch(.beginFrame(frameSeq: 3, baseFrameSeq: 0))
        dispatcher.dispatch(.guiTheme(slots: [(GUI_COLOR_EDITOR_BG, 0x00, 0x00, 0x00)]))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [Wire.TabEntry(id: 1, groupId: 0, isActive: true, isDirty: false, isAgent: false, hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "", label: "partial.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 3, seq: 0))

        #expect(gui.protocolErrorState.isPresented)
        #expect(gui.protocolErrorState.message?.contains("missing gui_theme slots in keyframe") == true)
        #expect(gui.protocolErrorState.message?.contains("0x02") == true)
        #expect(gui.protocolErrorState.message?.contains("0xA0") == true)
        #expect(gui.themeColors.hasAppliedTheme == false)
        #expect(gui.tabBarState.tabs.isEmpty)
    }
}

/// AC tests for frame-transaction staging and commit (#2219 child D).
///
/// Mirrors the epic headline in Swift: observable state is unchanged between
/// begin and commit, commit promotes atomically, invalidation requests a
/// keyframe with no partial promotion, and out-of-band commands apply without a
/// transaction.
@Suite("CommandDispatcher Frame Staging")
struct CommandDispatcherStagingTests {

    @MainActor
    private func makeDispatcher() -> (CommandDispatcher, GUIState) {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 80, rows: 24, guiState: gui)
        return (dispatcher, gui)
    }

    private func tab(_ label: String) -> Wire.TabEntry {
        Wire.TabEntry(id: 1, groupId: 0, isActive: true, isDirty: false, isAgent: false,
                      hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0,
                      icon: "", label: label)
    }

    // MARK: - Nothing paints between begin and commit

    @Test("observable GUIState is unchanged between begin and a partial frame")
    @MainActor func guiStateUnchangedMidTransaction() {
        let (dispatcher, gui) = makeDispatcher()

        // Establish a committed baseline so we have a "presented" tab bar.
        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("old.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))
        #expect(gui.tabBarState.tabs.first?.label == "old.ex")

        // Open a new transaction and stage a different tab bar, but do NOT commit.
        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 1))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("new.ex")]))

        // The presented state still shows the last committed frame.
        #expect(gui.tabBarState.tabs.first?.label == "old.ex")
    }

    @Test("observable FrameState is unchanged between begin and a partial frame")
    @MainActor func frameStateUnchangedMidTransaction() {
        let (dispatcher, _) = makeDispatcher()

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.setCursorShape(.block))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))
        #expect(dispatcher.frameState.cursorShape == .block)

        // Stage a shape change without committing; the presented shape holds.
        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 1))
        dispatcher.dispatch(.setCursorShape(.beam))
        #expect(dispatcher.frameState.cursorShape == .block)
    }

    // MARK: - Commit promotes atomically

    @Test("commit promotes all staged commands in one batch")
    @MainActor func commitPromotesStagedCommands() {
        let (dispatcher, gui) = makeDispatcher()

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("a.ex")]))
        dispatcher.dispatch(.setCursorShape(.beam))
        // Nothing promoted yet.
        #expect(gui.tabBarState.tabs.isEmpty)
        #expect(dispatcher.frameState.cursorShape == .block)

        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))

        // Both staged mutations land together at commit.
        #expect(gui.tabBarState.tabs.first?.label == "a.ex")
        #expect(dispatcher.frameState.cursorShape == .beam)
        #expect(dispatcher.lastCommittedFrameSeq == 1)
    }

    @Test("onFrameReady fires only at commit, not on staged commands")
    @MainActor func frameReadyFiresAtCommit() {
        let (dispatcher, _) = makeDispatcher()
        var readyCount = 0
        dispatcher.onFrameReady = { readyCount += 1 }

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("a.ex")]))
        #expect(readyCount == 0)

        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))
        #expect(readyCount == 1)
    }

    // MARK: - Delta-base validation

    @Test("delta frame committing against the last committed seq promotes cleanly")
    @MainActor func deltaBaseMatchesCommits() {
        let (dispatcher, gui) = makeDispatcher()

        dispatcher.dispatch(.beginFrame(frameSeq: 5, baseFrameSeq: 0))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("base.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 5, seq: 0))

        // Next frame is a delta whose base names the frame we just committed.
        dispatcher.dispatch(.beginFrame(frameSeq: 6, baseFrameSeq: 5))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("delta.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 6, seq: 0))

        #expect(gui.tabBarState.tabs.first?.label == "delta.ex")
        #expect(dispatcher.lastCommittedFrameSeq == 6)
    }

    @Test("delta frame with empty guiTheme rejects promotion")
    @MainActor func deltaFrameWithEmptyThemeErrors() {
        let (dispatcher, gui) = makeDispatcher()

        dispatcher.dispatch(.beginFrame(frameSeq: 5, baseFrameSeq: 0))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("base.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 5, seq: 0))
        let baselineThemeBg = gui.themeColors.editorBg

        dispatcher.dispatch(.beginFrame(frameSeq: 6, baseFrameSeq: 5))
        dispatcher.dispatch(.guiTheme(slots: []))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("empty-delta.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 6, seq: 0))

        #expect(gui.protocolErrorState.isPresented)
        #expect(gui.protocolErrorState.message?.contains("missing gui_theme slots: ") == true)
        #expect(gui.protocolErrorState.message?.contains("0x01") == true)
        #expect(gui.protocolErrorState.message?.contains("0xA0") == true)
        #expect(gui.themeColors.editorBg == baselineThemeBg)
        #expect(gui.tabBarState.tabs.first?.label == "base.ex")
    }

    @Test("delta frame with partial guiTheme rejects promotion")
    @MainActor func deltaFrameWithPartialThemeErrors() {
        let (dispatcher, gui) = makeDispatcher()

        dispatcher.dispatch(.beginFrame(frameSeq: 5, baseFrameSeq: 0))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("base.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 5, seq: 0))
        let baselineThemeBg = gui.themeColors.editorBg

        dispatcher.dispatch(.beginFrame(frameSeq: 6, baseFrameSeq: 5))
        dispatcher.dispatch(.guiTheme(slots: [(GUI_COLOR_EDITOR_BG, 0x00, 0x00, 0x00)]))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("partial-delta.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 6, seq: 0))

        #expect(gui.protocolErrorState.isPresented)
        #expect(gui.protocolErrorState.message?.contains("missing gui_theme slots: ") == true)
        #expect(gui.protocolErrorState.message?.contains("0x02") == true)
        #expect(gui.protocolErrorState.message?.contains("0xA0") == true)
        #expect(gui.themeColors.editorBg == baselineThemeBg)
        #expect(gui.tabBarState.tabs.first?.label == "base.ex")
    }

    // MARK: - Invalidation requests a keyframe with no partial promotion

    @Test("commit seq mismatch invalidates with no promotion and requests keyframe")
    @MainActor func seqMismatchInvalidates() {
        let (dispatcher, gui) = makeDispatcher()
        var requested: [UInt32] = []
        dispatcher.onRequestKeyframe = { requested.append($0) }

        // Commit a clean baseline so lastCommittedFrameSeq is known.
        dispatcher.dispatch(.beginFrame(frameSeq: 3, baseFrameSeq: 0))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("good.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 3, seq: 0))

        // Open a frame, stage a change, then commit with the WRONG seq.
        dispatcher.dispatch(.beginFrame(frameSeq: 4, baseFrameSeq: 3))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("bad.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 99, seq: 0))

        // No partial promotion: the presented tab bar is still the good frame.
        #expect(gui.tabBarState.tabs.first?.label == "good.ex")
        // Keyframe requested carrying the last good frame_seq.
        #expect(requested == [3])
        // Resync hint raised.
        #expect(gui.resyncState.pending == true)
        #expect(dispatcher.lastCommittedFrameSeq == 3)
    }

    @Test("pending resync debounces further keyframe requests until a valid commit")
    @MainActor func resyncDebouncesRequests() {
        let (dispatcher, gui) = makeDispatcher()
        var requested: [UInt32] = []
        dispatcher.onRequestKeyframe = { requested.append($0) }

        // First invalidation: commit with no open transaction.
        dispatcher.dispatch(.commitFrame(frameSeq: 7, seq: 0))
        #expect(requested == [0])

        // Stale in-flight frame: base mismatch while resync is already pending.
        // It must discard silently without re-requesting (#2267 review: every
        // stale frame after an invalidation fails its base check; re-requesting
        // per frame would force a duplicate BEAM render each).
        dispatcher.dispatch(.beginFrame(frameSeq: 8, baseFrameSeq: 7))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("stale.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 8, seq: 0))
        #expect(requested == [0])

        // The keyframe arrives: pending clears and content promotes.
        dispatcher.dispatch(.beginFrame(frameSeq: 9, baseFrameSeq: 0))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("fresh.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 9, seq: 0))
        #expect(gui.resyncState.pending == false)
        #expect(gui.tabBarState.tabs.first?.label == "fresh.ex")
    }

    @Test("double begin (truncation) invalidates the open frame and requests keyframe")
    @MainActor func doubleBeginTruncates() {
        let (dispatcher, gui) = makeDispatcher()
        var requested: [UInt32] = []
        dispatcher.onRequestKeyframe = { requested.append($0) }

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("staged.ex")]))
        // A new begin before commit: the first frame was truncated.
        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 0))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))

        // The truncated frame promoted nothing.
        #expect(gui.tabBarState.tabs.isEmpty)
        #expect(requested == [0]) // no good frame yet
        #expect(gui.resyncState.pending == true)
    }

    @Test("base mismatch invalidates without promotion")
    @MainActor func baseMismatchInvalidates() {
        let (dispatcher, gui) = makeDispatcher()
        var requested: [UInt32] = []
        dispatcher.onRequestKeyframe = { requested.append($0) }

        dispatcher.dispatch(.beginFrame(frameSeq: 10, baseFrameSeq: 0))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("base.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 10, seq: 0))

        // Delta whose base names a frame this client never committed (7, not 10).
        dispatcher.dispatch(.beginFrame(frameSeq: 11, baseFrameSeq: 7))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("orphan.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 11, seq: 0))

        #expect(gui.tabBarState.tabs.first?.label == "base.ex")
        #expect(requested == [10])
        #expect(gui.resyncState.pending == true)
    }

    @Test("commit with no open begin invalidates and requests keyframe")
    @MainActor func commitWithoutBeginInvalidates() {
        let (dispatcher, _) = makeDispatcher()
        var requested: [UInt32] = []
        dispatcher.onRequestKeyframe = { requested.append($0) }

        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))
        #expect(requested == [0])
    }

    @Test("decodeFailed inside an open transaction invalidates and requests keyframe")
    @MainActor func decodeFailureInsideTransactionInvalidates() {
        let (dispatcher, gui) = makeDispatcher()
        var requested: [UInt32] = []
        dispatcher.onRequestKeyframe = { requested.append($0) }

        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 0))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("partial.ex")]))
        dispatcher.decodeFailed()

        #expect(gui.tabBarState.tabs.isEmpty)
        #expect(requested == [0])
        #expect(gui.resyncState.pending == true)
        // A subsequent decode failure with no open transaction is a no-op.
        requested.removeAll()
        dispatcher.decodeFailed()
        #expect(requested.isEmpty)
    }

    @Test("a clean commit after a resync clears the pending hint")
    @MainActor func cleanCommitClearsResyncHint() {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.onRequestKeyframe = { _ in }

        // Force a resync.
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))
        #expect(gui.resyncState.pending == true)

        // The recovering keyframe arrives and commits cleanly.
        dispatcher.dispatch(.beginFrame(frameSeq: 7, baseFrameSeq: 0))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("recovered.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 7, seq: 0))

        #expect(gui.resyncState.pending == false)
        #expect(gui.tabBarState.tabs.first?.label == "recovered.ex")
    }

    // MARK: - Out-of-band allowlist

    @Test("set_title applies immediately with no open transaction")
    @MainActor func titleAppliesOutOfBand() {
        let (dispatcher, _) = makeDispatcher()
        var requested: [UInt32] = []
        var title: String?
        dispatcher.onRequestKeyframe = { requested.append($0) }
        dispatcher.onTitleChanged = { title = $0 }

        dispatcher.dispatch(.setTitle("buffer.ex"))

        #expect(title == "buffer.ex")
        #expect(requested.isEmpty) // out-of-band, not an invalidation
    }

    @Test("set_window_bg applies immediately with no open transaction")
    @MainActor func windowBgAppliesOutOfBand() {
        let (dispatcher, _) = makeDispatcher()
        var requested: [UInt32] = []
        dispatcher.onRequestKeyframe = { requested.append($0) }

        dispatcher.dispatch(.setWindowBg(r: 0x28, g: 0x2C, b: 0x34))

        let expected: UInt32 = (0x28 << 16) | (0x2C << 8) | 0x34
        #expect(dispatcher.frameState.defaultBg == expected)
        #expect(requested.isEmpty)
    }

    @Test("protocol_error applies immediately with no open transaction")
    @MainActor func protocolErrorAppliesOutOfBand() {
        let (dispatcher, gui) = makeDispatcher()
        var requested: [UInt32] = []
        dispatcher.onRequestKeyframe = { requested.append($0) }

        dispatcher.dispatch(.protocolError(message: "version mismatch"))

        #expect(gui.protocolErrorState.isPresented == true)
        #expect(requested.isEmpty)
    }

    @Test("a chrome command outside a transaction is an invalidation, not applied")
    @MainActor func chromeOutOfBandInvalidates() {
        let (dispatcher, gui) = makeDispatcher()
        var requested: [UInt32] = []
        dispatcher.onRequestKeyframe = { requested.append($0) }

        // guiTabBar is NOT on the out-of-band allowlist.
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("rogue.ex")]))

        #expect(gui.tabBarState.tabs.isEmpty)
        #expect(requested == [0])
        #expect(gui.resyncState.pending == true)
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
        iconColorR: 0x6D,
        iconColorG: 0x80,
        iconColorB: 0x86,
        name: name,
        relPath: relPath,
        editingType: editingType,
        editingText: editingText
    )
}
