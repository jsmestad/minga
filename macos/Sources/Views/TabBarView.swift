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

            // Tab strip
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(tabBarState.tabs) { tab in
                        tabItem(tab)

                        // Thin separator between tabs (skip after last)
                        if tab.id != tabBarState.tabs.last?.id {
                            verticalSeparator
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
