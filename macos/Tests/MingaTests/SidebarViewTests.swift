/// View structure tests for sidebar components (FileTreeView, GitStatusView,
/// SidebarContainer, SidebarHeaderButton).
///
/// Verifies that structural refactors (header backgrounds, button extraction,
/// shared resize handle) didn't break text rendering or button counts.
/// Cosmetic details (opacity, padding, colors) are left to visual QA.

import Testing
import SwiftUI
import ViewInspector

// MARK: - SidebarHeaderButton

@Suite("SidebarHeaderButton View Structure")
struct SidebarHeaderButtonTests {

    @Test("Renders with provided SF Symbol")
    @MainActor func rendersIcon() throws {
        let sut = SidebarHeaderButton(
            systemName: "doc.badge.plus",
            barFg: .white,
            tooltip: "New File…",
            action: {}
        )
        let body = try sut.inspect()
        let images = body.findAll(ViewType.Image.self)
        #expect(!images.isEmpty)
    }

    @Test("Tap triggers the action closure")
    @MainActor func tapTriggersAction() throws {
        var tapped = false
        let sut = SidebarHeaderButton(
            systemName: "plus",
            barFg: .white,
            tooltip: "Add",
            action: { tapped = true }
        )
        let body = try sut.inspect()
        let button = try body.find(ViewType.Button.self)
        try button.tap()
        #expect(tapped)
    }

    @Test("Tooltip also backs the accessibility label")
    @MainActor func tooltipBacksAccessibilityLabel() throws {
        let sut = SidebarHeaderButton(
            systemName: "plus",
            barFg: .white,
            tooltip: "New File…",
            action: {}
        )
        let button = try sut.inspect().find(ViewType.Button.self)
        #expect(try button.accessibilityLabel().string() == "New File…")
    }
}

// MARK: - GitStatusView Empty States

@Suite("GitStatusView Empty States")
struct GitStatusViewEmptyStateTests {

    @Test("Not-a-repo state shows explanation text")
    @MainActor func notARepo() throws {
        let state = GitStatusState()
        state.repoState = .notARepo

        let sut = GitStatusView(state: state, theme: ThemeColors(), encoder: nil)
        let body = try sut.inspect()
        let strings = body.findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }

        #expect(strings.contains("Not a git repository"))
    }

    @Test("Loading state shows loading indicator text")
    @MainActor func loading() throws {
        let state = GitStatusState()
        state.repoState = .loading

        let sut = GitStatusView(state: state, theme: ThemeColors(), encoder: nil)
        let body = try sut.inspect()
        let strings = body.findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }

        #expect(strings.contains("Loading\u{2026}"))
    }

    @Test("Clean repo shows working-tree-clean message")
    @MainActor func cleanRepo() throws {
        let state = GitStatusState()
        state.repoState = .normal
        state.branchName = "main"
        // No entries = clean

        let sut = GitStatusView(state: state, theme: ThemeColors(), encoder: nil)
        let body = try sut.inspect()
        let strings = body.findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }

        #expect(strings.contains("Nothing to commit"))
        #expect(strings.contains("Working tree clean"))
    }
}

// MARK: - GitStatusView Branch Header

@Suite("GitStatusHeaderContent Branch Header")
struct GitStatusViewBranchHeaderTests {

    @Test("Branch header shows project and branch name")
    @MainActor func showsBranchName() throws {
        let state = GitStatusState()
        state.repoState = .normal
        state.branchName = "feat/sidebar-polish"

        let sut = GitStatusHeaderContent(state: state, theme: ThemeColors(), projectName: "minga", leadingPadding: 10)
        let body = try sut.inspect()
        let strings = body.findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }

        #expect(strings.contains("minga"))
        #expect(strings.contains("feat/sidebar-polish"))
    }

    @Test("Empty branch name falls back to 'No branch'")
    @MainActor func fallbackBranchName() throws {
        let state = GitStatusState()
        state.repoState = .normal
        state.branchName = ""

        let sut = GitStatusHeaderContent(state: state, theme: ThemeColors(), projectName: "minga", leadingPadding: 10)
        let body = try sut.inspect()
        let strings = body.findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }

        #expect(strings.contains("No branch"))
    }
}

// MARK: - FileTreeView

@Suite("FileTreeView View Structure")
struct FileTreeViewTests {

    @Test("Project header shows project and branch from projectRoot path")
    @MainActor func showsProjectName() throws {
        let state = FileTreeState()
        state.visible = true
        state.projectRoot = "/Users/test/code/minga"

        let sut = FileTreeHeaderContent(fileTreeState: state, theme: ThemeColors(), encoder: nil, branchName: "main", leadingPadding: 10)
        let body = try sut.inspect()
        let strings = body.findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }

        #expect(strings.contains("minga"))
        #expect(strings.contains("main"))
    }

    @Test("Empty projectRoot falls back to 'Project' name")
    @MainActor func fallbackProjectName() throws {
        let state = FileTreeState()
        state.visible = true
        state.projectRoot = ""

        let sut = FileTreeHeaderContent(fileTreeState: state, theme: ThemeColors(), encoder: nil, branchName: "", leadingPadding: 10)
        let body = try sut.inspect()
        let strings = body.findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }

        #expect(strings.contains("Project"))
    }

    @Test("Header action buttons reserve layout space at rest")
    @MainActor func headerActionButtonsReserveLayoutSpaceAtRest() throws {
        let state = FileTreeState()
        state.visible = true

        let sut = FileTreeHeaderContent(fileTreeState: state, theme: ThemeColors(), encoder: nil, branchName: "", leadingPadding: 10)
        let body = try sut.inspect()
        let buttons = body.findAll(ViewType.Button.self)
        #expect(buttons.count == 4)
    }

    @Test("Header action buttons send file-tree actions")
    @MainActor func headerActionButtonsSendFileTreeActions() throws {
        let state = FileTreeState()
        state.visible = true
        state.selectedIndex = 7
        let spy = SpyEncoder()

        let sut = FileTreeHeaderContent(fileTreeState: state, theme: ThemeColors(), encoder: spy, branchName: "main", leadingPadding: 10)
        let buttons = try sut.inspect().findAll(ViewType.Button.self)

        try buttons[0].tap()
        try buttons[1].tap()
        try buttons[2].tap()
        try buttons[3].tap()

        #expect(spy.guiActions == [
            .fileTreeNewFile(parentIndex: 7),
            .fileTreeNewFolder(parentIndex: 7),
            .fileTreeRefresh,
            .fileTreeCollapseAll,
        ])
    }

    @Test("Header accessibility summarizes project and branch context")
    @MainActor func headerAccessibilitySummarizesProjectAndBranchContext() throws {
        let state = FileTreeState()
        state.visible = true
        state.projectRoot = "/Users/test/code/minga"

        let sut = FileTreeHeaderContent(fileTreeState: state, theme: ThemeColors(), encoder: nil, branchName: "main", leadingPadding: 10)

        #expect(sut.accessibilityLabelText == "File tree for minga, branch main")
    }

    @Test("File entries render their names")
    @MainActor func fileEntriesRenderNames() throws {
        let state = FileTreeState()
        state.visible = true
        state.entries = [
            sidebarFileTreeEntry(id: 1, index: 0, isDir: true, isExpanded: true,
                                 icon: "\u{F024B}", name: "lib", relPath: "lib"),
            sidebarFileTreeEntry(id: 2, index: 1, isSelected: true, depth: 1,
                                 icon: "\u{E62D}", name: "editor.ex", relPath: "lib/editor.ex"),
        ]

        let sut = FileTreeView(fileTreeState: state, theme: ThemeColors(), encoder: nil)
        let body = try sut.inspect()
        let strings = body.findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }

        #expect(strings.contains("lib"))
        #expect(strings.contains("editor.ex"))
    }

    @Test("Dirty marker renders independently from selected and git state")
    @MainActor func dirtyMarkerRendersWithSelectedAndGitState() throws {
        let state = FileTreeState()
        state.visible = true
        state.entries = [
            sidebarFileTreeEntry(id: 1, index: 0, isSelected: true, isFocused: false, isDirty: true, gitStatus: 1,
                                 icon: "\u{E62D}", name: "editor.ex", relPath: "lib/editor.ex"),
        ]

        let sut = FileTreeView(fileTreeState: state, theme: ThemeColors(), encoder: nil)
        let body = try sut.inspect()
        let strings = body.findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }

        #expect(strings.contains("editor.ex"))
        #expect(strings.contains("●"))
    }

    @Test("Drop sends BEAM-owned intent instead of performing filesystem work")
    @MainActor func dropSendsBeamOwnedIntent() throws {
        let state = FileTreeState()
        state.visible = true
        state.projectRoot = "/project"
        let entry = sidebarFileTreeEntry(id: 0xABCD, index: 4, isDir: false, icon: "\u{E62D}", name: "file.ex", relPath: "lib/file.ex", path: "/project/lib/file.ex")
        state.entries = [entry]
        let spy = SpyEncoder()

        let sut = FileTreeView(fileTreeState: state, theme: ThemeColors(), encoder: spy)
        let handled = sut.handleDrop(urls: [URL(fileURLWithPath: "/tmp/from.txt")], onto: entry)

        #expect(handled)
        #expect(spy.guiActions == [
            .fileTreeDrop(sourcePaths: ["/tmp/from.txt"], targetIndex: 4, targetId: "lib/file.ex", targetPathHash: 0xABCD, targetPath: "/project/lib/file.ex", targetIsDir: false, modifiers: 0)
        ])
    }

    @Test("Drop is not handled when encoder is unavailable")
    @MainActor func dropWithoutEncoderIsRejected() throws {
        let state = FileTreeState()
        state.visible = true
        state.projectRoot = "/project"
        let entry = sidebarFileTreeEntry(id: 0xABCD, index: 4, isDir: false, icon: "\u{E62D}", name: "file.ex", relPath: "lib/file.ex", path: "/project/lib/file.ex")
        state.entries = [entry]

        let sut = FileTreeView(fileTreeState: state, theme: ThemeColors(), encoder: nil)
        let handled = sut.handleDrop(urls: [URL(fileURLWithPath: "/tmp/from.txt")], onto: entry)

        #expect(!handled)
    }

    @Test("Editing row renders inline edit field")
    @MainActor func editingRowRendersInlineEditField() throws {
        let state = FileTreeState()
        state.visible = true
        state.entries = [
            sidebarFileTreeEntry(id: 1, index: 0, isEditing: true, editingType: 2, editingText: "renamed.ex",
                                 icon: "\u{E62D}", name: "editor.ex", relPath: "lib/editor.ex"),
        ]

        let sut = FileTreeView(fileTreeState: state, theme: ThemeColors(), encoder: nil)
        let body = try sut.inspect()
        let fields = body.findAll(InlineEditField.self)

        #expect(fields.count == 1)
    }
}

// MARK: - FileTreeRowView

@Suite("FileTreeRowView View Structure")
struct FileTreeRowViewTests {

    @Test("Accessibility labels and hints describe row state")
    @MainActor func accessibilityLabelsAndHintsDescribeRowState() throws {
        let file = fileTreeRowView(entry: sidebarFileTreeEntry(id: 1, index: 0, icon: "\u{E62D}", name: "editor.ex", relPath: "lib/editor.ex"))
        #expect(file.accessibilityLabelText == "File: editor.ex")
        #expect(file.accessibilityHintText == "Press Return to open.")

        let collapsedDir = fileTreeRowView(entry: sidebarFileTreeEntry(id: 2, index: 1, isDir: true, icon: "\u{F024B}", name: "lib", relPath: "lib"))
        #expect(collapsedDir.accessibilityLabelText == "Folder: lib")
        #expect(collapsedDir.accessibilityHintText == "Collapsed folder. Press Return to expand.")

        let expandedDir = fileTreeRowView(entry: sidebarFileTreeEntry(id: 3, index: 2, isDir: true, isExpanded: true, icon: "\u{F0256}", name: "test", relPath: "test"))
        #expect(expandedDir.accessibilityHintText == "Expanded folder. Press Return to collapse.")

        let editing = fileTreeRowView(entry: sidebarFileTreeEntry(id: 4, index: 3, isEditing: true, editingType: 2, editingText: "renamed.ex", icon: "\u{E62D}", name: "editor.ex", relPath: "lib/editor.ex"))
        #expect(editing.accessibilityLabelText == "Editing: editor.ex")
        #expect(editing.accessibilityHintText == "Type a new name, then press Return to confirm or Escape to cancel.")
    }

    @Test("Files directories and expanded folders have distinct row affordances")
    @MainActor func filesDirectoriesAndExpandedFoldersHaveDistinctAffordances() throws {
        let file = fileTreeRowView(entry: sidebarFileTreeEntry(id: 1, index: 0, icon: "\u{E62D}", name: "editor.ex", relPath: "lib/editor.ex"))
        let collapsedDir = fileTreeRowView(entry: sidebarFileTreeEntry(id: 2, index: 1, isDir: true, icon: "\u{F024B}", name: "lib", relPath: "lib"))
        let expandedDir = fileTreeRowView(entry: sidebarFileTreeEntry(id: 3, index: 2, isDir: true, isExpanded: true, icon: "\u{F0256}", name: "test", relPath: "test"))

        #expect(try file.inspect().findAll(ViewType.Image.self).isEmpty)
        #expect(try collapsedDir.inspect().findAll(ViewType.Image.self).count == 1)
        #expect(try expandedDir.inspect().findAll(ViewType.Image.self).count == 1)
        #expect(try collapsedDir.inspect().find(ViewType.Image.self).rotation().angle.degrees == 0)
        #expect(try expandedDir.inspect().find(ViewType.Image.self).rotation().angle.degrees == 90)
    }

    @Test("Status markers remain separate from name text")
    @MainActor func statusMarkersRemainSeparateFromNameText() throws {
        let row = fileTreeRowView(entry: sidebarFileTreeEntry(id: 1, index: 0, isSelected: true, isFocused: true, isActive: true, isDirty: true, gitStatus: 1, diagnosticErrorCount: 2, icon: "\u{E62D}", name: "editor.ex", relPath: "lib/editor.ex"))
        let strings = try row.inspect().findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }

        #expect(strings.contains("editor.ex"))
        #expect(strings.contains("✖2"))
        #expect(strings.contains("●"))
        #expect(try row.inspect().findAll(ViewType.Shape.self).count >= 1)
    }

    @Test("Accessibility labels include independent status summaries")
    @MainActor func accessibilityLabelsIncludeStatusSummaries() throws {
        let row = fileTreeRowView(entry: sidebarFileTreeEntry(id: 1, index: 0, isDirty: true, gitStatus: 4, diagnosticWarningCount: 1, icon: "\u{E62D}", name: "editor.ex", relPath: "lib/editor.ex"))

        #expect(row.accessibilityLabelText == "File: editor.ex, 1 warning, unsaved changes, git conflict")
    }

    @Test("Diagnostic info and hint severities render distinct markers")
    @MainActor func diagnosticInfoAndHintSeveritiesRenderDistinctMarkers() throws {
        let info = fileTreeRowView(entry: sidebarFileTreeEntry(id: 1, index: 0, diagnosticInfoCount: 1, icon: "\u{E62D}", name: "info.ex", relPath: "info.ex"))
        let hint = fileTreeRowView(entry: sidebarFileTreeEntry(id: 2, index: 1, diagnosticHintCount: 3, icon: "\u{E62D}", name: "hint.ex", relPath: "hint.ex"))
        let noisy = fileTreeRowView(entry: sidebarFileTreeEntry(id: 3, index: 2, diagnosticErrorCount: 120, icon: "\u{E62D}", name: "noisy.ex", relPath: "noisy.ex"))

        let infoStrings = try info.inspect().findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }
        let hintStrings = try hint.inspect().findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }
        let noisyStrings = try noisy.inspect().findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }

        #expect(infoStrings.contains("ℹ"))
        #expect(hintStrings.contains("·3"))
        #expect(noisyStrings.contains("✖9+"))
    }

    @Test("Deep rows compress indentation before it overwhelms names")
    @MainActor func deepRowsCompressIndentationBeforeItOverwhelmsNames() throws {
        let shallow = fileTreeRowView(entry: sidebarFileTreeEntry(id: 1, index: 0, depth: 2, icon: "\u{E62D}", name: "editor.ex", relPath: "lib/editor.ex"))
        let deep = fileTreeRowView(entry: sidebarFileTreeEntry(id: 2, index: 1, depth: 8, icon: "\u{E62D}", name: "very_long_component_view.ex", relPath: "lib/minga_editor/shell/traditional/very_long_component_view.ex"))

        #expect(deep.leadingPadding > shallow.leadingPadding)
        #expect(deep.leadingPadding < 8 + CGFloat(8) * 14)
    }

    @Test("Selected rows quiet indent guides")
    @MainActor func selectedRowsQuietIndentGuides() throws {
        let normal = fileTreeRowView(entry: sidebarFileTreeEntry(id: 1, index: 0, depth: 4, guides: [true, true, false, true], icon: "\u{E62D}", name: "normal.ex", relPath: "lib/normal.ex"))
        let selected = fileTreeRowView(entry: sidebarFileTreeEntry(id: 2, index: 1, isSelected: true, depth: 4, guides: [true, true, false, true], icon: "\u{E62D}", name: "selected.ex", relPath: "lib/selected.ex"))

        #expect(selected.indentGuideOpacity < normal.indentGuideOpacity)
    }

    @Test("Nested rows keep names and status badges as independent views")
    @MainActor func nestedRowsKeepNamesAndStatusBadgesAsIndependentViews() throws {
        let row = fileTreeRowView(entry: sidebarFileTreeEntry(id: 1, index: 0, isDirty: true, gitStatus: 1, diagnosticWarningCount: 1, depth: 8, guides: [true, true, false, true, false, true, true, false], icon: "\u{E62D}", name: "非常に長い_component_view.ex", relPath: "lib/minga_editor/shell/traditional/非常に長い_component_view.ex"))
        let strings = try row.inspect().findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }

        #expect(strings.contains("非常に長い_component_view.ex"))
        #expect(strings.contains("⚠"))
        #expect(strings.contains("●"))
        #expect(try row.inspect().findAll(ViewType.Shape.self).count >= 1)
    }

    @Test("Selected active and hovered rows keep status markers readable")
    @MainActor func selectedActiveAndHoveredRowsKeepStatusMarkersReadable() throws {
        let selected = fileTreeRowView(entry: sidebarFileTreeEntry(id: 1, index: 0, isSelected: true, isFocused: false, isDirty: true, gitStatus: 1, diagnosticWarningCount: 1, icon: "\u{E62D}", name: "selected.ex", relPath: "selected.ex"))
        let active = fileTreeRowView(entry: sidebarFileTreeEntry(id: 2, index: 1, isSelected: true, isFocused: true, isActive: true, isDirty: true, gitStatus: 4, diagnosticErrorCount: 1, icon: "\u{E62D}", name: "active.ex", relPath: "active.ex"))
        let hovered = fileTreeRowView(entry: sidebarFileTreeEntry(id: 3, index: 2, isDirty: true, gitStatus: 2, diagnosticInfoCount: 1, icon: "\u{E62D}", name: "hovered.ex", relPath: "hovered.ex"), isHovered: true)

        for row in [selected, active, hovered] {
            let strings = try row.inspect().findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }
            #expect(strings.contains("●"))
            #expect(row.accessibilityLabelText.contains("unsaved changes"))
            #expect(row.accessibilityLabelText.contains("git"))
        }
    }
}

// MARK: - GitStatusView Section Headers

@Suite("GitStatusView Section Headers")
struct GitStatusViewSectionTests {

    @Test("All four section labels render when entries exist in each section")
    @MainActor func allSectionLabelsRender() throws {
        let state = GitStatusState()
        state.repoState = .normal
        state.branchName = "main"
        state.stagedEntries = [
            GitStatusEntry(id: 1, section: .staged, status: .modified, path: "lib/a.ex"),
        ]
        state.changedEntries = [
            GitStatusEntry(id: 2, section: .changed, status: .modified, path: "lib/b.ex"),
        ]
        state.untrackedEntries = [
            GitStatusEntry(id: 3, section: .untracked, status: .untracked, path: "lib/c.ex"),
        ]
        state.conflictedEntries = [
            GitStatusEntry(id: 4, section: .conflicted, status: .conflicted, path: "lib/d.ex"),
        ]

        let sut = GitStatusView(state: state, theme: ThemeColors(), encoder: nil)
        let body = try sut.inspect()
        let strings = body.findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }

        // Section labels are uppercased in the view via .textCase(.uppercase),
        // but the source string is the label property value.
        #expect(strings.contains(where: { $0.localizedCaseInsensitiveContains("Staged") }))
        #expect(strings.contains(where: { $0.localizedCaseInsensitiveContains("Changes") }))
        #expect(strings.contains(where: { $0.localizedCaseInsensitiveContains("Untracked") }))
        #expect(strings.contains(where: { $0.localizedCaseInsensitiveContains("Merge Conflicts") || $0.localizedCaseInsensitiveContains("Conflicted") }))
    }

    @Test("File entries show status letter and filename")
    @MainActor func fileEntriesShowStatusAndName() throws {
        let state = GitStatusState()
        state.repoState = .normal
        state.branchName = "main"
        state.changedEntries = [
            GitStatusEntry(id: 1, section: .changed, status: .modified, path: "lib/minga/editor.ex"),
        ]

        let sut = GitStatusView(state: state, theme: ThemeColors(), encoder: nil)
        let body = try sut.inspect()
        let strings = body.findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }

        #expect(strings.contains("M"))
        #expect(strings.contains("editor.ex"))
    }
}

@MainActor
private func fileTreeRowView(entry: FileTreeEntry, isHovered: Bool = false, isDropTarget: Bool = false) -> FileTreeRowView {
    FileTreeRowView(
        entry: entry,
        theme: ThemeColors(),
        rowHeight: 22,
        indentWidth: 14,
        chevronWidth: 12,
        isHovered: isHovered,
        isDropTarget: isDropTarget,
        animDuration: 0,
        onEditCommit: { _ in },
        onEditCancel: {}
    )
}

private func sidebarFileTreeEntry(
    id: UInt32,
    index: Int,
    isDir: Bool = false,
    isExpanded: Bool = false,
    isSelected: Bool = false,
    isFocused: Bool = false,
    isActive: Bool = false,
    isDirty: Bool = false,
    gitStatus: UInt8 = 0,
    diagnosticErrorCount: UInt16 = 0,
    diagnosticWarningCount: UInt16 = 0,
    diagnosticInfoCount: UInt16 = 0,
    diagnosticHintCount: UInt16 = 0,
    isEditing: Bool = false,
    editingType: UInt8 = 0xFF,
    editingText: String = "",
    depth: Int = 0,
    guides: [Bool] = [],
    icon: String,
    name: String,
    relPath: String,
    path: String? = nil
) -> FileTreeEntry {
    FileTreeEntry(id: relPath, pathHash: id, index: index, isDir: isDir, isExpanded: isExpanded, isSelected: isSelected,
                  isFocused: isFocused, isActive: isActive, isDirty: isDirty, isEditing: isEditing,
                  isLastChild: false, depth: depth, gitStatus: gitStatus, diagnosticErrorCount: diagnosticErrorCount,
                  diagnosticWarningCount: diagnosticWarningCount, diagnosticInfoCount: diagnosticInfoCount, diagnosticHintCount: diagnosticHintCount,
                  guides: guides, icon: icon, name: name, relPath: relPath, path: path ?? relPath,
                  editingType: editingType, editingText: editingText)
}
