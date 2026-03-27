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

/// An agent group entry for the tab bar capsules and indicator.
struct AgentGroupEntry: Identifiable {
    let id: UInt16
    let agentStatus: UInt8
    let color: Color
    let tabCount: UInt16
    let label: String
    let icon: String
}

/// Observable state for the tab bar, driven by BEAM protocol messages.
@MainActor
@Observable
final class TabBarState {
    var tabs: [TabEntry] = []
    var activeIndex: Int = 0
    var agentGroups: [AgentGroupEntry] = []
    var activeGroupId: UInt16 = 0

    /// Whether any agent groups exist (controls visibility of group UI).
    var hasAgentGroups: Bool {
        !agentGroups.isEmpty
    }

    /// The active agent group, if the active tab belongs to one. Nil when
    /// the user is viewing ungrouped tabs.
    var activeGroup: AgentGroupEntry? {
        agentGroups.first { $0.id == activeGroupId }
    }

    /// Update from a decoded gui_tab_bar protocol message.
    func update(activeIndex: UInt8, entries: [Wire.TabEntry]) {
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

    /// Update from a decoded gui_agent_groups protocol message.
    func updateAgentGroups(activeGroupId: UInt16, entries: [Wire.AgentGroupEntry]) {
        self.activeGroupId = activeGroupId
        self.agentGroups = entries.map { entry in
            AgentGroupEntry(
                id: entry.id,
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

    /// Clear all tab state.
    func hide() {
        tabs = []
        activeIndex = 0
        agentGroups = []
        activeGroupId = 0
    }
}
