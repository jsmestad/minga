/// Container for all GUI chrome sub-states.
///
/// Holds every `@Observable` state object that SwiftUI chrome views need.
/// Injected once into `CommandDispatcher` and `ContentView`, eliminating
/// the 9 optional property wiring that previously required individual
/// assignment in `AppDelegate`.
///
/// All sub-states are initialized at creation time; no optional nil-checks
/// needed in dispatch handlers.
import MingaProtocol

@MainActor
public final class GUIState {
    public init(windowContents: [UInt16: GUIWindowContent] = [:]) {
        self.windowContents = windowContents
    }
    /// Theme colors for SwiftUI chrome views.
    public let themeColors = ThemeColors()

    /// Native settings panel state.
    public let settingsState = SettingsState()

    /// Bottom-right editor notification center state.
    public let notificationCenterState = NotificationCenterState()

    /// Tab bar state.
    public let tabBarState = TabBarState()

    /// Launchpad empty state (0xA5), shown when zero buffers are open.
    public let emptyStateState = EmptyStateState()

    /// Workspace header and active-workspace file tab state.
    public let workspaceState = WorkspaceState()

    /// Native sidebar host state.
    public let sidebarHostState = SidebarHostState()

    /// Rich sidebar payload state.
    public let fileTreeState = FileTreeState()
    public let gitStatusState = GitStatusState()
    public let observatoryState = ObservatoryState()

    /// Completion popup state.
    public let completionState = CompletionState()

    /// Which-key popup state.
    public let whichKeyState = WhichKeyState()

    /// Breadcrumb path bar state.
    public let breadcrumbState = BreadcrumbState()

    /// Status bar state.
    public let statusBarState = StatusBarState()

    /// Action feedback state (delay-then-show spinner, hold floor).
    public let feedbackState = FeedbackState()

    /// Picker (command palette) state.
    public let pickerState = PickerState()

    /// Agent chat state.
    public let agentChatState = AgentChatState()

    /// Bottom panel container state.
    public let bottomPanelState = BottomPanelState()

    /// Tool manager panel state.
    public let toolManagerState = ToolManagerState()

    /// Native minibuffer state (0x7F).
    public let minibufferState = MinibufferState()

    /// Hover popup state (0x81).
    public let hoverPopupState = HoverPopupState()

    /// Signature help popup state (0x82).
    public let signatureHelpState = SignatureHelpState()

    /// Float popup state (0x83).
    public let floatPopupState = FloatPopupState()

    /// Agent context bar state (0x88).
    public let agentContextBarState = AgentContextBarState()
    /// Change summary sidebar for agent card zoomed-in view.
    public let changeSummaryState = ChangeSummaryState()

    /// Edit timeline scrubber state.
    public let editTimelineState = EditTimelineState()

    /// Extension overlay state (0x9C).
    public let extensionOverlayState = ExtensionOverlayState()

    /// Extension panel state (0x9D).
    public let extensionPanelState = ExtensionPanelState()

    /// Frontend extension runtime registry for extension-owned decoders and views.
    public let frontendExtensions = FrontendExtensionRuntimeRegistry()

    /// Search toolbar state (0x9E).
    public let searchState = SearchState()

    /// Blocking protocol_error state (0x18). Set when the BEAM rejects this
    /// frontend's handshake protocol_version; drives a full-window error overlay
    /// so a version-mismatched frontend shows an explicit reason instead of a
    /// blank screen (ticket #2237).
    public let protocolErrorState = ProtocolErrorState()

    /// Keystroke-to-present latency HUD state (ticket #2215). Client-local debug
    /// overlay; boots visible when MINGA_LATENCY_HUD=1, toggled from the View menu.
    public let latencyHUDState = LatencyHUDState()

    /// Pending frame-transaction resync hint (#2219 child D). Raised by
    /// CommandDispatcher when a frame is invalidated and a keyframe is requested;
    /// cleared on the next clean commit. Ephemeral: it lives between commits and
    /// never routes through staging.
    public let resyncState = ResyncState()

    /// Semantic window content from gui_window_content (0x80).
    /// Keyed by windowId. NOT cleared between frames; the guiWindowContent
    /// dispatch overwrites per-window data each frame. Stale entries serve
    /// as fallback to prevent blank viewport flashes.
    public var windowContents: [UInt16: GUIWindowContent] = [:]

}
