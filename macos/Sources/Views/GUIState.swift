/// Container for all GUI chrome sub-states.
///
/// Holds every `@Observable` state object that SwiftUI chrome views need.
/// Injected once into `CommandDispatcher` and `ContentView`, eliminating
/// the 9 optional property wiring that previously required individual
/// assignment in `AppDelegate`.
///
/// All sub-states are initialized at creation time; no optional nil-checks
/// needed in dispatch handlers.
@MainActor
final class GUIState {
    /// Theme colors for SwiftUI chrome views.
    let themeColors = ThemeColors()

    /// Tab bar state.
    let tabBarState = TabBarState()

    /// File tree sidebar state.
    let fileTreeState = FileTreeState()
    let gitStatusState = GitStatusState()

    /// Completion popup state.
    let completionState = CompletionState()

    /// Which-key popup state.
    let whichKeyState = WhichKeyState()

    /// Breadcrumb path bar state.
    let breadcrumbState = BreadcrumbState()

    /// Status bar state.
    let statusBarState = StatusBarState()

    /// Picker (command palette) state.
    let pickerState = PickerState()

    /// Agent chat state.
    let agentChatState = AgentChatState()

    /// Bottom panel container state.
    let bottomPanelState = BottomPanelState()

    /// Tool manager panel state.
    let toolManagerState = ToolManagerState()

    /// Native minibuffer state (0x7F).
    let minibufferState = MinibufferState()

    /// Hover popup state (0x81).
    let hoverPopupState = HoverPopupState()

    /// Signature help popup state (0x82).
    let signatureHelpState = SignatureHelpState()

    /// Float popup state (0x83).
    let floatPopupState = FloatPopupState()

    /// Board card grid state (0x87).
    let boardState = BoardState()

    /// Semantic window content from gui_window_content (0x80).
    /// Keyed by windowId. NOT cleared between frames; the guiWindowContent
    /// dispatch overwrites per-window data each frame. Stale entries serve
    /// as fallback to prevent blank viewport flashes.
    var windowContents: [UInt16: GUIWindowContent] = [:]

    /// Prepares for a new frame.
    ///
    /// Note: `windowContents` is intentionally NOT cleared here.
    /// The `guiWindowContent` dispatch overwrites per-window data each
    /// frame. Keeping stale content as fallback prevents a blank viewport
    /// flash if frame delivery is interrupted (defense-in-depth alongside
    /// the atomic Metal frame bundling on the BEAM side).
    func beginFrame() {
        // No-op: all per-frame state is overwritten by incoming commands.
        // Previously cleared windowContents here, but that caused blank
        // frames when vsync fired between clear and content arrival.
    }
}
