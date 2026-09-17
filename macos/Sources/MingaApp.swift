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

import MingaProtocol
import MingaUI
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

/// Stable identity for the one editor scene owned by a frontend process.
///
/// Minga cannot use `WindowGroup` until the renderer, encoder, GUI state, `EditorNSView`, and BEAM session are all owned per scene. Sharing any of those application-singleton resources across editor windows is unsupported.
private enum EditorScene {
    static let id = "editor"
    static let windowIdentifier = NSUserInterfaceItemIdentifier("MingaEditorWindow")
}

@main
struct MingaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("Minga", id: EditorScene.id) {
            ContentView(
                gui: appDelegate.appState.gui,
                encoder: { [appState = appDelegate.appState] in appState.encoder },
                editorGeometry: { [appState = appDelegate.appState] in
                    EditorGeometry(editorNSView: appState.editorNSView)
                },
                chrome: WindowChrome(appState: appDelegate.appState),
                onAgentChatVisibleChange: { [appState = appDelegate.appState] visible in
                    appState.editorNSView?.setAgentChatVisible(visible)
                },
                makeEditorSurface: { [appState = appDelegate.appState] in
                    if let nsView = appState.editorNSView {
                        EditorView(editorNSView: nsView)
                    } else {
                        Color(red: 0.12, green: 0.12, blue: 0.14)
                    }
                }
            )
                .frame(minWidth: 160, minHeight: 80)
                // Disable SwiftUI's focus system so it doesn't steal
                // first responder from the EditorNSView.
                .focusable(false)
                .focusEffectDisabled()
                .background(EditorWindowIdentifierSetter())
                .overlay(
                    SingletonEditorWindowProbe {
                        appDelegate.finishSingletonEditorWindowProbe()
                    }
                )
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: defaultWindowWidth, height: defaultWindowHeight)
        .commands {
            MingaMenuCommands(appState: appDelegate.appState)
        }

        Settings {
            SettingsView(state: appDelegate.appState.gui.settingsState, sendAction: { action in appDelegate.appState.encoder?.send(action) })
        }
    }
}

/// Identifies the editor window for lifecycle checks without changing its scene identity.
private struct EditorWindowIdentifierSetter: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        identifyWindow(containing: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        identifyWindow(containing: nsView)
    }

    private func identifyWindow(containing view: NSView) {
        DispatchQueue.main.async {
            view.window?.identifier = EditorScene.windowIdentifier
        }
    }
}

private struct SingletonEditorWindowProbeSnapshot: Codable {
    let editorWindowCount: Int
    let reusedExistingWindow: Bool
    let editorWindowIsVisible: Bool
}

/// Deterministic launch probe for the singleton editor scene contract.
private struct SingletonEditorWindowProbe: View {
    static let outputPathEnvironmentKey = "MINGA_SINGLETON_EDITOR_WINDOW_PROBE_PATH"
    @MainActor private static var hasStarted = false

    @Environment(\.openWindow) private var openWindow

    let onComplete: @MainActor () -> Void

    static var isRequested: Bool {
        outputPath != nil
    }

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .task {
                await runIfRequested()
            }
    }

    @MainActor
    private func runIfRequested() async {
        guard let outputPath = Self.outputPath else { return }
        guard !Self.hasStarted else { return }
        Self.hasStarted = true
        guard let originalWindow = await waitForEditorWindow(visible: true) else {
            write(
                SingletonEditorWindowProbeSnapshot(
                    editorWindowCount: editorWindows.count,
                    reusedExistingWindow: false,
                    editorWindowIsVisible: false
                ),
                to: outputPath
            )
            onComplete()
            return
        }

        openWindow(id: EditorScene.id)
        openWindow(id: EditorScene.id)
        try? await Task.sleep(for: .milliseconds(100))

        let reopenedWindow = editorWindows.first(where: \.isVisible)
        write(
            SingletonEditorWindowProbeSnapshot(
                editorWindowCount: editorWindows.count,
                reusedExistingWindow: reopenedWindow === originalWindow,
                editorWindowIsVisible: reopenedWindow?.isVisible == true
            ),
            to: outputPath
        )
        onComplete()
    }

    @MainActor
    private var editorWindows: [NSWindow] {
        NSApp.windows.filter { $0.identifier == EditorScene.windowIdentifier }
    }

    @MainActor
    private func waitForEditorWindow(visible: Bool) async -> NSWindow? {
        for _ in 0..<100 {
            if let window = editorWindows.first(where: { $0.isVisible == visible }) {
                return window
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    private func write(_ snapshot: SingletonEditorWindowProbeSnapshot, to path: String) {
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            NSLog("Singleton editor window probe failed: %@", String(describing: error))
        }
    }

    private static var outputPath: String? {
#if DEBUG
        ProcessInfo.processInfo.environment[outputPathEnvironmentKey]
#else
        nil
#endif
    }
}

/// Native menu bar for Minga.
///
/// Items that map to editor commands send the appropriate event to the
/// BEAM via the protocol encoder. Items that are purely macOS-native
/// (Minimize, Zoom, Full Screen, Quit) use standard AppKit behavior.
struct MingaMenuCommands: Commands {
    let appState: AppState

    private var encoder: OutboundActionEncoding? { appState.encoder }
    private var connected: Bool { encoder != nil }
    private var latencyHUDState: LatencyHUDState { appState.gui.latencyHUDState }

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                routeTextEditingCommand(.undo) { $0.send(.executeCommand(name: "undo")) }
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!textEditingCommandIsAvailable(.undo))
            Button("Redo") {
                routeTextEditingCommand(.redo) { $0.send(.executeCommand(name: "redo")) }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!textEditingCommandIsAvailable(.redo))
        }

        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { routeTextEditingCommand(.cut) { $0.send(.commandCut) } }
                .keyboardShortcut("x", modifiers: .command)
                .disabled(!textEditingCommandIsAvailable(.cut))
            Button("Copy") { routeTextEditingCommand(.copy) { $0.send(.commandCopy) } }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(!textEditingCommandIsAvailable(.copy))
            Button("Paste") { routeTextEditingCommand(.paste) { pasteFromClipboard(using: $0) } }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(!textEditingCommandIsAvailable(.paste))
        }

        CommandGroup(replacing: .textEditing) {
            Button("Select All") {
                routeTextEditingCommand(.selectAll) { $0.send(.executeCommand(name: "select_all")) }
            }
            .keyboardShortcut("a", modifiers: .command)
            .disabled(!textEditingCommandIsAvailable(.selectAll))
        }

        CommandGroup(after: .textEditing) {
            Button("Find…") { encoder?.send(.searchFocus(replaceMode: false)) }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!connected)

            Button("Find and Replace…") { encoder?.send(.searchFocus(replaceMode: true)) }
                .keyboardShortcut("h", modifiers: .command)
                .disabled(!connected)
        }

        // File menu: New, Open, Save, Close Tab.
        // SwiftUI provides the default "New Window" item; we replace it with
        // "New Buffer" which opens an empty scratch buffer in the BEAM.
        CommandGroup(replacing: .newItem) {
            Button("New Buffer") { encoder?.send(.executeCommand(name: "new_buffer")) }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!connected)
        }

        CommandGroup(after: .newItem) {
            Button("Open…") { encoder?.send(.executeCommand(name: "open_file_dialog")) }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(!connected)

            Divider()

            Button("Save") { encoder?.send(.executeCommand(name: "save")) }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!connected)

            Button("Save As…") { encoder?.send(.executeCommand(name: "save_as_dialog")) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!connected)

            Divider()

            Button("Close Tab") { encoder?.send(.executeCommand(name: "quit")) }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(!connected)
        }

        // View menu
        CommandMenu("View") {
            Button("Toggle File Tree") { encoder?.send(.togglePanel(panel: 0)) }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(!connected)

            Divider()

            Button("Increase Font Size") { encoder?.send(.fontSizeAdjust(direction: 0x01)) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!connected)
            Button("Decrease Font Size") { encoder?.send(.fontSizeAdjust(direction: 0x00)) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!connected)
            Button("Reset Font Size") { encoder?.send(.fontSizeAdjust(direction: 0x02)) }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(!connected)

            Divider()

            // Keystroke-to-present latency HUD (ticket #2215). This is a
            // frontend-local debug surface, so the toggle does not route through
            // the BEAM and stays enabled even before connection. cmd-ctrl-l is the
            // macOS-conventional equivalent of the Go TUI's ctrl+alt+l chord.
            Button(latencyHUDState.visible ? "Hide Latency HUD" : "Show Latency HUD") {
                latencyHUDState.toggle()
            }
            .keyboardShortcut("l", modifiers: [.command, .control])
        }
    }

    private func routeTextEditingCommand(_ command: NativeTextCommandRouter.Command, fallback: (OutboundActionEncoding) -> Void) {
        NativeMenuTextRouter.perform(command, encoder: encoder, fallback: fallback)
    }

    private func textEditingCommandIsAvailable(_ command: NativeTextCommandRouter.Command) -> Bool {
        NativeMenuTextRouter.isAvailable(command, encoder: encoder)
    }

    /// Reads the system pasteboard and sends a paste event to the BEAM.
    private func pasteFromClipboard(using encoder: OutboundActionEncoding) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        encoder.send(.paste(text))
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
    let appState: AppState

    private var beamManager: BEAMProcessManager?
    private var protocolConnection: ProtocolConnection?
    private var encoder: ProtocolEncoder? { protocolConnection?.encoder }
    private var dispatcher: CommandDispatcher?
    private var applicationQuitCoordinator: ApplicationQuitCoordinator?
    private var applicationQuitAlert: NSAlert?
    private var activeFilePanel: NSSavePanel?
    private var inputRejectionAlert: NSAlert?
    private var coreConnectionIsLive = true
    private var recoveryManager: RecoveryManager?
    private var fontManager: FontManager?
    private var editorNSView: EditorNSView?
    private var workspaceNotificationTasks: [Task<Void, Never>] = []
    private var outboundConnectionState = OutboundConnectionState()
    private var pendingFileURLs: [URL] = []
    private var acceptsOpenRequests = false
    private let frameResourcePolicy = FrameResourcePolicy.default

    override init() {
        let appState = AppState()
#if DEBUG
        if ProcessInfo.processInfo.environment[MenuSnapshotProbe.connectedEnvironmentKey] == "1" {
            appState.encoder = ClosureOutboundActionEncoder { _ in .rejected(.disconnected) }
        }
#endif
        self.appState = appState
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
#if DEBUG
        if runMenuSnapshotProbeIfRequested() {
            return
        }
        if SingletonEditorWindowProbe.isRequested {
            coreConnectionIsLive = false
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            return
        }
#endif

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

        // Font manager owns the primary and all registered font faces.
        let fm = FontManager(name: defaultFontName, size: defaultFontSize, scale: scale)
        self.fontManager = fm

        // Initial grid dimensions (no gutter padding subtraction yet; the first
        // setFrameSize call will send corrected cols once the gutter is established).
        let cols = UInt16(max(defaultWindowWidth / CGFloat(fm.cellWidth), 1))
        let rows = UInt16(defaultWindowHeight / CGFloat(fm.cellHeight))

        // CoreText renderer.
        guard let ctRenderer = CoreTextMetalRenderer(
            resourcePolicy: frameResourcePolicy.nativeRenderer
        ) else {
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

            manager.onCrash = { [weak self] in
                let disposition = self?.applicationQuitCoordinator?.coreDidExit()
                // The editor core died and automatic restart gave up. Present the
                // recovery surface instead of terminating, and keep the app
                // responsive (clickable/quittable) while the user decides (#2698).
                if disposition != .approvedTermination {
                    self?.presentEditorCoreStoppedRecovery()
                }
            }
            manager.onNormalExit = { [weak self] in
                let disposition = self?.applicationQuitCoordinator?.coreDidExit() ?? .noPendingQuit
                if disposition == .noPendingQuit {
                    NSApp.terminate(nil)
                }
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

        let recovery = RecoveryManager { [weak self] in
            if let manager = self?.beamManager {
                manager.sendRecoveryRestartSignal()
            } else {
                let parentPid = getppid()
                if parentPid > 1 { kill(parentPid, SIGUSR2) }
            }
        }
        self.recoveryManager = recovery

        let connectionID = outboundConnectionState.issueID()
        guard let connection = replaceProtocolConnection(
            connectionID: connectionID,
            readHandle: protocolInput,
            writeHandle: protocolOutput,
            canRestart: false
        ) else { return }
        let enc = connection.encoder

        // Enable port-based logging so messages appear in *Messages*.
        PortLogger.info("macOS GUI frontend starting (\(beamManager != nil ? "bundle" : "dev") mode)")
        PortLogger.info("Font: \(defaultFontName) \(Int(defaultFontSize))pt, cell: \(fm.cellWidth)x\(fm.cellHeight), scale: \(scale)x")
        PortLogger.info("Initial grid: \(cols)x\(rows) cells")

        // Command dispatcher.
        let disp = CommandDispatcher(
            cols: cols, rows: rows, guiState: appState.gui,
            resourcePolicy: frameResourcePolicy,
            applicationEffectSink: { [weak self] effect in
                self?.handleApplicationCommitEffect(effect)
            }
        )
        disp.fontManager = fm
        disp.replaceConnection(with: connectionID)
        disp.onOperationNativeResult = { [weak self] result in
            self?.encoder?.send(.operationNativeResult(result))
        }
        disp.onNativePresentationObservation = { [weak self] evidence in
            self?.encoder?.send(.nativePresentationObservation(evidence))
        }
        disp.requestPresentationFocus = { [weak self] in
            self?.editorNSView?.focusPolicy.requestPresentationFocus() == true
        }
        self.dispatcher = disp

        let quitCoordinator = ApplicationQuitCoordinator(
            sendRequest: { [weak self] requestID in
                self?.encoder?.send(.applicationQuitRequest(requestID: requestID)).wasAccepted ?? false
            },
            sendDecision: { [weak self] requestID, decision in
                self?.encoder?.send(.applicationQuitDecision(requestID: requestID, decision: decision.rawValue)).wasAccepted ?? false
            },
            presentDecision: { [weak self] dirtyCount, completion in
                self?.presentApplicationQuitDecision(dirtyCount: dirtyCount, completion: completion)
            },
            dismissDecision: { [weak self] in
                self?.dismissApplicationQuitDecision()
            },
            replyToAppKit: { approved in
                NSApp.reply(toApplicationShouldTerminate: approved)
            },
            presentFailure: { [weak self] message in
                self?.presentApplicationQuitFailure(message)
            },
            restoreFocus: { [weak self] in
                self?.editorNSView?.focusPolicy.restoreAfterNativeModal()
            }
        )
        self.applicationQuitCoordinator = quitCoordinator
        disp.onApplicationQuitResponse = { [weak quitCoordinator] response in
            quitCoordinator?.receive(response)
        }
        disp.onFileDialogRequest = { [weak self] request in
            self?.presentFileDialog(request)
        }

        // Wire the latency HUD (ticket #2215) to the recorder. The snapshot is
        // computed outside the stamp/resolve critical sections, so the HUD's
        // refresh timer never perturbs the keystroke-to-present samples.
        appState.gui.latencyHUDState.connect { [weak disp] in
            disp?.latency.snapshot() ?? LatencyRecorder.Stats()
        }

        // Create the editor view.
        let nsView = EditorNSView(encoder: enc, dispatcher: disp,
                                   coreTextRenderer: ctRenderer, fontManager: fm)
        nsView.editorInput = appState.gui.editorInput
        ctRenderer.presentationMetrics = appState.gui.presentationMetrics
        nsView.statusBarState = appState.gui.statusBarState
        appState.gui.settingsState.sendAction = { action in enc.send(action) }
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

        disp.onFramePresented = { [weak recovery] in
            recovery?.onRenderReceived()
        }
        // #2739 status is emitted at semantic publication/rejection, never from
        // the old replay loop and never delayed until Metal presentation.
        disp.onTransactionResult = { [weak self] result in
            guard let encoder = self?.encoder else { return }
            switch result {
            case .applied(let generation, let frameSeq):
                encoder.send(.frameApplied(generation: generation, frameSequence: frameSeq))
            case .rejected(let generation, let frameSeq, let lastApplied, let reason):
                encoder.send(.frameRejected(
                    generation: generation,
                    frameSequence: frameSeq,
                    lastAppliedFrameSequence: lastApplied,
                    reason: reason.wireCode,
                    disposition: reason.disposition.rawValue
                ))
            case .windowRefMiss(let generation, let frameSeq, let lastApplied, let windowId):
                encoder.send(.windowReferenceMiss(
                    generation: generation,
                    frameSequence: frameSeq,
                    lastAppliedFrameSequence: lastApplied,
                    windowID: windowId
                ))
            }
        }
        disp.onFrameReady = { [weak nsView] in
            nsView?.renderFrame()
        }
        // The ready event is deferred: EditorNSView.setFrameSize sends it
        // once SwiftUI assigns the real frame dimensions. This avoids
        // the BEAM rendering at hardcoded 800x600 defaults.

        // Start the already-installed connection only after every application consumer is ready to receive its ordered events.
        connection.start()
        coreConnectionIsLive = true

        // First frame callback: dismiss the startup overlay and flush Finder,
        // `open -a`, and CLI wait requests buffered until the BEAM can accept
        // semantic GUI actions.
        disp.onFirstRender = { [weak self] in
            guard let self else { return }

            os_signpost(.end, log: startupLog, name: "AppStartup")

            let duration: Double = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.25
            withAnimation(.easeOut(duration: duration)) {
                self.appState.hasReceivedFirstFrame = true
            }

            self.acceptsOpenRequests = true
            self.flushPendingOpenRequests()
        }
    }

    /// Delivers every application-owned prepared effect to its existing resource owner.
    private func handleApplicationCommitEffect(_ effect: ApplicationCommitEffect) {
        switch effect {
        case .fontChanged(let family, let size, let ligatures, let weight):
            handleFontChange(family: family, size: CGFloat(size), ligatures: ligatures, weight: weight)
        case .scrollPresentationReset(let windowID):
            editorNSView?.resetScrollPresentation(windowId: windowID)
        case .titleChanged(let title):
            appState.windowTitle = title
        case .windowBackgroundChanged(let red, let green, let blue):
            let r = CGFloat(red) / 255.0
            let g = CGFloat(green) / 255.0
            let b = CGFloat(blue) / 255.0
            let isDark = (r * 0.299 + g * 0.587 + b * 0.114) < 0.5
            appState.windowBgIsDark = isDark
            let bgColor = NSColor(red: r, green: g, blue: b, alpha: 1)
            for window in NSApp.windows where window.identifier?.rawValue != "MingaSettingsWindow" {
                window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
                window.backgroundColor = bgColor
            }
        case .linkCursorChanged(let active):
            editorNSView?.setLinkCursorActive(active)
        case .lineSpacingChanged(let spacing):
            editorNSView?.lineSpacingChanged(spacing)
        case .cursorAnimationChanged(let enabled):
            editorNSView?.coreTextRenderer.setCursorAnimateConfigEnabled(enabled)
            editorNSView?.renderFrame()
        case .accessibilityModeChanged(let modeName):
            guard let editorNSView else { return }
            editorNSView.statusBarModeDidChange()
            NSAccessibility.post(
                element: editorNSView,
                notification: .announcementRequested,
                userInfo: [.announcement: "\(modeName) mode"]
            )
        case .agentChatVisibilityChanged(let visible):
            editorNSView?.setAgentChatVisible(visible)
        }
    }

    func finishSingletonEditorWindowProbe() {
        coreConnectionIsLive = false
        NSApp.terminate(nil)
    }

#if DEBUG
    private func runMenuSnapshotProbeIfRequested() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard let outputPath = environment[MenuSnapshotProbe.outputPathEnvironmentKey] else { return false }
        Task { @MainActor in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
            let editorResponder = NSView(frame: window.contentLayoutRect)
            window.contentView = editorResponder
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(100))
            do {
                try MenuSnapshotProbe.writeMainMenu(to: outputPath)
                window.orderOut(nil)
                coreConnectionIsLive = false
                NSApp.terminate(nil)
            } catch {
                NSLog("Minga menu snapshot probe failed: %@", String(describing: error))
                window.orderOut(nil)
                coreConnectionIsLive = false
                NSApp.terminate(nil)
            }
        }
        return true
    }
#endif

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let coreIsLive = coreConnectionIsLive
            && (beamManager.map { !$0.isShuttingDown && $0.hasLiveProcess } ?? true)
        return ApplicationTerminationPolicy.reply(
            coreIsLive: coreIsLive,
            coordinator: applicationQuitCoordinator
        )
    }

    private func presentApplicationQuitDecision(
        dirtyCount: UInt16,
        completion: @escaping (ApplicationQuitDecision) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = dirtyCount == 1
            ? "Save changes before quitting Minga?"
            : "Save changes in \(dirtyCount) buffers before quitting Minga?"
        alert.informativeText = "The editor core will save every modified buffer before Minga quits."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        let cancelButton = alert.addButton(withTitle: "Cancel")
        cancelButton.keyEquivalent = "\u{1b}"
        applicationQuitAlert = alert

        let resolve: (NSApplication.ModalResponse) -> Void = { [weak self, weak alert] response in
            if let self, let alert, self.applicationQuitAlert === alert {
                self.applicationQuitAlert = nil
            }
            switch response {
            case .alertFirstButtonReturn: completion(.save)
            case .alertSecondButtonReturn: completion(.discard)
            default: completion(.cancel)
            }
        }

        if let window = editorNSView?.window {
            alert.beginSheetModal(for: window, completionHandler: resolve)
        } else {
            resolve(alert.runModal())
        }
    }

    private func dismissApplicationQuitDecision() {
        guard let alert = applicationQuitAlert else { return }
        applicationQuitAlert = nil

        if let sheetParent = alert.window.sheetParent {
            sheetParent.endSheet(alert.window, returnCode: .abort)
        } else {
            NSApp.abortModal()
            alert.window.orderOut(nil)
        }
    }

    private func presentApplicationQuitFailure(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Minga Did Not Quit"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")

        if let window = editorNSView?.window {
            alert.beginSheetModal(for: window) { _ in }
        } else {
            alert.runModal()
        }
    }

    private func presentFileDialog(_ request: NativeFileDialogRequest) {
        guard activeFilePanel == nil else {
            encoder?.send(.fileDialogResult(requestID: request.requestID, outcome: 0, paths: []))
            return
        }
        guard let requestEncoder = encoder else { return }

        let panel: NSSavePanel
        switch request.kind {
        case .open:
            let openPanel = NSOpenPanel()
            openPanel.allowsMultipleSelection = true
            openPanel.canChooseFiles = true
            openPanel.canChooseDirectories = false
            panel = openPanel
        case .saveAs:
            let savePanel = NSSavePanel()
            configureSavePanel(savePanel, suggestedPath: request.suggestedPath)
            panel = savePanel
        }

        activeFilePanel = panel
        editorNSView?.focusPolicy.beginNativeModal()
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            guard let self else { return }
            if let panel, self.activeFilePanel === panel {
                self.activeFilePanel = nil
            }
            self.sendFileDialogResult(
                request,
                response: response,
                panel: panel,
                encoder: requestEncoder
            )
            self.editorNSView?.focusPolicy.endNativeModalAndRestore()
        }

        if let window = editorNSView?.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private func configureSavePanel(_ panel: NSSavePanel, suggestedPath: String) {
        guard !suggestedPath.isEmpty else { return }
        let url = URL(fileURLWithPath: suggestedPath)
        panel.nameFieldStringValue = url.lastPathComponent
        if suggestedPath.hasPrefix("/") {
            panel.directoryURL = url.deletingLastPathComponent()
        }
    }

    private func sendFileDialogResult(
        _ request: NativeFileDialogRequest,
        response: NSApplication.ModalResponse,
        panel: NSSavePanel?,
        encoder: ProtocolEncoder
    ) {
        guard response == .OK, let panel else {
            encoder.send(.fileDialogResult(requestID: request.requestID, outcome: 0, paths: []))
            return
        }

        switch request.kind {
        case .open:
            let paths = (panel as? NSOpenPanel)?.urls.map { $0.standardizedFileURL.path } ?? []
            let outcome: UInt8 = paths.isEmpty ? 0 : 1
            encoder.send(.fileDialogResult(
                requestID: request.requestID,
                outcome: outcome,
                paths: paths
            ))
        case .saveAs:
            guard let path = panel.url?.standardizedFileURL.path else {
                encoder.send(.fileDialogResult(requestID: request.requestID, outcome: 0, paths: []))
                return
            }
            encoder.send(.fileDialogResult(
                requestID: request.requestID,
                outcome: 2,
                paths: [path]
            ))
        }
    }

    /// Presents the recovery surface after the editor core exited and automatic
    /// restart gave up. Scheduled on the next main-actor turn so the termination
    /// handler that triggers it returns immediately and never blocks the main
    /// actor; the alert itself is an interactive, quittable surface (#2698).
    private func presentEditorCoreStoppedRecovery() {
        recoveryManager?.presentEditorCoreStopped { [weak self] in
            self?.beamManager?.restartAfterRecovery()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        cancelWorkspaceLifecycleNotifications()
        protocolConnection?.stop()
        protocolConnection = nil
        beamManager?.beginAppShutdown()
    }

    /// Handles Finder/Open With and `open -a Minga file.ex` file URLs.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.isFileURL {
            let fileURL = url.standardizedFileURL
            if acceptsOpenRequests, let encoder {
                encoder.send(.openFile(path: fileURL.path))
            } else {
                pendingFileURLs.append(fileURL)
            }
        }
    }

    private func flushPendingOpenRequests() {
        guard let encoder else { return }
        let urls = pendingFileURLs
        pendingFileURLs.removeAll()

        for url in urls {
            encoder.send(.openFile(path: url.path))
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
                    self.encoder?.send(.systemWillSleep)
                }
            },
            Task { @MainActor [weak self] in
                for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification) {
                    guard let self else { return }
                    PortLogger.info("System did wake")
                    self.encoder?.send(.systemDidWake)
                }
            },
            Task { @MainActor [weak self] in
                for await notification in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.willUnmountNotification) {
                    guard let self else { return }
                    guard let volumePath = Self.unmountVolumePath(from: notification) else {
                        PortLogger.info("Volume will unmount with no resolvable path; ignoring")
                        continue
                    }
                    PortLogger.info("Volume will unmount: \(volumePath)")
                    self.encoder?.send(.systemWillUnmount(volumePath: volumePath))
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

    /// Resolves the mount path of a volume from a willUnmount/didUnmount notification.
    ///
    /// Modern AppKit delivers the mounted volume URL under `volumeURLUserInfoKey`;
    /// older releases used the `"NSDevicePath"` string. We accept either so the BEAM
    /// always receives a filesystem path it can prefix-match against open buffers.
    private static func unmountVolumePath(from notification: Notification) -> String? {
        if let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
            return url.path
        }
        if let path = notification.userInfo?["NSDevicePath"] as? String {
            return path
        }
        return nil
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
        encoder?.send(.powerThermalState(lowPowerMode: lowPowerMode, thermalState: encodedThermalState))
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
        let connectionID = outboundConnectionState.issueID()
        guard let replacement = replaceProtocolConnection(
            connectionID: connectionID,
            readHandle: readHandle,
            writeHandle: writeHandle,
            canRestart: true
        ) else { return }
        replacement.start()

        recoveryManager?.transportDidReconnect()
        coreConnectionIsLive = true

        // Re-send ready event so the new BEAM knows our dimensions.
        if let nsView = editorNSView {
            let gutterPad: CGFloat = (nsView.dispatcher.committedEditorSnapshot?.gutterCol ?? 0) > 0 ? CoreTextMetalRenderer.gutterPixelPaddingPt : 0
            let cols = UInt16(max((nsView.bounds.width - gutterPad) / CGFloat(nsView.cellWidth), 1))
            let rows = UInt16(nsView.bounds.height / CGFloat(nsView.cellHeight))
            replacement.encoder.send(.ready(cols: cols, rows: rows))
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
        applyFontConfiguration(
            FontManager.Configuration(
                family: family,
                size: size,
                scale: currentBackingScaleFactor(),
                ligatures: ligatures,
                weight: weight
            ),
            reason: "Font changed"
        )
    }

    private func handleScaleChange(newScale: CGFloat) {
        guard let fontManager else { return }
        applyFontConfiguration(
            fontManager.configuration.withScale(newScale),
            reason: "Display scale changed"
        )
    }

    private func applyFontConfiguration(_ configuration: FontManager.Configuration, reason: String) {
        guard let nsView = editorNSView, let fontManager else { return }
        let update = fontManager.setPrimaryFont(configuration)
        guard update.configurationChanged else { return }

        let fontName = CTFontCopyPostScriptName(update.current.ctFont) as String
        PortLogger.info("\(reason): \(fontName) \(Int(configuration.size))pt, scale: \(configuration.scale)x, ligatures: \(configuration.ligatures), cell: \(update.current.cellWidth)x\(update.current.cellHeight)")

        // Rebuild renderer resources before the view requests drawing with new metrics.
        nsView.coreTextRenderer.setupRenderers(fontManager: fontManager)
        nsView.fontConfigurationChanged(metricsChanged: update.metricsChanged)
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

    private func replaceProtocolConnection(
        connectionID: UInt64,
        readHandle: FileHandle,
        writeHandle: FileHandle,
        canRestart: Bool
    ) -> ProtocolConnection? {
        let connection = ProtocolConnection.replacing(
            protocolConnection,
            connectionID: connectionID,
            readHandle: readHandle,
            writeHandle: writeHandle,
            resourcePolicy: frameResourcePolicy,
            invalidate: {
                self.dismissInputRejection()
                self.protocolConnection = nil
                self.outboundConnectionState.install(id: connectionID)
                self.dispatcher?.replaceConnection(with: connectionID)
                self.editorNSView?.invalidateConnection()
                self.appState.encoder = nil
                self.appState.gui.settingsState.sendAction = nil
                self.applicationQuitCoordinator?.replaceConnection()
                self.coreConnectionIsLive = false
                PortLogger.clearEncoder()
            },
            isCurrent: { [weak self] candidate in
                self?.outboundConnectionState.isCurrent(candidate) == true
            },
            consume: { [weak self] event, eventConnectionID in
                guard let self else { return }
                switch event {
                case .frame(let frame):
                    self.handleDecodedFrame(frame, connectionID: eventConnectionID)
                case .failure(let failure):
                    self.handleProtocolDecodeFailure(failure, connectionID: eventConnectionID)
                }
            },
            onTransportFailure: { [weak self] report in
                self?.handleOutboundTransportFailure(report, connectionID: connectionID)
            },
            onInputRejection: { [weak self] rejection in
                self?.handleOutboundInputRejection(rejection, connectionID: connectionID)
            },
            onReaderDisconnect: { [weak self] disconnectedEncoder, disconnectedConnectionID in
                self?.handleOutboundReaderDisconnect(
                    encoder: disconnectedEncoder,
                    connectionID: disconnectedConnectionID
                )
            },
            onInitializationFailure: { [weak self] error in
                self?.presentOutboundTransportInitializationFailure(error, canRestart: canRestart)
            }
        )
        guard let connection else { return nil }
        protocolConnection = connection
        appState.encoder = connection.encoder
        appState.gui.settingsState.sendAction = { action in connection.encoder.send(action) }
        editorNSView?.installConnectionEncoder(connection.encoder)
        PortLogger.setup(encoder: connection.encoder)
        return connection
    }

    private func handleDecodedFrame(_ frame: DecodedFrame, connectionID: UInt64) {
        os_signpost(
            .event,
            log: protocolLog,
            name: "ProtocolPayloadDelivered",
            "bytes=%{public}d hops=%{public}d",
            frame.metrics.packetBytes,
            frame.metrics.actorHopCount
        )
        guard let dispatcher else { return }
        dispatcher.dispatch(frame, connectionID: connectionID)
    }

    private func handleProtocolDecodeFailure(_ failure: DecodedFrameFailure, connectionID: UInt64) {
        // The packet is transactional: no command from it crossed actor isolation.
        dispatcher?.decodedFrameFailed(failure, connectionID: connectionID)
    }

    private func handleOutboundInputRejection(_ rejection: OutboundInputRejection, connectionID: UInt64) {
        guard outboundConnectionState.isCurrent(connectionID), coreConnectionIsLive,
              inputRejectionAlert == nil else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Paste Is Too Large"
        alert.informativeText = rejection.userFacingMessage
        alert.addButton(withTitle: "OK")
        inputRejectionAlert = alert

        let finish: @MainActor (NSApplication.ModalResponse) -> Void = { [weak self, weak alert] _ in
            guard let self, let alert, self.inputRejectionAlert === alert else { return }
            self.inputRejectionAlert = nil
            self.editorNSView?.focusPolicy.restoreAfterNativeModal()
        }
        if let window = editorNSView?.window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    private func handleOutboundTransportFailure(
        _ report: OutboundTransportFailureReport,
        connectionID: UInt64
    ) {
        guard outboundConnectionState.acceptFailure(for: connectionID) else { return }
        dismissInputRejection()
        coreConnectionIsLive = false
        applicationQuitCoordinator?.transportDidDisconnect()
        if protocolConnection?.connectionID == connectionID {
            protocolConnection?.stop()
            protocolConnection = nil
        }
        appState.encoder = nil
        appState.gui.settingsState.sendAction = nil
        editorNSView?.encoder = ClosureOutboundActionEncoder { _ in .rejected(.disconnected) }
        if let manager = beamManager {
            recoveryManager?.presentTransportFailure(
                message: report.userFacingMessage,
                restartAction: { manager.restartTransportAfterFailure() }
            )
        } else {
            recoveryManager?.presentTransportFailure(
                message: report.userFacingMessage,
                restartAction: nil
            )
        }
    }

    private func handleOutboundReaderDisconnect(
        encoder: ProtocolEncoder,
        connectionID: UInt64
    ) {
        guard outboundConnectionState.isCurrent(connectionID) else { return }
        encoder.disconnect(reason: .unexpectedPeerClosure)
    }

    private func dismissInputRejection() {
        guard let alert = inputRejectionAlert else { return }
        inputRejectionAlert = nil
        if let window = alert.window.sheetParent {
            window.endSheet(alert.window, returnCode: .abort)
        } else {
            NSApp.abortModal()
            alert.window.orderOut(nil)
        }
    }

    private func presentOutboundTransportInitializationFailure(
        _ error: OutboundTransportInitializationError,
        canRestart: Bool
    ) {
        coreConnectionIsLive = false
        applicationQuitCoordinator?.transportDidDisconnect()
        if canRestart, let manager = beamManager {
            recoveryManager?.presentTransportFailure(
                message: error.userFacingMessage,
                restartAction: { manager.restartTransportAfterFailure() }
            )
        } else {
            recoveryManager?.presentTransportFailure(
                message: error.userFacingMessage,
                restartAction: nil
            )
        }
    }
}
