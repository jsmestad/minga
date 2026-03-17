/// Observable file tree state driven by the BEAM via gui_file_tree protocol messages.

import SwiftUI

/// A single file tree entry for SwiftUI rendering.
struct FileTreeEntry: Identifiable {
    /// Use the array index as ID since paths can be long and we rebuild every update.
    let id: Int
    let isDir: Bool
    let isExpanded: Bool
    let isSelected: Bool
    let depth: Int
    let gitStatus: UInt8
    let icon: String
    let name: String
}

/// Observable state for the file tree sidebar, driven by BEAM protocol messages.
@MainActor
@Observable
final class FileTreeState {
    var entries: [FileTreeEntry] = []
    var selectedIndex: Int = 0
    var treeWidth: Int = 30
    var visible: Bool = false

    /// Update from a decoded gui_file_tree protocol message.
    func update(selectedIndex: UInt16, treeWidth: UInt16, rawEntries: [GUIFileTreeEntry]) {
        self.selectedIndex = Int(selectedIndex)
        self.treeWidth = Int(treeWidth)
        self.visible = true
        self.entries = rawEntries.enumerated().map { index, entry in
            FileTreeEntry(
                id: index,
                isDir: entry.isDir,
                isExpanded: entry.isExpanded,
                isSelected: entry.isSelected,
                depth: Int(entry.depth),
                gitStatus: entry.gitStatus,
                icon: entry.icon,
                name: entry.name
            )
        }
    }

    /// Hide the file tree (BEAM toggled it off).
    func hide() {
        visible = false
        entries = []
    }
}
