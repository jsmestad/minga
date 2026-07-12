/// Maps view names to constructed SwiftUI chrome views with mock state.

import MingaUI
import AppKit
import SwiftUI
import MingaProtocol

@MainActor
enum PreviewRegistry {

    /// Returns the intended screenshot size for a preview.
    static func size(named name: String) -> CGSize {
        PreviewSnapshotPolicy.size(named: name)
    }

    /// Builds the full-shell `ContentView` from a production preview `AppState`,
    /// wiring the app-only editor geometry, window chrome, and Metal editor
    /// surface exactly the way `MingaApp` does.
    static func productionContentView(_ appState: AppState) -> some View {
        ContentView(
            gui: appState.gui,
            encoder: { appState.encoder },
            editorGeometry: { EditorGeometry(editorNSView: appState.editorNSView) },
            chrome: WindowChrome(appState: appState),
            onAgentChatVisibleChange: { visible in
                appState.editorNSView?.setAgentChatVisible(visible)
            },
            makeEditorSurface: {
                if let nsView = appState.editorNSView {
                    EditorView(editorNSView: nsView)
                } else {
                    Color(red: 0.12, green: 0.12, blue: 0.14)
                }
            }
        )
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
        case "EmptyStateView":
            emptyStatePreview()
        case "EmptyStateFirstRun":
            emptyStateFirstRunPreview()
        case "NotificationCenterView":
            notificationPreview()
        case "NotificationStack":
            notificationStackPreview()
        case "BottomPanelView":
            bottomPanelPreview()
        case "MessagesContentView":
            messagesContentPreview()
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
        case "ChangeSummaryView":
            changeSummaryPreview()
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
        case "LatencyHUDOverlay":
            latencyHUDPreview()
        case "LatencyHUDEmpty":
            latencyHUDEmptyPreview()
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
            productionContentView(appState)
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
            productionContentView(appState)
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
            productionContentView(appState)
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
            productionContentView(appState)
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

    /// Alias for the preview mode enum moved to PreviewFixtures.
    typealias PreviewMode = PreviewFixtures.PreviewMode

    private static func productionPreviewAppState(agentVisible: Bool, mode: PreviewMode = .normal) -> AppState? {
        let appState = AppState()
        appState.windowTitle = "Minga"
        appState.windowBgIsDark = true
        appState.hasReceivedFirstFrame = true
        appState.trafficLightMidY = 14

        let encoder = PreviewFixtures.encoder()
        appState.encoder = encoder
        appState.gui.settingsState.encoder = encoder

        PreviewFixtures.populateFileTree(appState.gui.fileTreeState)
        PreviewFixtures.populateGitStatus(appState.gui.gitStatusState)
        appState.gui.gitStatusState.hide()
        PreviewFixtures.populateTabBar(appState.gui.tabBarState)
        appState.gui.breadcrumbState.update(segments: ["lib", "minga", "editor.ex"])
        appState.gui.statusBarState.update(from: PreviewFixtures.statusBarUpdate(agentVisible: agentVisible, mode: mode))

        if agentVisible {
            PreviewFixtures.populateAgentChat(appState.gui.agentChatState)
        } else if mode == .insert {
            // Completion fires while typing, so show it in the insert-mode
            // preview. The normal-mode editor stays clean so its snapshot
            // shows the editor surface (cursorline, indent guides, diagnostics)
            // rather than a popup covering the code.
            PreviewFixtures.populateCompletion(appState.gui.completionState)
        }

        guard let editorNSView = previewEditorNSView(appState: appState, encoder: encoder) else { return nil }
        appState.editorNSView = editorNSView
        return appState
    }

    private static func previewEditorNSView(appState: AppState, encoder: InputEncoder) -> EditorNSView? {
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
        // Indent guides for the visible window, matching previewEditorRows()
        // (2-space Elixir indent). The cursor's enclosing level (col 2) is the
        // active guide. Exercises the same render path the BEAM drives via the
        // gui_indent_guides (0x91) opcode so the snapshot reflects the real
        // editor surface rather than underselling it.
        dispatcher.frameState.windowIndentGuides[1] = IndentGuideData(
            windowId: 1,
            tabWidth: 2,
            activeGuideCol: 2,
            guideCols: [0, 2],
            lineIndentLevels: [0, 1, 1, 1, 2, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        )
        dispatcher.frameState.windowGutters[1] = Wire.WindowGutter(
            windowId: 1,
            contentRow: 1,
            contentCol: 0,
            contentHeight: 22,
            isActive: true,
            contentWidth: 108,
            cursorLine: 43,
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
            lineAnnotations: [],
            // Current-line band on the cursor row. The renderer reads the
            // per-window cursorline (CoreTextMetalRenderer drawWindowedContent),
            // not frameState, so it must be set here to render.
            cursorline: GUICursorline(row: 5, bg: 0x2C323C)
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

    // MARK: - Moved sections removed (now in extension files)
    // See: PreviewRegistry+GitStatus.swift, PreviewRegistry+FileTree.swift,
    //      PreviewRegistry+AgentChat.swift, PreviewRegistry+Overlays.swift,
    //      PreviewRegistry+Chrome.swift


    // MARK: - DiagnosticsEditorView


    private static func diagnosticsEditorPreview() -> some View {
        previewDiagnosticsChromeView(failureMessage: "DiagnosticsEditorView could not initialize the production editor renderer.")
    }

    @ViewBuilder
    private static func previewDiagnosticsChromeView(failureMessage: String) -> some View {
        let size = PreviewSnapshotPolicy.size(named: "DiagnosticsEditorView")

        if let appState = diagnosticsPreviewAppState() {
            productionContentView(appState)
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

        let encoder = PreviewFixtures.encoder()
        appState.encoder = encoder
        appState.gui.settingsState.encoder = encoder

        PreviewFixtures.populateFileTree(appState.gui.fileTreeState)
        PreviewFixtures.populateGitStatus(appState.gui.gitStatusState)
        appState.gui.gitStatusState.hide()
        PreviewFixtures.populateTabBar(appState.gui.tabBarState)
        appState.gui.breadcrumbState.update(segments: ["lib", "minga", "editor.ex"])
        appState.gui.statusBarState.update(from: PreviewFixtures.statusBarUpdate(agentVisible: false))

        guard let editorNSView = previewDiagnosticsEditorNSView(appState: appState, encoder: encoder) else { return nil }
        appState.editorNSView = editorNSView
        return appState
    }

    private static func previewDiagnosticsEditorNSView(appState: AppState, encoder: InputEncoder) -> EditorNSView? {
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
}
