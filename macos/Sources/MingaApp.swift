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

            Button("Find…") { encoder?.sendSearchQuery(query: "", flags: 0) }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!connected)

            Button("Find and Replace…") { encoder?.sendSearchQuery(query: "", flags: 0x01) }
                .keyboardShortcut("h", modifiers: .command)
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

            Divider()

            Button("Increase Font Size") { encoder?.sendFontSizeAdjust(direction: 0x01) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!connected)
            Button("Decrease Font Size") { encoder?.sendFontSizeAdjust(direction: 0x00) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!connected)
            Button("Reset Font Size") { encoder?.sendFontSizeAdjust(direction: 0x02) }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(!connected)
        }
    }

    /// Reads the system pasteboard and sends a paste event to the BEAM.
    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        encoder?.sendPasteEvent(text: text)
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
