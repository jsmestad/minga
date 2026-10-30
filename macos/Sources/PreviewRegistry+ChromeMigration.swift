import MingaUI
import MingaProtocol
import SwiftUI

/// Additional visual evidence for chrome that is not visible in the original shell fixtures.
/// CI installs this identical preview-only file in the base checkout too. Do not use
/// ChromeTokens here: the fixture must compile against the pre-migration views.
@MainActor
extension PreviewRegistry {
    static func migrationContextBarPreview() -> some View {
        let theme = PreviewFixtures.theme()
        let state = AgentContextBarState(
            visible: true,
            task: "Review chrome",
            dispatchTimestamp: Date(),
            status: .working,
            canApprove: true,
            progress: .init(activeAction: "Checking views", toolCount: 8, fileCount: 3, reviewHint: "Ready to review"),
            todos: [.init(status: 1, description: "Compare previews")]
        )
        return VStack(spacing: 0) {
            AgentContextBar(state: state, onReview: { _ in })
            Spacer(minLength: 0)
        }
        .background(theme.editorBg)
        .environment(theme)
        .preferredColorScheme(.dark)
    }

    static func migrationWorkspaceIconPickerPreview() -> some View {
        let theme = PreviewFixtures.theme()
        return WorkspaceIconPicker(currentIcon: "folder", accentColor: theme.accent, onSelect: { _ in })
            .background(theme.popupBg)
            .environment(theme)
            .preferredColorScheme(.dark)
    }

    static func migrationWorkspaceHeaderPreview() -> some View {
        let theme = PreviewFixtures.theme()
        let state = WorkspaceState()
        state.install(WorkspacePresentationSnapshot(
            version: 1, activeWorkspaceId: 7, mode: .agent, flags: [.hasAttention],
            workspaces: [
                Wire.WorkspaceEntry(
                    id: 7, kind: 1, status: 2, flags: 0x0003,
                    colorR: 0x51, colorG: 0xAF, colorB: 0xEF,
                    tabCount: 3, draftCount: 1, conflictCount: 1, runningBackgroundCount: 1,
                    label: "Chrome review", icon: "cpu"
                ),
                Wire.WorkspaceEntry(
                    id: 8, kind: 1, status: 3, flags: 0x0001,
                    colorR: 0x98, colorG: 0xBE, colorB: 0x65,
                    tabCount: 2, draftCount: 2, conflictCount: 1, runningBackgroundCount: 2,
                    label: "Background research", icon: "network"
                )
            ],
            visibleTabs: []
        ))
        return VStack(spacing: 0) {
            if state.shouldShowHeader {
                WorkspaceHeaderView(workspaceState: state, sendAction: { _ in })
            }
            Spacer(minLength: 0)
        }
        .background(theme.tabBg)
        .environment(theme)
    }

    static func migrationWorkspaceIndicatorPreview() -> some View {
        let theme = PreviewFixtures.theme()
        let snapshot = WorkspacePresentationSnapshot(
            version: 1, activeWorkspaceId: 7, mode: .editor, flags: [],
            workspaces: [Wire.WorkspaceEntry(
                id: 7, kind: 0, status: 1, flags: 0,
                colorR: 0x51, colorG: 0xAF, colorB: 0xEF,
                tabCount: 3, draftCount: 0, conflictCount: 0, runningBackgroundCount: 0,
                label: "Chrome review", icon: "folder"
            )],
            visibleTabs: []
        )
        let state = TabBarState()
        state.install(snapshot)
        return HStack(spacing: 0) {
            ForEach(snapshot.workspaces) { workspace in
                WorkspaceIndicatorView(
                    workspace: workspace, presentationRevision: state.workspacePresentationRevision, owner: state,
                    sendAction: { _ in }, barHeight: 34
                )
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.tabBg)
        .environment(theme)
    }

    static func migrationExtensionOverlayPreview() -> some View {
        let theme = PreviewFixtures.theme()
        let state = ExtensionOverlayState()
        state.update([
            Wire.ExtensionOverlayEntry(
                extensionName: "review", overlayID: "cursor-label", windowID: 1,
                row: 3, col: 12, shape: 1, colorR: 0x51, colorG: 0xAF, colorB: 0xEF,
                opacity: 220, content: "Alice"
            ),
            Wire.ExtensionOverlayEntry(
                extensionName: "review", overlayID: "annotation", windowID: 1,
                row: 6, col: 28, shape: 2, colorR: 0x98, colorG: 0xBE, colorB: 0x65,
                opacity: 220, content: "3 references"
            )
        ])
        return ExtensionOverlayView(
            overlayState: state, windowID: 1, cellWidth: 8, cellHeight: 18,
            contentOrigin: CGPoint(x: 20, y: 20), firstColumn: 0, columnCount: 60, rowCount: 12
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.editorBg)
        .environment(theme)
    }

    static func migrationExtensionPanelPreview() -> some View {
        let theme = PreviewFixtures.theme()
        let panel = Wire.ExtensionPanelEntry(
            extensionName: "review", panelID: "chrome", title: "Extension overview",
            position: 1, sizeType: 0, sizeValue: 30, visible: true,
            blocks: [
                .text("The frontend renders extension-owned semantic content."),
                .table(columns: ["Surface", "Status"], rows: [["Sidebar", "Ready"], ["Overlay", "Review"]], selected: 1),
                .keyValue(pairs: [(key: "Workspace", value: "minga"), (key: "Files", value: "3 changed")]),
                .separator,
                .progress(label: "Review progress", percent: 0.65),
                .tree(nodes: [Wire.PanelTreeNode(label: "Sources", expanded: true, children: [
                    Wire.PanelTreeNode(label: "Views", expanded: true, children: [
                        Wire.PanelTreeNode(label: "Chrome.swift", expanded: false, children: [])
                    ])
                ])])
            ]
        )
        return ExtensionPanelView(panel: panel)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(theme.editorBg)
            .environment(theme)
            .preferredColorScheme(.dark)
    }

    static func migrationFloatPopupPreview() -> some View {
        let theme = PreviewFixtures.theme()
        let state = FloatPopupState()
        state.update(visible: true, width: 54, height: 14, title: "Workspace help", lines: [
            "SPC p  Project commands",
            "SPC b  Switch buffer",
            "SPC w  Window commands",
            "",
            "Float popups retain editor-cell-derived bounds."
        ])
        return FloatPopupOverlay(state: state, cellWidth: 8, cellHeight: 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.editorBg)
            .environment(theme)
    }

    static func migrationProtocolErrorPreview() -> some View {
        let state = ProtocolErrorState()
        state.present(message: "The editor and frontend protocol versions differ. Restart both processes to continue.")
        return ProtocolErrorOverlay(state: state)
            .environment(PreviewFixtures.theme())
    }

    static func migrationResyncPreview() -> some View {
        let theme = PreviewFixtures.theme()
        let state = ResyncState()
        state.markPending(lastGoodFrameSeq: 12, generation: 2, rejection: "waiting for a complete frame")
        return ResyncOverlay(state: state)
            .background(theme.editorBg)
            .environment(theme)
    }

    static func migrationTimelineFilesPreview() -> some View {
        let theme = PreviewFixtures.theme()
        let state = EditTimelineState(visible: true, files: [
            .init(path: "Sources/Chrome.swift", entryCount: 3, linesAdded: 18, linesRemoved: 7, reviewStatus: 1),
            .init(path: "Tests/ChromeTests.swift", entryCount: 2, linesAdded: 24, linesRemoved: 0, reviewStatus: 0)
        ])
        return VStack(spacing: 0) {
            EditTimelineView(state: state, sendAction: { _ in })
            Spacer(minLength: 0)
        }
        .background(theme.editorBg)
        .environment(theme)
    }

    static func migrationTimelineTrackPreview() -> some View {
        let theme = PreviewFixtures.theme()
        let state = EditTimelineState(visible: true, viewingIndex: 1, entries: [
            .init(entryID: "read", index: 0, toolName: "read_file", timestampDelta: 0),
            .init(entryID: "edit", index: 1, toolName: "edit_file", timestampDelta: 10),
            .init(entryID: "review", index: 2, toolName: "review", timestampDelta: 20)
        ])
        return VStack(spacing: 0) {
            EditTimelineView(state: state, sendAction: { _ in })
            Spacer(minLength: 0)
        }
        .background(theme.editorBg)
        .environment(theme)
    }

    static func migrationEditorSettingsPreview() -> some View {
        let theme = PreviewFixtures.theme()
        let state = SettingsState()
        state.isLoading = false
        state.tabWidth = 4
        state.lineNumbers = .relative
        return EditorSettingsView(state: state)
            .background(theme.editorBg)
            .environment(theme)
            .preferredColorScheme(.dark)
    }

    static func migrationKeybindingsSettingsPreview() -> some View {
        let theme = PreviewFixtures.theme()
        let state = SettingsState()
        state.isLoading = false
        state.keybindings = [
            .init(mode: "Normal", key: "SPC f f", command: "find_file", description: "Find a file"),
            .init(mode: "Normal", key: "SPC b b", command: "buffer_picker", description: "Switch buffers"),
            .init(mode: "Insert", key: "Ctrl-n", command: "completion_next", description: "Next completion")
        ]
        return KeybindingsSettingsView(state: state, sendAction: { _ in })
            .background(theme.editorBg)
            .environment(theme)
            .preferredColorScheme(.dark)
    }
}
