/// Observable tab bar state driven by the BEAM via gui_tab_bar protocol messages.
///
/// Updated by CommandDispatcher when a gui_tab_bar message arrives.
/// SwiftUI views observe this to render the tab strip.

import SwiftUI

/// A single tab entry for SwiftUI rendering.
struct TabEntry: Identifiable {
    let id: UInt32
    let groupId: UInt16
    let isActive: Bool
    let isDirty: Bool
    let isAgent: Bool
    let hasAttention: Bool
    let agentStatus: UInt8
    let icon: String
    let label: String
}

/// A workspace entry for the tab bar capsules and indicator.
struct WorkspaceEntry: Identifiable {
    let id: UInt16
    let kind: UInt8
    let agentStatus: UInt8
    let flags: UInt16
    let color: Color
    let tabCount: UInt16
    let draftCount: UInt16
    let conflictCount: UInt16
    let runningBackgroundCount: UInt16
    let label: String
    let icon: String
}

/// A visible file tab entry from the canonical workspace protocol.
struct WorkspaceTabEntry: Identifiable {
    let id: UInt32
    let workspaceId: UInt16
    let kind: UInt8
    let flags: UInt16
    let pathHash: UInt32
    let icon: String
    let label: String
    let path: String

    var isDirty: Bool { flags & 0x0001 != 0 }
    var hasAttention: Bool { flags & 0x0002 != 0 }
}

/// Observable state for the tab bar, driven by BEAM protocol messages.
@MainActor
@Observable
final class TabBarState {
    var tabs: [TabEntry] = []
    /// Visible-tab active index from gui_tab_bar, or 255 when the active tab is hidden.
    var activeIndex: UInt8 = 0
    var workspaces: [WorkspaceEntry] = []
    var workspaceTabs: [WorkspaceTabEntry] = []
    var activeWorkspaceId: UInt16 = 0
    var workspaceMode: UInt8 = 0
    var workspaceFlags: UInt8 = 0
    var hasCanonicalWorkspaceTabs: Bool = false

    /// Whether any agent workspaces exist (controls visibility of group UI).
    var hasWorkspaces: Bool {
        !workspaces.isEmpty
    }

    /// The active agent workspace, if the active tab belongs to one. Nil when
    /// the user is viewing the manual workspace.
    var activeWorkspace: WorkspaceEntry? {
        workspaces.first { $0.id == activeWorkspaceId }
    }

    /// Update from a decoded gui_tab_bar protocol message.
    func update(activeIndex: UInt8, entries: [Wire.TabEntry]) {
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
                icon: entry.icon,
                label: entry.label
            )
        }
    }

    /// Update from a decoded gui_workspaces protocol message.
    func updateWorkspaces(activeWorkspaceId: UInt16, mode: UInt8, flags: UInt8, entries: [Wire.WorkspaceEntry], visibleTabs: [Wire.WorkspaceTabEntry]) {
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
                icon: entry.icon,
                label: entry.label,
                path: entry.path
            )
        }
    }

    /// Clear all tab state.
    func hide() {
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
