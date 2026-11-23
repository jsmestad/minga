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

    /// The saved width after a resize drag that started at `start`, the width on screen.
    /// In a narrow window `start` is below `preference`, and widening the drag cannot show more because the layout pins the width. So a drag that does not narrow the sidebar keeps the saved preference; only a drag that narrows it lowers the preference.
    public static func draggedWidth(start: CGFloat, preference: CGFloat, translation: CGFloat, for item: SidebarItem?) -> CGFloat {
        let proposed = clamp(start + translation, for: item)
        guard proposed >= start else { return proposed }
        return max(proposed, preference)
    }

    /// The narrowest the sidebar is ever presented, below the 180 pt drag minimum.
    /// It still shows file icons with short names and the header's project icon and actions.
    public static let narrowMinWidth: CGFloat = 100

    /// The width the content beside the sidebar keeps before the sidebar narrows.
    /// 280 pt holds about 35 characters of 13 pt Agent transcript text after the card insets, which reads as prose rather than one word per line.
    public static let contentMinWidth: CGFloat = 280

    /// The presented width of the sidebar column: its ideal width when the window has room, otherwise narrower down to its minimum so the content keeps `contentMinimum`.
    nonisolated public static func presentedLeadingWidth(available: CGFloat, ideal: CGFloat, minimum: CGFloat, contentMinimum: CGFloat) -> CGFloat {
        let yielding = available - contentMinimum
        return min(ideal, max(minimum, yielding))
    }
}

public struct SidebarContainer: View {
    public enum Action: Equatable, Sendable {
        case fileTreeHeader(FileTreeHeaderView.Action)
        case fileTree(FileTreeView.Action)
        case gitStatus(GitStatusView.Action)
        case observatory(ObservatoryView.Action)
    }

    public init(input: ShellHostInput, activeSidebar: SidebarItem, sendAction: ViewActionHandler<Action>?, sidebarWidth: Binding<CGFloat>) {
        self.input = input
        self.activeSidebar = activeSidebar
        self.sendAction = sendAction
        self._sidebarWidth = sidebarWidth
        frameProbe = nil
    }

    init(input: ShellHostInput, activeSidebar: SidebarItem, sendAction: ViewActionHandler<Action>?, sidebarWidth: Binding<CGFloat>, frameProbe: ContentViewFrameProbe?) {
        self.input = input
        self.activeSidebar = activeSidebar
        self.sendAction = sendAction
        self._sidebarWidth = sidebarWidth
        self.frameProbe = frameProbe
    }

    public let input: ShellHostInput
    public let activeSidebar: SidebarItem
    @Environment(\.themeColors) private var theme

    public let sendAction: ViewActionHandler<Action>?
    @Binding public var sidebarWidth: CGFloat
    let frameProbe: ContentViewFrameProbe?

    @State private var isDraggingResize: Bool = false
    @State private var dragStartWidth: CGFloat = 0
    @State private var dragStartPreference: CGFloat = 0
    /// The width on screen, which is narrower than `sidebarWidth` in a narrow window. A drag starts from what the user sees.
    @State private var presentedWidth: CGFloat = SidebarSizing.defaultWidth

    public var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                NativeSidebarBody(
                    input: input,
                    item: activeSidebar,
                    sendAction: sendAction,
                    frameProbe: frameProbe
                )
            }
            // Narrows below the user's width only when SidebarSplitLayout offers less; never wider.
            .frame(minWidth: SidebarSizing.narrowMinWidth, idealWidth: sidebarWidth, maxWidth: sidebarWidth)
            .background(theme.treeBg)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                presentedWidth = width
            }

            resizeHandle
        }
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
                            dragStartWidth = min(sidebarWidth, presentedWidth)
                            dragStartPreference = sidebarWidth
                        }
                        sidebarWidth = SidebarSizing.draggedWidth(
                            start: dragStartWidth,
                            preference: dragStartPreference,
                            translation: value.translation.width,
                            for: activeSidebar
                        )
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
