/// Observable tab bar state driven by the BEAM via gui_tab_bar protocol messages.
///
/// Updated by CommandDispatcher when a gui_tab_bar message arrives.
/// SwiftUI views observe this to render the tab strip.

import SwiftUI
import MingaProtocol

/// A single tab entry for SwiftUI rendering.
public struct TabEntry: Identifiable {
    public init(id: UInt32, groupId: UInt16, isActive: Bool, isDirty: Bool, isAgent: Bool, hasAttention: Bool, agentStatus: UInt8, isPinned: Bool, isEphemeral: Bool = false, tintColor: Color? = nil, icon: String, label: String) {
        self.id = id
        self.groupId = groupId
        self.isActive = isActive
        self.isDirty = isDirty
        self.isAgent = isAgent
        self.hasAttention = hasAttention
        self.agentStatus = agentStatus
        self.isPinned = isPinned
        self.isEphemeral = isEphemeral
        self.tintColor = tintColor
        self.icon = icon
        self.label = label
    }
    public let id: UInt32
    public let groupId: UInt16
    public let isActive: Bool
    public let isDirty: Bool
    public let isAgent: Bool
    public let hasAttention: Bool
    public let agentStatus: UInt8
    public let isPinned: Bool
    /// File tab backed by no file on disk (e.g. Untitled-1).
    public let isEphemeral: Bool
    public let tintColor: Color?
    public let icon: String
    public let label: String
}

/// A workspace entry for the tab bar capsules and indicator.
public struct WorkspaceEntry: Identifiable {
    public init(id: UInt16, kind: UInt8, agentStatus: UInt8, flags: UInt16, color: Color, tabCount: UInt16, draftCount: UInt16, conflictCount: UInt16, runningBackgroundCount: UInt16, label: String, icon: String) {
        self.id = id
        self.kind = kind
        self.agentStatus = agentStatus
        self.flags = flags
        self.color = color
        self.tabCount = tabCount
        self.draftCount = draftCount
        self.conflictCount = conflictCount
        self.runningBackgroundCount = runningBackgroundCount
        self.label = label
        self.icon = icon
    }
    public let id: UInt16
    public let kind: UInt8
    public let agentStatus: UInt8
    public let flags: UInt16
    public let color: Color
    public let tabCount: UInt16
    public let draftCount: UInt16
    public let conflictCount: UInt16
    public let runningBackgroundCount: UInt16
    public let label: String
    public let icon: String
}

/// A visible file tab entry from the canonical workspace protocol.
public struct WorkspaceTabEntry: Identifiable {
    public init(id: UInt32, workspaceId: UInt16, kind: UInt8, flags: UInt16, pathHash: UInt32, tintColor: Color? = nil, icon: String, label: String, path: String) {
        self.id = id
        self.workspaceId = workspaceId
        self.kind = kind
        self.flags = flags
        self.pathHash = pathHash
        self.tintColor = tintColor
        self.icon = icon
        self.label = label
        self.path = path
    }
    public let id: UInt32
    public let workspaceId: UInt16
    public let kind: UInt8
    public let flags: UInt16
    public let pathHash: UInt32
    public let tintColor: Color?
    public let icon: String
    public let label: String
    public let path: String

    public var isAgent: Bool { kind == 1 }
    public var isDirty: Bool { flags & 0x0001 != 0 }
    public var hasAttention: Bool { flags & 0x0002 != 0 }
    public var isPinned: Bool { flags & 0x0020 != 0 }
    /// File tab backed by no file on disk (e.g. Untitled-1).
    public var isEphemeral: Bool { !isAgent && flags & 0x0040 != 0 }
}

/// Observable state for the tab bar, driven by BEAM protocol messages.
@MainActor
@Observable
public final class TabBarState {
    public init(tabs: [TabEntry] = [], activeIndex: UInt8 = 0, workspaces: [WorkspaceEntry] = [], workspaceTabs: [WorkspaceTabEntry] = [], activeWorkspaceId: UInt16 = 0, workspaceMode: UInt8 = 0, workspaceFlags: UInt8 = 0, hasCanonicalWorkspaceTabs: Bool = false) {
        self.tabs = tabs
        self.activeIndex = activeIndex
        self.workspaces = workspaces
        self.workspaceTabs = workspaceTabs
        self.activeWorkspaceId = activeWorkspaceId
        self.workspaceMode = workspaceMode
        self.workspaceFlags = workspaceFlags
        self.hasCanonicalWorkspaceTabs = hasCanonicalWorkspaceTabs
    }
    public var tabs: [TabEntry] = []
    /// Visible-tab active index from gui_tab_bar, or 255 when the active tab is hidden.
    public var activeIndex: UInt8 = 0
    public var workspaces: [WorkspaceEntry] = []
    public var workspaceTabs: [WorkspaceTabEntry] = []
    public var activeWorkspaceId: UInt16 = 0
    public var workspaceMode: UInt8 = 0
    public var workspaceFlags: UInt8 = 0
    public var hasCanonicalWorkspaceTabs: Bool = false

    /// Whether any agent workspaces exist (controls visibility of group UI).
    public var hasWorkspaces: Bool {
        !workspaces.isEmpty
    }

    /// The active agent workspace, if the active tab belongs to one. Nil when
    /// the user is viewing the manual workspace.
    public var activeWorkspace: WorkspaceEntry? {
        workspaces.first { $0.id == activeWorkspaceId }
    }

    /// Update from a decoded gui_tab_bar protocol message.
    public func update(activeIndex: UInt8, entries: [Wire.TabEntry]) {
        self.activeIndex = activeIndex
        self.tabs = entries.map { entry in
            TabEntry(
                id: entry.id,
                groupId: entry.groupId,
                isActive: entry.isActive,
                isDirty: entry.isDirty,
                isAgent: entry.isAgent,
                hasAttention: entry.hasAttention,
                agentStatus: entry.agentStatus,
                isPinned: entry.isPinned,
                isEphemeral: entry.isEphemeral,
                tintColor: Self.color(from: entry.tintColorRGB),
                icon: entry.icon,
                label: entry.label
            )
        }
    }

    /// Update from a decoded gui_workspaces protocol message.
    public func updateWorkspaces(activeWorkspaceId: UInt16, mode: UInt8, flags: UInt8, entries: [Wire.WorkspaceEntry], visibleTabs: [Wire.WorkspaceTabEntry]) {
        self.activeWorkspaceId = activeWorkspaceId
        self.workspaceMode = mode
        self.workspaceFlags = flags
        self.hasCanonicalWorkspaceTabs = true
        self.workspaces = entries.map { entry in
            WorkspaceEntry(
                id: entry.id,
                kind: entry.kind,
                agentStatus: entry.agentStatus,
                flags: entry.flags,
                color: Color(
                    .sRGB,
                    red: Double(entry.colorR) / 255.0,
                    green: Double(entry.colorG) / 255.0,
                    blue: Double(entry.colorB) / 255.0
                ),
                tabCount: entry.tabCount,
                draftCount: entry.draftCount,
                conflictCount: entry.conflictCount,
                runningBackgroundCount: entry.runningBackgroundCount,
                label: entry.label,
                icon: entry.icon
            )
        }
        self.workspaceTabs = visibleTabs.map { entry in
            WorkspaceTabEntry(
                id: entry.id,
                workspaceId: entry.workspaceId,
                kind: entry.kind,
                flags: entry.flags,
                pathHash: entry.pathHash,
                tintColor: Self.color(from: entry.tintColorRGB),
                icon: entry.icon,
                label: entry.label,
                path: entry.path
            )
        }
    }

    private static func color(from rgb: UInt32) -> Color? {
        guard rgb != 0 else { return nil }
        return Color(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }

    // MARK: - Display tabs

    public var displayTabs: [TabEntry] {
        if hasCanonicalWorkspaceTabs {
            return workspaceTabs.enumerated().map { index, tab in
                TabEntry(
                    id: tab.id,
                    groupId: tab.workspaceId,
                    isActive: index == Int(activeIndex),
                    isDirty: tab.isDirty,
                    isAgent: tab.isAgent,
                    hasAttention: tab.hasAttention,
                    agentStatus: 0,
                    isPinned: tab.isPinned,
                    isEphemeral: tab.isEphemeral,
                    tintColor: tab.tintColor,
                    icon: tab.icon,
                    label: tab.label
                )
            }
        }

        return tabs
    }

    // MARK: - Tab ordering

    public func canMoveTabLeft(_ tab: TabEntry) -> Bool {
        guard let index = movableFileTabIndex(for: tab) else { return false }
        return index > 0
    }

    public func canMoveTabRight(_ tab: TabEntry) -> Bool {
        guard let index = movableFileTabIndex(for: tab) else { return false }
        return index < movableFileTabs(for: tab).count - 1
    }

    public func tabDropReorder(droppedTabs: [TabDragPayload], target tab: TabEntry, visibleIndex _: Int) -> (id: UInt32, newIndex: UInt16)? {
        guard let draggedId = droppedTabs.first?.id,
              draggedId != tab.id else {
            return nil
        }
        guard let draggedTab = displayTabs.first(where: { $0.id == draggedId }),
              draggedTab.groupId == tab.groupId,
              draggedTab.isPinned == tab.isPinned else {
            return nil
        }
        guard let newIndex = visibleFileTabIndex(for: tab) else {
            return nil
        }
        return (draggedId, UInt16(newIndex))
    }

    public func movableFileTabIndex(for tab: TabEntry) -> Int? {
        movableFileTabs(for: tab).firstIndex { $0.id == tab.id }
    }

    public func visibleFileTabIndex(for tab: TabEntry) -> Int? {
        visibleFileTabs(for: tab).firstIndex { $0.id == tab.id }
    }

    private func movableTabs(for tab: TabEntry) -> [TabEntry] {
        displayTabs.filter { candidate in
            candidate.groupId == tab.groupId && candidate.isPinned == tab.isPinned
        }
    }

    private func movableFileTabs(for tab: TabEntry) -> [TabEntry] {
        movableTabs(for: tab).filter { !$0.isAgent }
    }

    private func visibleFileTabs(for tab: TabEntry) -> [TabEntry] {
        displayTabs.filter { candidate in
            candidate.groupId == tab.groupId && !candidate.isAgent
        }
    }

    /// Clear all tab state.
    public func hide() {
        tabs = []
        activeIndex = 0
        workspaces = []
        workspaceTabs = []
        activeWorkspaceId = 0
        workspaceMode = 0
        workspaceFlags = 0
        hasCanonicalWorkspaceTabs = false
    }
}
