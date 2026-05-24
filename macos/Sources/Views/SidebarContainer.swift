/// Sidebar body container that renders the BEAM-active semantic sidebar.
///
/// The header is rendered separately in the unified toolbar row (see ContentView). This container owns only the body content and the resize handle so all panels share a single width. Dragging the resize handle persists across panel switches, matching Zed/VS Code behavior.

import SwiftUI

struct SidebarContainer: View {
    let guiState: GUIState
    let activeSidebar: SidebarItem
    let theme: ThemeColors
    let encoder: InputEncoder?
    let projectName: String
    let gitBranch: String
    let leadingPadding: CGFloat
    @Binding var sidebarWidth: CGFloat

    private let sidebarMinWidth: CGFloat = 180
    private let sidebarMaxWidth: CGFloat = 360

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
                        sidebarWidth = min(max(newWidth, sidebarMinWidth), sidebarMaxWidth)
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
