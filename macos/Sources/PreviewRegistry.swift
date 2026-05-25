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
        case "FileTreeView":
            fileTreePreview()
        case "CompletionOverlay":
            completionPreview()
        case "StatusBarView":
            statusBarPreview()
        case "TabBarView":
            tabBarPreview()
        case "NotificationCenterView":
            notificationPreview()
        case "ObservatoryView":
            observatoryPreview()
        case "AgentChatView":
            agentChatPreview()
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

    private static func productionPreviewAppState(agentVisible: Bool) -> AppState? {
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
        appState.gui.statusBarState.update(from: previewStatusBarUpdate(agentVisible: agentVisible))

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
            GUIVisualRow(rowType: .normal, bufLine: UInt32(38 + index), contentHash: UInt32(index + 1), text: row.0, spans: row.1)
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

    private static func previewStatusBarUpdate(agentVisible: Bool) -> StatusBarUpdate {
        StatusBarUpdate(
            contentKind: 0, mode: 0, cursorLine: 42, cursorCol: 9,
            lineCount: 1250, flags: 0x02, lspStatus: 1, gitBranch: "main",
            message: "", filetype: "elixir", errorCount: 0, warningCount: 2,
            modelName: agentVisible ? "claude-sonnet-4" : "", messageCount: agentVisible ? 6 : 0, sessionStatus: agentVisible ? 2 : 0,
            infoCount: 0, hintCount: 0, macroRecording: 0, parserStatus: 1, agentStatus: agentVisible ? 2 : 0,
            activeToolName: agentVisible ? "read" : "",
            gitAdded: 0, gitModified: 0, gitDeleted: 0,
            icon: "", iconColorR: 0x88, iconColorG: 0x57, iconColorB: 0xA6, filename: "editor.ex", diagnosticHint: "",
            backgroundSubagentCount: 0, backgroundSubagentLabel: "",
            modelineLeftSegments: previewStatusLeftSegments(),
            modelineRightSegments: previewStatusRightSegments()
        )
    }

    private static func previewStatusLeftSegments() -> [Wire.StatusBarSegment] {
        [
            Wire.StatusBarSegment(id: 0, kind: "mode", text: " NORMAL ", fgColor: 0x000000, bgColor: 0x7AA2F7, attrs: 1, command: ""),
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

        return GitStatusView(state: state, theme: theme, encoder: nil)
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

    // MARK: - FileTreeView

    private static func fileTreePreview() -> some View {
        let theme = populatedTheme()

        return fileTreeBodyPreview(theme: theme)
            .frame(width: 280, height: 600)
            .background(theme.treeBg)
    }

    private static func fileTreeBodyPreview(theme: ThemeColors) -> some View {
        FileTreeView(fileTreeState: fileTreeState(), theme: theme, encoder: nil)
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
        gitStatus: UInt8 = 0
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
            isEditing: false,
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
            editingType: 255,
            editingText: ""
        )
    }
}
