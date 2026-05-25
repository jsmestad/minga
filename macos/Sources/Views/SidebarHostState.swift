/// Observable native sidebar host state driven by semantic BEAM metadata.

import SwiftUI

/// Sidebar metadata adapted for SwiftUI rendering.
struct SidebarItem: Identifiable, Equatable {
    let id: String
    let displayName: String
    let semanticKind: String
    let icon: String
    let order: UInt16
    let visible: Bool
    let focused: Bool
    let preferredWidth: UInt16
    let badgeCount: UInt16?

    init(_ wire: Wire.SidebarMetadata) {
        id = wire.id
        displayName = wire.displayName
        semanticKind = wire.semanticKind
        icon = wire.icon
        order = wire.order
        visible = wire.visible
        focused = wire.focused
        preferredWidth = wire.preferredWidth
        badgeCount = wire.badgeCount
    }
}

/// Stores the BEAM-selected sidebar identities and validates semantic kinds against the native registry.
@MainActor
@Observable
final class SidebarHostState {
    private(set) var sidebars: [SidebarItem] = SidebarHostState.defaultSidebars
    private(set) var activeId: String = "file_tree"
    private var warnedUnknownKinds: Set<String> = []

    var visibleSidebars: [SidebarItem] {
        sidebars.sorted { lhs, rhs in lhs.order < rhs.order }
    }

    var activeSidebar: SidebarItem? {
        if let active = sidebars.first(where: { $0.id == activeId && $0.visible }) {
            return active
        }

        if let focused = sidebars.filter({ $0.visible && $0.focused }).sorted(by: { lhs, rhs in lhs.order > rhs.order }).first {
            return focused
        }

        return sidebars
            .filter(\.visible)
            .sorted { lhs, rhs in lhs.order > rhs.order }
            .first
    }

    var hasVisibleSidebar: Bool {
        activeSidebar != nil
    }

    /// Applies semantic sidebar metadata from the BEAM.
    func update(activeId: String, sidebars wireSidebars: [Wire.SidebarMetadata]) {
        let items = wireSidebars.map(SidebarItem.init).sorted { lhs, rhs in lhs.order < rhs.order }
        self.sidebars = items.isEmpty ? SidebarHostState.defaultSidebars : items
        self.activeId = activeId
        warnForUnknownVisibleSidebars(items)
    }

    private func warnForUnknownVisibleSidebars(_ items: [SidebarItem]) {
        for item in items where item.visible && NativeSidebarRegistry.adapter(for: item.semanticKind) == nil {
            if warnedUnknownKinds.insert(item.semanticKind).inserted {
                PortLogger.warn("Unknown sidebar kind '\(item.semanticKind)' for sidebar '\(item.id)'; using generic fallback")
            }
        }
    }

    private static let defaultSidebars: [SidebarItem] = [
        SidebarItem(Wire.SidebarMetadata(
            id: "file_tree",
            displayName: "File Tree",
            semanticKind: "file_tree",
            icon: "folder",
            order: 10,
            visible: false,
            focused: false,
            preferredWidth: 30,
            badgeCount: nil
        )),
        SidebarItem(Wire.SidebarMetadata(
            id: "git_status",
            displayName: "Git Status",
            semanticKind: "git_status",
            icon: "point.3.filled.connected.trianglepath.dotted",
            order: 20,
            visible: false,
            focused: false,
            preferredWidth: 30,
            badgeCount: nil
        )),
        SidebarItem(Wire.SidebarMetadata(
            id: "observatory",
            displayName: "BEAM Observatory",
            semanticKind: "observatory",
            icon: "network",
            order: 30,
            visible: false,
            focused: false,
            preferredWidth: 30,
            badgeCount: nil
        ))
    ]
}
