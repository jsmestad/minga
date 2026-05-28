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
import UniformTypeIdentifiers

/// Context-menu actions that target a specific tab without selecting it first.
enum TabContextMenuAction: Equatable, Hashable {
    case pin
    case unpin
    case moveLeft
    case moveRight
}

/// Presentation state for a tab context-menu move item.
struct TabContextMenuMoveItem: Identifiable, Equatable {
    let id: TabContextMenuAction
    let title: String
    let isDisabled: Bool
}

/// The tab bar strip rendered above the editor area.
struct TabBarView: View {
    let tabBarState: TabBarState
    let theme: ThemeColors
    let encoder: InputEncoder?

    @State private var hoverTabId: UInt32?
    @State private var dropTargetTabId: UInt32?
    @State private var tabDragInProgress: Bool = false
    /// Accumulated horizontal swipe delta for agent workspace switching.
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

            // Legacy workspace indicator, hidden when the canonical workspace header is active.
            if !tabBarState.hasCanonicalWorkspaceTabs, let activeWorkspace = tabBarState.activeWorkspace {
                workspaceIndicator(activeWorkspace)
                groupSeparator(color: activeWorkspace.color)
            }

            // Tab strip with collapsible groups
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    if tabBarState.hasWorkspaces && !tabBarState.hasCanonicalWorkspaceTabs {
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
                    encoder?.sendExecuteCommand(name: "toggle_agentic_view")
                }) {
                    Label("Agent", systemImage: "cpu")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.chromeMutedFg)
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
                    guard tabBarState.hasWorkspaces && !tabDragInProgress else { return }
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

    private var displayTabs: [TabEntry] {
        if tabBarState.hasCanonicalWorkspaceTabs {
            return tabBarState.workspaceTabs.enumerated().map { index, tab in
                TabEntry(
                    id: tab.id,
                    groupId: tab.workspaceId,
                    isActive: index == Int(tabBarState.activeIndex),
                    isDirty: tab.isDirty,
                    isAgent: false,
                    hasAttention: tab.hasAttention,
                    agentStatus: 0,
                    isPinned: tab.isPinned,
                    tintColor: tab.tintColor,
                    icon: tab.icon,
                    label: tab.label
                )
            }
        }

        return tabBarState.tabs
    }

    func performTabContextMenuAction(_ action: TabContextMenuAction, for tab: TabEntry) {
        switch action {
        case .pin:
            encoder?.sendTabPin(id: tab.id)
        case .unpin:
            encoder?.sendTabUnpin(id: tab.id)
        case .moveLeft:
            encoder?.sendTabMoveLeft(id: tab.id)
        case .moveRight:
            encoder?.sendTabMoveRight(id: tab.id)
        }
    }

    func canMoveTabLeft(_ tab: TabEntry) -> Bool {
        guard let index = movableTabIndex(tab) else { return false }
        return index > 0
    }

    func canMoveTabRight(_ tab: TabEntry) -> Bool {
        guard let index = movableTabIndex(tab) else { return false }
        return index < movableTabs(for: tab).count - 1
    }

    func tabContextMenuMoveItems(for tab: TabEntry) -> [TabContextMenuMoveItem] {
        [
            TabContextMenuMoveItem(id: .moveLeft, title: "Move Tab Left", isDisabled: !canMoveTabLeft(tab)),
            TabContextMenuMoveItem(id: .moveRight, title: "Move Tab Right", isDisabled: !canMoveTabRight(tab))
        ]
    }

    func handleTabDrop(droppedTabs: [TabDragPayload], target tab: TabEntry, visibleIndex: Int) -> Bool {
        guard let reorder = tabDropReorder(droppedTabs: droppedTabs, target: tab, visibleIndex: visibleIndex) else {
            return false
        }
        encoder?.sendTabReorder(id: reorder.id, newIndex: reorder.newIndex)
        return true
    }

    func tabDropReorder(droppedTabs: [TabDragPayload], target tab: TabEntry, visibleIndex: Int) -> (id: UInt32, newIndex: UInt16)? {
        guard let draggedId = droppedTabs.first?.id,
              draggedId != tab.id else {
            return nil
        }
        guard let draggedTab = displayTabs.first(where: { $0.id == draggedId }),
              draggedTab.groupId == tab.groupId,
              draggedTab.isPinned == tab.isPinned else {
            return nil
        }
        return (draggedId, UInt16(visibleIndex))
    }

    private func movableTabIndex(_ tab: TabEntry) -> Int? {
        movableTabs(for: tab).firstIndex { $0.id == tab.id }
    }

    private func movableTabs(for tab: TabEntry) -> [TabEntry] {
        displayTabs.filter { candidate in
            candidate.groupId == tab.groupId && candidate.isPinned == tab.isPinned
        }
    }

    // MARK: - Tab strip layouts

    /// Flat tab strip (no workspaces active, Tier 0).
    @ViewBuilder
    private var flatTabStrip: some View {
        let tabs = displayTabs
        let pinnedCount = tabs.filter(\.isPinned).count

        ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
            if index == pinnedCount && pinnedCount > 0 && pinnedCount < tabs.count {
                pinnedSeparator
            }

            tabItem(tab, visibleIndex: index)

            if index < tabs.count - 1 && index + 1 != pinnedCount {
                verticalSeparator
            }
        }
    }

    /// Grouped tab strip: the active workspace expands to tabs, while
    /// inactive agent workspaces remain available as collapsed capsules.
    @ViewBuilder
    private var groupedTabStrip: some View {
        let groupsById = Dictionary(uniqueKeysWithValues: groupedTabs().map { ($0.groupId, $0) })
        let workspacesById = Dictionary(uniqueKeysWithValues: tabBarState.workspaces.map { ($0.id, $0) })
        let allWorkspaceIds = Set(groupsById.keys).union(workspacesById.keys)
        let workspaceIds = [tabBarState.activeWorkspaceId] + allWorkspaceIds.subtracting([tabBarState.activeWorkspaceId]).sorted()

        ForEach(Array(workspaceIds.enumerated()), id: \.element) { index, groupId in
            if index > 0 {
                groupSeparator(color: workspaceColor(for: groupId))
            }

            if let group = groupsById[groupId] {
                visibleGroupTabs(group)
            } else if let workspace = workspacesById[groupId] {
                collapsedWorkspaceCapsule(workspace)
            }
        }
    }

    @ViewBuilder
    private func visibleGroupTabs(_ group: TabGroup) -> some View {
        ForEach(Array(group.tabs.enumerated()), id: \.element.id) { tabIndex, tab in
            tabItem(tab, visibleIndex: tabIndex)

            if tabIndex < group.tabs.count - 1 {
                verticalSeparator
            }
        }
    }

    // MARK: - Collapsed workspace capsule

    @ViewBuilder
    private func collapsedWorkspaceCapsule(_ workspace: WorkspaceEntry) -> some View {
        let color = workspace.color

        Button(action: {
            // Switch to this workspace by id (activates its first tab on the BEAM side)
            encoder?.sendExecuteCommand(name: workspaceGotoCommand(for: workspace))
        }) {
            HStack(spacing: 4) {
                Image(systemName: workspace.icon.isEmpty ? "cpu" : workspace.icon)
                    .font(.system(size: 10))
                    .foregroundStyle(color)

                Text(workspace.label)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(theme.tabInactiveFg)

                agentStatusDot(workspace.agentStatus, color: color)

                Text("(\(workspace.tabCount))")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tabInactiveFg.opacity(0.7))
            }
            .padding(.horizontal, 10)
            .frame(height: barHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Switch to workspace \(workspace.label)")
        .help("Switch to workspace")
        .onHover { isHovered in
            if isHovered { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDisappear {
            NSCursor.pop()
        }
        .contextMenu {
            Button("Switch to Workspace") {
                encoder?.sendExecuteCommand(name: workspaceGotoCommand(for: workspace))
            }
            Divider()
            Button("Close Workspace") {
                encoder?.sendWorkspaceClose(id: workspace.id)
            }
        }
    }

    @MainActor
    private func workspaceGotoCommand(for workspace: WorkspaceEntry) -> String {
        if workspace.kind == 0 {
            return "manual_workspace"
        }

        let agentWorkspaces = tabBarState.workspaces.filter { $0.kind == 1 }
        guard let idx = agentWorkspaces.firstIndex(where: { $0.id == workspace.id }), idx < 9 else {
            return "workspace_next_agent"
        }

        return "workspace_goto_\(idx + 1)"
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
                        DispatchQueue.main.async { renameFieldFocused = true }
                    }
                    .onTapGesture(count: 1) {
                        encoder?.sendExecuteCommand(name: "workspace_list")
                    }
            }

            if true {
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
                DispatchQueue.main.async { renameFieldFocused = true }
            }
            Button("Change Icon...") {
                showIconPicker = true
            }
            Divider()
            if !false {
                Button("Close Workspace") {
                    encoder?.sendWorkspaceClose(id: workspace.id)
                }
            }
        }
    }

    private func commitRename(_ workspace: WorkspaceEntry) {
        guard isRenaming else { return }
        isRenaming = false
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
        case 4: return theme.agentStatusNeedsYou  // plan
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
    private func tabItem(_ tab: TabEntry, visibleIndex: Int) -> some View {
        let isHovering = hoverTabId == tab.id || dropTargetTabId == tab.id

        HStack(spacing: tab.isPinned ? 0 : 5) {
            // File type icon (Nerd Font for files, SF Symbol for agents)
            if tab.isAgent {
                Image(systemName: "cpu")
                    .font(.system(size: 11))
                    .foregroundStyle(tab.isActive ? theme.tabActiveFg : theme.tabSecondaryFg)
            } else {
                Text(tab.icon)
                    .font(.custom("Symbols Nerd Font Mono", size: 12))
                    .foregroundStyle(tab.isActive ? theme.tabActiveFg : theme.tabSecondaryFg)
            }

            // Label: pinned and agent tabs stay compact; the tooltip carries the full name.
            if !tab.isPinned && !tab.isAgent {
                Text(tab.label)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(tab.isActive ? theme.tabActiveFg : theme.tabSecondaryFg)
            }

            if !tab.isPinned {
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
        }
        .padding(.horizontal, tab.isPinned ? 8 : 12)
        .frame(width: tab.isPinned ? 28 : nil, height: barHeight)
        .background {
            RoundedRectangle(cornerRadius: 5)
                .fill(tabBackgroundColor(tab, isHovering: isHovering))
                .padding(.vertical, 4)
        }
        .overlay(alignment: .top) {
            if tab.isActive {
                Rectangle()
                    .fill(tabTint(tab) ?? theme.accent)
                    .frame(height: 2)
            }
        }
        .overlay(alignment: .bottom) {
            if let tint = tabTint(tab), !tab.isActive {
                Rectangle()
                    .fill(tint.opacity(0.75))
                    .frame(height: 2)
            }
        }
        .overlay(alignment: .topTrailing) {
            if tab.isPinned, let badgeColor = pinnedBadgeColor(tab) {
                Circle()
                    .fill(badgeColor)
                    .frame(width: 5, height: 5)
                    .padding(.top, 6)
                    .padding(.trailing, 5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            encoder?.sendSelectTab(id: tab.id)
        }
        .onHover { hovering in
            withAnimation(nil) {
                hoverTabId = hovering ? tab.id : nil
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 3)
                .onChanged { _ in
                    tabDragInProgress = true
                }
                .onEnded { _ in
                    tabDragInProgress = false
                }
        )
        .draggable(TabDragPayload(id: tab.id)) {
            tabDragPreview(tab)
        }
        .dropDestination(for: TabDragPayload.self) { droppedTabs, _location in
            handleTabDrop(droppedTabs: droppedTabs, target: tab, visibleIndex: visibleIndex)
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.12)) {
                dropTargetTabId = targeted ? tab.id : nil
            }
        }
        .accessibilityIdentifier("workspace-file-tab-\(tab.id)")
        .accessibilityLabel("File tab \(tab.label)")
        .accessibilityValue(tabAccessibilityValue(tab))
        .help(tab.label)
        .contextMenu {
            Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") {
                performTabContextMenuAction(tab.isPinned ? .unpin : .pin, for: tab)
            }
            Divider()
            ForEach(tabContextMenuMoveItems(for: tab)) { item in
                Button(item.title) {
                    performTabContextMenuAction(item.id, for: tab)
                }
                .disabled(item.isDisabled)
            }
            Divider()
            Button("Close") {
                encoder?.sendCloseTab(id: tab.id)
            }
            Button("Close Others") {
                encoder?.sendSelectTab(id: tab.id)
                encoder?.sendExecuteCommand(name: "close_other_tabs")
            }
            Button("Close All") {
                encoder?.sendExecuteCommand(name: "quit_all")
            }
            Divider()
            Button("Copy Path") {
                encoder?.sendTabCopyPath(id: tab.id)
            }
            .disabled(tab.isAgent)
        }
    }

    @ViewBuilder
    private func tabDragPreview(_ tab: TabEntry) -> some View {
        HStack(spacing: 5) {
            if tab.isAgent {
                Image(systemName: "cpu")
                    .font(.system(size: 11))
            } else {
                Text(tab.icon)
                    .font(.custom("Symbols Nerd Font Mono", size: 12))
            }

            if !tab.isPinned && !tab.isAgent {
                Text(tab.label)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, tab.isPinned ? 8 : 12)
        .frame(width: tab.isPinned ? 28 : nil, height: barHeight)
        .background(theme.tabActiveBg)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(radius: 6, y: 3)
    }

    // MARK: - Helpers

    /// Consolidates tabs by groupId into workspace groups.
    /// Group 0 (manual) always comes first; agent workspaces sorted by id.
    /// Within each group, tab order is preserved from the BEAM's tab list.
    private func groupedTabs() -> [TabGroup] {
        Dictionary(grouping: displayTabs, by: \.groupId)
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
                .foregroundStyle(theme.chromeMutedFg)
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

    private var pinnedSeparator: some View {
        Rectangle()
            .fill(theme.tabSeparatorFg.opacity(0.75))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 3)
    }

    private func tabBackgroundColor(_ tab: TabEntry, isHovering: Bool) -> Color {
        if tab.isActive {
            return theme.tabActiveBg
        }
        if isHovering {
            return theme.tabInactiveFg.opacity(0.08)
        }
        return Color.clear
    }

    private func tabTint(_ tab: TabEntry) -> Color? {
        if let tint = tab.tintColor {
            return tint
        }
        return tab.isAgent ? theme.accent : nil
    }

    private func pinnedBadgeColor(_ tab: TabEntry) -> Color? {
        if tab.isDirty {
            return theme.tabModifiedFg
        }
        if tab.hasAttention {
            return theme.tabAttentionFg
        }
        return nil
    }

    private func tabAccessibilityValue(_ tab: TabEntry) -> String {
        var values: [String] = []

        if tab.isPinned {
            values.append("pinned")
        }
        if tab.isDirty {
            values.append("modified")
        }
        if tab.hasAttention {
            values.append("attention")
        }

        return values.isEmpty ? "clean" : values.joined(separator: ", ")
    }
}

// MARK: - Drag payload

/// App-private tab drag payload used for in-window tab reordering.
struct TabDragPayload: Codable, Hashable, Sendable, Transferable {
    static let contentType = UTType(exportedAs: "com.minga.tab-id")

    let id: UInt32

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: contentType)
    }
}

// MARK: - Tab grouping model

/// A contiguous group of tabs sharing the same groupId.
private struct TabGroup {
    let groupId: UInt16
    let tabs: [TabEntry]
}
