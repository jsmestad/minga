/// Observable tab bar state driven by the BEAM via gui_tab_bar protocol messages.
///
/// Updated by CommandDispatcher when a gui_tab_bar message arrives.
/// SwiftUI views observe this to render the tab strip.

import SwiftUI
import MingaProtocol

/// A single tab entry for SwiftUI rendering.
public struct TabEntry: Identifiable {
    public init(id: UInt32, groupId: UInt16, isActive: Bool, isDirty: Bool, isAgent: Bool, hasAttention: Bool, agentStatus: AgentStatus, isPinned: Bool, isEphemeral: Bool = false, tintColor: Color? = nil, icon: String, label: String) {
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
    public init(id: UInt32, groupId: UInt16, isActive: Bool, isDirty: Bool, isAgent: Bool, hasAttention: Bool, agentStatus: UInt8, isPinned: Bool, isEphemeral: Bool = false, tintColor: Color? = nil, icon: String, label: String) {
        self.init(id: id, groupId: groupId, isActive: isActive, isDirty: isDirty, isAgent: isAgent, hasAttention: hasAttention, agentStatus: AgentStatus(rawValue: agentStatus), isPinned: isPinned, isEphemeral: isEphemeral, tintColor: tintColor, icon: icon, label: label)
    }
    public let id: UInt32
    public let groupId: UInt16
    public let isActive: Bool
    public let isDirty: Bool
    public let isAgent: Bool
    public let hasAttention: Bool
    public let agentStatus: AgentStatus
    public let isPinned: Bool
    /// File tab backed by no file on disk (e.g. Untitled-1).
    public let isEphemeral: Bool
    public let tintColor: Color?
    public let icon: String
    public let label: String
}

/// Observable state for the tab bar, driven by BEAM protocol messages.
@MainActor
@Observable
public final class TabBarState {
    public init(tabs: [TabEntry] = [], activeIndex: UInt8 = 0, workspaces: [WorkspacePresentationEntry] = [], workspaceTabs: [WorkspacePresentationTabEntry] = [], activeWorkspaceId: UInt16 = 0, workspaceMode: WorkspaceViewMode = .editor, workspaceFlags: WorkspaceFlags = [], hasCanonicalWorkspaceTabs: Bool = false) {
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
    public var workspaces: [WorkspacePresentationEntry] = []
    public var workspaceTabs: [WorkspacePresentationTabEntry] = []
    public var activeWorkspaceId: UInt16 = 0
    public var workspaceMode: WorkspaceViewMode = .editor
    public var workspaceFlags: WorkspaceFlags = []
    public var hasCanonicalWorkspaceTabs: Bool = false
    public private(set) var workspacePresentationRevision: UInt64 = 0

    /// Whether any agent workspaces exist (controls visibility of group UI).
    public var hasWorkspaces: Bool {
        !workspaces.isEmpty
    }

    /// The active agent workspace, if the active tab belongs to one. Nil when
    /// the user is viewing the manual workspace.
    public var activeWorkspace: WorkspacePresentationEntry? {
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
                tintColor: ChromePresentationColor.optionalColor(from: entry.tintColorRGB),
                icon: entry.icon,
                label: entry.label
            )
        }
    }

    /// Install workspace presentation without changing tab-bar-owned derived behavior.
    public func install(_ snapshot: WorkspacePresentationSnapshot) {
        workspacePresentationRevision += 1
        activeWorkspaceId = snapshot.activeWorkspaceId
        workspaceMode = snapshot.mode
        workspaceFlags = snapshot.flags
        hasCanonicalWorkspaceTabs = true
        workspaces = snapshot.workspaces
        workspaceTabs = snapshot.visibleTabs
    }

    public func isCurrentWorkspace(_ workspace: WorkspacePresentationEntry, presentationRevision: UInt64) -> Bool {
        workspacePresentationRevision == presentationRevision &&
            activeWorkspaceId == workspace.id &&
            workspaces.contains { $0.id == workspace.id }
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
                    agentStatus: .idle,
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
        workspaceMode = .editor
        workspaceFlags = []
        hasCanonicalWorkspaceTabs = false
    }
}
