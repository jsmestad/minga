/// Minga macOS GUI frontend.
///
/// A SwiftUI app that speaks the Port protocol on stdin/stdout. The BEAM
/// spawns this process as a child; it reads render commands from stdin,
/// renders with Metal, and writes input events to stdout.
///
/// Architecture:
///   ProtocolReader (background thread) → decodes commands → dispatches to main thread
///   CommandDispatcher (main thread) → updates FrameState + GUIState → triggers CoreTextMetalRenderer
///   EditorNSView (main thread) → keyboard/mouse → ProtocolEncoder → stdout

import SwiftUI
import AppKit
import Darwin
import os

/// Default font settings.
private let defaultFontName = "Menlo"
private let defaultFontSize: CGFloat = 13.0

/// Default window dimensions in pixels.
private let defaultWindowWidth: CGFloat = 1200
private let defaultWindowHeight: CGFloat = 800

@main
struct MingaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appDelegate.appState)
                .frame(minWidth: 160, minHeight: 80)
                // Disable SwiftUI's focus system so it doesn't steal
                // first responder from the EditorNSView.
                .focusable(false)
                .focusEffectDisabled()
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            MingaMenuCommands(appState: appDelegate.appState)
        }

        Settings {
            SettingsView(appState: appDelegate.appState)
        }
    }
}

/// Native menu bar for Minga.
///
/// Items that map to editor commands send the appropriate event to the
/// BEAM via the protocol encoder. Items that are purely macOS-native
/// (Minimize, Zoom, Full Screen, Quit) use standard AppKit behavior.
struct MingaMenuCommands: Commands {
    let appState: AppState

    private var encoder: InputEncoder? { appState.encoder }
    private var connected: Bool { encoder != nil }

    var body: some Commands {
        // Replace the default text editing commands (Cmd+C/V/X/Z/A) with
        // our own versions that route through the BEAM.
        CommandGroup(replacing: .textEditing) {
            Button("Undo") { encoder?.sendKeyPress(codepoint: 0x75, modifiers: 0) } // 'u' = vim undo
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!connected)
            Button("Redo") { encoder?.sendKeyPress(codepoint: 0x72, modifiers: 0x02) } // Ctrl+R = vim redo
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!connected)

            Divider()

            Button("Cut") { encoder?.sendCmdCut() }
                .keyboardShortcut("x", modifiers: .command)
                .disabled(!connected)
            Button("Copy") { encoder?.sendCmdCopy() }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(!connected)
            Button("Paste") { pasteFromClipboard() }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(!connected)
            Button("Select All") { encoder?.sendExecuteCommand(name: "select_all") }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(!connected)

            Divider()

            Button("Find…") { encoder?.sendKeyPress(codepoint: 0x2F, modifiers: 0) }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!connected)
        }

        // File menu: New, Open, Save, Close Tab.
        // SwiftUI provides the default "New Window" item; we replace it with
        // "New Buffer" which opens an empty scratch buffer in the BEAM.
        CommandGroup(replacing: .newItem) {
            Button("New Buffer") { encoder?.sendExecuteCommand(name: "new_buffer") }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!connected)
        }

        CommandGroup(after: .newItem) {
            Button("Open…") { encoder?.sendExecuteCommand(name: "find_file") }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(!connected)

            Divider()

            Button("Save") { encoder?.sendExecuteCommand(name: "save") }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!connected)

            Divider()

            Button("Close Tab") { encoder?.sendExecuteCommand(name: "quit") }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(!connected)
        }

        // View menu
        CommandMenu("View") {
            Button("Toggle File Tree") { encoder?.sendTogglePanel(panel: 0) }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(!connected)
        }
    }

    /// Reads the system pasteboard and sends a paste event to the BEAM.
    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        encoder?.sendPasteEvent(text: text)
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
    @State private var sidebarWidth: CGFloat = 240
    @State private var changeSummaryWidth: CGFloat = 280
    @State private var activeSidebarPanel: ActivityBarPanel = .fileTree

    private let activityBarWidth: CGFloat = 32

    private var showSidebarContent: Bool {
        appState.gui.fileTreeState.visible || appState.gui.gitStatusState.visible
    }

    private var showChangeSummary: Bool {
        appState.gui.changeSummaryState.visible
    }

    private var theme: ThemeColors { appState.gui.themeColors }

    private var titleBarLeadingPadding: CGFloat {
        appState.isFullScreen ? 10 : 84
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
            sidebarWidth = CGFloat(appState.gui.fileTreeState.treeWidth) * 7.5
            syncActiveSidebarPanel()
        }
        .onChange(of: appState.gui.fileTreeState.visible) { _, _ in
            syncActiveSidebarPanel()
        }
        .onChange(of: appState.gui.gitStatusState.visible) { _, _ in
            syncActiveSidebarPanel()
        }
    }

    // MARK: - Unified Toolbar

    /// Single toolbar row spanning the full window width. Contains the
    /// sidebar header (when visible) and the tab bar, sharing one background.
    private let contentHeight: CGFloat = 28
    private let workspaceHeaderHeight: CGFloat = 30

    private var toolbarContentHeight: CGFloat {
        appState.gui.workspaceState.hasCanonicalPayload ? contentHeight + workspaceHeaderHeight : contentHeight
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
                    if appState.gui.workspaceState.hasCanonicalPayload {
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

    /// Switches between file tree header and git status header based on
    /// which sidebar panel the BEAM has active.
    @ViewBuilder
    private var sidebarHeaderContent: some View {
        if appState.gui.fileTreeState.visible {
            FileTreeHeaderContent(
                fileTreeState: appState.gui.fileTreeState,
                theme: theme,
                encoder: appState.encoder,
                branchName: gitBranch,
                leadingPadding: titleBarLeadingPadding
            )
        } else if appState.gui.gitStatusState.visible {
            GitStatusHeaderContent(
                state: appState.gui.gitStatusState,
                theme: theme,
                projectName: projectName,
                leadingPadding: titleBarLeadingPadding
            )
        }
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
                activePanel: activeSidebarPanel,
                gitStatusCount: appState.gui.gitStatusState.totalCount,
                theme: theme,
                encoder: appState.encoder
            )

            if showSidebarContent {
                SidebarContainer(
                    fileTreeState: appState.gui.fileTreeState,
                    gitStatusState: appState.gui.gitStatusState,
                    theme: theme,
                    encoder: appState.encoder,
                    sidebarWidth: $sidebarWidth
                )
            }
        }
    }

    private func syncActiveSidebarPanel() {
        if appState.gui.gitStatusState.visible {
            activeSidebarPanel = .gitStatus
        } else if appState.gui.fileTreeState.visible {
            activeSidebarPanel = .fileTree
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

/// App delegate that sets up the protocol reader, renderer, and wiring.
///
/// Operates in two modes:
/// - **Bundle mode**: Minga.app launched from Finder/Spotlight/Dock. The app
///   spawns the BEAM release as a child process via BEAMProcessManager.
/// - **Dev mode**: BEAM spawned us. We read/write our own stdin/stdout.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    private var beamManager: BEAMProcessManager?
    private var protocolReader: ProtocolReader?
    private var encoder: ProtocolEncoder?
    private var dispatcher: CommandDispatcher?
    private var recoveryManager: RecoveryManager?
    private var fontFace: FontFace?
    private var fontManager: FontManager?
    private var editorNSView: EditorNSView?
    private var workspaceNotificationTasks: [Task<Void, Never>] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ignore SIGPIPE so broken pipe writes return EPIPE instead of
        // killing the process. Without this, any write to the BEAM pipe
        // after Ctrl+C delivers SIGPIPE (default action: terminate).
        signal(SIGPIPE, SIG_IGN)

        os_signpost(.begin, log: startupLog, name: "AppStartup")

        // Register the bundled Nerd Font for devicon rendering.
        registerBundledFonts()

        // Register as a regular GUI app so macOS routes keyboard events to us.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

        // Initial backing scale for Retina rendering. The window does not exist yet, so NSScreen.main is the only safe source here. EditorNSView.viewDidMoveToWindow/viewDidChangeBackingProperties corrects this if the window lands on another display.
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0

        // Initialize font.
        let face = FontFace(name: defaultFontName, size: defaultFontSize, scale: scale)
        self.fontFace = face

        // Font manager for CoreText rendering.
        let fm = FontManager(name: defaultFontName, size: defaultFontSize, scale: scale)
        self.fontManager = fm

        // Initial grid dimensions (no gutter padding subtraction yet; the first
        // setFrameSize call will send corrected cols once the gutter is established).
        let cols = UInt16(max(defaultWindowWidth / CGFloat(face.cellWidth), 1))
        let rows = UInt16(defaultWindowHeight / CGFloat(face.cellHeight))

        // CoreText renderer.
        guard let ctRenderer = CoreTextMetalRenderer() else {
            NSLog("Failed to initialize CoreText Metal renderer")
            NSApp.terminate(nil)
            return
        }
        ctRenderer.setupRenderers(fontManager: fm)

        // Protocol encoder and reader: in bundle mode, we spawn the BEAM
        // and use pipe file handles. In dev mode, we use stdin/stdout.
        let protocolInput: FileHandle
        let protocolOutput: FileHandle

        if BEAMProcessManager.isBundleMode {
            let manager = BEAMProcessManager()
            self.beamManager = manager

            manager.onCrash = {
                // TODO: show error UI instead of terminating
                NSLog("BEAM crashed too many times, terminating")
                NSApp.terminate(nil)
            }
            manager.onNormalExit = {
                NSApp.terminate(nil)
            }
            manager.onBEAMReady = { [weak self] newReadHandle, newWriteHandle in
                self?.reconnectProtocol(readHandle: newReadHandle, writeHandle: newWriteHandle)
            }

            manager.start()

            guard let readH = manager.readHandle, let writeH = manager.writeHandle else {
                NSLog("Failed to start BEAM process")
                NSApp.terminate(nil)
                return
            }
            protocolInput = readH
            protocolOutput = writeH
        } else {
            // Dev mode: BEAM is our parent, use stdin/stdout
            protocolInput = .standardInput
            protocolOutput = .standardOutput
        }

        let enc = ProtocolEncoder(output: protocolOutput)
        self.encoder = enc
        appState.encoder = enc
        appState.gui.settingsState.encoder = enc

        // Enable port-based logging so messages appear in *Messages*.
        PortLogger.setup(encoder: enc)
        PortLogger.info("macOS GUI frontend starting (\(beamManager != nil ? "bundle" : "dev") mode)")
        PortLogger.info("Font: \(defaultFontName) \(Int(defaultFontSize))pt, cell: \(face.cellWidth)x\(face.cellHeight), scale: \(scale)x")
        PortLogger.info("Initial grid: \(cols)x\(rows) cells")

        // Command dispatcher.
        let disp = CommandDispatcher(cols: cols, rows: rows, guiState: appState.gui)
        disp.fontManager = fm
        disp.onFontChanged = { [weak self] family, size, ligatures, weight in
            self?.handleFontChange(family: family, size: CGFloat(size), ligatures: ligatures, weight: weight)
        }
        self.dispatcher = disp

        // Recovery manager tracks key input and render responses so Ctrl-G
        // can present a native restart dialog if the BEAM stops responding.
        let recovery = RecoveryManager { [weak self] in
            if let manager = self?.beamManager {
                manager.sendRecoveryRestartSignal()
            } else {
                let parentPid = getppid()
                if parentPid > 1 { kill(parentPid, SIGUSR1) }
            }
        }
        self.recoveryManager = recovery

        // Create the editor view.
        let nsView = EditorNSView(encoder: enc, fontFace: face, dispatcher: disp,
                                   coreTextRenderer: ctRenderer, fontManager: fm)
        nsView.guiState = appState.gui
        nsView.statusBarState = appState.gui.statusBarState
        appState.gui.settingsState.encoder = enc
        appState.gui.settingsState.onCursorBlinkChanged = { [weak nsView] enabled in
            nsView?.setCursorBlinkEnabled(enabled)
        }
        nsView.onFullScreenChanged = { [weak appState] isFullScreen in
            Task { @MainActor in
                appState?.isFullScreen = isFullScreen
            }
        }
        nsView.onTrafficLightMeasured = { [weak appState] midY in
            Task { @MainActor in
                appState?.trafficLightMidY = midY
            }
        }
        nsView.recoveryManager = recovery
        nsView.onScaleFactorChanged = { [weak self] newScale in
            self?.handleScaleChange(newScale: newScale)
        }
        self.editorNSView = nsView
        appState.editorNSView = nsView
        observeWorkspaceLifecycleNotifications()
        os_signpost(.event, log: startupLog, name: "EditorViewCreated")

        disp.onBatchEnd = { [weak recovery] in
            recovery?.onRenderReceived()
        }
        disp.onFrameReady = { [weak nsView] in
            nsView?.renderFrame()
        }
        disp.onAgentChatVisibilityChanged = { [weak nsView] visible in
            nsView?.setAgentChatVisible(visible)
        }
        disp.onModeChanged = { [weak nsView] modeName in
            guard let nsView else { return }
            nsView.statusBarModeDidChange()
            NSAccessibility.post(
                element: nsView,
                notification: .announcementRequested,
                userInfo: [.announcement: "\(modeName) mode"]
            )
        }
        disp.onLineSpacingChanged = { [weak nsView] spacing in
            nsView?.lineSpacingChanged(spacing)
        }
        disp.onCursorAnimationChanged = { [weak ctRenderer, weak nsView] enabled in
            ctRenderer?.setCursorAnimateConfigEnabled(enabled)
            nsView?.renderFrame()
        }
        disp.onTitleChanged = { [weak appState] title in
            Task { @MainActor in
                appState?.windowTitle = title
            }
        }
        disp.onWindowBgChanged = { [weak appState] color in
            Task { @MainActor in
                guard let appState else { return }
                let r = color.redComponent
                let g = color.greenComponent
                let b = color.blueComponent
                let isDark = (r * 0.299 + g * 0.587 + b * 0.114) < 0.5
                appState.windowBgIsDark = isDark
                let bgColor = NSColor(red: r, green: g, blue: b, alpha: 1)
                for window in NSApp.windows where window.identifier?.rawValue != "MingaSettingsWindow" {
                    window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
                    window.backgroundColor = bgColor
                }
            }
        }

        // The ready event is deferred: EditorNSView.setFrameSize sends it
        // once SwiftUI assigns the real frame dimensions. This avoids
        // the BEAM rendering at hardcoded 800x600 defaults.

        // Capture the encoder for the disconnect callback. The closure
        // runs on the reader's background thread; ProtocolEncoder is
        // @unchecked Sendable and disconnect() is lock-protected.
        let disconnectEncoder = enc

        // Start reading protocol commands.
        let reader = ProtocolReader(
            input: protocolInput,
            handler: { [weak self] data in
                DispatchQueue.main.async {
                    self?.handleProtocolData(data)
                }
            },
            onDisconnect: { [weak self] in
                // Immediately mark the encoder as disconnected so any
                // in-flight writes (keystrokes, mouse events) on the
                // main thread are silently dropped instead of hitting
                // a broken pipe. This runs on the reader's background
                // thread, but ProtocolEncoder.disconnect() is lock-
                // protected and safe to call from any thread.
                disconnectEncoder.disconnect()

                DispatchQueue.main.async {
                    // In bundle mode, BEAMProcessManager handles restart/error.
                    // In dev mode, our parent (BEAM) exited; shut down.
                    if self?.beamManager == nil {
                        NSApp.terminate(nil)
                    }
                }
            }
        )
        reader.start()
        self.protocolReader = reader

        // First frame callback: dismiss the startup overlay and flush any
        // pending file URLs (bundle mode only).
        disp.onFirstRender = { [weak self] in
            guard let self else { return }

            os_signpost(.end, log: startupLog, name: "AppStartup")

            let duration: Double = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.25
            withAnimation(.easeOut(duration: duration)) {
                self.appState.hasReceivedFirstFrame = true
            }

            // In bundle mode, flush file URLs buffered before the BEAM was ready.
            if let manager = self.beamManager, let enc = self.encoder {
                let urls = manager.flushPendingFileURLs()
                for url in urls {
                    enc.sendOpenFile(path: url.path)
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // In dev mode (no beamManager), terminate immediately.
        guard let manager = beamManager, !manager.isShuttingDown else {
            return .terminateNow
        }

        // In bundle mode, wait for the BEAM to exit cleanly before
        // allowing the app to terminate. This prevents orphaned BEAM
        // processes running in the background after the Dock icon disappears.
        manager.onNormalExit = {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        manager.onCrash = {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        manager.shutdownGracefully(timeout: 3.0)
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        cancelWorkspaceLifecycleNotifications()
        protocolReader?.stop()
    }

    /// Handle files opened via Finder "Open With", file associations, or
    /// `open -a Minga file.ex` from the terminal.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let enc = encoder {
            // BEAM is running, send open_file commands directly.
            for url in urls where url.isFileURL {
                enc.sendOpenFile(path: url.path)
            }
        } else if let manager = beamManager {
            // BEAM not ready yet, buffer the URLs.
            for url in urls where url.isFileURL {
                manager.bufferFileURL(url)
            }
        }
    }

    // MARK: - Workspace lifecycle notifications

    /// Registers macOS sleep and screen sleep observers.
    private func observeWorkspaceLifecycleNotifications() {
        cancelWorkspaceLifecycleNotifications()

        workspaceNotificationTasks = [
            Task { @MainActor [weak self] in
                for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.willSleepNotification) {
                    guard let self else { return }
                    PortLogger.info("System will sleep")
                    self.encoder?.sendSystemWillSleep()
                }
            },
            Task { @MainActor [weak self] in
                for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification) {
                    guard let self else { return }
                    PortLogger.info("System did wake")
                    self.encoder?.sendSystemDidWake()
                }
            },
            Task { @MainActor [weak self] in
                for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.screensDidSleepNotification) {
                    guard let self else { return }
                    PortLogger.info("Screens did sleep; pausing Metal rendering")
                    self.editorNSView?.pauseForScreenSleep()
                }
            },
            Task { @MainActor [weak self] in
                for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.screensDidWakeNotification) {
                    guard let self else { return }
                    PortLogger.info("Screens did wake; resuming Metal rendering")
                    self.editorNSView?.resumeAfterScreenWake()
                }
            },
            Task { @MainActor [weak self] in
                for await _ in NotificationCenter.default.notifications(named: NSApplication.didChangeScreenParametersNotification) {
                    guard let self else { return }
                    let scale = self.currentBackingScaleFactor()
                    PortLogger.info("Display configuration changed; current scale: \(scale)x")
                    self.editorNSView?.displayConfigurationChanged(newScale: scale, forceResizeEvent: true)
                }
            },
            Task { @MainActor [weak self] in
                for await _ in NotificationCenter.default.notifications(named: Notification.Name.NSProcessInfoPowerStateDidChange) {
                    guard let self else { return }
                    self.sendCurrentPowerThermalState(reason: "Power state changed")
                }
            },
            Task { @MainActor [weak self] in
                for await _ in NotificationCenter.default.notifications(named: ProcessInfo.thermalStateDidChangeNotification) {
                    guard let self else { return }
                    self.sendCurrentPowerThermalState(reason: "Thermal state changed")
                }
            }
        ]

        sendCurrentPowerThermalState(reason: "Initial power state")
    }

    /// Applies the current power/thermal policy locally and notifies the BEAM.
    private func sendCurrentPowerThermalState(reason: String) {
        let processInfo = ProcessInfo.processInfo
        let lowPowerMode = processInfo.isLowPowerModeEnabled
        let thermalState = processInfo.thermalState
        let encodedThermalState = PowerThermalPolicy.encodeThermalState(thermalState)
        let policy = PowerThermalPolicy.policy(lowPowerMode: lowPowerMode, thermalState: thermalState)
        let thermalName = PowerThermalPolicy.thermalStateName(thermalState)

        editorNSView?.applyPowerThermalPolicy(lowPowerMode: lowPowerMode, thermalState: thermalState)
        encoder?.sendPowerThermalState(lowPowerMode: lowPowerMode, thermalState: encodedThermalState)
        PortLogger.info("\(reason): low_power=\(lowPowerMode), thermal=\(thermalName), cursor_blink_multiplier=\(policy.cursorBlinkMultiplier)")
    }

    /// Cancels macOS sleep and screen sleep observers.
    private func cancelWorkspaceLifecycleNotifications() {
        for task in workspaceNotificationTasks {
            task.cancel()
        }
        workspaceNotificationTasks = []
    }

    // MARK: - Protocol reconnection (after BEAM restart)

    /// Replaces the protocol reader and encoder with fresh ones backed by new pipe handles.
    /// Called by BEAMProcessManager.onBEAMReady after a crash restart.
    private func reconnectProtocol(readHandle: FileHandle, writeHandle: FileHandle) {
        // Stop the old reader (its input pipe is already closed).
        protocolReader?.stop()

        // Create new encoder for the new pipe.
        let enc = ProtocolEncoder(output: writeHandle)
        self.encoder = enc
        appState.encoder = enc
        appState.gui.settingsState.encoder = enc
        PortLogger.setup(encoder: enc)

        // Capture for the background-thread disconnect callback.
        let disconnectEncoder = enc

        // Create new reader for the new pipe.
        let reader = ProtocolReader(
            input: readHandle,
            handler: { [weak self] data in
                DispatchQueue.main.async {
                    self?.handleProtocolData(data)
                }
            },
            onDisconnect: { [weak self] in
                disconnectEncoder.disconnect()

                DispatchQueue.main.async {
                    if self?.beamManager == nil {
                        NSApp.terminate(nil)
                    }
                }
            }
        )
        reader.start()
        self.protocolReader = reader

        // Update the editor view's encoder reference so keystrokes
        // go to the new BEAM process, not the dead pipe.
        editorNSView?.encoder = enc

        // Re-send ready event so the new BEAM knows our dimensions.
        if let nsView = editorNSView {
            let gutterPad: CGFloat = nsView.dispatcher.frameState.gutterCol > 0 ? CoreTextMetalRenderer.gutterPixelPaddingPt : 0
            let cols = UInt16(max((nsView.bounds.width - gutterPad) / CGFloat(nsView.cellWidth), 1))
            let rows = UInt16(nsView.bounds.height / CGFloat(nsView.cellHeight))
            enc.sendReady(cols: cols, rows: rows)
        }

        sendCurrentPowerThermalState(reason: "Power state after BEAM reconnect")

        PortLogger.info("Protocol reconnected after BEAM restart")
    }

    // MARK: - Font change

    private func currentBackingScaleFactor() -> CGFloat {
        editorNSView?.window?.screen?.backingScaleFactor ??
            editorNSView?.window?.backingScaleFactor ??
            NSScreen.main?.backingScaleFactor ??
            2.0
    }

    private func handleFontChange(family: String, size: CGFloat, ligatures: Bool, weight: UInt8) {
        rebuildFont(family: family, size: size, scale: currentBackingScaleFactor(), ligatures: ligatures, weight: weight, reason: "Font changed")
    }

    private func handleScaleChange(newScale: CGFloat) {
        guard let currentFace = fontFace else { return }
        guard abs(currentFace.scale - newScale) > 0.001 else { return }

        rebuildFont(
            family: currentFace.requestedName,
            size: CTFontGetSize(currentFace.ctFont),
            scale: newScale,
            ligatures: currentFace.ligaturesEnabled,
            weight: currentFace.protocolWeight,
            reason: "Display scale changed"
        )
    }

    private func rebuildFont(family: String, size: CGFloat, scale: CGFloat, ligatures: Bool, weight: UInt8, reason: String) {
        guard let nsView = editorNSView else { return }

        let newFace = FontFace(name: family, size: size, scale: scale, ligatures: ligatures, weight: weight)
        let fontName = CTFontCopyPostScriptName(newFace.ctFont) as String
        PortLogger.info("\(reason): \(fontName) \(Int(size))pt, scale: \(scale)x, ligatures: \(ligatures), cell: \(newFace.cellWidth)x\(newFace.cellHeight)")

        self.fontFace = newFace

        // Update FontManager and CoreText renderer for the new font.
        fontManager?.setPrimaryFont(name: family, size: size, scale: scale,
                                     ligatures: ligatures, weight: weight)
        if let fm = fontManager {
            nsView.coreTextRenderer.setupRenderers(fontManager: fm)
        }

        nsView.updateFont(newFace)
    }

    // MARK: - Font registration

    /// Registers bundled Nerd Font so SwiftUI views can use it for devicons.
    private func registerBundledFonts() {
        let fontName = "SymbolsNerdFontMono-Regular"
        let ext = "ttf"

        // Look for the font in the app bundle's Resources directory.
        // Bundle.main.resourceURL resolves to Contents/Resources/ for app
        // bundles and the executable's directory for tool targets.
        let searchPaths: [URL] = [
            Bundle.main.resourceURL?.appendingPathComponent("Fonts/\(fontName).\(ext)"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Fonts/\(fontName).\(ext)"),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Resources/Fonts/\(fontName).\(ext)"),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("\(fontName).\(ext)")
        ].compactMap { $0 }

        for url in searchPaths {
            if FileManager.default.fileExists(atPath: url.path) {
                var errorRef: Unmanaged<CFError>?
                if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &errorRef) {
                    NSLog("Registered bundled font: \(fontName)")
                    return
                } else if let error = errorRef?.takeRetainedValue() {
                    // Font might already be registered (e.g., user has it installed)
                    let desc = CFErrorCopyDescription(error) as String
                    if desc.contains("already registered") {
                        return
                    }
                    NSLog("Failed to register font \(fontName): \(desc)")
                }
            }
        }

        // Font not found in bundle; check if it's already available system-wide
        let testFont = NSFont(name: "Symbols Nerd Font Mono", size: 12)
        if testFont != nil {
            return
        }

        NSLog("Warning: Nerd Font not found. Devicons will show as missing glyphs.")
    }

    // MARK: - Protocol handling

    private func handleProtocolData(_ data: Data) {
        guard let dispatcher else { return }
        do {
            try decodeCommands(from: data) { command in
                dispatcher.dispatch(command)
            }
        } catch {
            PortLogger.error("Protocol decode error: \(error)")
        }
    }
}
