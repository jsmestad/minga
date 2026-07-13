/// Container for stable protocol-backed GUI state and focused publication inputs.
import MingaProtocol
import Observation

@MainActor
fileprivate final class GUIThemeBacking {
    var current = ThemeColors()
}

@MainActor
fileprivate final class GUIWindowContentBacking {
    var current: [UInt16: GUIWindowContent]

    init(_ current: [UInt16: GUIWindowContent]) {
        self.current = current
    }
}

@MainActor
@Observable
public final class GUIState {
    @ObservationIgnored private let themeBacking = GUIThemeBacking()
    @ObservationIgnored private let windowContentBacking: GUIWindowContentBacking

    public let frameStore = GUIFrameStore()
    public let presentationMetrics = GUIFramePresentationMetrics()

    public init(windowContents: [UInt16: GUIWindowContent] = [:]) {
        windowContentBacking = GUIWindowContentBacking(windowContents)
        feedbackState.onPresentationChanged = { [weak frameStore] in
            frameStore?.publishLocal(impact: .shell) {}
        }
    }

    /// Stable shell-scoped input created and owned by this GUI state.
    @ObservationIgnored public lazy private(set) var shellInput = ShellHostInput(
        theme: themeBacking,
        tabBarState: tabBarState, emptyStateState: emptyStateState,
        workspaceState: workspaceState, sidebarHostState: sidebarHostState,
        fileTreeState: fileTreeState, gitStatusState: gitStatusState,
        observatoryState: observatoryState, breadcrumbState: breadcrumbState,
        statusBarState: statusBarState, feedbackState: feedbackState,
        agentChatState: agentChatState, bottomPanelState: bottomPanelState,
        minibufferState: minibufferState, agentContextBarState: agentContextBarState,
        changeSummaryState: changeSummaryState, editTimelineState: editTimelineState,
        extensionPanelState: extensionPanelState, searchState: searchState
    )

    /// Stable editor-scoped input created and owned by this GUI state.
    @ObservationIgnored public lazy private(set) var editorInput = EditorHostInput(
        theme: themeBacking, windows: windowContentBacking,
        statusBarState: statusBarState, agentChatState: agentChatState,
        emptyStateState: emptyStateState, extensionPanelState: extensionPanelState
    )

    /// Stable editor-overlay-scoped input created and owned by this GUI state.
    @ObservationIgnored public lazy private(set) var editorOverlayInput = EditorOverlayHostInput(
        theme: themeBacking, windows: windowContentBacking,
        completionState: completionState, hoverPopupState: hoverPopupState,
        signatureHelpState: signatureHelpState, extensionOverlayState: extensionOverlayState
    )

    /// Stable window-overlay-scoped input created and owned by this GUI state.
    @ObservationIgnored public lazy private(set) var windowOverlayInput = WindowOverlayHostInput(
        theme: themeBacking, notificationCenterState: notificationCenterState,
        whichKeyState: whichKeyState, pickerState: pickerState,
        bottomPanelState: bottomPanelState, toolManagerState: toolManagerState,
        floatPopupState: floatPopupState, extensionPanelState: extensionPanelState,
        frontendExtensions: frontendExtensions, protocolErrorState: protocolErrorState,
        latencyHUDState: latencyHUDState, resyncState: resyncState
    )

    /// Current theme reference. Replacement is published through all four domains.
    public var themeColors: ThemeColors { themeBacking.current }

    /// Builds and installs a complete theme value without mutating the observed prior instance.
    public func replaceTheme(slots: [(slotId: UInt8, r: UInt8, g: UInt8, b: UInt8)]) {
        let replacement = ThemeColors()
        replacement.applySlots(slots)
        themeBacking.current = replacement
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
    public var windowContents: [UInt16: GUIWindowContent] {
        get { windowContentBacking.current }
        set { windowContentBacking.current = newValue }
    }
}

/// Stable explicit references used only by shell consumers.
@MainActor
public final class ShellHostInput {
    fileprivate let theme: GUIThemeBacking
    public let tabBarState: TabBarState
    public let emptyStateState: EmptyStateState
    public let workspaceState: WorkspaceState
    public let sidebarHostState: SidebarHostState
    public let fileTreeState: FileTreeState
    public let gitStatusState: GitStatusState
    public let observatoryState: ObservatoryState
    public let breadcrumbState: BreadcrumbState
    public let statusBarState: StatusBarState
    public let feedbackState: FeedbackState
    public let agentChatState: AgentChatState
    public let bottomPanelState: BottomPanelState
    public let minibufferState: MinibufferState
    public let agentContextBarState: AgentContextBarState
    public let changeSummaryState: ChangeSummaryState
    public let editTimelineState: EditTimelineState
    public let extensionPanelState: ExtensionPanelState
    public let searchState: SearchState

    public var currentTheme: ThemeColors { theme.current }

    fileprivate init(
        theme: GUIThemeBacking,
        tabBarState: TabBarState, emptyStateState: EmptyStateState,
        workspaceState: WorkspaceState, sidebarHostState: SidebarHostState,
        fileTreeState: FileTreeState, gitStatusState: GitStatusState,
        observatoryState: ObservatoryState, breadcrumbState: BreadcrumbState,
        statusBarState: StatusBarState, feedbackState: FeedbackState,
        agentChatState: AgentChatState, bottomPanelState: BottomPanelState,
        minibufferState: MinibufferState, agentContextBarState: AgentContextBarState,
        changeSummaryState: ChangeSummaryState, editTimelineState: EditTimelineState,
        extensionPanelState: ExtensionPanelState, searchState: SearchState
    ) {
        self.theme = theme
        self.tabBarState = tabBarState
        self.emptyStateState = emptyStateState
        self.workspaceState = workspaceState
        self.sidebarHostState = sidebarHostState
        self.fileTreeState = fileTreeState
        self.gitStatusState = gitStatusState
        self.observatoryState = observatoryState
        self.breadcrumbState = breadcrumbState
        self.statusBarState = statusBarState
        self.feedbackState = feedbackState
        self.agentChatState = agentChatState
        self.bottomPanelState = bottomPanelState
        self.minibufferState = minibufferState
        self.agentContextBarState = agentContextBarState
        self.changeSummaryState = changeSummaryState
        self.editTimelineState = editTimelineState
        self.extensionPanelState = extensionPanelState
        self.searchState = searchState
    }
}

/// Stable explicit references used only by the resident editor surface.
@MainActor
public final class EditorHostInput {
    fileprivate let theme: GUIThemeBacking
    fileprivate let windows: GUIWindowContentBacking
    public let statusBarState: StatusBarState
    public let agentChatState: AgentChatState
    public let emptyStateState: EmptyStateState
    public let extensionPanelState: ExtensionPanelState

    public var currentTheme: ThemeColors { theme.current }
    public var currentWindowContents: [UInt16: GUIWindowContent] { windows.current }
    public func windowContent(for windowID: UInt16) -> GUIWindowContent? { windows.current[windowID] }

    fileprivate init(
        theme: GUIThemeBacking, windows: GUIWindowContentBacking,
        statusBarState: StatusBarState, agentChatState: AgentChatState,
        emptyStateState: EmptyStateState, extensionPanelState: ExtensionPanelState
    ) {
        self.theme = theme
        self.windows = windows
        self.statusBarState = statusBarState
        self.agentChatState = agentChatState
        self.emptyStateState = emptyStateState
        self.extensionPanelState = extensionPanelState
    }
}

/// Stable explicit references used only by editor-anchored overlays.
@MainActor
public final class EditorOverlayHostInput {
    fileprivate let theme: GUIThemeBacking
    fileprivate let windows: GUIWindowContentBacking
    public let completionState: CompletionState
    public let hoverPopupState: HoverPopupState
    public let signatureHelpState: SignatureHelpState
    public let extensionOverlayState: ExtensionOverlayState

    public var currentTheme: ThemeColors { theme.current }
    public func windowContent(for windowID: UInt16) -> GUIWindowContent? { windows.current[windowID] }

    fileprivate init(
        theme: GUIThemeBacking, windows: GUIWindowContentBacking,
        completionState: CompletionState, hoverPopupState: HoverPopupState,
        signatureHelpState: SignatureHelpState, extensionOverlayState: ExtensionOverlayState
    ) {
        self.theme = theme
        self.windows = windows
        self.completionState = completionState
        self.hoverPopupState = hoverPopupState
        self.signatureHelpState = signatureHelpState
        self.extensionOverlayState = extensionOverlayState
    }
}

/// Stable explicit references used only by whole-window overlays.
@MainActor
public final class WindowOverlayHostInput {
    fileprivate let theme: GUIThemeBacking
    public let notificationCenterState: NotificationCenterState
    public let whichKeyState: WhichKeyState
    public let pickerState: PickerState
    public let bottomPanelState: BottomPanelState
    public let toolManagerState: ToolManagerState
    public let floatPopupState: FloatPopupState
    public let extensionPanelState: ExtensionPanelState
    public let frontendExtensions: FrontendExtensionRuntimeRegistry
    public let protocolErrorState: ProtocolErrorState
    public let latencyHUDState: LatencyHUDState
    public let resyncState: ResyncState

    public var currentTheme: ThemeColors { theme.current }

    fileprivate init(
        theme: GUIThemeBacking, notificationCenterState: NotificationCenterState,
        whichKeyState: WhichKeyState, pickerState: PickerState,
        bottomPanelState: BottomPanelState, toolManagerState: ToolManagerState,
        floatPopupState: FloatPopupState, extensionPanelState: ExtensionPanelState,
        frontendExtensions: FrontendExtensionRuntimeRegistry,
        protocolErrorState: ProtocolErrorState, latencyHUDState: LatencyHUDState,
        resyncState: ResyncState
    ) {
        self.theme = theme
        self.notificationCenterState = notificationCenterState
        self.whichKeyState = whichKeyState
        self.pickerState = pickerState
        self.bottomPanelState = bottomPanelState
        self.toolManagerState = toolManagerState
        self.floatPopupState = floatPopupState
        self.extensionPanelState = extensionPanelState
        self.frontendExtensions = frontendExtensions
        self.protocolErrorState = protocolErrorState
        self.latencyHUDState = latencyHUDState
        self.resyncState = resyncState
    }
}
