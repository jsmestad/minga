/// Bottom panel container: resizable tabbed panel below the editor surface.
///
/// A VS Code-style bottom panel with a drag handle at the top edge,
/// a tab bar, and a content area. The BEAM controls visibility and tab
/// state declaratively; this view is a pure function of `BottomPanelState`.

import SwiftUI

struct BottomPanelView: View {
    @Bindable var state: BottomPanelState
    let theme: ThemeColors
    let encoder: InputEncoder?
    /// Total height of the right pane (tab bar + editor + panel + status bar).
    /// Used to cap the panel at 60% of available space. Measured by the parent
    /// via a preference key so the panel itself doesn't need a GeometryReader.
    let availableHeight: CGFloat

    /// Minimum panel height in points.
    private let minHeight: CGFloat = 100
    /// Maximum panel height as fraction of available space.
    private let maxHeightFraction: CGFloat = 0.6

    /// Height at drag start, used to avoid compounding error from cumulative translation.
    @State private var dragStartHeight: CGFloat = 0
    @State private var hoveredTabId: Int? = nil

    var body: some View {
        let maxH = availableHeight * maxHeightFraction
        let panelH = min(max(state.userHeight, minHeight), maxH)

        VStack(spacing: 0) {
            // Drag handle at the top edge
            dragHandle(maxHeight: maxH, windowHeight: availableHeight)

            // Tab bar
            tabBar

            // Content area (placeholder for now; Messages content is a follow-up)
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: panelH)
        .clipped()
        .background(theme.editorBg)
    }

    // MARK: - Drag handle

    private func dragHandle(maxHeight: CGFloat, windowHeight: CGFloat) -> some View {
        Rectangle()
            .fill(theme.treeSeparatorFg)
            .frame(height: 1)
            .overlay(
                // Invisible wider hit area for dragging
                Color.clear
                    .frame(height: 8)
                    .contentShape(Rectangle())
                    .cursor(.resizeUpDown)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                // Capture initial height on first drag event to avoid
                                // compounding error (translation is cumulative from start).
                                if dragStartHeight == 0 {
                                    dragStartHeight = state.userHeight
                                }
                                let newHeight = dragStartHeight - value.translation.height
                                state.userHeight = min(max(newHeight, minHeight), maxHeight)
                            }
                            .onEnded { _ in
                                dragStartHeight = 0
                                // Send final height to BEAM as a percentage of window height.
                                guard windowHeight > 0 else { return }
                                let percent = Int((state.userHeight / windowHeight) * 100)
                                let clamped = UInt8(min(max(percent, 10), 60))
                                encoder?.sendPanelResize(heightPercent: clamped)
                            }
                    )
            )
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(state.tabs) { tab in
                tabButton(tab: tab)
            }

            Spacer()

            // Dismiss button
            Button(action: {
                encoder?.sendPanelDismiss()
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.tabInactiveFg)
            }
            .buttonStyle(.plain)
            .help("Close panel")
            .padding(.horizontal, 8)
            .onHover { isHovered in
                if isHovered { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .frame(height: 28)
        .background(theme.tabBg)
    }

    private func tabButton(tab: BottomPanelTab) -> some View {
        let isActive = tab.id == state.activeTabIndex

        return Button(action: {
            encoder?.sendPanelSwitchTab(index: UInt8(tab.id))
        }) {
            Text(tab.name)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? theme.tabActiveFg : theme.tabInactiveFg)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .background(
            isActive
                ? theme.tabActiveBg.opacity(0.5)
                : (hoveredTabId == tab.id ? theme.tabInactiveFg.opacity(0.06) : Color.clear)
        )
        .overlay(alignment: .bottom) {
            if isActive {
                Rectangle()
                    .fill(theme.accent)
                    .frame(height: 2)
            }
        }
        .onHover { isHovered in
            hoveredTabId = isHovered ? tab.id : nil
        }
    }

    // MARK: - Content area

    @ViewBuilder
    private var contentArea: some View {
        if state.activeTabIndex < state.tabs.count,
           state.tabs[state.activeTabIndex].tabType == 0x01 {
            // Messages tab: render structured log entries
            MessagesContentView(
                state: state.messagesState,
                theme: theme,
                encoder: encoder
            )
        } else {
            // Placeholder for other tab types (diagnostics, terminal)
            VStack {
                Spacer()
                Text(activeTabName)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.tabInactiveFg.opacity(0.5))
                Spacer()
            }
        }
    }

    private var activeTabName: String {
        if state.activeTabIndex < state.tabs.count {
            return state.tabs[state.activeTabIndex].name
        }
        return ""
    }
}

// MARK: - Cursor extension

private extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { hovering in
            if hovering {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
