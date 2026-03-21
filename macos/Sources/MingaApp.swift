/// Minga macOS GUI frontend.
///
/// A SwiftUI app that speaks the Port protocol on stdin/stdout. The BEAM
/// spawns this process as a child; it reads render commands from stdin,
/// renders with Metal, and writes input events to stdout.
///
/// Architecture:
///   ProtocolReader (background thread) → decodes commands → dispatches to main thread
///   CommandDispatcher (main thread) → updates LineBuffer → triggers CoreTextMetalRenderer
///   EditorNSView (main thread) → keyboard/mouse → ProtocolEncoder → stdout

import SwiftUI
import AppKit

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

/// ContentView observes AppState and switches from a placeholder to the
/// editor surface once the AppDelegate finishes initialization.
struct ContentView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        ZStack {
        HStack(spacing: 0) {
            // File tree sidebar
            if appState.gui.fileTreeState.visible {
                FileTreeView(
                    fileTreeState: appState.gui.fileTreeState,
                    theme: appState.gui.themeColors,
                    encoder: appState.encoder
                )

                // 1px separator between sidebar and editor
                Rectangle()
                    .fill(appState.gui.themeColors.treeSeparatorFg)
                    .frame(width: 1)
            }

            // Right pane: tab bar + breadcrumb + editor + status bar
            VStack(spacing: 0) {
                // Native tab bar
                if !appState.gui.tabBarState.tabs.isEmpty {
                    TabBarView(
                        tabBarState: appState.gui.tabBarState,
                        theme: appState.gui.themeColors,
                        encoder: appState.encoder
                    )
                }

                // Breadcrumb path bar
                BreadcrumbBar(
                    state: appState.gui.breadcrumbState,
                    theme: appState.gui.themeColors,
                    encoder: appState.encoder
                )

                // Editor surface (Metal) with optional agent chat overlay
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
                            isInsertMode: appState.gui.statusBarState.isInsertMode
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
                }

                // Bottom panel (between editor and status bar)
                if appState.gui.bottomPanelState.visible {
                    BottomPanelView(
                        state: appState.gui.bottomPanelState,
                        theme: appState.gui.themeColors,
                        encoder: appState.encoder
                    )
                }

                // Native minibuffer (appears above status bar when active)
                if appState.gui.minibufferState.visible {
                    MinibufferView(
                        state: appState.gui.minibufferState,
                        theme: appState.gui.themeColors
                    )
                    .transition(
                        .move(edge: .bottom)
                        .combined(with: .opacity)
                        .animation(.easeInOut(duration: 0.15))
                    )
                }

                // Status bar
                StatusBarView(
                    state: appState.gui.statusBarState,
                    theme: appState.gui.themeColors,
                    encoder: appState.encoder
                )
            }

        }

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
            theme: appState.gui.themeColors
        )

        // Tool manager overlay (floats over entire window)
        ToolManagerView(
            state: appState.gui.toolManagerState,
            theme: appState.gui.themeColors,
            encoder: appState.encoder
        )
        }
        .navigationTitle(appState.windowTitle)
        .toolbarBackground(appState.windowBgColor ?? Color(red: 0.12, green: 0.12, blue: 0.14), for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbarColorScheme(appState.windowBgIsDark ? .dark : .light, for: .windowToolbar)
        .preferredColorScheme(appState.windowBgIsDark ? .dark : .light)
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
    /// All GUI chrome sub-states in a single container.
    let gui = GUIState()
    /// Protocol encoder for sending gui_action events from SwiftUI chrome.
    var encoder: InputEncoder?
}

/// App delegate that sets up the protocol reader, renderer, and wiring.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    private var protocolReader: ProtocolReader?
    private var encoder: ProtocolEncoder?
    private var dispatcher: CommandDispatcher?
    private var fontFace: FontFace?
    private var fontManager: FontManager?
    private var editorNSView: EditorNSView?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        ctRenderer.setupLineRenderer(fontManager: fm)

        // Protocol encoder (writes to stdout).
        let enc = ProtocolEncoder()
        self.encoder = enc
        appState.encoder = enc

        // Enable port-based logging so messages appear in *Messages*.
        PortLogger.setup(encoder: enc)
        PortLogger.info("macOS GUI frontend starting")
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
        let nsView = EditorNSView(encoder: enc, fontFace: face, lineBuffer: disp.lineBuffer,
                                   coreTextRenderer: ctRenderer, fontManager: fm)
        nsView.guiState = appState.gui
        nsView.statusBarState = appState.gui.statusBarState
        self.editorNSView = nsView
        appState.editorNSView = nsView

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

        // Start reading protocol commands from stdin.
        let reader = ProtocolReader(
            handler: { [weak self] data in
                DispatchQueue.main.async {
                    self?.handleProtocolData(data)
                }
            },
            onDisconnect: {
                // BEAM has exited; shut down gracefully.
                DispatchQueue.main.async {
                    NSApp.terminate(nil)
                }
            }
        )
        reader.start()
        self.protocolReader = reader
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        protocolReader?.stop()
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
            nsView.coreTextRenderer.setupLineRenderer(fontManager: fm)
        }

        nsView.updateFont(newFace)
    }

    // MARK: - Font registration

    /// Registers bundled Nerd Font so SwiftUI views can use it for devicons.
    private func registerBundledFonts() {
        let fontName = "SymbolsNerdFontMono-Regular"
        let ext = "ttf"

        // Look for the font in the app bundle's Resources directory.
        // For a tool target, resources are next to the binary.
        let searchPaths = [
            Bundle.main.bundleURL.appendingPathComponent("Resources/Fonts/\(fontName).\(ext)"),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Resources/Fonts/\(fontName).\(ext)"),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("\(fontName).\(ext)")
        ]

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
