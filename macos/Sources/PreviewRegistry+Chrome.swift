import MingaUI
import SwiftUI
import MingaProtocol

@MainActor
extension PreviewRegistry {

    // MARK: - StatusBarView

    static func statusBarPreview() -> some View {
        statusBarView(width: 800)
    }

    static func statusBarView(width: CGFloat) -> some View {
        let state = StatusBarState()
        let theme = PreviewFixtures.theme()

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

        return StatusBarView(state: state, encoder: nil)
            .frame(width: width, height: 28)
            .background(theme.editorBg)
            .environment(theme)
    }

    // MARK: - EmptyStateView (launchpad, #2689)

    static func emptyStatePreview() -> some View {
        emptyStateView(sections: PreviewFixtures.emptyStateReturningUser(), focusedId: "resume")
    }

    static func emptyStateFirstRunPreview() -> some View {
        emptyStateView(sections: PreviewFixtures.emptyStateFirstRun(), focusedId: "action-tutor")
    }

    static func emptyStateView(sections: [Wire.EmptyStateSection], focusedId: String) -> some View {
        let state = EmptyStateState()
        let theme = PreviewFixtures.theme()
        state.update(crashed: false, version: "v0.9", focusedId: focusedId, sections: sections)

        return EmptyStateView(state: state, encoder: nil)
            .frame(width: 900, height: 640)
            .background(theme.editorBg)
            .environment(theme)
    }

    // MARK: - TabBarView

    static func tabBarPreview() -> some View {
        tabBarView(width: 800)
    }

    static func tabBarView(width: CGFloat) -> some View {
        let state = TabBarState()
        let theme = PreviewFixtures.theme()
        state.update(activeIndex: 1, entries: [
            Wire.TabEntry(id: 1, groupId: 0, isActive: false, isDirty: true, isAgent: false, hasAttention: false, agentStatus: 0, isPinned: true, tintColorRGB: 0, icon: "\u{E62D}", label: "editor.ex"),
            Wire.TabEntry(id: 2, groupId: 0, isActive: true, isDirty: false, isAgent: false, hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "\u{E62D}", label: "buffer.ex"),
            Wire.TabEntry(id: 3, groupId: 0, isActive: false, isDirty: false, isAgent: false, hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "\u{E755}", label: "ContentView.swift"),
            Wire.TabEntry(id: 4, groupId: 0, isActive: false, isDirty: true, isAgent: false, hasAttention: true, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "\u{F0219}", label: "README.md"),
            Wire.TabEntry(id: 5, groupId: 0, isActive: false, isDirty: false, isAgent: false, hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "\u{E7A8}", label: "main.rs"),
        ])

        return TabBarView(tabBarState: state, encoder: nil)
            .frame(width: width, height: 36)
            .background(theme.editorBg)
            .environment(theme)
    }

    // MARK: - TabBarOverflow

    static func tabBarOverflowPreview() -> some View {
        tabBarOverflowView(width: 1200)
    }

    static func tabBarOverflowView(width: CGFloat) -> some View {
        let state = TabBarState()
        let theme = PreviewFixtures.theme()
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

        return TabBarView(tabBarState: state, encoder: nil)
            .frame(width: width, height: 36)
            .background(theme.editorBg)
            .environment(theme)
    }

    // MARK: - NotificationCenterView

    static func notificationPreview() -> some View {
        let state = NotificationCenterState()
        let theme = PreviewFixtures.theme()
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

        return NotificationCenterView(state: state, encoder: nil, bottomInset: 40)
            .frame(width: 800, height: 600)
            .background(theme.editorBg)
            .environment(theme)
    }

    // MARK: - NotificationStack

    static func notificationStackPreview() -> some View {
        let state = NotificationCenterState()
        let theme = PreviewFixtures.theme()
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

        return NotificationCenterView(state: state, encoder: nil, bottomInset: 40)
            .frame(width: 800, height: 600)
            .background(theme.editorBg)
            .environment(theme)
    }

    // MARK: - NotificationOverflow

    static func notificationOverflowPreview() -> some View {
        let state = NotificationCenterState()
        let theme = PreviewFixtures.theme()
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

        return NotificationCenterView(state: state, encoder: nil, bottomInset: 40)
            .frame(width: 800, height: 600)
            .background(theme.editorBg)
            .environment(theme)
    }

    // MARK: - BottomPanelView

    static func bottomPanelPreview() -> some View {
        let state = BottomPanelState()
        let theme = PreviewFixtures.theme()
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

        return BottomPanelView(state: state, encoder: nil, availableHeight: 600)
            .frame(width: 800, height: 250)
            .background(theme.editorBg)
            .environment(theme)
    }

    static func bottomPanelEmptyPreview() -> some View {
        let state = BottomPanelState()
        let theme = PreviewFixtures.theme()
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

        return BottomPanelView(state: state, encoder: nil, availableHeight: 600)
            .frame(width: 800, height: 250)
            .background(theme.editorBg)
            .environment(theme)
    }

    // MARK: - BottomPanelDiagnostics

    static func bottomPanelDiagnosticsPreview() -> some View {
        let theme = PreviewFixtures.theme()
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

        return BottomPanelView(state: state, encoder: nil, availableHeight: 600)
            .frame(width: 800, height: 250)
            .background(theme.editorBg)
            .environment(theme)
    }

    // MARK: - MessagesContentView

    static func messagesContentPreview() -> some View {
        let state = MessagesContentState()
        let theme = PreviewFixtures.theme()
        populateMessages(state)

        return MessagesContentView(
            state: state,
            encoder: nil,
            usesPreviewEagerLayout: PreviewSnapshotPolicy.shouldUseEagerLayout(for: "MessagesContentView")
        )
        .frame(width: 800, height: 360)
        .background(theme.editorBg)
            .environment(theme)
        .preferredColorScheme(.dark)
    }

    static func populateMessages(_ state: MessagesContentState) {
        let baseTime: UInt32 = 43200  // 12:00:00
        state.appendEntries([
            Wire.MessageEntry(streamInstance: 1, id: 1, level: 1, subsystem: 0, timestampSecs: baseTime, filePath: "lib/minga/editor.ex", text: "Buffer opened: editor.ex (1250 lines)"),
            Wire.MessageEntry(streamInstance: 1, id: 2, level: 0, subsystem: 1, timestampSecs: baseTime + 1, filePath: "", text: "ElixirLS initialized in 340ms"),
            Wire.MessageEntry(streamInstance: 1, id: 3, level: 2, subsystem: 2, timestampSecs: baseTime + 3, filePath: "lib/minga/buffer/document.ex", text: "Tree-sitter parse timeout (>50ms) on large file"),
            Wire.MessageEntry(streamInstance: 1, id: 4, level: 1, subsystem: 3, timestampSecs: baseTime + 5, filePath: "", text: "Branch switched: feat/preview-host (2 ahead)"),
            Wire.MessageEntry(streamInstance: 1, id: 5, level: 3, subsystem: 4, timestampSecs: baseTime + 8, filePath: "", text: "Metal shader compilation failed: fragment_main"),
            Wire.MessageEntry(streamInstance: 1, id: 6, level: 1, subsystem: 5, timestampSecs: baseTime + 12, filePath: "", text: "Agent session started (claude-sonnet-4, medium thinking)"),
            Wire.MessageEntry(streamInstance: 1, id: 7, level: 0, subsystem: 6, timestampSecs: baseTime + 14, filePath: "", text: "TUI grid resized to 112x36"),
            Wire.MessageEntry(streamInstance: 1, id: 8, level: 2, subsystem: 7, timestampSecs: baseTime + 18, filePath: "", text: "SwiftUI layout cycle detected in NotificationCard"),
        ])
    }

    // MARK: - SettingsView

    static func settingsPreview() -> some View {
        let appState = AppState()
        let encoder = PreviewFixtures.encoder()
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

        return SettingsView(state: appState.gui.settingsState, encoder: appState.encoder)
            .frame(width: 600, height: 480)
            .environment(\.themeColors, appState.gui.themeColors)
    }


    // MARK: - ObservatoryView

    static func observatoryPreview() -> some View {
        let state = ObservatoryState()
        let theme = PreviewFixtures.theme()
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

        return ObservatoryView(state: state, encoder: nil)
            .frame(width: 320, height: 640)
            .background(theme.treeBg)
            .environment(theme)
    }

}
