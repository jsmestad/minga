import AppKit
import SwiftUI

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
/// dark screen. Fades out when the first batch_end arrives.
///
/// Adapts to the macOS system appearance (light/dark) to minimize the flash
/// when the editor's actual theme loads. The exact theme colors are not
/// available yet (BEAM has not sent guiTheme), but matching the system
/// appearance gets close enough for most users.
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
struct ContentView: View {
    var appState: AppState
    @State private var rightPaneHeight: CGFloat = 600
    @State private var sidebarWidth: CGFloat = SidebarSizing.defaultWidth
    @State private var changeSummaryWidth: CGFloat = 280

    private let activityBarWidth: CGFloat = 32

    private var showSidebarContent: Bool {
        appState.gui.sidebarHostState.hasVisibleSidebar
    }

    private var showChangeSummary: Bool {
        appState.gui.changeSummaryState.visible
    }

    private var theme: ThemeColors { appState.gui.themeColors }

    private var titleBarLeadingPadding: CGFloat {
        appState.isFullScreen ? 10 : 84
    }

    private var sidebarHeaderLeadingPadding: CGFloat {
        appState.isFullScreen ? 12 : 36
    }

    private var projectName: String {
        if !appState.gui.fileTreeState.projectRoot.isEmpty {
            return (appState.gui.fileTreeState.projectRoot as NSString).lastPathComponent
        }
        return "Minga"
    }

    private var gitBranch: String {
        appState.gui.statusBarState.gitBranch
    }

    private var notificationCenterBottomInset: CGFloat {
        let statusBarHeight: CGFloat = 24
        let panelHeight: CGFloat

        if appState.gui.bottomPanelState.visible {
            let maxPanelHeight = rightPaneHeight * 0.6
            panelHeight = min(max(appState.gui.bottomPanelState.userHeight, 100), maxPanelHeight)
        } else {
            panelHeight = 0
        }

        return statusBarHeight + panelHeight + 18
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                unifiedToolbar
                HStack(spacing: 0) {
                    sidebarBody
                    editorBody
                }
                statusBar
            }
            windowOverlays
        }
        .navigationTitle(appState.windowTitle)
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(appState.windowBgIsDark ? .dark : .light)
        .onAppear {
            applyActiveSidebarPreferredWidth()
        }
        .onChange(of: appState.gui.sidebarHostState.activeSidebar) { _, _ in
            applyActiveSidebarPreferredWidth()
        }
    }

    private func applyActiveSidebarPreferredWidth() {
        sidebarWidth = SidebarSizing.widthByApplyingPreferred(
            for: appState.gui.sidebarHostState.activeSidebar,
            currentWidth: sidebarWidth
        )
    }

    // MARK: - Unified Toolbar

    /// Single toolbar row spanning the full window width. Contains the
    /// sidebar header (when visible) and the tab bar, sharing one background.
    private let contentHeight: CGFloat = 28
    private let workspaceHeaderHeight: CGFloat = 30

    private var showsWorkspaceHeader: Bool {
        appState.gui.workspaceState.shouldShowHeader
    }

    private var toolbarContentHeight: CGFloat {
        showsWorkspaceHeader ? contentHeight + workspaceHeaderHeight : contentHeight
    }

    private var toolbarTopPadding: CGFloat {
        max(appState.trafficLightMidY - contentHeight / 2, 0)
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
                            workspaceState: appState.gui.workspaceState,
                            theme: theme,
                            encoder: appState.encoder
                        )
                    }

                    if !appState.gui.tabBarState.tabs.isEmpty || !appState.gui.workspaceState.visibleTabs.isEmpty {
                        TabBarView(
                            tabBarState: appState.gui.tabBarState,
                            theme: theme,
                            encoder: appState.encoder
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
            }
        }
    }

    /// Renders the header for the BEAM-selected semantic sidebar.
    @ViewBuilder
    private var sidebarHeaderContent: some View {
        if let activeSidebar = appState.gui.sidebarHostState.activeSidebar {
            NativeSidebarRegistry
                .adapterOrFallback(for: activeSidebar.semanticKind)
                .makeHeader(sidebarContext, activeSidebar)
        }
    }

    private var sidebarContext: NativeSidebarContext {
        NativeSidebarContext(
            guiState: appState.gui,
            theme: theme,
            encoder: appState.encoder,
            projectName: projectName,
            gitBranch: gitBranch,
            leadingPadding: sidebarHeaderLeadingPadding
        )
    }

    private var compactProjectBranchHeader: some View {
        HStack(spacing: 6) {
            Text("\u{F024B}")
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
                guiState: appState.gui,
                sidebarHostState: appState.gui.sidebarHostState,
                theme: theme,
                encoder: appState.encoder
            )

            if let activeSidebar = appState.gui.sidebarHostState.activeSidebar {
                SidebarContainer(
                    guiState: appState.gui,
                    activeSidebar: activeSidebar,
                    theme: theme,
                    encoder: appState.encoder,
                    projectName: projectName,
                    gitBranch: gitBranch,
                    leadingPadding: titleBarLeadingPadding,
                    sidebarWidth: $sidebarWidth
                )
            }
        }
    }

    // MARK: - Change Summary Sidebar

    @State private var changeSummaryMinWidth: CGFloat = 200
    @State private var changeSummaryMaxWidth: CGFloat = 400
    @State private var isDraggingChangeSummaryResize: Bool = false

    @ViewBuilder
    private var changeSummarySidebar: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ChangeSummaryView(
                    state: appState.gui.changeSummaryState,
                    theme: theme,
                    encoder: appState.encoder
                )
            }
            .frame(width: changeSummaryWidth)
            .background(theme.treeBg)

            // Resize handle (8px hit target with 1px visible separator)
            Color.clear
                .frame(width: 8)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(isDraggingChangeSummaryResize ? theme.treeActiveFg.opacity(0.3) : theme.treeSeparatorFg.opacity(0.4))
                        .frame(width: 1)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            isDraggingChangeSummaryResize = true
                            let newWidth = changeSummaryWidth + value.translation.width
                            changeSummaryWidth = min(max(newWidth, changeSummaryMinWidth), changeSummaryMaxWidth)
                        }
                        .onEnded { _ in
                            isDraggingChangeSummaryResize = false
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

    // MARK: - Editor Body

    @Namespace private var zoomNamespace

    private var editorBody: some View {
        VStack(spacing: 0) {

            // Conditionally show agent context bar (when zoomed into an agent card)
            // or breadcrumb bar (when in traditional editor or zoomed into You card)
            if appState.gui.agentContextBarState.visible {
                AgentContextBar(
                    state: appState.gui.agentContextBarState,
                    theme: appState.gui.themeColors,
                    encoder: appState.encoder
                )
            } else {
                BreadcrumbBar(
                    state: appState.gui.breadcrumbState,
                    theme: appState.gui.themeColors,
                    encoder: appState.encoder
                )
            }

            // Search toolbar (appears below breadcrumb bar when active)
            if appState.gui.searchState.visible {
                SearchToolbar(
                    searchState: appState.gui.searchState,
                    theme: appState.gui.themeColors,
                    encoder: appState.encoder
                )
                .transition(
                    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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

                // ZStack: editor surface (always present for keyboard input)
                // with Board overlay on top when active.
                ZStack {
                    editorSurface
                        .opacity(appState.gui.boardState.visible ? 0 : 1)

                    if appState.gui.boardState.visible {
                        BoardView(
                            state: appState.gui.boardState,
                            dispatchSheet: appState.gui.dispatchSheetState,
                            theme: appState.gui.themeColors,
                            encoder: appState.encoder,
                            namespace: zoomNamespace
                        )
                        .transition(
                            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                                ? .opacity
                                : .scale(scale: 0.97).combined(with: .opacity)
                        )
                    }
                }
            }
            .animation(
                NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    ? nil
                    : .spring(response: 0.25, dampingFraction: 0.85),
                value: appState.gui.boardState.visible
            )
            .animation(
                NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    ? nil
                    : .spring(response: 0.25, dampingFraction: 0.85),
                value: appState.gui.boardState.zoomedCardId
            )
            .onChange(of: appState.gui.boardState.visible) { _, newVisible in
                appState.editorNSView?.setBoardVisible(newVisible)
            }
            .onChange(of: appState.gui.agentChatState.visible) { _, visible in
                appState.editorNSView?.setAgentChatVisible(visible)
            }

            // Edit timeline scrubber (between editor and bottom panel)
            EditTimelineView(
                state: appState.gui.editTimelineState,
                themeColors: appState.gui.themeColors,
                encoder: appState.encoder
            )

            // Bottom panel (between editor and status bar)
            if appState.gui.bottomPanelState.visible {
                BottomPanelView(
                    state: appState.gui.bottomPanelState,
                    theme: appState.gui.themeColors,
                    encoder: appState.encoder,
                    availableHeight: rightPaneHeight
                )
            }

            // Native minibuffer (appears above status bar when active)
            if appState.gui.minibufferState.visible {
                MinibufferView(
                    state: appState.gui.minibufferState,
                    theme: appState.gui.themeColors,
                    encoder: appState.encoder
                )
                .transition(
                    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                        ? .opacity.animation(.easeInOut(duration: 0.1))
                        : .move(edge: .bottom)
                            .combined(with: .opacity)
                            .animation(.easeInOut(duration: 0.15))
                )
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: PaneHeightKey.self,
                    value: geo.size.height
                )
            }
        )
        .onPreferenceChange(PaneHeightKey.self) { height in
            rightPaneHeight = height
        }
    }

    // MARK: - Editor Surface (Metal + editor-local overlays)

    private func completionOverlayCursor() -> (row: Int, col: Int, gutterPad: CGFloat) {
        guard let nsView = appState.editorNSView else {
            return (appState.gui.completionState.anchorRow, appState.gui.completionState.anchorCol, 0)
        }

        let frameState = nsView.dispatcher.frameState
        let gutterPad: CGFloat

        if frameState.gutterCol > 0 {
            if frameState.cursorCol >= frameState.gutterCol {
                gutterPad = CoreTextMetalRenderer.gutterLeftMarginPt + CoreTextMetalRenderer.gutterRightGapPt
            } else {
                gutterPad = CoreTextMetalRenderer.gutterLeftMarginPt
            }
        } else {
            gutterPad = 0
        }

        return (Int(frameState.cursorRow), Int(frameState.cursorCol), gutterPad)
    }

    private var editorSurface: some View {
        ZStack(alignment: .topLeading) {
            // Metal editor surface (always present for input handling).
            // Hidden when agent chat is visible so the SwiftUI chat overlay
            // is not occluded by the NSView layer (AppKit NSViews render
            // above SwiftUI views in a ZStack regardless of child order).
            Group {
                if let nsView = appState.editorNSView {
                    EditorView(editorNSView: nsView)
                } else {
                    Color(red: 0.12, green: 0.12, blue: 0.14)
                }
            }
            .opacity(appState.gui.agentChatState.visible ? 0 : 1)

            if appState.gui.agentChatState.visible {
                AgentChatView(
                    state: appState.gui.agentChatState,
                    theme: appState.gui.themeColors,
                    isInsertMode: appState.gui.statusBarState.isInsertMode,
                    encoder: appState.encoder,
                    cellHeight: CGFloat(appState.editorNSView?.cellHeight ?? 16)
                )
            }

            // Completion overlay (positioned at cursor)
            if appState.gui.completionState.visible {
                let cw = CGFloat(appState.editorNSView?.cellWidth ?? 8)
                let ch = CGFloat(appState.editorNSView?.cellHeight ?? 16)
                let cursor = completionOverlayCursor()
                let x = CGFloat(cursor.col) * cw + cursor.gutterPad
                let y = (CGFloat(cursor.row) + 1) * ch

                CompletionOverlay(
                    state: appState.gui.completionState,
                    theme: appState.gui.themeColors,
                    encoder: appState.encoder
                )
                .offset(x: x, y: y)
            }

            // Overlay shared dimensions (computed once for all overlays)
            let overlayCW = CGFloat(appState.editorNSView?.cellWidth ?? 8)
            let overlayCH = CGFloat(appState.editorNSView?.cellHeight ?? 16)
            let overlayVPW = CGFloat(appState.editorNSView?.bounds.width ?? 800)

            // Signature help overlay (lowest overlay z-order)
            if appState.gui.signatureHelpState.visible {
                SignatureHelpOverlay(
                    state: appState.gui.signatureHelpState,
                    theme: appState.gui.themeColors,
                    cellWidth: overlayCW,
                    cellHeight: overlayCH,
                    viewportHeight: rightPaneHeight,
                    viewportWidth: overlayVPW
                )
            }

            // Hover popup overlay (above signature help, below completion)
            if appState.gui.hoverPopupState.visible {
                HoverPopupOverlay(
                    state: appState.gui.hoverPopupState,
                    theme: appState.gui.themeColors,
                    cellWidth: overlayCW,
                    cellHeight: overlayCH,
                    viewportHeight: rightPaneHeight,
                    viewportWidth: overlayVPW,
                    encoder: appState.encoder
                )
            }
        }
    }

    // MARK: - Status Bar (full window width)

    private var statusBar: some View {
        StatusBarView(
            state: appState.gui.statusBarState,
            theme: appState.gui.themeColors,
            encoder: appState.encoder,
            isFileTreeVisible: appState.gui.fileTreeState.visible,
            isGitStatusVisible: appState.gui.gitStatusState.visible,
            isBottomPanelVisible: appState.gui.bottomPanelState.visible,
            isAgentChatVisible: appState.gui.agentChatState.visible,
            gitSyncing: appState.gui.gitStatusState.syncing
        )
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
                    state: appState.gui.whichKeyState,
                    theme: appState.gui.themeColors
                )
                Spacer()
            }
        }

        // Picker overlay (floats over entire window)
        PickerOverlay(
            state: appState.gui.pickerState,
            theme: appState.gui.themeColors,
            encoder: appState.encoder
        )

        // Tool manager overlay (floats over entire window)
        ToolManagerView(
            state: appState.gui.toolManagerState,
            theme: appState.gui.themeColors,
            encoder: appState.encoder
        )

        // Float popup overlay (centered, like picker)
        if appState.gui.floatPopupState.visible {
            let cw = CGFloat(appState.editorNSView?.cellWidth ?? 8)
            let ch = CGFloat(appState.editorNSView?.cellHeight ?? 16)

            FloatPopupOverlay(
                state: appState.gui.floatPopupState,
                theme: appState.gui.themeColors,
                cellWidth: cw,
                cellHeight: ch
            )
        }

        // Notification stack (bottom-right, above regular workspace content).
        NotificationCenterView(
            state: appState.gui.notificationCenterState,
            theme: appState.gui.themeColors,
            encoder: appState.encoder,
            bottomInset: notificationCenterBottomInset
        )

        // Startup overlay: covers the empty Metal framebuffer with a
        // spinner while the BEAM boots. Fades out on first batch_end.
        if !appState.hasReceivedFirstFrame {
            StartupOverlay()
                .transition(.opacity)
        }
    }
}
