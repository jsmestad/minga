/// Minga macOS GUI frontend.
///
/// A SwiftUI app that speaks the Port protocol on stdin/stdout. The BEAM
/// spawns this process as a child; it reads render commands from stdin,
/// renders with Metal, and writes input events to stdout.
///
/// Architecture:
///   ProtocolReader (background thread) → decodes commands → dispatches to main thread
///   CommandDispatcher (main thread) → updates CellGrid → triggers MetalRenderer
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
        Group {
            if let nsView = appState.editorNSView {
                EditorView(editorNSView: nsView)
            } else {
                Color(red: 0.12, green: 0.12, blue: 0.14)
            }
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
}

/// App delegate that sets up the protocol reader, renderer, and wiring.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    private var protocolReader: ProtocolReader?
    private var encoder: ProtocolEncoder?
    private var dispatcher: CommandDispatcher?
    private var fontFace: FontFace?
    private var editorNSView: EditorNSView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register as a regular GUI app so macOS routes keyboard events to us.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

        // Backing scale factor for Retina rendering.
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0

        // Initialize font.
        let face = FontFace(name: defaultFontName, size: defaultFontSize, scale: scale)
        face.preloadAscii()
        self.fontFace = face

        // Initial grid dimensions.
        let cols = UInt16(defaultWindowWidth / CGFloat(face.cellWidth))
        let rows = UInt16(defaultWindowHeight / CGFloat(face.cellHeight))
        let grid = CellGrid(cols: cols, rows: rows)

        // Metal renderer.
        guard let metalRenderer = MetalRenderer() else {
            // PortLogger isn't set up yet, fall back to NSLog.
            NSLog("Failed to initialize Metal renderer")
            NSApp.terminate(nil)
            return
        }

        // Protocol encoder (writes to stdout).
        let enc = ProtocolEncoder()
        self.encoder = enc

        // Enable port-based logging so messages appear in *Messages*.
        PortLogger.setup(encoder: enc)
        PortLogger.info("macOS GUI frontend starting")
        PortLogger.info("Font: \(defaultFontName) \(Int(defaultFontSize))pt, cell: \(face.cellWidth)x\(face.cellHeight), scale: \(scale)x")
        PortLogger.info("Initial grid: \(cols)x\(rows) cells")

        // Create the editor view.
        let nsView = EditorNSView(encoder: enc, metalRenderer: metalRenderer, fontFace: face, cellGrid: grid)
        self.editorNSView = nsView
        appState.editorNSView = nsView

        // Command dispatcher.
        let disp = CommandDispatcher(grid: grid)
        disp.onFrameReady = { [weak nsView] in
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
                appState.windowBgColor = Color(red: r, green: g, blue: b)
                let isDark = (r * 0.299 + g * 0.587 + b * 0.114) < 0.5
                appState.windowBgIsDark = isDark
                // Also set the NSWindow appearance directly. SwiftUI's
                // toolbarColorScheme doesn't always update the title text
                // color reliably, but NSAppearance does.
                for window in NSApp.windows {
                    window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
                }
            }
        }
        disp.fontFace = face
        disp.onFontChanged = { [weak self] family, size, ligatures in
            self?.handleFontChange(family: family, size: CGFloat(size), ligatures: ligatures)
        }
        self.dispatcher = disp

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

    private func handleFontChange(family: String, size: CGFloat, ligatures: Bool) {
        guard let nsView = editorNSView, let dispatcher else { return }

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let newFace = FontFace(name: family, size: size, scale: scale, ligatures: ligatures)
        newFace.preloadAscii()

        let fontName = CTFontCopyPostScriptName(newFace.ctFont) as String
        PortLogger.info("Font changed: \(fontName) \(Int(size))pt, ligatures: \(ligatures), cell: \(newFace.cellWidth)x\(newFace.cellHeight)")

        self.fontFace = newFace
        dispatcher.fontFace = newFace
        nsView.updateFont(newFace)
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
