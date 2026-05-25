/// Maps view names to constructed SwiftUI chrome views with mock state.

import SwiftUI

@MainActor
enum PreviewRegistry {

    /// Returns a preview for the named view, or an error label for unknown names.
    @ViewBuilder
    static func view(named name: String) -> some View {
        switch name {
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - GitStatusView

    private static func gitStatusPreview() -> some View {
        let state = GitStatusState()
        let theme = populatedTheme()
        state.update(
            repoState: .normal,
            branchName: "feat/preview-host",
            ahead: 2,
            behind: 0,
            syncing: false,
            entries: [
                GitStatusEntry(pathHash: 1, section: .staged, status: .modified, path: "lib/minga/editor.ex"),
                GitStatusEntry(pathHash: 2, section: .staged, status: .added, path: "lib/minga/preview.ex"),
                GitStatusEntry(pathHash: 3, section: .staged, status: .deleted, path: "lib/minga/old_module.ex"),
                GitStatusEntry(pathHash: 4, section: .changed, status: .modified, path: "lib/minga/buffer/document.ex"),
                GitStatusEntry(pathHash: 5, section: .changed, status: .modified, path: "test/minga/editor_test.exs"),
                GitStatusEntry(pathHash: 6, section: .untracked, status: .untracked, path: "lib/minga/new_feature.ex"),
            ],
            toast: nil,
            entryBasePath: "/Users/dev/code/minga",
            lastCommitMessage: "feat(editor): add preview host target",
            stashCount: 1
        )

        return GitStatusView(state: state, theme: theme, encoder: nil)
            .frame(width: 280, height: 600)
            .background(theme.treeBg)
    }

    // MARK: - FileTreeView

    private static func fileTreePreview() -> some View {
        let theme = populatedTheme()
        let entries = fileTreeEntries()

        // Render FileTreeRowView directly in a VStack instead of through
        // FileTreeView, because FileTreeView uses LazyVStack inside ScrollView
        // which renders zero rows in offscreen/ImageRenderer capture.
        return VStack(spacing: 0) {
            ForEach(entries) { entry in
                FileTreeRowView(
                    entry: entry,
                    theme: theme,
                    rowHeight: 22,
                    indentWidth: 14,
                    chevronWidth: 12,
                    isHovered: false,
                    isDropTarget: false,
                    animDuration: 0,
                    onActivate: {},
                    onEditCommit: { _ in },
                    onEditCancel: {}
                )
            }
            Spacer()
        }
        .frame(width: 280, height: 600)
        .background(theme.treeBg)
    }

    private static func fileTreeEntries() -> [FileTreeEntry] {
        let raw = [
            wireFileEntry(id: "lib", name: "lib", path: "/Users/dev/code/minga/lib", relPath: "lib", isDir: true, isExpanded: true, depth: 0, icon: ""),
            wireFileEntry(id: "lib/minga", name: "minga", path: "/Users/dev/code/minga/lib/minga", relPath: "lib/minga", isDir: true, isExpanded: true, depth: 1, icon: ""),
            wireFileEntry(id: "lib/minga/editor.ex", name: "editor.ex", path: "/Users/dev/code/minga/lib/minga/editor.ex", relPath: "lib/minga/editor.ex", isDir: false, depth: 2, icon: "", isActive: true, gitStatus: 1),
            wireFileEntry(id: "lib/minga/buffer.ex", name: "buffer.ex", path: "/Users/dev/code/minga/lib/minga/buffer.ex", relPath: "lib/minga/buffer.ex", isDir: false, depth: 2, icon: "", isDirty: true),
            wireFileEntry(id: "lib/minga/mode", name: "mode", path: "/Users/dev/code/minga/lib/minga/mode", relPath: "lib/minga/mode", isDir: true, isExpanded: false, depth: 2, icon: ""),
            wireFileEntry(id: "test", name: "test", path: "/Users/dev/code/minga/test", relPath: "test", isDir: true, isExpanded: false, depth: 0, icon: "", isLastChild: true),
        ]
        return raw.enumerated().map { index, wire in
            FileTreeEntry(
                id: wire.id, pathHash: wire.pathHash, index: index,
                isDir: wire.isDir, isExpanded: wire.isExpanded,
                isSelected: wire.isSelected, isFocused: wire.isFocused,
                isActive: wire.isActive, isDirty: wire.isDirty,
                isEditing: wire.isEditing, isLastChild: wire.isLastChild,
                depth: Int(wire.depth), gitStatus: wire.gitStatus,
                diagnosticErrorCount: wire.diagnosticErrorCount,
                diagnosticWarningCount: wire.diagnosticWarningCount,
                diagnosticInfoCount: wire.diagnosticInfoCount,
                diagnosticHintCount: wire.diagnosticHintCount,
                guides: wire.guides, icon: wire.icon,
                name: wire.name, relPath: wire.relPath, path: wire.path,
                editingType: wire.editingType, editingText: wire.editingText
            )
        }
    }

    // MARK: - CompletionOverlay

    private static func completionPreview() -> some View {
        let state = CompletionState()
        let theme = populatedTheme()
        state.update(
            visible: true, anchorRow: 5, anchorCol: 10, selectedIndex: 1,
            rawItems: [
                Wire.CompletionItem(kind: 6, label: "defmodule", detail: "keyword"),
                Wire.CompletionItem(kind: 6, label: "defstruct", detail: "keyword"),
                Wire.CompletionItem(kind: 6, label: "defdelegate", detail: "keyword"),
                Wire.CompletionItem(kind: 2, label: "def", detail: "keyword"),
                Wire.CompletionItem(kind: 1, label: "Document", detail: "Minga.Buffer.Document"),
            ]
        )

        return CompletionOverlay(state: state, theme: theme, encoder: nil)
            .frame(width: 400, height: 300)
            .background(theme.editorBg)
    }

    // MARK: - StatusBarView

    private static func statusBarPreview() -> some View {
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
            .frame(width: 800, height: 28)
            .background(theme.editorBg)
    }

    // MARK: - TabBarView

    private static func tabBarPreview() -> some View {
        let state = TabBarState()
        let theme = populatedTheme()
        state.update(activeIndex: 1, entries: [
            Wire.TabEntry(id: 1, groupId: 0, isActive: false, isDirty: true, isAgent: false, hasAttention: false, agentStatus: 0, isPinned: true, tintColorRGB: 0, icon: "", label: "editor.ex"),
            Wire.TabEntry(id: 2, groupId: 0, isActive: true, isDirty: false, isAgent: false, hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "", label: "buffer.ex"),
            Wire.TabEntry(id: 3, groupId: 0, isActive: false, isDirty: false, isAgent: false, hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "", label: "document.ex"),
            Wire.TabEntry(id: 4, groupId: 0, isActive: false, isDirty: true, isAgent: false, hasAttention: true, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "", label: "mode.ex"),
        ])

        return TabBarView(tabBarState: state, theme: theme, encoder: nil)
            .frame(width: 800, height: 36)
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
            .frame(width: 760, height: 600)
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

    /// ThemeColors() already initializes with Doom One defaults, which look
    /// representative for preview screenshots without any BEAM theme push.
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
