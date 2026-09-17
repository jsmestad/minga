/// Tests for computed properties on view model types.
///
/// These types have business logic beyond simple storage: icon extraction,
/// match position adjustment, display name formatting, status labels, etc.
/// Bugs in these computations produce visible UX issues (wrong highlights,
/// missing icons, incorrect counts).

import Testing
@testable import MingaUI
import Foundation
import SwiftUI
import MingaProtocol

// MARK: - WorkspacePresentationSnapshot

@Suite("Workspace Presentation Snapshot")
struct WorkspacePresentationSnapshotTests {
    @Test("converts every shared workspace and tab field once")
    func convertsSharedWorkspaceFields() throws {
        let snapshot = WorkspacePresentationSnapshot(
            version: 3,
            activeWorkspaceId: 9,
            mode: .fileTree,
            flags: WorkspaceFlags(rawValue: 0x05),
            workspaces: [
                Wire.WorkspaceEntry(id: 0, kind: 0, status: 1, flags: 0x0001, colorR: 0x11, colorG: 0x22, colorB: 0x33, tabCount: 2, draftCount: 3, conflictCount: 4, runningBackgroundCount: 5, label: "Manual", icon: "folder"),
                Wire.WorkspaceEntry(id: 9, kind: 1, status: 2, flags: 0x0002, colorR: 0x44, colorG: 0x55, colorB: 0x66, tabCount: 6, draftCount: 7, conflictCount: 8, runningBackgroundCount: 9, label: "Review", icon: "cpu"),
            ],
            visibleTabs: [
                Wire.WorkspaceTabEntry(id: 42, workspaceId: 9, kind: 0, flags: 0x003F, pathHash: 0x12345678, tintColorRGB: 0x7AA2F7, icon: "file-code", label: "first.ex", path: "/tmp/first.ex"),
                Wire.WorkspaceTabEntry(id: 43, workspaceId: 9, kind: 0, flags: 0x0040, pathHash: 0x87654321, tintColorRGB: 0, icon: "file", label: "untitled", path: ""),
            ]
        )

        #expect(snapshot.version == 3)
        #expect(snapshot.activeWorkspaceId == 9)
        #expect(snapshot.mode == .fileTree)
        #expect(snapshot.flags.rawValue == 0x05)
        #expect(snapshot.workspaces.map(\.id) == [0, 9])

        let workspace = try #require(snapshot.workspaces.last)
        #expect(workspace.kind == .agent)
        #expect(workspace.agentStatus == .executingTool)
        #expect(workspace.flags == [.closeable])
        #expect(workspace.color == Color(.sRGB, red: 0x44 / 255.0, green: 0x55 / 255.0, blue: 0x66 / 255.0))
        #expect(workspace.tabCount == 6)
        #expect(workspace.draftCount == 7)
        #expect(workspace.conflictCount == 8)
        #expect(workspace.runningBackgroundCount == 9)
        #expect(workspace.label == "Review")
        #expect(workspace.icon == "cpu")

        #expect(snapshot.visibleTabs.map(\.id) == [42, 43])
        let colored = snapshot.visibleTabs[0]
        #expect(colored.workspaceId == 9)
        #expect(colored.kind == .file)
        #expect(colored.flags.rawValue == 0x003F)
        #expect(colored.pathHash == 0x12345678)
        #expect(colored.tintColor == Color(.sRGB, red: 0x7A / 255.0, green: 0xA2 / 255.0, blue: 0xF7 / 255.0))
        #expect(colored.icon == "file-code")
        #expect(colored.label == "first.ex")
        #expect(colored.path == "/tmp/first.ex")
        #expect(colored.isDirty)
        #expect(colored.hasAttention)
        #expect(colored.isDraft)
        #expect(colored.isDraftElsewhere)
        #expect(colored.hasConflict)
        #expect(colored.isPinned)
        #expect(snapshot.visibleTabs[1].tintColor == nil)
        #expect(snapshot.visibleTabs[1].isEphemeral)
    }

    @Test("owners install shared values but retain canonical-payload semantics")
    @MainActor func ownersRetainPresentationBehavior() {
        let snapshot = WorkspacePresentationSnapshot(version: 0, activeWorkspaceId: 0, mode: .fileTree, flags: WorkspaceFlags(rawValue: 3), workspaces: [], visibleTabs: [])
        let workspaceState = WorkspaceState()
        let tabBarState = TabBarState()

        workspaceState.install(snapshot)
        tabBarState.install(snapshot)

        #expect(workspaceState.activeWorkspaceId == tabBarState.activeWorkspaceId)
        #expect(workspaceState.viewMode == tabBarState.workspaceMode)
        #expect(workspaceState.flags == tabBarState.workspaceFlags)
        #expect(workspaceState.workspaces.isEmpty)
        #expect(tabBarState.workspaces.isEmpty)
        #expect(workspaceState.visibleTabs.isEmpty)
        #expect(tabBarState.workspaceTabs.isEmpty)
        #expect(!workspaceState.hasCanonicalPayload)
        #expect(tabBarState.hasCanonicalWorkspaceTabs)
    }
}

// MARK: - PickerItem

@Suite("PickerItem Computed Properties")
struct PickerItemComputedTests {

    @Test("icon is empty for plain labels")
    func iconPlainLabel() {
        let item = PickerItem(id: 0, iconColor: 0, label: "editor.ex",
                             description: "", annotation: "",
                             matchPositions: [], isTwoLine: false, isMarked: false)
        #expect(item.hasLeadingIcon == false)
        #expect(item.icon == "")
    }

    @Test("icon returns empty string for empty label")
    func iconEmpty() {
        let item = PickerItem(id: 0, iconColor: 0, label: "",
                             description: "", annotation: "",
                             matchPositions: [], isTwoLine: false, isMarked: false)
        #expect(item.icon == "")
    }

    @Test("icon handles Nerd Font character (multi-byte)")
    func iconNerdFont() {
        let item = PickerItem(id: 0, iconColor: 0, label: "\u{F0256}lib",
                             description: "", annotation: "",
                             matchPositions: [], isTwoLine: false, isMarked: false)
        #expect(item.hasLeadingIcon == true)
        #expect(item.icon == "\u{F0256}")
    }

    @Test("displayLabel keeps plain labels intact")
    func displayLabelPlainText() {
        let item = PickerItem(id: 0, iconColor: 0, label: "editor.ex",
                             description: "", annotation: "",
                             matchPositions: [], isTwoLine: false, isMarked: false)
        #expect(item.displayLabel == "editor.ex")
    }

    @Test("displayLabel keeps colored plain labels intact")
    func displayLabelColoredPlainText() {
        let item = PickerItem(id: 0, iconColor: 0x51AFEF, label: "Workspace",
                             description: "", annotation: "",
                             matchPositions: [], isTwoLine: false, isMarked: false)
        #expect(item.hasLeadingIcon == false)
        #expect(item.displayLabel == "Workspace")
    }

    @Test("displayLabel drops icon and spacer")
    func displayLabelWithIconAndSpacer() {
        let item = PickerItem(id: 0, iconColor: 0x51AFEF, label: "\u{F024B} lib",
                             description: "", annotation: "",
                             matchPositions: [], isTwoLine: false, isMarked: false)
        #expect(item.displayLabel == "lib")
    }

    @Test("displayLabel returns full label when single character")
    func displayLabelSingleChar() {
        let item = PickerItem(id: 0, iconColor: 0, label: "x",
                             description: "", annotation: "",
                             matchPositions: [], isTwoLine: false, isMarked: false)
        #expect(item.displayLabel == "x")
    }

    @Test("displayMatchPositions keeps plain label positions")
    func matchPositionPlainLabel() {
        let item = PickerItem(id: 0, iconColor: 0, label: "editor.ex",
                             description: "", annotation: "",
                             matchPositions: [0, 1, 4], isTwoLine: false, isMarked: false)
        #expect(item.displayMatchPositions == Set([0, 1, 4]))
    }

    @Test("displayMatchPositions adjusts for icon and spacer")
    func matchPositionIconAdjustment() {
        // Label: "icon lib" -> displayLabel="lib"
        // Match positions in the removed icon/spacer prefix are filtered out.
        let item = PickerItem(id: 0, iconColor: 0x51AFEF, label: "\u{F024B} lib",
                             description: "", annotation: "",
                             matchPositions: [0, 2, 4], isTwoLine: false, isMarked: false)
        #expect(item.displayMatchPositions == Set([0, 2]))
    }

    @Test("displayMatchPositions with no matches returns empty set")
    func matchPositionEmpty() {
        let item = PickerItem(id: 0, iconColor: 0, label: "test",
                             description: "", annotation: "",
                             matchPositions: [], isTwoLine: false, isMarked: false)
        #expect(item.displayMatchPositions.isEmpty)
    }

    @Test("displayMatchPositions filters positions beyond label range")
    func matchPositionOutOfRange() {
        let item = PickerItem(id: 0, iconColor: 0, label: "ab",
                             description: "", annotation: "",
                             matchPositions: [5], isTwoLine: false, isMarked: false)
        #expect(item.displayMatchPositions.isEmpty)
    }
}

// MARK: - GUIHighlightSpan attribute flags

@Suite("GUIHighlightSpan Attribute Flags")
struct HighlightSpanFlagTests {

    @Test("Bold flag is bit 0")
    func boldFlag() {
        let span = GUIHighlightSpan(startCol: 0, endCol: 5, fg: 0, bg: 0,
                                     attrs: 0x01, fontWeight: 0, fontId: 0)
        #expect(span.isBold == true)
        #expect(span.isItalic == false)
        #expect(span.isUnderline == false)
    }

    @Test("Italic flag is bit 1")
    func italicFlag() {
        let span = GUIHighlightSpan(startCol: 0, endCol: 5, fg: 0, bg: 0,
                                     attrs: 0x02, fontWeight: 0, fontId: 0)
        #expect(span.isBold == false)
        #expect(span.isItalic == true)
    }

    @Test("Underline flag is bit 2")
    func underlineFlag() {
        let span = GUIHighlightSpan(startCol: 0, endCol: 5, fg: 0, bg: 0,
                                     attrs: 0x04, fontWeight: 0, fontId: 0)
        #expect(span.isUnderline == true)
    }

    @Test("Strikethrough flag is bit 3")
    func strikethroughFlag() {
        let span = GUIHighlightSpan(startCol: 0, endCol: 5, fg: 0, bg: 0,
                                     attrs: 0x08, fontWeight: 0, fontId: 0)
        #expect(span.isStrikethrough == true)
    }

    @Test("Curl flag is bit 4")
    func curlFlag() {
        let span = GUIHighlightSpan(startCol: 0, endCol: 5, fg: 0, bg: 0,
                                     attrs: 0x10, fontWeight: 0, fontId: 0)
        #expect(span.isCurl == true)
    }

    @Test("Combined bold+italic+underline")
    func combinedFlags() {
        let span = GUIHighlightSpan(startCol: 0, endCol: 5, fg: 0, bg: 0,
                                     attrs: 0x07, fontWeight: 0, fontId: 0)
        #expect(span.isBold == true)
        #expect(span.isItalic == true)
        #expect(span.isUnderline == true)
        #expect(span.isStrikethrough == false)
        #expect(span.isCurl == false)
    }
}

// MARK: - CursorShape

@Suite("CursorShape Raw Values")
struct CursorShapeTests {

    @Test("Block is 0x00")
    func block() {
        #expect(CursorShape.block.rawValue == 0x00)
    }

    @Test("Beam is 0x01")
    func beam() {
        #expect(CursorShape.beam.rawValue == 0x01)
    }

    @Test("Underline is 0x02")
    func underline() {
        #expect(CursorShape.underline.rawValue == 0x02)
    }
}

// MARK: - WhichKeyBinding

@Suite("WhichKeyBinding Computed Properties")
struct WhichKeyBindingTests {

    @Test("isGroup is true when kind == 1")
    func isGroupTrue() {
        let binding = WhichKeyBinding(id: 0, isGroup: true, key: "b",
                                      description: "Buffers", icon: "")
        #expect(binding.isGroup == true)
    }

    @Test("isGroup is false when kind == 0")
    func isGroupFalse() {
        let binding = WhichKeyBinding(id: 0, isGroup: false, key: "f",
                                      description: "Find file", icon: "🔍")
        #expect(binding.isGroup == false)
    }
}

// MARK: - FileTreeState and FileTreeEntry computed state

@Suite("FileTreeState and FileTreeEntry Computed State")
struct FileTreeStateComputedTests {

    @Test("BEAM protocol fields drive active dirty selected and git state")
    @MainActor func protocolFieldsDriveSemanticState() {
        let state = FileTreeState()
        state.update(version: 2, selectedId: "/project/lib/editor.ex", focused: false, treeWidth: 30, rootPath: "/project", rawEntries: [
            computedWireFileTreeEntry(id: "/project/lib/editor.ex", isSelected: true, isFocused: false, isActive: true, isDirty: true, gitStatus: 4),
        ])

        let entry = state.entries[0]
        #expect(entry.id == "/project/lib/editor.ex")
        #expect(entry.isSelected == true)
        #expect(entry.isFocused == false)
        #expect(entry.isActive == true)
        #expect(entry.isDirty == true)
        #expect(entry.gitStatusValue == .conflict)
        #expect(entry.showsActiveAccent == true)
        #expect(entry.showsDirtyMarker == true)
        #expect(entry.showsGitMarker == true)
        #expect(entry.hasConflictStatus == true)
    }

    @Test("Diagnostic severity uses error warning info hint priority")
    @MainActor func diagnosticSeverityUsesPriority() {
        let state = FileTreeState()
        state.update(version: 2, selectedId: "/project/lib/editor.ex", focused: false, treeWidth: 30, rootPath: "/project", rawEntries: [
            computedWireFileTreeEntry(id: "/project/lib/editor.ex", isSelected: false, isFocused: false, isActive: false, isDirty: false, gitStatus: 0, diagnosticErrorCount: 0, diagnosticWarningCount: 2, diagnosticInfoCount: 5, diagnosticHintCount: 8),
        ])

        let entry = state.entries[0]
        #expect(entry.highestDiagnosticSeverity == .warning)
        #expect(entry.highestDiagnosticCount == 2)
    }

    @Test("Dirty marker is suppressed for directories")
    @MainActor func directoryDirtyMarkerSuppressed() {
        let entry = computedFileTreeEntry(path: "/project/lib", relPath: "lib", isDir: true, isDirty: true)
        #expect(entry.showsDirtyMarker == false)
    }
}

// MARK: - FileTreeState fullPath

@Suite("FileTreeState Path Computation")
struct FileTreePathTests {

    @Test("fullPath with empty projectRoot returns relPath")
    @MainActor func emptyRoot() {
        let state = FileTreeState()
        state.projectRoot = ""
        let entry = computedFileTreeEntry(path: "", relPath: "lib/test.ex")
        #expect(state.fullPath(for: entry) == "lib/test.ex")
    }

    @Test("fullPath with empty relPath returns relPath")
    @MainActor func emptyRelPath() {
        let state = FileTreeState()
        state.projectRoot = "/project"
        let entry = computedFileTreeEntry(path: "", relPath: "")
        #expect(state.fullPath(for: entry) == "")
    }
}

private func computedFileTreeEntry(path: String, relPath: String, isDir: Bool = false, isDirty: Bool = false) -> FileTreeEntry {
    FileTreeEntry(id: relPath, pathHash: 1, index: 0, isDir: isDir, isExpanded: false, isSelected: false,
                  isFocused: false, isActive: false, isDirty: isDirty, isEditing: false,
                  isLastChild: false, depth: 0, gitStatus: 0, diagnosticErrorCount: 0,
                  diagnosticWarningCount: 0, diagnosticInfoCount: 0, diagnosticHintCount: 0,
                  guides: [], icon: "",
                  iconColor: Color(red: 0x6D / 255, green: 0x80 / 255, blue: 0x86 / 255),
                  name: "test", relPath: relPath, path: path,
                  editingType: 0xFF, editingText: "")
}

private func computedWireFileTreeEntry(id: String, isSelected: Bool, isFocused: Bool, isActive: Bool, isDirty: Bool, gitStatus: UInt8, diagnosticErrorCount: UInt16 = 0, diagnosticWarningCount: UInt16 = 0, diagnosticInfoCount: UInt16 = 0, diagnosticHintCount: UInt16 = 0) -> Wire.FileTreeEntry {
    Wire.FileTreeEntry(pathHash: 1, id: id, path: id, isDir: false, isExpanded: false,
                       isSelected: isSelected, isFocused: isFocused, isActive: isActive,
                       isDirty: isDirty, isEditing: false, isLastChild: false, depth: 0,
                       gitStatus: gitStatus, diagnosticErrorCount: diagnosticErrorCount, diagnosticWarningCount: diagnosticWarningCount,
                       diagnosticInfoCount: diagnosticInfoCount, diagnosticHintCount: diagnosticHintCount, guides: [], icon: "",
                       iconColorR: 0x6D, iconColorG: 0x80, iconColorB: 0x86,
                       name: "editor.ex", relPath: "lib/editor.ex", editingType: 0xFF,
                       editingText: "")
}
