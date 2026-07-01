/// Observable file tree state driven by the BEAM via gui_file_tree protocol messages.

import SwiftUI
import MingaProtocol

private enum FileTreeProtocolConstants {
    static let localNavigationFlag: UInt8 = 0x20
}

/// A single file tree entry for SwiftUI rendering.
public struct FileTreeEntry: Identifiable {
    /// Visual states are layered in the same priority order as the BEAM TUI renderer: inline editing, drop target, selected row, active file, dirty buffer, git status, then directory emphasis.
    /// Stable semantic row identity sent by the BEAM. SwiftUI uses this as the row identity so hover, drop, and diffing state cannot collide on a 32-bit hash.
    public let id: String
    /// Stable 32-bit hash sent by the BEAM for protocol/debug parity. It is not used as SwiftUI identity because hashes can collide.
    public let pathHash: UInt32
    /// Array index within the current visible entries. Used for click actions
    /// (the BEAM expects an index, not a hash).
    public let index: Int
    public let isDir: Bool
    public let isExpanded: Bool
    public let isSelected: Bool
    public let isFocused: Bool
    public let isActive: Bool
    public let isDirty: Bool
    public let isEditing: Bool
    public let isLastChild: Bool
    public let depth: Int
    public let gitStatus: UInt8
    public let diagnosticErrorCount: UInt16
    public let diagnosticWarningCount: UInt16
    public let diagnosticInfoCount: UInt16
    public let diagnosticHintCount: UInt16
    public let guides: [Bool]
    public let icon: String
    /// Per-row icon color resolved from the active theme's icon palette by the BEAM.
    public let iconColor: Color
    public let name: String
    /// Path relative to the project root (e.g., "lib/minga/editor.ex").
    public let relPath: String
    /// Absolute path sent by the BEAM. Swift renders this value but does not infer filesystem state from it.
    public let path: String
    /// 0=new_file, 1=new_folder, 2=rename. Only meaningful when isEditing is true.
    public let editingType: UInt8
    /// Pre-filled text for the editing field. Only meaningful when isEditing is true.
    public let editingText: String
    /// Extension-contributed familiarity/heat bucket 0...4, or 255 for none.
    public let heatLevel: UInt8

    public init(
        id: String,
        pathHash: UInt32,
        index: Int,
        isDir: Bool,
        isExpanded: Bool,
        isSelected: Bool,
        isFocused: Bool,
        isActive: Bool,
        isDirty: Bool,
        isEditing: Bool,
        isLastChild: Bool,
        depth: Int,
        gitStatus: UInt8,
        diagnosticErrorCount: UInt16,
        diagnosticWarningCount: UInt16,
        diagnosticInfoCount: UInt16,
        diagnosticHintCount: UInt16,
        guides: [Bool],
        icon: String,
        iconColor: Color,
        name: String,
        relPath: String,
        path: String,
        editingType: UInt8,
        editingText: String,
        heatLevel: UInt8 = 255
    ) {
        self.id = id
        self.pathHash = pathHash
        self.index = index
        self.isDir = isDir
        self.isExpanded = isExpanded
        self.isSelected = isSelected
        self.isFocused = isFocused
        self.isActive = isActive
        self.isDirty = isDirty
        self.isEditing = isEditing
        self.isLastChild = isLastChild
        self.depth = depth
        self.gitStatus = gitStatus
        self.diagnosticErrorCount = diagnosticErrorCount
        self.diagnosticWarningCount = diagnosticWarningCount
        self.diagnosticInfoCount = diagnosticInfoCount
        self.diagnosticHintCount = diagnosticHintCount
        self.guides = guides
        self.icon = icon
        self.iconColor = iconColor
        self.name = name
        self.relPath = relPath
        self.path = path
        self.editingType = editingType
        self.editingText = editingText
        self.heatLevel = heatLevel
    }

    public func withSelection(isSelected: Bool, isFocused: Bool) -> FileTreeEntry {
        FileTreeEntry(
            id: id,
            pathHash: pathHash,
            index: index,
            isDir: isDir,
            isExpanded: isExpanded,
            isSelected: isSelected,
            isFocused: isFocused,
            isActive: isActive,
            isDirty: isDirty,
            isEditing: isEditing,
            isLastChild: isLastChild,
            depth: depth,
            gitStatus: gitStatus,
            diagnosticErrorCount: diagnosticErrorCount,
            diagnosticWarningCount: diagnosticWarningCount,
            diagnosticInfoCount: diagnosticInfoCount,
            diagnosticHintCount: diagnosticHintCount,
            guides: guides,
            icon: icon,
            iconColor: iconColor,
            name: name,
            relPath: relPath,
            path: path,
            editingType: editingType,
            editingText: editingText,
            heatLevel: heatLevel
        )
    }

    /// Familiarity tint for the row background, or nil when the row carries no
    /// heat decoration. Warmer (more familiar) reads as a faint amber; cooler
    /// (unfamiliar) as a faint blue. Levels: 0 coldest ... 4 warmest.
    public var heatTint: Color? {
        let cool = Color(red: 0.36, green: 0.54, blue: 0.92)
        let warm = Color(red: 0.95, green: 0.70, blue: 0.30)
        switch heatLevel {
        case 0: return cool.opacity(0.22)
        case 1: return cool.opacity(0.12)
        case 2: return nil
        case 3: return warm.opacity(0.12)
        case 4: return warm.opacity(0.22)
        default: return nil
        }
    }
}

public enum FileTreeGitStatus: UInt8 {
    case clean = 0
    case modified = 1
    case staged = 2
    case untracked = 3
    case conflict = 4
    case renamed = 5
    case deleted = 6
}

public enum FileTreeDiagnosticSeverity {
    case error
    case warning
    case info
    case hint
}

/// Explicit sidebar state sent by the BEAM. Row count alone is not enough because hidden, loading, empty, and error states can all have zero rows.
public enum FileTreeVisibilityState: UInt8 {
    case hidden = 0
    case loading = 1
    case empty = 2
    case ready = 3
    case error = 4
}

extension FileTreeEntry {
    public var gitStatusValue: FileTreeGitStatus {
        FileTreeGitStatus(rawValue: gitStatus) ?? .clean
    }

    public var showsActiveAccent: Bool {
        isActive && !isEditing
    }

    public var showsDirtyMarker: Bool {
        isDirty && !isDir
    }

    public var showsGitMarker: Bool {
        gitStatusValue != .clean
    }

    public var hasConflictStatus: Bool {
        gitStatusValue == .conflict
    }

    public var highestDiagnosticSeverity: FileTreeDiagnosticSeverity? {
        if diagnosticErrorCount > 0 { return .error }
        if diagnosticWarningCount > 0 { return .warning }
        if diagnosticInfoCount > 0 { return .info }
        if diagnosticHintCount > 0 { return .hint }
        return nil
    }

    public var highestDiagnosticCount: UInt16 {
        switch highestDiagnosticSeverity {
        case .error: return diagnosticErrorCount
        case .warning: return diagnosticWarningCount
        case .info: return diagnosticInfoCount
        case .hint: return diagnosticHintCount
        case nil: return 0
        }
    }

}

/// Observable state for the file tree sidebar, driven by BEAM protocol messages.
@MainActor
@Observable
public final class FileTreeState {
    public init(entries: [FileTreeEntry] = [], version: UInt8 = 1, selectedId: String = "", selectedIndex: Int = 0, treeWidth: Int = 30, visible: Bool = false, focused: Bool = false, localNavigationEnabled: Bool = false, treeState: FileTreeVisibilityState = .hidden, errorReason: String = "", projectRoot: String = "", editingIndex: Int? = nil) {
        self.entries = entries
        self.version = version
        self.selectedId = selectedId
        self.selectedIndex = selectedIndex
        self.treeWidth = treeWidth
        self.visible = visible
        self.focused = focused
        self.localNavigationEnabled = localNavigationEnabled
        self.treeState = treeState
        self.errorReason = errorReason
        self.projectRoot = projectRoot
        self.editingIndex = editingIndex
    }
    public var entries: [FileTreeEntry] = []
    public var version: UInt8 = 1
    public var selectedId: String = ""
    public var selectedIndex: Int = 0
    public var treeWidth: Int = 30
    public var visible: Bool = false
    public var focused: Bool = false
    public var localNavigationEnabled: Bool = false
    public var treeState: FileTreeVisibilityState = .hidden
    public var errorReason: String = ""
    /// Project root path sent by the BEAM (e.g., "/Users/foo/myproject").
    public var projectRoot: String = ""
    /// Index of the entry currently being edited, or nil if no editing is active.
    public var editingIndex: Int? = nil

    /// Update from a decoded gui_file_tree protocol message.
    ///
    /// The BEAM-side fingerprint caching (phash2 of the entire FileTree
    /// struct) is the primary guard against redundant sends. When this
    /// function is called, the tree data has genuinely changed and the
    /// array rebuild is necessary (git status, file renames, expand/collapse
    /// can change entry content without changing count or selection).
    public func update(
        version: UInt8,
        treeFlags: UInt8 = 0,
        selectedId: String,
        focused: Bool,
        treeWidth: UInt16,
        rootPath: String,
        rawEntries: [Wire.FileTreeEntry],
        treeState: UInt8 = FileTreeVisibilityState.ready.rawValue,
        errorReason: String = ""
    ) {
        let decodedState = FileTreeVisibilityState(rawValue: treeState) ?? .ready
        self.version = version
        self.selectedId = selectedId
        self.selectedIndex = rawEntries.firstIndex(where: { $0.id == selectedId }) ?? 0
        self.treeWidth = Int(treeWidth)
        self.projectRoot = rootPath
        self.visible = decodedState != .hidden
        self.focused = focused
        self.localNavigationEnabled = treeFlags & FileTreeProtocolConstants.localNavigationFlag != 0
        self.treeState = decodedState
        self.errorReason = errorReason
        self.entries = rawEntries.enumerated().map { index, entry in
            FileTreeEntry(
                id: entry.id,
                pathHash: entry.pathHash,
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
                iconColor: Color(
                    red: Double(entry.iconColorR) / 255.0,
                    green: Double(entry.iconColorG) / 255.0,
                    blue: Double(entry.iconColorB) / 255.0
                ),
                name: entry.name,
                relPath: entry.relPath,
                path: entry.path,
                editingType: entry.editingType,
                editingText: entry.editingText,
                heatLevel: entry.heatLevel
            )
        }
        // Track which entry is being edited for quick lookup
        self.editingIndex = rawEntries.firstIndex(where: { $0.isEditing })
    }

    /// Updates selection and focus without replacing the full tree payload.
    public func updateSelection(selectedId: String, focused: Bool) {
        guard let selectedIndex = entries.firstIndex(where: { $0.id == selectedId }) else {
            self.focused = focused
            self.entries = entries.map { entry in
                entry.withSelection(isSelected: entry.isSelected, isFocused: focused)
            }
            return
        }

        applySelection(selectedIndex: selectedIndex, focused: focused)
    }

    /// Applies a frontend-local row navigation preview over the last committed tree model.
    /// The BEAM remains authoritative: the next gui_file_tree or gui_file_tree_selection payload reconciles this optimistic selection.
    @discardableResult
    public func previewNavigation(delta: Int) -> Bool {
        guard visible, focused, localNavigationEnabled, treeState == .ready, editingIndex == nil, !entries.isEmpty else {
            return false
        }

        let nextIndex = min(max(selectedIndex + delta, 0), entries.count - 1)
        guard nextIndex != selectedIndex else { return false }

        applySelection(selectedIndex: nextIndex, focused: focused)
        return true
    }

    private func applySelection(selectedIndex: Int, focused: Bool) {
        guard entries.indices.contains(selectedIndex) else { return }

        let previousIndex = self.selectedIndex
        let selectedId = entries[selectedIndex].id
        let focusChanged = self.focused != focused
        var nextEntries = entries

        if focusChanged {
            nextEntries = nextEntries.map { entry in
                entry.withSelection(isSelected: entry.id == selectedId, isFocused: focused)
            }
        } else {
            if nextEntries.indices.contains(previousIndex), previousIndex != selectedIndex {
                nextEntries[previousIndex] = nextEntries[previousIndex].withSelection(isSelected: false, isFocused: focused)
            }

            nextEntries[selectedIndex] = nextEntries[selectedIndex].withSelection(isSelected: true, isFocused: focused)
        }

        self.selectedId = selectedId
        self.selectedIndex = selectedIndex
        self.focused = focused
        self.entries = nextEntries
    }

    /// Computes the full absolute path for an entry.
    public func fullPath(for entry: FileTreeEntry) -> String {
        if !entry.path.isEmpty { return entry.path }
        guard !projectRoot.isEmpty, !entry.relPath.isEmpty else { return entry.relPath }
        return (projectRoot as NSString).appendingPathComponent(entry.relPath)
    }

    /// Resolves the current entry for a stable row identifier.
    public func entry(withID id: String) -> FileTreeEntry? {
        entries.first { $0.id == id }
    }

    /// Hide the file tree (BEAM toggled it off) and keep the shared window chrome in sync with the latest project root.
    public func hide(rootPath: String = "") {
        visible = false
        focused = false
        localNavigationEnabled = false
        treeState = .hidden
        errorReason = ""
        entries = []
        selectedId = ""
        editingIndex = nil
        projectRoot = rootPath
    }
}
