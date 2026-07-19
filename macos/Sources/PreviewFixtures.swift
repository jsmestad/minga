/// Reusable preview fixture data builders for PreviewRegistry and #Preview macros.

import SwiftUI
import MingaProtocol

// MARK: - .mingaChrome PreviewModifier (AC #7)

/// A `PreviewModifier` that injects the standard Doom One preview theme into any
/// `#Preview` block. Usage: `#Preview("Foo", traits: .mingaChrome) { FooView(...) }`.
///
/// `Context = Void` keeps `makeSharedContext()` nonisolated async-safe — no
/// `@MainActor` call occurs there. Theme setup defers to `onAppear` inside
/// `_MingaChromeHost`, which runs on the main actor where `ThemeColors` lives.
public struct MingaChromeModifier: PreviewModifier {
    public typealias Context = Void

    public static func makeSharedContext() async throws {}

    public func body(content: Content, context: Void) -> some View {
        _MingaChromeHost(content: content)
    }
}

/// Internal helper view that holds the preview theme in `@State` so the theme
/// is populated on first appear rather than at struct-init time (avoiding the
/// nonisolated-context restriction on `@MainActor` code).
private struct _MingaChromeHost<Content: View>: View {
    @State private var theme: ThemeColors?
    let content: Content

    var body: some View {
        let t = theme ?? ThemeColors()
        content
            .environment(\.themeColors, t)
            .background(t.editorBg)
            .onAppear {
                if theme == nil {
                    theme = PreviewFixtures.theme()
                }
            }
    }
}

public extension PreviewTrait where T == Preview.ViewTraits {
    /// Applies the standard Doom One preview theme and editor background so individual
    /// `#Preview` blocks do not need to repeat `.environment(\.themeColors, theme)` boilerplate.
    static var mingaChrome: PreviewTrait<T> {
        .modifier(MingaChromeModifier())
    }
}

@MainActor
public enum PreviewFixtures {

    /// Vim mode used for preview fixture state.
    public enum PreviewMode {
        case normal
        case insert
    }

    // MARK: - Theme & Encoder

    /// Preview-only theme fixture. Runtime theme selection comes from the BEAM via guiTheme; previews apply explicit slots because ThemeColors itself starts with neutral bootstrap colors.
    public static func theme() -> ThemeColors {
        let theme = ThemeColors()
        applyPreviewTheme(to: theme)
        return theme
    }

    /// Applies the Doom One preview palette to an existing `ThemeColors`.
    /// Use this to theme a `GUIState`'s owned `themeColors` (which views read
    /// via `\.themeColors`) rather than a standalone instance.
    public static func applyPreviewTheme(to theme: ThemeColors) {
        theme.applySlots([
            (GUI_COLOR_EDITOR_BG, 0x28, 0x2C, 0x34),
            (GUI_COLOR_EDITOR_FG, 0xBB, 0xC2, 0xCF),
            (GUI_COLOR_TREE_BG, 0x21, 0x24, 0x2B),
            (GUI_COLOR_TREE_FG, 0xBB, 0xC2, 0xCF),
            (GUI_COLOR_TREE_SELECTION_BG, 0x22, 0x57, 0xA0),
            (GUI_COLOR_TAB_BG, 0x21, 0x24, 0x2B),
            (GUI_COLOR_TAB_ACTIVE_BG, 0x28, 0x2C, 0x34),
            (GUI_COLOR_TAB_ACTIVE_FG, 0xBB, 0xC2, 0xCF),
            (GUI_COLOR_TAB_INACTIVE_FG, 0x5B, 0x62, 0x68),
            (GUI_COLOR_POPUP_BG, 0x21, 0x24, 0x2B),
            (GUI_COLOR_POPUP_FG, 0xBB, 0xC2, 0xCF),
            (GUI_COLOR_MODELINE_BAR_BG, 0x21, 0x24, 0x2B),
            (GUI_COLOR_MODELINE_BAR_FG, 0xBB, 0xC2, 0xCF),
            (GUI_COLOR_ACCENT, 0x51, 0xAF, 0xEF),
            (GUI_COLOR_SELECTION_BG, 0x26, 0x4F, 0x78),
        ])
    }

    public static func encoder() -> InputEncoder {
        NullInputEncoder()
    }

    // MARK: - State Population Helpers

    public static func populateFileTree(_ state: FileTreeState) {
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

    public static func populateGitStatus(_ state: GitStatusState) {
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

    public static func populateTabBar(_ state: TabBarState) {
        state.update(activeIndex: 0, entries: tabs())
    }

    /// Launchpad fixture matching what the BEAM builder emits for a returning user (#2689).
    public static func emptyStateReturningUser() -> [Wire.EmptyStateSection] {
        [
            Wire.EmptyStateSection(sectionId: 0, title: "Session", items: [
                Wire.EmptyStateItem(kind: 0, id: "resume", label: "resume last session", detail: "4 files", jumpKey: "r", chord: "", icon: "", iconColorRGB: 0),
            ]),
            Wire.EmptyStateSection(sectionId: 1, title: "Recent", items: [
                Wire.EmptyStateItem(kind: 1, id: "recent-1", label: "startup.ex", detail: "lib/minga_editor", jumpKey: "1", chord: "", icon: "\u{E62D}", iconColorRGB: 0xA074C4),
                Wire.EmptyStateItem(kind: 1, id: "recent-2", label: "render_content.go", detail: "go/tui/internal/ui", jumpKey: "2", chord: "", icon: "\u{E627}", iconColorRGB: 0x519ABA),
                Wire.EmptyStateItem(kind: 1, id: "recent-3", label: "ContentView.swift", detail: "macos/Sources", jumpKey: "3", chord: "", icon: "\u{E755}", iconColorRGB: 0xF05138),
            ]),
            Wire.EmptyStateSection(sectionId: 2, title: "Start", items: [
                Wire.EmptyStateItem(kind: 2, id: "action-find-file", label: "open file", detail: "", jumpKey: "", chord: "SPC f f", icon: "\u{F0224}", iconColorRGB: 0x61AFEF),
                Wire.EmptyStateItem(kind: 2, id: "action-file-tree", label: "file tree", detail: "", jumpKey: "", chord: "SPC o p", icon: "\u{F0256}", iconColorRGB: 0x78909C),
                Wire.EmptyStateItem(kind: 2, id: "action-palette", label: "command palette", detail: "", jumpKey: "", chord: "SPC :", icon: "\u{F0633}", iconColorRGB: 0x51AFEF),
                Wire.EmptyStateItem(kind: 2, id: "action-tutor", label: "tutorial", detail: ":Tutor", jumpKey: "", chord: "", icon: "", iconColorRGB: 0),
            ]),
            Wire.EmptyStateSection(sectionId: 3, title: "", items: [
                Wire.EmptyStateItem(kind: 3, id: "hint-write", label: "write", detail: "", jumpKey: "i", chord: "", icon: "", iconColorRGB: 0),
                Wire.EmptyStateItem(kind: 3, id: "hint-quit", label: "quit", detail: ":q", jumpKey: "", chord: "", icon: "", iconColorRGB: 0),
            ]),
        ]
    }

    /// Launchpad fixture for a first run: tutorial hero, no session or recents (#2689).
    public static func emptyStateFirstRun() -> [Wire.EmptyStateSection] {
        [
            Wire.EmptyStateSection(sectionId: 0, title: "Get started", items: [
                Wire.EmptyStateItem(kind: 2, id: "action-tutor", label: "open the tutorial", detail: ":Tutor", jumpKey: "RET", chord: "", icon: "", iconColorRGB: 0),
            ]),
            Wire.EmptyStateSection(sectionId: 2, title: "Start", items: [
                Wire.EmptyStateItem(kind: 2, id: "action-find-file", label: "open file", detail: "", jumpKey: "", chord: "SPC f f", icon: "\u{F0224}", iconColorRGB: 0x61AFEF),
                Wire.EmptyStateItem(kind: 2, id: "action-file-tree", label: "file tree", detail: "", jumpKey: "", chord: "SPC o p", icon: "\u{F0256}", iconColorRGB: 0x78909C),
                Wire.EmptyStateItem(kind: 2, id: "action-palette", label: "command palette", detail: "", jumpKey: "", chord: "SPC :", icon: "\u{F0633}", iconColorRGB: 0x51AFEF),
            ]),
            Wire.EmptyStateSection(sectionId: 3, title: "", items: [
                Wire.EmptyStateItem(kind: 3, id: "hint-write", label: "to start writing", detail: "", jumpKey: "i", chord: "", icon: "", iconColorRGB: 0),
                Wire.EmptyStateItem(kind: 3, id: "hint-quit", label: "to quit", detail: ":q", jumpKey: "", chord: "", icon: "", iconColorRGB: 0),
            ]),
        ]
    }

    public static func populateCompletion(_ state: CompletionState) {
        state.update(visible: true, anchorRow: 5, anchorCol: 10, selectedIndex: 1, rawItems: completionItems(), documentation: "")
    }

    public static func populateAgentChat(_ state: AgentChatState) {
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
            helpGroups: []
        )
        state.applyTranscript(mode: 0, epoch: 1, baseCount: 0, messages: agentChatMessages())
    }

    // MARK: - StatusBar Helpers

    public static func statusBarUpdate(agentVisible: Bool, mode: PreviewMode = .normal) -> StatusBarUpdate {
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
            modelineLeftSegments: statusLeftSegments(mode: mode),
            modelineRightSegments: statusRightSegments()
        )
    }

    public static func statusLeftSegments(mode: PreviewMode = .normal) -> [Wire.StatusBarSegment] {
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

    public static func statusRightSegments() -> [Wire.StatusBarSegment] {
        [
            Wire.StatusBarSegment(id: 0, kind: "diagnostics", text: " 0 ", fgColor: 0xF7768E, bgColor: 0x000000, attrs: 0, command: "diagnostic_list"),
            Wire.StatusBarSegment(id: 1, kind: "diagnostics", text: " 2 ", fgColor: 0xE0AF68, bgColor: 0x000000, attrs: 0, command: "diagnostic_list"),
            Wire.StatusBarSegment(id: 2, kind: "filetype", text: " Elixir ", fgColor: 0xC0CAF5, bgColor: 0x000000, attrs: 0, command: "set_language"),
            Wire.StatusBarSegment(id: 3, kind: "position", text: " Ln 42, Col 9 ", fgColor: 0xC0CAF5, bgColor: 0x000000, attrs: 0, command: "goto_line"),
        ]
    }

    // MARK: - Data Builders

    public static func tabs() -> [Wire.TabEntry] {
        [
            Wire.TabEntry(id: 1, groupId: 0, isActive: true, isDirty: false, isAgent: false, hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "\u{E62D}", label: "buffer.ex"),
            Wire.TabEntry(id: 2, groupId: 0, isActive: false, isDirty: false, isAgent: false, hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "\u{E62D}", label: "document.ex"),
            Wire.TabEntry(id: 3, groupId: 0, isActive: false, isDirty: true, isAgent: false, hasAttention: true, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "\u{E755}", label: "ContentView.swift"),
            Wire.TabEntry(id: 4, groupId: 0, isActive: false, isDirty: false, isAgent: false, hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "\u{F0219}", label: "README.md"),
            Wire.TabEntry(id: 5, groupId: 0, isActive: false, isDirty: false, isAgent: false, hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "\u{E7A8}", label: "main.rs"),
        ]
    }

    public static func completionItems() -> [Wire.CompletionItem] {
        [
            Wire.CompletionItem(kind: 7, label: "defmodule", detail: "keyword"),
            Wire.CompletionItem(kind: 7, label: "defstruct", detail: "keyword"),
            Wire.CompletionItem(kind: 7, label: "defdelegate", detail: "keyword"),
            Wire.CompletionItem(kind: 2, label: "def", detail: "keyword"),
            Wire.CompletionItem(kind: 1, label: "Document", detail: "Minga.Buffer.Document"),
        ]
    }

    public static func gitStatusEntries() -> [GitStatusEntry] {
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

    public static func fileTreeRawEntries() -> [Wire.FileTreeEntry] {
        [
            wireFileEntry(id: "lib", name: "lib", path: "/Users/dev/code/minga/lib", relPath: "lib", isDir: true, isExpanded: true, depth: 0, icon: "\u{F1247}", iconColor: 0x42A5F5),
            wireFileEntry(id: "lib/minga", name: "minga", path: "/Users/dev/code/minga/lib/minga", relPath: "lib/minga", isDir: true, isExpanded: true, depth: 1, icon: "\u{F0256}", iconColor: 0x78909C),
            wireFileEntry(id: "lib/minga/editor.ex", name: "editor.ex", path: "/Users/dev/code/minga/lib/minga/editor.ex", relPath: "lib/minga/editor.ex", isDir: false, depth: 2, icon: "\u{E62D}", iconColor: 0x9B59B6, isActive: true, gitStatus: 1),
            wireFileEntry(id: "lib/minga/buffer.ex", name: "buffer.ex", path: "/Users/dev/code/minga/lib/minga/buffer.ex", relPath: "lib/minga/buffer.ex", isDir: false, depth: 2, icon: "\u{E62D}", iconColor: 0x9B59B6, isDirty: true),
            wireFileEntry(id: "lib/minga/buffer", name: "buffer", path: "/Users/dev/code/minga/lib/minga/buffer", relPath: "lib/minga/buffer", isDir: true, isExpanded: true, depth: 2, icon: "\u{F0256}", iconColor: 0x78909C),
            wireFileEntry(id: "lib/minga/buffer/document.ex", name: "document.ex", path: "/Users/dev/code/minga/lib/minga/buffer/document.ex", relPath: "lib/minga/buffer/document.ex", isDir: false, depth: 3, icon: "\u{E62D}", iconColor: 0x9B59B6),
            wireFileEntry(id: "lib/minga/buffer/process.ex", name: "process.ex", path: "/Users/dev/code/minga/lib/minga/buffer/process.ex", relPath: "lib/minga/buffer/process.ex", isDir: false, depth: 3, icon: "\u{E62D}", iconColor: 0x9B59B6, gitStatus: 1),
            wireFileEntry(id: "lib/minga/mode", name: "mode", path: "/Users/dev/code/minga/lib/minga/mode", relPath: "lib/minga/mode", isDir: true, isExpanded: false, depth: 2, icon: "\u{F0256}", iconColor: 0x78909C),
            wireFileEntry(id: "lib/minga/editor", name: "editor", path: "/Users/dev/code/minga/lib/minga/editor", relPath: "lib/minga/editor", isDir: true, isExpanded: true, depth: 2, icon: "\u{F0256}", iconColor: 0x78909C),
            wireFileEntry(id: "lib/minga/editor/render_pipeline.ex", name: "render_pipeline.ex", path: "/Users/dev/code/minga/lib/minga/editor/render_pipeline.ex", relPath: "lib/minga/editor/render_pipeline.ex", isDir: false, depth: 3, icon: "\u{E62D}", iconColor: 0x9B59B6, gitStatus: 1),
            wireFileEntry(id: "macos", name: "macos", path: "/Users/dev/code/minga/macos", relPath: "macos", isDir: true, isExpanded: true, depth: 0, icon: "\u{F0256}", iconColor: 0xBDBDBD),
            wireFileEntry(id: "macos/Sources", name: "Sources", path: "/Users/dev/code/minga/macos/Sources", relPath: "macos/Sources", isDir: true, isExpanded: true, depth: 1, icon: "\u{F0256}", iconColor: 0x78909C),
            wireFileEntry(id: "macos/Sources/PreviewRegistry.swift", name: "PreviewRegistry.swift", path: "/Users/dev/code/minga/macos/Sources/PreviewRegistry.swift", relPath: "macos/Sources/PreviewRegistry.swift", isDir: false, depth: 2, icon: "\u{E755}", iconColor: 0xF05138, gitStatus: 1),
            wireFileEntry(id: "test", name: "test", path: "/Users/dev/code/minga/test", relPath: "test", isDir: true, isExpanded: false, depth: 0, icon: "\u{F1354}", iconColor: 0x66BB6A),
            wireFileEntry(id: "zig", name: "zig", path: "/Users/dev/code/minga/zig", relPath: "zig", isDir: true, isExpanded: false, depth: 0, icon: "\u{F0256}", iconColor: 0xF69A1B, isLastChild: true),
        ]
    }

    public static func agentChatMessages() -> [Wire.ChatMessage] {
        [
            Wire.ChatMessage(beamId: 1, content: .user(text: "The notification card should use our configured theme.")),
            Wire.ChatMessage(beamId: 2, content: .thinking(text: "Inspecting the SwiftUI chrome path and checking whether the notification background bypasses ThemeColors.", collapsed: false)),
            Wire.ChatMessage(beamId: 3, content: .toolCall(name: "read", summary: "macos/Sources/Views/NotificationCenterView.swift", status: 1, isError: false, collapsed: false, autoApprovedScope: 0, durationMs: 148, result: "Found .ultraThinMaterial on the card background.", previewKind: 0, previewLines: [])),
            Wire.ChatMessage(beamId: 4, content: .assistant(text: "I'll switch the card to theme.popupBg and keep severity as a themed border, so light and dark themes stay under BEAM control.")),
            Wire.ChatMessage(beamId: 5, content: .styledToolCall(name: "edit", summary: "Apply notification theme polish", status: 1, isError: false, collapsed: false, autoApprovedScope: 0, durationMs: 93, resultLines: [[styledRun(".background(theme.popupBg", 0x98, 0xBE, 0x65, bold: true), styledRun(", in: RoundedRectangle(cornerRadius: 10))", 0xBB, 0xC2, 0xCF)]], previewKind: 0, previewLines: [])),
            Wire.ChatMessage(beamId: 6, content: .usage(input: 128_000, output: 3_840, cacheRead: 64_000, cacheWrite: 1_280, costMicros: 431_000)),
        ]
    }

    public static func styledRun(_ text: String, _ r: UInt8, _ g: UInt8, _ b: UInt8, bold: Bool = false) -> Wire.StyledTextRun {
        Wire.StyledTextRun(text: text, fgR: r, fgG: g, fgB: b, bgR: 0, bgG: 0, bgB: 0, bold: bold, italic: false, underline: false)
    }

    // MARK: - Wire Helpers

    public static func wireFileEntry(
        id: String,
        name: String,
        path: String,
        relPath: String,
        isDir: Bool,
        isExpanded: Bool = false,
        depth: UInt8,
        icon: String,
        iconColor: UInt32 = 0x6D8086,
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
            iconColorR: UInt8((iconColor >> 16) & 0xFF),
            iconColorG: UInt8((iconColor >> 8) & 0xFF),
            iconColorB: UInt8(iconColor & 0xFF),
            name: name,
            relPath: relPath,
            editingType: editingType,
            editingText: editingText
        )
    }
}
