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

            // New tab / new agent dropdown
            Menu {
                Button(action: {
                    encoder?.sendNewTab()
                }) {
                    Label("New File", systemImage: "doc")
                }
                Button(action: {
                    encoder?.sendExecuteCommand(name: "toggle_agent_split")
                }) {
                    Label("New Agent Session", systemImage: "cpu")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.tabInactiveFg)
                    .frame(width: 28, height: barHeight)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28)
            .help("New file or agent session")
            .onHover { isHovered in
                if isHovered { NSCursor.pointingHand.push() } else { NSCursor.pop() }
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

    /// Grouped tab strip: only the active workspace's tabs are expanded.
    /// All other workspaces collapse to capsules automatically.
    /// Groups are consolidated by groupId so tabs from the same workspace
    /// always appear together.
    @ViewBuilder
    private var groupedTabStrip: some View {
        let groups = groupedTabs()
        let activeWsId = tabBarState.activeWorkspaceId

        ForEach(groups, id: \.groupId) { group in
            // Group separator before non-first groups
            if group.groupId != groups.first?.groupId {
                groupSeparator(color: workspaceColor(for: group.groupId))
            }

            if group.groupId == 0 || group.groupId == activeWsId {
                // Manual workspace is always expanded; active workspace is expanded
                ForEach(Array(group.tabs.enumerated()), id: \.element.id) { tabIndex, tab in
                    tabItem(tab)

                    if tabIndex < group.tabs.count - 1 {
                        verticalSeparator
                    }
                }
            } else {
                // Inactive agent workspace: show collapsed capsule
                collapsedGroupCapsule(group)
            }
        }
    }

    // MARK: - Collapsed group capsule

    @ViewBuilder
    private func collapsedGroupCapsule(_ group: TabGroup) -> some View {
        let ws = tabBarState.workspaces.first { $0.id == group.groupId }
        let color = ws?.color ?? theme.tabInactiveFg

        Button(action: {
            // Switch to this workspace by id (activates its first tab on the BEAM side)
            if group.groupId == 0 {
                encoder?.sendExecuteCommand(name: "workspace_manual")
            } else if let idx = tabBarState.workspaces.firstIndex(where: { $0.id == group.groupId }),
                      idx >= 1, idx <= 9 {
                encoder?.sendExecuteCommand(name: "workspace_goto_\(idx)")
            } else {
                encoder?.sendExecuteCommand(name: "workspace_next_agent")
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: ws?.icon ?? "cpu")
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
        .onDisappear {
            // Safety net: pop cursor if capsule is removed while hovered
            NSCursor.pop()
        }
    }

    // MARK: - Workspace indicator

    @State private var isRenaming: Bool = false
    @State private var renameText: String = ""
    @State private var showIconPicker: Bool = false
    @FocusState private var renameFieldFocused: Bool

    @ViewBuilder
    private func workspaceIndicator(_ workspace: WorkspaceEntry) -> some View {
        HStack(spacing: 4) {
            // Icon (click to change)
            Image(systemName: workspace.icon.isEmpty ? "folder" : workspace.icon)
                .font(.system(size: 10))
                .foregroundStyle(workspace.color)
                .contentShape(Rectangle())
                .onTapGesture {
                    showIconPicker = true
                }
                .popover(isPresented: $showIconPicker, arrowEdge: .bottom) {
                    WorkspaceIconPicker(
                        currentIcon: workspace.icon,
                        accentColor: workspace.color,
                        theme: theme
                    ) { selectedIcon in
                        showIconPicker = false
                        encoder?.sendWorkspaceSetIcon(id: workspace.id, icon: selectedIcon)
                    }
                }

            // Label (double-click to rename, single-click for picker)
            if isRenaming {
                TextField("", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .focused($renameFieldFocused)
                    .frame(minWidth: 40, maxWidth: 160)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.tabActiveBg)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
                            )
                    )
                    .onSubmit {
                        commitRename(workspace)
                    }
                    .onExitCommand {
                        isRenaming = false
                        tabBarState.isEditingWorkspaceName = false
                    }
                    .onChange(of: renameFieldFocused) { _, focused in
                        if !focused {
                            commitRename(workspace)
                        }
                    }
            } else {
                Text(workspace.label)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(theme.tabActiveFg)
                    .onTapGesture(count: 2) {
                        renameText = workspace.label
                        isRenaming = true
                        tabBarState.isEditingWorkspaceName = true
                        DispatchQueue.main.async { renameFieldFocused = true }
                    }
                    .onTapGesture(count: 1) {
                        encoder?.sendExecuteCommand(name: "workspace_list")
                    }
            }

            if workspace.isAgent {
                agentStatusDot(workspace.agentStatus, color: workspace.color)
            }

            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(theme.tabInactiveFg)
                .onTapGesture {
                    encoder?.sendExecuteCommand(name: "workspace_list")
                }
        }
        .padding(.horizontal, 8)
        .frame(height: barHeight)
        .contextMenu {
            Button("Rename Workspace...") {
                renameText = workspace.label
                isRenaming = true
                tabBarState.isEditingWorkspaceName = true
                DispatchQueue.main.async { renameFieldFocused = true }
            }
            Button("Change Icon...") {
                showIconPicker = true
            }
            Divider()
            if workspace.isAgent {
                Button("Close Workspace") {
                    encoder?.sendExecuteCommand(name: "workspace_close")
                }
            }
        }
    }

    private func commitRename(_ workspace: WorkspaceEntry) {
        guard isRenaming else { return }
        isRenaming = false
        tabBarState.isEditingWorkspaceName = false
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != workspace.label else { return }
        encoder?.sendWorkspaceRename(id: workspace.id, name: trimmed)
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

            // Close button / dirty indicator zone.
            // The close button is always in the view hierarchy so it can
            // receive clicks without the parent onTapGesture intercepting.
            // It's visually hidden (opacity 0) when not hovered or active.
            ZStack {
                if tab.isDirty && !isHovering {
                    Circle()
                        .fill(theme.tabModifiedFg)
                        .frame(width: 5, height: 5)
                } else if tab.hasAttention && !isHovering {
                    Circle()
                        .fill(theme.tabAttentionFg)
                        .frame(width: 5, height: 5)
                }

                closeButton(tab)
                    .opacity(isHovering || tab.isActive ? 1 : 0)
            }
            .frame(width: 12, height: 12)
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
            Button("Close Tab") {
                encoder?.sendCloseTab(id: tab.id)
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
