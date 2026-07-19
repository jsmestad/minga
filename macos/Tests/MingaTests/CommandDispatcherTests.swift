/// Tests for CommandDispatcher routing logic.
///
/// Verifies that each RenderCommand type updates the correct GUIState
/// sub-state when dispatched. Catches wiring bugs where a command is
/// routed to the wrong state or not routed at all.

import MingaUI
import Observation
import SwiftUI
import Synchronization
import Testing
import Foundation
import AppKit
import MingaProtocol

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

    @Test("empty keyframe prunes retained windows and stale gutter globals")
    @MainActor func emptyKeyframePrunesRetainedWindowState() throws {
        let (dispatcher, gui) = makeDispatcher()
        gui.windowContents[1] = try GUIWindowContent(
            windowId: 1, fullRefresh: false,
            cursorRow: 0, cursorCol: 0, cursorShape: .block,
            rows: [], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: []
        )
        dispatcher.applyForTesting(.guiGutter(data: Wire.WindowGutter(
            windowId: 1, contentRow: 0, contentCol: 5, contentHeight: 24,
            isActive: true, contentWidth: 80, cursorLine: 9, lineNumberStyle: .hybrid,
            lineNumberWidth: 4, signColWidth: 3,
            entries: [Wire.GutterEntry(bufLine: 9, displayType: .normal, signType: .none, foldEndLine: 0xFFFF_FFFF, signFg: 0, signText: "")]
        )))
        dispatcher.applyForTesting(.guiIndentGuides(data: IndentGuideData(
            windowId: 1, tabWidth: 4, activeGuideCol: 0xFFFF,
            guideCols: [2], lineIndentLevels: [1]
        )))
        #expect(dispatcher.frameState.windowGutters[1] != nil)
        #expect(dispatcher.frameState.gutterCol == 7)
        #expect(dispatcher.frameState.viewportTopLine == 9)

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))

        #expect(gui.windowContents.isEmpty)
        #expect(dispatcher.frameState.windowGutters.isEmpty)
        #expect(dispatcher.frameState.windowIndentGuides.isEmpty)
        #expect(dispatcher.committedEditorSnapshot?.windowIds.isEmpty == true)
        #expect(dispatcher.frameState.gutterCol == 0)
        #expect(dispatcher.frameState.viewportTopLine == 0xFFFF_FFFF)
    }

    @Test("keyframe commit prunes stale window content, gutters, and indent guides")
    @MainActor func keyframeCommitPrunesStaleWindowState() throws {
        let (dispatcher, gui) = makeDispatcher()
        gui.windowContents[2] = try GUIWindowContent(
            windowId: 2, fullRefresh: false,
            cursorRow: 0, cursorCol: 0, cursorShape: .block,
            rows: [], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: []
        )
        dispatcher.applyForTesting(.guiGutter(data: Wire.WindowGutter(
            windowId: 2, contentRow: 0, contentCol: 5, contentHeight: 24,
            isActive: false, contentWidth: 80, cursorLine: 0, lineNumberStyle: .hybrid,
            lineNumberWidth: 4, signColWidth: 3, entries: []
        )))
        dispatcher.applyForTesting(.guiIndentGuides(data: IndentGuideData(
            windowId: 2, tabWidth: 4, activeGuideCol: 0xFFFF,
            guideCols: [], lineIndentLevels: []
        )))

        dispatcher.dispatch(.beginFrame(frameSeq: 3, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        let geometry = editorGeometry(windowId: 1, lineNumberWidth: 4, signColWidth: 3)
        dispatcher.dispatch(.guiWindowContent(data: try editorContent(windowId: 1, geometry: geometry)))
        dispatcher.dispatch(.guiGutter(data: editorGutter(windowId: 1, geometry: geometry)))
        dispatcher.dispatch(.guiIndentGuides(data: IndentGuideData(
            windowId: 1, tabWidth: 4, activeGuideCol: 0xFFFF,
            guideCols: [], lineIndentLevels: []
        )))
        dispatcher.dispatch(.commitFrame(frameSeq: 3, seq: 0))

        #expect(gui.windowContents[1] != nil)
        #expect(gui.windowContents[2] == nil)
        #expect(dispatcher.frameState.windowGutters[1] != nil)
        #expect(dispatcher.frameState.windowGutters[2] == nil)
        #expect(dispatcher.frameState.windowIndentGuides[1] != nil)
        #expect(dispatcher.frameState.windowIndentGuides[2] == nil)
        #expect(dispatcher.committedEditorSnapshot?.windowIds == [1])
    }

    @Test("setCursorShape updates frameState cursor shape")
    @MainActor func setCursorShapeCommand() throws {
        let (dispatcher, _) = makeDispatcher()
        dispatcher.applyForTesting(.setCursorShape(.beam))
        #expect(dispatcher.frameState.cursorShape == .beam)
    }

    @Test("protocolError latches a blocking message on protocolErrorState")
    @MainActor func protocolErrorRouting() throws {
        let (dispatcher, gui) = makeDispatcher()
        #expect(gui.protocolErrorState.isPresented == false)

        dispatcher.applyForTesting(.protocolError(message: "protocol_version mismatch: frontend 1, beam 2"))

        #expect(gui.protocolErrorState.isPresented == true)
        #expect(gui.protocolErrorState.message == "protocol_version mismatch: frontend 1, beam 2")
    }

    @Test("setWindowBg updates frameState defaultBg")
    @MainActor func setWindowBgCommand() throws {
        let (dispatcher, _) = makeDispatcher()
        dispatcher.applyForTesting(.setWindowBg(r: 0x28, g: 0x2C, b: 0x34))
        let expected: UInt32 = (0x28 << 16) | (0x2C << 8) | 0x34
        #expect(dispatcher.frameState.defaultBg == expected)
    }

    // MARK: - View-driven FrameState mutations

    @Test("applyViewportResize writes grid dimensions")
    @MainActor func applyViewportResizeUpdatesGrid() throws {
        let (dispatcher, _) = makeDispatcher()

        // A view-driven resize (e.g. font change) funnels through the dispatcher.
        dispatcher.applyViewportResize(newCols: 120, newRows: 40)

        #expect(dispatcher.frameState.cols == 120)
        #expect(dispatcher.frameState.rows == 40)
    }

    @Test("applyViewportResize is a no-op when dimensions are unchanged")
    @MainActor func applyViewportResizeNoOp() throws {
        let (dispatcher, _) = makeDispatcher()

        dispatcher.applyViewportResize(newCols: 80, newRows: 24)

        #expect(dispatcher.frameState.cols == 80)
        #expect(dispatcher.frameState.rows == 24)
    }

    // MARK: - GUI chrome routing

    @Test("guiTabBar updates tabBarState")
    @MainActor func guiTabBarRouting() throws {
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

    @Test("canonical chrome payloads keep compatibility mirrors in presentation parity")
    @MainActor func canonicalChromeCompatibilityParity() {
        let (dispatcher, gui) = makeDispatcher()
        let workspaces = [
            Wire.WorkspaceEntry(
                id: 7, kind: 1, status: 0, flags: 0,
                colorR: 0x11, colorG: 0x22, colorB: 0x33,
                tabCount: 1, draftCount: 0, conflictCount: 0,
                runningBackgroundCount: 0, label: "Review", icon: "cpu"
            )
        ]
        let workspaceTabs = [
            Wire.WorkspaceTabEntry(
                id: 41, workspaceId: 7, kind: 0, flags: 0x0023,
                pathHash: 41, tintColorRGB: 0x112233, icon: "file-code", label: "first.ex",
                path: "/tmp/first.ex"
            ),
            Wire.WorkspaceTabEntry(
                id: 42, workspaceId: 7, kind: 0, flags: 0x0040,
                pathHash: 42, tintColorRGB: 0, icon: "file", label: "review.ex",
                path: "/tmp/review.ex"
            ),
        ]

        dispatcher.applyForTesting(.guiTabBar(activeIndex: 1, tabs: []))
        dispatcher.applyForTesting(.guiWorkspaces(
            version: 1,
            activeWorkspaceId: 7,
            mode: 1,
            flags: 0,
            workspaces: workspaces,
            visibleTabs: workspaceTabs
        ))
        dispatcher.applyForTesting(.guiSidebars(
            version: 1,
            activeId: "file_tree",
            sidebars: [Wire.SidebarMetadata(
                id: "file_tree",
                displayName: "File Tree",
                semanticKind: "file_tree",
                icon: "folder",
                order: 10,
                visible: true,
                focused: true,
                preferredWidth: 30,
                badgeCount: nil
            )]
        ))
        dispatcher.applyForTesting(.guiFileTree(
            version: 1,
            treeFlags: 0x03,
            treeState: FileTreeVisibilityState.ready.rawValue,
            selectedId: "",
            treeWidth: 30,
            rootPath: "/tmp",
            errorReason: "",
            entries: []
        ))
        dispatcher.applyForTesting(.guiStatusBar(StatusBarUpdate(
            contentKind: 0, mode: 0, cursorLine: 1, cursorCol: 1, lineCount: 1,
            flags: 0x02, lspStatus: 0, gitBranch: "feature/publication",
            message: "", filetype: "elixir", errorCount: 0, warningCount: 0,
            modelName: "", messageCount: 0, sessionStatus: 0, infoCount: 0,
            hintCount: 0, macroRecording: 0, parserStatus: 0, agentStatus: 0,
            gitAdded: 0, gitModified: 0, gitDeleted: 0, icon: "",
            iconColorR: 0, iconColorG: 0, iconColorB: 0, filename: "",
            diagnosticHint: "", backgroundSubagentCount: 0,
            backgroundSubagentLabel: ""
        )))
        dispatcher.applyForTesting(.guiGitStatus(
            repoState: 0,
            syncing: false,
            ahead: 0,
            behind: 0,
            branchName: "feature/publication",
            entries: [],
            toast: nil,
            entryBasePath: "/tmp",
            lastCommitMessage: "",
            stashCount: 0
        ))

        #expect(gui.workspaceState.activeWorkspaceId == 7)
        #expect(gui.tabBarState.activeWorkspaceId == 7)
        #expect(gui.workspaceState.visibleTabs.map(\.id) == [41, 42])
        #expect(gui.tabBarState.workspaceTabs.map(\.id) == [41, 42])
        #expect(gui.workspaceState.visibleTabs.map(\.workspaceId) == [7, 7])
        #expect(gui.tabBarState.workspaceTabs.map(\.workspaceId) == [7, 7])
        #expect(gui.workspaceState.visibleTabs.map(\.label) == ["first.ex", "review.ex"])
        #expect(gui.tabBarState.workspaceTabs.map(\.label) == ["first.ex", "review.ex"])
        #expect(gui.workspaceState.visibleTabs.map(\.path) == ["/tmp/first.ex", "/tmp/review.ex"])
        #expect(gui.tabBarState.workspaceTabs.map(\.path) == ["/tmp/first.ex", "/tmp/review.ex"])
        #expect(gui.workspaceState.visibleTabs.map(\.flags) == [0x0023, 0x0040])
        #expect(gui.tabBarState.workspaceTabs.map(\.flags) == [0x0023, 0x0040])

        let displayedTabs = gui.tabBarState.displayTabs
        #expect(displayedTabs.map(\.id) == [41, 42])
        #expect(displayedTabs.map(\.label) == ["first.ex", "review.ex"])
        #expect(displayedTabs.map(\.groupId) == [7, 7])
        #expect(displayedTabs.map(\.isActive) == [false, true])
        #expect(displayedTabs.map(\.isDirty) == [true, false])
        #expect(displayedTabs.map(\.hasAttention) == [true, false])
        #expect(displayedTabs.map(\.isPinned) == [true, false])
        #expect(displayedTabs.map(\.isEphemeral) == [false, true])

        #expect(gui.sidebarHostState.activeSidebar?.semanticKind == "file_tree")
        #expect(gui.fileTreeState.visible)
        #expect(gui.statusBarState.gitBranch == "feature/publication")
        #expect(gui.gitStatusState.branchName == "feature/publication")
    }

    @Test("guiObservatory updates observatoryState")
    @MainActor func guiObservatoryRouting() throws {
        let (dispatcher, gui) = makeDispatcher()
        let nodes = [Wire.ObservatoryNode(pid: "<0.1.0>", parentPid: "", name: "Minga.Supervisor", processClass: 0, depth: 0, memory: 1024, messageQueueLen: 0, reductions: 10, sparkline: [0, 0.5])]

        dispatcher.applyForTesting(.guiObservatory(visible: true, nodeCount: 1, nodes: nodes))

        #expect(gui.observatoryState.visible == true)
        #expect(gui.observatoryState.nodes.count == 1)
        #expect(gui.observatoryState.nodes[0].pid == "<0.1.0>")
        #expect(gui.observatoryState.nodes[0].sparkline == [0, 0.5])
    }

    @Test("guiObservatory hidden payload hides observatoryState")
    @MainActor func guiObservatoryHiddenRouting() throws {
        let (dispatcher, gui) = makeDispatcher()
        let nodes = [Wire.ObservatoryNode(pid: "<0.1.0>", parentPid: "", name: "Minga.Supervisor", processClass: 0, depth: 0, memory: 1024, messageQueueLen: 0, reductions: 10, sparkline: [])]
        dispatcher.applyForTesting(.guiObservatory(visible: true, nodeCount: 1, nodes: nodes))

        dispatcher.applyForTesting(.guiObservatory(visible: false, nodeCount: 0, nodes: []))

        #expect(gui.observatoryState.visible == false)
        #expect(gui.observatoryState.nodes.isEmpty)
    }

    @Test("guiFileTree updates fileTreeState when entries present")
    @MainActor func guiFileTreeRouting() throws {
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
    @MainActor func guiFileTreeSelectionRouting() throws {
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
    @MainActor func guiFileTreeSelectionIgnoresUnknownId() throws {
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

    @Test("file tree local navigation preview moves selection when eligible")
    @MainActor func fileTreeLocalNavigationPreviewMovesSelectionWhenEligible() throws {
        let (dispatcher, gui) = makeDispatcher()
        let entries = [
            wireFileTreeEntry(pathHash: 1, isSelected: true, isFocused: true, id: "/project/a", path: "/project/a", name: "a", relPath: "a"),
            wireFileTreeEntry(pathHash: 2, isFocused: true, id: "/project/b", path: "/project/b", name: "b", relPath: "b")
        ]
        dispatcher.applyForTesting(.guiFileTree(version: 2, treeFlags: 0x23, treeState: 3, selectedId: "/project/a", treeWidth: 30,
                                          rootPath: "/project", errorReason: "", entries: entries))

        let moved = dispatcher.previewFileTreeNavigation(codepoint: 106, modifiers: 0)

        #expect(moved == true)
        #expect(gui.fileTreeState.selectedId == "/project/b")
        #expect(gui.fileTreeState.selectedIndex == 1)
        #expect(gui.fileTreeState.entries[0].isSelected == false)
        #expect(gui.fileTreeState.entries[1].isSelected == true)
    }

    @Test("file tree local navigation preview is disabled without BEAM eligibility flag")
    @MainActor func fileTreeLocalNavigationPreviewRequiresEligibilityFlag() throws {
        let (dispatcher, gui) = makeDispatcher()
        let entries = [
            wireFileTreeEntry(pathHash: 1, isSelected: true, isFocused: true, id: "/project/a", path: "/project/a", name: "a", relPath: "a"),
            wireFileTreeEntry(pathHash: 2, isFocused: true, id: "/project/b", path: "/project/b", name: "b", relPath: "b")
        ]
        dispatcher.applyForTesting(.guiFileTree(version: 2, treeFlags: 0x03, treeState: 3, selectedId: "/project/a", treeWidth: 30,
                                          rootPath: "/project", errorReason: "", entries: entries))

        let moved = dispatcher.previewFileTreeNavigation(codepoint: 106, modifiers: 0)

        #expect(moved == false)
        #expect(gui.fileTreeState.selectedId == "/project/a")
        #expect(gui.fileTreeState.selectedIndex == 0)
        #expect(gui.fileTreeState.entries[0].isSelected == true)
        #expect(gui.fileTreeState.entries[1].isSelected == false)
    }

    @Test("guiFileTree hides when explicit tree state is hidden")
    @MainActor func guiFileTreeHidesOnHiddenState() throws {
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
    @MainActor func guiFileTreeClearsRootOnHiddenPayload() throws {
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
    @MainActor func guiFileTreeKeepsEmptyVisibleTreeOpen() throws {
        let (dispatcher, gui) = makeDispatcher()

        dispatcher.applyForTesting(.guiFileTree(version: 2, treeFlags: 0x11, treeState: 2, selectedId: "", treeWidth: 30,
                                          rootPath: "/empty-project", errorReason: "", entries: []))

        #expect(gui.fileTreeState.visible == true)
        #expect(gui.fileTreeState.treeState == .empty)
        #expect(gui.fileTreeState.entries.isEmpty)
        #expect(gui.fileTreeState.projectRoot == "/empty-project")
    }

    @Test("guiFileTree preserves loading and error states with empty entries")
    @MainActor func guiFileTreePreservesLoadingAndErrorStates() throws {
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
    @MainActor func guiGitStatusRouting() throws {
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
    @MainActor func guiGitStatusHidesOnClearSignal() throws {
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
    @MainActor func guiGitStatusKeepsUnknownStatus() throws {
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
    @MainActor func guiGitStatusDropsInvalidSections() throws {
        let (dispatcher, gui) = makeDispatcher()
        let rawEntries = [
            Wire.GitStatusEntry(pathHash: 12345, section: 99, status: 1, path: "lib/bad-section.ex")
        ]
        dispatcher.applyForTesting(.guiGitStatus(repoState: 0, syncing: false, ahead: 0, behind: 0,
                                           branchName: "main", entries: rawEntries, toast: nil, entryBasePath: "", lastCommitMessage: "", stashCount: 0))

        #expect(gui.gitStatusState.totalCount == 0)
    }

    @Test("guiGitStatus shows not-a-repo panel when BEAM sends a project root")
    @MainActor func guiGitStatusShowsNotARepoPanel() throws {
        let (dispatcher, gui) = makeDispatcher()

        dispatcher.applyForTesting(.guiGitStatus(repoState: 1, syncing: false, ahead: 0, behind: 0,
                                           branchName: "", entries: [], toast: nil, entryBasePath: "/project", lastCommitMessage: "", stashCount: 0))

        #expect(gui.gitStatusState.visible == true)
        #expect(gui.gitStatusState.repoState == .notARepo)
        #expect(gui.gitStatusState.entryBasePath == "/project")
    }

    @Test("guiGitStatus shows panel for normal repo with clean working tree")
    @MainActor func guiGitStatusShowsCleanRepo() throws {
        let (dispatcher, gui) = makeDispatcher()
        // Normal repo (0) with zero entries is a clean working tree, NOT
        // a hide signal. Only notARepo + empty triggers hide.
        dispatcher.applyForTesting(.guiGitStatus(repoState: 0, syncing: false, ahead: 0, behind: 0,
                                           branchName: "main", entries: [], toast: nil, entryBasePath: "", lastCommitMessage: "", stashCount: 0))
        #expect(gui.gitStatusState.visible == true)
        #expect(gui.gitStatusState.branchName == "main")
    }

    @Test("guiGitStatus preserves toast message when metadata is unknown")
    @MainActor func guiGitStatusToastFallback() throws {
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
    @MainActor func guiCompletionVisible() throws {
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
    @MainActor func guiCompletionHidden() throws {
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
    @MainActor func guiWhichKeyVisible() throws {
        let (dispatcher, gui) = makeDispatcher()
        let bindings = [Wire.WhichKeyBinding(kind: 0, key: "f", description: "Find file", icon: "")]
        dispatcher.applyForTesting(.guiWhichKey(visible: true, prefix: "SPC",
                                          page: 0, pageCount: 1, bindings: bindings))

        #expect(gui.whichKeyState.visible == true)
        #expect(gui.whichKeyState.prefix == "SPC")
        #expect(gui.whichKeyState.bindings.count == 1)
    }

    @Test("guiWhichKey hidden clears whichKeyState")
    @MainActor func guiWhichKeyHidden() throws {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.applyForTesting(.guiWhichKey(visible: false, prefix: "", page: 0,
                                          pageCount: 0, bindings: []))
        #expect(gui.whichKeyState.visible == false)
    }

    @Test("guiStatusBar updates statusBarState and clears safeMode")
    @MainActor func guiStatusBarRouting() throws {
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
    @MainActor func guiStatusBarAgentRouting() throws {
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
    @MainActor func guiBreadcrumbRouting() throws {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.applyForTesting(.guiBreadcrumb(segments: ["lib", "minga", "editor.ex"]))

        #expect(gui.breadcrumbState.segments == ["lib", "minga", "editor.ex"])
    }

    @Test("guiPicker visible updates pickerState")
    @MainActor func guiPickerVisible() throws {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.applyForTesting(.guiPicker(visible: true, selectedIndex: 0, filteredCount: 5,
                                        totalCount: 100, markedCount: 2, title: "Find File", query: "edi",
                                        hasPreview: false, items: [], actionMenu: nil, modePrefix: ">", loadStatus: .ready,
                                        queryGeneration: 7, acknowledgedQueryEditSeq: 11))

        #expect(gui.pickerState.visible == true)
        #expect(gui.pickerState.title == "Find File")
        #expect(gui.pickerState.query == "edi")
        #expect(gui.pickerState.queryGeneration == 7)
        #expect(gui.pickerState.acknowledgedQueryEditSeq == 11)
        #expect(gui.pickerState.modePrefix == ">")
        #expect(gui.pickerState.markedCount == 2)
    }

    @Test("guiPicker hidden clears pickerState")
    @MainActor func guiPickerHidden() throws {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.applyForTesting(.guiPicker(visible: true, selectedIndex: 0, filteredCount: 5,
                                        totalCount: 100, markedCount: 2, title: "Find File", query: "edi",
                                        hasPreview: false, items: [], actionMenu: nil, modePrefix: ">", loadStatus: .ready,
                                        queryGeneration: 7, acknowledgedQueryEditSeq: 11))
        dispatcher.applyForTesting(.guiPicker(visible: false, selectedIndex: 0, filteredCount: 0,
                                        totalCount: 0, markedCount: 0, title: "", query: "",
                                        hasPreview: false, items: [], actionMenu: nil, modePrefix: "", loadStatus: .ready,
                                        queryGeneration: 0, acknowledgedQueryEditSeq: 0))

        #expect(gui.pickerState.visible == false)
        #expect(gui.pickerState.items.isEmpty)
        #expect(gui.pickerState.modePrefix.isEmpty)
        #expect(gui.pickerState.markedCount == 0)
    }

    @Test("guiAgentChat updates chrome and leaves resident messages unchanged")
    @MainActor func guiAgentChatVisible() throws {
        let (dispatcher, gui) = makeDispatcher()
        gui.agentChatState.applyTranscript(mode: 0, epoch: 1, baseCount: 0, messages: [
            Wire.ChatMessage(beamId: 1, content: .user(text: "hello"))
        ])
        dispatcher.applyForTesting(.guiAgentChat(visible: true, status: 1, model: "claude",
                                           thinkingLevel: "medium", prompt: "Fix this", promptLineCount: 1,
                                           promptCursorLine: 0, promptCursorCol: 0,
                                           promptVimMode: 1, promptVisibleRows: 1,
                                           promptCompletion: nil, pendingToolName: nil,
                                           pendingToolSummary: "", helpVisible: false, helpGroups: []))

        #expect(gui.agentChatState.visible == true)
        #expect(gui.agentChatState.model == "claude")
        #expect(gui.agentChatState.thinkingLevel == "medium")
        #expect(gui.agentChatState.messages.map(\.id) == [1])
    }

    @Test("guiAgentTranscript populates agentChatState messages")
    @MainActor func guiAgentTranscriptPopulatesMessages() throws {
        let (dispatcher, gui) = makeDispatcher()
        // Chrome frame first (visible), then the resident transcript stream.
        dispatcher.applyForTesting(.guiAgentChat(visible: true, status: 1, model: "claude",
                                           thinkingLevel: "medium", prompt: "", promptLineCount: 1,
                                           promptCursorLine: 0, promptCursorCol: 0,
                                           promptVimMode: 1, promptVisibleRows: 1,
                                           promptCompletion: nil, pendingToolName: nil,
                                           pendingToolSummary: "", helpVisible: false, helpGroups: []))
        dispatcher.applyForTesting(.guiAgentTranscript(mode: 0, epoch: 3, truncated: false, trimFront: 0, baseCount: 0, messages: [
            Wire.ChatMessage(beamId: 1, content: .user(text: "hello")),
            Wire.ChatMessage(beamId: 2, content: .assistant(text: "hi"))
        ]))

        #expect(gui.agentChatState.messages.map(\.id) == [1, 2])
        #expect(gui.agentChatState.transcriptEpoch == 3)
    }

    @Test("guiAgentChat hidden clears agentChatState")
    @MainActor func guiAgentChatHidden() throws {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.applyForTesting(.guiAgentChat(visible: false, status: 0, model: "",
                                           thinkingLevel: "", prompt: "", promptLineCount: 1,
                                           promptCursorLine: 0, promptCursorCol: 0,
                                           promptVimMode: 0, promptVisibleRows: 1,
                                           promptCompletion: nil, pendingToolName: nil,
                                           pendingToolSummary: "", helpVisible: false, helpGroups: []))

        #expect(gui.agentChatState.visible == false)
        #expect(gui.agentChatState.messages.isEmpty)
    }

    @Test("guiBottomPanel visible updates bottomPanelState and appends entries")
    @MainActor func guiBottomPanelVisible() throws {
        let (dispatcher, gui) = makeDispatcher()
        let tabs = [Wire.BottomPanelTab(tabType: 0, name: "Messages")]
        let entries = [Wire.MessageEntry(streamInstance: 1, id: 1, level: 1, subsystem: 0,
                                       timestampSecs: 3600, filePath: "", text: "test")]
        dispatcher.applyForTesting(.guiBottomPanel(visible: true, activeTabIndex: 0,
                                             heightPercent: 30, filterPreset: 0,
                                             tabs: tabs, entries: entries))

        #expect(gui.bottomPanelState.visible == true)
        #expect(gui.bottomPanelState.tabs.count == 1)
        #expect(gui.bottomPanelState.messagesState.entries.count == 1)
    }

    @Test("guiBottomPanel hidden hides bottomPanelState")
    @MainActor func guiBottomPanelHidden() throws {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.applyForTesting(.guiBottomPanel(visible: false, activeTabIndex: 0,
                                             heightPercent: 30, filterPreset: 0,
                                             tabs: [], entries: []))
        #expect(gui.bottomPanelState.visible == false)
    }


    @Test("guiWindowContent stores content in guiState")
    @MainActor func guiWindowContentRouting() throws {
        let (dispatcher, gui) = makeDispatcher()
        let content = try GUIWindowContent(
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

    @Test("reset-required scroll presentation clears local smooth-scroll state once per promoted frame")
    @MainActor func resetRequiredScrollPresentationClearsLocalStateOnce() throws {
        let (dispatcher, gui) = makeDispatcher()
        var resetCount = 0
        dispatcher.onScrollPresentationReset = { resetCount += 1 }

        let resetPresentation = GUIScrollPresentation(
            windowId: 7,
            resetRequired: true,
            anchorTop: 5,
            anchorLeft: 2,
            anchorVisualRowOffset: 0,
            visibleStartLine: 5,
            visibleEndLine: 8,
            overscanStartLine: 4,
            overscanEndLine: 9,
            contentEpoch: 42,
            layoutGeneration: 77
        )

        dispatcher.applyForTesting(.guiWindowContent(data: try GUIWindowContent(
            windowId: 7, fullRefresh: true, contentEpoch: 42,
            cursorRow: 5, cursorCol: 10, cursorShape: .beam,
            rows: [], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: [],
            scrollPresentation: resetPresentation
        )))
        #expect(resetCount == 1)

        dispatcher.applyForTesting(.guiWindowOverlayDelta(data: GUIWindowOverlayDelta(
            windowId: 7, contentEpoch: 42,
            cursorVisible: true, cursorRow: 5, cursorCol: 10,
            cursorShape: .beam, cursorline: nil
        )))
        #expect(resetCount == 1)

        gui.windowContents[7] = try GUIWindowContent(
            windowId: 7, fullRefresh: false, contentEpoch: 42,
            cursorRow: 5, cursorCol: 10, cursorShape: .beam,
            rows: [], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: []
        )

        dispatcher.applyForTesting(.guiWindowRowsDelta(data: GUIWindowRowsDelta(
            windowId: 7,
            contentEpoch: 42,
            cursorVisible: true,
            cursorRow: 5,
            cursorCol: 10,
            cursorShape: .beam,
            scrollLeft: 0,
            rows: [],
            selection: nil,
            searchMatches: [],
            diagnosticUnderlines: [],
            documentHighlights: [],
            lineAnnotations: [],
            paneGeometry: nil,
            cursorline: nil,
            scrollPresentation: resetPresentation
        )))
        #expect(resetCount == 2)
    }

    @Test("layoutGeneration-only change fires scroll presentation discard")
    @MainActor func layoutGenerationChangeFiresDiscard() throws {
        let (dispatcher, _) = makeDispatcher()
        var discardCount = 0
        dispatcher.onScrollPresentationReset = { discardCount += 1 }

        let base = GUIScrollPresentation(
            windowId: 7, resetRequired: false,
            anchorTop: 10, anchorLeft: 0, anchorVisualRowOffset: 0,
            visibleStartLine: 10, visibleEndLine: 20,
            overscanStartLine: 5, overscanEndLine: 25,
            contentEpoch: 42, layoutGeneration: 1
        )

        dispatcher.applyForTesting(.guiWindowContent(data: try GUIWindowContent(
            windowId: 7, fullRefresh: true, contentEpoch: 42,
            cursorRow: 5, cursorCol: 10, cursorShape: .beam,
            rows: [], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: [],
            scrollPresentation: base
        )))
        #expect(discardCount == 0)

        let bumped = GUIScrollPresentation(
            windowId: 7, resetRequired: false,
            anchorTop: 10, anchorLeft: 0, anchorVisualRowOffset: 0,
            visibleStartLine: 10, visibleEndLine: 20,
            overscanStartLine: 5, overscanEndLine: 25,
            contentEpoch: 42, layoutGeneration: 2
        )

        dispatcher.applyForTesting(.guiWindowContent(data: try GUIWindowContent(
            windowId: 7, fullRefresh: true, contentEpoch: 42,
            cursorRow: 5, cursorCol: 10, cursorShape: .beam,
            rows: [], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: [],
            scrollPresentation: bumped
        )))
        #expect(discardCount == 1)
    }

    @Test("identical anchor key does not fire scroll presentation discard")
    @MainActor func identicalAnchorKeyDoesNotDiscard() throws {
        let (dispatcher, _) = makeDispatcher()
        var discardCount = 0
        dispatcher.onScrollPresentationReset = { discardCount += 1 }

        let presentation = GUIScrollPresentation(
            windowId: 7, resetRequired: false,
            anchorTop: 10, anchorLeft: 0, anchorVisualRowOffset: 0,
            visibleStartLine: 10, visibleEndLine: 20,
            overscanStartLine: 5, overscanEndLine: 25,
            contentEpoch: 42, layoutGeneration: 1
        )

        dispatcher.applyForTesting(.guiWindowContent(data: try GUIWindowContent(
            windowId: 7, fullRefresh: true, contentEpoch: 42,
            cursorRow: 5, cursorCol: 10, cursorShape: .beam,
            rows: [], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: [],
            scrollPresentation: presentation
        )))
        #expect(discardCount == 0)

        dispatcher.applyForTesting(.guiWindowContent(data: try GUIWindowContent(
            windowId: 7, fullRefresh: true, contentEpoch: 42,
            cursorRow: 6, cursorCol: 10, cursorShape: .beam,
            rows: [], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: [],
            scrollPresentation: presentation
        )))
        #expect(discardCount == 0)
    }

    @Test("identical anchor key with a newer scroll_seq still fires discard (#2661 race case)")
    @MainActor func newerScrollSeqDiscardsEvenWithSameAnchorKey() throws {
        let (dispatcher, _) = makeDispatcher()
        var discardCount = 0
        dispatcher.onScrollPresentationReset = { discardCount += 1 }

        let base = GUIScrollPresentation(
            windowId: 7, resetRequired: false,
            anchorTop: 10, anchorLeft: 0, anchorVisualRowOffset: 0,
            visibleStartLine: 10, visibleEndLine: 20,
            overscanStartLine: 5, overscanEndLine: 25,
            contentEpoch: 42, layoutGeneration: 1, scrollSeq: 3
        )

        dispatcher.applyForTesting(.guiWindowContent(data: try GUIWindowContent(
            windowId: 7, fullRefresh: true, contentEpoch: 42,
            cursorRow: 5, cursorCol: 10, cursorShape: .beam,
            rows: [], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: [],
            scrollPresentation: base
        )))
        #expect(discardCount == 0)

        // A BEAM-initiated jump (search, ctrl-d, zz) races a local scroll report
        // and coincidentally lands back on the exact same anchor key. Without
        // the scroll_seq check this would be indistinguishable from an echo of
        // the frontend's own report and would wrongly keep the stale local offset.
        let coincidentallySameAnchor = GUIScrollPresentation(
            windowId: 7, resetRequired: false,
            anchorTop: 10, anchorLeft: 0, anchorVisualRowOffset: 0,
            visibleStartLine: 10, visibleEndLine: 20,
            overscanStartLine: 5, overscanEndLine: 25,
            contentEpoch: 42, layoutGeneration: 1, scrollSeq: 4
        )

        dispatcher.applyForTesting(.guiWindowContent(data: try GUIWindowContent(
            windowId: 7, fullRefresh: true, contentEpoch: 42,
            cursorRow: 5, cursorCol: 10, cursorShape: .beam,
            rows: [], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: [],
            scrollPresentation: coincidentallySameAnchor
        )))
        #expect(discardCount == 1)
    }

    @Test("an unchanged or lower scroll_seq with the same anchor key does not discard")
    @MainActor func unchangedScrollSeqDoesNotDiscard() throws {
        let (dispatcher, _) = makeDispatcher()
        var discardCount = 0
        dispatcher.onScrollPresentationReset = { discardCount += 1 }

        let base = GUIScrollPresentation(
            windowId: 7, resetRequired: false,
            anchorTop: 10, anchorLeft: 0, anchorVisualRowOffset: 0,
            visibleStartLine: 10, visibleEndLine: 20,
            overscanStartLine: 5, overscanEndLine: 25,
            contentEpoch: 42, layoutGeneration: 1, scrollSeq: 5
        )

        dispatcher.applyForTesting(.guiWindowContent(data: try GUIWindowContent(
            windowId: 7, fullRefresh: true, contentEpoch: 42,
            cursorRow: 5, cursorCol: 10, cursorShape: .beam,
            rows: [], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: [],
            scrollPresentation: base
        )))
        #expect(discardCount == 0)

        // Same scroll_seq: this is the routine echo-loop case (#2661) — the
        // wheel report kept the cursor inside scrolloff, so the BEAM committed
        // the same anchor and did not advance the authority sequence.
        dispatcher.applyForTesting(.guiWindowContent(data: try GUIWindowContent(
            windowId: 7, fullRefresh: true, contentEpoch: 42,
            cursorRow: 5, cursorCol: 10, cursorShape: .beam,
            rows: [], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: [],
            scrollPresentation: base
        )))
        #expect(discardCount == 0)
    }

    @Test("anchorTop-only change fires scroll presentation discard")
    @MainActor func anchorTopChangeFiresDiscard() throws {
        let (dispatcher, _) = makeDispatcher()
        var discardCount = 0
        dispatcher.onScrollPresentationReset = { discardCount += 1 }

        let base = GUIScrollPresentation(
            windowId: 7, resetRequired: false,
            anchorTop: 10, anchorLeft: 0, anchorVisualRowOffset: 0,
            visibleStartLine: 10, visibleEndLine: 20,
            overscanStartLine: 5, overscanEndLine: 25,
            contentEpoch: 42, layoutGeneration: 1
        )

        dispatcher.applyForTesting(.guiWindowContent(data: try GUIWindowContent(
            windowId: 7, fullRefresh: true, contentEpoch: 42,
            cursorRow: 5, cursorCol: 10, cursorShape: .beam,
            rows: [], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: [],
            scrollPresentation: base
        )))
        #expect(discardCount == 0)

        let shifted = GUIScrollPresentation(
            windowId: 7, resetRequired: false,
            anchorTop: 15, anchorLeft: 0, anchorVisualRowOffset: 0,
            visibleStartLine: 15, visibleEndLine: 25,
            overscanStartLine: 10, overscanEndLine: 30,
            contentEpoch: 42, layoutGeneration: 1
        )

        dispatcher.applyForTesting(.guiWindowContent(data: try GUIWindowContent(
            windowId: 7, fullRefresh: true, contentEpoch: 42,
            cursorRow: 5, cursorCol: 10, cursorShape: .beam,
            rows: [], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: [],
            scrollPresentation: shifted
        )))
        #expect(discardCount == 1)
    }

    @Test("guiWindowOverlayDelta updates matching retained content")
    @MainActor func guiWindowOverlayDeltaRouting() throws {
        let (dispatcher, gui) = makeDispatcher()
        gui.windowContents[7] = try GUIWindowContent(
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
        #expect(gui.windowContents[7] != nil)
        #expect(dispatcher.frameState.cursorVisible == false)
    }

    @Test("guiWindowOverlayDelta clears retained cursorline when cursorline is omitted")
    @MainActor func guiWindowOverlayDeltaClearsRetainedCursorline() throws {
        let (dispatcher, gui) = makeDispatcher()
        gui.windowContents[7] = try GUIWindowContent(
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
        #expect(gui.windowContents[7] != nil)
    }

    @Test("stale guiWindowOverlayDelta is ignored without marking the window live")
    @MainActor func staleGuiWindowOverlayDeltaIgnored() throws {
        let (dispatcher, gui) = makeDispatcher()
        let content = try GUIWindowContent(
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
        #expect(dispatcher.frameState.cursorVisible == true)
    }

    @Test("guiWindowOverlayDelta without retained content is ignored")
    @MainActor func missingGuiWindowOverlayDeltaIgnored() throws {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.frameState.cursorVisible = true

        dispatcher.applyForTesting(.guiWindowOverlayDelta(data: GUIWindowOverlayDelta(
            windowId: 7, contentEpoch: 42, cursorVisible: false,
            cursorRow: 6, cursorCol: 11, cursorShape: .beam,
            cursorline: nil
        )))

        #expect(gui.windowContents[7] == nil)
        #expect(dispatcher.frameState.cursorVisible == true)
    }

    @Test("guiWindowRowsDelta updates retained rows and marks window live")
    @MainActor func guiWindowRowsDeltaRouting() throws {
        let (dispatcher, gui) = makeDispatcher()
        let retained = GUIVisualRow(rowType: .normal, rowId: 1, bufLine: 0, contentHash: 11, text: "old", spans: [])
        let replacement = GUIVisualRow(rowType: .normal, rowId: 2, bufLine: 1, contentHash: 22, text: "new", spans: [])
        gui.windowContents[7] = try GUIWindowContent(
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
        #expect(gui.windowContents[7] != nil)
    }

    @Test("guiWindowViewportDelta updates retained rows and marks window live")
    @MainActor func guiWindowViewportDeltaRouting() throws {
        let (dispatcher, gui) = makeDispatcher()
        let retained = GUIVisualRow(rowType: .normal, rowId: 1, bufLine: 0, contentHash: 11, text: "old", spans: [])
        gui.windowContents[7] = try GUIWindowContent(
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
        #expect(gui.windowContents[7] != nil)
    }

    @Test("stale guiWindowRowsDelta is ignored without clearing current content")
    @MainActor func staleGuiWindowRowsDeltaIgnored() throws {
        let (dispatcher, gui) = makeDispatcher()
        let retained = GUIVisualRow(rowType: .normal, rowId: 1, bufLine: 0, contentHash: 11, text: "old", spans: [])
        let content = try GUIWindowContent(
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
    }

    @Test("guiWindowRowsDelta missing retained ref clears content for full-refresh recovery")
    @MainActor func guiWindowRowsDeltaMissingRefClearsContent() throws {
        let (dispatcher, gui) = makeDispatcher()
        let retained = GUIVisualRow(rowType: .normal, rowId: 1, bufLine: 0, contentHash: 11, text: "old", spans: [])
        gui.windowContents[7] = try GUIWindowContent(
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
    }

    @Test("guiGutterSeparator updates frameState gutter state")
    @MainActor func guiGutterSepRouting() throws {
        let (dispatcher, _) = makeDispatcher()
        dispatcher.applyForTesting(.guiGutterSeparator(col: 4, r: 0x3F, g: 0x44, b: 0x4A))

        #expect(dispatcher.frameState.gutterCol == 4)
        let expected: UInt32 = (0x3F << 16) | (0x44 << 8) | 0x4A
        #expect(dispatcher.frameState.gutterSeparatorColor == expected)
    }

    @Test("guiCursorline updates frameState cursorline state")
    @MainActor func guiCursorlineRouting() throws {
        let (dispatcher, _) = makeDispatcher()
        dispatcher.applyForTesting(.guiCursorline(row: 12, r: 0x2C, g: 0x32, b: 0x3C))

        #expect(dispatcher.frameState.cursorlineRow == 12)
        let expected: UInt32 = (0x2C << 16) | (0x32 << 8) | 0x3C
        #expect(dispatcher.frameState.cursorlineBg == expected)
    }

    @Test("guiGutter stores gutter data in frameState")
    @MainActor func guiGutterRouting() throws {
        let (dispatcher, _) = makeDispatcher()
        let gutter = Wire.WindowGutter(
            windowId: 1, contentRow: 0, contentCol: 5, contentHeight: 24,
            isActive: true, contentWidth: 80, cursorLine: 10, lineNumberStyle: .hybrid,
            lineNumberWidth: 4, signColWidth: 1, entries: []
        )
        dispatcher.applyForTesting(.guiGutter(data: gutter))

        #expect(dispatcher.frameState.windowGutters[1] != nil)
        #expect(dispatcher.frameState.windowGutters[1] != nil)
        // Active window gutter syncs gutterCol
        #expect(dispatcher.frameState.gutterCol == 5) // 4 + 1
    }

    @Test("guiHoverPopup exposes lines after scroll offset")
    @MainActor func guiHoverPopupScrollOffset() throws {
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
    @MainActor func commitFrameFiresFirstRenderOnce() throws {
        let (dispatcher, _) = makeDispatcher()
        var callCount = 0
        dispatcher.onFirstRender = { callCount += 1 }

        // Two well-formed keyframe transactions; onFirstRender fires only once.
        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))
        #expect(callCount == 1)
        #expect(dispatcher.onFirstRender == nil)

        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.commitFrame(frameSeq: 2, seq: 0))
        #expect(callCount == 1)
    }

    // MARK: - Theme

    @Test("guiTheme updates themeColors and syncs to frameState")
    @MainActor func guiThemeRouting() throws {
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

    @Test("staged theme colors are frozen into the committed editor snapshot")
    @MainActor func stagedThemeColorsFreezeIntoCommittedEditorSnapshot() throws {
        let (dispatcher, _) = makeDispatcher()
        let expected: UInt32 = (0x12 << 16) | (0x34 << 8) | 0x56
        let slots = completeThemeSlots().map { slot, r, g, b in
            slot == GUI_COLOR_GUTTER_FG ? (slot, 0x12, 0x34, 0x56) : (slot, r, g, b)
        }
        let geometry = editorGeometry(windowId: 1, lineNumberWidth: 4, signColWidth: 3)

        dispatcher.dispatch(.beginFrame(frameSeq: 4, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: slots))
        dispatcher.dispatch(.guiWindowContent(data: try editorContent(windowId: 1, geometry: geometry)))
        dispatcher.dispatch(.guiGutter(data: editorGutter(windowId: 1, geometry: geometry)))
        dispatcher.dispatch(.guiIndentGuides(data: IndentGuideData(
            windowId: 1, tabWidth: 4, activeGuideCol: 0xFFFF,
            guideCols: [], lineIndentLevels: []
        )))
        dispatcher.dispatch(.commitFrame(frameSeq: 4, seq: 0))

        #expect(dispatcher.committedEditorSnapshot?.frameState.gutterColors.fg == expected)
        #expect(dispatcher.frameState.gutterColors.fg == expected)
    }

    @Test("keyframe with content but no guiTheme returns a typed rejection")
    @MainActor func keyframeWithoutThemeErrors() throws {
        let (dispatcher, gui) = makeDispatcher()
        var results: [FrameTransactionResult] = []
        dispatcher.onTransactionResult = { results.append($0) }

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [Wire.TabEntry(id: 1, groupId: 0, isActive: true, isDirty: false, isAgent: false, hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "", label: "unthemed.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))

        #expect(gui.protocolErrorState.isPresented == false)
        #expect(gui.tabBarState.tabs.isEmpty)
        #expect(results == [.rejected(generation: 1, frameSeq: 1, lastAppliedFrameSeq: 0, reason: .missingTheme)])
    }

    @Test("keyframe with empty guiTheme rejects promotion")
    @MainActor func keyframeWithEmptyThemeErrors() throws {
        let (dispatcher, gui) = makeDispatcher()
        var results: [FrameTransactionResult] = []
        dispatcher.onTransactionResult = { results.append($0) }

        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: []))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [Wire.TabEntry(id: 1, groupId: 0, isActive: true, isDirty: false, isAgent: false, hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "", label: "empty.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 2, seq: 0))

        #expect(gui.protocolErrorState.isPresented == false)
        #expect(gui.themeColors.hasAppliedTheme == false)
        #expect(gui.tabBarState.tabs.isEmpty)
        guard case .rejected(generation: 1, frameSeq: 2, lastAppliedFrameSeq: _, reason: .incompleteTheme(let missing)) = results.first else {
            Issue.record("expected incomplete-theme rejection")
            return
        }
        #expect(missing.contains(0x01))
    }

    @Test("keyframe with partial guiTheme rejects promotion")
    @MainActor func keyframeWithPartialThemeErrors() throws {
        let (dispatcher, gui) = makeDispatcher()
        var results: [FrameTransactionResult] = []
        dispatcher.onTransactionResult = { results.append($0) }

        dispatcher.dispatch(.beginFrame(frameSeq: 3, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: [(GUI_COLOR_EDITOR_BG, 0x00, 0x00, 0x00)]))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [Wire.TabEntry(id: 1, groupId: 0, isActive: true, isDirty: false, isAgent: false, hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "", label: "partial.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 3, seq: 0))

        #expect(gui.protocolErrorState.isPresented == false)
        #expect(gui.themeColors.hasAppliedTheme == false)
        #expect(gui.tabBarState.tabs.isEmpty)
        guard case .rejected(generation: 1, frameSeq: 3, lastAppliedFrameSeq: _, reason: .incompleteTheme(let missing)) = results.first else {
            Issue.record("expected incomplete-theme rejection")
            return
        }
        #expect(missing.contains(0x02))
        #expect(missing.contains(0xA0))
    }
}

/// AC tests for frame-transaction staging and commit (#2219 child D).
///
/// Mirrors the epic headline in Swift: observable state is unchanged between
/// begin and commit, commit promotes atomically, invalidation requests a
/// keyframe with no partial promotion, and out-of-band commands apply without a
/// transaction.
fileprivate func editorGeometry(windowId: UInt16 = 1, lineNumberWidth: UInt16 = 4, signColWidth: UInt16 = 1) -> GUIPaneGeometry {
    GUIPaneGeometry(
        windowId: windowId,
        totalRect: GUICellRect(row: 0, col: 0, width: 80, height: 24),
        contentRect: GUICellRect(row: 0, col: 0, width: 80, height: 24),
        textRect: GUICellRect(row: 0, col: UInt16(lineNumberWidth + signColWidth), width: UInt16(80 - lineNumberWidth - signColWidth), height: 24),
        gutterRect: GUICellRect(row: 0, col: 0, width: UInt16(lineNumberWidth + signColWidth), height: 24),
        clipRect: GUICellRect(row: 0, col: 0, width: 80, height: 24),
        viewport: GUIViewportSummary(top: 0, left: 0, rows: 24, cols: 80, totalLines: 24, visualRowOffset: 0, totalVisualRows: 24),
        gutterMetrics: GUIGutterMetrics(lineNumberWidth: lineNumberWidth, signColWidth: signColWidth),
        hitRegions: lineNumberWidth + signColWidth == 0 ? [] : [GUIHitRegion(kind: .gutter, rect: GUICellRect(row: 0, col: 0, width: UInt16(lineNumberWidth + signColWidth), height: 24), windowId: windowId)]
    )
}

fileprivate func editorContent(windowId: UInt16 = 1, geometry: GUIPaneGeometry? = editorGeometry()) throws -> GUIWindowContent {
    try GUIWindowContent(
        windowId: windowId, fullRefresh: true,
        cursorRow: 0, cursorCol: 0, cursorShape: .block,
        rows: [], selection: nil,
        searchMatches: [], diagnosticUnderlines: [],
        documentHighlights: [], paneGeometry: geometry
    )
}

fileprivate func editorGutter(windowId: UInt16 = 1, geometry: GUIPaneGeometry = editorGeometry()) -> Wire.WindowGutter {
    Wire.WindowGutter(
        windowId: windowId, contentRow: geometry.textRect.row, contentCol: geometry.textRect.col, contentHeight: geometry.textRect.height,
        isActive: true, contentWidth: geometry.textRect.width, cursorLine: 0, lineNumberStyle: .hybrid,
        lineNumberWidth: UInt8(geometry.gutterMetrics.lineNumberWidth), signColWidth: UInt8(geometry.gutterMetrics.signColWidth), entries: []
    )
}

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

    private func windowContent(
        windowId: UInt16 = 7,
        epoch: UInt32 = 42,
        fontId: UInt8 = 0,
        scrollPresentation: GUIScrollPresentation? = nil
    ) throws -> GUIWindowContent {
        let span = GUIHighlightSpan(
            startCol: 0, endCol: 3, fg: 0xFFFFFF, bg: 0,
            attrs: 0, fontWeight: 0, fontId: fontId
        )
        let row = GUIVisualRow(
            rowType: .normal, rowId: 1, bufLine: 0,
            contentHash: 11, text: "old", spans: [span]
        )
        return try GUIWindowContent(
            windowId: windowId, fullRefresh: true, contentEpoch: epoch,
            cursorRow: 0, cursorCol: 0, cursorShape: .block,
            rows: [row], selection: nil, searchMatches: [],
            diagnosticUnderlines: [], documentHighlights: [],
            paneGeometry: editorGeometry(windowId: windowId, lineNumberWidth: 0, signColWidth: 0),
            scrollPresentation: scrollPresentation
        )
    }

    private func status(mode: UInt8 = 1) -> StatusBarUpdate {
        StatusBarUpdate(
            contentKind: 0, mode: mode, cursorLine: 4, cursorCol: 2,
            lineCount: 12, flags: 0, lspStatus: 0, gitBranch: "",
            message: "committed", filetype: "swift", errorCount: 0,
            warningCount: 0, modelName: "", messageCount: 0,
            sessionStatus: 0, infoCount: 0, hintCount: 0,
            macroRecording: 0, parserStatus: 0, agentStatus: 0,
            gitAdded: 0, gitModified: 0, gitDeleted: 0, icon: "",
            iconColorR: 0, iconColorG: 0, iconColorB: 0,
            filename: "Commit.swift", diagnosticHint: "",
            backgroundSubagentCount: 0, backgroundSubagentLabel: ""
        )
    }

    private func overlayDelta(windowId: UInt16 = 7, epoch: UInt32 = 42) -> GUIWindowOverlayDelta {
        GUIWindowOverlayDelta(
            windowId: windowId, contentEpoch: epoch, cursorVisible: true,
            cursorRow: 0, cursorCol: 1, cursorShape: .beam, cursorline: nil
        )
    }

    private func policy(stagingWeight: FrameResourceWeight) -> FrameResourcePolicy {
        let defaults = FrameResourcePolicy.default
        return FrameResourcePolicy(
            wire: defaults.wire, decode: defaults.decode,
            staging: .init(weight: stagingWeight), resident: defaults.resident
        )
    }

    @Test("committed editor snapshot contains complete surfaces after freeze")
    @MainActor func committedEditorSnapshotContainsCompleteSurfaces() throws {
        let (dispatcher, _) = makeDispatcher()
        let geometry = editorGeometry()

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiWindowContent(data: try editorContent(geometry: geometry)))
        dispatcher.dispatch(.guiGutter(data: editorGutter(geometry: geometry)))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))

        let snapshot = try #require(dispatcher.committedEditorSnapshot)
        #expect(snapshot.frameSeq == 1)
        #expect(snapshot.surfaces.count == 1)
        #expect(snapshot.windowContents[1] != nil)
        #expect(snapshot.windowGutters[1] != nil)
        #expect(snapshot.surfaces.first?.paneGeometry == geometry)
    }

    @Test("freeze rejects content that requires a missing gutter")
    @MainActor func freezeRejectsMissingRequiredGutter() throws {
        let (dispatcher, gui) = makeDispatcher()
        var results: [FrameTransactionResult] = []
        dispatcher.onTransactionResult = { results.append($0) }
        let geometry = editorGeometry()

        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiWindowContent(data: try editorContent(geometry: geometry)))
        dispatcher.dispatch(.commitFrame(frameSeq: 2, seq: 0))

        #expect(gui.windowContents.isEmpty)
        #expect(dispatcher.committedEditorSnapshot == nil)
        guard case .rejected(generation: 1, frameSeq: 2, lastAppliedFrameSeq: 0, reason: .missingWindowGutter(windowId: 1)) = results.first else {
            Issue.record("expected missing gutter rejection")
            return
        }
    }

    @Test("freeze accepts explicitly gutterless zero-width geometry")
    @MainActor func freezeAcceptsExplicitGutterlessGeometry() throws {
        let (dispatcher, _) = makeDispatcher()
        let geometry = editorGeometry(lineNumberWidth: 0, signColWidth: 0)

        dispatcher.dispatch(.beginFrame(frameSeq: 3, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiWindowContent(data: try editorContent(geometry: geometry)))
        dispatcher.dispatch(.commitFrame(frameSeq: 3, seq: 0))

        let snapshot = try #require(dispatcher.committedEditorSnapshot)
        #expect(snapshot.windowGutters.isEmpty)
        guard case .none = try #require(snapshot.surfaces.first).gutter else {
            Issue.record("expected explicit gutterless surface")
            return
        }
    }

    @Test("freeze rejects gutter widths that differ from pane geometry")
    @MainActor func freezeRejectsIncompatibleGutterWidths() throws {
        let (dispatcher, gui) = makeDispatcher()
        var results: [FrameTransactionResult] = []
        dispatcher.onTransactionResult = { results.append($0) }
        let geometry = editorGeometry(lineNumberWidth: 4, signColWidth: 1)
        let gutter = Wire.WindowGutter(
            windowId: 1, contentRow: geometry.textRect.row, contentCol: geometry.textRect.col, contentHeight: geometry.textRect.height,
            isActive: true, contentWidth: geometry.textRect.width + 1, cursorLine: 0, lineNumberStyle: .hybrid,
            lineNumberWidth: 3, signColWidth: UInt8(geometry.gutterMetrics.signColWidth), entries: []
        )

        dispatcher.dispatch(.beginFrame(frameSeq: 4, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiWindowContent(data: try editorContent(geometry: geometry)))
        dispatcher.dispatch(.guiGutter(data: gutter))
        dispatcher.dispatch(.commitFrame(frameSeq: 4, seq: 0))

        #expect(gui.windowContents.isEmpty)
        #expect(dispatcher.committedEditorSnapshot == nil)
        guard case .rejected(generation: 1, frameSeq: 4, lastAppliedFrameSeq: 0, reason: .incompatibleWindowGeometry(windowId: 1)) = results.first else {
            Issue.record("expected incompatible geometry rejection")
            return
        }
    }

    @Test("freeze rejects multiple active gutter owners before publication")
    @MainActor func freezeRejectsMultipleActiveGutters() throws {
        let (dispatcher, gui) = makeDispatcher()
        var results: [FrameTransactionResult] = []
        dispatcher.onTransactionResult = { results.append($0) }
        let firstGeometry = editorGeometry(windowId: 1)
        let secondGeometry = editorGeometry(windowId: 2)

        dispatcher.dispatch(.beginFrame(frameSeq: 5, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiWindowContent(data: try editorContent(windowId: 1, geometry: firstGeometry)))
        dispatcher.dispatch(.guiWindowContent(data: try editorContent(windowId: 2, geometry: secondGeometry)))
        dispatcher.dispatch(.guiGutter(data: editorGutter(windowId: 1, geometry: firstGeometry)))
        dispatcher.dispatch(.guiGutter(data: editorGutter(windowId: 2, geometry: secondGeometry)))
        dispatcher.dispatch(.commitFrame(frameSeq: 5, seq: 0))

        #expect(gui.windowContents.isEmpty)
        #expect(dispatcher.committedEditorSnapshot == nil)
        guard case .rejected(generation: 1, frameSeq: 5, lastAppliedFrameSeq: 0, reason: .invalidActiveWindow(windowId: 2)) = results.first else {
            Issue.record("expected multiple-active-window rejection")
            return
        }
    }

    @Test("visible editor snapshot advances only after matching presentation")
    @MainActor func visibleSnapshotAdvancesOnlyAfterMatchingPresentation() throws {
        let (dispatcher, _) = makeDispatcher()
        let geometry = editorGeometry(lineNumberWidth: 0, signColWidth: 0)

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiWindowContent(data: try editorContent(geometry: geometry)))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))
        let firstSnapshot = try #require(dispatcher.committedEditorSnapshot)
        #expect(dispatcher.visibleEditorSnapshot == nil)
        #expect(dispatcher.pendingPresentationFrame() == GUICommittedFrame(generation: 1, frameSeq: 1))

        dispatcher.promoteVisibleEditorSnapshot(firstSnapshot)
        #expect(dispatcher.visibleEditorSnapshot?.frameSeq == 1)
        #expect(dispatcher.pendingPresentationFrame() == nil)

        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 1, generation: 1))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("shell-only")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 2, seq: 0))
        #expect(dispatcher.committedEditorSnapshot?.frameSeq == 1)
        #expect(dispatcher.visibleEditorSnapshot?.frameSeq == 1)
        #expect(dispatcher.pendingPresentationFrame() == nil)

        dispatcher.dispatch(.beginFrame(frameSeq: 3, baseFrameSeq: 2, generation: 1))
        dispatcher.dispatch(.guiWindowContent(data: try editorContent(geometry: geometry)))
        dispatcher.dispatch(.commitFrame(frameSeq: 3, seq: 0))
        let thirdSnapshot = try #require(dispatcher.committedEditorSnapshot)
        #expect(thirdSnapshot.frameSeq == 3)
        #expect(dispatcher.visibleEditorSnapshot?.frameSeq == 1)
        #expect(dispatcher.pendingPresentationFrame() == GUICommittedFrame(generation: 1, frameSeq: 3))

        dispatcher.promoteVisibleEditorSnapshot(firstSnapshot)
        #expect(dispatcher.visibleEditorSnapshot?.frameSeq == 1)
        #expect(dispatcher.pendingPresentationFrame() == GUICommittedFrame(generation: 1, frameSeq: 3))

        dispatcher.promoteVisibleEditorSnapshot(thirdSnapshot)
        #expect(dispatcher.visibleEditorSnapshot?.frameSeq == 3)
        #expect(dispatcher.pendingPresentationFrame() == nil)
    }

    @Test("older in-flight presentation promotes when a newer commit is pending")
    @MainActor func olderInFlightPresentationPromotesWhileNewerCommitIsPending() throws {
        let (dispatcher, _) = makeDispatcher()
        let geometry = editorGeometry(lineNumberWidth: 0, signColWidth: 0)

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiWindowContent(data: try editorContent(geometry: geometry)))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))
        let visibleBase = try #require(dispatcher.committedEditorSnapshot)
        dispatcher.promoteVisibleEditorSnapshot(visibleBase)

        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 1, generation: 1))
        dispatcher.dispatch(.guiWindowContent(data: try editorContent(geometry: geometry)))
        dispatcher.dispatch(.commitFrame(frameSeq: 2, seq: 0))
        let inFlightA = try #require(dispatcher.committedEditorSnapshot)

        dispatcher.dispatch(.beginFrame(frameSeq: 3, baseFrameSeq: 2, generation: 1))
        dispatcher.dispatch(.guiWindowContent(data: try editorContent(geometry: geometry)))
        dispatcher.dispatch(.commitFrame(frameSeq: 3, seq: 0))
        let inFlightB = try #require(dispatcher.committedEditorSnapshot)
        let inFlightBFrame = GUICommittedFrame(generation: inFlightB.generation, frameSeq: inFlightB.frameSeq)
        #expect(dispatcher.pendingPresentationFrame() == inFlightBFrame)

        dispatcher.promoteVisibleEditorSnapshot(inFlightA)
        #expect(dispatcher.visibleEditorSnapshot?.frameSeq == 2)
        #expect(dispatcher.pendingPresentationFrame() == inFlightBFrame)
    }

    @Test("visible presentation retains captured local transform")
    @MainActor func visiblePresentationRetainsCapturedLocalTransform() throws {
        let (dispatcher, _) = makeDispatcher()
        let geometry = editorGeometry(lineNumberWidth: 0, signColWidth: 0)
        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiWindowContent(data: try editorContent(geometry: geometry)))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))
        let snapshot = try #require(dispatcher.committedEditorSnapshot)
        let transform = EditorLocalPresentationTransform(windowId: 1, offset: CGPoint(x: 7, y: 11))

        dispatcher.promoteVisibleEditorPresentation(snapshot: snapshot, localTransform: transform)

        #expect(dispatcher.visibleEditorPresentation?.snapshot.frameSeq == 1)
        #expect(dispatcher.visibleEditorPresentation?.localTransform == transform)
    }

    // MARK: - Nothing paints between begin and commit

    @Test("observable GUIState is unchanged between begin and a partial frame")
    @MainActor func guiStateUnchangedMidTransaction() throws {
        let (dispatcher, gui) = makeDispatcher()

        // Establish a committed baseline so we have a "presented" tab bar.
        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("old.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))
        #expect(gui.tabBarState.tabs.first?.label == "old.ex")

        // Open a new transaction and stage a different tab bar, but do NOT commit.
        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 1, generation: 1))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("new.ex")]))

        // The presented state still shows the last committed frame.
        #expect(gui.tabBarState.tabs.first?.label == "old.ex")
    }

    @Test("observable FrameState is unchanged between begin and a partial frame")
    @MainActor func frameStateUnchangedMidTransaction() throws {
        let (dispatcher, _) = makeDispatcher()

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.setCursorShape(.block))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))
        #expect(dispatcher.frameState.cursorShape == .block)

        // Stage a shape change without committing; the presented shape holds.
        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 1, generation: 1))
        dispatcher.dispatch(.setCursorShape(.beam))
        #expect(dispatcher.frameState.cursorShape == .block)
    }

    // MARK: - Commit promotes atomically

    @Test("commit promotes all staged commands in one batch")
    @MainActor func commitPromotesStagedCommands() throws {
        let (dispatcher, gui) = makeDispatcher()

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
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
    @MainActor func frameReadyFiresAtCommit() throws {
        let (dispatcher, _) = makeDispatcher()
        var readyCount = 0
        dispatcher.onFrameReady = { readyCount += 1 }

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("a.ex")]))
        #expect(readyCount == 0)

        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))
        #expect(readyCount == 1)
    }

    // MARK: - Delta-base validation

    @Test("delta frame committing against the last committed seq promotes cleanly")
    @MainActor func deltaBaseMatchesCommits() throws {
        let (dispatcher, gui) = makeDispatcher()

        dispatcher.dispatch(.beginFrame(frameSeq: 5, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("base.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 5, seq: 0))

        // Next frame is a delta whose base names the frame we just committed.
        dispatcher.dispatch(.beginFrame(frameSeq: 6, baseFrameSeq: 5, generation: 1))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("delta.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 6, seq: 0))

        #expect(gui.tabBarState.tabs.first?.label == "delta.ex")
        #expect(dispatcher.lastCommittedFrameSeq == 6)
    }

    @Test("delta frame with empty guiTheme rejects promotion")
    @MainActor func deltaFrameWithEmptyThemeErrors() throws {
        let (dispatcher, gui) = makeDispatcher()
        var results: [FrameTransactionResult] = []
        dispatcher.onTransactionResult = { results.append($0) }

        dispatcher.dispatch(.beginFrame(frameSeq: 5, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("base.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 5, seq: 0))
        let baselineThemeBg = gui.themeColors.editorBg

        dispatcher.dispatch(.beginFrame(frameSeq: 6, baseFrameSeq: 5, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: []))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("empty-delta.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 6, seq: 0))

        #expect(gui.protocolErrorState.isPresented == false)
        #expect(gui.themeColors.editorBg == baselineThemeBg)
        #expect(gui.tabBarState.tabs.first?.label == "base.ex")
        #expect(results.count == 2)
        guard case .rejected(generation: 1, frameSeq: 6, lastAppliedFrameSeq: _, reason: .incompleteTheme(let missing)) = results.last else {
            Issue.record("expected incomplete-theme rejection")
            return
        }
        #expect(missing.contains(0x01))
        #expect(missing.contains(0xA0))
    }

    @Test("delta frame with partial guiTheme rejects promotion")
    @MainActor func deltaFrameWithPartialThemeErrors() throws {
        let (dispatcher, gui) = makeDispatcher()
        var results: [FrameTransactionResult] = []
        dispatcher.onTransactionResult = { results.append($0) }

        dispatcher.dispatch(.beginFrame(frameSeq: 5, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("base.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 5, seq: 0))
        let baselineThemeBg = gui.themeColors.editorBg

        dispatcher.dispatch(.beginFrame(frameSeq: 6, baseFrameSeq: 5, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: [(GUI_COLOR_EDITOR_BG, 0x00, 0x00, 0x00)]))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("partial-delta.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 6, seq: 0))

        #expect(gui.protocolErrorState.isPresented == false)
        #expect(gui.themeColors.editorBg == baselineThemeBg)
        #expect(gui.tabBarState.tabs.first?.label == "base.ex")
        #expect(results.count == 2)
        guard case .rejected(generation: 1, frameSeq: 6, lastAppliedFrameSeq: _, reason: .incompleteTheme(let missing)) = results.last else {
            Issue.record("expected incomplete-theme rejection")
            return
        }
        #expect(missing.contains(0x02))
        #expect(missing.contains(0xA0))
    }

    // MARK: - Invalidation requests a keyframe with no partial promotion

    @Test("commit seq mismatch invalidates with no promotion and requests keyframe")
    @MainActor func seqMismatchInvalidates() throws {
        let (dispatcher, gui) = makeDispatcher()
        var requested: [UInt32] = []
        dispatcher.onRequestKeyframe = { requested.append($0) }

        // Commit a clean baseline so lastCommittedFrameSeq is known.
        dispatcher.dispatch(.beginFrame(frameSeq: 3, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("good.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 3, seq: 0))

        // Open a frame, stage a change, then commit with the WRONG seq.
        dispatcher.dispatch(.beginFrame(frameSeq: 4, baseFrameSeq: 3, generation: 1))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("bad.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 99, seq: 0))

        // No partial promotion: the presented tab bar is still the good frame.
        #expect(gui.tabBarState.tabs.first?.label == "good.ex")
        // Keyframe requested carrying the last good frame_seq.
        #expect(requested == [3])
        // Resync hint raised.
        #expect(gui.resyncState.pending == true)
        #expect(gui.resyncState.lastGoodFrameSeq == 3)
        #expect(dispatcher.lastCommittedFrameSeq == 3)
    }

    @Test("pending resync debounces further keyframe requests until a valid commit")
    @MainActor func resyncDebouncesRequests() throws {
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
        dispatcher.dispatch(.beginFrame(frameSeq: 8, baseFrameSeq: 7, generation: 1))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("stale.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 8, seq: 0))
        #expect(requested == [0])

        // The keyframe arrives: pending clears and content promotes.
        dispatcher.dispatch(.beginFrame(frameSeq: 9, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("fresh.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 9, seq: 0))
        #expect(gui.resyncState.pending == false)
        #expect(gui.tabBarState.tabs.first?.label == "fresh.ex")
    }

    @Test("a stale delta commit does not clear a pending resync")
    @MainActor func staleDeltaDoesNotClearPendingResync() throws {
        let (dispatcher, gui) = makeDispatcher()
        var requested: [UInt32] = []
        dispatcher.onRequestKeyframe = { requested.append($0) }

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("rogue.ex")]))
        #expect(requested == [1])

        // This delta is valid against our retained baseline, but it is not the
        // requested base-0 recovery frame and must not dismiss the pending hint.
        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 1, generation: 1))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("stale.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 2, seq: 0))
        #expect(gui.resyncState.pending == true)

        dispatcher.dispatch(.beginFrame(frameSeq: 3, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.commitFrame(frameSeq: 3, seq: 0))
        #expect(gui.resyncState.pending == false)
    }

    @Test("invalidating a requested keyframe sends one replacement request")
    @MainActor func failedKeyframeRequestsReplacement() throws {
        let (dispatcher, gui) = makeDispatcher()
        var requested: [UInt32] = []
        dispatcher.onRequestKeyframe = { requested.append($0) }

        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))
        #expect(requested == [0])
        #expect(gui.resyncState.lastGoodFrameSeq == 0)

        // A base-0 frame has answered the request, but fails validation before it
        // can commit. It must reopen the request window instead of hanging forever.
        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: []))
        dispatcher.dispatch(.commitFrame(frameSeq: 2, seq: 0))
        #expect(requested == [0, 0])
        #expect(gui.resyncState.pending == true)

        dispatcher.dispatch(.beginFrame(frameSeq: 3, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.commitFrame(frameSeq: 3, seq: 0))
        #expect(gui.resyncState.pending == false)
    }

    @Test("double begin (truncation) invalidates the open frame and requests keyframe")
    @MainActor func doubleBeginTruncates() throws {
        let (dispatcher, gui) = makeDispatcher()
        var requested: [UInt32] = []
        dispatcher.onRequestKeyframe = { requested.append($0) }

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("staged.ex")]))
        // A new begin before commit: the first frame was truncated.
        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))

        // The truncated frame promoted nothing.
        #expect(gui.tabBarState.tabs.isEmpty)
        #expect(requested == [0]) // no good frame yet
        #expect(gui.resyncState.pending == true)
    }

    @Test("base mismatch invalidates without promotion")
    @MainActor func baseMismatchInvalidates() throws {
        let (dispatcher, gui) = makeDispatcher()
        var requested: [UInt32] = []
        dispatcher.onRequestKeyframe = { requested.append($0) }

        dispatcher.dispatch(.beginFrame(frameSeq: 10, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("base.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 10, seq: 0))

        // Delta whose base names a frame this client never committed (7, not 10).
        dispatcher.dispatch(.beginFrame(frameSeq: 11, baseFrameSeq: 7, generation: 1))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("orphan.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 11, seq: 0))

        #expect(gui.tabBarState.tabs.first?.label == "base.ex")
        #expect(requested == [10])
        #expect(gui.resyncState.pending == true)
        #expect(gui.resyncState.lastGoodFrameSeq == 10)
    }

    @Test("commit with no open begin invalidates and requests keyframe")
    @MainActor func commitWithoutBeginInvalidates() throws {
        let (dispatcher, _) = makeDispatcher()
        var requested: [UInt32] = []
        dispatcher.onRequestKeyframe = { requested.append($0) }

        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))
        #expect(requested == [0])
    }

    @Test("decodeFailed inside an open transaction invalidates and requests keyframe")
    @MainActor func decodeFailureInsideTransactionInvalidates() throws {
        let (dispatcher, gui) = makeDispatcher()
        var requested: [UInt32] = []
        dispatcher.onRequestKeyframe = { requested.append($0) }

        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 0, generation: 1))
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
    @MainActor func cleanCommitClearsResyncHint() throws {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.onRequestKeyframe = { _ in }

        // Force a resync.
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))
        #expect(gui.resyncState.pending == true)

        // The recovering keyframe arrives and commits cleanly.
        dispatcher.dispatch(.beginFrame(frameSeq: 7, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("recovered.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 7, seq: 0))

        #expect(gui.resyncState.pending == false)
        #expect(gui.resyncState.lastGoodFrameSeq == 0)
        #expect(gui.tabBarState.tabs.first?.label == "recovered.ex")
    }

    // MARK: - Prepared transaction publication contract (#2747)

    @Test("prepared publication is equivalent to the direct command fixture")
    @MainActor func preparedPublicationEquivalence() throws {
        let (direct, directGUI) = makeDispatcher()
        let (prepared, preparedGUI) = makeDispatcher()
        let content = try windowContent()
        let commands: [RenderCommand] = [
            .guiTheme(slots: completeThemeSlots()),
            .guiWindowContent(data: content),
            .guiTabBar(activeIndex: 0, tabs: [tab("equivalent.ex")]),
            .setCursorShape(.beam),
        ]

        for command in commands { direct.applyForTesting(command) }
        prepared.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        for command in commands { prepared.dispatch(command) }
        prepared.dispatch(.commitFrame(frameSeq: 1, seq: 0))

        #expect(preparedGUI.themeColors.editorBg == directGUI.themeColors.editorBg)
        #expect(preparedGUI.windowContents[7]?.rows.map(\.text) == directGUI.windowContents[7]?.rows.map(\.text))
        #expect(preparedGUI.tabBarState.tabs.map(\.label) == directGUI.tabBarState.tabs.map(\.label))
        #expect(prepared.frameState.cursorShape == direct.frameState.cursorShape)
    }

    @Test("one valid frame enters the publication boundary exactly once")
    @MainActor func onePublicationPerFrame() throws {
        let (dispatcher, gui) = makeDispatcher()
        var results: [FrameTransactionResult] = []
        dispatcher.onTransactionResult = { results.append($0) }

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiWindowContent(data: try windowContent()))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("prepared.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))

        #expect(dispatcher.publicationCount == 1)
        #expect(results == [.applied(generation: 1, frameSeq: 1)])
        #expect(gui.windowContents[7]?.rows.first?.text == "old")
        #expect(gui.tabBarState.tabs.first?.label == "prepared.ex")
    }

    @Test("applied follows semantic publication and does not wait for Metal presentation")
    @MainActor func appliedAtSemanticBoundary() throws {
        let (dispatcher, gui) = makeDispatcher()
        var readyCount = 0
        var publicationSeenByApplied = false
        dispatcher.onFrameReady = { readyCount += 1 }
        dispatcher.onTransactionResult = { result in
            guard case .applied(generation: 4, frameSeq: 8) = result else { return }
            publicationSeenByApplied = dispatcher.publicationCount == 1 &&
                gui.tabBarState.tabs.first?.label == "semantic.ex" && readyCount == 0
        }

        dispatcher.dispatch(.beginFrame(frameSeq: 8, baseFrameSeq: 0, generation: 4))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("semantic.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 8, seq: 0))

        #expect(publicationSeenByApplied)
        #expect(readyCount == 1)
    }

    @Test("focused direct owner observes one committed update")
    @MainActor func focusedObservationIsAtomic() throws {
        let (dispatcher, gui) = makeDispatcher()
        let notificationCount = Mutex(0)

        withObservationTracking {
            _ = gui.tabBarState.tabs
        } onChange: {
            notificationCount.withLock { $0 += 1 }
        }

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("atomic.ex")]))
        dispatcher.dispatch(.guiAgentChat(
            visible: true, status: 0, model: "prepared-model", thinkingLevel: "medium",
            prompt: "", promptLineCount: 1, promptCursorLine: 0, promptCursorCol: 0,
            promptVimMode: 1, promptVisibleRows: 1, promptCompletion: nil,
            pendingToolName: nil, pendingToolSummary: "", helpVisible: false,
            helpGroups: []
        ))
        #expect(notificationCount.withLock { $0 } == 0)
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))

        #expect(notificationCount.withLock { $0 } == 1)
        #expect(gui.tabBarState.tabs.first?.label == "atomic.ex")
        #expect(gui.agentChatState.model == "prepared-model")
    }

    @Test("an early prepared callback observes all later semantic state")
    @MainActor func preparedCallbackObservesCompleteState() throws {
        let (dispatcher, gui) = makeDispatcher()
        var observation: (Bool, String?, String, Set<UInt16>, Bool)?
        dispatcher.onFontChanged = { _, _, _, _ in
            observation = (
                gui.themeColors.hasAppliedTheme,
                gui.windowContents[7]?.rows.first?.text,
                gui.statusBarState.modeName,
                dispatcher.committedEditorSnapshot?.windowIds ?? [],
                gui.completionState.visible
            )
        }

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.setFont(family: "Menlo", size: 14, ligatures: true, weight: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiWindowContent(data: try windowContent()))
        dispatcher.dispatch(.guiStatusBar(status()))
        dispatcher.dispatch(.guiCompletion(
            visible: true, anchorRow: 3, anchorCol: 4, selectedIndex: 0,
            items: [Wire.CompletionItem(kind: 1, label: "commit", detail: "state")],
            documentation: "installed after the resource domain"
        ))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))

        #expect(observation?.0 == true)
        #expect(observation?.1 == "old")
        #expect(observation?.2 == "INSERT")
        #expect(observation?.3 == Set([7]))
        #expect(observation?.4 == true)
    }

    @Test("prepared effects replay once in canonical order before acknowledgement")
    @MainActor func preparedEffectsReplayInCanonicalOrder() throws {
        let (dispatcher, gui) = makeDispatcher()
        var events: [String] = []
        gui.frontendExtensions.register(
            extensionID: "effects-test",
            decoder: { _ in events.append("extension") },
            view: { _ in AnyView(EmptyView()) }
        )
        dispatcher.onFontChanged = { _, _, _, _ in events.append("font") }
        dispatcher.onScrollPresentationReset = { events.append("scroll") }
        dispatcher.onTitleChanged = { _ in events.append("title") }
        dispatcher.onWindowBgChanged = { _ in events.append("background") }
        dispatcher.onModeChanged = { _ in events.append("mode") }
        dispatcher.onLineSpacingChanged = { _ in events.append("spacing") }
        dispatcher.onCursorAnimationChanged = { _ in events.append("cursor-animation") }
        dispatcher.onAgentChatVisibilityChanged = { _ in events.append("agent-chat") }
        dispatcher.onLinkCursorChanged = { _ in events.append("link") }
        dispatcher.onTransactionResult = { _ in events.append("transaction") }
        dispatcher.onFirstRender = { events.append("first-render") }
        dispatcher.onFramePresented = { events.append("presented") }
        dispatcher.onFrameReady = { events.append("ready") }

        let reset = GUIScrollPresentation(
            windowId: 7, resetRequired: true, anchorTop: 5, anchorLeft: 0,
            anchorVisualRowOffset: 0, visibleStartLine: 5, visibleEndLine: 8,
            overscanStartLine: 4, overscanEndLine: 9, contentEpoch: 42,
            layoutGeneration: 1
        )
        let runtime = FrontendExtensionRuntimeMessage(
            extensionID: "effects-test", channel: "commit", payload: Data([1])
        )

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        // Deliberately scramble input order; prepared domains define replay order.
        dispatcher.dispatch(.setLinkCursor(active: true))
        dispatcher.dispatch(.guiAgentChat(
            visible: true, status: 0, model: "model", thinkingLevel: "medium",
            prompt: "", promptLineCount: 1, promptCursorLine: 0,
            promptCursorCol: 0, promptVimMode: 1, promptVisibleRows: 1,
            promptCompletion: nil, pendingToolName: nil, pendingToolSummary: "",
            helpVisible: false, helpGroups: []
        ))
        dispatcher.dispatch(.guiExtensionRuntime(runtime))
        dispatcher.dispatch(.guiCursorAnimation(enabled: false))
        dispatcher.dispatch(.guiLineSpacing(spacing: 1.5))
        dispatcher.dispatch(.guiStatusBar(status()))
        dispatcher.dispatch(.setWindowBg(r: 0x22, g: 0x33, b: 0x44))
        dispatcher.dispatch(.setTitle("Committed"))
        dispatcher.dispatch(.guiWindowContent(data: try windowContent(scrollPresentation: reset)))
        dispatcher.dispatch(.setFont(family: "Menlo", size: 14, ligatures: true, weight: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))

        #expect(events == [
            "font", "scroll", "cursor-animation", "spacing", "mode",
            "background", "title", "extension", "agent-chat", "link",
            "transaction", "first-render", "presented", "ready"
        ])
    }

    @Test("gutter and indent guide keys cannot collide across window ids")
    @MainActor func typedWindowCoalescingKeysDoNotCollide() throws {
        let (dispatcher, _) = makeDispatcher()
        let gutterGeometry = editorGeometry(windowId: 1001, lineNumberWidth: 3, signColWidth: 1)
        let gutter = editorGutter(windowId: 1001, geometry: gutterGeometry)
        let guides = IndentGuideData(
            windowId: 1, tabWidth: 4, activeGuideCol: 4,
            guideCols: [4, 8], lineIndentLevels: [2]
        )

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiWindowContent(data: try editorContent(windowId: 1001, geometry: gutterGeometry)))
        dispatcher.dispatch(.guiWindowContent(data: try windowContent(windowId: 1)))
        dispatcher.dispatch(.guiGutter(data: gutter))
        dispatcher.dispatch(.guiIndentGuides(data: guides))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))

        #expect(dispatcher.frameState.windowGutters[1001]?.lineNumberWidth == 3)
        #expect(dispatcher.frameState.windowIndentGuides[1]?.guideCols == [4, 8])
    }

    @Test("terminal resource-policy rejection preserves committed state and emits once")
    @MainActor func terminalResourcePolicyRejectionPreservesLastGood() throws {
        let (dispatcher, gui) = makeDispatcher()
        var results: [FrameTransactionResult] = []
        var requested: [UInt32] = []
        dispatcher.onTransactionResult = { results.append($0) }
        dispatcher.onRequestKeyframe = { requested.append($0) }

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("committed.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))

        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 1, generation: 1))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("rejected.ex")]))
        dispatcher.resourcePolicyRejected()
        dispatcher.resourcePolicyRejected()

        #expect(dispatcher.lastCommittedFrameSeq == 1)
        #expect(gui.tabBarState.tabs.first?.label == "committed.ex")
        #expect(gui.resyncState.pending == false)
        #expect(requested.isEmpty)
        #expect(results.count == 2)
        guard case .rejected(
            generation: 1,
            frameSeq: 2,
            lastAppliedFrameSeq: 1,
            reason: .resourcePolicy
        ) = results.last else {
            Issue.record("expected one terminal resource-policy rejection")
            return
        }

        dispatcher.dispatch(.beginFrame(frameSeq: 3, baseFrameSeq: 1, generation: 1))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("adapted.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 3, seq: 0))

        #expect(dispatcher.lastCommittedFrameSeq == 3)
        #expect(gui.tabBarState.tabs.first?.label == "adapted.ex")
        #expect(gui.resyncState.pending == false)
        #expect(results.count == 3)
        #expect(results.last == .applied(generation: 1, frameSeq: 3))
    }

    @Test("semantic staging subtracts coalesced command replacements")
    @MainActor func stagingSubtractsCoalescedReplacements() throws {
        let staging = FrameResourceWeight(
            commands: 2, ownedUTF8Bytes: .max, arrayEntries: .max,
            rows: .max, spans: .max, overlays: .max,
            spliceEntries: .max, locatorEntries: .max
        )
        let gui = GUIState()
        let dispatcher = CommandDispatcher(
            cols: 80, rows: 24, guiState: gui,
            resourcePolicy: policy(stagingWeight: staging)
        )
        var results: [FrameTransactionResult] = []
        dispatcher.onTransactionResult = { results.append($0) }

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("first.ex")]))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("replacement.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))

        #expect(gui.tabBarState.tabs.first?.label == "replacement.ex")
        #expect(results == [.applied(generation: 1, frameSeq: 1)])
    }

    @Test("semantic staging bounds append-only chrome across packets")
    @MainActor func stagingBoundsAppendOnlyChrome() throws {
        let staging = FrameResourceWeight(
            commands: 2, ownedUTF8Bytes: .max, arrayEntries: .max,
            rows: .max, spans: .max, overlays: .max,
            spliceEntries: .max, locatorEntries: .max
        )
        let gui = GUIState()
        let dispatcher = CommandDispatcher(
            cols: 80, rows: 24, guiState: gui,
            resourcePolicy: policy(stagingWeight: staging)
        )
        var results: [FrameTransactionResult] = []
        dispatcher.onTransactionResult = { results.append($0) }
        let tabs = [Wire.BottomPanelTab(tabType: 0, name: "Messages")]
        let entry = Wire.MessageEntry(
            streamInstance: 1, id: 1, level: 1, subsystem: 0,
            timestampSecs: 0, filePath: "", text: "entry"
        )

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiBottomPanel(
            visible: true, activeTabIndex: 0, heightPercent: 30,
            filterPreset: 0, tabs: tabs, entries: [entry]
        ))
        dispatcher.dispatch(.guiBottomPanel(
            visible: true, activeTabIndex: 0, heightPercent: 30,
            filterPreset: 0, tabs: tabs, entries: [entry]
        ))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))

        #expect(dispatcher.publicationCount == 0)
        #expect(results == [.rejected(
            generation: 1, frameSeq: 1, lastAppliedFrameSeq: 0,
            reason: .resourcePolicy
        )])
    }

    @Test("semantic staging bounds the resulting transcript before mapping")
    @MainActor func stagingBoundsResultingTranscript() throws {
        let staging = FrameResourceWeight(
            commands: .max, ownedUTF8Bytes: 5, arrayEntries: .max,
            rows: .max, spans: .max, overlays: .max,
            spliceEntries: .max, locatorEntries: .max
        )
        let gui = GUIState()
        let dispatcher = CommandDispatcher(
            cols: 80, rows: 24, guiState: gui,
            resourcePolicy: policy(stagingWeight: staging)
        )
        var results: [FrameTransactionResult] = []
        dispatcher.onTransactionResult = { results.append($0) }

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiAgentTranscript(
            mode: 0, epoch: 1, truncated: false, trimFront: 0, baseCount: 0,
            messages: [Wire.ChatMessage(beamId: 1, content: .user(text: "seed"))]
        ))
        dispatcher.dispatch(.guiAgentTranscript(
            mode: 1, epoch: 1, truncated: false, trimFront: 0, baseCount: 1,
            messages: [Wire.ChatMessage(beamId: 2, content: .assistant(text: "more"))]
        ))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))

        #expect(gui.agentChatState.messages.isEmpty)
        #expect(results == [.rejected(
            generation: 1, frameSeq: 1, lastAppliedFrameSeq: 0,
            reason: .resourcePolicy
        )])
    }

    @Test("resource failure in a later packet terminally rejects the open frame")
    @MainActor func crossPacketResourceFailureIsTerminal() throws {
        let (dispatcher, gui) = makeDispatcher()
        var results: [FrameTransactionResult] = []
        var requested: [UInt32] = []
        dispatcher.onTransactionResult = { results.append($0) }
        dispatcher.onRequestKeyframe = { requested.append($0) }

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("last-good.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))
        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 1, generation: 1))
        dispatcher.decodedFrameFailed(DecodedFrameFailure(
            error: .resource(.limitExceeded(
                dimension: .ownedUTF8Bytes, used: 4, requested: 8, limit: 5
            )),
            envelope: nil
        ))

        #expect(gui.tabBarState.tabs.first?.label == "last-good.ex")
        #expect(requested.isEmpty)
        #expect(results.last == .rejected(
            generation: 1, frameSeq: 2, lastAppliedFrameSeq: 1,
            reason: .resourcePolicy
        ))
    }

    @Test("semantic staging rejects resident result weight before publication")
    @MainActor func residentWeightRejectsBeforePublication() throws {
        let defaults = FrameResourcePolicy.default
        let residentLimit = FrameResourceWeight(
            commands: .max, ownedUTF8Bytes: .max, arrayEntries: .max,
            rows: 1, spans: .max, overlays: .max,
            spliceEntries: .max, locatorEntries: 1
        )
        let policy = FrameResourcePolicy(
            wire: defaults.wire,
            decode: defaults.decode,
            staging: defaults.staging,
            resident: .init(weightPerWindow: residentLimit)
        )
        let gui = GUIState()
        let dispatcher = CommandDispatcher(
            cols: 80, rows: 24, guiState: gui, resourcePolicy: policy
        )
        var results: [FrameTransactionResult] = []
        dispatcher.onTransactionResult = { results.append($0) }
        let content = try GUIWindowContent(
            windowId: 1, fullRefresh: true, cursorRow: 0, cursorCol: 0,
            cursorShape: .block,
            rows: [
                GUIVisualRow(rowType: .normal, rowId: 1, bufLine: 0,
                             contentHash: 1, text: "one", spans: []),
                GUIVisualRow(rowType: .normal, rowId: 2, bufLine: 1,
                             contentHash: 2, text: "two", spans: [])
            ],
            selection: nil, searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: []
        )

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiWindowContent(data: content))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))

        #expect(gui.windowContents.isEmpty)
        #expect(results == [.rejected(
            generation: 1, frameSeq: 1, lastAppliedFrameSeq: 0,
            reason: .resourcePolicy
        )])
    }

    @Test("correlated decode rejection is terminal, deduplicated, and preserves last-good")
    @MainActor func correlatedDecodeResourceRejection() throws {
        let (dispatcher, gui) = makeDispatcher()
        var results: [FrameTransactionResult] = []
        var requested: [UInt32] = []
        dispatcher.onTransactionResult = { results.append($0) }
        dispatcher.onRequestKeyframe = { requested.append($0) }

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 4))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("last-good.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))

        let envelope = FrameEnvelope(generation: 4, frameSeq: 2, baseFrameSeq: 1)
        dispatcher.resourcePolicyRejected(envelope: envelope)
        dispatcher.resourcePolicyRejected(envelope: envelope)

        #expect(dispatcher.lastCommittedFrameSeq == 1)
        #expect(gui.tabBarState.tabs.first?.label == "last-good.ex")
        #expect(gui.resyncState.pending == false)
        #expect(requested.isEmpty)
        #expect(results == [
            .applied(generation: 4, frameSeq: 1),
            .rejected(
                generation: 4, frameSeq: 2, lastAppliedFrameSeq: 1,
                reason: .resourcePolicy
            )
        ])
    }

    @Test("a later invalid domain rejects the whole frame without publication")
    @MainActor func partialFrameRejectionPublishesNothing() throws {
        let (dispatcher, gui) = makeDispatcher()
        var results: [FrameTransactionResult] = []
        dispatcher.onTransactionResult = { results.append($0) }

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("must-not-publish.ex")]))
        dispatcher.dispatch(.guiWindowOverlayDelta(data: overlayDelta(windowId: 99)))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))

        #expect(dispatcher.publicationCount == 0)
        #expect(gui.tabBarState.tabs.isEmpty)
        #expect(gui.resyncState.pending == false)
        #expect(results == [.windowRefMiss(generation: 1, frameSeq: 1, lastAppliedFrameSeq: 0, windowId: 99)])
    }

    @Test("incomplete, resource-rejected, and superseded frames replay no effects")
    @MainActor func nonPublishedFramesReplayNoEffects() throws {
        var effectCount = 0
        func armEffects(_ dispatcher: CommandDispatcher) {
            dispatcher.onTitleChanged = { _ in effectCount += 1 }
            dispatcher.onFontChanged = { _, _, _, _ in effectCount += 1 }
        }

        let (incomplete, _) = makeDispatcher()
        armEffects(incomplete)
        incomplete.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        incomplete.dispatch(.setTitle("incomplete"))
        incomplete.dispatch(.setFont(family: "Menlo", size: 14, ligatures: true, weight: 1))
        incomplete.dispatch(.commitFrame(frameSeq: 1, seq: 0))

        let (resourceRejected, _) = makeDispatcher()
        armEffects(resourceRejected)
        resourceRejected.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        resourceRejected.dispatch(.guiTheme(slots: completeThemeSlots()))
        resourceRejected.dispatch(.setTitle("resource rejected"))
        resourceRejected.resourcePolicyRejected()

        let (superseded, _) = makeDispatcher()
        superseded.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 2))
        superseded.dispatch(.guiTheme(slots: completeThemeSlots()))
        superseded.dispatch(.commitFrame(frameSeq: 1, seq: 0))
        armEffects(superseded)
        superseded.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 1, generation: 1))
        superseded.dispatch(.setTitle("superseded"))
        superseded.dispatch(.setFont(family: "Menlo", size: 14, ligatures: true, weight: 1))
        superseded.dispatch(.commitFrame(frameSeq: 2, seq: 0))

        #expect(effectCount == 0)
    }

    @Test("invalid transcript operations reject without publishing sibling state")
    @MainActor func invalidTranscriptRejectsWholeTransaction() throws {
        let invalidCommands: [(RenderCommand, PreparedFrameRejection)] = [
            (
                .guiAgentTranscript(mode: 1, epoch: 1, truncated: false, trimFront: 0, baseCount: 0, messages: []),
                .transcriptBeforeSeed
            ),
            (
                .guiAgentTranscript(mode: 1, epoch: 2, truncated: false, trimFront: 0, baseCount: 1, messages: []),
                .transcriptEpochMismatch
            ),
            (
                .guiAgentTranscript(mode: 1, epoch: 1, truncated: false, trimFront: 0, baseCount: 9, messages: []),
                .transcriptDesynced
            ),
        ]

        for (index, invalid) in invalidCommands.enumerated() {
            let (dispatcher, gui) = makeDispatcher()
            var results: [FrameTransactionResult] = []
            dispatcher.onTransactionResult = { results.append($0) }

            if index > 0 {
                dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
                dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
                dispatcher.dispatch(.guiAgentTranscript(
                    mode: 0, epoch: 1, truncated: false, trimFront: 0, baseCount: 0,
                    messages: [Wire.ChatMessage(beamId: 1, content: .user(text: "seed"))]
                ))
                dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("baseline.ex")]))
                dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))
            }

            let baselinePublications = dispatcher.publicationCount
            let frameSeq = UInt32(index > 0 ? 2 : 1)
            let baseSeq = UInt32(index > 0 ? 1 : 0)
            dispatcher.dispatch(.beginFrame(frameSeq: frameSeq, baseFrameSeq: baseSeq, generation: 1))
            if baseSeq == 0 { dispatcher.dispatch(.guiTheme(slots: completeThemeSlots())) }
            dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("must-not-publish.ex")]))
            dispatcher.dispatch(invalid.0)
            dispatcher.dispatch(.commitFrame(frameSeq: frameSeq, seq: 0))

            #expect(dispatcher.publicationCount == baselinePublications)
            #expect(gui.tabBarState.tabs.first?.label == (index > 0 ? "baseline.ex" : nil))
            #expect(results.last == .rejected(generation: 1, frameSeq: frameSeq, lastAppliedFrameSeq: UInt32(index > 0 ? 1 : 0), reason: invalid.1))
            #expect(gui.agentChatState.messages.map(\.id) == (index > 0 ? [1] : []))
        }
    }

    @Test("duplicate and out-of-order frame sequences return typed rejections")
    @MainActor func duplicateAndOutOfOrderFramesReject() throws {
        for incoming: UInt32 in [5, 4] {
            let (dispatcher, _) = makeDispatcher()
            var results: [FrameTransactionResult] = []
            dispatcher.onTransactionResult = { results.append($0) }
            dispatcher.dispatch(.beginFrame(frameSeq: 5, baseFrameSeq: 0, generation: 1))
            dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
            dispatcher.dispatch(.commitFrame(frameSeq: 5, seq: 0))

            dispatcher.dispatch(.beginFrame(frameSeq: incoming, baseFrameSeq: 0, generation: 1))
            dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
            dispatcher.dispatch(.commitFrame(frameSeq: incoming, seq: 0))

            #expect(results.last == .rejected(generation: 1, frameSeq: incoming, lastAppliedFrameSeq: 5, reason: .frameSequenceNotIncreasing(lastFrameSeq: 5, incomingFrameSeq: incoming)))
            #expect(dispatcher.publicationCount == 1)
        }
    }

    @Test("missing window references and stale epochs reject before publication")
    @MainActor func windowReferenceAndEpochValidation() throws {
        let (dispatcher, gui) = makeDispatcher()
        var results: [FrameTransactionResult] = []
        dispatcher.onTransactionResult = { results.append($0) }

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiWindowContent(data: try windowContent()))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))

        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 1, generation: 1))
        dispatcher.dispatch(.guiWindowOverlayDelta(data: overlayDelta(epoch: 41)))
        dispatcher.dispatch(.commitFrame(frameSeq: 2, seq: 0))

        #expect(dispatcher.publicationCount == 1)
        #expect(results.last == .rejected(generation: 1, frameSeq: 2, lastAppliedFrameSeq: 1, reason: .windowEpochMismatch(windowId: 7, expected: 42, actual: 41)))
        #expect(gui.windowContents[7]?.cursorShape == .block)
    }

    @Test("unsorted full content fails before resident construction or publication")
    @MainActor func unsortedContentIsTransactional() throws {
        let (dispatcher, gui) = makeDispatcher()
        let high = GUIVisualRow(rowType: .normal, rowId: 1, bufLine: 2,
            contentHash: 11, text: "high", spans: [])
        let low = GUIVisualRow(rowType: .normal, rowId: 2, bufLine: 1,
            contentHash: 22, text: "low", spans: [])

        #expect(throws: ResidentRowStoreError.unsortedBufferLine(previous: 2, next: 1)) {
            _ = try GUIWindowContent(windowId: 7, fullRefresh: true, contentEpoch: 42,
                cursorRow: 0, cursorCol: 0, cursorShape: .block, rows: [high, low],
                selection: nil, searchMatches: [], diagnosticUnderlines: [],
                documentHighlights: [])
        }
        #expect(dispatcher.publicationCount == 0)
        #expect(gui.windowContents.isEmpty)
    }

    @Test("missing retained row reports targeted miss without partial publication")
    @MainActor func missingRetainedRowIsTransactional() throws {
        let (dispatcher, gui) = makeDispatcher()
        var results: [FrameTransactionResult] = []
        dispatcher.onTransactionResult = { results.append($0) }

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiWindowContent(data: try windowContent()))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("baseline.ex")]))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))

        let missing = GUIWindowRowsDelta(
            windowId: 7, contentEpoch: 42, cursorVisible: true,
            cursorRow: 0, cursorCol: 0, cursorShape: .block, scrollLeft: 0,
            rows: [
                .reference(rowId: 1, contentHash: 11),
                .reference(rowId: 999, contentHash: 999)
            ], selection: nil,
            searchMatches: [], diagnosticUnderlines: [], documentHighlights: [],
            lineAnnotations: [], paneGeometry: nil, cursorline: nil
        )

        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 1, generation: 1))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("must-not-publish.ex")]))
        dispatcher.dispatch(.guiWindowRowsDelta(data: missing))
        dispatcher.dispatch(.commitFrame(frameSeq: 2, seq: 0))

        #expect(dispatcher.publicationCount == 1)
        #expect(gui.tabBarState.tabs.first?.label == "baseline.ex")
        #expect(gui.windowContents[7]?.rows.first?.text == "old")
        #expect(results.last == .windowRefMiss(generation: 1, frameSeq: 2, lastAppliedFrameSeq: 1, windowId: 7))
    }

    @Test("unregistered font resources reject a prepared frame")
    @MainActor func missingFontResourceRejects() throws {
        let (dispatcher, _) = makeDispatcher()
        var results: [FrameTransactionResult] = []
        dispatcher.onTransactionResult = { results.append($0) }

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiWindowContent(data: try windowContent(fontId: 3)))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))

        #expect(dispatcher.publicationCount == 0)
        #expect(results == [.rejected(generation: 1, frameSeq: 1, lastAppliedFrameSeq: 0, reason: .missingFontResource(fontId: 3))])
    }

    @Test("unregistered font resources in row splices reject a prepared frame")
    @MainActor func missingSpliceFontResourceRejects() throws {
        let (dispatcher, _) = makeDispatcher()
        var results: [FrameTransactionResult] = []
        dispatcher.onTransactionResult = { results.append($0) }

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiWindowContent(data: try windowContent()))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))

        let replacement = GUIVisualRow(
            rowType: .normal, rowId: 2, bufLine: 0, contentHash: 22,
            text: "new", spans: [GUIHighlightSpan(
                startCol: 0, endCol: 3, fg: 0xFFFFFF, bg: 0,
                attrs: 0, fontWeight: 0, fontId: 3
            )]
        )
        let delta = GUIWindowRowsDelta(
            windowId: 7, contentEpoch: 42, cursorVisible: true,
            cursorRow: 0, cursorCol: 0, cursorShape: .block, scrollLeft: 0,
            baseRowCount: 1, resultRowCount: 1,
            rowSplices: [GUIWindowRowSplice(
                startIndex: 0, deleteCount: 1, insertEntries: [.full(replacement)]
            )],
            selection: nil, searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: [], lineAnnotations: [], paneGeometry: nil,
            cursorline: nil
        )

        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 1, generation: 1))
        dispatcher.dispatch(.guiWindowRowsDelta(data: delta))
        dispatcher.dispatch(.commitFrame(frameSeq: 2, seq: 0))

        #expect(dispatcher.publicationCount == 1)
        #expect(results.last == .rejected(
            generation: 1, frameSeq: 2, lastAppliedFrameSeq: 1,
            reason: .missingFontResource(fontId: 3)
        ))
    }

    @Test("publication operation count depends on changed domains, not command count")
    @MainActor func changedDomainOperationCount() throws {
        let (dispatcher, gui) = makeDispatcher()
        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))

        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 1, generation: 1))
        for index in 0..<100 {
            dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [tab("\(index).ex")]))
        }
        dispatcher.dispatch(.commitFrame(frameSeq: 2, seq: 0))

        #expect(dispatcher.lastPublicationOperationCounts == PreparedFrameOperationCounts(
            theme: 0, windows: 0, chrome: 1, overlays: 0,
            resources: 0, focus: 0, metadata: 0
        ))
        #expect(dispatcher.publicationCount == 2)
        #expect(gui.tabBarState.tabs.first?.label == "99.ex")
    }

    // MARK: - Negative-guard dispatch (#2634)
    //
    // Sanctioned out-of-band commands have explicit match arms in dispatch() and
    // apply (or stage) directly. Everything else outside a transaction hits the
    // default branch: active recovery via invalidation and a keyframe request.
    // This is the negative-guard pattern from Go's model.go applyCommands.

    @Test("set_title applies immediately with no open transaction")
    @MainActor func titleAppliesOutOfBand() throws {
        let (dispatcher, _) = makeDispatcher()
        var requested: [UInt32] = []
        var title: String?
        dispatcher.onRequestKeyframe = { requested.append($0) }
        dispatcher.onTitleChanged = { title = $0 }

        dispatcher.dispatch(.setTitle("buffer.ex"))

        #expect(title == "buffer.ex")
        #expect(requested.isEmpty) // out-of-band, not an invalidation
    }

    @Test("set_window_bg replays its local effect immediately after mutation")
    @MainActor func windowBgAppliesOutOfBand() throws {
        let (dispatcher, _) = makeDispatcher()
        var requested: [UInt32] = []
        var callbackCount = 0
        var callbackSawInstalledState = false
        let expected: UInt32 = (0x28 << 16) | (0x2C << 8) | 0x34
        dispatcher.onRequestKeyframe = { requested.append($0) }
        dispatcher.onWindowBgChanged = { _ in
            callbackCount += 1
            callbackSawInstalledState = dispatcher.frameState.defaultBg == expected
        }

        dispatcher.dispatch(.setWindowBg(r: 0x28, g: 0x2C, b: 0x34))

        #expect(dispatcher.frameState.defaultBg == expected)
        #expect(callbackCount == 1)
        #expect(callbackSawInstalledState)
        #expect(requested.isEmpty)
    }

    @Test("protocol_error applies immediately with no open transaction")
    @MainActor func protocolErrorAppliesOutOfBand() throws {
        let (dispatcher, gui) = makeDispatcher()
        var requested: [UInt32] = []
        dispatcher.onRequestKeyframe = { requested.append($0) }

        dispatcher.dispatch(.protocolError(message: "version mismatch"))

        #expect(gui.protocolErrorState.isPresented == true)
        #expect(requested.isEmpty)
    }

    @Test("set_font applies immediately with no open transaction")
    @MainActor func setFontAppliesOutOfBand() throws {
        let (dispatcher, _) = makeDispatcher()
        var requested: [UInt32] = []
        var fontArgs: (family: String, size: UInt16, ligatures: Bool, weight: UInt8)?
        dispatcher.onRequestKeyframe = { requested.append($0) }
        dispatcher.onFontChanged = { family, size, ligatures, weight in
            fontArgs = (family, size, ligatures, weight)
        }

        dispatcher.dispatch(.setFont(family: "JetBrainsMono Nerd Font", size: 14, ligatures: true, weight: 2))

        #expect(fontArgs?.family == "JetBrainsMono Nerd Font")
        #expect(fontArgs?.size == 14)
        #expect(fontArgs?.ligatures == true)
        #expect(fontArgs?.weight == 2)
        #expect(requested.isEmpty)
    }

    @Test("set_font_fallback applies immediately with no open transaction")
    @MainActor func setFontFallbackAppliesOutOfBand() throws {
        let (dispatcher, _) = makeDispatcher()
        var requested: [UInt32] = []
        dispatcher.onRequestKeyframe = { requested.append($0) }
        let fontManager = FontManager(name: "Menlo", size: 13.0, scale: 2.0)
        dispatcher.fontManager = fontManager

        dispatcher.dispatch(.setFontFallback(families: ["Symbols Nerd Font Mono", "Apple Color Emoji"]))

        #expect(requested.isEmpty)
    }

    @Test("register_font applies immediately with no open transaction")
    @MainActor func registerFontAppliesOutOfBand() throws {
        let (dispatcher, _) = makeDispatcher()
        var requested: [UInt32] = []
        dispatcher.onRequestKeyframe = { requested.append($0) }
        let fontManager = FontManager(name: "Menlo", size: 13.0, scale: 2.0)
        dispatcher.fontManager = fontManager

        dispatcher.dispatch(.registerFont(id: 1, family: "JetBrainsMono Nerd Font"))

        #expect(requested.isEmpty)
    }

    @Test("gui_config_state applies immediately with no open transaction")
    @MainActor func guiConfigStateAppliesOutOfBand() throws {
        let (dispatcher, _) = makeDispatcher()
        var requested: [UInt32] = []
        dispatcher.onRequestKeyframe = { requested.append($0) }

        let configState = Wire.ConfigState(options: [:], themePreviews: [], keybindings: [])
        dispatcher.dispatch(.guiConfigState(configState))

        #expect(requested.isEmpty)
    }

    @Test("clipboard_write applies immediately with no open transaction")
    @MainActor func clipboardWriteAppliesOutOfBand() throws {
        let (dispatcher, _) = makeDispatcher()
        var requested: [UInt32] = []
        dispatcher.onRequestKeyframe = { requested.append($0) }

        dispatcher.dispatch(.clipboardWrite(target: 0, text: "yanked text"))

        let pasted = NSPasteboard.general.string(forType: .string)
        #expect(pasted == "yanked text")
        #expect(requested.isEmpty)
    }

    @Test("non-sanctioned command outside a transaction triggers keyframe request, not silent drop")
    @MainActor func chromeOutOfBandInvalidates() throws {
        let (dispatcher, gui) = makeDispatcher()
        var requested: [UInt32] = []
        dispatcher.onRequestKeyframe = { requested.append($0) }

        // guiTabBar has no explicit sanctioned match arm in dispatch() — negative guard.
        // Sending it outside a transaction must trigger active recovery (AC#5 / #2634):
        // the keyframe callback fires and the command is not applied, rather than being
        // silently dropped or partially applied.
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

@Suite("CommandDispatcher presentation samples")
struct CommandDispatcherPresentationSampleTests {
    @MainActor
    private func makeDispatcher() -> CommandDispatcher {
        CommandDispatcher(cols: 80, rows: 24, guiState: GUIState())
    }

    @MainActor
    private func commit(_ dispatcher: CommandDispatcher, frameSeq: UInt32,
                        baseFrameSeq: UInt32, inputSeq: UInt32) {
        dispatcher.dispatch(.beginFrame(frameSeq: frameSeq, baseFrameSeq: baseFrameSeq, generation: 1))
        if frameSeq == 1 {
            dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        }
        dispatcher.dispatch(.commitFrame(frameSeq: frameSeq, seq: inputSeq))
    }

    @Test("a newer semantic frame discards the unsubmitted sample as superseded")
    @MainActor func supersededSampleIsDiscarded() throws {
        let dispatcher = makeDispatcher()
        let first = dispatcher.latency.stamp()
        commit(dispatcher, frameSeq: 1, baseFrameSeq: 0, inputSeq: first)
        let second = dispatcher.latency.stamp()
        commit(dispatcher, frameSeq: 2, baseFrameSeq: 1, inputSeq: second)

        #expect(dispatcher.latency.snapshot().discardCounts[.superseded] == 1)
        #expect(dispatcher.takePresentationInputSeq() == second)
    }

    @Test("an unavailable surface discards rather than selects the pending sample")
    @MainActor func unavailableSurfaceDiscardsPendingSample() throws {
        let dispatcher = makeDispatcher()
        let seq = dispatcher.latency.stamp()
        commit(dispatcher, frameSeq: 1, baseFrameSeq: 0, inputSeq: seq)

        dispatcher.discardPendingPresentation(reason: .occluded)

        #expect(dispatcher.takePresentationInputSeq() == 0)
        #expect(dispatcher.latency.snapshot().discardCounts[.occluded] == 1)
    }
}
