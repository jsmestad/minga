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

private let appStartupLogger = Logger(subsystem: PortLogger.subsystem, category: "Startup")
private let fontRegistrationLogger = Logger(subsystem: PortLogger.subsystem, category: "Fonts")
private let appProbeLogger = Logger(subsystem: PortLogger.subsystem, category: "Probes")

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
                .environment(\.editorFocusPolicy, appDelegate.appState.editorNSView?.focusPolicy)
                .environment(\.agentPromptSurface, appDelegate.appState.editorNSView.map { AgentPromptSurface(editor: $0) })
                .frame(minWidth: 160, minHeight: 80)
                .allowsHitTesting(appDelegate.appState.hasReceivedFirstFrame)
                .accessibilityHidden(!appDelegate.appState.hasReceivedFirstFrame)
                // Disable SwiftUI's focus system so it doesn't steal
                // first responder from the EditorNSView.
                .focusable(false)
                .focusEffectDisabled()
                .background(EditorWindowIdentifierSetter(onAttach: appDelegate.configureEditorWindow))
                .overlay {
                    if let startup = appDelegate.appState.startup {
                        StartupOverlay(
                            startup: startup,
                            compilingExtension: appDelegate.appState.compilingExtension,
                            canRestartInSafeMode: appDelegate.canRestartInSafeMode,
                            onKeepWaiting: { appDelegate.keepWaitingForStartup() },
                            onRetry: { appDelegate.retryStartup(inSafeMode: $0) },
                            onQuit: { appDelegate.quitDuringStartup() }
                        )
                        .transition(.opacity)
                    }
                }
                // Scene-owned URL delivery preserves the window and its Metal view's redraw lifecycle.
                .onOpenURL { url in
                    appDelegate.openFileURL(url)
                }
                .overlay(
                    SingletonEditorWindowProbe(receivedFileURLs: { appDelegate.pendingFileURLs }) {
                        appDelegate.finishSingletonEditorWindowProbe()
                    }
                )
        }
        .windowStyle(.hiddenTitleBar)
        .restorationBehavior(appDelegate.appState.usesDevelopmentProfile ? .disabled : .automatic)
        .defaultSize(width: defaultWindowWidth, height: defaultWindowHeight)
        .commands {
            MingaMenuCommands(appState: appDelegate.appState)
            LeaderMenuCommands(appState: appDelegate.appState)
        }

        Settings {
            SettingsView(
                state: appDelegate.appState.gui.settingsState,
                sendAction: FrontendActionComposition.settingsHandler(encoder: appDelegate.appState.encoder)
            )
        }
        .restorationBehavior(appDelegate.appState.usesDevelopmentProfile ? .disabled : .automatic)
    }
}

private struct StartupOverlay: View {
    let startup: StartupPresentation
    let compilingExtension: String?
    let canRestartInSafeMode: Bool
    let onKeepWaiting: () -> Void
    let onRetry: (Bool) -> Void
    let onQuit: () -> Void

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

    @State private var quip = StartupOverlay.quips.randomElement() ?? "Starting Minga…"
    @State private var showsQuit = false

    private var title: String {
        switch startup {
        case .starting, .waiting: quip
        case .waitingLonger: "Waiting for the editor…"
        case .slow: "Minga is taking longer than expected"
        case .retrying: "Restarting the editor core…"
        case .failed: "Minga Could Not Start"
        }
    }

    private var showsProgress: Bool {
        switch startup {
        case .starting, .waiting, .waitingLonger, .retrying: true
        case .slow, .failed: false
        }
    }

    private var canRetry: Bool {
        switch startup {
        case .slow(let canRetry), .waitingLonger(let canRetry), .failed(_, let canRetry): canRetry
        case .starting, .waiting, .retrying: false
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: Spacing.lg) {
                    Image("MingaLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96, height: 96)
                        .accessibilityHidden(true)
                    if showsProgress {
                        ProgressView().controlSize(.small).accessibilityLabel("Loading the editor")
                    }
                    Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                    if let compilingExtension {
                        Text("Compiling extension \(compilingExtension)…")
                            .foregroundStyle(.secondary)
                    }
                    if case .failed(let message, _) = startup {
                        Text(message).foregroundStyle(.secondary)
                    }
                    if canRetry {
                        Text("Restarting replaces the editor core. Changes not saved or recovered may be lost.")
                            .foregroundStyle(.secondary)
                        if canRestartInSafeMode {
                            Text("Safe mode skips user configuration and extensions for this launch.")
                                .foregroundStyle(.secondary)
                        }
                    } else if case .slow = startup {
                        Text("You can keep waiting or quit and relaunch Minga from your terminal.")
                            .foregroundStyle(.secondary)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Spacing.md) { actions }
                        VStack(spacing: Spacing.md) { actions }
                    }
                    .buttonStyle(.bordered)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .padding(Spacing.panel)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(.background)
        .task {
            do {
                try await Task.sleep(for: .seconds(10))
                showsQuit = true
            } catch {
                return
            }
        }
    }

    @ViewBuilder private var actions: some View {
        if case .slow = startup {
            Button("Keep Waiting", action: onKeepWaiting)
        }
        if canRetry {
            Button("Retry Startup") { onRetry(false) }
            if canRestartInSafeMode {
                Button("Restart in Safe Mode") { onRetry(true) }
            }
        }
        if showsQuit {
            Button("Quit Minga", action: onQuit)
        }
    }
}

/// Identifies the editor window for lifecycle checks without changing its scene identity.
private struct EditorWindowIdentifierSetter: NSViewRepresentable {
    let onAttach: @MainActor (NSWindow) -> Void

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
            guard let window = view.window else { return }
            window.identifier = EditorScene.windowIdentifier
            onAttach(window)
        }
    }
}

private struct SingletonEditorWindowProbeSnapshot: Codable {
    let editorWindowCount: Int
    let reusedExistingWindow: Bool
    let editorWindowIsVisible: Bool
    let reusedWindowForFileURLs: Bool
    let receivedFilePaths: [String]
    let fileURLError: String?
}

/// Deterministic launch probe for the singleton editor scene contract.
private struct SingletonEditorWindowProbe: View {
    static let outputPathEnvironmentKey = "MINGA_SINGLETON_EDITOR_WINDOW_PROBE_PATH"
    @MainActor private static var hasStarted = false

    @Environment(\.openWindow) private var openWindow

    let receivedFileURLs: @MainActor () -> [URL]
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
                    editorWindowIsVisible: false,
                    reusedWindowForFileURLs: false,
                    receivedFilePaths: [],
                    fileURLError: "Initial editor window was unavailable"
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
        let originalWindowNumber = originalWindow.windowNumber
        let directory = URL(fileURLWithPath: outputPath).deletingLastPathComponent()
        var reusedWindowForFileURLs = true
        var fileURLError: String?
        do {
            try Data("0".utf8).write(to: URL(fileURLWithPath: outputPath + ".ready"), options: .atomic)
        } catch {
            fileURLError = String(describing: error)
        }
        for (index, name) in ["first.txt", "second.txt"].enumerated() where fileURLError == nil {
            let url = directory.appendingPathComponent(name).standardizedFileURL
            do {
                for _ in 0..<500 where !receivedFileURLs().contains(url) {
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard receivedFileURLs().contains(url) else {
                    fileURLError = "File-open event was not delivered: \(url.path)"
                    break
                }
                reusedWindowForFileURLs = reusedWindowForFileURLs
                    && editorWindows.count == 1
                    && editorWindows.first === originalWindow
                    && originalWindow.windowNumber == originalWindowNumber
                try Data(String(index + 1).utf8).write(to: URL(fileURLWithPath: outputPath + ".ready"), options: .atomic)
            } catch {
                fileURLError = String(describing: error)
                break
            }
        }
        write(
            SingletonEditorWindowProbeSnapshot(
                editorWindowCount: editorWindows.count,
                reusedExistingWindow: reopenedWindow === originalWindow,
                editorWindowIsVisible: editorWindows.first?.isVisible == true,
                reusedWindowForFileURLs: reusedWindowForFileURLs,
                receivedFilePaths: receivedFileURLs().map(\.path),
                fileURLError: fileURLError
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
            PortLogger.report(.error, "Singleton editor window probe failed", to: appProbeLogger, privateDetail: error.localizedDescription)
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

#if DEBUG
/// Launch probe proving the editor window exists while the app has never requested activation.
@MainActor
private enum InactiveLaunchWindowProbe {
    struct Snapshot: Codable {
        let editorWindowCount: Int
        let editorWindowIsVisible: Bool
        let applicationIsActive: Bool
    }

    static var outputPath: String? {
        ProcessInfo.processInfo.environment["MINGA_INACTIVE_LAUNCH_WINDOW_PROBE_PATH"]
    }

    static func run(writingTo path: String) {
        Task { @MainActor in
            for _ in 0..<300 where editorWindows.isEmpty {
                try? await Task.sleep(for: .milliseconds(10))
            }
            let snapshot = Snapshot(
                editorWindowCount: editorWindows.count,
                editorWindowIsVisible: editorWindows.first?.isVisible == true,
                applicationIsActive: NSApp.isActive
            )
            do {
                try JSONEncoder().encode(snapshot).write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch {
                PortLogger.report(.error, "Inactive launch window probe failed", to: appProbeLogger, privateDetail: error.localizedDescription)
            }
            NSApp.terminate(nil)
        }
    }

    private static var editorWindows: [NSWindow] {
        NSApp.windows.filter { $0.identifier == EditorScene.windowIdentifier }
    }
}
#endif

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

        // View menu: these items join the system View menu (Enter Full Screen and the rest), before its toolbar
        // group, so the menu bar has one View menu. A CommandMenu("View") would add a second one beside it.
        CommandGroup(before: .toolbar) {
            Button("Toggle File Tree") { encoder?.send(.togglePanel(panel: 0)) }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(!connected)
            // The modeline carries state, not panel toggles; these panels open from here by mouse and from their leader keys.
            Button("Toggle Git Status") { encoder?.send(.togglePanel(panel: 2)) }
                .disabled(!connected)
            Button("Toggle Messages") { encoder?.send(.togglePanel(panel: 1)) }
                .disabled(!connected)
            Button("Toggle Conversation") { encoder?.send(.togglePanel(panel: 3)) }
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

        // Go menu: ⌘[ and ⌘] are the macOS aliases of ⌃O and ⌃I, which walk the jump list
        // (docs/design/keys.md). The BEAM owns the list; these items only name the command.
        CommandMenu("Go") {
            Button("Back") { encoder?.send(.executeCommand(name: "jump_back")) }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!connected)
            Button("Forward") { encoder?.send(.executeCommand(name: "jump_forward")) }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!connected)
        }
    }

    private func routeTextEditingCommand(_ command: NativeTextCommandRouter.Command, fallback: (OutboundActionEncoding) -> Void) {
        guard appState.gui.focusOwnerState.decodedOwner?.ownsActMenu != true else { return }
        NativeMenuTextRouter.perform(command, encoder: encoder, fallback: fallback)
    }

    private func textEditingCommandIsAvailable(_ command: NativeTextCommandRouter.Command) -> Bool {
        guard appState.gui.focusOwnerState.decodedOwner?.ownsActMenu != true else { return false }
        return NativeMenuTextRouter.isAvailable(command, encoder: encoder)
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
    private var desktopAgentNotifications: DesktopAgentNotifications?
    /// Mirrors the leader keymap into the menu bar (docs/design/surfaces.md, Mouse).
    private var applicationQuitCoordinator: ApplicationQuitCoordinator?
    private var applicationQuitAlert: NSAlert?
    private var activeFilePanel: NSSavePanel?
    private var inputRejectionAlert: NSAlert?
    private var coreConnectionIsLive = false
    private var recoveryManager: RecoveryManager?
    private var fontManager: FontManager?
    private var editorNSView: EditorNSView?
    private var workspaceNotificationTasks: [Task<Void, Never>] = []
    // Retain the profiled singleton until app termination, including when its window closed first.
    private var profileEditorWindow: NSWindow?
    private var outboundConnectionState = OutboundConnectionState()
    private var coreLifecycle: EditorCoreLifecycle?
    fileprivate private(set) var pendingFileURLs: [URL] = []
    private var acceptsOpenRequests = false
    private let frameResourcePolicy = FrameResourcePolicy.default

    override init() {
        let environment = ProcessInfo.processInfo.environment
        let appState = AppState(applicationEnvironment: environment)
#if DEBUG
        if environment[MenuSnapshotProbe.connectedEnvironmentKey] == "1" {
            appState.encoder = ClosureOutboundActionEncoder { _ in .rejected(.disconnected) }
        }
#endif
        self.appState = appState
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        desktopAgentNotifications = DesktopAgentNotifications(
            openEditor: {
                NSApp.activate()
                guard let window = NSApp.windows.first(where: { $0.identifier == EditorScene.windowIdentifier }) else { return }
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            },
            // The BEAM opens the tasks drawer on the alert's task, as it is now; the click answers nothing.
            openAlert: { [weak self] alert in
                _ = self?.encoder?.send(.agentNotificationOpen(alert: alert))
            }
        )
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        desktopAgentNotifications?.activation(true)
    }

    func applicationDidResignActive(_ notification: Notification) {
        desktopAgentNotifications?.activation(false)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
#if DEBUG
        if runMenuSnapshotProbeIfRequested() {
            return
        }
        if SingletonEditorWindowProbe.isRequested {
            appState.startup = nil
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            scheduleEditorWindowLaunchFallback()
            return
        }
        if let outputPath = InactiveLaunchWindowProbe.outputPath {
            // Never request activation, so AppKit handles the launch event while inactive, as it does when another app is frontmost.
            appState.startup = nil
            NSApp.setActivationPolicy(.regular)
            scheduleEditorWindowLaunchFallback()
            InactiveLaunchWindowProbe.run(writingTo: outputPath)
            return
        }
#endif

        // Ignore SIGPIPE so broken pipe writes return EPIPE instead of
        // killing the process. Without this, any write to the BEAM pipe
        // after Ctrl+C delivers SIGPIPE (default action: terminate).
        signal(SIGPIPE, SIG_IGN)

        os_signpost(.begin, log: startupLog, name: "AppStartup")
        recordStartupPhase("app_startup")

        // Protocol encoder and reader: in bundle mode, we spawn the BEAM
        // and use pipe file handles. In dev mode, we use stdin/stdout.
        let handles: (input: FileHandle, output: FileHandle)?

        if BEAMProcessManager.isBundleMode {
            let manager = BEAMProcessManager()
            self.beamManager = manager
            manager.onStartupCompile = { [weak self] name in
                guard let self, !self.appState.hasReceivedFirstFrame else { return }
                self.appState.compilingExtension = name
            }

            manager.onTermination = { [weak self] _ in
                guard let self else { return false }
                if let encoder = self.encoder { PortLogger.clearEncoder(encoder) }
                self.coreConnectionIsLive = false
                return self.coreLifecycle?.coreDidExit() ?? false
            }
            manager.onCrash = { [weak self] in
                self?.presentEditorCoreStoppedRecovery()
            }
            manager.onNormalExit = { [weak self] in
                guard let self, self.beamManager?.isShuttingDown != true else { return }
                NSApp.terminate(nil)
            }
            manager.start(onStartupFailure: { [weak self] in self?.presentStartupProcessFailure($0) })
            if let input = manager.readHandle, let output = manager.writeHandle {
                recordStartupPhase("beam_spawned")
                handles = (input, output)
            } else {
                handles = nil
            }
        } else {
            // Dev mode: BEAM is our parent, use stdin/stdout
            handles = (.standardInput, .standardOutput)
        }

        // Register the bundled Nerd Font for devicon rendering.
        registerBundledFonts()

        // Register as a regular GUI app so macOS routes keyboard events to us.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        scheduleEditorWindowLaunchFallback()

        // Initial backing scale for Retina rendering. The window does not exist yet, so NSScreen.main is the only safe source here. EditorNSView.viewDidMoveToWindow/viewDidChangeBackingProperties corrects this if the window lands on another display.
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0

        // Font manager owns the primary and all registered font faces.
        let fm = FontManager(name: defaultFontName, size: defaultFontSize, scale: scale)
        self.fontManager = fm
        recordStartupPhase("fonts_ready")

        // Initial grid dimensions via the shared formula (GridFit). No gutter
        // padding yet; the first setFrameSize sends corrected cols once the gutter
        // is established. Line spacing defaults to 1.0 before the BEAM sends a
        // value, which matches the GridFit default parameter.
        let cols = GridFit.colsThatFit(width: defaultWindowWidth, cellWidth: CGFloat(fm.cellWidth))
        let rows = GridFit.rowsThatFit(height: defaultWindowHeight, cellHeight: CGFloat(fm.cellHeight))

        // CoreText renderer.
        guard let ctRenderer = CoreTextMetalRenderer(
            resourcePolicy: frameResourcePolicy.nativeRenderer
        ) else {
            beamManager?.abortStartup()
            presentStartupFailure("Minga could not initialize Metal. Check that this Mac supports Metal and reinstall Minga if its shader resources are missing.", canRetry: false)
            return
        }
        ctRenderer.setupRenderers(fontManager: fm)
        recordStartupPhase("native_ready")

        let recovery = RecoveryManager { [weak self] in
            if let manager = self?.beamManager {
                manager.sendRecoveryRestartSignal()
            } else {
                let parentPid = getppid()
                if parentPid > 1 { kill(parentPid, SIGUSR2) }
            }
        }
        self.recoveryManager = recovery

        // Command dispatcher.
        let disp = CommandDispatcher(
            cols: cols, rows: rows, guiState: appState.gui,
            resourcePolicy: frameResourcePolicy,
            applicationEffectSink: { [weak self] effect in
                self?.handleApplicationCommitEffect(effect)
            }
        )
        disp.fontManager = fm
        disp.onOperationNativeResult = { [weak self] result in
            self?.encoder?.send(.operationNativeResult(result))
        }
        disp.onNativePresentationObservation = { [weak self] evidence in
            self?.encoder?.send(.nativePresentationObservation(evidence))
        }
        disp.textPresentationLeases.onState = { [weak self] windowID, presentationID, state in
            self?.encoder?.send(.textPresentationState(windowID: windowID, presentationID: presentationID, state: state))
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
        let lifecycle = EditorCoreLifecycle(
            quitCoordinator: quitCoordinator,
            processManager: beamManager,
            retireConnection: { [weak self] in self?.retireProtocolConnection() },
            presentTransportFailure: { [weak self] message in self?.presentTerminalTransportFailure(message: message) },
            presentCoreStopped: { [weak self] in self?.presentEditorCoreStoppedRecovery() },
            terminateApplication: { NSApp.terminate(nil) }
        )
        self.coreLifecycle = lifecycle
        disp.onApplicationQuitResponse = { [weak lifecycle] response in
            lifecycle?.receive(response)
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
        let nsView = EditorNSView(encoder: ClosureOutboundActionEncoder { _ in .rejected(.disconnected) }, dispatcher: disp,
                                   coreTextRenderer: ctRenderer, fontManager: fm)
        nsView.savesFrameInApplicationPreferences = !appState.usesDevelopmentProfile
        nsView.editorInput = appState.gui.editorInput
        ctRenderer.presentationMetrics = appState.gui.presentationMetrics
        nsView.statusBarState = appState.gui.statusBarState
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
            guard let self, let encoder = self.encoder else { return }
            encoder.send(result.outboundAction)
            if case .applied = result, self.coreConnectionIsLive {
                self.protocolConnection?.startLogging()
            }
            if !self.appState.hasReceivedFirstFrame,
               case .rejected(_, _, _, .resourcePolicy) = result {
                self.presentStartupFailure("The editor’s first frame exceeds the macOS frontend’s resource limits.", canRetry: false)
            }
        }
        disp.onFrameReady = { [weak nsView] in
            nsView?.renderFrame()
        }
        // The ready event is deferred: EditorNSView.setFrameSize sends it
        // once SwiftUI assigns the real frame dimensions. This avoids
        // the BEAM rendering at hardcoded 800x600 defaults.

        beamManager?.onBEAMReady = { [weak self] input, output in
            self?.connectProtocol(readHandle: input, writeHandle: output)
        }
        if let handles {
            connectProtocol(readHandle: handles.input, writeHandle: handles.output)
        }
    }

    /// Requests the editor window on a later main-queue turn, after AppKit has had its chance to open the launch window.
    ///
    /// If this runs before AppKit handles the open-application event, AppKit finds the open editor window and does not open another.
    private func scheduleEditorWindowLaunchFallback() {
        DispatchQueue.main.async { [weak self] in
            self?.openEditorWindowIfLaunchSkippedIt()
        }
    }

    /// Opens the singleton editor scene when AppKit declined to open it at launch.
    ///
    /// AppKit opens the launch window only when the app is active as it handles the open-application event. Cooperative activation denies `NSApp.activate()` while another app is frontmost, so a background launch otherwise creates no editor window. `EditorNSView` then never sends `ready`, and every BEAM frame goes unacknowledged until the user reopens Minga. This asks the SwiftUI application delegate for the same untitled window AppKit would have requested. It does not activate the app or take focus from the frontmost app. `Window` is a single-instance scene, so a launch that already opened the editor reuses it.
    private func openEditorWindowIfLaunchSkippedIt() {
        guard !NSApp.windows.contains(where: \.isVisible), let delegate = NSApp.delegate,
              delegate.applicationShouldOpenUntitledFile?(NSApp) ?? true else { return }
        PortLogger.report(.info, "Opening the editor window that AppKit skipped during an inactive launch", to: appStartupLogger)
        _ = delegate.applicationOpenUntitledFile?(NSApp)
    }

    private func installStartupFrameCallback() {
        // The callback is one-shot, so every new startup connection installs its own.
        dispatcher?.onFirstRender = { [weak self] in
            guard let self, let disposition = self.coreLifecycle?.firstFrameDidCommit(),
                  disposition != .ignored else { return }

            os_signpost(.end, log: startupLog, name: "AppStartup")
            recordStartupPhase("first_frame_committed")
            self.editorNSView?.focusPolicy.firstFrameDidRender()

            let duration: Double = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.25
            withAnimation(.easeOut(duration: duration), completionCriteria: .removed) {
                self.appState.startup = nil
            } completion: { [weak self] in
                guard let editorNSView = self?.editorNSView else { return }
                _ = editorNSView.focusPolicy.requestPresentationFocus()
            }

            self.acceptsOpenRequests = true
            self.flushPendingOpenRequests()
        }
    }

    private func startProtocolConnection(_ connection: ProtocolConnection) {
        coreConnectionIsLive = true
        if !appState.hasReceivedFirstFrame {
            appState.startup = .waiting
            installStartupFrameCallback()
            coreLifecycle?.waitForFirstFrame { [weak self] in self?.presentStartupTimeout() }
        }
        // Start only after every consumer, including the first-frame callback, is installed.
        connection.start()
        recordStartupPhase("protocol_started")
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
        case .agentDesktopNotification(let notification):
            if coreConnectionIsLive { desktopAgentNotifications?.receive(notification) }
        case .nativeFileLocationAction(let action):
            guard coreConnectionIsLive else { return }
            let url = URL(fileURLWithPath: action.path, isDirectory: action.kind == .openTerminal)
            switch action.kind {
            case .reveal:
                NSWorkspace.shared.activateFileViewerSelecting([url])
            case .openTerminal:
                NSWorkspace.shared.open(
                    [url],
                    withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                    configuration: NSWorkspace.OpenConfiguration()
                )
            }
        case .needsYouCountChanged(let count):
            desktopAgentNotifications?.needsYouCount(count)
        case .documentEditedChanged(let edited):
            editorNSView?.window?.isDocumentEdited = edited
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
        case .focusOwnerChanged(let owner):
            editorNSView?.focusPolicy.focusOwnerDidChange(owner)
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
                PortLogger.report(.error, "Minga menu snapshot probe failed", to: appProbeLogger, privateDetail: error.localizedDescription)
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
        if coreLifecycle?.startupHasTimedOut == true { return .terminateNow }
        let coreIsLive = coreConnectionIsLive
            && (beamManager.map { !$0.isShuttingDown && $0.hasLiveProcess } ?? true)
        return ApplicationTerminationPolicy.reply(
            coreIsLive: coreIsLive,
            waitingForFirstFrame: coreLifecycle?.isAwaitingFirstFrame == true,
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
            let paths = (panel as? NSOpenPanel)?.urls.map(\.path) ?? []
            let outcome: UInt8 = paths.isEmpty ? 0 : 1
            encoder.send(.fileDialogResult(
                requestID: request.requestID,
                outcome: outcome,
                paths: paths
            ))
        case .saveAs:
            guard let path = panel.url?.path else {
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

    func configureEditorWindow(_ window: NSWindow) {
        guard appState.usesDevelopmentProfile, profileEditorWindow !== window else { return }
        profileEditorWindow = window
        window.isRestorable = false
        _ = window.setFrameAutosaveName("")
        appState.editorWindowFrame?.restore(window)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let window = profileEditorWindow {
            appState.editorWindowFrame?.save(window)
        }
        cancelWorkspaceLifecycleNotifications()
        beamManager?.beginAppShutdown()
        coreLifecycle?.stop()
        retireProtocolConnection()
        beamManager?.abortStartup()
    }

    /// Handles file URLs in the existing SwiftUI scene without replacing its native window.
    func openFileURL(_ url: URL) {
        guard url.isFileURL else { return }
        // Forward the supplied path unchanged. Foundation standardization can change the spelling that identifies an existing buffer and its swap.
        if acceptsOpenRequests, let encoder {
            encoder.send(.openFile(path: url.path))
        } else {
            pendingFileURLs.append(url)
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
                    PortLogger.info("Volume will unmount", privateDetail: volumePath)
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

    // MARK: - Protocol connection

    private func connectProtocol(readHandle: FileHandle, writeHandle: FileHandle) {
        let connectionID = outboundConnectionState.issueID()
        guard let replacement = replaceProtocolConnection(
            connectionID: connectionID,
            readHandle: readHandle,
            writeHandle: writeHandle
        ) else { return }
        recoveryManager?.transportDidReconnect()
        startProtocolConnection(replacement)
        PortLogger.info("macOS GUI frontend connected (\(beamManager != nil ? "bundle" : "dev") mode)")

        editorNSView?.announceReadyIfLaidOut()

        sendCurrentPowerThermalState(reason: "Power state after BEAM connection")
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
                    PortLogger.report(.info, "Registered bundled font: \(fontName)", to: fontRegistrationLogger)
                    return
                } else if let error = errorRef?.takeRetainedValue() {
                    // Font might already be registered (e.g., user has it installed)
                    let desc = CFErrorCopyDescription(error) as String
                    if desc.contains("already registered") {
                        return
                    }
                    PortLogger.report(.warning, "Failed to register bundled font \(fontName)", to: fontRegistrationLogger, privateDetail: desc)
                }
            }
        }

        // Font not found in bundle; check if it's already available system-wide
        let testFont = NSFont(name: "Symbols Nerd Font Mono", size: 12)
        if testFont != nil {
            return
        }

        PortLogger.report(.warning, "Nerd Font not found. Devicons will show as missing glyphs.", to: fontRegistrationLogger)
    }

    // MARK: - Protocol handling

    private func replaceProtocolConnection(
        connectionID: UInt64,
        readHandle: FileHandle,
        writeHandle: FileHandle
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
                self.coreLifecycle?.replaceConnection()
                self.coreConnectionIsLive = false
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
                self?.presentOutboundTransportInitializationFailure(error)
            }
        )
        guard let connection else { return nil }
        beamManager?.transferPipeOwnership()
        protocolConnection = connection
        appState.encoder = connection.encoder
        appState.gui.settingsState.sendAction = FrontendActionComposition.settingsStateHandler(encoder: connection.encoder)
        editorNSView?.installConnectionEncoder(connection.encoder)
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
        if !appState.hasReceivedFirstFrame, let message = appState.gui.protocolErrorState.message {
            coreLifecycle?.abandonStartup()
            beamManager?.abortStartup()
            presentStartupFailure(message, canRetry: false)
        }
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
        guard outboundConnectionState.isCurrent(connectionID) else { return }
        if let encoder { PortLogger.clearEncoder(encoder) }
        coreConnectionIsLive = false
        coreLifecycle?.transportDidFail(message: report.userFacingMessage)
    }

    private func handleOutboundReaderDisconnect(
        encoder: ProtocolEncoder,
        connectionID: UInt64
    ) {
        guard outboundConnectionState.isCurrent(connectionID) else { return }
        encoder.disconnect(reason: .expectedTeardown)
        coreConnectionIsLive = false
        desktopAgentNotifications?.retireConnection()
        coreLifecycle?.readerDidClose()
    }

    private func retireProtocolConnection() {
        coreConnectionIsLive = false
        desktopAgentNotifications?.retireConnection()
        outboundConnectionState.retire()
        recoveryManager?.transportDidReconnect()
        dismissInputRejection()
        protocolConnection?.stop()
        protocolConnection = nil
        appState.encoder = nil
        appState.gui.settingsState.sendAction = nil
        editorNSView?.encoder = ClosureOutboundActionEncoder { _ in .rejected(.disconnected) }
    }

    func keepWaitingForStartup() {
        guard case .slow(let canRetry) = appState.startup else { return }
        appState.startup = .waitingLonger(canRetry: canRetry)
    }

    var canRestartInSafeMode: Bool { beamManager?.isSafeMode == false }

    func retryStartup(inSafeMode: Bool) {
        guard let manager = beamManager, !inSafeMode || canRestartInSafeMode else { return }
        switch appState.startup {
        case .slow(true), .waitingLonger(true), .failed(_, true):
            appState.startup = .retrying
            appState.compilingExtension = nil
            coreLifecycle?.abandonStartup()
            manager.retryStartup(inSafeMode: inSafeMode) { [weak self] in self?.presentStartupProcessFailure($0) }
        default:
            break
        }
    }

    func quitDuringStartup() {
        guard !appState.hasReceivedFirstFrame else { return }
        coreLifecycle?.abandonStartup()
        NSApp.terminate(nil)
    }

    private func presentStartupProcessFailure(_ failure: BEAMProcessManager.StartupFailure) {
        switch failure {
        case .missingRelease:
            presentStartupFailure("The bundled editor core is missing. Reinstall Minga and launch it again.", canRetry: false)
        case .missingDevelopmentProfile:
            presentStartupFailure("A Debug app cannot start its bundled editor core without an isolated development profile. Quit and use bin/minga-mac from the source checkout.", canRetry: false)
        case .launch(let reason):
            presentStartupFailure("Minga could not launch the editor core. \(reason)", canRetry: true)
        case .previousCoreStopTimedOut:
            presentStartupFailure("Minga could not confirm that the previous editor core stopped in time. No replacement was started.", canRetry: false)
        }
    }

    private func presentStartupFailure(_ message: String, canRetry: Bool) {
        PortLogger.report(.error, "Minga startup failed", to: appStartupLogger, privateDetail: message)
        appState.compilingExtension = nil
        appState.startup = .failed(message: message, canRetry: canRetry)
    }

    private func presentStartupTimeout() {
        guard case .waiting = appState.startup else { return }
        PortLogger.report(.warning, "Minga startup is waiting for its first frame", to: appStartupLogger)
        appState.startup = .slow(canRetry: beamManager != nil)
    }

    private func presentTerminalTransportFailure(message: String) {
        guard appState.hasReceivedFirstFrame else {
            if case .failed(_, false) = appState.startup { return }
            let detail = beamManager == nil ? message + " Quit, then relaunch Minga from your terminal." : message
            presentStartupFailure(detail, canRetry: beamManager != nil)
            return
        }
        let restart: (@MainActor () -> Void)?
        if let manager = beamManager {
            restart = { manager.restartTransportAfterFailure() }
        } else {
            restart = nil
        }
        recoveryManager?.presentTransportFailure(message: message, restartAction: restart)
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

    private func presentOutboundTransportInitializationFailure(_ error: OutboundTransportInitializationError) {
        coreConnectionIsLive = false
        applicationQuitCoordinator?.transportRecoveryDidExpire()
        if !appState.hasReceivedFirstFrame {
            coreLifecycle?.stop()
            beamManager?.stopUnconnectedStartup()
        }
        presentTerminalTransportFailure(message: error.userFacingMessage)
    }
}
