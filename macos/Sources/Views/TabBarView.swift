/// Custom-drawn tab bar matching Zed's visual style.
///
/// Compact horizontal strip with file type icons, subtle separators,
/// and navigation arrows. No stock SwiftUI tab bar widgets.
/// All colors driven by BEAM theme.

import SwiftUI

/// The tab bar strip rendered above the editor area.
struct TabBarView: View {
    let tabBarState: TabBarState
    let theme: ThemeColors
    let encoder: InputEncoder?

    @State private var hoverTabId: UInt32?

    private let barHeight: CGFloat = 34

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

            // Tab strip
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(tabBarState.tabs.enumerated()), id: \.element.id) { index, tab in
                        tabItem(tab)

                        // Group separator at group_id transitions, thin separator otherwise
                        if tab.id != tabBarState.tabs.last?.id {
                            let nextTab = tabBarState.tabs[index + 1]
                            if tab.groupId != nextTab.groupId && tabBarState.hasWorkspaces {
                                let separatorColor = workspaceColor(for: nextTab.groupId)
                                groupSeparator(color: separatorColor)
                            } else {
                                verticalSeparator
                            }
                        }
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
        .frame(height: barHeight)
        .background(theme.tabBg)
        .focusable(false)
        .focusEffectDisabled()
    }

    // MARK: - Workspace indicator

    @ViewBuilder
    private func workspaceIndicator(_ workspace: WorkspaceEntry) -> some View {
        Button(action: {
            // Toggle workspace dropdown (handled by BEAM command)
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

                // Agent status indicator
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

    @ViewBuilder
    private func agentStatusDot(_ status: UInt8, color: Color) -> some View {
        Circle()
            .fill(agentStatusColor(status, accent: color))
            .frame(width: 5, height: 5)
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
                // Reserve space for alignment stability
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
    }

    // MARK: - Helpers

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

    /// Compact icon button for the tab bar toolbar with tooltip and pointer cursor.
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
