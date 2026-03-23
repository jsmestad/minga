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

/// A workspace entry for the workspace indicator/dropdown.
struct WorkspaceEntry: Identifiable {
    let id: UInt16
    let kind: UInt8       // 0 = manual, 1 = agent
    let agentStatus: UInt8
    let color: Color
    let tabCount: UInt16
    let label: String
    let icon: String

    var isManual: Bool { kind == 0 }
    var isAgent: Bool { kind == 1 }
}

/// Observable state for the tab bar, driven by BEAM protocol messages.
@MainActor
@Observable
final class TabBarState {
    var tabs: [TabEntry] = []
    var activeIndex: Int = 0
    var workspaces: [WorkspaceEntry] = []
    var activeWorkspaceId: UInt16 = 0

    /// Whether workspace grouping is active (at least one agent workspace exists).
    var hasWorkspaces: Bool {
        workspaces.contains { $0.isAgent }
    }

    /// The active workspace entry, if any.
    var activeWorkspace: WorkspaceEntry? {
        workspaces.first { $0.id == activeWorkspaceId }
    }

    /// Update from a decoded gui_tab_bar protocol message.
    func update(activeIndex: UInt8, entries: [GUITabEntry]) {
        self.activeIndex = Int(activeIndex)
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

    /// Update from a decoded gui_workspace_bar protocol message.
    func updateWorkspaces(activeWorkspaceId: UInt16, entries: [GUIWorkspaceEntry]) {
        self.activeWorkspaceId = activeWorkspaceId
        self.workspaces = entries.map { entry in
            WorkspaceEntry(
                id: entry.id,
                kind: entry.kind,
                agentStatus: entry.agentStatus,
                color: Color(
                    .sRGB,
                    red: Double(entry.colorR) / 255.0,
                    green: Double(entry.colorG) / 255.0,
                    blue: Double(entry.colorB) / 255.0
                ),
                tabCount: entry.tabCount,
                label: entry.label,
                icon: entry.icon
            )
        }
    }

    /// Clear all tab state. Called when the BEAM sends an empty tab bar
    /// or during error recovery to prevent stale tabs from persisting.
    func hide() {
        tabs = []
        activeIndex = 0
        workspaces = []
        activeWorkspaceId = 0
    }
}
