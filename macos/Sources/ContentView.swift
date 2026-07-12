import MingaUI
import AppKit
import SwiftUI
import MingaProtocol

public struct AnchoredOverlayPlacement: Equatable {
    public let offsetY: CGFloat
    public let maxHeight: CGFloat
    public let side: AnchoredOverlaySide

    public var showsAbove: Bool {
        side == .above
    }

    public static func resolve(
        anchorRow: Int,
        cellHeight: CGFloat,
        measuredHeight: CGFloat,
        viewportHeight: CGFloat,
        desiredMaxHeight: CGFloat,
        preferredSide: AnchoredOverlaySide,
        gap: CGFloat,
        bottomInset: CGFloat
    ) -> AnchoredOverlayPlacement {
        let anchorTop = CGFloat(anchorRow) * cellHeight
        let anchorBottom = anchorTop + cellHeight
        let availableAbove = max(anchorTop - gap, 0)
        let availableBelow = max(viewportHeight - bottomInset - anchorBottom - gap, 0)
        let candidateHeight = measuredHeight > 0 ? min(measuredHeight, desiredMaxHeight) : desiredMaxHeight
        let side = resolveSide(preferredSide: preferredSide, candidateHeight: candidateHeight, availableAbove: availableAbove, availableBelow: availableBelow)
        let availableOnSide = side == .above ? availableAbove : availableBelow
        let maxHeight = min(desiredMaxHeight, max(availableOnSide, 1))
        let renderedHeight = min(measuredHeight > 0 ? measuredHeight : maxHeight, maxHeight)
        let offsetY = side == .above ? max(anchorTop - gap - renderedHeight, 0) : anchorBottom + gap

        return AnchoredOverlayPlacement(offsetY: offsetY, maxHeight: maxHeight, side: side)
    }

    public static func offsetX(
        anchorCol: Int,
        cellWidth: CGFloat,
        measuredWidth: CGFloat,
        viewportWidth: CGFloat,
        gutterPad: CGFloat,
        rightInset: CGFloat = 8
    ) -> CGFloat {
        let rawX = CGFloat(anchorCol) * cellWidth + gutterPad
        let maxX = max(viewportWidth - measuredWidth - rightInset, 0)
        return min(rawX, maxX)
    }

    private static func resolveSide(
        preferredSide: AnchoredOverlaySide,
        candidateHeight: CGFloat,
        availableAbove: CGFloat,
        availableBelow: CGFloat
    ) -> AnchoredOverlaySide {
        switch preferredSide {
        case .above:
            if availableAbove >= candidateHeight {
                return .above
            }
            if availableBelow >= candidateHeight {
                return .below
            }
        case .below:
            if availableBelow >= candidateHeight {
                return .below
            }
            if availableAbove >= candidateHeight {
                return .above
            }
        }

        return availableAbove >= availableBelow ? .above : .below
    }
}

/// Preference key for measuring the right pane's total height.
/// Used by BottomPanelView to cap its height at a fraction of
/// available space without needing a greedy GeometryReader.
private struct PaneHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 600
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        // Single measurement source (one GeometryReader); last write wins.
        value = nextValue()
    }
}

/// Preference key for measuring the editor column's total width.
/// Used as a stable basis for percent-sized extension panels: the panels live
/// inside this column, so its width does not shrink when a panel mounts (unlike
/// the editor NSView, which is the surface left over after the panel takes space).
private struct PaneWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 800
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct EditorOverlayHost: View {
    let gui: GUIState
    let geometry: EditorGeometry
    let viewportHeight: CGFloat
    let encoder: InputEncoder?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if gui.signatureHelpState.visible {
                anchoredOverlay(row: gui.signatureHelpState.anchorRow, col: gui.signatureHelpState.anchorCol, preferredSide: .above, maxHeight: 220) { _ in
                    SignatureHelpOverlay(state: gui.signatureHelpState)
                        .allowsHitTesting(false)
                }
                .zIndex(10)
            }

            if gui.hoverPopupState.visible {
                anchoredOverlay(row: gui.hoverPopupState.anchorRow, col: gui.hoverPopupState.anchorCol, preferredSide: .above, maxHeight: 300) { _ in
                    HoverPopupOverlay(state: gui.hoverPopupState, encoder: encoder)
                        .allowsHitTesting(true)
                }
                .zIndex(20)
            }

            if gui.completionState.visible {
                anchoredOverlay(row: gui.completionState.anchorRow, col: gui.completionState.anchorCol, preferredSide: .below, maxHeight: 420, gap: 2) { _ in
                    CompletionOverlay(state: gui.completionState, encoder: encoder)
                }
                .zIndex(30)
            }
        }
    }

    private func anchoredOverlay<Content: View>(
        row: Int,
        col: Int,
        preferredSide: AnchoredOverlaySide,
        maxHeight: CGFloat,
        gap: CGFloat = 4,
        @ViewBuilder content: @escaping (AnchoredOverlayPlacement) -> Content
    ) -> some View {
        AnchoredEditorOverlay(
            anchorRow: row,
            anchorCol: col,
            cellWidth: geometry.cellWidth,
            cellHeight: geometry.cellHeight,
            viewportHeight: viewportHeight,
            viewportWidth: geometry.viewportWidth,
            gutterPad: anchoredOverlayGutterPad(col: col),
            desiredMaxHeight: maxHeight,
            preferredSide: preferredSide,
            gap: gap,
            content: content
        )
    }

    private func anchoredOverlayGutterPad(col: Int) -> CGFloat {
        if geometry.gutterCol > 0 {
            return col >= geometry.gutterCol ? geometry.gutterLeftMargin + geometry.gutterRightGap : geometry.gutterLeftMargin
        }

        return 0
    }
}

private struct AnchoredEditorOverlay<Content: View>: View {
    let anchorRow: Int
    let anchorCol: Int
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let viewportHeight: CGFloat
    let viewportWidth: CGFloat
    let gutterPad: CGFloat
    let desiredMaxHeight: CGFloat
    let preferredSide: AnchoredOverlaySide
    let gap: CGFloat
    let bottomInset: CGFloat
    let content: (AnchoredOverlayPlacement) -> Content

    @State private var measuredHeight: CGFloat = 0
    @State private var measuredWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        anchorRow: Int,
        anchorCol: Int,
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        viewportHeight: CGFloat,
        viewportWidth: CGFloat,
        gutterPad: CGFloat,
        desiredMaxHeight: CGFloat,
        preferredSide: AnchoredOverlaySide,
        gap: CGFloat,
        bottomInset: CGFloat = 8,
        @ViewBuilder content: @escaping (AnchoredOverlayPlacement) -> Content
    ) {
        self.anchorRow = anchorRow
        self.anchorCol = anchorCol
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.viewportHeight = viewportHeight
        self.viewportWidth = viewportWidth
        self.gutterPad = gutterPad
        self.desiredMaxHeight = desiredMaxHeight
        self.preferredSide = preferredSide
        self.gap = gap
        self.bottomInset = bottomInset
        self.content = content
    }

    private var placement: AnchoredOverlayPlacement {
        AnchoredOverlayPlacement.resolve(anchorRow: anchorRow, cellHeight: cellHeight, measuredHeight: measuredHeight, viewportHeight: viewportHeight, desiredMaxHeight: desiredMaxHeight, preferredSide: preferredSide, gap: gap, bottomInset: bottomInset)
    }

    private var offsetX: CGFloat {
        AnchoredOverlayPlacement.offsetX(anchorCol: anchorCol, cellWidth: cellWidth, measuredWidth: measuredWidth, viewportWidth: viewportWidth, gutterPad: gutterPad)
    }

    var body: some View {
        let placement = placement
        content(placement)
            .environment(\.anchoredOverlayContext, AnchoredOverlayContext(side: placement.side, maxHeight: placement.maxHeight))
            .frame(maxHeight: placement.maxHeight)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .preference(key: AnchoredOverlayHeightKey.self, value: geo.size.height)
                        .preference(key: AnchoredOverlayWidthKey.self, value: geo.size.width)
                }
            )
            .onPreferenceChange(AnchoredOverlayHeightKey.self) { measuredHeight = $0 }
            .onPreferenceChange(AnchoredOverlayWidthKey.self) { measuredWidth = $0 }
            .offset(x: offsetX, y: placement.offsetY)
            .transition(transition(for: placement.side))
    }

    private func transition(for side: AnchoredOverlaySide) -> AnyTransition {
        if reduceMotion {
            return .opacity.animation(.easeInOut(duration: 0.08))
        }

        let anchor: UnitPoint = side == .above ? .bottomLeading : .topLeading
        let motionY: CGFloat = side == .above ? 6 : -6

        return .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.985, anchor: anchor))
                .combined(with: .offset(x: 0, y: motionY))
                .animation(.easeOut(duration: 0.14)),
            removal: .opacity.animation(.easeIn(duration: 0.08))
        )
    }
}

private struct AnchoredOverlayHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct AnchoredOverlayWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Transparent AppKit hit region that preserves standard title-bar interactions for the custom toolbar.
private struct TitleBarDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        TitleBarDragNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class TitleBarDragNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            performSystemDoubleClickAction()
            return
        }

        super.mouseDown(with: event)
    }

    private func performSystemDoubleClickAction() {
        let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")?.lowercased()
        switch action {
        case "minimize":
            window?.performMiniaturize(nil)
        case "none":
            return
        default:
            window?.performZoom(nil)
        }
    }
}

/// Loading overlay shown while the BEAM boots and renders its first frame.
/// Covers the empty Metal framebuffer with the app icon, a spinner, and a
/// random quip so the user sees a friendly loading state instead of a blank
/// dark screen. Fades out when the first commit_frame arrives.
///
/// Adapts to the macOS system appearance (light/dark) before the BEAM sends
/// guiTheme. The overlay is a loading surface, not a theme fallback; the BEAM
/// still owns the editor theme.
struct StartupOverlay: View {
    @Environment(\.colorScheme) private var systemScheme

    private static let quips = [
        "Reticulating splines…",
        "Warming up the BEAM…",
        "Spawning processes…",
        "Consulting the oracle…",
        "Aligning the gap buffer…",
        "Negotiating with tree-sitter…",
        "Calibrating modal flux…",
        "Herding supervisors…",
        "Entering god mode…",
        "The cake is a lie…",
        "It's dangerous to go alone…",
        "Kept you waiting, huh?",
        "Calibrating…",
        "Preparing emotional states…",
        "Escaping to normal mode…",
        "M-x start-editor",
    ]

    /// Picked once per overlay lifetime so it doesn't change mid-fade.
    @State private var quip = quips.randomElement()!

    private var backgroundColor: Color {
        if systemScheme == .dark {
            Color(red: 0.12, green: 0.12, blue: 0.14)
        } else {
            Color(red: 0.95, green: 0.95, blue: 0.96)
        }
    }

    var body: some View {
        ZStack {
            backgroundColor

            VStack(spacing: 16) {
                Image("MingaLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 96)

                ProgressView()
                    .controlSize(.small)

                Text(quip)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .ignoresSafeArea()
    }
}

/// ContentView observes AppState and switches from a placeholder to the
/// editor surface once the AppDelegate finishes initialization.
///
/// Layout hierarchy:
///   ZStack {
///     VStack { unifiedToolbar, HStack { sidebarBody, editorBody }, statusBar }
///     windowOverlays
///   }
///
/// The unified toolbar is a single row spanning the full window width,
/// containing the sidebar header (project name/branch) and the tab bar.
/// One shared background eliminates visual seams between sidebar and editor.
public struct ContentView<EditorSurface: View>: View {
    let gui: GUIState
    let encoderProvider: () -> InputEncoder?
    var encoder: InputEncoder? { encoderProvider() }
    /// Editor geometry read just-in-time inside the body. This is a closure (not
    /// a stored value) so each read reflects the live editor metrics: a value
    /// computed in MingaApp's body would go stale because MingaApp under-renders
    /// relative to ContentView.
    let editorGeometry: () -> EditorGeometry
    /// Window chrome. A plain value is safe: its inputs are `@Observable` on
    /// AppState, so it stays fresh across ContentView body re-evaluations.
    let chrome: WindowChrome
    /// Called when the agent chat visibility changes so the app can hide/show the
    /// Metal editor NSView layer underneath the SwiftUI chat overlay.
    let onAgentChatVisibleChange: (Bool) -> Void
    @ViewBuilder let makeEditorSurface: () -> EditorSurface

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var rightPaneHeight: CGFloat = 600
    @State private var workspaceWidth: CGFloat = 800
    @State private var sidebarWidth: CGFloat = SidebarSizing.defaultWidth
    @State private var changeSummaryWidth: CGFloat = 280
    @Namespace private var frontendExtensionNamespace

    public init(
        gui: GUIState,
        encoder: @escaping () -> InputEncoder?,
        editorGeometry: @escaping () -> EditorGeometry,
        chrome: WindowChrome,
        onAgentChatVisibleChange: @escaping (Bool) -> Void,
        @ViewBuilder makeEditorSurface: @escaping () -> EditorSurface
    ) {
        self.gui = gui
        self.encoderProvider = encoder
        self.editorGeometry = editorGeometry
        self.chrome = chrome
        self.onAgentChatVisibleChange = onAgentChatVisibleChange
        self.makeEditorSurface = makeEditorSurface
    }

    private let activityBarWidth: CGFloat = 32

    private var showSidebarContent: Bool {
        gui.sidebarHostState.hasVisibleSidebar
    }

    private var showChangeSummary: Bool {
        gui.changeSummaryState.visible
    }

    private var theme: ThemeColors { gui.themeColors }

    private var titleBarLeadingPadding: CGFloat {
        chrome.isFullScreen ? 10 : 84
    }

    private var sidebarHeaderLeadingPadding: CGFloat {
        chrome.isFullScreen ? 12 : 36
    }

    private var projectName: String {
        if !gui.fileTreeState.projectRoot.isEmpty {
            return (gui.fileTreeState.projectRoot as NSString).lastPathComponent
        }
        return "Minga"
    }

    private var gitBranch: String {
        gui.statusBarState.gitBranch
    }

    private var notificationCenterBottomInset: CGFloat {
        let statusBarHeight: CGFloat = 24
        let panelHeight: CGFloat

        if gui.bottomPanelState.visible {
            let maxPanelHeight = rightPaneHeight * 0.6
            panelHeight = min(max(gui.bottomPanelState.userHeight, 100), maxPanelHeight)
        } else {
            panelHeight = 0
        }

        return statusBarHeight + panelHeight + 18
    }

    public var body: some View {
        // Protocol-driven child State objects publish through these aggregate
        // swaps, never through independent nested observation notifications.
        _ = gui.framePublication
        _ = gui.outOfBandPublication

        return ZStack {
            VStack(spacing: 0) {
                unifiedToolbar
                HStack(spacing: 0) {
                    sidebarBody
                    editorBody
                }
                statusBar
            }
            frontendExtensionRuntimeLayer
            windowOverlays
        }
        .environment(\.themeColors, gui.themeColors)
        .navigationTitle(chrome.title)
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(chrome.backgroundIsDark ? .dark : .light)
        .onAppear {
            applyActiveSidebarPreferredWidth()
        }
        .onChange(of: gui.sidebarHostState.activeSidebar) { _, _ in
            applyActiveSidebarPreferredWidth()
        }
    }

    private func applyActiveSidebarPreferredWidth() {
        sidebarWidth = SidebarSizing.widthByApplyingPreferred(
            for: gui.sidebarHostState.activeSidebar,
            currentWidth: sidebarWidth
        )
    }

    // MARK: - Unified Toolbar

    /// Single toolbar row spanning the full window width. Contains the
    /// sidebar header (when visible) and the tab bar, sharing one background.
    private let contentHeight: CGFloat = 28
    private let workspaceHeaderHeight: CGFloat = 30

    private var showsWorkspaceHeader: Bool {
        gui.workspaceState.shouldShowHeader
    }

    private var toolbarContentHeight: CGFloat {
        showsWorkspaceHeader ? contentHeight + workspaceHeaderHeight : contentHeight
    }

    private var toolbarTopPadding: CGFloat {
        max(chrome.trafficLightMidY - contentHeight / 2, 0)
    }

    @ViewBuilder
    private var unifiedToolbar: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                if showSidebarContent {
                    HStack(spacing: 0) {
                        Color.clear
                            .frame(width: activityBarWidth)

                        sidebarHeaderContent
                            .frame(width: sidebarWidth + 8) // +8 aligns with resize handle
                    }

                    // Thin vertical separator between sidebar header and tab bar
                    Rectangle()
                        .fill(theme.tabSeparatorFg.opacity(0.4))
                        .frame(width: 1, height: 16)
                } else {
                    compactProjectBranchHeader
                }

                VStack(spacing: 0) {
                    if showsWorkspaceHeader {
                        WorkspaceHeaderView(
                            workspaceState: gui.workspaceState,
                            encoder: encoder
                        )
                    }

                    if !gui.tabBarState.tabs.isEmpty || !gui.workspaceState.visibleTabs.isEmpty {
                        TabBarView(
                            tabBarState: gui.tabBarState,
                            encoder: encoder
                        )
                        .accessibilityIdentifier("workspace-tabbar")
                    } else {
                        Spacer()
                    }
                }
            }
            .frame(height: toolbarContentHeight)
            .padding(.top, toolbarTopPadding)
            .frame(maxHeight: .infinity, alignment: .top)

            Rectangle()
                .fill(theme.tabSeparatorFg.opacity(0.3))
                .frame(height: 1)
        }
        .frame(height: toolbarContentHeight + toolbarTopPadding + 4)
        .background {
            ZStack {
                theme.tabBg
                TitleBarDragRegion()
                    .accessibilityHidden(true)
            }
        }
    }

    /// Renders the header for the BEAM-selected semantic sidebar.
    @ViewBuilder
    private var sidebarHeaderContent: some View {
        if let activeSidebar = gui.sidebarHostState.activeSidebar {
            NativeSidebarRegistry
                .adapterOrFallback(for: activeSidebar.semanticKind)
                .makeHeader(sidebarContext, activeSidebar)
        }
    }

    private var sidebarContext: NativeSidebarContext {
        NativeSidebarContext(
            guiState: gui,
            theme: theme,
            encoder: encoder,
            projectName: projectName,
            gitBranch: gitBranch,
            leadingPadding: sidebarHeaderLeadingPadding
        )
    }

    private var compactProjectBranchHeader: some View {
        HStack(spacing: 6) {
            Text("\u{F0256}")
                .font(.custom("Symbols Nerd Font Mono", size: 12))
                .foregroundStyle(theme.treeDirFg.opacity(0.7))

            Text(projectName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.tabActiveFg.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.tail)

            if !gitBranch.isEmpty {
                Text("\u{E725}")
                    .font(.custom("Symbols Nerd Font Mono", size: 12))
                    .foregroundStyle(theme.treeDirFg.opacity(0.7))

                Text(gitBranch)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(theme.tabActiveFg.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.leading, titleBarLeadingPadding)
        .padding(.trailing, 12)
    }

    // MARK: - Sidebar Body

    @ViewBuilder
    private var sidebarBody: some View {
        HStack(spacing: 0) {
            ActivityBar(
                guiState: gui,
                sidebarHostState: gui.sidebarHostState,
                encoder: encoder
            )

            if let activeSidebar = gui.sidebarHostState.activeSidebar {
                SidebarContainer(
                    guiState: gui,
                    activeSidebar: activeSidebar,
                    encoder: encoder,
                    projectName: projectName,
                    gitBranch: gitBranch,
                    leadingPadding: titleBarLeadingPadding,
                    sidebarWidth: $sidebarWidth
                )
            }
        }
    }

    // MARK: - Change Summary Sidebar

    @ViewBuilder
    private var changeSummarySidebar: some View {
        ChangeSummarySidebarView(
            changeSummaryState: gui.changeSummaryState,
            encoder: encoder,
            width: $changeSummaryWidth
        )
    }

    // MARK: - Editor Body


    private var editorBody: some View {
        VStack(spacing: 0) {

            // Conditionally show agent context bar (when zoomed into an agent card)
            // or breadcrumb bar (when in traditional editor or zoomed into You card)
            if gui.agentContextBarState.visible {
                AgentContextBar(
                    state: gui.agentContextBarState,
                    encoder: encoder
                )
            } else {
                BreadcrumbBar(
                    state: gui.breadcrumbState,
                    encoder: encoder
                )
            }

            // Search toolbar (appears below breadcrumb bar when active)
            if gui.searchState.visible {
                SearchToolbar(
                    searchState: gui.searchState,
                    encoder: encoder
                )
                .transition(
                    reduceMotion
                        ? .opacity.animation(.easeInOut(duration: 0.1))
                        : .move(edge: .top)
                            .combined(with: .opacity)
                            .animation(.easeInOut(duration: 0.15))
                )
            }

            // HStack: change summary sidebar (when zoomed into agent card) + editor
            HStack(spacing: 0) {
                if showChangeSummary {
                    changeSummarySidebar
                }

                editorSurface

                extensionRightPanels
            }
            .onChange(of: gui.agentChatState.visible) { _, visible in
                onAgentChatVisibleChange(visible)
            }

            // Edit timeline scrubber (between editor and bottom panel)
            EditTimelineView(
                state: gui.editTimelineState,
                encoder: encoder
            )

            // Bottom panel (between editor and status bar)
            if gui.bottomPanelState.visible {
                BottomPanelView(
                    state: gui.bottomPanelState,
                    encoder: encoder,
                    availableHeight: rightPaneHeight
                )
            }

            // Extension-registered bottom panels (gui_extension_panel, 0x9D, position 0)
            extensionBottomPanels

            // Native minibuffer (appears above status bar when active)
            if gui.minibufferState.visible {
                MinibufferView(
                    state: gui.minibufferState,
                    encoder: encoder
                )
                .transition(
                    reduceMotion
                        ? .opacity.animation(.easeInOut(duration: 0.1))
                        : .move(edge: .bottom)
                            .combined(with: .opacity)
                            .animation(.easeInOut(duration: 0.15))
                )
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .preference(key: PaneHeightKey.self, value: geo.size.height)
                    .preference(key: PaneWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(PaneHeightKey.self) { height in
            rightPaneHeight = height
        }
        .onPreferenceChange(PaneWidthKey.self) { width in
            workspaceWidth = width
        }
    }

    // MARK: - Editor Surface (Metal + editor-local overlays)

    private var editorSurface: some View {
        let geo = editorGeometry()
        return ZStack(alignment: .topLeading) {
            // Metal editor surface (always present for input handling).
            // Hidden when agent chat is visible so the SwiftUI chat overlay
            // is not occluded by the NSView layer (AppKit NSViews render
            // above SwiftUI views in a ZStack regardless of child order).
            makeEditorSurface()
                .opacity(gui.agentChatState.visible || gui.emptyStateState.visible ? 0 : 1)

            if gui.agentChatState.visible {
                AgentChatView(
                    state: gui.agentChatState,
                    isInsertMode: gui.statusBarState.isInsertMode,
                    encoder: encoder,
                    cellHeight: geo.cellHeight
                )
            }

            // Launchpad empty state (zero buffers). Swapped in over the Metal
            // surface exactly like AgentChatView; keys still flow to the BEAM.
            if gui.emptyStateState.visible {
                EmptyStateView(
                    state: gui.emptyStateState,
                    encoder: encoder
                )
            }

            EditorOverlayHost(
                gui: gui,
                geometry: geo,
                viewportHeight: rightPaneHeight,
                encoder: encoder
            )

            // Extension-registered overlays (positioned per window on the editor surface)
            extensionOverlayLayer
        }
    }

    /// Origin (in points) of a window's text rect on the editor surface, matching the
    /// Metal renderer's per-window text origin: `textCol * cellW + gutterPad - scrollLeft *
    /// cellW` horizontally and `textRow * cellH` vertically. Overlay row/col are
    /// window-local text coordinates, so an entry then lands at `origin + col*cellW`.
    nonisolated static func overlayContentOrigin(
        textCol: UInt16,
        textRow: UInt16,
        scrollLeft: UInt16,
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        gutterPad: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: CGFloat(textCol) * cellWidth + gutterPad - CGFloat(scrollLeft) * cellWidth,
            y: CGFloat(textRow) * cellHeight
        )
    }

    /// Editor-surface overlays contributed by extensions (gui_extension_overlay, 0x9C).
    /// Overlay row/col are window-local text coordinates, so each window's origin is derived
    /// from that window's retained pane geometry (`textRect`) and horizontal scroll
    /// (`scrollLeft`), which is how the Metal renderer positions the window's text. This
    /// keeps overlays aligned in split panes and under horizontal scroll. Falls back to the
    /// active window's gutter column when pane geometry has not been retained yet.
    @ViewBuilder
    private var extensionOverlayLayer: some View {
        if !gui.extensionOverlayState.entries.isEmpty {
            let geo = editorGeometry()
            let cw = geo.cellWidth
            let ch = geo.cellHeight
            let frameGutterCols = UInt16(geo.gutterCol)
            let gutterPad: CGFloat = frameGutterCols > 0
                ? geo.gutterLeftMargin + geo.gutterRightGap
                : 0

            ForEach(gui.extensionOverlayState.windowIDs, id: \.self) { wid in
                let content = gui.windowContents[wid]
                let geometry = content?.paneGeometry
                let scrollLeft = content?.scrollLeft ?? 0
                let origin = Self.overlayContentOrigin(
                    textCol: geometry?.textRect.col ?? frameGutterCols,
                    textRow: geometry?.textRect.row ?? 0,
                    scrollLeft: scrollLeft,
                    cellWidth: cw,
                    cellHeight: ch,
                    gutterPad: gutterPad
                )

                ExtensionOverlayView(
                    overlayState: gui.extensionOverlayState,
                    windowID: wid,
                    cellWidth: cw,
                    cellHeight: ch,
                    contentOrigin: origin,
                    firstColumn: scrollLeft,
                    columnCount: geometry?.textRect.width ?? 0,
                    rowCount: geometry?.textRect.height ?? 0
                )
            }
        }
    }

    // MARK: - Extension Panels (gui_extension_panel, 0x9D)

    /// One extension panel rendered as a themed card.
    @ViewBuilder
    private func extensionPanelCard(_ panel: Wire.ExtensionPanelEntry) -> some View {
        ExtensionPanelView(panel: panel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.treeBg)
    }

    /// Resolves an extension panel's requested cross-axis size (`sizeType`/`sizeValue`)
    /// to points. `sizeType` 0 = percent of `basis`; 1 = lines/columns (× `cellExtent`).
    /// Clamped to `[minimum, basis * 0.8]` so a panel can neither vanish nor crowd out
    /// the editor.
    nonisolated static func panelCrossSize(
        sizeType: UInt8,
        sizeValue: UInt8,
        cellExtent: CGFloat,
        basis: CGFloat,
        minimum: CGFloat
    ) -> CGFloat {
        let requested: CGFloat = sizeType == 0
            ? basis * CGFloat(sizeValue) / 100
            : CGFloat(sizeValue) * cellExtent
        return min(max(requested, minimum), basis * 0.8)
    }

    private func panelCrossSize(
        _ panel: Wire.ExtensionPanelEntry,
        cellExtent: CGFloat,
        basis: CGFloat,
        minimum: CGFloat
    ) -> CGFloat {
        Self.panelCrossSize(
            sizeType: panel.sizeType,
            sizeValue: panel.sizeValue,
            cellExtent: cellExtent,
            basis: basis,
            minimum: minimum
        )
    }

    /// Right-docked extension panels (position 1), shown as a sidebar column sized to
    /// the widest panel's requested size.
    @ViewBuilder
    private var extensionRightPanels: some View {
        let panels = gui.extensionPanelState.panels(forPosition: 1)
        if !panels.isEmpty {
            let cw = editorGeometry().cellWidth
            // Percent panels size against the stable editor-column width, not the editor
            // NSView (which is the surface left over after the panel takes space, causing
            // a 30% request to converge to ~23% and oscillate as layout settles).
            let basis = workspaceWidth
            let width = panels
                .map { panelCrossSize($0, cellExtent: cw, basis: basis, minimum: 160) }
                .max() ?? 280

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(panels) { panel in
                        extensionPanelCard(panel)
                        Divider()
                    }
                }
            }
            .frame(width: width)
            .background(theme.treeBg)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(theme.treeSeparatorFg.opacity(0.4))
                    .frame(width: 1)
            }
        }
    }

    /// Bottom-docked extension panels (position 0), shown above the status bar, sized to
    /// the tallest panel's requested size.
    @ViewBuilder
    private var extensionBottomPanels: some View {
        let panels = gui.extensionPanelState.panels(forPosition: 0)
        if !panels.isEmpty {
            let ch = editorGeometry().cellHeight
            let height = panels
                .map { panelCrossSize($0, cellExtent: ch, basis: rightPaneHeight, minimum: 80) }
                .max() ?? (rightPaneHeight * 0.4)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(panels) { panel in
                        extensionPanelCard(panel)
                    }
                }
            }
            .frame(maxHeight: height)
            .background(theme.treeBg)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(theme.treeSeparatorFg.opacity(0.4))
                    .frame(height: 1)
            }
        }
    }

    /// Floating extension panels (position 2), centered over the workspace.
    @ViewBuilder
    private var extensionFloatPanels: some View {
        let panels = gui.extensionPanelState.panels(forPosition: 2)
        if !panels.isEmpty {
            VStack(spacing: 12) {
                ForEach(panels) { panel in
                    extensionPanelCard(panel)
                        .frame(maxWidth: 500)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(theme.treeSeparatorFg.opacity(0.4))
                        )
                        .shadow(radius: 12)
                }
            }
        }
    }

    // MARK: - Status Bar (full window width)

    private var statusBar: some View {
        StatusBarView(
            state: gui.statusBarState,
            feedbackState: gui.feedbackState,
            encoder: encoder,
            isFileTreeVisible: gui.fileTreeState.visible,
            isGitStatusVisible: gui.gitStatusState.visible,
            isBottomPanelVisible: gui.bottomPanelState.visible,
            isAgentChatVisible: gui.agentChatState.visible,
            gitSyncing: gui.gitStatusState.syncing
        )
    }

    // MARK: - Frontend Extension Runtime

    @ViewBuilder
    private var frontendExtensionRuntimeLayer: some View {
        let context = FrontendExtensionViewContext(theme: gui.themeColors, encoder: encoder, namespace: frontendExtensionNamespace)
        ForEach(gui.frontendExtensions.activeExtensionIDs, id: \.self) { extensionID in
            if let view = gui.frontendExtensions.view(for: extensionID, context: context) {
                view
            }
        }
    }

    // MARK: - Window Overlays (floating UI on top of everything)

    @ViewBuilder
    private var windowOverlays: some View {
        // Which-key overlay (center bottom of full window)
        VStack {
            Spacer()
            HStack {
                Spacer()
                WhichKeyOverlay(
                    state: gui.whichKeyState
                )
                Spacer()
            }
        }

        // Picker overlay (floats over entire window)
        PickerOverlay(
            state: gui.pickerState,
            encoder: encoder
        )

        // Tool manager overlay (floats over entire window)
        ToolManagerView(
            state: gui.toolManagerState,
            encoder: encoder
        )

        // Float popup overlay (centered, like picker)
        if gui.floatPopupState.visible {
            let geo = editorGeometry()
            let cw = geo.cellWidth
            let ch = geo.cellHeight

            FloatPopupOverlay(
                state: gui.floatPopupState,
                cellWidth: cw,
                cellHeight: ch
            )
        }

        // Extension-registered floating panels (gui_extension_panel, 0x9D, position 2)
        extensionFloatPanels

        // Notification stack (bottom-right, above regular workspace content).
        NotificationCenterView(
            state: gui.notificationCenterState,
            encoder: encoder,
            bottomInset: notificationCenterBottomInset
        )

        // Keystroke-to-present latency HUD (ticket #2215). Top-right, client-local
        // debug overlay; visibility is owned by LatencyHUDState.
        LatencyHUDOverlay(
            state: gui.latencyHUDState
        )

        // Frame-transaction resync hint (#2219 child D). Bottom-trailing badge
        // shown while a keyframe is in flight after an invalidation; the editor keeps showing the last good frame underneath.
        // If recovery stalls, the badge becomes a small manual retry control.
        ResyncOverlay(
            state: gui.resyncState,
            onRetry: { lastGoodFrameSeq, generation in
                encoder?.sendRequestKeyframe(lastGoodFrameSeq: lastGoodFrameSeq, generation: generation)
            }
        )

        // Startup overlay: covers the empty Metal framebuffer with a
        // spinner while the BEAM boots. Fades out on first commit_frame.
        if !chrome.hasReceivedFirstFrame {
            StartupOverlay()
                .transition(.opacity)
        }

        // Protocol error overlay: blocks the whole window when the BEAM rejects
        // this frontend's handshake protocol_version (0x18). Highest z-order so
        // it takes precedence over the startup overlay and all content.
        if gui.protocolErrorState.isPresented {
            ProtocolErrorOverlay(
                state: gui.protocolErrorState
            )
        }
    }
}

// MARK: - Canvas preview

/// Builds a fully-populated `GUIState` for the canvas shell preview. No `AppState`,
/// no `EditorNSView`, and no Metal are involved: `ContentView` renders entirely
/// from injected `MingaUI` values, so the whole shell lays out in Xcode's canvas
/// with a placeholder rect where the Metal editor surface would be.
@MainActor
private func fullShellPreviewGUI() -> GUIState {
    let gui = GUIState()
    PreviewFixtures.applyPreviewTheme(to: gui.themeColors)
    PreviewFixtures.populateFileTree(gui.fileTreeState)
    PreviewFixtures.populateTabBar(gui.tabBarState)
    PreviewFixtures.populateGitStatus(gui.gitStatusState)
    gui.statusBarState.update(from: PreviewFixtures.statusBarUpdate(agentVisible: false))
    // Mark the file-tree sidebar visible + active so the shell shows the sidebar.
    gui.fileTreeState.visible = true
    gui.sidebarHostState.update(
        activeId: "file_tree",
        sidebars: [
            Wire.SidebarMetadata(
                id: "file_tree",
                displayName: "File Tree",
                semanticKind: "file_tree",
                icon: "folder",
                order: 10,
                visible: true,
                focused: true,
                preferredWidth: 30,
                badgeCount: nil
            )
        ]
    )
    return gui
}

#Preview("Full Shell", traits: .mingaChrome) {
    ContentView(
        gui: fullShellPreviewGUI(),
        encoder: { NullInputEncoder() },
        editorGeometry: { .preview },
        chrome: .preview,
        onAgentChatVisibleChange: { _ in }
    ) {
        Color(red: 0.12, green: 0.12, blue: 0.14)
            .overlay(Text("editor surface").foregroundStyle(.secondary))
    }
    .frame(width: 1200, height: 800)
}
