/// Sidebar body container that renders the BEAM-active semantic sidebar.
///
/// The header is rendered separately in the unified toolbar row (see ContentView). This container owns only the body content and the resize handle so all panels share a single width. Dragging the resize handle persists across panel switches, matching Zed/VS Code behavior.

import SwiftUI

public enum SidebarSizing {
    public static let columnWidth: CGFloat = 8
    public static let defaultWidth: CGFloat = 240
    public static let minWidth: CGFloat = 180
    public static let baseMaxWidth: CGFloat = 360
    public static let maxExtraWidth: CGFloat = 144
    public static let hardMaxWidth: CGFloat = 560

    public static func preferredWidth(for item: SidebarItem?) -> CGFloat {
        guard let item else { return defaultWidth }
        return max(defaultWidth, CGFloat(item.preferredWidth) * columnWidth)
    }

    public static func maxWidth(for item: SidebarItem?) -> CGFloat {
        let preferred = preferredWidth(for: item)
        guard preferred > defaultWidth else { return baseMaxWidth }
        return min(max(baseMaxWidth, preferred + maxExtraWidth), hardMaxWidth)
    }

    public static func clamp(_ width: CGFloat, for item: SidebarItem?) -> CGFloat {
        min(max(width, minWidth), maxWidth(for: item))
    }

    public static func widthByApplyingPreferred(for item: SidebarItem?, currentWidth: CGFloat) -> CGFloat {
        clamp(max(currentWidth, preferredWidth(for: item)), for: item)
    }
}

public struct SidebarContainer: View {
    public init(input: ShellHostInput, activeSidebar: SidebarItem, encoder: InputEncoder? = nil, projectName: String, gitBranch: String, leadingPadding: CGFloat, sidebarWidth: Binding<CGFloat>) {
        self.input = input
        self.activeSidebar = activeSidebar
        self.encoder = encoder
        self.projectName = projectName
        self.gitBranch = gitBranch
        self.leadingPadding = leadingPadding
        self._sidebarWidth = sidebarWidth
        frameProbe = nil
    }

    init(input: ShellHostInput, activeSidebar: SidebarItem, encoder: InputEncoder? = nil, projectName: String, gitBranch: String, leadingPadding: CGFloat, sidebarWidth: Binding<CGFloat>, frameProbe: ContentViewFrameProbe?) {
        self.input = input
        self.activeSidebar = activeSidebar
        self.encoder = encoder
        self.projectName = projectName
        self.gitBranch = gitBranch
        self.leadingPadding = leadingPadding
        self._sidebarWidth = sidebarWidth
        self.frameProbe = frameProbe
    }

    public let input: ShellHostInput
    public let activeSidebar: SidebarItem
    @Environment(\.themeColors) private var theme

    public let encoder: InputEncoder?
    public let projectName: String
    public let gitBranch: String
    public let leadingPadding: CGFloat
    @Binding public var sidebarWidth: CGFloat
    let frameProbe: ContentViewFrameProbe?

    @State private var isDraggingResize: Bool = false
    @State private var dragStartWidth: CGFloat = 0

    public var body: some View {
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
            input: input,
            theme: theme,
            encoder: encoder,
            projectName: projectName,
            gitBranch: gitBranch,
            leadingPadding: leadingPadding,
            frameProbe: frameProbe
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
            .accessibilityLabel("Sidebar resize handle")
            .accessibilityAdjustableAction { direction in
                let step: CGFloat = 20
                switch direction {
                case .increment:
                    sidebarWidth = SidebarSizing.clamp(sidebarWidth + step, for: activeSidebar)
                case .decrement:
                    sidebarWidth = SidebarSizing.clamp(sidebarWidth - step, for: activeSidebar)
                @unknown default:
                    break
                }
            }
    }
}
