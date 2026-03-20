/// Observable tab bar state driven by the BEAM via gui_tab_bar protocol messages.
///
/// Updated by CommandDispatcher when a gui_tab_bar message arrives.
/// SwiftUI views observe this to render the tab strip.

import SwiftUI

/// A single tab entry for SwiftUI rendering.
struct TabEntry: Identifiable {
    let id: UInt32
    let isActive: Bool
    let isDirty: Bool
    let isAgent: Bool
    let hasAttention: Bool
    let agentStatus: UInt8
    let icon: String
    let label: String
}

/// Observable state for the tab bar, driven by BEAM protocol messages.
@MainActor
@Observable
final class TabBarState {
    var tabs: [TabEntry] = []
    var activeIndex: Int = 0

    /// Update from a decoded gui_tab_bar protocol message.
    func update(activeIndex: UInt8, entries: [GUITabEntry]) {
        self.activeIndex = Int(activeIndex)
        self.tabs = entries.map { entry in
            TabEntry(
                id: entry.id,
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

    /// Clear all tab state. Called when the BEAM sends an empty tab bar
    /// or during error recovery to prevent stale tabs from persisting.
    func hide() {
        tabs = []
        activeIndex = 0
    }
}
