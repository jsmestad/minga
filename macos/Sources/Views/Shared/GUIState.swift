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

    /// Native settings panel state.
    let settingsState = SettingsState()

    /// Bottom-right editor notification center state.
    let notificationCenterState = NotificationCenterState()

    /// Tab bar state.
    let tabBarState = TabBarState()

    /// Workspace header and active-workspace file tab state.
    let workspaceState = WorkspaceState()

    /// Native sidebar host state.
    let sidebarHostState = SidebarHostState()

    /// Rich sidebar payload state.
    let fileTreeState = FileTreeState()
    let gitStatusState = GitStatusState()
    let observatoryState = ObservatoryState()

    /// Completion popup state.
    let completionState = CompletionState()

    /// Which-key popup state.
    let whichKeyState = WhichKeyState()

    /// Breadcrumb path bar state.
    let breadcrumbState = BreadcrumbState()

    /// Status bar state.
    let statusBarState = StatusBarState()

    /// Action feedback state (delay-then-show spinner, hold floor).
    let feedbackState = FeedbackState()

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

    /// Agent context bar state (0x88).
    let agentContextBarState = AgentContextBarState()
    /// Change summary sidebar for agent card zoomed-in view.
    let changeSummaryState = ChangeSummaryState()

    /// Edit timeline scrubber state.
    let editTimelineState = EditTimelineState()

    /// Extension overlay state (0x9C).
    let extensionOverlayState = ExtensionOverlayState()

    /// Extension panel state (0x9D).
    let extensionPanelState = ExtensionPanelState()

    /// Frontend extension runtime registry for extension-owned decoders and views.
    let frontendExtensions = FrontendExtensionRuntimeRegistry()

    /// Search toolbar state (0x9E).
    let searchState = SearchState()

    /// Blocking protocol_error state (0x18). Set when the BEAM rejects this
    /// frontend's handshake protocol_version; drives a full-window error overlay
    /// so a version-mismatched frontend shows an explicit reason instead of a
    /// blank screen (ticket #2237).
    let protocolErrorState = ProtocolErrorState()

    /// Keystroke-to-present latency HUD state (ticket #2215). Client-local debug
    /// overlay; boots visible when MINGA_LATENCY_HUD=1, toggled from the View menu.
    let latencyHUDState = LatencyHUDState()

    /// Pending frame-transaction resync hint (#2219 child D). Raised by
    /// CommandDispatcher when a frame is invalidated and a keyframe is requested;
    /// cleared on the next clean commit. Ephemeral: it lives between commits and
    /// never routes through staging.
    let resyncState = ResyncState()

    /// Semantic window content from gui_window_content (0x80).
    /// Keyed by windowId. NOT cleared between frames; the guiWindowContent
    /// dispatch overwrites per-window data each frame. Stale entries serve
    /// as fallback to prevent blank viewport flashes.
    var windowContents: [UInt16: GUIWindowContent] = [:]

}
