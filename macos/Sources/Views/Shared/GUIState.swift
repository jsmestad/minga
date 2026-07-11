/// Container for all GUI chrome sub-states.
///
/// Owns the protocol-driven State + View objects behind one observable aggregate
/// publication value. The child states are deliberately non-observable: a frame
/// mutates them while hidden, then swaps `framePublication` exactly once.
/// Injected once into `CommandDispatcher` and `ContentView`, eliminating
/// the 9 optional property wiring that previously required individual
/// assignment in `AppDelegate`.
///
/// All sub-states are initialized at creation time; no optional nil-checks
/// needed in dispatch handlers.
import MingaProtocol
import Observation

/// Immutable observation token published after one complete GUI state transition.
public struct GUIStatePublication: Equatable, Sendable {
    public let generation: UInt64
    public let frameSeq: UInt32?
}

@MainActor
@Observable
public final class GUIState {
    public init(windowContents: [UInt16: GUIWindowContent] = [:]) {
        self.windowContents = windowContents
        feedbackState.onPresentationChanged = { [weak self] in
            self?.performOutOfBandPublication {}
        }
    }

    /// Immutable aggregate token swapped after every complete prepared frame.
    /// Reading this token is the only observation dependency views need for
    /// protocol-driven child state.
    public private(set) var framePublication = GUIStatePublication(generation: 0, frameSeq: nil)

    /// Out-of-band/recovery state has a separate publication stream so rejecting
    /// a frame never masquerades as a committed frame publication.
    public private(set) var outOfBandPublication = GUIStatePublication(generation: 0, frameSeq: nil)

    /// Number of complete prepared frames published since this GUI state was created.
    public var framePublicationCount: UInt64 { framePublication.generation }

    /// Child state cannot notify while this closure runs because protocol-driven
    /// State objects are non-observable. The immutable aggregate swap is therefore
    /// the sole frame observation point.
    public func performFramePublication(frameSeq: UInt32, _ mutation: () -> Void) {
        mutation()
        framePublication = GUIStatePublication(
            generation: framePublication.generation + 1,
            frameSeq: frameSeq
        )
    }

    /// Applies one recovery or local-presentation mutation and publishes it separately from committed frames.
    public func performOutOfBandPublication(_ mutation: () -> Void) {
        mutation()
        outOfBandPublication = GUIStatePublication(
            generation: outOfBandPublication.generation + 1,
            frameSeq: nil
        )
    }

    /// Theme remains Observable because SwiftUI environment injection requires
    /// that conformance. Frame publication replaces the whole instance, so the
    /// published instance is never mutated under active observers.
    @ObservationIgnored public private(set) var themeColors = ThemeColors()

    /// Builds and installs a complete theme value without mutating the observed prior instance.
    public func replaceTheme(slots: [(slotId: UInt8, r: UInt8, g: UInt8, b: UInt8)]) {
        let replacement = ThemeColors()
        replacement.applySlots(slots)
        themeColors = replacement
    }

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
    @ObservationIgnored public var windowContents: [UInt16: GUIWindowContent] = [:]

}
