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
    let depth: Int
    let gitStatus: UInt8
    let icon: String
    let name: String
    /// Path relative to the project root (e.g., "lib/minga/editor.ex").
    let relPath: String
}

/// Observable state for the file tree sidebar, driven by BEAM protocol messages.
@MainActor
@Observable
final class FileTreeState {
    var entries: [FileTreeEntry] = []
    var selectedIndex: Int = 0
    var treeWidth: Int = 30
    var visible: Bool = false
    /// Project root path sent by the BEAM (e.g., "/Users/foo/myproject").
    var projectRoot: String = ""

    /// Update from a decoded gui_file_tree protocol message.
    func update(selectedIndex: UInt16, treeWidth: UInt16, rootPath: String, rawEntries: [GUIFileTreeEntry]) {
        self.selectedIndex = Int(selectedIndex)
        self.treeWidth = Int(treeWidth)
        self.projectRoot = rootPath
        self.visible = true
        self.entries = rawEntries.enumerated().map { index, entry in
            FileTreeEntry(
                id: entry.pathHash,
                index: index,
                isDir: entry.isDir,
                isExpanded: entry.isExpanded,
                isSelected: entry.isSelected,
                depth: Int(entry.depth),
                gitStatus: entry.gitStatus,
                icon: entry.icon,
                name: entry.name,
                relPath: entry.relPath
            )
        }
    }

    /// Computes the full absolute path for an entry.
    func fullPath(for entry: FileTreeEntry) -> String {
        guard !projectRoot.isEmpty, !entry.relPath.isEmpty else { return entry.relPath }
        return (projectRoot as NSString).appendingPathComponent(entry.relPath)
    }

    /// Hide the file tree (BEAM toggled it off).
    func hide() {
        visible = false
        entries = []
        projectRoot = ""
    }
}
