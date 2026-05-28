/// Maps view names to constructed SwiftUI chrome views with mock state.

import AppKit
import SwiftUI

@MainActor
enum PreviewRegistry {

    /// Returns the intended screenshot size for a preview.
    static func size(named name: String) -> CGSize {
        PreviewSnapshotPolicy.size(named: name)
    }

    /// Returns a preview for the named view, or an error label for unknown names.
    @ViewBuilder
    static func view(named name: String) -> some View {
        switch name {
        case "EditorChromeView":
            editorChromePreview()
        case "AgentChromeView":
            agentChromePreview()
        case "GitStatusView":
            gitStatusPreview()
        case "GitStatusClean":
            gitStatusCleanPreview()
        case "GitStatusConflict":
            gitStatusConflictPreview()
        case "GitStatusDense":
            gitStatusDensePreview()
        case "FileTreeView":
            fileTreePreview()
        case "FileTreeEmpty":
            fileTreeEmptyPreview()
        case "FileTreeError":
            fileTreeErrorPreview()
        case "FileTreeDeep":
            fileTreeDeepPreview()
        case "CompletionOverlay":
            completionPreview()
        case "StatusBarView":
            statusBarPreview()
        case "TabBarView":
            tabBarPreview()
        case "NotificationCenterView":
            notificationPreview()
        case "NotificationStack":
            notificationStackPreview()
        case "BottomPanelView":
            bottomPanelPreview()
        case "BottomPanelEmpty":
            bottomPanelEmptyPreview()
        case "SettingsView":
            settingsPreview()
        case "ToolManagerView":
            toolManagerPreview()
        case "ObservatoryView":
            observatoryPreview()
        case "AgentChatView":
            agentChatPreview()
        case "AgentChatStreaming":
            agentChatStreamingPreview()
        case "AgentChatApproval":
            agentChatApprovalPreview()
        case "AgentChatError":
            agentChatErrorPreview()
        case "AgentChatCompletion":
            agentChatCompletionPreview()
        case "AgentChatSummary":
            agentChatSummaryPreview()
        case "BoardView":
            boardPreview()
        case "ChangeSummaryView":
            changeSummaryPreview()
        case "DispatchSheetView":
            dispatchSheetPreview()
        case "PickerOverlay":
            pickerPreview()
        case "MinibufferView":
            minibufferPreview()
        case "WhichKeyOverlay":
            whichKeyPreview()
        case "SearchToolbar":
            searchToolbarPreview()
        case "HoverPopupOverlay":
            hoverPopupPreview()
        case "SignatureHelpOverlay":
            signatureHelpPreview()
        case "DiagnosticsEditorView":
            diagnosticsEditorPreview()
        case "TabBarOverflow":
            tabBarOverflowPreview()
        case "InsertModeEditorView":
            insertModeEditorPreview()
        case "HoverEditorView":
            hoverEditorPreview()
        case "SignatureHelpEditorView":
            signatureHelpEditorPreview()
        case "BottomPanelDiagnostics":
            bottomPanelDiagnosticsPreview()
        case "NotificationOverflow":
            notificationOverflowPreview()
        case "FileTreeRename":
            fileTreeRenamePreview()
        case "WhichKeyPaged":
            whichKeyPagedPreview()
        default:
            Text("Unknown view: \(name)")
                .font(.title)
                .foregroundStyle(.red)
                .padding(24)
        }
    }

    // MARK: - EditorChromeView

    private static func editorChromePreview() -> some View {
        previewChromeView(agentVisible: false, failureMessage: "EditorChromeView could not initialize the production editor renderer.")
    }

    private static func agentChromePreview() -> some View {
        previewChromeView(agentVisible: true, failureMessage: "AgentChromeView could not initialize the production editor renderer.")
    }

    // MARK: - InsertModeEditorView

    @ViewBuilder
    private static func insertModeEditorPreview() -> some View {
        let size = PreviewSnapshotPolicy.size(named: "InsertModeEditorView")
        if let appState = productionPreviewAppState(agentVisible: false, mode: .insert) {
            ContentView(appState: appState)
                .frame(width: size.width, height: size.height)
        } else {
            previewFailureView(message: "InsertModeEditorView could not initialize the production editor renderer.")
                .frame(width: size.width, height: size.height)
        }
    }

    // MARK: - HoverEditorView

    @ViewBuilder
    private static func hoverEditorPreview() -> some View {
        let size = PreviewSnapshotPolicy.size(named: "HoverEditorView")
        if let appState = hoverEditorAppState() {
            ContentView(appState: appState)
                .frame(width: size.width, height: size.height)
        } else {
            previewFailureView(message: "HoverEditorView could not initialize the production editor renderer.")
                .frame(width: size.width, height: size.height)
        }
    }

    private static func hoverEditorAppState() -> AppState? {
        guard let appState = productionPreviewAppState(agentVisible: false) else { return nil }
        appState.gui.completionState.hide()
        appState.gui.hoverPopupState.update(
            visible: true, anchorRow: 4, anchorCol: 10,
            focused: false, scrollOffset: 0,
            rawLines: previewHoverLines()
        )
        return appState
    }

    // MARK: - SignatureHelpEditorView

    @ViewBuilder
    private static func signatureHelpEditorPreview() -> some View {
        let size = PreviewSnapshotPolicy.size(named: "SignatureHelpEditorView")
        if let appState = signatureHelpEditorAppState() {
            ContentView(appState: appState)
                .frame(width: size.width, height: size.height)
        } else {
            previewFailureView(message: "SignatureHelpEditorView could not initialize the production editor renderer.")
                .frame(width: size.width, height: size.height)
        }
    }

    private static func signatureHelpEditorAppState() -> AppState? {
        guard let appState = productionPreviewAppState(agentVisible: false) else { return nil }
        appState.gui.completionState.hide()
        appState.gui.signatureHelpState.update(
            visible: true, anchorRow: 5, anchorCol: 10,
            activeSignature: 0, activeParameter: 1,
            rawSignatures: previewSignatures()
        )
        return appState
    }

    @ViewBuilder
    private static func previewChromeView(agentVisible: Bool, failureMessage: String) -> some View {
        let viewName = agentVisible ? "AgentChromeView" : "EditorChromeView"
        let size = PreviewSnapshotPolicy.size(named: viewName)

        if let appState = productionPreviewAppState(agentVisible: agentVisible) {
            ContentView(appState: appState)
                .frame(width: size.width, height: size.height)
        } else {
            previewFailureView(message: failureMessage)
                .frame(width: size.width, height: size.height)
        }
    }

    private static func previewFailureView(message: String) -> some View {
        ZStack {
            Color(red: 0.16, green: 0.08, blue: 0.08)
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color(red: 0.95, green: 0.58, blue: 0.28))
                Text("Preview fixture failed")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
    }

    /// Vim mode used for preview fixture state.
    private enum PreviewMode {
        case normal
        case insert
    }

    private static func productionPreviewAppState(agentVisible: Bool, mode: PreviewMode = .normal) -> AppState? {
        let appState = AppState()
        appState.windowTitle = "Minga"
        appState.windowBgIsDark = true
        appState.hasReceivedFirstFrame = true
        appState.trafficLightMidY = 14

        let encoder = previewEncoder()
        appState.encoder = encoder
        appState.gui.settingsState.encoder = encoder

        populateFileTree(appState.gui.fileTreeState)
        populateGitStatus(appState.gui.gitStatusState)
        appState.gui.gitStatusState.hide()
        populateTabBar(appState.gui.tabBarState)
        appState.gui.breadcrumbState.update(segments: ["lib", "minga", "editor.ex"])
        appState.gui.statusBarState.update(from: previewStatusBarUpdate(agentVisible: agentVisible, mode: mode))

        if agentVisible {
            populateAgentChat(appState.gui.agentChatState)
        } else {
            populateCompletion(appState.gui.completionState)
        }

        guard let editorNSView = previewEditorNSView(appState: appState, encoder: encoder) else { return nil }
        appState.editorNSView = editorNSView
        return appState
    }

    private static func previewEncoder() -> ProtocolEncoder {
        let output = FileHandle(forWritingAtPath: "/dev/null") ?? .standardOutput
        return ProtocolEncoder(output: output)
    }

    private static func previewEditorNSView(appState: AppState, encoder: ProtocolEncoder) -> EditorNSView? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let fontFace = FontFace(name: "Menlo", size: 13, scale: scale)
        let fontManager = FontManager(name: "Menlo", size: 13, scale: scale)
        guard let renderer = CoreTextMetalRenderer() else { return nil }
        renderer.setupRenderers(fontManager: fontManager)

        let dispatcher = CommandDispatcher(cols: 112, rows: 36, guiState: appState.gui)
        dispatcher.fontManager = fontManager
        populateEditorFrame(dispatcher: dispatcher, guiState: appState.gui)

        let nsView = EditorNSView(encoder: encoder, fontFace: fontFace, dispatcher: dispatcher, coreTextRenderer: renderer, fontManager: fontManager)
        nsView.guiState = appState.gui
        nsView.statusBarState = appState.gui.statusBarState
        nsView.renderFrame()
        return nsView
    }

    private static func populateEditorFrame(dispatcher: CommandDispatcher, guiState: GUIState) {
        dispatcher.frameState.defaultBg = 0x282C34
        dispatcher.frameState.gutterCol = 4
        dispatcher.frameState.gutterSeparatorColor = 0x3E4452
        dispatcher.frameState.cursorRow = 5
        dispatcher.frameState.cursorCol = 12
        dispatcher.frameState.cursorShape = .beam
        dispatcher.frameState.cursorlineRow = 5
        dispatcher.frameState.cursorlineBg = 0x2C323C
        dispatcher.frameState.totalLineCount = 1250
        dispatcher.frameState.viewportTopLine = 38
        dispatcher.frameState.scrollIndicatorColor = 0x5C6370
        dispatcher.frameState.windowGutters[1] = Wire.WindowGutter(
            windowId: 1,
            contentRow: 1,
            contentCol: 0,
            contentHeight: 22,
            isActive: true,
            contentWidth: 108,
            cursorLine: 42,
            lineNumberStyle: .absolute,
            lineNumberWidth: 3,
            signColWidth: 1,
            entries: previewGutterEntries()
        )
        guiState.windowContents[1] = GUIWindowContent(
            windowId: 1,
            fullRefresh: true,
            cursorVisible: true,
            cursorRow: 5,
            cursorCol: 12,
            cursorShape: .beam,
            rows: previewEditorRows(),
            selection: nil,
            searchMatches: [],
            diagnosticUnderlines: [GUIDiagnosticUnderline(startRow: 4, startCol: 20, endRow: 4, endCol: 31, severity: .warning)],
            documentHighlights: [GUIDocumentHighlight(startRow: 5, startCol: 4, endRow: 5, endCol: 10, kind: .read)],
            lineAnnotations: []
        )
    }

    private static func previewGutterEntries() -> [Wire.GutterEntry] {
        (38...59).map { line in
            let sign: Wire.GutterSignType = line == 42 || line == 47 ? .gitModified : .none
            return Wire.GutterEntry(bufLine: UInt32(line), displayType: .normal, signType: sign)
        }
    }

    private static func previewEditorRows() -> [GUIVisualRow] {
        let rows: [(String, [GUIHighlightSpan])] = [
            ("defmodule Minga.Editor do", [span(0, 9, 0xC678DD, attrs: 1), span(10, 22, 0xBBC2CF), span(23, 25, 0x51AFEF, attrs: 1)]),
            ("  alias Minga.Buffer", [span(2, 7, 0xC678DD), span(8, 20, 0xBBC2CF)]),
            ("", []),
            ("  def open(path) do", [span(2, 5, 0xC678DD, attrs: 1), span(6, 10, 0x98BE65), span(17, 19, 0x51AFEF)]),
            ("    {:ok, buffer} = Buffer.open(path)", [span(5, 8, 0xECBE7B), span(10, 16, 0xBBC2CF), span(20, 26, 0x51AFEF), span(27, 31, 0x98BE65)]),
            ("    render(buffer)", [span(4, 10, 0x51AFEF), span(11, 17, 0xBBC2CF)]),
            ("  end", [span(2, 5, 0xC678DD)]),
            ("end", [span(0, 3, 0xC678DD)]),
            ("", []),
            ("# PreviewHost captures this through ContentView.", [span(0, 45, 0x5C6370, attrs: 2)]),
        ]

        return rows.enumerated().map { index, row in
            let bufLine = UInt32(38 + index)
            let rowId = (UInt64(1) << 60) | (UInt64(bufLine) << 28)
            return GUIVisualRow(rowType: .normal, rowId: rowId, bufLine: bufLine, contentHash: UInt32(index + 1), text: row.0, spans: row.1)
        }
    }

    private static func span(_ start: UInt16, _ end: UInt16, _ fg: UInt32, bg: UInt32 = 0, attrs: UInt8 = 0) -> GUIHighlightSpan {
        GUIHighlightSpan(startCol: start, endCol: end, fg: fg, bg: bg, attrs: attrs, fontWeight: 0, fontId: 0)
    }

    private static func populateFileTree(_ state: FileTreeState) {
        state.update(
            version: 1,
            selectedId: "lib/minga/editor.ex",
            focused: true,
            treeWidth: 30,
            rootPath: "/Users/dev/code/minga",
            rawEntries: fileTreeRawEntries(),
            treeState: FileTreeVisibilityState.ready.rawValue
        )
    }

    private static func populateGitStatus(_ state: GitStatusState) {
        state.update(
            repoState: .normal,
            branchName: "feat/preview-host",
            ahead: 2,
            behind: 0,
            syncing: false,
            entries: gitStatusEntries(),
            toast: nil,
            entryBasePath: "/Users/dev/code/minga",
            lastCommitMessage: "feat(editor): add preview host target",
            stashCount: 1
        )
        state.commitMessage = "feat(macos): polish preview snapshots"
    }

    private static func populateTabBar(_ state: TabBarState) {
        state.update(activeIndex: 0, entries: previewTabs())
    }

    private static func previewTabs() -> [Wire.TabEntry] {
        [
            Wire.TabEntry(id: 1, groupId: 0, isActive: true, isDirty: false, isAgent: false, hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "", label: "editor.ex"),
            Wire.TabEntry(id: 2, groupId: 0, isActive: false, isDirty: false, isAgent: false, hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "", label: "document.ex"),
            Wire.TabEntry(id: 3, groupId: 0, isActive: false, isDirty: true, isAgent: false, hasAttention: true, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "", label: "mode.ex"),
        ]
    }

    private static func populateCompletion(_ state: CompletionState) {
        state.update(visible: true, anchorRow: 5, anchorCol: 10, selectedIndex: 1, rawItems: previewCompletionItems())
    }

    private static func previewCompletionItems() -> [Wire.CompletionItem] {
        [
            Wire.CompletionItem(kind: 7, label: "defmodule", detail: "keyword"),
            Wire.CompletionItem(kind: 7, label: "defstruct", detail: "keyword"),
            Wire.CompletionItem(kind: 7, label: "defdelegate", detail: "keyword"),
            Wire.CompletionItem(kind: 2, label: "def", detail: "keyword"),
            Wire.CompletionItem(kind: 1, label: "Document", detail: "Minga.Buffer.Document"),
        ]
    }

    private static func populateAgentChat(_ state: AgentChatState) {
        state.update(
            visible: true,
            status: 2,
            model: "anthropic:claude-sonnet-4",
            thinkingLevel: "medium",
            prompt: "Make the notification card use the configured theme",
            promptLineCount: 1,
            promptCursorLine: 0,
            promptCursorCol: 52,
            promptVimMode: 1,
            promptVisibleRows: 1,
            promptCompletion: nil,
            helpVisible: false,
            helpGroups: [],
            rawMessages: agentChatMessages()
        )
    }

    private static func previewStatusBarUpdate(agentVisible: Bool, mode: PreviewMode = .normal) -> StatusBarUpdate {
        let modeValue: UInt8 = mode == .insert ? 1 : 0
        return StatusBarUpdate(
            contentKind: 0, mode: modeValue, cursorLine: 42, cursorCol: 9,
            lineCount: 1250, flags: 0x02, lspStatus: 1, gitBranch: "main",
            message: "", filetype: "elixir", errorCount: 0, warningCount: 2,
            modelName: agentVisible ? "claude-sonnet-4" : "", messageCount: agentVisible ? 6 : 0, sessionStatus: agentVisible ? 2 : 0,
            infoCount: 0, hintCount: 0, macroRecording: 0, parserStatus: 1, agentStatus: agentVisible ? 2 : 0,
            activeToolName: agentVisible ? "read" : "",
            gitAdded: 0, gitModified: 0, gitDeleted: 0,
            icon: "", iconColorR: 0x88, iconColorG: 0x57, iconColorB: 0xA6, filename: "editor.ex", diagnosticHint: "",
            backgroundSubagentCount: 0, backgroundSubagentLabel: "",
            modelineLeftSegments: previewStatusLeftSegments(mode: mode),
            modelineRightSegments: previewStatusRightSegments()
        )
    }

    private static func previewStatusLeftSegments(mode: PreviewMode = .normal) -> [Wire.StatusBarSegment] {
        let modeSegment: Wire.StatusBarSegment
        switch mode {
        case .normal:
            modeSegment = Wire.StatusBarSegment(id: 0, kind: "mode", text: " NORMAL ", fgColor: 0x000000, bgColor: 0x7AA2F7, attrs: 1, command: "")
        case .insert:
            modeSegment = Wire.StatusBarSegment(id: 0, kind: "mode", text: " INSERT ", fgColor: 0x000000, bgColor: 0x9ECE6A, attrs: 1, command: "")
        }
        return [
            modeSegment,
            Wire.StatusBarSegment(id: 1, kind: "git", text: " main ", fgColor: 0xBB9AF7, bgColor: 0x000000, attrs: 0, command: "git_branch_picker"),
            Wire.StatusBarSegment(id: 2, kind: "filename", text: " editor.ex [+] ", fgColor: 0xC0CAF5, bgColor: 0x000000, attrs: 0, command: "buffer_list"),
        ]
    }

    private static func previewStatusRightSegments() -> [Wire.StatusBarSegment] {
        [
            Wire.StatusBarSegment(id: 0, kind: "diagnostics", text: " 0 ", fgColor: 0xF7768E, bgColor: 0x000000, attrs: 0, command: "diagnostic_list"),
            Wire.StatusBarSegment(id: 1, kind: "diagnostics", text: " 2 ", fgColor: 0xE0AF68, bgColor: 0x000000, attrs: 0, command: "diagnostic_list"),
            Wire.StatusBarSegment(id: 2, kind: "filetype", text: " Elixir ", fgColor: 0xC0CAF5, bgColor: 0x000000, attrs: 0, command: "set_language"),
            Wire.StatusBarSegment(id: 3, kind: "position", text: " Ln 42, Col 9 ", fgColor: 0xC0CAF5, bgColor: 0x000000, attrs: 0, command: "goto_line"),
        ]
    }

    // MARK: - GitStatusView

    private static func gitStatusPreview() -> some View {
        let theme = populatedTheme()
        let state = gitStatusState()
        state.commitMessage = "feat(macos): polish preview snapshots"

        return GitStatusView(
            state: state,
            theme: theme,
            encoder: nil,
            usesPreviewEagerLayout: PreviewSnapshotPolicy.shouldUseEagerLayout(for: "GitStatusView")
        )
        .frame(width: 280, height: 600)
        .background(theme.treeBg)
    }

    private static func gitStatusState() -> GitStatusState {
        let state = GitStatusState()
        state.update(
            repoState: .normal,
            branchName: "feat/preview-host",
            ahead: 2,
            behind: 0,
            syncing: false,
            entries: gitStatusEntries(),
            toast: nil,
            entryBasePath: "/Users/dev/code/minga",
            lastCommitMessage: "feat(editor): add preview host target",
            stashCount: 1
        )
        return state
    }

    private static func gitStatusEntries() -> [GitStatusEntry] {
        [
            GitStatusEntry(pathHash: 1, section: .staged, status: .modified, path: "lib/minga/editor.ex"),
            GitStatusEntry(pathHash: 2, section: .staged, status: .added, path: "lib/minga/preview.ex"),
            GitStatusEntry(pathHash: 3, section: .staged, status: .deleted, path: "lib/minga/old_module.ex"),
            GitStatusEntry(pathHash: 4, section: .changed, status: .modified, path: "lib/minga/buffer/document.ex"),
            GitStatusEntry(pathHash: 5, section: .changed, status: .modified, path: "lib/minga/buffer/process.ex"),
            GitStatusEntry(pathHash: 6, section: .changed, status: .modified, path: "lib/minga/editor/render_pipeline.ex"),
            GitStatusEntry(pathHash: 7, section: .changed, status: .modified, path: "test/minga/editor/render_pipeline_test.exs"),
            GitStatusEntry(pathHash: 8, section: .changed, status: .renamed, path: "macos/Sources/Views/PreviewRegistry.swift"),
            GitStatusEntry(pathHash: 9, section: .untracked, status: .untracked, path: "lib/minga/new_feature.ex"),
            GitStatusEntry(pathHash: 10, section: .untracked, status: .untracked, path: "docs/SNAPSHOT_AUDIT.md"),
            GitStatusEntry(pathHash: 11, section: .untracked, status: .untracked, path: "zig/tests/fixtures/full_editor.bin"),
        ]
    }

    // MARK: - GitStatusClean

    private static func gitStatusCleanPreview() -> some View {
        let theme = populatedTheme()
        let state = GitStatusState()
        state.update(
            repoState: .normal,
            branchName: "main",
            ahead: 0,
            behind: 0,
            syncing: false,
            entries: [],
            toast: nil,
            entryBasePath: "/Users/dev/code/minga",
            lastCommitMessage: "chore: bump dependency versions",
            stashCount: 0
        )

        return GitStatusView(
            state: state,
            theme: theme,
            encoder: nil,
            usesPreviewEagerLayout: PreviewSnapshotPolicy.shouldUseEagerLayout(for: "GitStatusClean")
        )
        .frame(width: 280, height: 600)
        .background(theme.treeBg)
    }

    // MARK: - GitStatusConflict

    private static func gitStatusConflictPreview() -> some View {
        let theme = populatedTheme()
        let state = GitStatusState()
        state.update(
            repoState: .normal,
            branchName: "feat/agent-refactor",
            ahead: 3,
            behind: 5,
            syncing: false,
            entries: gitStatusConflictEntries(),
            toast: nil,
            entryBasePath: "/Users/dev/code/minga",
            lastCommitMessage: "feat(agent): restructure session manager",
            stashCount: 0
        )
        state.commitMessage = ""

        return GitStatusView(
            state: state,
            theme: theme,
            encoder: nil,
            usesPreviewEagerLayout: PreviewSnapshotPolicy.shouldUseEagerLayout(for: "GitStatusConflict")
        )
        .frame(width: 280, height: 600)
        .background(theme.treeBg)
    }

    private static func gitStatusConflictEntries() -> [GitStatusEntry] {
        [
            GitStatusEntry(pathHash: 1, section: .conflicted, status: .conflicted, path: "lib/minga/editor.ex"),
            GitStatusEntry(pathHash: 2, section: .conflicted, status: .conflicted, path: "lib/minga/buffer/document.ex"),
            GitStatusEntry(pathHash: 3, section: .conflicted, status: .conflicted, path: "lib/minga/agent/session_manager.ex"),
            GitStatusEntry(pathHash: 4, section: .staged, status: .modified, path: "mix.exs"),
            GitStatusEntry(pathHash: 5, section: .staged, status: .modified, path: "mix.lock"),
            GitStatusEntry(pathHash: 6, section: .changed, status: .modified, path: "lib/minga/buffer/process.ex"),
            GitStatusEntry(pathHash: 7, section: .changed, status: .modified, path: "test/minga/editor_test.exs"),
        ]
    }

    // MARK: - GitStatusDense

    private static func gitStatusDensePreview() -> some View {
        let theme = populatedTheme()
        let state = GitStatusState()
        state.update(
            repoState: .normal,
            branchName: "feat/full-stack-overhaul",
            ahead: 12,
            behind: 0,
            syncing: false,
            entries: gitStatusDenseEntries(),
            toast: nil,
            entryBasePath: "/Users/dev/code/minga",
            lastCommitMessage: "wip: large refactor across multiple subsystems",
            stashCount: 3
        )
        state.commitMessage = "feat(editor): comprehensive render pipeline overhaul"

        return GitStatusView(
            state: state,
            theme: theme,
            encoder: nil,
            usesPreviewEagerLayout: PreviewSnapshotPolicy.shouldUseEagerLayout(for: "GitStatusDense")
        )
        .frame(width: 280, height: 600)
        .background(theme.treeBg)
    }

    private static func gitStatusDenseEntries() -> [GitStatusEntry] {
        [
            GitStatusEntry(pathHash: 1, section: .staged, status: .modified, path: "lib/minga/editor/render_pipeline/stages/syntax_highlight_pass.ex"),
            GitStatusEntry(pathHash: 2, section: .staged, status: .modified, path: "lib/minga/editor/render_pipeline/stages/diagnostic_underline_pass.ex"),
            GitStatusEntry(pathHash: 3, section: .staged, status: .added, path: "lib/minga/editor/render_pipeline/stages/selection_overlay_compositor.ex"),
            GitStatusEntry(pathHash: 4, section: .staged, status: .added, path: "lib/minga/editor/render_pipeline/pipeline_coordinator.ex"),
            GitStatusEntry(pathHash: 5, section: .staged, status: .deleted, path: "lib/minga/editor/old_render_pipeline.ex"),
            GitStatusEntry(pathHash: 6, section: .staged, status: .renamed, path: "lib/minga/editor/viewport_calculation_service.ex"),
            GitStatusEntry(pathHash: 7, section: .changed, status: .modified, path: "lib/minga/buffer/document.ex"),
            GitStatusEntry(pathHash: 8, section: .changed, status: .modified, path: "lib/minga/buffer/process.ex"),
            GitStatusEntry(pathHash: 9, section: .changed, status: .modified, path: "lib/minga/agent/session_manager.ex"),
            GitStatusEntry(pathHash: 10, section: .changed, status: .modified, path: "macos/Sources/Views/PreviewRegistry.swift"),
            GitStatusEntry(pathHash: 11, section: .changed, status: .modified, path: "macos/Sources/Views/PreviewSnapshotPolicy.swift"),
            GitStatusEntry(pathHash: 12, section: .changed, status: .modified, path: "test/minga/editor/render_pipeline_test.exs"),
            GitStatusEntry(pathHash: 13, section: .changed, status: .modified, path: "test/minga/buffer/document_test.exs"),
            GitStatusEntry(pathHash: 14, section: .untracked, status: .untracked, path: "lib/minga/editor/render_pipeline/frame_scheduler.ex"),
            GitStatusEntry(pathHash: 15, section: .untracked, status: .untracked, path: "lib/minga/editor/render_pipeline/stages/line_number_gutter_renderer.ex"),
            GitStatusEntry(pathHash: 16, section: .untracked, status: .untracked, path: "docs/architecture/render_pipeline_design.md"),
            GitStatusEntry(pathHash: 17, section: .untracked, status: .untracked, path: "test/minga/editor/render_pipeline/stages/syntax_highlight_pass_test.exs"),
            GitStatusEntry(pathHash: 18, section: .untracked, status: .untracked, path: "zig/tests/fixtures/render_pipeline_integration_snapshot.bin"),
        ]
    }

    // MARK: - FileTreeView

    private static func fileTreePreview() -> some View {
        let theme = populatedTheme()

        return fileTreeBodyPreview(theme: theme)
            .frame(width: 280, height: 600)
            .background(theme.treeBg)
    }

    private static func fileTreeBodyPreview(theme: ThemeColors) -> some View {
        FileTreeView(
            fileTreeState: fileTreeState(),
            theme: theme,
            encoder: nil,
            usesPreviewEagerLayout: PreviewSnapshotPolicy.shouldUseEagerLayout(for: "FileTreeView")
        )
    }

    private static func fileTreeState() -> FileTreeState {
        let state = FileTreeState()
        let raw = fileTreeRawEntries()
        state.update(
            version: 1,
            selectedId: "lib/minga/editor.ex",
            focused: true,
            treeWidth: 30,
            rootPath: "/Users/dev/code/minga",
            rawEntries: raw,
            treeState: FileTreeVisibilityState.ready.rawValue
        )
        return state
    }

    // MARK: - FileTreeEmpty

    private static func fileTreeEmptyPreview() -> some View {
        let theme = populatedTheme()
        let state = FileTreeState()
        state.update(
            version: 1,
            selectedId: "",
            focused: false,
            treeWidth: 30,
            rootPath: "/Users/dev/code/minga",
            rawEntries: [],
            treeState: FileTreeVisibilityState.empty.rawValue
        )

        return FileTreeView(
            fileTreeState: state,
            theme: theme,
            encoder: nil,
            usesPreviewEagerLayout: PreviewSnapshotPolicy.shouldUseEagerLayout(for: "FileTreeEmpty")
        )
        .frame(width: 280, height: 600)
        .background(theme.treeBg)
    }

    // MARK: - FileTreeError

    private static func fileTreeErrorPreview() -> some View {
        let theme = populatedTheme()
        let state = FileTreeState()
        state.update(
            version: 1,
            selectedId: "",
            focused: false,
            treeWidth: 30,
            rootPath: "/Users/dev/code/minga",
            rawEntries: [],
            treeState: FileTreeVisibilityState.error.rawValue,
            errorReason: "Permission denied: /Users/dev/code/minga/.git/objects"
        )

        return FileTreeView(
            fileTreeState: state,
            theme: theme,
            encoder: nil,
            usesPreviewEagerLayout: PreviewSnapshotPolicy.shouldUseEagerLayout(for: "FileTreeError")
        )
        .frame(width: 280, height: 600)
        .background(theme.treeBg)
    }

    // MARK: - FileTreeDeep

    private static func fileTreeDeepPreview() -> some View {
        let theme = populatedTheme()
        let state = FileTreeState()
        state.update(
            version: 1,
            selectedId: "lib/minga/editor/render_pipeline/stages/syntax_highlight_pass.ex",
            focused: true,
            treeWidth: 30,
            rootPath: "/Users/dev/code/minga",
            rawEntries: fileTreeDeepRawEntries(),
            treeState: FileTreeVisibilityState.ready.rawValue
        )

        return FileTreeView(
            fileTreeState: state,
            theme: theme,
            encoder: nil,
            usesPreviewEagerLayout: PreviewSnapshotPolicy.shouldUseEagerLayout(for: "FileTreeDeep")
        )
        .frame(width: 280, height: 600)
        .background(theme.treeBg)
    }

    private static func fileTreeDeepRawEntries() -> [Wire.FileTreeEntry] {
        [
            wireFileEntry(id: "lib", name: "lib", path: "/Users/dev/code/minga/lib", relPath: "lib", isDir: true, isExpanded: true, depth: 0, icon: ""),
            wireFileEntry(id: "lib/minga", name: "minga", path: "/Users/dev/code/minga/lib/minga", relPath: "lib/minga", isDir: true, isExpanded: true, depth: 1, icon: ""),
            wireFileEntry(id: "lib/minga/editor", name: "editor", path: "/Users/dev/code/minga/lib/minga/editor", relPath: "lib/minga/editor", isDir: true, isExpanded: true, depth: 2, icon: ""),
            wireFileEntry(id: "lib/minga/editor/render_pipeline", name: "render_pipeline", path: "/Users/dev/code/minga/lib/minga/editor/render_pipeline", relPath: "lib/minga/editor/render_pipeline", isDir: true, isExpanded: true, depth: 3, icon: ""),
            wireFileEntry(id: "lib/minga/editor/render_pipeline/stages", name: "stages", path: "/Users/dev/code/minga/lib/minga/editor/render_pipeline/stages", relPath: "lib/minga/editor/render_pipeline/stages", isDir: true, isExpanded: true, depth: 4, icon: ""),
            wireFileEntry(id: "lib/minga/editor/render_pipeline/stages/syntax_highlight_pass.ex", name: "syntax_highlight_pass.ex", path: "/Users/dev/code/minga/lib/minga/editor/render_pipeline/stages/syntax_highlight_pass.ex", relPath: "lib/minga/editor/render_pipeline/stages/syntax_highlight_pass.ex", isDir: false, depth: 5, icon: "", isActive: true, gitStatus: 1),
            wireFileEntry(id: "lib/minga/editor/render_pipeline/stages/diagnostic_underline_pass.ex", name: "diagnostic_underline_pass.ex", path: "/Users/dev/code/minga/lib/minga/editor/render_pipeline/stages/diagnostic_underline_pass.ex", relPath: "lib/minga/editor/render_pipeline/stages/diagnostic_underline_pass.ex", isDir: false, depth: 5, icon: "", gitStatus: 1),
            wireFileEntry(id: "lib/minga/editor/render_pipeline/stages/line_number_gutter_renderer.ex", name: "line_number_gutter_renderer.ex", path: "/Users/dev/code/minga/lib/minga/editor/render_pipeline/stages/line_number_gutter_renderer.ex", relPath: "lib/minga/editor/render_pipeline/stages/line_number_gutter_renderer.ex", isDir: false, depth: 5, icon: ""),
            wireFileEntry(id: "lib/minga/editor/render_pipeline/stages/selection_overlay_compositor.ex", name: "selection_overlay_compositor.ex", path: "/Users/dev/code/minga/lib/minga/editor/render_pipeline/stages/selection_overlay_compositor.ex", relPath: "lib/minga/editor/render_pipeline/stages/selection_overlay_compositor.ex", isDir: false, depth: 5, icon: "", isDirty: true),
            wireFileEntry(id: "lib/minga/editor/render_pipeline/pipeline_coordinator.ex", name: "pipeline_coordinator.ex", path: "/Users/dev/code/minga/lib/minga/editor/render_pipeline/pipeline_coordinator.ex", relPath: "lib/minga/editor/render_pipeline/pipeline_coordinator.ex", isDir: false, depth: 4, icon: ""),
            wireFileEntry(id: "lib/minga/editor/render_pipeline/frame_scheduler.ex", name: "frame_scheduler.ex", path: "/Users/dev/code/minga/lib/minga/editor/render_pipeline/frame_scheduler.ex", relPath: "lib/minga/editor/render_pipeline/frame_scheduler.ex", isDir: false, depth: 4, icon: ""),
            wireFileEntry(id: "lib/minga/editor/viewport_calculation_service.ex", name: "viewport_calculation_service.ex", path: "/Users/dev/code/minga/lib/minga/editor/viewport_calculation_service.ex", relPath: "lib/minga/editor/viewport_calculation_service.ex", isDir: false, depth: 3, icon: ""),
            wireFileEntry(id: "lib/minga/buffer", name: "buffer", path: "/Users/dev/code/minga/lib/minga/buffer", relPath: "lib/minga/buffer", isDir: true, isExpanded: true, depth: 2, icon: ""),
            wireFileEntry(id: "lib/minga/buffer/document.ex", name: "document.ex", path: "/Users/dev/code/minga/lib/minga/buffer/document.ex", relPath: "lib/minga/buffer/document.ex", isDir: false, depth: 3, icon: ""),
            wireFileEntry(id: "lib/minga/buffer/process.ex", name: "process.ex", path: "/Users/dev/code/minga/lib/minga/buffer/process.ex", relPath: "lib/minga/buffer/process.ex", isDir: false, depth: 3, icon: "", gitStatus: 1),
            wireFileEntry(id: "test", name: "test", path: "/Users/dev/code/minga/test", relPath: "test", isDir: true, isExpanded: false, depth: 0, icon: "", isLastChild: true),
        ]
    }

    private static func fileTreeRawEntries() -> [Wire.FileTreeEntry] {
        [
            wireFileEntry(id: "lib", name: "lib", path: "/Users/dev/code/minga/lib", relPath: "lib", isDir: true, isExpanded: true, depth: 0, icon: ""),
            wireFileEntry(id: "lib/minga", name: "minga", path: "/Users/dev/code/minga/lib/minga", relPath: "lib/minga", isDir: true, isExpanded: true, depth: 1, icon: ""),
            wireFileEntry(id: "lib/minga/editor.ex", name: "editor.ex", path: "/Users/dev/code/minga/lib/minga/editor.ex", relPath: "lib/minga/editor.ex", isDir: false, depth: 2, icon: "", isActive: true, gitStatus: 1),
            wireFileEntry(id: "lib/minga/buffer.ex", name: "buffer.ex", path: "/Users/dev/code/minga/lib/minga/buffer.ex", relPath: "lib/minga/buffer.ex", isDir: false, depth: 2, icon: "", isDirty: true),
            wireFileEntry(id: "lib/minga/buffer", name: "buffer", path: "/Users/dev/code/minga/lib/minga/buffer", relPath: "lib/minga/buffer", isDir: true, isExpanded: true, depth: 2, icon: ""),
            wireFileEntry(id: "lib/minga/buffer/document.ex", name: "document.ex", path: "/Users/dev/code/minga/lib/minga/buffer/document.ex", relPath: "lib/minga/buffer/document.ex", isDir: false, depth: 3, icon: ""),
            wireFileEntry(id: "lib/minga/buffer/process.ex", name: "process.ex", path: "/Users/dev/code/minga/lib/minga/buffer/process.ex", relPath: "lib/minga/buffer/process.ex", isDir: false, depth: 3, icon: "", gitStatus: 1),
            wireFileEntry(id: "lib/minga/mode", name: "mode", path: "/Users/dev/code/minga/lib/minga/mode", relPath: "lib/minga/mode", isDir: true, isExpanded: false, depth: 2, icon: ""),
            wireFileEntry(id: "lib/minga/editor", name: "editor", path: "/Users/dev/code/minga/lib/minga/editor", relPath: "lib/minga/editor", isDir: true, isExpanded: true, depth: 2, icon: ""),
            wireFileEntry(id: "lib/minga/editor/render_pipeline.ex", name: "render_pipeline.ex", path: "/Users/dev/code/minga/lib/minga/editor/render_pipeline.ex", relPath: "lib/minga/editor/render_pipeline.ex", isDir: false, depth: 3, icon: "", gitStatus: 1),
            wireFileEntry(id: "macos", name: "macos", path: "/Users/dev/code/minga/macos", relPath: "macos", isDir: true, isExpanded: true, depth: 0, icon: ""),
            wireFileEntry(id: "macos/Sources", name: "Sources", path: "/Users/dev/code/minga/macos/Sources", relPath: "macos/Sources", isDir: true, isExpanded: true, depth: 1, icon: ""),
            wireFileEntry(id: "macos/Sources/PreviewRegistry.swift", name: "PreviewRegistry.swift", path: "/Users/dev/code/minga/macos/Sources/PreviewRegistry.swift", relPath: "macos/Sources/PreviewRegistry.swift", isDir: false, depth: 2, icon: "", gitStatus: 1),
            wireFileEntry(id: "test", name: "test", path: "/Users/dev/code/minga/test", relPath: "test", isDir: true, isExpanded: false, depth: 0, icon: ""),
            wireFileEntry(id: "zig", name: "zig", path: "/Users/dev/code/minga/zig", relPath: "zig", isDir: true, isExpanded: false, depth: 0, icon: "", isLastChild: true),
        ]
    }

    // MARK: - CompletionOverlay

    private static func completionPreview() -> some View {
        let theme = populatedTheme()

        return completionPopupPreview(theme: theme)
            .frame(width: 400, height: 300)
            .background(theme.editorBg)
    }

    private static func completionPopupPreview(theme: ThemeColors) -> some View {
        let state = CompletionState()
        state.update(
            visible: true, anchorRow: 5, anchorCol: 10, selectedIndex: 1,
            rawItems: [
                Wire.CompletionItem(kind: 7, label: "defmodule", detail: "keyword"),
                Wire.CompletionItem(kind: 7, label: "defstruct", detail: "keyword"),
                Wire.CompletionItem(kind: 7, label: "defdelegate", detail: "keyword"),
                Wire.CompletionItem(kind: 2, label: "def", detail: "keyword"),
                Wire.CompletionItem(kind: 1, label: "Document", detail: "Minga.Buffer.Document"),
            ]
        )

        return CompletionOverlay(state: state, theme: theme, encoder: nil)
    }

    // MARK: - StatusBarView

    private static func statusBarPreview() -> some View {
        statusBarView(width: 800)
    }

    private static func statusBarView(width: CGFloat) -> some View {
        let state = StatusBarState()
        let theme = populatedTheme()

        let leftSegments = [
            Wire.StatusBarSegment(id: 0, kind: "mode", text: " NORMAL ", fgColor: 0x000000, bgColor: 0x7AA2F7, attrs: 1, command: ""),
            Wire.StatusBarSegment(id: 1, kind: "git", text: " main ", fgColor: 0xBB9AF7, bgColor: 0x000000, attrs: 0, command: "git_branch_picker"),
            Wire.StatusBarSegment(id: 2, kind: "filename", text: " editor.ex [+] ", fgColor: 0xC0CAF5, bgColor: 0x000000, attrs: 0, command: "buffer_list"),
        ]
        let rightSegments = [
            Wire.StatusBarSegment(id: 0, kind: "diagnostics", text: " 0 ", fgColor: 0xF7768E, bgColor: 0x000000, attrs: 0, command: "diagnostic_list"),
            Wire.StatusBarSegment(id: 1, kind: "diagnostics", text: " 2 ", fgColor: 0xE0AF68, bgColor: 0x000000, attrs: 0, command: "diagnostic_list"),
            Wire.StatusBarSegment(id: 2, kind: "filetype", text: " Elixir ", fgColor: 0xC0CAF5, bgColor: 0x000000, attrs: 0, command: "set_language"),
            Wire.StatusBarSegment(id: 3, kind: "position", text: " Ln 42, Col 9 ", fgColor: 0xC0CAF5, bgColor: 0x000000, attrs: 0, command: "goto_line"),
        ]

        state.update(from: StatusBarUpdate(
            contentKind: 0, mode: 0, cursorLine: 42, cursorCol: 9,
            lineCount: 1250, flags: 0x02, lspStatus: 1, gitBranch: "main",
            message: "", filetype: "elixir", errorCount: 0, warningCount: 2,
            modelName: "", messageCount: 0, sessionStatus: 0,
            infoCount: 0, hintCount: 0, macroRecording: 0, parserStatus: 1, agentStatus: 0,
            activeToolName: "",
            gitAdded: 0, gitModified: 0, gitDeleted: 0,
            icon: "", iconColorR: 0x88, iconColorG: 0x57, iconColorB: 0xA6, filename: "editor.ex", diagnosticHint: "",
            backgroundSubagentCount: 0, backgroundSubagentLabel: "",
            modelineLeftSegments: leftSegments,
            modelineRightSegments: rightSegments
        ))

        return StatusBarView(state: state, theme: theme, encoder: nil)
            .frame(width: width, height: 28)
            .background(theme.editorBg)
    }

    // MARK: - TabBarView

    private static func tabBarPreview() -> some View {
        tabBarView(width: 800)
    }

    private static func tabBarView(width: CGFloat) -> some View {
        let state = TabBarState()
        let theme = populatedTheme()
        state.update(activeIndex: 1, entries: [
            Wire.TabEntry(id: 1, groupId: 0, isActive: false, isDirty: true, isAgent: false, hasAttention: false, agentStatus: 0, isPinned: true, tintColorRGB: 0, icon: "", label: "editor.ex"),
            Wire.TabEntry(id: 2, groupId: 0, isActive: true, isDirty: false, isAgent: false, hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "", label: "buffer.ex"),
            Wire.TabEntry(id: 3, groupId: 0, isActive: false, isDirty: false, isAgent: false, hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "", label: "document.ex"),
            Wire.TabEntry(id: 4, groupId: 0, isActive: false, isDirty: true, isAgent: false, hasAttention: true, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "", label: "mode.ex"),
        ])

        return TabBarView(tabBarState: state, theme: theme, encoder: nil)
            .frame(width: width, height: 36)
            .background(theme.editorBg)
    }

    // MARK: - NotificationCenterView

    private static func notificationPreview() -> some View {
        let state = NotificationCenterState()
        let theme = populatedTheme()
        let now = UInt64(Date().timeIntervalSince1970)
        state.update(rawNotifications: [
            Wire.EditorNotification(
                id: "notif-1",
                level: .info,
                flags: 0x01,
                createdAt: now,
                updatedAt: now,
                autoDismissMs: nil,
                title: "Extension loaded",
                body: "org-mode v0.3.0 activated for .org files",
                source: "Extensions",
                actions: [
                    Wire.NotificationAction(id: "configure", label: "Configure"),
                ]
            ),
        ])

        return NotificationCenterView(state: state, theme: theme, encoder: nil, bottomInset: 40)
            .frame(width: 800, height: 600)
            .background(theme.editorBg)
    }

    // MARK: - NotificationStack

    private static func notificationStackPreview() -> some View {
        let state = NotificationCenterState()
        let theme = populatedTheme()
        let now = UInt64(Date().timeIntervalSince1970)
        state.update(rawNotifications: [
            Wire.EditorNotification(
                id: "notif-info",
                level: .info,
                flags: 0x01,
                createdAt: now - 120,
                updatedAt: now - 120,
                autoDismissMs: nil,
                title: "Extension loaded",
                body: "org-mode v0.3.0 activated for .org files",
                source: "Extensions",
                actions: [
                    Wire.NotificationAction(id: "configure", label: "Configure"),
                ]
            ),
            Wire.EditorNotification(
                id: "notif-warning",
                level: .warning,
                flags: 0x01,
                createdAt: now - 60,
                updatedAt: now - 60,
                autoDismissMs: nil,
                title: "Formatter unavailable",
                body: "mix format could not be found in PATH. Code formatting is disabled.",
                source: "LSP",
                actions: [
                    Wire.NotificationAction(id: "install", label: "Install"),
                    Wire.NotificationAction(id: "dismiss", label: "Ignore"),
                ]
            ),
            Wire.EditorNotification(
                id: "notif-error",
                level: .error,
                flags: 0x01,
                createdAt: now - 30,
                updatedAt: now - 30,
                autoDismissMs: nil,
                title: "LSP crashed",
                body: "ElixirLS exited unexpectedly (exit code 1). Restart manually or wait for auto-recovery.",
                source: "Language Server",
                actions: [
                    Wire.NotificationAction(id: "restart", label: "Restart"),
                    Wire.NotificationAction(id: "logs", label: "View Logs"),
                ]
            ),
            Wire.EditorNotification(
                id: "notif-progress",
                level: .progress,
                flags: 0x00,
                createdAt: now,
                updatedAt: now,
                autoDismissMs: 5000,
                title: "Indexing workspace",
                body: "Scanning 1,284 files for symbols and references...",
                source: "Parser",
                actions: []
            ),
        ])

        return NotificationCenterView(state: state, theme: theme, encoder: nil, bottomInset: 40)
            .frame(width: 800, height: 600)
            .background(theme.editorBg)
    }

    // MARK: - BottomPanelView

    private static func bottomPanelPreview() -> some View {
        let state = BottomPanelState()
        let theme = populatedTheme()
        state.update(
            visible: true,
            activeTabIndex: 0,
            heightPercent: 30,
            filterPreset: 0,
            tabs: [
                BottomPanelTab(id: 0, tabType: 0x01, name: "Messages"),
                BottomPanelTab(id: 1, tabType: 0x02, name: "Diagnostics"),
                BottomPanelTab(id: 2, tabType: 0x03, name: "Terminal"),
            ]
        )
        populateMessages(state.messagesState)

        return BottomPanelView(state: state, theme: theme, encoder: nil, availableHeight: 600)
            .frame(width: 800, height: 250)
            .background(theme.editorBg)
    }

    private static func bottomPanelEmptyPreview() -> some View {
        let state = BottomPanelState()
        let theme = populatedTheme()
        state.update(
            visible: true,
            activeTabIndex: 0,
            heightPercent: 30,
            filterPreset: 0,
            tabs: [
                BottomPanelTab(id: 0, tabType: 0x01, name: "Messages"),
                BottomPanelTab(id: 1, tabType: 0x02, name: "Diagnostics"),
            ]
        )

        return BottomPanelView(state: state, theme: theme, encoder: nil, availableHeight: 600)
            .frame(width: 800, height: 250)
            .background(theme.editorBg)
    }

    private static func populateMessages(_ state: MessagesContentState) {
        let baseTime: UInt32 = 43200  // 12:00:00
        state.appendEntries([
            Wire.MessageEntry(id: 1, level: 1, subsystem: 0, timestampSecs: baseTime, filePath: "lib/minga/editor.ex", text: "Buffer opened: editor.ex (1250 lines)"),
            Wire.MessageEntry(id: 2, level: 0, subsystem: 1, timestampSecs: baseTime + 1, filePath: "", text: "ElixirLS initialized in 340ms"),
            Wire.MessageEntry(id: 3, level: 2, subsystem: 2, timestampSecs: baseTime + 3, filePath: "lib/minga/buffer/document.ex", text: "Tree-sitter parse timeout (>50ms) on large file"),
            Wire.MessageEntry(id: 4, level: 1, subsystem: 3, timestampSecs: baseTime + 5, filePath: "", text: "Branch switched: feat/preview-host (2 ahead)"),
            Wire.MessageEntry(id: 5, level: 3, subsystem: 4, timestampSecs: baseTime + 8, filePath: "", text: "Metal shader compilation failed: fragment_main"),
            Wire.MessageEntry(id: 6, level: 1, subsystem: 5, timestampSecs: baseTime + 12, filePath: "", text: "Agent session started (claude-sonnet-4, medium thinking)"),
            Wire.MessageEntry(id: 7, level: 0, subsystem: 6, timestampSecs: baseTime + 14, filePath: "", text: "TUI grid resized to 112x36"),
            Wire.MessageEntry(id: 8, level: 2, subsystem: 7, timestampSecs: baseTime + 18, filePath: "", text: "SwiftUI layout cycle detected in NotificationCard"),
        ])
    }

    // MARK: - SettingsView

    private static func settingsPreview() -> some View {
        let appState = AppState()
        let encoder = previewEncoder()
        appState.encoder = encoder
        appState.gui.settingsState.encoder = encoder

        // Populate settings state to skip the loading spinner
        let settings = appState.gui.settingsState
        settings.isLoading = false
        settings.currentThemeName = "doom_one"
        settings.fontFamily = "Menlo"
        settings.fontSize = 13
        settings.fontWeight = "regular"
        settings.fontLigatures = true
        settings.tabWidth = 2
        settings.lineNumbers = .absolute
        settings.wordWrap = false
        settings.cursorBlink = true
        settings.cursorline = true
        settings.themePreviews = [
            Wire.ThemePreview(name: "Doom One", atom: "doom_one", editorBg: 0x282C34, editorFg: 0xBBC2CF, accent: 0x51AFEF),
            Wire.ThemePreview(name: "Tokyo Night", atom: "tokyo_night", editorBg: 0x1A1B26, editorFg: 0xC0CAF5, accent: 0x7AA2F7),
            Wire.ThemePreview(name: "Catppuccin Mocha", atom: "catppuccin_mocha", editorBg: 0x1E1E2E, editorFg: 0xCDD6F4, accent: 0x89B4FA),
            Wire.ThemePreview(name: "Solarized Dark", atom: "solarized_dark", editorBg: 0x002B36, editorFg: 0x839496, accent: 0x268BD2),
            Wire.ThemePreview(name: "Gruvbox Dark", atom: "gruvbox_dark", editorBg: 0x282828, editorFg: 0xEBDBB2, accent: 0xFE8019),
            Wire.ThemePreview(name: "Nord", atom: "nord", editorBg: 0x2E3440, editorFg: 0xD8DEE9, accent: 0x88C0D0),
        ]

        return SettingsView(appState: appState)
            .frame(width: 600, height: 480)
    }

    // MARK: - ToolManagerView

    private static func toolManagerPreview() -> some View {
        let state = ToolManagerState()
        let theme = populatedTheme()
        state.update(
            visible: true,
            filter: .all,
            selectedIndex: 1,
            tools: [
                ToolEntry(id: "elixir_ls", name: "elixir_ls", label: "ElixirLS", description: "Elixir language server with debugger support", category: .lspServer, status: .installed, method: .githubRelease, languages: ["Elixir", "HEEx"], version: "0.22.1", homepage: "", provides: ["elixir-ls"], errorReason: ""),
                ToolEntry(id: "lua_ls", name: "lua_ls", label: "Lua Language Server", description: "Lua language server for Neovim configs and scripts", category: .lspServer, status: .notInstalled, method: .githubRelease, languages: ["Lua"], version: "", homepage: "", provides: ["lua-language-server"], errorReason: ""),
                ToolEntry(id: "prettier", name: "prettier", label: "Prettier", description: "Opinionated code formatter for web languages", category: .formatter, status: .installed, method: .npm, languages: ["TypeScript", "JavaScript", "CSS", "HTML"], version: "3.2.5", homepage: "", provides: ["prettier"], errorReason: ""),
                ToolEntry(id: "ruff", name: "ruff", label: "Ruff", description: "Extremely fast Python linter and formatter", category: .linter, status: .installing, method: .pip, languages: ["Python"], version: "", homepage: "", provides: ["ruff"], errorReason: ""),
                ToolEntry(id: "rust_analyzer", name: "rust_analyzer", label: "rust-analyzer", description: "Rust language server with full IDE features", category: .lspServer, status: .updateAvailable, method: .githubRelease, languages: ["Rust"], version: "2024.03.04", homepage: "", provides: ["rust-analyzer"], errorReason: ""),
                ToolEntry(id: "codelldb", name: "codelldb", label: "CodeLLDB", description: "LLDB-based debugger for C, C++, and Rust", category: .debugger, status: .failed, method: .githubRelease, languages: ["C", "C++", "Rust"], version: "", homepage: "", provides: ["codelldb"], errorReason: "Error: GitHub API rate limit exceeded. Try again in 42 minutes."),
            ]
        )

        return ToolManagerView(state: state, theme: theme, encoder: nil)
            .frame(width: 800, height: 600)
            .background(theme.editorBg)
    }

    // MARK: - ObservatoryView

    private static func observatoryPreview() -> some View {
        let state = ObservatoryState()
        let theme = populatedTheme()
        state.update(visible: true, rawNodes: [
            Wire.ObservatoryNode(pid: "<0.100.0>", parentPid: "", name: "Elixir.Minga.Application", processClass: 0, depth: 0, memory: 184_320, messageQueueLen: 0, reductions: 91_204, sparkline: [0.12, 0.18, 0.13, 0.22, 0.19, 0.24]),
            Wire.ObservatoryNode(pid: "<0.101.0>", parentPid: "<0.100.0>", name: "Elixir.Minga.Foundation.Supervisor", processClass: 0, depth: 1, memory: 96_448, messageQueueLen: 0, reductions: 40_112, sparkline: [0.10, 0.12, 0.09, 0.11, 0.10, 0.13]),
            Wire.ObservatoryNode(pid: "<0.102.0>", parentPid: "<0.101.0>", name: "Elixir.Minga.Events", processClass: 4, depth: 2, memory: 58_912, messageQueueLen: 1, reductions: 18_901, sparkline: [0.08, 0.20, 0.12, 0.18, 0.16, 0.19]),
            Wire.ObservatoryNode(pid: "<0.120.0>", parentPid: "<0.100.0>", name: "Elixir.Minga.Editor.Supervisor", processClass: 0, depth: 1, memory: 122_880, messageQueueLen: 0, reductions: 52_772, sparkline: [0.18, 0.16, 0.20, 0.21, 0.19, 0.24]),
            Wire.ObservatoryNode(pid: "<0.121.0>", parentPid: "<0.120.0>", name: "Elixir.MingaEditor", processClass: 5, depth: 2, memory: 214_016, messageQueueLen: 7, reductions: 182_394, sparkline: [0.24, 0.42, 0.32, 0.54, 0.37, 0.49]),
            Wire.ObservatoryNode(pid: "<0.122.0>", parentPid: "<0.120.0>", name: "Elixir.Minga.Buffer.Process", processClass: 1, depth: 2, memory: 73_728, messageQueueLen: 0, reductions: 22_140, sparkline: [0.10, 0.14, 0.11, 0.15, 0.12, 0.16]),
            Wire.ObservatoryNode(pid: "<0.130.0>", parentPid: "<0.100.0>", name: "Elixir.MingaAgent.SessionManager", processClass: 2, depth: 1, memory: 308_224, messageQueueLen: 14, reductions: 241_006, sparkline: [0.38, 0.48, 0.62, 0.57, 0.72, 0.66]),
            Wire.ObservatoryNode(pid: "<0.140.0>", parentPid: "<0.100.0>", name: "Elixir.Minga.LSP.Client", processClass: 3, depth: 1, memory: 155_648, messageQueueLen: 2, reductions: 88_440, sparkline: [0.16, 0.18, 0.26, 0.22, 0.28, 0.24]),
        ])

        return ObservatoryView(state: state, theme: theme, encoder: nil)
            .frame(width: 320, height: 640)
            .background(theme.treeBg)
    }

    // MARK: - AgentChatView

    private static func agentChatPreview() -> some View {
        agentChatView(width: 760, height: 600)
    }

    private static func agentChatView(width: CGFloat, height: CGFloat) -> some View {
        let state = AgentChatState()
        let theme = populatedTheme()
        state.update(
            visible: true,
            status: 2,
            model: "anthropic:claude-sonnet-4",
            thinkingLevel: "medium",
            prompt: "Make the notification card use the configured theme",
            promptLineCount: 1,
            promptCursorLine: 0,
            promptCursorCol: 52,
            promptVimMode: 1,
            promptVisibleRows: 1,
            promptCompletion: nil,
            helpVisible: false,
            helpGroups: [],
            rawMessages: agentChatMessages()
        )

        return AgentChatView(state: state, theme: theme, isInsertMode: true, encoder: nil, cellHeight: 18)
            .frame(width: width, height: height)
            .background(theme.agentPanelBg)
    }

    private static func agentChatMessages() -> [Wire.ChatMessage] {
        [
            Wire.ChatMessage(beamId: 1, content: .user(text: "The notification card should use our configured theme.")),
            Wire.ChatMessage(beamId: 2, content: .thinking(text: "Inspecting the SwiftUI chrome path and checking whether the notification background bypasses ThemeColors.", collapsed: false)),
            Wire.ChatMessage(beamId: 3, content: .toolCall(name: "read", summary: "macos/Sources/Views/NotificationCenterView.swift", status: 1, isError: false, collapsed: false, autoApprovedScope: 0, durationMs: 148, result: "Found .ultraThinMaterial on the card background.")),
            Wire.ChatMessage(beamId: 4, content: .assistant(text: "I’ll switch the card to theme.popupBg and keep severity as a themed border, so light and dark themes stay under BEAM control.")),
            Wire.ChatMessage(beamId: 5, content: .styledToolCall(name: "edit", summary: "Apply notification theme polish", status: 1, isError: false, collapsed: false, autoApprovedScope: 0, durationMs: 93, resultLines: [[styledRun(".background(theme.popupBg", 0x98, 0xBE, 0x65, bold: true), styledRun(", in: RoundedRectangle(cornerRadius: 10))", 0xBB, 0xC2, 0xCF)]])),
            Wire.ChatMessage(beamId: 6, content: .usage(input: 128_000, output: 3_840, cacheRead: 64_000, cacheWrite: 1_280, costMicros: 431_000)),
        ]
    }

    private static func styledRun(_ text: String, _ r: UInt8, _ g: UInt8, _ b: UInt8, bold: Bool = false) -> Wire.StyledTextRun {
        Wire.StyledTextRun(text: text, fgR: r, fgG: g, fgB: b, bgR: 0, bgG: 0, bgB: 0, bold: bold, italic: false, underline: false)
    }

    // MARK: - PickerOverlay

    private static func pickerPreview() -> some View {
        let theme = populatedTheme()
        let state = PickerState()
        state.update(
            visible: true,
            selectedIndex: 1,
            filteredCount: 5,
            totalCount: 42,
            markedCount: 0,
            title: "Find File",
            query: "edit",
            hasPreview: false,
            rawItems: [
                Wire.PickerItem(iconColor: 0x98BE65, flags: 0, label: "\u{f0e7}editor.ex", description: "lib/minga/editor.ex", annotation: "", matchPositions: [1, 2, 3, 4]),
                Wire.PickerItem(iconColor: 0x98BE65, flags: 0x01, label: "\u{f0e7}editor_test.exs", description: "test/minga/editor_test.exs", annotation: "test", matchPositions: [1, 2, 3, 4]),
                Wire.PickerItem(iconColor: 0x51AFEF, flags: 0, label: "\u{f0e7}EditorNSView.swift", description: "macos/Sources/EditorNSView.swift", annotation: "swift", matchPositions: [1, 2, 3, 4]),
                Wire.PickerItem(iconColor: 0xECBE7B, flags: 0, label: "\u{f085}edit_mode.ex", description: "lib/minga/mode/edit_mode.ex", annotation: "", matchPositions: [1, 2, 3, 4]),
                Wire.PickerItem(iconColor: 0xC678DD, flags: 0, label: "\u{f0e7}editor_config.ex", description: "lib/minga/editor/config.ex", annotation: "", matchPositions: [1, 2, 3, 4]),
            ],
            actionMenu: nil,
            modePrefix: ""
        )

        return ZStack {
            theme.editorBg
            PickerOverlay(state: state, theme: theme, encoder: nil)
        }
        .frame(width: 600, height: 400)
        .clipped()
    }

    // MARK: - MinibufferView

    private static func minibufferPreview() -> some View {
        let theme = populatedTheme()
        let state = MinibufferState()
        state.update(
            visible: true,
            mode: MinibufferMode.command.rawValue,
            cursorPos: 7,
            prompt: "M-x ",
            input: "org-mod",
            context: "",
            selectedIndex: 0,
            totalCandidates: 23,
            rawCandidates: [
                Wire.MinibufferCandidate(matchScore: 95, label: "org-mode", description: "Toggle Org major mode", annotation: "SPC m o", matchPositions: [0, 1, 2, 3, 4, 5, 6]),
                Wire.MinibufferCandidate(matchScore: 80, label: "org-mode-restart", description: "Restart Org mode parser", annotation: "", matchPositions: [0, 1, 2, 3, 4, 5, 6]),
                Wire.MinibufferCandidate(matchScore: 72, label: "org-modernize", description: "Modernize Org buffer syntax", annotation: "", matchPositions: [0, 1, 2, 3, 4, 5, 6, 8]),
            ]
        )

        return MinibufferView(state: state, theme: theme, encoder: nil)
            .frame(width: 600, height: 140)
            .background(theme.editorBg)
    }

    // MARK: - WhichKeyOverlay

    private static func whichKeyPreview() -> some View {
        let theme = populatedTheme()
        let state = WhichKeyState()
        state.update(
            visible: true,
            prefix: "SPC",
            page: 0,
            pageCount: 1,
            rawBindings: [
                Wire.WhichKeyBinding(kind: 1, key: "f", description: "+file", icon: ""),
                Wire.WhichKeyBinding(kind: 1, key: "b", description: "+buffer", icon: ""),
                Wire.WhichKeyBinding(kind: 1, key: "w", description: "+window", icon: ""),
                Wire.WhichKeyBinding(kind: 1, key: "g", description: "+git", icon: ""),
                Wire.WhichKeyBinding(kind: 1, key: "s", description: "+search", icon: ""),
                Wire.WhichKeyBinding(kind: 0, key: ":", description: "M-x command", icon: ""),
                Wire.WhichKeyBinding(kind: 0, key: ".", description: "repeat", icon: ""),
                Wire.WhichKeyBinding(kind: 0, key: "/", description: "search project", icon: ""),
                Wire.WhichKeyBinding(kind: 1, key: "p", description: "+project", icon: ""),
                Wire.WhichKeyBinding(kind: 1, key: "t", description: "+toggle", icon: ""),
                Wire.WhichKeyBinding(kind: 1, key: "c", description: "+code", icon: ""),
                Wire.WhichKeyBinding(kind: 0, key: "e", description: "file tree", icon: ""),
            ]
        )

        return WhichKeyOverlay(state: state, theme: theme)
            .frame(width: 520, height: 300)
            .background(theme.editorBg)
    }

    // MARK: - WhichKeyPaged

    private static func whichKeyPagedPreview() -> some View {
        let theme = populatedTheme()
        let state = WhichKeyState()
        state.update(
            visible: true,
            prefix: "SPC g",
            page: 1,
            pageCount: 3,
            rawBindings: [
                Wire.WhichKeyBinding(kind: 0, key: "s", description: "stage file", icon: ""),
                Wire.WhichKeyBinding(kind: 0, key: "u", description: "unstage file", icon: ""),
                Wire.WhichKeyBinding(kind: 0, key: "c", description: "commit", icon: ""),
                Wire.WhichKeyBinding(kind: 0, key: "p", description: "push", icon: ""),
                Wire.WhichKeyBinding(kind: 0, key: "f", description: "fetch", icon: ""),
                Wire.WhichKeyBinding(kind: 0, key: "d", description: "diff", icon: ""),
                Wire.WhichKeyBinding(kind: 1, key: "b", description: "+branch", icon: ""),
                Wire.WhichKeyBinding(kind: 1, key: "r", description: "+rebase", icon: ""),
                Wire.WhichKeyBinding(kind: 0, key: "l", description: "log", icon: ""),
                Wire.WhichKeyBinding(kind: 0, key: "z", description: "stash", icon: ""),
            ]
        )

        return WhichKeyOverlay(state: state, theme: theme)
            .frame(width: 520, height: 300)
            .background(theme.editorBg)
    }

    // MARK: - SearchToolbar

    private static func searchToolbarPreview() -> some View {
        let theme = populatedTheme()
        let state = SearchState()
        state.update(active: true, matchCount: 12, currentIndex: 3, flags: 0)

        return SearchToolbar(searchState: state, theme: theme, encoder: nil)
            .frame(width: 800, height: 40)
            .background(theme.editorBg)
    }

    // MARK: - HoverPopupOverlay

    private static func hoverPopupPreview() -> some View {
        let theme = populatedTheme()
        let state = HoverPopupState()
        state.update(
            visible: true, anchorRow: 8, anchorCol: 4,
            focused: false, scrollOffset: 0,
            rawLines: [
                Wire.HoverLine(lineType: .header, segments: [
                    Wire.HoverSegment(style: .header2, fgColor: nil, flags: 0, text: "Buffer.open/1"),
                ]),
                Wire.HoverLine(lineType: .empty, segments: []),
                Wire.HoverLine(lineType: .text, segments: [
                    Wire.HoverSegment(style: .plain, fgColor: nil, flags: 0, text: "Opens a file from disk and returns a managed buffer process."),
                ]),
                Wire.HoverLine(lineType: .text, segments: [
                    Wire.HoverSegment(style: .plain, fgColor: nil, flags: 0, text: "The buffer is registered under the given path and will be reused"),
                ]),
                Wire.HoverLine(lineType: .text, segments: [
                    Wire.HoverSegment(style: .plain, fgColor: nil, flags: 0, text: "on subsequent calls with the same path."),
                ]),
                Wire.HoverLine(lineType: .empty, segments: []),
                Wire.HoverLine(lineType: .codeHeader, segments: [
                    Wire.HoverSegment(style: .codeBlock, fgColor: nil, flags: 0, text: "elixir"),
                ]),
                Wire.HoverLine(lineType: .code, segments: [
                    Wire.HoverSegment(style: .syntaxHighlighted, fgColor: 0xC678DD, flags: 1, text: "@spec "),
                    Wire.HoverSegment(style: .syntaxHighlighted, fgColor: 0x61AFEF, flags: 0, text: "open"),
                    Wire.HoverSegment(style: .syntaxHighlighted, fgColor: 0xBBC2CF, flags: 0, text: "("),
                    Wire.HoverSegment(style: .syntaxHighlighted, fgColor: 0xE5C07B, flags: 0, text: "String.t()"),
                    Wire.HoverSegment(style: .syntaxHighlighted, fgColor: 0xBBC2CF, flags: 0, text: ") :: "),
                    Wire.HoverSegment(style: .syntaxHighlighted, fgColor: 0xE5C07B, flags: 0, text: "{:ok, pid()}"),
                ]),
                Wire.HoverLine(lineType: .empty, segments: []),
                Wire.HoverLine(lineType: .blockquote, segments: [
                    Wire.HoverSegment(style: .blockquote, fgColor: nil, flags: 0, text: "Since: v0.4.0"),
                ]),
            ]
        )

        return HoverPopupOverlay(state: state, theme: theme, cellWidth: 8, cellHeight: 18, viewportHeight: 300, viewportWidth: 500, encoder: nil)
            .frame(width: 500, height: 300)
            .background(theme.editorBg)
    }

    // MARK: - SignatureHelpOverlay

    private static func signatureHelpPreview() -> some View {
        let theme = populatedTheme()
        let state = SignatureHelpState()
        state.update(
            visible: true, anchorRow: 8, anchorCol: 6,
            activeSignature: 0, activeParameter: 1,
            rawSignatures: [
                Wire.Signature(
                    label: "GenServer.start_link(module, init_arg, options)",
                    documentation: "Starts a GenServer process linked to the current process.",
                    parameters: [
                        Wire.SignatureParameter(label: "module", documentation: "The module implementing the GenServer callbacks."),
                        Wire.SignatureParameter(label: "init_arg", documentation: "The argument passed to init/1."),
                        Wire.SignatureParameter(label: "options", documentation: "Options such as :name, :timeout, and :hibernate_after."),
                    ]
                ),
            ]
        )

        return SignatureHelpOverlay(state: state, theme: theme, cellWidth: 8, cellHeight: 18, viewportHeight: 200, viewportWidth: 500)
            .frame(width: 500, height: 200)
            .background(theme.editorBg)
    }

    // MARK: - DiagnosticsEditorView

    private static func diagnosticsEditorPreview() -> some View {
        previewDiagnosticsChromeView(failureMessage: "DiagnosticsEditorView could not initialize the production editor renderer.")
    }

    @ViewBuilder
    private static func previewDiagnosticsChromeView(failureMessage: String) -> some View {
        let size = PreviewSnapshotPolicy.size(named: "DiagnosticsEditorView")

        if let appState = diagnosticsPreviewAppState() {
            ContentView(appState: appState)
                .frame(width: size.width, height: size.height)
        } else {
            previewFailureView(message: failureMessage)
                .frame(width: size.width, height: size.height)
        }
    }

    private static func diagnosticsPreviewAppState() -> AppState? {
        let appState = AppState()
        appState.windowTitle = "Minga"
        appState.windowBgIsDark = true
        appState.hasReceivedFirstFrame = true
        appState.trafficLightMidY = 14

        let encoder = previewEncoder()
        appState.encoder = encoder
        appState.gui.settingsState.encoder = encoder

        populateFileTree(appState.gui.fileTreeState)
        populateGitStatus(appState.gui.gitStatusState)
        appState.gui.gitStatusState.hide()
        populateTabBar(appState.gui.tabBarState)
        appState.gui.breadcrumbState.update(segments: ["lib", "minga", "editor.ex"])
        appState.gui.statusBarState.update(from: previewStatusBarUpdate(agentVisible: false))

        guard let editorNSView = previewDiagnosticsEditorNSView(appState: appState, encoder: encoder) else { return nil }
        appState.editorNSView = editorNSView
        return appState
    }

    private static func previewDiagnosticsEditorNSView(appState: AppState, encoder: ProtocolEncoder) -> EditorNSView? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let fontFace = FontFace(name: "Menlo", size: 13, scale: scale)
        let fontManager = FontManager(name: "Menlo", size: 13, scale: scale)
        guard let renderer = CoreTextMetalRenderer() else { return nil }
        renderer.setupRenderers(fontManager: fontManager)

        let dispatcher = CommandDispatcher(cols: 112, rows: 36, guiState: appState.gui)
        dispatcher.fontManager = fontManager
        populateDiagnosticsEditorFrame(dispatcher: dispatcher, guiState: appState.gui)

        let nsView = EditorNSView(encoder: encoder, fontFace: fontFace, dispatcher: dispatcher, coreTextRenderer: renderer, fontManager: fontManager)
        nsView.guiState = appState.gui
        nsView.statusBarState = appState.gui.statusBarState
        nsView.renderFrame()
        return nsView
    }

    private static func populateDiagnosticsEditorFrame(dispatcher: CommandDispatcher, guiState: GUIState) {
        dispatcher.frameState.defaultBg = 0x282C34
        dispatcher.frameState.gutterCol = 4
        dispatcher.frameState.gutterSeparatorColor = 0x3E4452
        dispatcher.frameState.cursorRow = 5
        dispatcher.frameState.cursorCol = 12
        dispatcher.frameState.cursorShape = .beam
        dispatcher.frameState.cursorlineRow = 5
        dispatcher.frameState.cursorlineBg = 0x2C323C
        dispatcher.frameState.totalLineCount = 1250
        dispatcher.frameState.viewportTopLine = 38
        dispatcher.frameState.scrollIndicatorColor = 0x5C6370
        dispatcher.frameState.windowGutters[1] = Wire.WindowGutter(
            windowId: 1,
            contentRow: 1,
            contentCol: 0,
            contentHeight: 22,
            isActive: true,
            contentWidth: 108,
            cursorLine: 42,
            lineNumberStyle: .absolute,
            lineNumberWidth: 3,
            signColWidth: 1,
            entries: previewDiagnosticsGutterEntries()
        )
        guiState.windowContents[1] = GUIWindowContent(
            windowId: 1,
            fullRefresh: true,
            cursorVisible: true,
            cursorRow: 5,
            cursorCol: 12,
            cursorShape: .beam,
            rows: previewEditorRows(),
            selection: nil,
            searchMatches: [],
            diagnosticUnderlines: [
                GUIDiagnosticUnderline(startRow: 4, startCol: 20, endRow: 4, endCol: 31, severity: .error),
                GUIDiagnosticUnderline(startRow: 5, startCol: 4, endRow: 5, endCol: 10, severity: .warning),
                GUIDiagnosticUnderline(startRow: 1, startCol: 8, endRow: 1, endCol: 20, severity: .info),
            ],
            documentHighlights: [],
            lineAnnotations: []
        )
    }

    private static func previewDiagnosticsGutterEntries() -> [Wire.GutterEntry] {
        (38...59).map { line in
            let sign: Wire.GutterSignType
            switch line {
            case 42: sign = .diagError
            case 43: sign = .diagWarning
            case 39: sign = .diagInfo
            case 47: sign = .gitModified
            default: sign = .none
            }
            return Wire.GutterEntry(bufLine: UInt32(line), displayType: .normal, signType: sign)
        }
    }

    // MARK: - TabBarOverflow

    private static func tabBarOverflowPreview() -> some View {
        tabBarOverflowView(width: 1200)
    }

    private static func tabBarOverflowView(width: CGFloat) -> some View {
        let state = TabBarState()
        let theme = populatedTheme()
        state.update(activeIndex: 3, entries: [
            Wire.TabEntry(id: 1, groupId: 0, isActive: false, isDirty: false, isAgent: false, hasAttention: false, agentStatus: 0, isPinned: true, tintColorRGB: 0, icon: "", label: "editor.ex"),
            Wire.TabEntry(id: 2, groupId: 0, isActive: false, isDirty: true, isAgent: false, hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "", label: "buffer.ex"),
            Wire.TabEntry(id: 3, groupId: 0, isActive: false, isDirty: false, isAgent: false, hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "", label: "document.ex"),
            Wire.TabEntry(id: 4, groupId: 0, isActive: true, isDirty: false, isAgent: false, hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "", label: "render_pipeline_integration_test.exs"),
            Wire.TabEntry(id: 5, groupId: 0, isActive: false, isDirty: true, isAgent: false, hasAttention: true, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "", label: "protocol_decoder_compatibility_test.exs"),
            Wire.TabEntry(id: 6, groupId: 0, isActive: false, isDirty: false, isAgent: false, hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "", label: "mode.ex"),
            Wire.TabEntry(id: 7, groupId: 0, isActive: false, isDirty: false, isAgent: true, hasAttention: false, agentStatus: 2, isPinned: false, tintColorRGB: 0, icon: "", label: "Agent"),
            Wire.TabEntry(id: 8, groupId: 0, isActive: false, isDirty: true, isAgent: false, hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "", label: "core_text_metal_renderer.swift"),
            Wire.TabEntry(id: 9, groupId: 0, isActive: false, isDirty: false, isAgent: false, hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "", label: "preview_snapshot_policy.swift"),
            Wire.TabEntry(id: 10, groupId: 0, isActive: false, isDirty: false, isAgent: false, hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "", label: "application_supervisor_configuration.ex"),
        ])

        return TabBarView(tabBarState: state, theme: theme, encoder: nil)
            .frame(width: width, height: 36)
            .background(theme.editorBg)
    }

    // MARK: - AgentChatStreaming

    private static func agentChatStreamingPreview() -> some View {
        let state = AgentChatState()
        let theme = populatedTheme()
        state.update(
            visible: true,
            status: 1,
            model: "anthropic:claude-sonnet-4",
            thinkingLevel: "medium",
            prompt: "",
            promptLineCount: 1,
            promptCursorLine: 0,
            promptCursorCol: 0,
            promptVimMode: 0,
            promptVisibleRows: 1,
            promptCompletion: nil,
            helpVisible: false,
            helpGroups: [],
            rawMessages: [
                Wire.ChatMessage(beamId: 1, content: .user(text: "Refactor the buffer module to separate read and write concerns into distinct GenServer processes.")),
                Wire.ChatMessage(beamId: 2, content: .thinking(text: "The buffer module currently mixes read-only queries (content, line count, syntax tree) with mutation operations (insert, delete, undo/redo). Splitting these would let readers proceed without blocking on writes, improving latency for completions and diagnostics that only need a snapshot.", collapsed: false)),
                Wire.ChatMessage(beamId: 3, content: .toolCall(name: "read", summary: "lib/minga/buffer/process.ex", status: 0, isError: false, collapsed: true, autoApprovedScope: 1, durationMs: 0, result: "")),
            ]
        )

        return AgentChatView(state: state, theme: theme, isInsertMode: false, encoder: nil, cellHeight: 18)
            .frame(width: 760, height: 600)
            .background(theme.agentPanelBg)
    }

    // MARK: - AgentChatApproval

    private static func agentChatApprovalPreview() -> some View {
        let state = AgentChatState()
        let theme = populatedTheme()
        state.update(
            visible: true,
            status: 2,
            model: "anthropic:claude-sonnet-4",
            thinkingLevel: "medium",
            prompt: "",
            promptLineCount: 1,
            promptCursorLine: 0,
            promptCursorCol: 0,
            promptVimMode: 0,
            promptVisibleRows: 1,
            promptCompletion: nil,
            helpVisible: false,
            helpGroups: [],
            rawMessages: [
                Wire.ChatMessage(beamId: 1, content: .user(text: "Run the full test suite and fix any failures.")),
                Wire.ChatMessage(beamId: 2, content: .thinking(text: "I'll run the tests first to identify failures before making changes.", collapsed: true)),
                Wire.ChatMessage(beamId: 3, content: .toolCall(name: "read", summary: "mix.exs", status: 1, isError: false, collapsed: true, autoApprovedScope: 1, durationMs: 62, result: "Read 48 lines")),
                Wire.ChatMessage(beamId: 4, content: .approvalToolCall(name: "shell", summary: "mix test --trace", toolCallId: "tc-approve-1", previewKind: 2, previewLines: ["mix test --trace", "", "Runs the full test suite with verbose output.", "This command may take several minutes."])),
            ]
        )

        return AgentChatView(state: state, theme: theme, isInsertMode: false, encoder: nil, cellHeight: 18)
            .frame(width: 760, height: 600)
            .background(theme.agentPanelBg)
    }

    // MARK: - AgentChatError

    private static func agentChatErrorPreview() -> some View {
        let state = AgentChatState()
        let theme = populatedTheme()
        state.update(
            visible: true,
            status: 3,
            model: "anthropic:claude-sonnet-4",
            thinkingLevel: "medium",
            prompt: "",
            promptLineCount: 1,
            promptCursorLine: 0,
            promptCursorCol: 0,
            promptVimMode: 0,
            promptVisibleRows: 1,
            promptCompletion: nil,
            helpVisible: false,
            helpGroups: [],
            rawMessages: [
                Wire.ChatMessage(beamId: 1, content: .user(text: "Deploy the staging environment.")),
                Wire.ChatMessage(beamId: 2, content: .thinking(text: "I'll check the deployment configuration and run the staging deploy script.", collapsed: true)),
                Wire.ChatMessage(beamId: 3, content: .toolCall(name: "shell", summary: "mix release --env=staging", status: 1, isError: false, collapsed: true, autoApprovedScope: 2, durationMs: 4200, result: "Release built successfully")),
                Wire.ChatMessage(beamId: 4, content: .toolCall(name: "shell", summary: "scripts/deploy.sh staging", status: 2, isError: true, collapsed: false, autoApprovedScope: 2, durationMs: 12400, result: "Error: SSH connection to staging-01.internal timed out after 30s\nexit code: 1")),
                Wire.ChatMessage(beamId: 5, content: .system(text: "Tool execution failed. The deploy script could not reach the staging host.", isError: true)),
                Wire.ChatMessage(beamId: 6, content: .assistant(text: "The deploy failed because the staging host is unreachable. Check that the VPN is connected and that staging-01.internal is responding to SSH on port 22.")),
            ]
        )

        return AgentChatView(state: state, theme: theme, isInsertMode: false, encoder: nil, cellHeight: 18)
            .frame(width: 760, height: 600)
            .background(theme.agentPanelBg)
    }

    // MARK: - AgentChatCompletion

    private static func agentChatCompletionPreview() -> some View {
        let state = AgentChatState()
        let theme = populatedTheme()
        state.update(
            visible: true,
            status: 0,
            model: "anthropic:claude-sonnet-4",
            thinkingLevel: "medium",
            prompt: "/",
            promptLineCount: 1,
            promptCursorLine: 0,
            promptCursorCol: 1,
            promptVimMode: 1,
            promptVisibleRows: 1,
            promptCompletion: Wire.PromptCompletion(
                type: 1,
                selected: 1,
                anchorLine: 0,
                anchorCol: 0,
                candidates: [
                    (name: "/clear", description: "Clear conversation history"),
                    (name: "/compact", description: "Summarize and compact context"),
                    (name: "/cost", description: "Show session cost breakdown"),
                    (name: "/help", description: "Show available commands"),
                    (name: "/model", description: "Switch the active model"),
                    (name: "/thinking", description: "Set thinking level"),
                ]
            ),
            helpVisible: false,
            helpGroups: [],
            rawMessages: [
                Wire.ChatMessage(beamId: 1, content: .system(text: "Agent session started.", isError: false)),
            ]
        )

        return AgentChatView(state: state, theme: theme, isInsertMode: true, encoder: nil, cellHeight: 18)
            .frame(width: 760, height: 600)
            .background(theme.agentPanelBg)
    }

    // MARK: - AgentChatSummary

    private static func agentChatSummaryPreview() -> some View {
        let state = AgentChatState()
        let theme = populatedTheme()
        state.update(
            visible: true,
            status: 0,
            model: "anthropic:claude-sonnet-4",
            thinkingLevel: "medium",
            prompt: "",
            promptLineCount: 1,
            promptCursorLine: 0,
            promptCursorCol: 0,
            promptVimMode: 0,
            promptVisibleRows: 1,
            promptCompletion: nil,
            helpVisible: false,
            helpGroups: [],
            rawMessages: [
                Wire.ChatMessage(beamId: 1, content: .user(text: "Add input validation to the user registration form.")),
                Wire.ChatMessage(beamId: 2, content: .thinking(text: "I need to add validation for email format, password strength, and required fields.", collapsed: true)),
                Wire.ChatMessage(beamId: 3, content: .toolCall(name: "read", summary: "lib/minga/accounts/registration.ex", status: 1, isError: false, collapsed: true, autoApprovedScope: 1, durationMs: 95, result: "Read 82 lines")),
                Wire.ChatMessage(beamId: 4, content: .toolCall(name: "edit", summary: "Add changeset validations", status: 1, isError: false, collapsed: true, autoApprovedScope: 1, durationMs: 210, result: "Applied 3 edits")),
                Wire.ChatMessage(beamId: 5, content: .toolCall(name: "edit", summary: "Add error message helpers", status: 1, isError: false, collapsed: true, autoApprovedScope: 1, durationMs: 145, result: "Applied 1 edit")),
                Wire.ChatMessage(beamId: 6, content: .toolCall(name: "shell", summary: "mix test test/minga/accounts/registration_test.exs", status: 1, isError: false, collapsed: true, autoApprovedScope: 2, durationMs: 3400, result: "8 tests, 0 failures")),
                Wire.ChatMessage(beamId: 7, content: .assistant(text: "I added input validation to the registration changeset: email format check via a regex, password minimum length of 8 characters with at least one digit, and validate_required on name, email, and password. All 8 tests pass.")),
                Wire.ChatMessage(beamId: 8, content: .usage(input: 96_000, output: 2_150, cacheRead: 48_000, cacheWrite: 960, costMicros: 287_000)),
            ]
        )

        return AgentChatView(state: state, theme: theme, isInsertMode: false, encoder: nil, cellHeight: 18)
            .frame(width: 760, height: 600)
            .background(theme.agentPanelBg)
    }

    // MARK: - BoardView

    private static func boardPreview() -> some View {
        BoardPreviewWrapper()
    }

    // MARK: - ChangeSummaryView

    private static func changeSummaryPreview() -> some View {
        let state = ChangeSummaryState()
        let theme = populatedTheme()
        state.update(
            visible: true,
            entries: [
                ChangeSummaryEntry(id: 1, path: "lib/minga/accounts/registration.ex", action: .modified, linesAdded: 24, linesRemoved: 3),
                ChangeSummaryEntry(id: 2, path: "lib/minga/accounts/validation.ex", action: .added, linesAdded: 48, linesRemoved: 0),
                ChangeSummaryEntry(id: 3, path: "test/minga/accounts/registration_test.exs", action: .modified, linesAdded: 36, linesRemoved: 2),
                ChangeSummaryEntry(id: 4, path: "lib/minga/accounts/old_validator.ex", action: .deleted, linesAdded: 0, linesRemoved: 31),
                ChangeSummaryEntry(id: 5, path: "lib/minga/accounts/user.ex", action: .modified, linesAdded: 5, linesRemoved: 1),
            ],
            selectedIndex: 0
        )

        return ChangeSummaryView(state: state, theme: theme, encoder: nil)
            .frame(width: 280, height: 400)
            .background(theme.treeBg)
    }

    // MARK: - DispatchSheetView

    private static func dispatchSheetPreview() -> some View {
        let state = DispatchSheetState()
        let theme = populatedTheme()
        state.update(
            visible: true,
            models: [
                (name: "claude-sonnet-4", hint: "Fast, balanced"),
                (name: "claude-opus-4", hint: "Deep reasoning"),
                (name: "gpt-4o", hint: "OpenAI flagship"),
            ]
        )
        state.taskText = "Refactor the buffer module to separate read and write concerns"

        return DispatchSheetView(state: state, theme: theme, encoder: nil)
            .frame(width: 600, height: 500)
            .background(theme.editorBg.opacity(0.5))
    }

    // MARK: - Hover / Signature Help data

    private static func previewHoverLines() -> [Wire.HoverLine] {
        [
            Wire.HoverLine(lineType: .codeHeader, segments: [
                Wire.HoverSegment(style: .code, fgColor: 0x5C6370, flags: 0, text: "elixir"),
            ]),
            Wire.HoverLine(lineType: .code, segments: [
                Wire.HoverSegment(style: .syntaxHighlighted, fgColor: 0xC678DD, flags: 0, text: "@spec "),
                Wire.HoverSegment(style: .syntaxHighlighted, fgColor: 0x98BE65, flags: 0, text: "open"),
                Wire.HoverSegment(style: .syntaxHighlighted, fgColor: 0xBBC2CF, flags: 0, text: "("),
                Wire.HoverSegment(style: .syntaxHighlighted, fgColor: 0xECBE7B, flags: 0, text: "String.t()"),
                Wire.HoverSegment(style: .syntaxHighlighted, fgColor: 0xBBC2CF, flags: 0, text: ") :: "),
                Wire.HoverSegment(style: .syntaxHighlighted, fgColor: 0xECBE7B, flags: 0, text: "{:ok, Buffer.t()}"),
            ]),
            Wire.HoverLine(lineType: .empty, segments: []),
            Wire.HoverLine(lineType: .text, segments: [
                Wire.HoverSegment(style: .plain, fgColor: nil, flags: 0, text: "Opens a file at the given path and returns the buffer."),
            ]),
            Wire.HoverLine(lineType: .text, segments: [
                Wire.HoverSegment(style: .plain, fgColor: nil, flags: 0, text: "Returns "),
                Wire.HoverSegment(style: .code, fgColor: nil, flags: 0, text: "{:ok, buffer}"),
                Wire.HoverSegment(style: .plain, fgColor: nil, flags: 0, text: " on success."),
            ]),
        ]
    }

    private static func previewSignatures() -> [Wire.Signature] {
        [
            Wire.Signature(
                label: "Buffer.open(path, opts \\\\ [])",
                documentation: "Opens a file buffer at the given path with optional configuration.",
                parameters: [
                    Wire.SignatureParameter(label: "path", documentation: "Absolute or relative file path to open."),
                    Wire.SignatureParameter(label: "opts", documentation: "Keyword list of options: :encoding, :line_ending."),
                ]
            ),
        ]
    }

    // MARK: - BottomPanelDiagnostics

    private static func bottomPanelDiagnosticsPreview() -> some View {
        let theme = populatedTheme()
        let state = BottomPanelState()

        state.update(
            visible: true,
            activeTabIndex: 1,
            heightPercent: 30,
            filterPreset: 1,
            tabs: [
                BottomPanelTab(id: 0, tabType: 0x00, name: "Terminal"),
                BottomPanelTab(id: 1, tabType: 0x01, name: "Diagnostics"),
                BottomPanelTab(id: 2, tabType: 0x02, name: "Output"),
            ]
        )

        state.messagesState.entries = [
            MessageEntry(id: 1, level: 3, subsystem: 1, timestampSecs: 36_061, filePath: "lib/minga/editor.ex", text: "function head/2 is undefined or private"),
            MessageEntry(id: 2, level: 3, subsystem: 1, timestampSecs: 36_062, filePath: "lib/minga/buffer/process.ex", text: "pattern can never match: the types <<_::binary>> and :error are incompatible"),
            MessageEntry(id: 3, level: 2, subsystem: 1, timestampSecs: 36_063, filePath: "lib/minga/editor.ex", text: "unused variable `opts`"),
            MessageEntry(id: 4, level: 3, subsystem: 2, timestampSecs: 36_064, filePath: "lib/minga/mode/normal.ex", text: "missing @spec for public function handle_key/2"),
            MessageEntry(id: 5, level: 2, subsystem: 1, timestampSecs: 36_065, filePath: "lib/minga/buffer/document.ex", text: "this clause cannot match because a previous clause always matches"),
            MessageEntry(id: 6, level: 2, subsystem: 2, timestampSecs: 36_066, filePath: "lib/minga/editor/render_pipeline.ex", text: "unused alias Buffer"),
            MessageEntry(id: 7, level: 3, subsystem: 1, timestampSecs: 36_067, filePath: "test/minga/editor_test.exs", text: "undefined function assert_received/1 (expected MingaTest.EditorTest to define such a function)"),
            MessageEntry(id: 8, level: 2, subsystem: 0, timestampSecs: 36_068, filePath: "lib/minga/editor.ex", text: "variable `state` is unused (if the variable is not meant to be used, prefix it with an underscore)"),
        ]

        state.messagesState.activeLevels = [2, 3]

        return BottomPanelView(state: state, theme: theme, encoder: nil, availableHeight: 600)
            .frame(width: 800, height: 250)
            .background(theme.editorBg)
    }

    // MARK: - NotificationOverflow

    private static func notificationOverflowPreview() -> some View {
        let state = NotificationCenterState()
        let theme = populatedTheme()
        let now = UInt64(Date().timeIntervalSince1970)

        state.update(rawNotifications: [
            Wire.EditorNotification(
                id: "notif-1",
                level: .error,
                flags: 0x01,
                createdAt: now - 120,
                updatedAt: now - 120,
                autoDismissMs: nil,
                title: "Build failed",
                body: "Compilation error in lib/minga/editor.ex:42 - undefined function render/1",
                source: "Compiler",
                actions: [
                    Wire.NotificationAction(id: "show", label: "Show Error"),
                    Wire.NotificationAction(id: "rebuild", label: "Rebuild"),
                ]
            ),
            Wire.EditorNotification(
                id: "notif-2",
                level: .warning,
                flags: 0x01,
                createdAt: now - 90,
                updatedAt: now - 90,
                autoDismissMs: nil,
                title: "Deprecation warning",
                body: "Minga.Buffer.read/1 is deprecated. Use Minga.Buffer.open/2 instead. This function will be removed in v2.0.",
                source: "Compiler",
                actions: []
            ),
            Wire.EditorNotification(
                id: "notif-3",
                level: .info,
                flags: 0x01,
                createdAt: now - 60,
                updatedAt: now - 60,
                autoDismissMs: nil,
                title: "Extension loaded",
                body: "org-mode v0.3.0 activated for .org files",
                source: "Extensions",
                actions: [
                    Wire.NotificationAction(id: "configure", label: "Configure"),
                ]
            ),
            Wire.EditorNotification(
                id: "notif-4",
                level: .success,
                flags: 0x01,
                createdAt: now - 45,
                updatedAt: now - 45,
                autoDismissMs: nil,
                title: "Tests passed",
                body: "42 tests, 0 failures",
                source: "ExUnit",
                actions: []
            ),
            Wire.EditorNotification(
                id: "notif-5",
                level: .progress,
                flags: 0x00,
                createdAt: now - 30,
                updatedAt: now - 30,
                autoDismissMs: nil,
                title: "LSP indexing",
                body: "Indexing project files (1,247 / 2,891)...",
                source: "ElixirLS",
                actions: []
            ),
            Wire.EditorNotification(
                id: "notif-6",
                level: .warning,
                flags: 0x01,
                createdAt: now - 15,
                updatedAt: now - 15,
                autoDismissMs: nil,
                title: "Git conflict detected",
                body: "lib/minga/buffer/process.ex has merge conflicts that must be resolved before committing",
                source: "Git",
                actions: [
                    Wire.NotificationAction(id: "resolve", label: "Open File"),
                ]
            ),
            Wire.EditorNotification(
                id: "notif-7",
                level: .error,
                flags: 0x01,
                createdAt: now - 5,
                updatedAt: now - 5,
                autoDismissMs: nil,
                title: "Agent tool error",
                body: "File write failed: permission denied for /etc/hosts. The agent cannot modify system files without elevated privileges.",
                source: "Agent",
                actions: [
                    Wire.NotificationAction(id: "retry", label: "Retry"),
                    Wire.NotificationAction(id: "dismiss", label: "Dismiss"),
                ]
            ),
        ])

        return NotificationCenterView(state: state, theme: theme, encoder: nil, bottomInset: 40)
            .frame(width: 800, height: 600)
            .background(theme.editorBg)
    }

    // MARK: - FileTreeRename

    private static func fileTreeRenamePreview() -> some View {
        let theme = populatedTheme()
        let state = fileTreeRenameState()

        return FileTreeView(
            fileTreeState: state,
            theme: theme,
            encoder: nil,
            usesPreviewEagerLayout: PreviewSnapshotPolicy.shouldUseEagerLayout(for: "FileTreeRename")
        )
        .frame(width: 280, height: 600)
        .background(theme.treeBg)
    }

    private static func fileTreeRenameState() -> FileTreeState {
        let state = FileTreeState()
        var raw = fileTreeRawEntries()

        // Replace the editor.ex entry (index 2) with an editing version
        raw[2] = wireFileEntry(
            id: "lib/minga/editor.ex",
            name: "editor.ex",
            path: "/Users/dev/code/minga/lib/minga/editor.ex",
            relPath: "lib/minga/editor.ex",
            isDir: false,
            depth: 2,
            icon: "",
            isActive: true,
            gitStatus: 1,
            isEditing: true,
            editingType: 2,
            editingText: "new_name.ex"
        )

        state.update(
            version: 1,
            selectedId: "lib/minga/editor.ex",
            focused: true,
            treeWidth: 30,
            rootPath: "/Users/dev/code/minga",
            rawEntries: raw,
            treeState: FileTreeVisibilityState.ready.rawValue
        )
        return state
    }

    // MARK: - Helpers

    /// ThemeColors() already initializes with Doom One defaults, which look representative for preview screenshots without any BEAM theme push.
    private static func populatedTheme() -> ThemeColors {
        ThemeColors()
    }

    private static func wireFileEntry(
        id: String,
        name: String,
        path: String,
        relPath: String,
        isDir: Bool,
        isExpanded: Bool = false,
        depth: UInt8,
        icon: String,
        isActive: Bool = false,
        isDirty: Bool = false,
        isLastChild: Bool = false,
        gitStatus: UInt8 = 0,
        isEditing: Bool = false,
        editingType: UInt8 = 255,
        editingText: String = ""
    ) -> Wire.FileTreeEntry {
        Wire.FileTreeEntry(
            pathHash: UInt32(id.hashValue & 0x7FFFFFFF),
            id: id,
            path: path,
            isDir: isDir,
            isExpanded: isExpanded,
            isSelected: isActive,
            isFocused: false,
            isActive: isActive,
            isDirty: isDirty,
            isEditing: isEditing,
            isLastChild: isLastChild,
            depth: depth,
            gitStatus: gitStatus,
            diagnosticErrorCount: 0,
            diagnosticWarningCount: 0,
            diagnosticInfoCount: 0,
            diagnosticHintCount: 0,
            guides: Array(repeating: false, count: Int(depth)),
            icon: icon,
            name: name,
            relPath: relPath,
            editingType: editingType,
            editingText: editingText
        )
    }
}

// MARK: - Board preview wrapper (requires @Namespace for matchedGeometryEffect)

/// Wraps BoardView in a struct that owns a @Namespace for the zoom animation.
/// BoardView requires a Namespace.ID for matchedGeometryEffect, which can only
/// be created via the @Namespace property wrapper on a View struct.
private struct BoardPreviewWrapper: View {
    @Namespace private var ns

    private static func boardState() -> BoardState {
        let state = BoardState()
        let now = UInt32(Date().timeIntervalSince1970)
        state.update(
            visible: true,
            focusedCardId: 2,
            cards: [
                BoardCard(id: 1, status: .working, isYouCard: true, isFocused: false, task: "Refactor buffer read/write separation", model: "claude-sonnet-4", dispatchTimestamp: now - 180, recentFiles: ["lib/minga/buffer/process.ex", "lib/minga/buffer/reader.ex"], sparkline: [0.2, 0.4, 0.6, 0.5, 0.7, 0.8]),
                BoardCard(id: 2, status: .needsYou, isYouCard: false, isFocused: true, task: "Add validation to registration form", model: "claude-sonnet-4", dispatchTimestamp: now - 420, recentFiles: ["lib/minga/accounts/registration.ex"], sparkline: [0.3, 0.5, 0.4, 0.6, 0.3, 0.2]),
                BoardCard(id: 3, status: .done, isYouCard: false, isFocused: false, task: "Fix notification theme colors", model: "claude-sonnet-4", dispatchTimestamp: now - 900, recentFiles: ["macos/Sources/Views/NotificationCenterView.swift"], sparkline: [0.5, 0.7, 0.6, 0.4, 0.2, 0.1]),
                BoardCard(id: 4, status: .errored, isYouCard: false, isFocused: false, task: "Deploy staging environment", model: "claude-opus-4", dispatchTimestamp: now - 600, recentFiles: ["scripts/deploy.sh"], sparkline: [0.1, 0.3, 0.8, 0.9, 1.0, 0.0]),
            ],
            filterMode: false,
            filterText: ""
        )
        return state
    }

    var body: some View {
        let state = Self.boardState()
        let dispatchSheet = DispatchSheetState()
        let theme = ThemeColors()

        BoardView(state: state, dispatchSheet: dispatchSheet, theme: theme, encoder: nil, namespace: ns)
            .frame(width: 900, height: 600)
            .background(theme.editorBg)
    }
}
