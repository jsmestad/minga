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

enum ContentViewFrameProbePoint: Hashable {
    case shell
    case fileTree
    case editor
    case editorOverlay
    case extensionOverlay
    case windowOverlay
}

struct ContentViewFrameProbe {
    let makeView: (ContentViewFrameProbePoint, String, AnyObject) -> AnyView
}

private struct ShellFramePresentationHost<Content: View>: View {
    let metrics: GUIFramePresentationMetrics
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frameNativeDrawProbe(domain: .shell, metrics: metrics)
    }
}

private struct UnifiedToolbarHost<Content: View>: View {
    let input: ShellHostInput
    @ViewBuilder let content: (ShellHostInput) -> Content

    var body: some View {
        content(input)
            .environment(\.themeColors, input.currentTheme)
    }
}

private struct SidebarHost<Content: View>: View {
    let input: ShellHostInput
    @ViewBuilder let content: (ShellHostInput) -> Content

    var body: some View {
        content(input)
            .environment(\.themeColors, input.currentTheme)
    }
}

private struct EditorColumnHost<Content: View>: View {
    let input: ShellHostInput
    @ViewBuilder let content: (ShellHostInput) -> Content

    var body: some View {
        content(input)
            .environment(\.themeColors, input.currentTheme)
    }
}

private struct EditorSurfaceHost<Content: View>: View {
    let input: EditorHostInput
    @ViewBuilder let content: (EditorHostInput) -> Content

    var body: some View {
        content(input)
            .environment(\.themeColors, input.currentTheme)
    }
}

private struct StatusBarHost<Content: View>: View {
    let input: ShellHostInput
    @ViewBuilder let content: (ShellHostInput) -> Content

    var body: some View {
        content(input)
            .environment(\.themeColors, input.currentTheme)
    }
}

private struct WindowOverlayHost<Content: View>: View {
    let input: WindowOverlayHostInput
    let metrics: GUIFramePresentationMetrics
    @ViewBuilder let content: (WindowOverlayHostInput) -> Content

    var body: some View {
        content(input)
            .environment(\.themeColors, input.currentTheme)
            .frameNativeDrawProbe(domain: .windowOverlay, metrics: metrics)
    }
}

private struct EditorOverlayHost<ExtensionContent: View>: View {
    let input: EditorOverlayHostInput
    let metrics: GUIFramePresentationMetrics
    let geometry: EditorGeometry
    let viewportHeight: CGFloat
    let encoder: InputEncoder?
    let frameProbe: ContentViewFrameProbe?
    @ViewBuilder let extensionContent: () -> ExtensionContent

    var body: some View {
        ZStack(alignment: .topLeading) {
            if input.signatureHelpState.visible {
                anchoredOverlay(row: input.signatureHelpState.anchorRow, col: input.signatureHelpState.anchorCol, preferredSide: .above, maxHeight: 220) { _ in
                    SignatureHelpOverlay(state: input.signatureHelpState)
                        .allowsHitTesting(false)
                }
                .zIndex(10)
            }

            if input.hoverPopupState.visible {
                anchoredOverlay(row: input.hoverPopupState.anchorRow, col: input.hoverPopupState.anchorCol, preferredSide: .above, maxHeight: 300) { _ in
                    HoverPopupOverlay(state: input.hoverPopupState, encoder: encoder)
                        .allowsHitTesting(true)
                }
                .zIndex(20)
            }

            if input.completionState.visible {
                anchoredOverlay(row: input.completionState.anchorRow, col: input.completionState.anchorCol, preferredSide: .below, maxHeight: 420, gap: 2) { _ in
                    CompletionOverlay(state: input.completionState, encoder: encoder)
                        .background {
                            probe(
                                .editorOverlay,
                                value: input.completionState.items.map(\.label).joined(separator: ","),
                                stateObject: input.completionState
                            )
                        }
                }
                .zIndex(30)
            }

            extensionContent()
        }
        .environment(\.themeColors, input.currentTheme)
        .frameNativeDrawProbe(domain: .editorOverlay, metrics: metrics)
    }

    @ViewBuilder
    private func probe(_ point: ContentViewFrameProbePoint, value: String, stateObject: AnyObject) -> some View {
        if let frameProbe {
            frameProbe.makeView(point, value, stateObject)
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

    let frameProbe: ContentViewFrameProbe?

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
        frameProbe = nil
    }

    init(
        gui: GUIState,
        encoder: @escaping () -> InputEncoder?,
        editorGeometry: @escaping () -> EditorGeometry,
        chrome: WindowChrome,
        onAgentChatVisibleChange: @escaping (Bool) -> Void,
        frameProbe: ContentViewFrameProbe,
        @ViewBuilder makeEditorSurface: @escaping () -> EditorSurface
    ) {
        self.gui = gui
        self.encoderProvider = encoder
        self.editorGeometry = editorGeometry
        self.chrome = chrome
        self.onAgentChatVisibleChange = onAgentChatVisibleChange
        self.makeEditorSurface = makeEditorSurface
        self.frameProbe = frameProbe
    }

    @ViewBuilder
    private func frameProbeView(_ point: ContentViewFrameProbePoint, value: String, stateObject: AnyObject) -> some View {
        if let frameProbe {
            frameProbe.makeView(point, value, stateObject)
        }
    }

    private let activityBarWidth: CGFloat = 32

    private var titleBarLeadingPadding: CGFloat {
        chrome.isFullScreen ? 10 : 84
    }

    private var sidebarHeaderLeadingPadding: CGFloat {
        chrome.isFullScreen ? 12 : 36
    }

    private func projectName(_ input: ShellHostInput) -> String {
        if !input.fileTreeState.projectRoot.isEmpty {
            return (input.fileTreeState.projectRoot as NSString).lastPathComponent
        }
        return "Minga"
    }

    private func notificationCenterBottomInset(_ input: WindowOverlayHostInput) -> CGFloat {
        let statusBarHeight: CGFloat = 24
        let panelHeight: CGFloat

        if input.bottomPanelState.visible {
            let maxPanelHeight = rightPaneHeight * 0.6
            panelHeight = min(max(input.bottomPanelState.userHeight, 100), maxPanelHeight)
        } else {
            panelHeight = 0
        }

        return statusBarHeight + panelHeight + 18
    }

    public var body: some View {
        let metrics = gui.presentationMetrics
        let shellInput = gui.shellInput
        let editorInput = gui.editorInput
        let editorOverlayInput = gui.editorOverlayInput
        let windowOverlayInput = gui.windowOverlayInput

        return ZStack {
            ShellFramePresentationHost(metrics: metrics) {
                VStack(spacing: 0) {
                    UnifiedToolbarHost(input: shellInput) { input in
                        unifiedToolbar(input)
                    }
                    HStack(spacing: 0) {
                        SidebarHost(input: shellInput) { input in
                            sidebarBody(input)
                                .onAppear { applyActiveSidebarPreferredWidth(input) }
                                .onChange(of: input.sidebarHostState.activeSidebar) { _, _ in
                                    applyActiveSidebarPreferredWidth(input)
                                }
                        }
                        EditorColumnHost(input: shellInput) { input in
                            editorBody(
                                input,
                                editorInput: editorInput,
                                editorOverlayInput: editorOverlayInput,
                                metrics: metrics
                            )
                        }
                    }
                    StatusBarHost(input: shellInput) { input in
                        statusBar(input)
                    }
                }
            }
            WindowOverlayHost(input: windowOverlayInput, metrics: metrics) { input in
                ZStack {
                    frontendExtensionRuntimeLayer(input)
                    windowOverlays(input)
                }
            }
        }
        .navigationTitle(chrome.title)
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(chrome.backgroundIsDark ? .dark : .light)
    }

    private func applyActiveSidebarPreferredWidth(_ input: ShellHostInput) {
        sidebarWidth = SidebarSizing.widthByApplyingPreferred(
            for: input.sidebarHostState.activeSidebar,
            currentWidth: sidebarWidth
        )
    }

    // MARK: - Unified Toolbar

    /// Single toolbar row spanning the full window width. Contains the
    /// sidebar header (when visible) and the tab bar, sharing one background.
    private let contentHeight: CGFloat = 28
    private let workspaceHeaderHeight: CGFloat = 30

    private func toolbarContentHeight(_ input: ShellHostInput) -> CGFloat {
        input.workspaceState.shouldShowHeader
            ? contentHeight + workspaceHeaderHeight
            : contentHeight
    }

    private var toolbarTopPadding: CGFloat {
        max(chrome.trafficLightMidY - contentHeight / 2, 0)
    }

    @ViewBuilder
    private func unifiedToolbar(_ input: ShellHostInput) -> some View {
        let theme = input.currentTheme
        let toolbarHeight = toolbarContentHeight(input)
        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                if input.sidebarHostState.hasVisibleSidebar {
                    HStack(spacing: 0) {
                        Color.clear
                            .frame(width: activityBarWidth)

                        sidebarHeaderContent(input)
                            .frame(width: sidebarWidth + 8) // +8 aligns with resize handle
                    }

                    Rectangle()
                        .fill(theme.tabSeparatorFg.opacity(0.4))
                        .frame(width: 1, height: 16)
                } else {
                    compactProjectBranchHeader(input)
                }

                VStack(spacing: 0) {
                    if input.workspaceState.shouldShowHeader {
                        WorkspaceHeaderView(
                            workspaceState: input.workspaceState,
                            encoder: encoder
                        )
                    }

                    if !input.tabBarState.displayTabs.isEmpty {
                        TabBarView(
                            tabBarState: input.tabBarState,
                            encoder: encoder
                        )
                        .background {
                            frameProbeView(
                                .shell,
                                value: input.tabBarState.displayTabs.map(\.label).joined(separator: ","),
                                stateObject: input.tabBarState
                            )
                        }
                        .accessibilityIdentifier("workspace-tabbar")
                    } else {
                        Spacer()
                    }
                }
            }
            .frame(height: toolbarHeight)
            .padding(.top, toolbarTopPadding)
            .frame(maxHeight: .infinity, alignment: .top)

            Rectangle()
                .fill(theme.tabSeparatorFg.opacity(0.3))
                .frame(height: 1)
        }
        .frame(height: toolbarHeight + toolbarTopPadding + 4)
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
    private func sidebarHeaderContent(_ input: ShellHostInput) -> some View {
        if let activeSidebar = input.sidebarHostState.activeSidebar {
            NativeSidebarRegistry
                .adapterOrFallback(for: activeSidebar.semanticKind)
                .makeHeader(sidebarContext(input), activeSidebar)
        }
    }

    private func sidebarContext(_ input: ShellHostInput) -> NativeSidebarContext {
        NativeSidebarContext(
            input: input,
            theme: input.currentTheme,
            encoder: encoder,
            projectName: projectName(input),
            gitBranch: input.statusBarState.gitBranch,
            leadingPadding: sidebarHeaderLeadingPadding
        )
    }

    private func compactProjectBranchHeader(_ input: ShellHostInput) -> some View {
        let theme = input.currentTheme
        let branch = input.statusBarState.gitBranch
        return HStack(spacing: 6) {
            Text("\u{F0256}")
                .font(.custom("Symbols Nerd Font Mono", size: 12))
                .foregroundStyle(theme.treeDirFg.opacity(0.7))

            Text(projectName(input))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.tabActiveFg.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.tail)

            if !branch.isEmpty {
                Text("\u{E725}")
                    .font(.custom("Symbols Nerd Font Mono", size: 12))
                    .foregroundStyle(theme.treeDirFg.opacity(0.7))

                Text(branch)
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
    private func sidebarBody(_ input: ShellHostInput) -> some View {
        HStack(spacing: 0) {
            ActivityBar(
                input: input,
                sidebarHostState: input.sidebarHostState,
                encoder: encoder
            )

            if let activeSidebar = input.sidebarHostState.activeSidebar {
                SidebarContainer(
                    input: input,
                    activeSidebar: activeSidebar,
                    encoder: encoder,
                    projectName: projectName(input),
                    gitBranch: input.statusBarState.gitBranch,
                    leadingPadding: titleBarLeadingPadding,
                    sidebarWidth: $sidebarWidth,
                    frameProbe: frameProbe
                )
            }
        }
    }

    // MARK: - Change Summary Sidebar

    @ViewBuilder
    private func changeSummarySidebar(_ input: ShellHostInput) -> some View {
        ChangeSummarySidebarView(
            changeSummaryState: input.changeSummaryState,
            encoder: encoder,
            width: $changeSummaryWidth
        )
    }

    // MARK: - Editor Body


    private func editorBody(
        _ input: ShellHostInput,
        editorInput: EditorHostInput,
        editorOverlayInput: EditorOverlayHostInput,
        metrics: GUIFramePresentationMetrics
    ) -> some View {
        VStack(spacing: 0) {
            if input.agentContextBarState.visible {
                AgentContextBar(
                    state: input.agentContextBarState,
                    encoder: encoder
                )
            } else {
                BreadcrumbBar(
                    state: input.breadcrumbState,
                    encoder: encoder
                )
            }

            if input.searchState.visible {
                SearchToolbar(
                    searchState: input.searchState,
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

            HStack(spacing: 0) {
                if input.changeSummaryState.visible {
                    changeSummarySidebar(input)
                }

                EditorSurfaceHost(input: editorInput) { focusedInput in
                    editorSurface(
                        focusedInput,
                        overlayInput: editorOverlayInput,
                        metrics: metrics
                    )
                }

                extensionRightPanels(input)
            }
            .onChange(of: input.agentChatState.visible) { _, visible in
                onAgentChatVisibleChange(visible)
            }

            EditTimelineView(
                state: input.editTimelineState,
                encoder: encoder
            )

            if input.bottomPanelState.visible {
                BottomPanelView(
                    state: input.bottomPanelState,
                    encoder: encoder,
                    availableHeight: rightPaneHeight
                )
            }

            extensionBottomPanels(input)

            if input.minibufferState.visible {
                MinibufferView(
                    state: input.minibufferState,
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

    private func editorSurface(
        _ input: EditorHostInput,
        overlayInput: EditorOverlayHostInput,
        metrics: GUIFramePresentationMetrics
    ) -> some View {
        let geo = editorGeometry()
        return ZStack(alignment: .topLeading) {
            // The Metal surface is unconditional so its AppKit and resident identity survives.
            makeEditorSurface()
                .opacity(input.agentChatState.visible || input.emptyStateState.visible ? 0 : 1)

            if input.agentChatState.visible {
                AgentChatView(
                    state: input.agentChatState,
                    isInsertMode: input.statusBarState.isInsertMode,
                    encoder: encoder,
                    cellHeight: geo.cellHeight
                )
            }

            if input.emptyStateState.visible {
                EmptyStateView(
                    state: input.emptyStateState,
                    encoder: encoder
                )
                .background {
                    frameProbeView(
                        .editor,
                        value: input.emptyStateState.sections.flatMap(\.items).map(\.label).joined(separator: ","),
                        stateObject: input.emptyStateState
                    )
                }
            }

            EditorOverlayHost(
                input: overlayInput,
                metrics: metrics,
                geometry: geo,
                viewportHeight: rightPaneHeight,
                encoder: encoder,
                frameProbe: frameProbe
            ) {
                extensionOverlayLayer(overlayInput)
            }
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
    private func extensionOverlayLayer(_ input: EditorOverlayHostInput) -> some View {
        if !input.extensionOverlayState.entries.isEmpty {
            let geo = editorGeometry()
            let cw = geo.cellWidth
            let ch = geo.cellHeight
            let frameGutterCols = UInt16(geo.gutterCol)
            let gutterPad: CGFloat = frameGutterCols > 0
                ? geo.gutterLeftMargin + geo.gutterRightGap
                : 0

            ForEach(input.extensionOverlayState.windowIDs, id: \.self) { wid in
                let content = input.windowContent(for: wid)
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
                    overlayState: input.extensionOverlayState,
                    windowID: wid,
                    cellWidth: cw,
                    cellHeight: ch,
                    contentOrigin: origin,
                    firstColumn: scrollLeft,
                    columnCount: geometry?.textRect.width ?? 0,
                    rowCount: geometry?.textRect.height ?? 0
                )
                .background {
                    frameProbeView(
                        .extensionOverlay,
                        value: input.extensionOverlayState.entries.map(\.content).joined(separator: ","),
                        stateObject: input.extensionOverlayState
                    )
                }
            }
        }
    }

    // MARK: - Extension Panels (gui_extension_panel, 0x9D)

    /// One extension panel rendered as a themed card.
    @ViewBuilder
    private func extensionPanelCard(
        _ panel: Wire.ExtensionPanelEntry,
        theme: ThemeColors
    ) -> some View {
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
    private func extensionRightPanels(_ input: ShellHostInput) -> some View {
        let panels = input.extensionPanelState.panels(forPosition: 1)
        let theme = input.currentTheme
        if !panels.isEmpty {
            let cw = editorGeometry().cellWidth
            let basis = workspaceWidth
            let width = panels
                .map { panelCrossSize($0, cellExtent: cw, basis: basis, minimum: 160) }
                .max() ?? 280

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(panels) { panel in
                        extensionPanelCard(panel, theme: theme)
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
    private func extensionBottomPanels(_ input: ShellHostInput) -> some View {
        let panels = input.extensionPanelState.panels(forPosition: 0)
        let theme = input.currentTheme
        if !panels.isEmpty {
            let ch = editorGeometry().cellHeight
            let height = panels
                .map { panelCrossSize($0, cellExtent: ch, basis: rightPaneHeight, minimum: 80) }
                .max() ?? (rightPaneHeight * 0.4)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(panels) { panel in
                        extensionPanelCard(panel, theme: theme)
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
    private func extensionFloatPanels(_ input: WindowOverlayHostInput) -> some View {
        let panels = input.extensionPanelState.panels(forPosition: 2)
        let theme = input.currentTheme
        if !panels.isEmpty {
            VStack(spacing: 12) {
                ForEach(panels) { panel in
                    extensionPanelCard(panel, theme: theme)
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

    private func statusBar(_ input: ShellHostInput) -> some View {
        StatusBarView(
            state: input.statusBarState,
            feedbackState: input.feedbackState,
            encoder: encoder,
            isFileTreeVisible: input.fileTreeState.visible,
            isGitStatusVisible: input.gitStatusState.visible,
            isBottomPanelVisible: input.bottomPanelState.visible,
            isAgentChatVisible: input.agentChatState.visible,
            gitSyncing: input.gitStatusState.syncing
        )
    }

    // MARK: - Frontend Extension Runtime

    @ViewBuilder
    private func frontendExtensionRuntimeLayer(_ input: WindowOverlayHostInput) -> some View {
        let context = FrontendExtensionViewContext(
            theme: input.currentTheme,
            encoder: encoder,
            namespace: frontendExtensionNamespace
        )
        ForEach(input.frontendExtensions.activeExtensionIDs, id: \.self) { extensionID in
            if let view = input.frontendExtensions.view(for: extensionID, context: context) {
                view
            }
        }
    }

    // MARK: - Window Overlays (floating UI on top of everything)

    @ViewBuilder
    private func windowOverlays(_ input: WindowOverlayHostInput) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                WhichKeyOverlay(state: input.whichKeyState)
                Spacer()
            }
        }

        PickerOverlay(
            state: input.pickerState,
            encoder: encoder
        )
        .background {
            frameProbeView(
                .windowOverlay,
                value: input.pickerState.items.map(\.label).joined(separator: ","),
                stateObject: input.pickerState
            )
        }

        ToolManagerView(
            state: input.toolManagerState,
            encoder: encoder
        )

        if input.floatPopupState.visible {
            let geo = editorGeometry()
            FloatPopupOverlay(
                state: input.floatPopupState,
                cellWidth: geo.cellWidth,
                cellHeight: geo.cellHeight
            )
        }

        extensionFloatPanels(input)

        NotificationCenterView(
            state: input.notificationCenterState,
            encoder: encoder,
            bottomInset: notificationCenterBottomInset(input)
        )

        LatencyHUDOverlay(state: input.latencyHUDState)

        ResyncOverlay(
            state: input.resyncState,
            onRetry: { lastGoodFrameSeq, generation in
                encoder?.sendRequestKeyframe(lastGoodFrameSeq: lastGoodFrameSeq, generation: generation)
            }
        )

        if !chrome.hasReceivedFirstFrame {
            StartupOverlay()
                .transition(.opacity)
        }

        if input.protocolErrorState.isPresented {
            ProtocolErrorOverlay(state: input.protocolErrorState)
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
