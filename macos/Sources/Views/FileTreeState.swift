/// Observable file tree state driven by the BEAM via gui_file_tree protocol messages.

import SwiftUI

/// A single file tree entry for SwiftUI rendering.
struct FileTreeEntry: Identifiable {
    /// Stable 32-bit hash of the file path, sent by the BEAM. Persists across
    /// tree updates so SwiftUI's diffing correctly identifies unchanged rows
    /// instead of treating every row below a change as new.
    let id: UInt32
    /// Array index within the current visible entries. Used for click actions
    /// (the BEAM expects an index, not a hash).
    let index: Int
    let isDir: Bool
    let isExpanded: Bool
    let isSelected: Bool
    let isFocused: Bool
    let isActive: Bool
    let isDirty: Bool
    let isEditing: Bool
    let isLastChild: Bool
    let depth: Int
    let gitStatus: UInt8
    let diagnosticErrorCount: UInt16
    let diagnosticWarningCount: UInt16
    let diagnosticInfoCount: UInt16
    let diagnosticHintCount: UInt16
    let guides: [Bool]
    let icon: String
    let name: String
    /// Path relative to the project root (e.g., "lib/minga/editor.ex").
    let relPath: String
    /// Absolute path sent by the BEAM. Swift renders this value but does not infer filesystem state from it.
    let path: String
    /// 0=new_file, 1=new_folder, 2=rename. Only meaningful when isEditing is true.
    let editingType: UInt8
    /// Pre-filled text for the editing field. Only meaningful when isEditing is true.
    let editingText: String
}

/// Observable state for the file tree sidebar, driven by BEAM protocol messages.
@MainActor
@Observable
final class FileTreeState {
    var entries: [FileTreeEntry] = []
    var version: UInt8 = 1
    var selectedId: String = ""
    var selectedIndex: Int = 0
    var treeWidth: Int = 30
    var visible: Bool = false
    var focused: Bool = false
    /// Project root path sent by the BEAM (e.g., "/Users/foo/myproject").
    var projectRoot: String = ""
    /// Index of the entry currently being edited, or nil if no editing is active.
    var editingIndex: Int? = nil

    /// Update from a decoded gui_file_tree protocol message.
    ///
    /// The BEAM-side fingerprint caching (phash2 of the entire FileTree
    /// struct) is the primary guard against redundant sends. When this
    /// function is called, the tree data has genuinely changed and the
    /// array rebuild is necessary (git status, file renames, expand/collapse
    /// can change entry content without changing count or selection).
    func update(version: UInt8, selectedId: String, focused: Bool, treeWidth: UInt16, rootPath: String, rawEntries: [Wire.FileTreeEntry]) {
        self.version = version
        self.selectedId = selectedId
        self.selectedIndex = rawEntries.firstIndex(where: { $0.id == selectedId }) ?? 0
        self.treeWidth = Int(treeWidth)
        self.projectRoot = rootPath
        self.visible = true
        self.focused = focused
        self.entries = rawEntries.enumerated().map { index, entry in
            FileTreeEntry(
                id: entry.pathHash,
                index: index,
                isDir: entry.isDir,
                isExpanded: entry.isExpanded,
                isSelected: entry.isSelected,
                isFocused: entry.isFocused,
                isActive: entry.isActive,
                isDirty: entry.isDirty,
                isEditing: entry.isEditing,
                isLastChild: entry.isLastChild,
                depth: Int(entry.depth),
                gitStatus: entry.gitStatus,
                diagnosticErrorCount: entry.diagnosticErrorCount,
                diagnosticWarningCount: entry.diagnosticWarningCount,
                diagnosticInfoCount: entry.diagnosticInfoCount,
                diagnosticHintCount: entry.diagnosticHintCount,
                guides: entry.guides,
                icon: entry.icon,
                name: entry.name,
                relPath: entry.relPath,
                path: entry.path,
                editingType: entry.editingType,
                editingText: entry.editingText
            )
        }
        // Track which entry is being edited for quick lookup
        self.editingIndex = rawEntries.firstIndex(where: { $0.isEditing })
    }

    /// Computes the full absolute path for an entry.
    func fullPath(for entry: FileTreeEntry) -> String {
        if !entry.path.isEmpty { return entry.path }
        guard !projectRoot.isEmpty, !entry.relPath.isEmpty else { return entry.relPath }
        return (projectRoot as NSString).appendingPathComponent(entry.relPath)
    }

    /// Hide the file tree (BEAM toggled it off) and keep the shared window chrome in sync with the latest project root.
    func hide(rootPath: String = "") {
        visible = false
        focused = false
        entries = []
        selectedId = ""
        editingIndex = nil
        projectRoot = rootPath
    }
}
