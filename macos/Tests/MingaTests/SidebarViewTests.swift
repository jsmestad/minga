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

@Suite("GitStatusView Branch Header")
struct GitStatusViewBranchHeaderTests {

    @Test("Branch header shows branch name")
    @MainActor func showsBranchName() throws {
        let state = GitStatusState()
        state.repoState = .normal
        state.branchName = "feat/sidebar-polish"

        let sut = GitStatusView(state: state, theme: ThemeColors(), encoder: nil)
        let body = try sut.inspect()
        let strings = body.findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }

        #expect(strings.contains("feat/sidebar-polish"))
    }

    @Test("Empty branch name falls back to 'No branch'")
    @MainActor func fallbackBranchName() throws {
        let state = GitStatusState()
        state.repoState = .normal
        state.branchName = ""

        let sut = GitStatusView(state: state, theme: ThemeColors(), encoder: nil)
        let body = try sut.inspect()
        let strings = body.findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }

        #expect(strings.contains("No branch"))
    }
}

// MARK: - FileTreeView

@Suite("FileTreeView View Structure")
struct FileTreeViewTests {

    @Test("Project header shows project name from projectRoot path")
    @MainActor func showsProjectName() throws {
        let state = FileTreeState()
        state.visible = true
        state.projectRoot = "/Users/test/code/minga"
        state.entries = [
            FileTreeEntry(
                id: 1, index: 0, isDir: true, isExpanded: true,
                isSelected: false, depth: 0, gitStatus: 0,
                icon: "\u{F024B}", name: "assets", relPath: "assets"
            ),
        ]

        let sut = FileTreeView(fileTreeState: state, theme: ThemeColors(), encoder: nil)
        let body = try sut.inspect()
        let strings = body.findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }

        // Should use projectRoot, not the first entry name
        #expect(strings.contains("minga"))
        #expect(!strings.contains("assets") || strings.filter { $0 == "assets" }.count == 1)
    }

    @Test("Empty projectRoot falls back to 'Project' name")
    @MainActor func fallbackProjectName() throws {
        let state = FileTreeState()
        state.visible = true
        state.projectRoot = ""
        state.entries = []

        let sut = FileTreeView(fileTreeState: state, theme: ThemeColors(), encoder: nil)
        let body = try sut.inspect()
        let strings = body.findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }

        #expect(strings.contains("Project"))
    }

    @Test("Header has four action buttons (new file, new folder, refresh, collapse all)")
    @MainActor func headerHasFourActionButtons() throws {
        let state = FileTreeState()
        state.visible = true
        state.entries = [
            FileTreeEntry(
                id: 1, index: 0, isDir: true, isExpanded: true,
                isSelected: false, depth: 0, gitStatus: 0,
                icon: "\u{F024B}", name: "minga", relPath: ""
            ),
        ]

        let sut = FileTreeView(fileTreeState: state, theme: ThemeColors(), encoder: nil)
        let body = try sut.inspect()
        // SidebarHeaderButton wraps a Button, so count all buttons in the header area.
        // There are 4 header action buttons plus potential click targets on entries.
        let buttons = body.findAll(ViewType.Button.self)
        #expect(buttons.count >= 4)
    }

    @Test("File entries render their names")
    @MainActor func fileEntriesRenderNames() throws {
        let state = FileTreeState()
        state.visible = true
        state.entries = [
            FileTreeEntry(
                id: 1, index: 0, isDir: true, isExpanded: true,
                isSelected: false, depth: 0, gitStatus: 0,
                icon: "\u{F024B}", name: "lib", relPath: "lib"
            ),
            FileTreeEntry(
                id: 2, index: 1, isDir: false, isExpanded: false,
                isSelected: true, depth: 1, gitStatus: 0,
                icon: "\u{E62D}", name: "editor.ex", relPath: "lib/editor.ex"
            ),
        ]

        let sut = FileTreeView(fileTreeState: state, theme: ThemeColors(), encoder: nil)
        let body = try sut.inspect()
        let strings = body.findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }

        #expect(strings.contains("lib"))
        #expect(strings.contains("editor.ex"))
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
