/// Custom-drawn tab bar view for the hybrid GUI.
///
/// Renders tabs as a horizontal strip with Nerd Font icons, theme colors,
/// and dirty/attention indicators. No stock SwiftUI tab bar widgets.
/// Clicks send gui_action events to the BEAM via the encoder.

import SwiftUI

/// The tab bar strip rendered above the editor area.
struct TabBarView: View {
    let tabBarState: TabBarState
    let theme: ThemeColors
    let encoder: InputEncoder?

    /// Track which tab the mouse is hovering over (for close button reveal).
    @State private var hoverTabId: UInt32?

    private let tabHeight: CGFloat = 30

    var body: some View {
        HStack(spacing: 0) {
            // Tab strip (scrollable when many tabs)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(tabBarState.tabs) { tab in
                        tabItem(tab)
                    }
                }
            }

            Spacer()

            // New tab button
            Button(action: {
                (encoder as? ProtocolEncoder)?.sendNewTab()
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.tabInactiveFg)
                    .frame(width: 28, height: tabHeight)
            }
            .buttonStyle(.plain)
        }
        .frame(height: tabHeight)
        .background(theme.tabBg)
        .focusable(false)
        .focusEffectDisabled()
    }

    @ViewBuilder
    private func tabItem(_ tab: TabEntry) -> some View {
        let isHovering = hoverTabId == tab.id

        HStack(spacing: 4) {
            // Nerd Font file type icon
            Text(tab.icon)
                .font(.custom("Symbols Nerd Font Mono", size: 13))
                .foregroundStyle(tab.isActive ? theme.tabActiveFg : theme.tabInactiveFg)

            // Label
            Text(tab.label)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(tab.isActive ? theme.tabActiveFg : theme.tabInactiveFg)

            // Dirty indicator or close button
            if isHovering {
                Button(action: {
                    (encoder as? ProtocolEncoder)?.sendCloseTab(id: tab.id)
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.tabCloseHoverFg)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
            } else if tab.isDirty {
                Circle()
                    .fill(theme.tabModifiedFg)
                    .frame(width: 6, height: 6)
            } else if tab.hasAttention {
                Circle()
                    .fill(theme.tabAttentionFg)
                    .frame(width: 6, height: 6)
            } else {
                // Spacer for consistent width
                Color.clear
                    .frame(width: 14, height: 14)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: tabHeight)
        .background(tab.isActive ? theme.tabActiveBg : theme.tabBg)
        .onTapGesture {
            (encoder as? ProtocolEncoder)?.sendSelectTab(id: tab.id)
        }
        .onHover { hovering in
            withAnimation(nil) {
                hoverTabId = hovering ? tab.id : nil
            }
        }
    }
}
