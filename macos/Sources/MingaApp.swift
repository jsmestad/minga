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
import os

/// Default font settings.
private let defaultFontName = "Menlo"
private let defaultFontSize: CGFloat = 13.0

/// Default window dimensions in pixels.
private let defaultWindowWidth: CGFloat = 800
private let defaultWindowHeight: CGFloat = 600

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
        .windowStyle(.titleBar)
        // Remove default menu keyboard shortcuts that would intercept
        // keys before our NSView sees them.
        .commands {
            CommandGroup(replacing: .textEditing) {}
        }
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
    @ObservedObject var appState: AppState
    @State private var rightPaneHeight: CGFloat = 600
    @State private var sidebarWidth: CGFloat = 240

    private var showSidebar: Bool {
        appState.gui.fileTreeState.visible || appState.gui.gitStatusState.visible
    }

    private var theme: ThemeColors { appState.gui.themeColors }

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
        .toolbarBackground(appState.windowBgColor ?? Color(red: 0.12, green: 0.12, blue: 0.14), for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbarColorScheme(appState.windowBgIsDark ? .dark : .light, for: .windowToolbar)
        .preferredColorScheme(appState.windowBgIsDark ? .dark : .light)
        .onAppear {
            sidebarWidth = CGFloat(appState.gui.fileTreeState.treeWidth) * 7.5
        }
    }

    // MARK: - Unified Toolbar

    /// Single toolbar row spanning the full window width. Contains the
    /// sidebar header (when visible) and the tab bar, sharing one background.
    @ViewBuilder
    private var unifiedToolbar: some View {
        HStack(spacing: 0) {
            if showSidebar {
                sidebarHeaderContent
                    .frame(width: sidebarWidth + 8) // +8 aligns with resize handle

                // Thin vertical separator between sidebar header and tab bar
                Rectangle()
                    .fill(theme.tabSeparatorFg.opacity(0.4))
                    .frame(width: 1, height: 16)
            }

            if !appState.gui.tabBarState.tabs.isEmpty {
                TabBarView(
                    tabBarState: appState.gui.tabBarState,
                    theme: theme,
                    encoder: appState.encoder
                )
            } else {
                Spacer()
            }
        }
        .frame(height: 34)
        .background(theme.tabBg)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.tabSeparatorFg.opacity(0.3))
                .frame(height: 1)
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
                encoder: appState.encoder
            )
        } else if appState.gui.gitStatusState.visible {
            GitStatusHeaderContent(
                state: appState.gui.gitStatusState,
                theme: theme
            )
        }
    }

    // MARK: - Sidebar Body

    @ViewBuilder
    private var sidebarBody: some View {
        if showSidebar {
            SidebarContainer(
                fileTreeState: appState.gui.fileTreeState,
                gitStatusState: appState.gui.gitStatusState,
                theme: theme,
                encoder: appState.encoder,
                sidebarWidth: $sidebarWidth
            )
        }
    }

    // MARK: - Editor Body

    private var editorBody: some View {
        VStack(spacing: 0) {

            // Breadcrumb path bar
            BreadcrumbBar(
                state: appState.gui.breadcrumbState,
                theme: appState.gui.themeColors,
                encoder: appState.encoder
            )

            // Editor surface (always present for keyboard input handling).
            // Hidden behind BoardView when the Board is active, same
            // pattern as the agent chat overlay.
            editorSurface
                .opacity(appState.gui.boardState.visible ? 0 : 1)

            // Board overlay (shown on top when active)
            if appState.gui.boardState.visible {
                BoardView(
                    state: appState.gui.boardState,
                    theme: appState.gui.themeColors,
                    encoder: appState.encoder
                )
                .transition(
                    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                        ? .opacity.animation(.easeInOut(duration: 0.15))
                        : .scale(scale: 0.95)
                            .combined(with: .opacity)
                            .animation(.easeOut(duration: 0.25))
                )
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

    private var editorSurface: some View {
        ZStack(alignment: .topLeading) {
            // Metal editor surface (always present for input handling)
            Group {
                if let nsView = appState.editorNSView {
                    EditorView(editorNSView: nsView)
                } else {
                    Color(red: 0.12, green: 0.12, blue: 0.14)
                }
            }
            // Show the agent view on top when visible. Keeping the
            // metal view underneath means EditorNSView stays in the
            // responder chain for keyboard input.
            .opacity(appState.gui.agentChatState.visible ? 0 : 1)
            .onChange(of: appState.gui.agentChatState.visible) { _, visible in
                appState.editorNSView?.setAgentChatVisible(visible)
            }

            if appState.gui.agentChatState.visible {
                AgentChatView(
                    state: appState.gui.agentChatState,
                    theme: appState.gui.themeColors,
                    isInsertMode: appState.gui.statusBarState.isInsertMode,
                    encoder: appState.encoder
                )
            }

            // Completion overlay (positioned at cursor)
            if appState.gui.completionState.visible {
                let cw = CGFloat(appState.editorNSView?.cellWidth ?? 8)
                let ch = CGFloat(appState.editorNSView?.cellHeight ?? 16)
                let x = CGFloat(appState.gui.completionState.anchorCol) * cw
                let y = (CGFloat(appState.gui.completionState.anchorRow) + 1) * ch

                CompletionOverlay(
                    state: appState.gui.completionState,
                    theme: appState.gui.themeColors,
                    encoder: appState.encoder,
                    cellWidth: cw,
                    cellHeight: ch
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
                    viewportWidth: overlayVPW
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
            isAgentChatVisible: appState.gui.agentChatState.visible
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

        // Startup overlay: covers the empty Metal framebuffer with a
        // spinner while the BEAM boots. Fades out on first batch_end.
        if !appState.hasReceivedFirstFrame {
            StartupOverlay()
                .transition(.opacity)
        }
    }
}

/// Observable state shared between the app delegate and views.
@MainActor
final class AppState: ObservableObject {
    @Published var windowTitle: String = "Minga"
    @Published var editorNSView: EditorNSView?
    /// Theme background color for the title bar, sent by the BEAM via set_window_bg.
    @Published var windowBgColor: Color?
    /// Whether the theme is dark (luminance < 0.5). Drives toolbarColorScheme.
    @Published var windowBgIsDark: Bool = true
    /// Flipped once when the first complete frame (batch_end) arrives from
    /// the BEAM. The startup overlay fades out when this becomes true.
    @Published var hasReceivedFirstFrame: Bool = false
    /// All GUI chrome sub-states in a single container.
    let gui = GUIState()
    /// Protocol encoder for sending gui_action events from SwiftUI chrome.
    var encoder: InputEncoder?
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
    private var fontFace: FontFace?
    private var fontManager: FontManager?
    private var editorNSView: EditorNSView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        os_signpost(.begin, log: startupLog, name: "AppStartup")

        // Register the bundled Nerd Font for devicon rendering.
        registerBundledFonts()

        // Register as a regular GUI app so macOS routes keyboard events to us.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

        // Backing scale factor for Retina rendering.
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0

        // Initialize font.
        let face = FontFace(name: defaultFontName, size: defaultFontSize, scale: scale)
        self.fontFace = face

        // Font manager for CoreText rendering.
        let fm = FontManager(name: defaultFontName, size: defaultFontSize, scale: scale)
        self.fontManager = fm

        // Initial grid dimensions.
        let cols = UInt16(defaultWindowWidth / CGFloat(face.cellWidth))
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

        // Create the editor view.
        let nsView = EditorNSView(encoder: enc, fontFace: face, dispatcher: disp,
                                   coreTextRenderer: ctRenderer, fontManager: fm)
        nsView.guiState = appState.gui
        nsView.statusBarState = appState.gui.statusBarState
        self.editorNSView = nsView
        appState.editorNSView = nsView
        os_signpost(.event, log: startupLog, name: "EditorViewCreated")

        disp.onFrameReady = { [weak nsView] in
            nsView?.renderFrame()
        }
        disp.onModeChanged = { [weak nsView] modeName in
            guard let nsView else { return }
            NSAccessibility.post(
                element: nsView,
                notification: .announcementRequested,
                userInfo: [.announcement: "\(modeName) mode"]
            )
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
                appState.windowBgColor = Color(red: r, green: g, blue: b)
                let isDark = (r * 0.299 + g * 0.587 + b * 0.114) < 0.5
                appState.windowBgIsDark = isDark
                for window in NSApp.windows {
                    window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
                }
            }
        }

        // The ready event is deferred: EditorNSView.setFrameSize sends it
        // once SwiftUI assigns the real frame dimensions. This avoids
        // the BEAM rendering at hardcoded 800x600 defaults.

        // Start reading protocol commands.
        let reader = ProtocolReader(
            input: protocolInput,
            handler: { [weak self] data in
                DispatchQueue.main.async {
                    self?.handleProtocolData(data)
                }
            },
            onDisconnect: { [weak self] in
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
        PortLogger.setup(encoder: enc)

        // Create new reader for the new pipe.
        let reader = ProtocolReader(
            input: readHandle,
            handler: { [weak self] data in
                DispatchQueue.main.async {
                    self?.handleProtocolData(data)
                }
            },
            onDisconnect: { [weak self] in
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
            let cols = UInt16(nsView.bounds.width / CGFloat(nsView.cellWidth))
            let rows = UInt16(nsView.bounds.height / CGFloat(nsView.cellHeight))
            enc.sendReady(cols: cols, rows: rows)
        }

        PortLogger.info("Protocol reconnected after BEAM restart")
    }

    // MARK: - Font change

    private func handleFontChange(family: String, size: CGFloat, ligatures: Bool, weight: UInt8) {
        guard let nsView = editorNSView else { return }

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let newFace = FontFace(name: family, size: size, scale: scale, ligatures: ligatures, weight: weight)

        let fontName = CTFontCopyPostScriptName(newFace.ctFont) as String
        PortLogger.info("Font changed: \(fontName) \(Int(size))pt, ligatures: \(ligatures), cell: \(newFace.cellWidth)x\(newFace.cellHeight)")

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
