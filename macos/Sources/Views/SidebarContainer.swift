/// Sidebar body container that renders the BEAM-active semantic sidebar.
///
/// The header is rendered separately in the unified toolbar row (see ContentView). This container owns only the body content and the resize handle so all panels share a single width. Dragging the resize handle persists across panel switches, matching Zed/VS Code behavior.

import SwiftUI

enum SidebarSizing {
    static let columnWidth: CGFloat = 8
    static let defaultWidth: CGFloat = 240
    static let minWidth: CGFloat = 180
    static let baseMaxWidth: CGFloat = 360
    static let maxExtraWidth: CGFloat = 144
    static let hardMaxWidth: CGFloat = 560

    static func preferredWidth(for item: SidebarItem?) -> CGFloat {
        guard let item else { return defaultWidth }
        return max(defaultWidth, CGFloat(item.preferredWidth) * columnWidth)
    }

    static func maxWidth(for item: SidebarItem?) -> CGFloat {
        let preferred = preferredWidth(for: item)
        guard preferred > defaultWidth else { return baseMaxWidth }
        return min(max(baseMaxWidth, preferred + maxExtraWidth), hardMaxWidth)
    }

    static func clamp(_ width: CGFloat, for item: SidebarItem?) -> CGFloat {
        min(max(width, minWidth), maxWidth(for: item))
    }

    static func widthByApplyingPreferred(for item: SidebarItem?, currentWidth: CGFloat) -> CGFloat {
        clamp(max(currentWidth, preferredWidth(for: item)), for: item)
    }
}

struct SidebarContainer: View {
    let guiState: GUIState
    let activeSidebar: SidebarItem
    let theme: ThemeColors
    let encoder: InputEncoder?
    let projectName: String
    let gitBranch: String
    let leadingPadding: CGFloat
    @Binding var sidebarWidth: CGFloat

    @State private var isDraggingResize: Bool = false
    @State private var dragStartWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                NativeSidebarRegistry
                    .adapterOrFallback(for: activeSidebar.semanticKind)
                    .makeBody(context, activeSidebar)
            }
            .frame(width: sidebarWidth)
            .background(theme.treeBg)

            resizeHandle
        }
    }

    private var context: NativeSidebarContext {
        NativeSidebarContext(
            guiState: guiState,
            theme: theme,
            encoder: encoder,
            projectName: projectName,
            gitBranch: gitBranch,
            leadingPadding: leadingPadding
        )
    }

    // MARK: - Resize handle

    /// 8px hit target with a 1px visible separator line.
    @ViewBuilder
    private var resizeHandle: some View {
        Color.clear
            .frame(width: 8)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isDraggingResize ? theme.treeActiveFg.opacity(0.3) : theme.treeSeparatorFg.opacity(0.4))
                    .frame(width: 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if !isDraggingResize {
                            isDraggingResize = true
                            dragStartWidth = sidebarWidth
                        }
                        let newWidth = dragStartWidth + value.translation.width
                        sidebarWidth = SidebarSizing.clamp(newWidth, for: activeSidebar)
                    }
                    .onEnded { _ in
                        isDraggingResize = false
                    }
            )
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}
