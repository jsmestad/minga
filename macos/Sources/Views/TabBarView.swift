/// Custom-drawn tab bar matching Zed's visual style.
///
/// Compact horizontal strip with file type icons, subtle separators,
/// and navigation arrows. No stock SwiftUI tab bar widgets.
/// All colors driven by BEAM theme.
///
/// Supports collapsible workspace groups: clicking a collapsed group
/// header expands it (shows individual tabs); clicking again collapses
/// back to a compact capsule showing the tab count.

import SwiftUI

/// The tab bar strip rendered above the editor area.
struct TabBarView: View {
    let tabBarState: TabBarState
    let theme: ThemeColors
    let encoder: InputEncoder?

    @State private var hoverTabId: UInt32?
    /// Tracks which workspace groups are collapsed (Swift-local state).
    /// Group 0 (manual) is never collapsible; only agent groups can collapse.
    @State private var collapsedGroups: Set<UInt16> = []
    /// Accumulated horizontal swipe delta for workspace switching.
    @State private var swipeDelta: CGFloat = 0
    /// Whether a swipe gesture is in progress.
    @State private var swiping: Bool = false

    private let barHeight: CGFloat = 34
    /// Minimum horizontal swipe distance to trigger a workspace switch.
    private let swipeThreshold: CGFloat = 80

    var body: some View {
        HStack(spacing: 0) {
            // Navigation arrows (back/forward)
            tabBarButton(
                systemIcon: "chevron.left",
                tooltip: "Previous tab (SPC b p)"
            ) {
                encoder?.sendExecuteCommand(name: "buffer_prev")
            }
            tabBarButton(
                systemIcon: "chevron.right",
                tooltip: "Next tab (SPC b n)"
            ) {
                encoder?.sendExecuteCommand(name: "buffer_next")
            }

            // Thin separator after nav arrows
            verticalSeparator

            // Workspace indicator (visible when workspaces exist)
            if tabBarState.hasWorkspaces, let activeWs = tabBarState.activeWorkspace {
                workspaceIndicator(activeWs)
                groupSeparator(color: activeWs.color)
            }

            // Tab strip with collapsible groups
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    if tabBarState.hasWorkspaces {
                        groupedTabStrip
                    } else {
                        flatTabStrip
                    }
                }
            }

            // Right-side controls
            verticalSeparator

            // New tab button
            tabBarButton(
                systemIcon: "plus",
                tooltip: "New tab"
            ) {
                encoder?.sendNewTab()
            }

            // Window split buttons
            tabBarButton(
                systemIcon: "rectangle.split.2x1",
                tooltip: "Split right (SPC w v)"
            ) {
                encoder?.sendExecuteCommand(name: "split_vertical")
            }
            tabBarButton(
                systemIcon: "rectangle.expand.vertical",
                tooltip: "Split below (SPC w s)"
            ) {
                encoder?.sendExecuteCommand(name: "split_horizontal")
            }
        }
        .focusable(false)
        .focusEffectDisabled()
        .gesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    // Only act on primarily horizontal drags (trackpad swipe)
                    guard tabBarState.hasWorkspaces else { return }
                    let horizontal = abs(value.translation.width)
                    let vertical = abs(value.translation.height)
                    guard horizontal > vertical * 1.5 else { return }
                    swiping = true
                    swipeDelta = value.translation.width
                }
                .onEnded { value in
                    guard swiping, tabBarState.hasWorkspaces else {
                        swiping = false
                        swipeDelta = 0
                        return
                    }
                    if value.translation.width < -swipeThreshold {
                        // Swipe left: next workspace
                        encoder?.sendExecuteCommand(name: "workspace_next")
                    } else if value.translation.width > swipeThreshold {
                        // Swipe right: previous workspace
                        encoder?.sendExecuteCommand(name: "workspace_prev")
                    }
                    swiping = false
                    swipeDelta = 0
                }
        )
    }

    // MARK: - Tab strip layouts

    /// Flat tab strip (no workspaces active, Tier 0).
    @ViewBuilder
    private var flatTabStrip: some View {
        ForEach(tabBarState.tabs) { tab in
            tabItem(tab)

            if tab.id != tabBarState.tabs.last?.id {
                verticalSeparator
            }
        }
    }

    /// Grouped tab strip: renders tabs in workspace groups with
    /// collapsible headers for agent workspaces. Groups are consolidated
    /// by groupId (not contiguous), so tabs from the same workspace always
    /// appear together even if they're interleaved in the underlying list.
    @ViewBuilder
    private var groupedTabStrip: some View {
        let groups = groupedTabs()

        ForEach(groups, id: \.groupId) { group in
            // Group separator before non-first groups
            if group.groupId != groups.first?.groupId {
                groupSeparator(color: workspaceColor(for: group.groupId))
            }

            if group.groupId != 0 && collapsedGroups.contains(group.groupId) {
                // Collapsed agent group: show capsule
                collapsedGroupCapsule(group)
            } else {
                // Expanded: show individual tabs
                ForEach(Array(group.tabs.enumerated()), id: \.element.id) { tabIndex, tab in
                    tabItem(tab)

                    // Thin separator between tabs within the same group
                    if tabIndex < group.tabs.count - 1 {
                        verticalSeparator
                    }
                }
            }
        }
    }

    // MARK: - Collapsed group capsule

    @ViewBuilder
    private func collapsedGroupCapsule(_ group: TabGroup) -> some View {
        let ws = tabBarState.workspaces.first { $0.id == group.groupId }
        let color = ws?.color ?? theme.tabInactiveFg

        Button(action: {
            // Pop cursor before view disappears to avoid stuck cursor
            NSCursor.pop()
            // Expand the group and switch to its workspace
            collapsedGroups.remove(group.groupId)
            // Switch to the specific workspace this capsule represents
            let wsIndex = tabBarState.workspaces.firstIndex { $0.id == group.groupId }
            let wsNum = wsIndex.map { $0 } ?? 0
            if wsNum > 0 && wsNum <= 9 {
                encoder?.sendExecuteCommand(name: "workspace_goto_\(wsNum)")
            } else {
                encoder?.sendExecuteCommand(name: "workspace_next_agent")
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.system(size: 10))
                    .foregroundStyle(color)

                Text(ws?.label ?? "Agent")
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(theme.tabInactiveFg)

                if let ws = ws, ws.isAgent {
                    agentStatusDot(ws.agentStatus, color: color)
                }

                // Tab count badge
                Text("(\(group.tabs.count))")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tabInactiveFg.opacity(0.7))
            }
            .padding(.horizontal, 10)
            .frame(height: barHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Expand and switch to workspace")
        .onHover { isHovered in
            if isHovered { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    // MARK: - Workspace indicator

    @ViewBuilder
    private func workspaceIndicator(_ workspace: WorkspaceEntry) -> some View {
        Button(action: {
            encoder?.sendExecuteCommand(name: "workspace_list")
        }) {
            HStack(spacing: 4) {
                Image(systemName: workspace.isManual ? "doc.on.doc" : "cpu")
                    .font(.system(size: 10))
                    .foregroundStyle(workspace.color)

                Text(workspace.label)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(theme.tabActiveFg)

                if workspace.isAgent {
                    agentStatusDot(workspace.agentStatus, color: workspace.color)
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(theme.tabInactiveFg)
            }
            .padding(.horizontal, 8)
            .frame(height: barHeight)
        }
        .buttonStyle(.plain)
        .help("Switch workspace (SPC TAB l)")
        .onHover { isHovered in
            if isHovered { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    private func agentStatusDot(_ status: UInt8, color: Color) -> some View {
        Circle()
            .fill(agentStatusColor(status, accent: color))
            .frame(width: 6, height: 6)
    }

    private func agentStatusColor(_ status: UInt8, accent: Color) -> Color {
        switch status {
        case 1: return accent   // thinking
        case 2: return accent   // tool_executing
        case 3: return Color.red  // error
        default: return theme.tabInactiveFg  // idle
        }
    }

    private func workspaceColor(for groupId: UInt16) -> Color {
        if let ws = tabBarState.workspaces.first(where: { $0.id == groupId }) {
            return ws.color
        }
        return theme.tabSeparatorFg
    }

    private func groupSeparator(color: Color) -> some View {
        Rectangle()
            .fill(color.opacity(0.6))
            .frame(width: 2, height: 20)
            .padding(.horizontal, 2)
    }

    // MARK: - Tab item

    @ViewBuilder
    private func tabItem(_ tab: TabEntry) -> some View {
        let isHovering = hoverTabId == tab.id

        HStack(spacing: 5) {
            // File type icon (Nerd Font)
            Text(tab.icon)
                .font(.custom("Symbols Nerd Font Mono", size: 12))
                .foregroundStyle(tab.isActive ? theme.tabActiveFg : theme.tabInactiveFg)

            // Label
            Text(tab.label)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(tab.isActive ? theme.tabActiveFg : theme.tabInactiveFg)

            // Dirty dot or close button
            if isHovering {
                closeButton(tab)
            } else if tab.isDirty {
                Circle()
                    .fill(theme.tabModifiedFg)
                    .frame(width: 5, height: 5)
            } else if tab.hasAttention {
                Circle()
                    .fill(theme.tabAttentionFg)
                    .frame(width: 5, height: 5)
            } else {
                Color.clear.frame(width: 12, height: 12)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: barHeight)
        .background(tab.isActive ? theme.tabActiveBg : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            encoder?.sendSelectTab(id: tab.id)
        }
        .onHover { hovering in
            withAnimation(nil) {
                hoverTabId = hovering ? tab.id : nil
            }
        }
        .contextMenu {
            // Right-click to collapse the group this tab belongs to
            if tab.groupId != 0 && tabBarState.hasWorkspaces {
                Button("Collapse Group") {
                    collapsedGroups.insert(tab.groupId)
                }
            }
        }
    }

    // MARK: - Helpers

    /// Consolidates tabs by groupId into workspace groups.
    /// Group 0 (manual) always comes first; agent groups sorted by id.
    /// Within each group, tab order is preserved from the BEAM's tab list.
    private func groupedTabs() -> [TabGroup] {
        Dictionary(grouping: tabBarState.tabs, by: \.groupId)
            .sorted { $0.key < $1.key }
            .map { TabGroup(groupId: $0.key, tabs: $0.value) }
    }

    @ViewBuilder
    private func closeButton(_ tab: TabEntry) -> some View {
        Button(action: {
            encoder?.sendCloseTab(id: tab.id)
        }) {
            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(theme.tabInactiveFg)
                .frame(width: 12, height: 12)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(theme.tabInactiveFg.opacity(0.15))
                )
        }
        .buttonStyle(.plain)
        .help("Close tab")
        .onHover { isHovered in
            if isHovered { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    @ViewBuilder
    private func tabBarButton(
        systemIcon: String,
        tooltip: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemIcon)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.tabInactiveFg)
                .frame(width: 28, height: barHeight)
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .onHover { isHovered in
            if isHovered { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    private var verticalSeparator: some View {
        Rectangle()
            .fill(theme.tabSeparatorFg.opacity(0.4))
            .frame(width: 1, height: 16)
    }
}

// MARK: - Tab grouping model

/// A contiguous group of tabs sharing the same groupId.
private struct TabGroup {
    let groupId: UInt16
    let tabs: [TabEntry]
}
