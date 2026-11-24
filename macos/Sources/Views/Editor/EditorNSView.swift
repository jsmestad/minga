/// MTKView subclass that handles Metal rendering and keyboard/mouse input.
///
/// This is the core editor surface. It receives raw key events and translates
/// them to protocol encoder calls. Rendering is event-driven: BEAM frame
/// updates and scroll events call `setNeedsDisplay(_:)`, and MTKView's
/// built-in display link coalesces them into one GPU frame per vsync.
///
/// Wrapped by EditorView (NSViewRepresentable) for use in SwiftUI.

import MingaUI
import AppKit
import os
import Synchronization
import MetalKit
import MingaProtocol

private enum DividerCursorState: Equatable {
    case none
    case vertical
    case horizontal
}

/// The main editor view. Uses MTKView's built-in display link for
/// vsync-driven rendering with automatic frame coalescing.
final class EditorNSView: MTKView {
    var encoder: OutboundActionEncoding

    /// Command dispatcher owning frame metadata.
    let dispatcher: CommandDispatcher

    /// CoreText-based renderer.
    let coreTextRenderer: CoreTextMetalRenderer

    /// Narrow drawable acquisition seam. Production leaves this nil and uses
    /// MTKView.currentDrawable; tests may inject nil without retaining a drawable.
    var drawableProvider: (() -> CAMetalDrawable?)?

    /// Sole owner of the primary font and per-span font families.
    let fontManager: FontManager

    /// Editor-scoped backing references for semantic content and theme.
    var editorInput: EditorHostInput?

    /// Notifies SwiftUI app state when the NSWindow enters or exits full-screen mode.
    var onFullScreenChanged: ((Bool) -> Void)?

    /// Called when the view moves to a display with a different backing scale factor.
    var onScaleFactorChanged: ((CGFloat) -> Void)?

    /// Notifies SwiftUI of the traffic light vertical center for toolbar alignment.
    var onTrafficLightMeasured: ((CGFloat) -> Void)?

    /// Tracks BEAM responsiveness and handles Ctrl-G recovery.
    var recoveryManager: RecoveryManager?

    private var trackingArea: NSTrackingArea?

    /// Whether the current right-click was consumed by a native context menu.
    private var contextMenuShownForRightClick = false
    private weak var activeContextMenu: NSMenu?

    /// Local input identity and press ownership prevent a gesture started on one
    /// BEAM connection from sending its drag, release, or menu action to another.
    private var inputConnectionGeneration: UInt64 = 0
    private var inputEnabled = true
    private var leftMousePressActive = false
    private var rightMousePressActive = false
    private var middleMousePressActive = false
    private var consumeLeftGestureTail = false
    private var consumeRightGestureTail = false
    private var consumeMiddleGestureTail = false

    /// IME composition state (marked text tracking).
    private var imeComposition = IMEComposition()
    private struct IMECommitTarget: Equatable {
        let connectionGeneration: UInt64
        let windowID: UInt16?
        let contentEpoch: UInt32?
    }
    private var imeCommitTarget: IMECommitTarget?
    private var textInputCallbacksSuppressed = false

    /// Controlled NSTextInputContext seam for native input-routing tests.
    var inputMethodEventHandlerForTesting: ((NSEvent) -> Bool)?

    /// Cell dimensions in points (used for mouse → cell coordinate mapping).
    var cellWidth: CGFloat { fontManager.cellWidth }
    var cellHeight: CGFloat { CGFloat(fontManager.cellHeight) }

    /// Track last reported cell position to avoid flooding the Port with
    /// redundant mouse move events.
    private var lastMoveRow: Int16 = -1
    private var lastMoveCol: Int16 = -1

    /// Gutter hover state used for fold chevron visibility and range highlight.
    private var isMouseInGutter: Bool = false
    private var gutterHoverWindowId: UInt16?
    private var gutterHoverRowIndex: Int?

    /// Current resize cursor pushed for split divider hover or drag.
    private var dividerCursorState: DividerCursorState = .none

    /// Whether the BEAM currently reports a navigable go-to-definition symbol
    /// under the pointer (Cmd+hover, #2630). Drives the pointing-hand cursor.
    private var linkCursorActive = false

    /// Last observed Command-key state, so `flagsChanged` only re-sends a motion
    /// event when Cmd is pressed or released (not for other modifier changes).
    private var lastCommandHeld = false

    /// Divider direction captured at mouse-down so drag keeps the resize cursor.
    private var dividerDragState: DividerCursorState = .none

    /// Text-selection drag tracking. AppKit can report tiny drags during a normal click, so buffer drags only start after the pointer crosses a small native threshold.
    private var leftMouseDownPoint: NSPoint?
    private var textGestureWindows: [UInt8: UInt16] = [:]
    private var lastTextHover: EditorTextTarget?
    private var leftMouseDragStarted: Bool = false
    private let textDragThreshold: CGFloat = 4.0

    /// Whether the ready event has been sent to the BEAM. Deferred until
    /// setFrameSize so we send the actual window dimensions, not hardcoded defaults.
    private var readySent = false

    // MARK: - Live-resize presentation (#2655)

    /// Pending-grid bookkeeping for a live window-edge drag. While a drag is in motion we
    /// keep presenting the last committed frame cropped top-left (the renderer anchors content
    /// in pixel space and fills the grown region with the editor background) and defer the
    /// re-layout to the trailing edge, so the BEAM does one committed re-layout instead of one
    /// per resize event. The state machine is a pure value type for testability; the field is
    /// internal (not private) so integration tests can seed a pending grid and pin the
    /// exactly-once flush behavior of the wiring.
    var resizeBookkeeping = LiveResizeBookkeeping()

    /// Trailing-edge flush scheduled during a live resize. Cancelled/rescheduled on each resize
    /// frame and flushed immediately at `viewDidEndLiveResize`. Structured concurrency (not a
    /// `DispatchWorkItem`) so the closure is provably main-actor isolated (macOS AGENTS.md).
    /// Internal for the same test-seam reason as `resizeBookkeeping`.
    var resizeDebounceTask: Task<Void, Never>?

    private static let resizeDebounceConfig = LiveResizeDebounce.Config.liveResize

    /// Whether macOS has put the displays to sleep. BEAM state may keep changing,
    /// but the Metal surface must not schedule GPU work until screens wake.
    private var isScreenAsleep = false

    /// One coalesced request to redraw the latest committed snapshot after native
    /// presentation capacity becomes available. It deliberately retains no
    /// snapshot, drawable, encoder, or input correlation.
    private(set) var hasPendingCapacityRedraw = false
    private(set) var capacityRetryScheduleCount = 0
    private var pendingCapacityRedrawStartedAt: CFTimeInterval?
    private var capacityRetryTask: Task<Void, Never>?
    private var presentationAvailabilityEpoch: UInt64 = 0

    /// Multiplier applied to system cursor blink timing under thermal or low-power pressure. A value of 0 keeps the cursor solid.
    private var cursorBlinkMultiplier: UInt64 = 1

    /// Last viewport top used for scroll indicator change detection.
    private var lastViewportTopForScroll: CGFloat?

    private struct GridDimensions {
        let cols: UInt16
        /// Content rows-that-fit at the current presentation metrics: one floor of
        /// content pixels by the spaced cell height (ADR-0001). This is the value
        /// reported on the wire and the value the BEAM lays out in; there is no
        /// separate unspaced "raw" row count anymore.
        let rows: UInt16
    }

    /// View-owned AppKit focus and overlay key-routing policy.
    private(set) lazy var focusPolicy = EditorFocusPolicy(editorView: self)

    /// Window currently registered for key/resign notifications.
    private weak var observedWindow: NSWindow?

    /// Chat chrome leaves a transparent aperture over this same input/render surface.
    var agentChatVisible: Bool { focusPolicy.agentOverlayVisible }
    private(set) var agentPromptPlacement: AgentPromptPlacement?
    private var agentPromptPlacementOwner: ObjectIdentifier?
    private var lastPromptFit: OutboundAction?
    private var promptScrollAccumulator = ScrollAccumulator()

    /// Installs discardable physical placement; no draft or responder ownership moves.
    func setAgentPromptPlacement(_ placement: AgentPromptPlacement?, owner: ObjectIdentifier) {
        if placement == nil, agentPromptPlacementOwner != owner { return }
        agentPromptPlacementOwner = placement == nil ? nil : owner
        guard placement != agentPromptPlacement else { return }
        agentPromptPlacement = placement
        layer?.isOpaque = placement == nil && !agentChatVisible
        lastPromptFit = nil
        presentationAvailabilityEpoch &+= 1
        renderFrame()
    }

    private func reportAgentPromptFit(snapshot: CommittedEditorSnapshot) {
        guard let placement = agentPromptPlacement,
              snapshot.surface(for: 65534) != nil,
              let generation = snapshot.metadata.textPresentations[65534],
              let action = placement.fit(cellWidth: cellWidth, rowPitch: cellHeight * CGFloat(snapshot.frameState.lineSpacing), generation: generation),
              action != lastPromptFit else { return }
        if encoder.send(action) == .accepted { lastPromptFit = action }
    }

    /// Border overlay shown during file drag-and-drop hover.
    private var dropHighlightLayer: CAShapeLayer?

    /// Status bar state from the BEAM. Used by the space leader key-chord logic to decide whether SPC is typed text or a leader key.
    var statusBarState: StatusBarState?

    /// Short-lived local prediction that the BEAM is about to enter a text-input mode.
    /// The status bar update is authoritative, but it arrives asynchronously after Vim-normal keys that enter insert-like input.
    /// Without this guard, a fast `i` then `set :` sequence can still see NORMAL on the Swift side and treat the space as a leader chord instead of literal text.
    private var optimisticTextInputMode: Bool = false

    /// Token used to expire stale optimistic text-input predictions without racing newer predictions.
    private var optimisticTextInputModeToken: UInt64 = 0

    /// Maximum time to trust the local text-input prediction if the BEAM has not confirmed it through the status bar yet.
    private let optimisticTextInputModeTimeoutMs: Int = 500

    // MARK: - Space leader key-chord state

    /// Phase 1: SPC keyDown received, within the 30ms grace window.
    /// No space has been sent to the BEAM yet. A chord keyDown in this
    /// state produces a clean leader entry (no flash). A keyUp produces
    /// a clean space (no latency beyond the grace period).
    private var spacePending: Bool = false

    /// Phase 2: grace timer fired, space was sent to the BEAM.
    /// A chord keyDown in this state sends retract_and_enter_leader.
    /// A keyUp just clears the flag (space stays).
    private var spaceKeyDown: Bool = false

    /// Timer for the grace period (30ms). If it fires, we send the space.
    private var spaceGraceTimer: DispatchWorkItem?

    /// Grace period in milliseconds. 30ms is below perceptual threshold for
    /// typing latency but long enough to catch fast key chords.
    private let leaderGraceMs: Int = 30

    // MARK: - Cursor blink

    /// Whether the cursor is currently visible in the blink cycle.
    /// The Metal renderer ANDs this with the committed window content's
    /// `cursorVisible` to determine whether to draw the cursor.
    public private(set) var cursorBlinkVisible: Bool = true

    /// Whether Minga config allows blinking the editor cursor.
    private var cursorBlinkEnabled: Bool = true

    /// The async task driving the blink timer. Cancelled on focus loss,
    /// cursor hide, or dealloc.
    private var blinkTask: Task<Void, Never>?

    /// Task observing accessibility display options changes.
    private var accessibilityTask: Task<Void, Never>?

    /// Stable virtual accessibility elements keyed by core, pane, and buffer lifetime.
    private var accessibilityPaneCache: [EditorAccessibilityIdentity: EditorPaneAccessibilityElement] = [:]
    private let accessibilityFocusedElementSnapshot = AccessibilityFocusedElementSnapshot()
    private var accessibilityProjections: [EditorAccessibilityProjection] = []
    private var accessibilityProjectionKey: AccessibilityProjectionKey?
    private var lastAccessibilityIdentities: Set<EditorAccessibilityIdentity> = []
    private var lastAccessibilitySelections: [EditorAccessibilityIdentity: String] = [:]
    private var lastAccessibilityActiveIdentity: EditorAccessibilityIdentity?

    /// Task observing system scroller style changes.
    private var scrollerStyleTask: Task<Void, Never>?

    var savesFrameInApplicationPreferences = true

    init(encoder: OutboundActionEncoding, dispatcher: CommandDispatcher,
         coreTextRenderer: CoreTextMetalRenderer, fontManager: FontManager,
         reduceMotionEnabled: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        self.encoder = encoder
        self.dispatcher = dispatcher
        self.coreTextRenderer = coreTextRenderer
        self.fontManager = fontManager
        super.init(frame: .zero, device: coreTextRenderer.device)

        // Event-driven rendering: MTKView only calls draw() when we set
        // needsDisplay = true. No continuous 60fps loop burning GPU cycles.
        isPaused = true
        enableSetNeedsDisplay = true

        // The renderer copies a completed offscreen candidate into the drawable
        // only after the candidate render succeeds, so drawable blits must be enabled.
        colorPixelFormat = .bgra8Unorm_srgb
        framebufferOnly = false
        layer?.isOpaque = true
        (layer as? CAMetalLayer)?.maximumDrawableCount = 3

        coreTextRenderer.setCursorAnimationReduceMotionDisabled(reduceMotionEnabled)
        coreTextRenderer.onNativePresentationFailure = { [weak dispatcher] frame, outcome in
            dispatcher?.nativePresentationFailed(frame: frame, outcome: outcome)
        }
        coreTextRenderer.onPresentationCapacityAvailable = { [weak self] in
            self?.schedulePendingCapacityRedraw()
        }
        scrollAnimationsReduceMotionDisabled = reduceMotionEnabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Not implemented") }

    /// Cleans up blink timer and accessibility observer.
    /// Called from viewDidMoveToWindow when window is nil (view removed).
    private func cleanupBlinkResources() {
        blinkTask?.cancel()
        blinkTask = nil
        accessibilityTask?.cancel()
        accessibilityTask = nil
    }

    /// Cleans up window-bound observers and monitors.
    private func cleanupWindowResources() {
        invalidatePresentationAvailability()
        cancelPendingCapacityRedraw()
        dispatcher.discardPendingPresentation(reason: .hidden)
        cleanupBlinkResources()
        cancelThumbDragWithFlush()
        resetSmoothScrollState()
        scrollerStyleTask?.cancel()
        scrollerStyleTask = nil
        scrollFadeTask?.cancel()
        scrollFadeTask = nil
        scrollIndicatorDragOffset = nil
        scrollIndicatorTarget = nil
        isDraggingScrollIndicator = false
        spaceGraceTimer?.cancel()
        spaceGraceTimer = nil
        cancelResizeFlushTask()
        // Unlike the thumb drag above (always flushed), a pending resize is deliberately
        // discarded here: the window is being torn down, so there is no surface left for
        // the BEAM to lay out.
        resizeBookkeeping = LiveResizeBookkeeping()
        dividerDragState = .none
        setDividerCursorState(.none)
        removeWindowObservers()
        focusPolicy.detach()
        accessibilityFocusedElementSnapshot.write(nil)
    }

    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if agentChatVisible || agentPromptPlacement != nil {
            let local = convert(point, from: superview)
            guard let pane = editorPresentation?.textLayout?.panes.first(where: { $0.windowID == 65534 }),
                  pane.rect.contains(local) else { return nil }
        }
        return super.hitTest(point)
    }
    override var isFlipped: Bool { true }

    // MARK: - Cursor blink control

    /// Resets the cursor to visible and restarts the blink cycle.
    /// Called on keystrokes, cursor movement, and focus gain.
    func resetCursorBlink() {
        blinkTask?.cancel()
        cursorBlinkVisible = true

        guard !isScreenAsleep else { return }
        guard cursorBlinkEnabled else { return }

        // Don't blink when Accessibility > Reduce Motion is on.
        guard !SystemBlinkTiming.blinkingDisabled else { return }

        // A multiplier of 0 means resource pressure has disabled cursor blinking.
        guard cursorBlinkMultiplier > 0 else { return }

        let timing = SystemBlinkTiming.system.scaled(by: cursorBlinkMultiplier)

        // If on-period is 0, the user has disabled cursor blink system-wide.
        guard timing.onDuration > 0 else { return }

        blinkTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: timing.onDuration)
                guard !Task.isCancelled else { break }
                self?.cursorBlinkVisible = false
                self?.needsDisplay = true
                try? await Task.sleep(nanoseconds: timing.offDuration)
                guard !Task.isCancelled else { break }
                self?.cursorBlinkVisible = true
                self?.needsDisplay = true
            }
        }
    }

    /// Enables or disables editor cursor blinking from Minga config.
    func setCursorBlinkEnabled(_ enabled: Bool) {
        cursorBlinkEnabled = enabled
        if enabled {
            resetCursorBlink()
        } else {
            stopCursorBlink()
        }
    }

    /// Stops the blink timer and shows the cursor as solid.
    /// Called on focus loss and when the cursor is hidden (minibuffer active).
    func stopCursorBlink() {
        blinkTask?.cancel()
        cursorBlinkVisible = true
        guard !isScreenAsleep else { return }
        needsDisplay = true
    }

    /// Pauses Metal rendering and cursor blinking while the screens are asleep.
    func pauseForScreenSleep() {
        isScreenAsleep = true
        dispatcher.discardPendingPresentation(reason: .screenSleep)
        blinkTask?.cancel()
        cursorBlinkVisible = true
    }

    /// Resumes Metal rendering after screen wake and forces one fresh frame.
    func resumeAfterScreenWake() {
        isScreenAsleep = false
        resetCursorBlink()
        renderFrame()
    }

    /// Applies the current macOS low power and thermal policy to cursor blinking.
    func applyPowerThermalPolicy(lowPowerMode: Bool, thermalState: ProcessInfo.ThermalState) {
        let policy = PowerThermalPolicy.policy(lowPowerMode: lowPowerMode, thermalState: thermalState)
        cursorBlinkMultiplier = policy.cursorBlinkMultiplier
        resetCursorBlink()
        renderFrame()
    }

    /// Starts observing Accessibility display option changes so the blink
    /// timer responds to live Reduce Motion toggles. Idempotent: only
    /// registers once (guards against repeated viewDidMoveToWindow calls).
    private func observeAccessibilityChanges() {
        guard accessibilityTask == nil else { return }
        accessibilityTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) {
                guard let self else { return }
                let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                self.coreTextRenderer.setCursorAnimationReduceMotionDisabled(reduceMotion)
                self.scrollAnimationsReduceMotionDisabled = reduceMotion
                if reduceMotion {
                    // Snap any in-flight presentation scroll animation straight to the grid. A
                    // thumb drag held across the toggle is discarded with its final target flushed
                    // so the dragged position is never silently dropped (Critical 2, policy b).
                    self.cancelThumbDragWithFlush()
                    self.resetSmoothScrollState()
                }
                if SystemBlinkTiming.blinkingDisabled {
                    self.stopCursorBlink()
                } else {
                    self.resetCursorBlink()
                }
            }
        }
    }

    // MARK: - Rendering

    /// Presentation offset from the committed anchor. Positive shifts content up/left.
    private var scrollPixelOffset = CGPoint(x: 0, y: 0)

    /// Client-only boundary elasticity applied when the target pane is already
    /// at the top or bottom of the committed overscan range.
    private var scrollElasticOffsetY: CGFloat = 0

    /// Raw accumulated overscroll pull (px) feeding the asymptotic rubber-band curve (AC2).
    private var scrollElasticRawDistance: CGFloat = 0

    /// Presentation-only decay of the residual sub-line offset toward the grid.
    /// Drives the AC1 gesture-end settle and the AC3 eased discrete-wheel tick.
    private var scrollSettleAnimator = PresentationScrollAnimator()

    /// Presentation-only spring-back of the rubber-band elastic offset on release (AC2).
    private var scrollElasticAnimator = PresentationScrollAnimator()

    /// Window whose committed anchor the settle/discrete animation reconciles against.
    /// Distinct from `scrollTargetWindowId`: it outlives the live gesture so the momentum-end
    /// settle can keep unconfirmed-line compensation stable while the BEAM's anchor eases
    /// forward, eliminating the back-then-forward stutter (AC1).
    private var scrollSettleWindowId: UInt16?

    /// Window whose rubber-band spring-back (AC2) is in flight. Like `scrollSettleWindowId`, it
    /// outlives the live gesture so the renderer keeps applying the elastic offset to that pane
    /// after `scrollTargetWindowId` has been released.
    private var scrollElasticWindowId: UInt16?

    /// One immutable snapshot of the pane and effective offset used by both drawing and pointer normalization.
    typealias LocalScrollPresentation = EditorLocalPresentationTransform

    /// The editor presentation visible to interaction and accessibility code. Metal promotes the exact presentation after presentation; committed-but-unpresented values are draw inputs only.
    private var editorPresentation: VisibleEditorPresentation? {
        dispatcher.visibleEditorPresentation
    }

    /// The editor snapshot visible to interaction and accessibility code. Metal promotes the exact snapshot after presentation; committed-but-unpresented snapshots are draw inputs only.
    private var editorPresentationSnapshot: CommittedEditorSnapshot? {
        editorPresentation?.snapshot
    }

    private var visibleLocalScrollPresentation: LocalScrollPresentation? {
        editorPresentation?.localTransform
    }

    private func interactionContent(windowId: UInt16) -> GUIWindowContent? {
        editorPresentationSnapshot?.content(for: windowId)
    }

    /// The local scroll presentation for this frame or input event.
    /// Decouples "which window shows the offset" from "a gesture is active": during a settle or
    /// spring-back the gesture target is nil,
    /// but the offset must still land on the settling/elastic pane.
    private var localScrollPresentation: LocalScrollPresentation? {
        let presentation = Self.localScrollPresentation(
            targetWindowId: scrollTargetWindowId,
            thumbDragWindowId: thumbDragSession?.windowId,
            settleWindowId: scrollSettleWindowId ?? scrollHorizontalWindowId,
            elasticWindowId: scrollElasticWindowId,
            scrollPixelOffset: scrollPixelOffset,
            scrollElasticOffsetY: scrollElasticOffsetY
        )
        guard let presentation, presentation.offset.x != 0,
              isSelectionDragActive || presentation.windowId != scrollHorizontalWindowId else { return presentation }
        return LocalScrollPresentation(windowId: presentation.windowId, offset: CGPoint(x: 0, y: presentation.offset.y))
    }

    /// Resolves the pane that owns the presentation offset, preferring the live trackpad
    /// gesture target, then the thumb-drag pane, then the settling window, then the elastic
    /// spring-back window. Trackpad and thumb-drag are mutually exclusive (a thumb drag holds
    /// the mouse button, a trackpad gesture does not), so their order relative to each other is
    /// immaterial; both must win over settle/elastic. Pure for testability.
    nonisolated static func presentationScrollWindowId(targetWindowId: UInt16?, thumbDragWindowId: UInt16?, settleWindowId: UInt16?, elasticWindowId: UInt16?) -> UInt16? {
        targetWindowId ?? thumbDragWindowId ?? settleWindowId ?? elasticWindowId
    }

    /// Resolves the exact owner and effective offset shared by drawing and pointer normalization.
    nonisolated static func localScrollPresentation(
        targetWindowId: UInt16?,
        thumbDragWindowId: UInt16?,
        settleWindowId: UInt16?,
        elasticWindowId: UInt16?,
        scrollPixelOffset: CGPoint,
        scrollElasticOffsetY: CGFloat
    ) -> LocalScrollPresentation? {
        guard let windowId = presentationScrollWindowId(
            targetWindowId: targetWindowId,
            thumbDragWindowId: thumbDragWindowId,
            settleWindowId: settleWindowId,
            elasticWindowId: elasticWindowId
        ) else { return nil }
        let elasticOffsetY = elasticWindowId == windowId ? scrollElasticOffsetY : 0
        return LocalScrollPresentation(
            windowId: windowId,
            offset: CGPoint(x: scrollPixelOffset.x, y: scrollPixelOffset.y + elasticOffsetY)
        )
    }

    /// System Reduce Motion state, which disables all presentation scroll animations (AC4).
    private var scrollAnimationsReduceMotionDisabled = false

    /// Whether presentation scroll animations may run. Mirrors the cursor-animation
    /// accessibility check: Reduce Motion turns every animation into an instant snap.
    private var scrollAnimateEnabled: Bool { !scrollAnimationsReduceMotionDisabled }

    /// Gesture-end settle duration (AC1): roughly 80-120ms per the acceptance criteria.
    private static let scrollSettleDuration: CFTimeInterval = 0.10
    /// Rubber-band spring-back duration on release (AC2).
    private static let scrollElasticSpringBackDuration: CFTimeInterval = 0.35
    /// Eased discrete-wheel tick duration (AC3).
    private static let scrollDiscreteTickDuration: CFTimeInterval = 0.12
    /// Rubber-band asymptote, in cells (AC2: about 3-4 cells of pull).
    private static let scrollElasticLimitCells: CGFloat = 3.5

    /// Window receiving the current fractional smooth-scroll offset.
    /// Nil means the event location did not resolve to a scrollable editor window, so fractional offset is disabled instead of shifting every pane.
    private var scrollTargetWindowId: UInt16?

    /// Active scrollbar thumb-drag over a resident pane (#2665), or nil. The session is the single
    /// owner of the drag's gate, target, throttle bookkeeping, release baselines, and reconcile
    /// watchdog; this view only translates its per-frame `Outcome` into encoder sends, the
    /// presentation offset, and redraw scheduling. Non-nil only for a resident pane: windowed panes
    /// keep the round-trip `sendScrollToLine` path (`thumbDragSession` stays nil). It outlives the
    /// button-held phase until the BEAM's echo-marked commit reaches the target or an authoritative interrupt or watchdog fires.
    private var thumbDragSession: ThumbDragSession?
    /// The pane and coordinate basis at press, not the lease (which follows the display).
    private struct ScrollIndicatorTarget {
        let windowID: UInt16
        let generation: UInt64
        let visualBasis: ThumbDragSession.Committed?
    }
    private var scrollIndicatorTarget: ScrollIndicatorTarget?

    /// Input routing survives finger lift even when the live transform has started settling.
    private struct TrackpadGesture {
        enum Axis { case undecided, vertical, horizontal }

        let windowId: UInt16?
        var fingersLifted = false
        private(set) var axis: Axis = .undecided
        private var travel = CGPoint.zero
        private var signedMotion = CGPoint.zero

        init(windowId: UInt16?) {
            self.windowId = windowId
        }

        mutating func lockDeltas(x: CGFloat, y: CGFloat) -> CGPoint {
            if axis == .undecided {
                travel.x += abs(x)
                travel.y += abs(y)
                signedMotion.x += x
                signedMotion.y += y
                guard max(travel.x, travel.y) >= 4 else { return .zero }
                axis = travel.y >= travel.x ? .vertical : .horizontal
                return axis == .vertical ? CGPoint(x: 0, y: signedMotion.y) : CGPoint(x: signedMotion.x, y: 0)
            }
            return axis == .vertical ? CGPoint(x: 0, y: y) : CGPoint(x: x, y: 0)
        }
    }

    private var trackpadGesture: TrackpadGesture?
    private var scrollHorizontalWindowId: UInt16?
    /// Pane switches change the visual owner, not the accepted input still awaiting an echo.
    private var pendingHorizontalPans: [UInt16: HorizontalScrollPrediction] = [:]
    /// Highest acknowledged or locally accepted sequence, retained across prediction resets.
    private var horizontalPanSequence: UInt32 = 0
    private var scrollHorizontalAnimator = PresentationScrollAnimator()

    private var scrollUnconfirmedLines: Int = 0
    /// Absolute visual rank for wrapped residence, logical top otherwise.
    private var scrollLastConfirmedAnchor: UInt32?
    /// A reversal can return to the committed rank before either leg has echoed.
    /// Keep reconciling until the turning rank is observed or the basis is reset.
    private var scrollWrappedTurningRank: UInt32?

    /// Schedule a render on the next vsync. Multiple calls between vsyncs
    /// are coalesced by MTKView into a single draw() call.
    func renderFrame() {
        guard !isScreenAsleep else { return }
        needsDisplay = true
    }

    /// Discards every local interaction tied to the replaced BEAM and disables input.
    func invalidateConnection() {
        invalidatePresentationAvailability()
        cancelPendingCapacityRedraw()
        self.encoder = ClosureOutboundActionEncoder { _ in .rejected(.disconnected) }
        inputEnabled = false
        readySent = false
        inputConnectionGeneration &+= 1
        horizontalPanSequence = 0
        pendingHorizontalPans.removeAll()
        textGestureWindows = [:]
        lastTextHover = nil
        invalidateAccessibilityConnection()
        consumeLeftGestureTail = consumeLeftGestureTail || leftMousePressActive || leftMouseDownPoint != nil || isDraggingScrollIndicator
        consumeRightGestureTail = consumeRightGestureTail || rightMousePressActive || contextMenuShownForRightClick
        consumeMiddleGestureTail = consumeMiddleGestureTail || middleMousePressActive
        leftMousePressActive = false
        rightMousePressActive = false
        middleMousePressActive = false
        activeContextMenu?.cancelTracking()
        activeContextMenu = nil
        contextMenuShownForRightClick = false
        cancelIMEComposition()
        lastMoveRow = -1
        lastMoveCol = -1
        isMouseInGutter = false
        gutterHoverWindowId = nil
        gutterHoverRowIndex = nil
        leftMouseDownPoint = nil
        leftMouseDragStarted = false
        thumbDragSession = nil
        scrollIndicatorTarget = nil
        isDraggingScrollIndicator = false
        scrollIndicatorDragOffset = nil
        hardResetSmoothScroll()
        cancelSpaceGrace()
        spacePending = false
        spaceKeyDown = false
        lastCommandHeld = false
        clearOptimisticTextInputMode()
        cancelResizeFlushTask()
        resizeBookkeeping = LiveResizeBookkeeping()
        dividerDragState = .none
        setDividerCursorState(.none)
        setLinkCursorActive(false)
        hideDropHighlight()
    }

    /// Enables input only after replacement transport construction succeeds.
    func installConnectionEncoder(_ encoder: OutboundActionEncoding) {
        self.encoder = encoder
        inputEnabled = true
    }

    /// Atomically replaces the input connection for callers that already own a valid encoder.
    func replaceConnection(encoder: OutboundActionEncoding) {
        invalidateConnection()
        installConnectionEncoder(encoder)
    }

    /// Previous cursor position for accessibility change detection.
    private var lastAccessibilityCursorRow: UInt16 = 0
    private var lastAccessibilityCursorCol: UInt16 = 0

    /// Called by MTKView's display link at vsync when needsDisplay is true.
    override func draw(_ dirtyRect: NSRect) {
        // Reject known non-presentable states before claiming an input sequence.
        // The renderer acquires a drawable only after its offscreen candidate completes.
        if let reason = presentationPreflightDiscardReason() {
            handlePresentationPreflightFailure(reason)
            return
        }
        let scale = Float(window?.backingScaleFactor ?? 2.0)

        guard let committedSnapshot = dispatcher.committedEditorSnapshot else {
            dispatcher.discardPendingPresentation(reason: .hidden)
            return
        }
        reportAgentPromptFit(snapshot: committedSnapshot)
        let promptPlacement = agentPromptPlacement

        let localScrollPresentation = prepareLocalScrollPresentationForDraw(committedSnapshot: committedSnapshot)
        if !isDraggingScrollIndicator {
            let metrics = committedSnapshot.activeSurface.flatMap {
                EditorScrollTrack.metrics(
                    surface: $0,
                    localTransform: localScrollPresentation,
                    rowPitch: cellHeight * CGFloat(committedSnapshot.frameState.lineSpacing)
                )
            }
            let top = metrics.flatMap { $0.canScroll ? $0.displayedTop : nil }
            if top != lastViewportTopForScroll {
                lastViewportTopForScroll = top
                if top != nil { flashScrollIndicator() }
            }
        }
        let validGutterHoverWindowId = gutterHoverWindowId.flatMap { windowId in
            committedSnapshot.windowIds.contains(windowId) ? windowId : nil
        }
        let validGutterHoverRowIndex = validGutterHoverWindowId == nil ? nil : gutterHoverRowIndex
        let validMouseInGutter = isMouseInGutter && validGutterHoverWindowId != nil
        let cursorAnimationGeneration = coreTextRenderer.cursorAnimationGeneration
        let presentationInputSeq = dispatcher.capturePresentationInputSeq()
        let connectionID = dispatcher.connectionID
        let presentationAvailabilityEpoch = presentationAvailabilityEpoch
        let textAttempt = dispatcher.textPresentationLeases.beginAttempt(committedSnapshot)
        let submissionOutcome = coreTextRenderer.render(
            snapshot: committedSnapshot,
            fontManager: fontManager,
            cursorBlinkVisible: cursorBlinkVisible,
            isMouseInGutter: validMouseInGutter,
            gutterHoverWindowId: validGutterHoverWindowId,
            gutterHoverRowIndex: validGutterHoverRowIndex,
            drawableProvider: { [weak self] in
                guard let self else { return nil }
                if let drawableProvider = self.drawableProvider {
                    return drawableProvider()
                }
                return self.currentDrawable
            },
            viewportSize: drawableSize,
            contentScale: scale,
            scrollOffset: SIMD2<Float>(
                Float(localScrollPresentation?.offset.x ?? 0),
                Float(localScrollPresentation?.offset.y ?? 0)
            ),
            presentationWindowId: localScrollPresentation?.windowId,
            promptPlacement: promptPlacement,
            agentPromptVisible: agentChatVisible,
            presentationInputSeq: presentationInputSeq,
            latencyRecorder: dispatcher.latency,
            connectionID: connectionID,
            isPresentationCurrent: { [weak self, weak dispatcher] in
                guard let self, let dispatcher else { return false }
                return dispatcher.isCurrentConnection(connectionID) &&
                    self.presentationAvailabilityEpoch == presentationAvailabilityEpoch &&
                    self.presentationPreflightDiscardReason() == nil
            },
            onAttemptFinished: { [weak dispatcher] in
                guard let dispatcher, dispatcher.isCurrentConnection(connectionID) else { return }
                dispatcher.textPresentationLeases.finishAttempt(textAttempt)
            },
            onTextPresented: { [weak self, localScrollPresentation] snapshot, textLayout in
                self?.promotePresentedSnapshot(
                    snapshot,
                    localScrollPresentation: localScrollPresentation,
                    textLayout: textLayout,
                    connectionID: connectionID
                )
            }
        )
        handleSubmissionOutcome(submissionOutcome, presentationInputSeq: presentationInputSeq)
        if coreTextRenderer.cursorAnimationGeneration != cursorAnimationGeneration {
            resetCursorBlink()
        }
        if coreTextRenderer.cursorAnimating, submissionOutcome != .deferredCapacity {
            needsDisplay = true
        }
        os_signpost(.event, log: renderLog, name: "DrawComplete")
    }

    private func handleSubmissionOutcome(
        _ outcome: NativeRenderSubmissionOutcome,
        presentationInputSeq: UInt32
    ) {
        switch outcome {
        case .submitted:
            dispatcher.acknowledgePresentationSubmission(inputSeq: presentationInputSeq)
            cancelPendingCapacityRedraw()
        case .deferredCapacity:
            retainPendingCapacityRedraw()
        case .failed:
            cancelPendingCapacityRedraw()
        }
    }

    private func retainPendingCapacityRedraw() {
        guard !hasPendingCapacityRedraw else { return }
        hasPendingCapacityRedraw = true
        pendingCapacityRedrawStartedAt = CACurrentMediaTime()
    }

    private func schedulePendingCapacityRedraw() {
        guard hasPendingCapacityRedraw, capacityRetryTask == nil else { return }
        if let reason = presentationPreflightDiscardReason() {
            if reason != .occluded { cancelPendingCapacityRedraw() }
            return
        }
        let connectionID = dispatcher.connectionID
        capacityRetryTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.capacityRetryTask = nil
            guard self.hasPendingCapacityRedraw,
                  self.dispatcher.isCurrentConnection(connectionID),
                  self.presentationPreflightDiscardReason() == nil else { return }
            let waitMilliseconds = self.pendingCapacityRedrawStartedAt.map {
                (CACurrentMediaTime() - $0) * 1_000
            } ?? 0
            os_signpost(.event, log: renderLog, name: "DeferredNativeRedraw",
                        "main_actor_wait_ms=%{public}.3f pending_redraw_count=1", waitMilliseconds)
            self.capacityRetryScheduleCount += 1
            self.renderFrame()
        }
    }

    private func cancelPendingCapacityRedraw() {
        capacityRetryTask?.cancel()
        capacityRetryTask = nil
        hasPendingCapacityRedraw = false
        pendingCapacityRedrawStartedAt = nil
    }

    private func invalidatePresentationAvailability() {
        presentationAvailabilityEpoch &+= 1
    }

    var hasCapacityRetryTaskForTesting: Bool { capacityRetryTask != nil }
    var inFlightNativePresentationCountForTesting: Int { coreTextRenderer.inFlightPresentationCount }

    private func promotePresentedSnapshot(
        _ snapshot: CommittedEditorSnapshot,
        localScrollPresentation: LocalScrollPresentation?,
        textLayout: PresentedTextLayout,
        connectionID: UInt64
    ) {
        guard dispatcher.isCurrentConnection(connectionID) else { return }
        dispatcher.promoteVisibleEditorPresentation(
            snapshot: snapshot,
            localTransform: localScrollPresentation,
            textLayout: textLayout,
            connectionID: connectionID
        )
        cancelIMECompositionIfTargetChanged()
        publishAccessibilityPresentationChanges()
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.dispatcher.resolvePresentedOperation(
                snapshot: snapshot,
                focusReady: self.focusPolicy.presentationFocusReady(),
                connectionID: connectionID
            )
        }
        let cursor = snapshot.activeSurface.map { ($0.content.cursorRow, $0.content.cursorCol) } ?? (0, 0)
        if cursor.0 != lastAccessibilityCursorRow || cursor.1 != lastAccessibilityCursorCol {
            lastAccessibilityCursorRow = cursor.0
            lastAccessibilityCursorCol = cursor.1
            resetCursorBlink()
        }
    }

    /// Reconciles every local scroll transform against the exact committed snapshot rendered by
    /// this draw. Interaction remains bound to the last presented snapshot; only render-local
    /// prediction consumes committed-but-unpresented scroll acknowledgements.
    private func prepareLocalScrollPresentationForDraw(committedSnapshot: CommittedEditorSnapshot) -> LocalScrollPresentation? {
        clearSmoothScrollStateIfTargetWindowMissing(in: committedSnapshot)
        advancePresentationScrollAnimation(snapshot: committedSnapshot)
        advanceThumbDragPresentation(committedSnapshot: committedSnapshot)
        return localScrollPresentation
    }

    private func currentGridDimensions() -> GridDimensions {
        gridDimensions(width: frame.width, height: frame.height)
    }

    private func gridDimensions(width: CGFloat, height: CGFloat, cellWidth: CGFloat? = nil, cellHeight: CGFloat? = nil) -> GridDimensions {
        let resolvedCellWidth = cellWidth ?? self.cellWidth
        let resolvedCellHeight = cellHeight ?? self.cellHeight
        guard resolvedCellWidth > 0, resolvedCellHeight > 0 else {
            return GridDimensions(cols: 1, rows: 1)
        }

        let gutterPad: CGFloat = (dispatcher.committedEditorSnapshot?.gutterCol ?? 0) > 0 ? CoreTextMetalRenderer.gutterPixelPaddingPt : 0
        let cols = UInt16(max((width - gutterPad) / resolvedCellWidth, 1))
        let rows = rowsThatFit(height: height, cellHeight: resolvedCellHeight, lineSpacing: dispatcher.frameState.lineSpacing)
        return GridDimensions(cols: cols, rows: rows)
    }

    /// The one and only row-fit floor (ADR-0001): content pixels divided by the
    /// spaced cell height, floored once, in the layer that owns the pixels. The
    /// BEAM consumes this verbatim and never re-derives a row count from spacing.
    private func rowsThatFit(height: CGFloat, cellHeight: CGFloat, lineSpacing: Float) -> UInt16 {
        let spacedCellHeight = cellHeight * CGFloat(max(lineSpacing, 1.0))
        return UInt16(max(floor(height / spacedCellHeight), 1))
    }

    // MARK: - Font update

    /// Called after FontManager applies a set_font command or display scale change.
    /// Resizes the grid from the manager-owned metrics and requests a fresh frame.
    func fontConfigurationChanged(metricsChanged: Bool) {
        guard metricsChanged else {
            renderFrame()
            return
        }

        let newCellW = fontManager.cellWidth
        let newCellH = CGFloat(fontManager.cellHeight)
        guard newCellW > 0, newCellH > 0 else { return }

        let grid = gridDimensions(width: frame.width, height: frame.height, cellWidth: newCellW, cellHeight: newCellH)

        if grid.cols != dispatcher.frameState.cols || grid.rows != dispatcher.frameState.rows {
            dispatcher.applyViewportResize(newCols: grid.cols, newRows: grid.rows)
            encoder.send(.resize(cols: grid.cols, rows: grid.rows))
        }

        // Force a full re-render.
        renderFrame()
    }

    // MARK: - Window lifecycle

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            cleanupWindowResources()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = window else {
            cleanupWindowResources()
            return
        }

        // Correct the startup scale immediately when the window lands on a display different from NSScreen.main. The first setFrameSize call still owns the initial ready event.
        displayConfigurationChanged(newScale: window.backingScaleFactor, sendDimensions: false)

        // Restore window position and size from previous session.
        // This fires before the window is made key/visible, so the
        // saved frame is applied without a visible position jump.
        if savesFrameInApplicationPreferences {
            window.setFrameAutosaveName("MingaEditorWindow")
        }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)

        measureTrafficLightPosition(in: window)
        installWindowObserversIfNeeded(for: window)
        focusPolicy.attach(to: window)

        registerForDraggedTypes([.fileURL])

        updateTrackingArea()
        observeScrollerStyle()
        observeAccessibilityChanges()
        resetCursorBlink()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let window else { return }
        displayConfigurationChanged(newScale: window.backingScaleFactor)
    }

    override func viewDidHide() {
        super.viewDidHide()
        invalidatePresentationAvailability()
        cancelPendingCapacityRedraw()
        dispatcher.discardPendingPresentation(reason: .hidden)
    }

    /// Applies a live display configuration update to the Metal surface.
    func displayConfigurationChanged(newScale: CGFloat, forceResizeEvent: Bool = false, sendDimensions: Bool = true) {
        updateMetalBackingScale(newScale)
        let scaleChanged = abs(fontManager.scale - newScale) > 0.001

        if sendDimensions && (scaleChanged || forceResizeEvent) {
            sendCurrentGridSize(reason: "Display configuration changed")
        }

        if scaleChanged {
            onScaleFactorChanged?(newScale)
        } else if forceResizeEvent {
            renderFrame()
        }
    }

    /// Updates CAMetalLayer and drawable sizing to match the current display scale.
    private func updateMetalBackingScale(_ scale: CGFloat) {
        (layer as? CAMetalLayer)?.contentsScale = scale

        let pixelWidth = bounds.width * scale
        let pixelHeight = bounds.height * scale
        guard pixelWidth > 0, pixelHeight > 0 else { return }
        drawableSize = CGSize(width: pixelWidth, height: pixelHeight)
    }

    /// Sends ready once when a replacement connects after the window already has dimensions.
    func announceReadyIfLaidOut() {
        guard !readySent else { return }
        sendCurrentGridSize(reason: "Window ready")
    }

    /// Sends the current grid dimensions to the BEAM after an external display change.
    private func sendCurrentGridSize(reason: String) {
        guard frame.width > 0, frame.height > 0 else { return }
        guard inputEnabled else { return }

        let grid = currentGridDimensions()
        dispatcher.applyViewportResize(newCols: grid.cols, newRows: grid.rows)

        if readySent {
            encoder.send(.resize(cols: grid.cols, rows: grid.rows))
        } else {
            readySent = true
            encoder.send(.ready(cols: grid.cols, rows: grid.rows))
        }

        PortLogger.info("\(reason): \(grid.cols)x\(grid.rows) rows")
    }

    private func measureTrafficLightPosition(in window: NSWindow) {
        guard let closeButton = window.standardWindowButton(.closeButton),
              let titleBarView = closeButton.superview else { return }
        let buttonInTitleBar = closeButton.frame
        let titleBarHeight = titleBarView.frame.height
        let topDownMidY = titleBarHeight - buttonInTitleBar.midY
        onTrafficLightMeasured?(topDownMidY)
    }

    /// Registers for key-window notifications exactly once per window.
    private func installWindowObserversIfNeeded(for window: NSWindow) {
        guard observedWindow !== window else { return }

        removeWindowObservers()
        observedWindow = window

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidEnterFullScreen),
            name: NSWindow.didEnterFullScreenNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidExitFullScreen),
            name: NSWindow.didExitFullScreenNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowPresentationAvailabilityDidChange),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowPresentationAvailabilityDidChange),
            name: NSWindow.didMiniaturizeNotification,
            object: window
        )
        onFullScreenChanged?(window.styleMask.contains(.fullScreen))

    }

    /// Removes key-window notifications from the previously observed window.
    private func removeWindowObservers() {
        guard let observedWindow else { return }
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didBecomeKeyNotification,
            object: observedWindow
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didResignKeyNotification,
            object: observedWindow
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didEnterFullScreenNotification,
            object: observedWindow
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didExitFullScreenNotification,
            object: observedWindow
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didChangeOcclusionStateNotification,
            object: observedWindow
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didMiniaturizeNotification,
            object: observedWindow
        )
        onFullScreenChanged?(false)
        self.observedWindow = nil
    }

    /// Notifies the AppKit focus owner that SwiftUI updated the hosted editor view.
    func swiftUIUpdateDidOccur() {
        focusPolicy.swiftUIUpdateDidOccur()
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        focusPolicy.windowDidBecomeKey()
        refreshAccessibilityNativeFocus()
        resetCursorBlink()
    }

    @objc private func windowDidEnterFullScreen(_ notification: Notification) {
        onFullScreenChanged?(true)
    }

    @objc private func windowDidExitFullScreen(_ notification: Notification) {
        onFullScreenChanged?(false)
        if let window { measureTrafficLightPosition(in: window) }
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        refreshAccessibilityNativeFocus()
        stopCursorBlink()
        // The window lost key while the thumb may still be held (system modal, Cmd-Tab, Mission
        // Control): no mouseUp is guaranteed, so discard the drag with its final target flushed
        // rather than leave the reconcile gate stuck open (Critical 1b / Critical 2, policy b).
        cancelThumbDragWithFlush()
    }

    @objc private func windowPresentationAvailabilityDidChange(_ notification: Notification) {
        if let reason = presentationPreflightDiscardReason() {
            handlePresentationPreflightFailure(reason)
        } else {
            renderFrame()
        }
    }

    private func handlePresentationPreflightFailure(_ reason: LatencyRecorder.DiscardReason) {
        invalidatePresentationAvailability()
        if reason == .occluded {
            dispatcher.deferOccludedPresentation()
        } else {
            cancelPendingCapacityRedraw()
            dispatcher.discardPendingPresentation(reason: reason)
        }
    }

    private func presentationPreflightDiscardReason() -> LatencyRecorder.DiscardReason? {
        let hidden = isHiddenOrHasHiddenAncestor || window?.isVisible == false || window?.isMiniaturized == true
        let occluded = window.map { !$0.occlusionState.contains(.visible) } ?? false
        return PresentationSamplePreflight.discardReason(
            screenAsleep: isScreenAsleep, hidden: hidden, occluded: occluded
        )
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            refreshAccessibilityNativeFocus()
            resetCursorBlink()
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        cancelIMEComposition()
        let result = super.resignFirstResponder()
        if result {
            clearAccessibilityNativeFocus()
            stopCursorBlink()
        }
        return result
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)

        guard inputEnabled, newSize.width > 0, newSize.height > 0 else { return }

        let grid = gridDimensions(width: newSize.width, height: newSize.height)

        if !readySent {
            // First real frame size: send the ready event with actual
            // window dimensions so the BEAM never sees wrong defaults.
            readySent = true
            dispatcher.applyViewportResize(newCols: grid.cols, newRows: grid.rows)
            encoder.send(.ready(cols: grid.cols, rows: grid.rows))
            os_signpost(.event, log: startupLog, name: "ReadySent", "%{public}dx%{public}d", grid.cols, grid.rows)
            PortLogger.info("Window ready: \(grid.cols)x\(grid.rows) rows (\(Int(newSize.width))x\(Int(newSize.height))pt)")
        } else if inLiveResize {
            // Window-edge drag in progress: present the last committed frame cropped
            // top-left and defer the BEAM re-layout to the trailing edge (#2655). We do
            // NOT applyViewportResize here so frameState keeps the committed grid, which
            // is what the crop displays and what pointer hit-testing must agree with.
            handleLiveResize(to: grid)
        } else if grid.cols != dispatcher.frameState.cols || grid.rows != dispatcher.frameState.rows {
            dispatcher.applyViewportResize(newCols: grid.cols, newRows: grid.rows)
            encoder.send(.resize(cols: grid.cols, rows: grid.rows))
            PortLogger.info("Window resized: \(grid.cols)x\(grid.rows) rows")
        }
    }

    // MARK: - Live resize

    /// AppKit is about to drive a run of `setFrameSize` calls from a window-edge drag.
    /// A resize is an authoritative layout change, so discard any in-flight presentation
    /// scroll animation (settle, rubber-band) and scroll-thumb drag state: they were
    /// computed against the old geometry and must not fight the resize.
    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        // The crop presented during the drag relies on the drawable auto-tracking the
        // view (see handleLiveResize); catch a future autoResizeDrawable flip loudly
        // instead of silently sample-stretching every resize.
        assert(autoResizeDrawable, "live-resize crop requires MTKView.autoResizeDrawable")
        resetSmoothScrollState()
        // resetSmoothScrollState deliberately spares a live thumb drag; a window
        // resize invalidates the drag's geometry, so it is a forced-reset path:
        // flush the final target (position is never silently dropped), then clear.
        cancelThumbDragWithFlush()
        isDraggingScrollIndicator = false
        scrollIndicatorTarget = nil
        scrollIndicatorDragOffset = nil
        // Pointer input is dropped during the resize (AC5), so a mouseUp that would
        // end an in-flight press may never reach the BEAM. Mirror the thumb-drag
        // rule: complete the gesture (send the release) before clearing its state.
        if leftMouseDownPoint != nil {
            let point = leftMouseDownPoint ?? .zero
            let (row, col) = rawCellPosition(at: point)
            if !sendPresentedText(at: point, button: MOUSE_BUTTON_LEFT, modifiers: 0, eventType: MOUSE_RELEASE, clickCount: 1) {
                encoder.send(.mouse(row: row, column: col, button: MOUSE_BUTTON_LEFT, modifiers: 0, eventType: MOUSE_RELEASE, clickCount: 1))
            }
        }
        leftMouseDownPoint = nil
        leftMouseDragStarted = false
        if dividerDragState != .none {
            dividerDragState = .none
            setDividerCursorState(.none)
        }
    }

    /// The drag ended. Flush any deferred resize immediately so the view snaps once to a
    /// fresh committed layout at the final size (AC2) instead of waiting for the trailing timer.
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        flushPendingResize()
    }

    /// Observes one live-resize frame through the pure bookkeeping state machine and runs the
    /// resulting side effect: flush now (max-wait cap), (re)schedule the trailing flush, or
    /// cancel a pending flush when the drag returns to the committed size. Always repaints the
    /// crop afterward.
    private func handleLiveResize(to grid: GridDimensions) {
        let live = LiveResizeBookkeeping.Grid(cols: grid.cols, rows: grid.rows)
        let committed = LiveResizeBookkeeping.Grid(cols: dispatcher.frameState.cols, rows: dispatcher.frameState.rows)
        let now = CACurrentMediaTime()

        switch resizeBookkeeping.onFrame(live: live, committed: committed, now: now, config: Self.resizeDebounceConfig) {
        case .flushNow(let target):
            cancelResizeFlushTask()
            sendLiveResize(cols: target.cols, rows: target.rows)
        case .schedule(let deadline):
            scheduleResizeFlush(at: deadline, now: now)
        case .cancelPending:
            // The drag came back to the committed grid: drop the timer so no stale resize fires.
            cancelResizeFlushTask()
        case .noop:
            break
        }

        // Repaint so the crop tracks the live drawable size and the background fill reaches the
        // freshly grown edge (no blank band). The drawable auto-tracks the view because
        // `MTKView.autoResizeDrawable` defaults to true (never set false here); if that ever
        // changes, the crop would sample-stretch instead of crop and this must set drawableSize.
        renderFrame()
    }

    /// Schedules a single trailing flush at an absolute `CACurrentMediaTime` deadline,
    /// replacing any previously scheduled one. Structured concurrency keeps the flush closure
    /// provably main-actor isolated and cheaply cancelable.
    private func scheduleResizeFlush(at deadline: TimeInterval, now: TimeInterval) {
        resizeDebounceTask?.cancel()
        let delay = max(deadline - now, 0)
        resizeDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.flushPendingResize()
        }
    }

    /// Cancels the trailing flush task, if any.
    private func cancelResizeFlushTask() {
        resizeDebounceTask?.cancel()
        resizeDebounceTask = nil
    }

    /// Flushes any deferred resize to the BEAM (one committed re-layout) and clears the
    /// debounce bookkeeping. Idempotent: a no-op when nothing is pending or the pending grid
    /// already matches the committed frame (the drag-away-and-back guard, re-applied here).
    /// Internal so integration tests can pin the exactly-once/idempotent contract.
    func flushPendingResize() {
        cancelResizeFlushTask()
        let committed = LiveResizeBookkeeping.Grid(cols: dispatcher.frameState.cols, rows: dispatcher.frameState.rows)
        guard let target = resizeBookkeeping.takeFlush(committed: committed) else { return }
        sendLiveResize(cols: target.cols, rows: target.rows)
    }

    /// Commits a debounced live-resize grid: updates local frame metadata and notifies the BEAM.
    private func sendLiveResize(cols: UInt16, rows: UInt16) {
        dispatcher.applyViewportResize(newCols: cols, newRows: rows)
        encoder.send(.resize(cols: cols, rows: rows))
        PortLogger.info("Window resized (debounced): \(cols)x\(rows) rows")
    }

    // MARK: - Scroll indicator interaction

    /// Whether the user is currently dragging the scroll indicator.
    private var isDraggingScrollIndicator = false

    /// Pointer offset from the rendered thumb's top edge captured at drag start.
    private var scrollIndicatorDragOffset: CGFloat?

    private func scrollTrackTarget(atY y: CGFloat, metrics: EditorScrollTrack.Metrics) -> UInt32 {
        if let scrollIndicatorDragOffset {
            return EditorScrollTrack.target(
                forDraggedY: y, dragOffset: scrollIndicatorDragOffset, viewHeight: bounds.height, metrics: metrics
            )
        }
        return EditorScrollTrack.target(forY: y, viewHeight: bounds.height, metrics: metrics)
    }

    private func scrollTrackMetrics(for surface: PresentedWindowSurface) -> EditorScrollTrack.Metrics? {
        EditorScrollTrack.metrics(
            surface: surface, localTransform: visibleLocalScrollPresentation, rowPitch: effectiveCellHeight
        )
    }

    // MARK: - Scrollbar thumb-drag local presentation (#2665)

    /// Captures the active track and sends the first target immediately. Resident panes
    /// also present locally; windowed panes keep the scroll-to-line round trip.
    private func beginScrollIndicatorDrag(at point: NSPoint) -> Bool {
        guard let snapshot = editorPresentationSnapshot,
              let surface = snapshot.activeSurface,
              let metrics = scrollTrackMetrics(for: surface),
              EditorScrollTrack.isInTrack(x: point.x, viewWidth: bounds.width),
              EditorScrollTrack.shouldCaptureTrackClick(
                  metrics: metrics, scrollIndicatorAlpha: coreTextRenderer.scrollIndicatorAlpha,
                  alwaysShowScrollbar: alwaysShowScrollbar
              ) else { return false }

        let visualBasis: ThumbDragSession.Committed?
        switch metrics.coordinate {
        case .visualRank:
            guard snapshot.metadata.textPresentations[surface.windowId] != nil,
                  let committed = Self.committedThumbDrag(content: surface.content, coordinate: .visualRank)
            else { return false }
            visualBasis = committed
        case .logicalLine:
            visualBasis = nil
        }
        scrollIndicatorDragOffset = EditorScrollTrack.thumb(viewHeight: bounds.height, metrics: metrics).flatMap {
            EditorScrollTrack.dragOffset(forY: point.y, thumb: $0)
        }
        let target = scrollTrackTarget(atY: point.y, metrics: metrics)
        isDraggingScrollIndicator = true

        // Thumb interaction supersedes trackpad/discrete prediction, including reconciliation.
        resetSmoothScrollState()
        thumbDragSession = nil
        let windowID = surface.windowId
        scrollIndicatorTarget = ScrollIndicatorTarget(
            windowID: windowID, generation: surface.content.accessibilityGeneration, visualBasis: visualBasis
        )
        if metrics.presentsLocally {
            var session = ThumbDragSession(windowId: windowID, targetLine: target)
            if let intent = session.takeIntent() { sendScrollIndicatorIntent(intent) }
            thumbDragSession = session
            applyThumbDragOffset(target: target, windowId: windowID)
        } else {
            sendScrollIndicatorIntent(target)
        }
        flashScrollIndicator()
        return true
    }

    /// Updates the drag target. Resident panes present same-frame and defer the intent to the
    /// per-frame throttle; windowed panes keep sending on every event (today's behavior).
    private func updateThumbDragPresentation(atY y: CGFloat) {
        guard let target = scrollIndicatorTarget,
              let snapshot = editorPresentationSnapshot,
              let surface = scrollIndicatorSurface(for: target, in: snapshot),
              let metrics = scrollTrackMetrics(for: surface) else {
            scrollIndicatorTarget = nil
            discardThumbDragPresentation()
            return
        }
        let position = scrollTrackTarget(atY: y, metrics: metrics)
        if let windowId = thumbDragSession?.windowId {
            thumbDragSession?.updateTarget(position)
            applyThumbDragOffset(target: position, windowId: windowId)
            needsDisplay = true
        } else {
            sendScrollIndicatorIntent(position)
        }
    }

    /// Handles thumb-drag release. Flushes any final throttled intent through the session, then
    /// hands off to the draw-loop reconcile: the offset keeps tracking the committed anchor until
    /// the BEAM's echo-marked commit reaches the target (offset 0), so there is no settle-jump.
    private func endThumbDragPresentation() {
        guard var session = thumbDragSession else {
            scrollIndicatorTarget = nil
            return
        }
        guard session.phase == .dragging else { return }
        if let intent = session.release(committed: committedThumbDrag(for: session.windowId), now: CACurrentMediaTime()) {
            sendScrollIndicatorIntent(intent)
        }
        thumbDragSession = session
        needsDisplay = true
    }

    /// Forced discard of an in-flight thumb drag that never silently drops the dragged position:
    /// flushes the final target intent, drops the session (the rest of the gesture, if the button is
    /// still held, degrades to the round-trip path), and zeroes the offset. Used by mid-hold reset
    /// paths that must discard local presentation (Reduce Motion toggle, window resign-key).
    private func cancelThumbDragWithFlush() {
        guard var session = thumbDragSession else { return }
        if let intent = session.cancelWithFlush() { sendScrollIndicatorIntent(intent) }
        discardThumbDragPresentation()
    }

    private func discardThumbDragPresentation() {
        guard thumbDragSession != nil else { return }
        thumbDragSession = nil
        scrollPixelOffset = CGPoint(x: scrollPixelOffset.x, y: 0)
        needsDisplay = true
    }

    /// Shifts resident rows from the committed top to the dragged line or visual rank.
    private func applyThumbDragOffset(target: UInt32, windowId: UInt16) {
        guard let top = committedThumbDrag(for: windowId)?.anchorTop, effectiveCellHeight > 0 else { return }
        scrollPixelOffset = CGPoint(
            x: scrollPixelOffset.x,
            y: Self.thumbDragPresentationOffsetY(targetLine: target, committedAnchorTop: top, cellHeight: effectiveCellHeight)
        )
    }

    /// The committed scroll presentation of the thumb-drag pane, or nil when it is gone.
    private func committedThumbDrag(for windowId: UInt16) -> ThumbDragSession.Committed? {
        committedThumbDrag(for: windowId, in: editorPresentationSnapshot)
    }

    private func committedThumbDrag(for windowId: UInt16, in snapshot: CommittedEditorSnapshot?) -> ThumbDragSession.Committed? {
        guard let content = snapshot?.content(for: windowId) else { return nil }
        if let target = scrollIndicatorTarget, let basis = target.visualBasis {
            guard content.accessibilityGeneration == target.generation,
                  let committed = Self.committedThumbDrag(content: content, coordinate: .visualRank),
                  committed.hasSameAuthority(as: basis) else { return nil }
            return committed
        }
        return Self.committedThumbDrag(content: content, coordinate: .logicalLine)
    }

    private static func committedThumbDrag(content: GUIWindowContent, coordinate: EditorScrollTrack.Coordinate) -> ThumbDragSession.Committed? {
        guard let sp = content.scrollPresentation else { return nil }
        let top: UInt32
        switch coordinate {
        case .visualRank:
            guard let rank = content.wrappedResidentAnchor else { return nil }
            top = UInt32(rank)
        case .logicalLine:
            guard !sp.isWrapped else { return nil }
            top = sp.anchorTop
        }
        return ThumbDragSession.Committed(
            anchorTop: top, scrollSeq: sp.scrollSeq, contentEpoch: sp.contentEpoch, layoutGeneration: sp.layoutGeneration
        )
    }

    /// Advances the thumb-drag session one frame and applies its decision: flushes at most one
    /// throttled intent (AC4), tracks the offset against the committed anchor, and finishes the
    /// session when the reconcile lands, an authoritative event interrupts it, the presentation
    /// vanishes, the button is released without a mouseUp, or the reconcile watchdog expires.
    private func advanceThumbDragPresentation(committedSnapshot: CommittedEditorSnapshot) {
        guard var session = thumbDragSession else { return }
        let committed = committedThumbDrag(for: session.windowId, in: committedSnapshot)
        // The button check catches a lost mouseUp (system modal / Mission Control / Cmd-Tab mid-drag)
        // so a gesture cannot stay stuck in the dragging phase with the gate held open.
        let buttonHeld = NSEvent.pressedMouseButtons & 0x1 != 0
        let outcome = session.advance(committed: committed, now: CACurrentMediaTime(), buttonHeld: buttonHeld)

        if let intent = outcome.intent, committed != nil { sendScrollIndicatorIntent(intent) }
        if outcome.finished {
            if committed == nil || !buttonHeld { scrollIndicatorTarget = nil }
            discardThumbDragPresentation()
        } else {
            thumbDragSession = session
            let rowPitch = cellHeight * CGFloat(committedSnapshot.frameState.lineSpacing)
            if rowPitch > 0 {
                scrollPixelOffset = CGPoint(x: scrollPixelOffset.x, y: CGFloat(outcome.offsetLines) * rowPitch)
            }
        }
        if outcome.needsRedraw { needsDisplay = true }
    }

    private func scrollIndicatorSurface(for target: ScrollIndicatorTarget, in snapshot: CommittedEditorSnapshot) -> PresentedWindowSurface? {
        guard let surface = snapshot.surface(for: target.windowID),
              surface.content.accessibilityGeneration == target.generation else { return nil }
        // Never reinterpret a captured pointer after its coordinate space changes.
        if let basis = target.visualBasis {
            guard let visual = Self.committedThumbDrag(content: surface.content, coordinate: .visualRank),
                  visual.hasSameAuthority(as: basis) else { return nil }
        } else if surface.content.scrollPresentation?.isWrapped == true {
            return nil
        }
        return surface
    }

    private func sendScrollIndicatorIntent(_ position: UInt32) {
        guard let target = scrollIndicatorTarget,
              let snapshot = editorPresentationSnapshot,
              scrollIndicatorSurface(for: target, in: snapshot) != nil else { return }
        if target.visualBasis != nil {
            guard let presentationID = snapshot.metadata.textPresentations[target.windowID] else { return }
            encoder.send(.scrollToVisualRank(windowID: target.windowID, presentationID: presentationID, rank: position))
        } else {
            encoder.send(.scrollToLine(windowID: target.windowID, generation: target.generation, line: position))
        }
    }

    /// Pixel offset that shifts resident rows so `targetLine` renders at the viewport top, given
    /// the BEAM's committed `anchorTop`. Positive shifts content up (scrolled toward the end),
    /// matching `scrollPixelOffset.y`. Pure for testability.
    nonisolated static func thumbDragPresentationOffsetY(targetLine: UInt32, committedAnchorTop: UInt32, cellHeight: CGFloat) -> CGFloat {
        CGFloat(Int64(targetLine) - Int64(committedAnchorTop)) * cellHeight
    }

    // MARK: - Line spacing

    /// Called when the BEAM sends a new line_spacing value (opcode 0x92). By the
    /// time this fires the dispatcher has already stored the new spacing, so we
    /// recompute rows-that-fit once against the spaced cell height (ADR-0001) and,
    /// if it changed, send an ordinary resize. The BEAM re-lays-out in the given
    /// rows without any spacing math of its own. A resize never re-triggers 0x92
    /// (the emit is fingerprint-gated on the spacing value), so there is no loop.
    func lineSpacingChanged(_ spacing: Float) {
        guard frame.width > 0, frame.height > 0 else { return }
        let grid = currentGridDimensions()

        if grid.cols != dispatcher.frameState.cols || grid.rows != dispatcher.frameState.rows {
            dispatcher.applyViewportResize(newCols: grid.cols, newRows: grid.rows)
            encoder.send(.resize(cols: grid.cols, rows: grid.rows))
        }
    }

    // MARK: - Tracking area

    private func updateTrackingArea() {
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Agent chat key forwarding

    /// Publishes overlay presence to the sole responder policy.
    func setAgentChatVisible(_ visible: Bool) {
        guard agentChatVisible != visible else { return }
        focusPolicy.agentOverlayVisibilityDidChange(visible)
        layer?.isOpaque = !visible
        if !visible {
            agentPromptPlacement = nil
            agentPromptPlacementOwner = nil
            lastPromptFit = nil
            promptScrollAccumulator.reset()
        }
        presentationAvailabilityEpoch &+= 1
        renderFrame()
    }

    // MARK: - Keyboard

    /// Returns true for shortcuts that the menu bar or AppKit should handle
    /// instead of being sent directly to the BEAM. The menu action sends
    /// the appropriate command to the BEAM, so the end result is the same
    /// but the menu item highlights visually.
    static func shouldYieldSystemCommandShortcut(_ event: NSEvent) -> Bool {
        EditorFocusPolicy.shouldYieldSystemCommandShortcut(event)
    }

    /// Intercept key equivalents (Cmd+key, etc.) before AppKit/SwiftUI
    /// can consume them for menus or focus navigation.
    ///
    /// Bare Cmd+Q (Quit), Cmd+H (Hide), and Cmd+M (Minimize) are returned
    /// to the system so macOS platform conventions work as expected.
    /// Modified variants (Cmd+Shift+M, Cmd+Option+Q, etc.) still route
    /// to the BEAM so user keybindings work.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // When a field editor (NSTextView) is active (e.g., workspace rename
        // TextField, or any SwiftUI text input), yield so the field editor
        // handles Cmd+A, Cmd+C, Cmd+Z, etc. through the normal responder chain.
        if focusPolicy.nativeTextEditingIsActive() {
            return false
        }

        if Self.shouldYieldSystemCommandShortcut(event) {
            return false
        }

        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        resetCursorBlink()
        let mods = modifierBits(from: event.modifierFlags)

        if imeComposition.hasMarkedText && !imeCommitTargetIsCurrent {
            cancelIMEComposition()
            return
        }
        textInputCallbacksSuppressed = false

        if event.modifierFlags.contains(.control),
           event.charactersIgnoringModifiers == "g",
           recoveryManager?.handleCtrlG() == true
        {
            return
        }

        // ── Space leader key-chord interception ──
        // When SPC is pending or held, intercept chord keys before any other processing.
        // Skip when IME is composing or when the current mode treats SPC as typed text.
        if !imeComposition.hasMarkedText && !spaceLeaderShouldTreatSpaceLiterally() {
            if let chars = event.charactersIgnoringModifiers, chars == " ", mods == 0 {
                // Bare SPC keyDown (no modifiers)
                if event.isARepeat {
                    // User holding SPC for repeated spaces. Cancel chord detection.
                    cancelSpaceGrace()
                    spaceKeyDown = false
                    sendKeyPress(codepoint: 0x20, modifiers: 0)
                    return
                }

                // Start the grace period. Don't send the space yet.
                spacePending = true
                spaceKeyDown = false
                let timer = DispatchWorkItem { [weak self] in
                    guard let self, self.spacePending else { return }
                    // Grace period expired. Send the space now.
                    self.spacePending = false
                    self.spaceKeyDown = true
                    self.sendKeyPress(codepoint: 0x20, modifiers: 0)
                }
                spaceGraceTimer?.cancel()
                spaceGraceTimer = timer
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + .milliseconds(leaderGraceMs), execute: timer)
                return
            }

            // Another key arrived. Check chord state.
            if spacePending {
                // Clean chord: SPC was never sent. Enter leader directly.
                cancelSpaceGrace()
                spacePending = false
                spaceKeyDown = false
                sendSpaceLeaderChord(codepoint: codepoint(from: event, mods: mods), modifiers: mods)
                return
            }

            if spaceKeyDown {
                // Fallback chord: SPC was already sent (grace timer fired).
                // Tell BEAM to retract the space and enter leader.
                spaceKeyDown = false
                sendSpaceLeaderRetract(codepoint: codepoint(from: event, mods: mods), modifiers: mods)
                return
            }
        }

        // ── Cmd+V paste interception ──
        if event.modifierFlags.contains(.command),
           let chars = event.charactersIgnoringModifiers,
           chars == "v"
        {
            if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
                encoder.send(.paste(text))
            }
            return
        }

        // ── Cmd+G / Cmd+Shift+G: Find next/prev using Find Pasteboard ──
        if event.modifierFlags.contains(.command),
           let chars = event.charactersIgnoringModifiers,
           chars == "g"
        {
            if let findText = NSPasteboard(name: .find).string(forType: .string), !findText.isEmpty {
                let direction: UInt8 = event.modifierFlags.contains(.shift) ? 1 : 0
                encoder.send(.findPasteboardSearch(text: findText, direction: direction))
            }
            return
        }

        if imeComposition.hasMarkedText,
           Self.routesToInputMethodDuringComposition(event)
        {
            handleInputMethodEvent(event)
            return
        }

        dispatcher.previewAgentHelpNavigation(event, in: window)

        // Special keys outside composition bypass IME.
        if let codepoint = mapKeyCode(event) {
            sendKeyPress(codepoint: codepoint, modifiers: mods)
            return
        }

        // Control/Command key combinations bypass IME and go directly
        // to the BEAM. Without this, Ctrl+A, Ctrl+W, etc. lose their
        // modifier bits when routed through insertText.
        if event.modifierFlags.contains(.control) || event.modifierFlags.contains(.command) {
            let textMods = mods & ~0x01  // strip shift (codepoint encodes it)
            let chars = event.modifierFlags.contains(.control)
                ? event.charactersIgnoringModifiers : event.characters
            if let characters = chars, !characters.isEmpty {
                for scalar in characters.unicodeScalars {
                    sendKeyPress(codepoint: scalar.value, modifiers: textMods)
                }
            }
            return
        }

        // Note: Option+Delete and Option+Arrows are handled above in the
        // "Special keys bypass IME" section via mapKeyCode, which returns
        // non-nil for all special key codes. The Option modifier bit is
        // included in `mods`, so the BEAM receives the correct modifiers
        // for word-delete and word-movement. Option+printable chars still
        // go through IME below for dead key / accent character support.

        // Route through the input method system. This calls our
        // NSTextInputClient methods (insertText, setMarkedText, etc.)
        // for IME-aware input. For non-IME input, it calls insertText
        // directly with the typed character.
        handleInputMethodEvent(event)
    }

    override func keyUp(with event: NSEvent) {
        // Space leader key-chord: SPC keyUp clears the chord state.
        if let chars = event.charactersIgnoringModifiers, chars == " " {
            if spacePending {
                // SPC released within the grace period. It was a tap.
                // Send the space now (clean, no flash).
                cancelSpaceGrace()
                spacePending = false
                sendKeyPress(codepoint: 0x20, modifiers: 0)
            }
            spaceKeyDown = false
        }
    }

    override func flagsChanged(with event: NSEvent) {
        // Cmd press/release while the pointer is stationary still needs to update
        // the go-to-definition link preview (#2630): pressing Cmd over a symbol
        // should underline it and show the hand cursor, and releasing Cmd should
        // clear both. AppKit delivers a flagsChanged (not a mouseMoved) for this,
        // so re-send a motion at the current pointer to let the BEAM recompute.
        let commandHeld = event.modifierFlags.contains(.command)
        guard commandHeld != lastCommandHeld else { return }
        lastCommandHeld = commandHeld
        resendMotionForModifierChange(event)
    }

    /// Re-sends a free MOUSE_MOTION at the current pointer cell with the latest
    /// modifier bits. Used when the Command key toggles without pointer movement
    /// so the BEAM can (re)resolve the Cmd+hover link preview (#2630).
    private func resendMotionForModifierChange(_ event: NSEvent) {
        let rawPoint = convert(event.locationInWindow, from: nil)
        guard bounds.contains(rawPoint) else { return }
        let (row, col) = cellPosition(from: event)
        encoder.send(.mouse(row: row, column: col, button: MOUSE_BUTTON_NONE, modifiers: modifierBits(from: event.modifierFlags), eventType: MOUSE_MOTION, clickCount: 1))
    }

    /// Shows or hides the pointing-hand cursor for a navigable Cmd+hover symbol
    /// (#2630). Driven by the BEAM's `set_link_cursor` command via the dispatcher.
    /// Uses the same guarded push/pop discipline as the split-divider cursor.
    func setLinkCursorActive(_ active: Bool) {
        guard linkCursorActive != active else { return }
        linkCursorActive = active
        if active {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pop()
        }
    }

    // MARK: - Space leader helpers

    /// Cancel the grace period timer without sending the space.
    private func cancelSpaceGrace() {
        spaceGraceTimer?.cancel()
        spaceGraceTimer = nil
    }

    /// Extract a codepoint from an event for the chord gui_action.
    /// Tries mapKeyCode first (special keys), then characters.
    private func codepoint(from event: NSEvent, mods: UInt8) -> UInt32 {
        if let cp = mapKeyCode(event) {
            return cp
        }
        // For printable characters, use the character value
        let chars = event.modifierFlags.contains(.control)
            ? event.charactersIgnoringModifiers : event.characters
        if let characters = chars, let scalar = characters.unicodeScalars.first {
            return scalar.value
        }
        return 0
    }

    /// Buffer input uses only the immutable native layout that reached the display.
    private func sendPresentedText(event: NSEvent, button: UInt8, eventType: UInt8, clickCount: UInt8) -> Bool {
        sendPresentedText(at: convert(event.locationInWindow, from: nil), button: button, modifiers: modifierBits(from: event.modifierFlags), eventType: eventType, clickCount: clickCount)
    }

    private func sendPresentedText(at point: CGPoint, button: UInt8, modifiers: UInt8, eventType: UInt8, clickCount: UInt8) -> Bool {
        let capturedWindow = textGestureWindows[button]
        let hit = dispatcher.visibleEditorPresentation?.textLayout?.hit(at: point, capturedWindowID: capturedWindow)
        if eventType == MOUSE_RELEASE { textGestureWindows.removeValue(forKey: button) }
        guard let hit else {
            guard let capturedWindow else {
                return agentChatVisible || editorPresentation?.textLayout?.promptTransform != nil
            }
            if eventType == MOUSE_RELEASE {
                let target = EditorTextTarget(windowID: capturedWindow, presentationID: 0, rowIndex: 0, rowID: 0, utf16Offset: 0)
                encoder.send(.editorText(target: target, button: button, modifiers: modifiers, eventType: eventType, clickCount: clickCount, scrollX: 0, scrollY: 0))
            }
            return true
        }
        if eventType == MOUSE_PRESS { textGestureWindows[button] = hit.target.windowID }
        if eventType == MOUSE_MOTION {
            guard lastTextHover != hit.target else { return true }
            lastTextHover = hit.target
        }
        encoder.send(.editorText(target: hit.target, button: button, modifiers: modifiers, eventType: eventType, clickCount: clickCount, scrollX: eventType == MOUSE_DRAG ? hit.scrollX : 0, scrollY: eventType == MOUSE_DRAG ? hit.scrollY : 0))
        return true
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        // Drop pointer input while a live resize is in flight (#2655, AC5): the view
        // geometry is changing and the on-screen content is a crop of the last committed
        // frame, so a hit-test would map against stale, in-flux geometry. Events are
        // discarded, not queued: nothing is replayed after the resize ends. The same
        // guard gates every geometry-hit-testing handler below; press/release pairs
        // that straddle a resize are completed by viewWillStartLiveResize instead.
        guard !inLiveResize else { return }
        consumeLeftGestureTail = false
        leftMousePressActive = true
        focusPolicy.pointerReturnedToEditor()

        let point = convert(event.locationInWindow, from: nil)
        if editorPresentation?.textLayout?.promptTransform == nil, beginScrollIndicatorDrag(at: point) {
            return
        }

        if editorPresentation?.textLayout?.promptTransform == nil, handleFoldChevronClick(at: point) {
            return
        }

        resetCursorBlink()
        leftMouseDownPoint = point
        leftMouseDragStarted = false
        dividerDragState = editorPresentation?.textLayout?.promptTransform == nil ? dividerHitState(at: point) : .none
        if dividerDragState != .none {
            setDividerCursorState(dividerDragState)
        }
        let (row, col) = dividerDragState == .none ? cellPosition(from: event) : dividerPressCellPosition(at: point, state: dividerDragState)
        let cc = UInt8(clamping: event.clickCount)
        if !(dividerDragState == .none && sendPresentedText(event: event, button: MOUSE_BUTTON_LEFT, eventType: MOUSE_PRESS, clickCount: cc)) {
            encoder.send(.mouse(row: row, column: col, button: MOUSE_BUTTON_LEFT, modifiers: modifierBits(from: event.modifierFlags), eventType: MOUSE_PRESS, clickCount: cc))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if consumeLeftGestureTail {
            consumeLeftGestureTail = false
            leftMousePressActive = false
            return
        }
        guard !inLiveResize else { return }
        leftMousePressActive = false
        if isDraggingScrollIndicator {
            isDraggingScrollIndicator = false
            scrollIndicatorDragOffset = nil
            endThumbDragPresentation()
            flashScrollIndicator()
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let (row, col) = dividerDragState == .none ? cellPosition(from: event) : rawCellPosition(at: point)
        if !(dividerDragState == .none && sendPresentedText(event: event, button: MOUSE_BUTTON_LEFT, eventType: MOUSE_RELEASE, clickCount: 1)) {
            encoder.send(.mouse(row: row, column: col, button: MOUSE_BUTTON_LEFT, modifiers: modifierBits(from: event.modifierFlags), eventType: MOUSE_RELEASE, clickCount: 1))
        }
        leftMouseDownPoint = nil
        leftMouseDragStarted = false
        if scrollHorizontalWindowId != nil { needsDisplay = true }
        if dividerDragState != .none {
            dividerDragState = .none
            setDividerCursorState(dividerHitState(at: point))
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        // Dropped during a live resize (see mouseDown). The matching rightMouseUp stays
        // ungated so a press that straddles the resize still delivers its release.
        guard !inLiveResize else { return }
        consumeRightGestureTail = false
        rightMousePressActive = true
        focusPolicy.pointerReturnedToEditor()
        resetCursorBlink()
        let (row, col) = cellPosition(from: event)
        let cc = UInt8(clamping: event.clickCount)
        let point = convert(event.locationInWindow, from: nil)
        let target = dispatcher.visibleEditorPresentation?.textLayout?.hit(at: point, capturedWindowID: nil)?.target
        if !(sendPresentedText(event: event, button: MOUSE_BUTTON_RIGHT, eventType: MOUSE_PRESS, clickCount: cc)) {
            encoder.send(.mouse(row: row, column: col, button: MOUSE_BUTTON_RIGHT, modifiers: modifierBits(from: event.modifierFlags), eventType: MOUSE_PRESS, clickCount: cc))
        }
        contextMenuShownForRightClick = true
        let menu = buildEditorContextMenu(connectionGeneration: inputConnectionGeneration, target: target)
        activeContextMenu = menu
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        if activeContextMenu === menu {
            activeContextMenu = nil
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        if consumeRightGestureTail {
            consumeRightGestureTail = false
            rightMousePressActive = false
            return
        }
        rightMousePressActive = false
        if contextMenuShownForRightClick {
            _ = sendPresentedText(event: event, button: MOUSE_BUTTON_RIGHT, eventType: MOUSE_RELEASE, clickCount: 1)
            contextMenuShownForRightClick = false
            return
        }

        let (row, col) = cellPosition(from: event)
        if !(sendPresentedText(event: event, button: MOUSE_BUTTON_RIGHT, eventType: MOUSE_RELEASE, clickCount: 1)) {
            encoder.send(.mouse(row: row, column: col, button: MOUSE_BUTTON_RIGHT, modifiers: modifierBits(from: event.modifierFlags), eventType: MOUSE_RELEASE, clickCount: 1))
        }
    }

    private struct EditorContextMenuAction {
        let name: String
        let connectionGeneration: UInt64
    }

    private func buildEditorContextMenu(connectionGeneration: UInt64, target: EditorTextTarget?) -> NSMenu {
        let menu = NSMenu(title: "Editor")
        menu.autoenablesItems = false
        addEditorMenuItem("Cut", action: "cut", connectionGeneration: connectionGeneration, to: menu)
        addEditorMenuItem("Copy", action: "copy", connectionGeneration: connectionGeneration, to: menu)
        addEditorMenuItem("Paste", action: "paste", connectionGeneration: connectionGeneration, to: menu)
        addEditorMenuItem("Select All", action: "select_all", connectionGeneration: connectionGeneration, to: menu)
        addEditorMenuItem("Attach Selection to Agent Draft", action: "agent_attach_selection", connectionGeneration: connectionGeneration, to: menu)
        addEditorMenuItem("Attach Current Buffer to Agent Draft", action: "agent_attach_buffer", connectionGeneration: connectionGeneration, to: menu)
        if let target {
            let action = "agent_attach_diagnostics_at:\(target.windowID):\(target.presentationID)"
            addEditorMenuItem("Attach File Diagnostics to Agent Draft", action: action, connectionGeneration: connectionGeneration, to: menu)
        }
        menu.addItem(.separator())

        let hasLsp = statusBarState?.hasLsp ?? false
        addEditorMenuItem("Go to Definition", action: "goto_definition", connectionGeneration: connectionGeneration, to: menu, enabled: hasLsp)
        addEditorMenuItem("Peek Definition", action: "peek_definition", connectionGeneration: connectionGeneration, to: menu, enabled: hasLsp)
        addEditorMenuItem("Find References", action: "find_references", connectionGeneration: connectionGeneration, to: menu, enabled: hasLsp)
        addEditorMenuItem("Rename Symbol", action: "rename_symbol", connectionGeneration: connectionGeneration, to: menu, enabled: hasLsp)
        menu.addItem(.separator())

        addEditorMenuItem("Toggle Comment", action: "toggle_comment_line", connectionGeneration: connectionGeneration, to: menu)
        addEditorMenuItem("Format Document", action: "format_buffer", connectionGeneration: connectionGeneration, to: menu)
        return menu
    }

    private func addEditorMenuItem(
        _ title: String,
        action: String,
        connectionGeneration: UInt64,
        to menu: NSMenu,
        enabled: Bool = true
    ) {
        let item = NSMenuItem(title: title, action: #selector(handleEditorContextMenuItem(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = EditorContextMenuAction(name: action, connectionGeneration: connectionGeneration)
        item.isEnabled = enabled
        menu.addItem(item)
    }

    @objc private func handleEditorContextMenuItem(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? EditorContextMenuAction else { return }
        performEditorContextMenuAction(action.name, connectionGeneration: action.connectionGeneration)
    }

    private func performEditorContextMenuAction(_ action: String, connectionGeneration: UInt64) {
        guard connectionGeneration == inputConnectionGeneration, !consumeRightGestureTail else { return }

        switch action {
        case "cut":
            encoder.send(.commandCut)
        case "copy":
            encoder.send(.commandCopy)
        case "paste":
            pasteFromClipboard()
        default:
            encoder.send(.executeCommand(name: action))
        }
    }

    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        encoder.send(.paste(text))
    }

    override func otherMouseDown(with event: NSEvent) {
        // Dropped during a live resize (see mouseDown). otherMouseUp stays ungated so a
        // press that straddles the resize still delivers its release.
        guard !inLiveResize else { return }
        consumeMiddleGestureTail = false
        middleMousePressActive = true
        focusPolicy.pointerReturnedToEditor()
        let (row, col) = cellPosition(from: event)
        if !(sendPresentedText(event: event, button: MOUSE_BUTTON_MIDDLE, eventType: MOUSE_PRESS, clickCount: 1)) {
            encoder.send(.mouse(row: row, column: col, button: MOUSE_BUTTON_MIDDLE, modifiers: modifierBits(from: event.modifierFlags), eventType: MOUSE_PRESS, clickCount: 1))
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        if consumeMiddleGestureTail {
            consumeMiddleGestureTail = false
            middleMousePressActive = false
            return
        }
        middleMousePressActive = false
        let (row, col) = cellPosition(from: event)
        if !(sendPresentedText(event: event, button: MOUSE_BUTTON_MIDDLE, eventType: MOUSE_RELEASE, clickCount: 1)) {
            encoder.send(.mouse(row: row, column: col, button: MOUSE_BUTTON_MIDDLE, modifiers: modifierBits(from: event.modifierFlags), eventType: MOUSE_RELEASE, clickCount: 1))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !consumeLeftGestureTail else { return }
        guard !inLiveResize else { return }
        if isDraggingScrollIndicator {
            let point = convert(event.locationInWindow, from: nil)
            updateThumbDragPresentation(atY: point.y)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        if dividerDragState != .none {
            setDividerCursorState(dividerDragState)
        } else if !shouldSendTextDrag(for: event) {
            return
        }
        let (row, col) = dividerDragState == .none ? cellPosition(from: event) : rawCellPosition(at: point)
        if !(dividerDragState == .none && sendPresentedText(event: event, button: MOUSE_BUTTON_LEFT, eventType: MOUSE_DRAG, clickCount: 1)) {
            encoder.send(.mouse(row: row, column: col, button: MOUSE_BUTTON_LEFT, modifiers: modifierBits(from: event.modifierFlags), eventType: MOUSE_DRAG, clickCount: 1))
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard !inLiveResize else { return }
        let point = convert(event.locationInWindow, from: nil)
        if editorPresentation?.textLayout?.promptTransform == nil {
            setDividerCursorState(dividerHitState(at: point))
            updateGutterHover(at: point)
        }
        let (row, col) = cellPosition(from: event)
        if sendPresentedText(event: event, button: MOUSE_BUTTON_NONE, eventType: MOUSE_MOTION, clickCount: 1) { return }
        lastTextHover = nil
        guard row != lastMoveRow || col != lastMoveCol else { return }
        lastMoveRow = row
        lastMoveCol = col
        encoder.send(.mouse(row: row, column: col, button: MOUSE_BUTTON_NONE, modifiers: modifierBits(from: event.modifierFlags), eventType: MOUSE_MOTION, clickCount: 1))
    }

    override func mouseExited(with event: NSEvent) {
        if dividerDragState == .none {
            setDividerCursorState(.none)
        }
        clearGutterHover()
        if trackpadGesture == nil, scrollHorizontalWindowId == nil { resetSmoothScrollState() }
        super.mouseExited(with: event)
    }

    /// Scroll accumulator for smooth trackpad scrolling. Extracted into a
    /// pure struct so the accumulation math is unit-testable.
    private var scrollAccumulator = ScrollAccumulator()

    // MARK: - Scroll indicator fade

    /// Pending scroll indicator fade animation.
    private var scrollFadeTask: Task<Void, Never>?

    /// Whether the system prefers always-visible scrollers.
    private var alwaysShowScrollbar: Bool = false

    /// Shows the scroll indicator and starts a fade timer.
    /// Called on scroll events and when viewport position changes.
    func flashScrollIndicator() {
        coreTextRenderer.scrollIndicatorAlpha = 1.0
        setNeedsDisplay(bounds)

        // Cancel any pending fade (both the idle delay and any in-progress steps).
        scrollFadeTask?.cancel()
        scrollFadeTask = nil

        // Don't fade if system preference is "Always show".
        guard !alwaysShowScrollbar else { return }

        scrollFadeTask = Task { [weak self] in
            // Initial delay before fade begins.
            do {
                try await Task.sleep(for: .milliseconds(1500))
            } catch {
                return  // Cancelled during idle delay.
            }

            // 6 fade steps, 50ms apart, total 300ms.
            for step in stride(from: 5, through: 0, by: -1) {
                guard let self else { return }
                if Task.isCancelled { return }
                if self.alwaysShowScrollbar {
                    self.coreTextRenderer.scrollIndicatorAlpha = 1.0
                    self.setNeedsDisplay(self.bounds)
                    return
                }
                self.coreTextRenderer.scrollIndicatorAlpha = Float(step) / 6.0
                self.setNeedsDisplay(self.bounds)
                if step > 0 {
                    do {
                        try await Task.sleep(for: .milliseconds(50))
                    } catch {
                        return  // Cancelled during fade step.
                    }
                }
            }
        }
    }

    /// Call once during setup to observe the system scroller style preference.
    func observeScrollerStyle() {
        guard scrollerStyleTask == nil else { return }
        alwaysShowScrollbar = NSScroller.preferredScrollerStyle == .legacy
        if alwaysShowScrollbar {
            coreTextRenderer.scrollIndicatorAlpha = 1.0
        }

        scrollerStyleTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSScroller.preferredScrollerStyleDidChangeNotification) {
                guard let self else { return }
                self.alwaysShowScrollbar = NSScroller.preferredScrollerStyle == .legacy
                if self.alwaysShowScrollbar {
                    self.scrollFadeTask?.cancel()
                    self.scrollFadeTask = nil
                    self.coreTextRenderer.scrollIndicatorAlpha = 1.0
                    self.setNeedsDisplay(self.bounds)
                } else {
                    self.flashScrollIndicator()
                }
            }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // Dropped during a live resize like the left-mouse family (see mouseDown): a wheel
        // event mid-resize would hit-test in-flux geometry and re-establish the scroll
        // offset the resize discard just cleared.
        guard !inLiveResize else { return }
        let startsGesture = event.hasPreciseScrollingDeltas && startsTrackpadGesture(event)
        let continuesPaneGesture = event.hasPreciseScrollingDeltas && !startsGesture && trackpadGesture?.windowId != nil
        if !continuesPaneGesture, sendAgentPromptScroll(event) {
            if startsGesture, trackpadGesture != nil { resetSmoothScrollState() }
            return
        }
        // A resident thumb drag owns scroll presentation while the button is held: ignore concurrent
        // wheel input so the two do not fight over the offset. A post-release reconcile (button up)
        // is superseded by a fresh wheel gesture, so flush-and-drop it and let the wheel take over.
        if let session = thumbDragSession {
            if session.ownsScrollInput { return }
            cancelThumbDragWithFlush()
        }

        let (row, col) = cellPosition(from: event)
        let mods = modifierBits(from: event.modifierFlags)

        // Flash the scroll indicator on any scroll activity.
        flashScrollIndicator()

        if event.hasPreciseScrollingDeltas {
            handleTrackpadScroll(event: event, startsGesture: startsGesture, row: row, col: col, mods: mods)
        } else {
            handleDiscreteScroll(event: event, row: row, col: col, mods: mods)
        }
    }
    /// Wheel input targets the same displayed TextPresentation as pointer input.
    private func sendAgentPromptScroll(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        guard let pane = editorPresentation?.textLayout?.panes.first(where: {
            $0.windowID == 65534 && $0.rect.contains(point)
        }) else { return false }
        if event.phase == .began { promptScrollAccumulator.reset() }
        let delta: Int32
        if event.hasPreciseScrollingDeltas {
            let events = promptScrollAccumulator.accumulateVertical(deltaY: event.scrollingDeltaY, cellHeight: effectiveCellHeight)
            delta = events.reduce(0) { $0 + ($1 == .scrollDown ? 1 : -1) }
        } else {
            delta = Int32(clamping: Int((-event.scrollingDeltaY).rounded(.awayFromZero)))
        }
        if delta != 0 {
            encoder.send(.agentPromptScroll(windowID: pane.windowID, generation: pane.presentationID, deltaRows: delta))
        }
        return true
    }


    /// Smooth trackpad scrolling: accumulate pixel deltas, emit discrete
    /// events at cell boundaries, and render the fractional offset via Metal.
    /// True while the user is actively dragging a text selection (left mouse
    /// button held down, excluding pane-divider and scrollbar-thumb drags,
    /// which are unrelated gestures that also hold the button down).
    ///
    /// #2661: during an active selection drag, local presentation scrolling
    /// defers to BEAM-authoritative anchors — drag-autoscroll is BEAM-owned,
    /// so the frontend must not layer its own ephemeral scroll offset on top
    /// of it. Scroll-intent reports still go out normally; only the local
    /// pixel-offset *presentation* is suppressed.
    private var isSelectionDragActive: Bool {
        Self.isSelectionDragActive(
            hasMouseDownPoint: leftMouseDownPoint != nil,
            isDividerDragActive: dividerDragState != .none,
            isDraggingScrollIndicator: isDraggingScrollIndicator
        )
    }

    nonisolated static func isSelectionDragActive(hasMouseDownPoint: Bool, isDividerDragActive: Bool, isDraggingScrollIndicator: Bool) -> Bool {
        hasMouseDownPoint && !isDividerDragActive && !isDraggingScrollIndicator
    }

#if DEBUG
    struct InteractionSnapshot {
        let hasMarkedText: Bool
        let markedRange: NSRange
        let hoverRow: Int16
        let hoverCol: Int16
        let selectionDragActive: Bool
        let selectionDragStarted: Bool
        let scrollWindowId: UInt16?
        let scrollOffset: CGPoint
        let inputConnectionGeneration: UInt64
        let consumesLeftGestureTail: Bool
        let consumesRightGestureTail: Bool
        let consumesMiddleGestureTail: Bool
        let inputEnabled: Bool
    }

    /// Read-only test seam for native interaction ownership across SwiftUI publication.
    var interactionSnapshot: InteractionSnapshot {
        InteractionSnapshot(
            hasMarkedText: imeComposition.hasMarkedText,
            markedRange: imeComposition.markedRange,
            hoverRow: lastMoveRow,
            hoverCol: lastMoveCol,
            selectionDragActive: isSelectionDragActive,
            selectionDragStarted: leftMouseDragStarted,
            scrollWindowId: localScrollPresentation?.windowId,
            scrollOffset: localScrollPresentation?.offset ?? .zero,
            inputConnectionGeneration: inputConnectionGeneration,
            consumesLeftGestureTail: consumeLeftGestureTail,
            consumesRightGestureTail: consumeRightGestureTail,
            consumesMiddleGestureTail: consumeMiddleGestureTail,
            inputEnabled: inputEnabled
        )
    }

    func performContextMenuActionForTesting(_ action: String, connectionGeneration: UInt64) {
        performEditorContextMenuAction(action, connectionGeneration: connectionGeneration)
    }

    func beginMousePressForTesting(button: UInt8) {
        switch button {
        case MOUSE_BUTTON_LEFT:
            leftMousePressActive = true
        case MOUSE_BUTTON_RIGHT:
            rightMousePressActive = true
        case MOUSE_BUTTON_MIDDLE:
            middleMousePressActive = true
        default:
            break
        }
    }

    func scrollTrackTargetForTesting(y: CGFloat) -> UInt32 {
        guard let surface = editorPresentationSnapshot?.activeSurface,
              let metrics = scrollTrackMetrics(for: surface) else { return 0 }
        return scrollTrackTarget(atY: y, metrics: metrics)
    }

    struct ScrollDrawSnapshot {
        let presentation: LocalScrollPresentation?
        let unconfirmedLines: Int
        let lastConfirmedAnchorTop: UInt32?
        let cellHeight: CGFloat
    }

    func seedTrackpadReconciliationForTesting(windowId: UInt16, unconfirmedLines: Int, confirmedAnchorTop: UInt32, settling: Bool) {
        scrollTargetWindowId = settling ? nil : windowId
        scrollSettleWindowId = settling ? windowId : nil
        scrollUnconfirmedLines = unconfirmedLines
        scrollLastConfirmedAnchor = confirmedAnchorTop
        scrollPixelOffset = CGPoint(x: 0, y: CGFloat(unconfirmedLines) * effectiveCellHeight)
        if settling {
            scrollSettleAnimator.start(offset: 0, duration: 60)
        }
    }

    func seedThumbDragReconciliationForTesting(windowId: UInt16, targetLine: UInt32, committedAnchorTop: UInt32) {
        var session = ThumbDragSession(windowId: windowId, targetLine: targetLine)
        _ = session.takeIntent()
        _ = session.release(
            committed: ThumbDragSession.Committed(anchorTop: committedAnchorTop, scrollSeq: 0, contentEpoch: 1, layoutGeneration: 1),
            now: CACurrentMediaTime()
        )
        thumbDragSession = session
        scrollPixelOffset = CGPoint(
            x: 0,
            y: Self.thumbDragPresentationOffsetY(targetLine: targetLine, committedAnchorTop: committedAnchorTop, cellHeight: effectiveCellHeight)
        )
    }

    func prepareLocalScrollPresentationForTesting(committedSnapshot: CommittedEditorSnapshot) -> ScrollDrawSnapshot {
        let presentation = prepareLocalScrollPresentationForDraw(committedSnapshot: committedSnapshot)
        return ScrollDrawSnapshot(
            presentation: presentation,
            unconfirmedLines: scrollUnconfirmedLines,
            lastConfirmedAnchorTop: scrollLastConfirmedAnchor,
            cellHeight: effectiveCellHeight
        )
    }
#endif

    private func startsTrackpadGesture(_ event: NSEvent) -> Bool {
        event.phase == .began || (event.phase == [] && event.momentumPhase == []
            && (trackpadGesture == nil || trackpadGesture?.fingersLifted == true))
    }

    private func handleTrackpadScroll(event: NSEvent, startsGesture: Bool, row: Int16, col: Int16, mods: UInt8) {
        guard event.phase != .mayBegin else { return }
        if startsGesture {
            let previousWindowId = scrollTargetWindowId ?? scrollSettleWindowId
            let target = smoothScrollTargetWindowId(row: row, col: col)
            trackpadGesture = TrackpadGesture(windowId: target)
            scrollTargetWindowId = target
            scrollAccumulator.reset()
            scrollPixelOffset.y = 0
            scrollElasticOffsetY = 0
            cancelScrollAnimations()
            let content = target.flatMap { dispatcher.committedEditorSnapshot?.content(for: $0) }
            // A new finger gesture on the same wrapped basis does not unsend prior intent.
            if target != previousWindowId || content?.wrappedResidentAnchor == nil {
                resetScrollReconciliation()
            }
            if target == scrollHorizontalWindowId {
                scrollHorizontalAnimator.cancel()
            } else {
                resetHorizontalScrollPresentation()
            }
        }
        guard var gesture = trackpadGesture else { return } // Ignore a discarded gesture's tail.

        if event.momentumPhase == .began || event.momentumPhase == .changed {
            scrollTargetWindowId = gesture.windowId
            if gesture.fingersLifted {
                gesture.fingersLifted = false
                cancelScrollAnimations()
                scrollHorizontalAnimator.cancel()
            }
        }
        let delta = gesture.lockDeltas(x: event.scrollingDeltaX, y: event.scrollingDeltaY)
        let targetContent = gesture.windowId.flatMap { dispatcher.committedEditorSnapshot?.content(for: $0) }
        switch gesture.axis {
        case .horizontal:
            if let targetContent, let scroll = targetContent.scrollPresentation,
               scroll.canPanHorizontally, !scroll.isWrapped {
                applyHorizontalWheelDelta(delta.x, content: targetContent, scroll: scroll)
            } else {
                scrollTargetWindowId = nil
                if gesture.windowId == nil {
                    let columns = scrollAccumulator.accumulateHorizontal(deltaX: delta.x, cellWidth: cellWidth)
                    let button = columns > 0 ? MOUSE_SCROLL_RIGHT : MOUSE_SCROLL_LEFT
                    for _ in 0..<abs(Int(columns)) {
                        sendWheelMouse(button, row: row, col: col, mods: mods)
                    }
                }
            }
        case .vertical:
            applyVerticalTrackpadDelta(delta.y, row: row, col: col, mods: mods, targetContent: targetContent)
        case .undecided:
            break
        }

        if event.phase == .ended || event.phase == .cancelled
            || event.momentumPhase == .ended || event.momentumPhase == .cancelled {
            if gesture.axis == .horizontal {
                finishHorizontalTrackpadGesture(windowId: gesture.windowId)
                scrollTargetWindowId = nil
            } else {
                finishSmoothScrollGesture()
            }
        }
        if event.phase == .ended {
            gesture.fingersLifted = true
        }
        trackpadGesture = event.phase == .cancelled || event.momentumPhase == .ended || event.momentumPhase == .cancelled
            ? nil : gesture
        needsDisplay = true
    }

    private func applyHorizontalWheelDelta(_ deltaX: CGFloat, content: GUIWindowContent, scroll: GUIScrollPresentation) {
        if scrollHorizontalWindowId != content.windowId {
            resetHorizontalScrollPresentation()
            scrollHorizontalWindowId = content.windowId
        }
        acknowledgeHorizontalPan(in: content.windowId, ack: scroll.horizontalPanAck)
        let left = pendingHorizontalPans[content.windowId]?.left ?? Int(content.scrollLeft)
        let right = max(Int(scroll.horizontalPanLimit) - left, 0)
        let columns = scrollAccumulator.accumulateHorizontal(
            deltaX: deltaX, cellWidth: cellWidth, left: left, right: right
        )
        if columns != 0 {
            if horizontalPanSequence < UInt32.max,
               encoder.send(.horizontalPan(windowID: content.windowId, deltaColumns: columns, inputSeq: horizontalPanSequence + 1)).wasAccepted {
                horizontalPanSequence += 1
                pendingHorizontalPans[content.windowId] = HorizontalScrollPrediction(
                    left: left + Int(columns), inputSeq: horizontalPanSequence
                )
            } else {
                scrollAccumulator.snapHorizontal()
            }
        }
        scrollPixelOffset.x = horizontalPanOffset(for: content, residual: scrollAccumulator.pixelOffsetX)
    }

    private func finishHorizontalTrackpadGesture(windowId: UInt16?) {
        guard let windowId, windowId == scrollHorizontalWindowId else { return }
        let residual = scrollAccumulator.pixelOffsetX
        scrollHorizontalAnimator.start(offset: residual, duration: scrollAnimateEnabled ? Self.scrollSettleDuration : 0)
        if !scrollHorizontalAnimator.isActive {
            scrollPixelOffset.x -= residual
        }
    }

    private func resetHorizontalScrollPresentation() {
        scrollHorizontalWindowId = nil
        scrollAccumulator.snapHorizontal()
        scrollHorizontalAnimator.cancel()
        scrollPixelOffset.x = 0
    }

    private func acknowledgeHorizontalPan(in windowId: UInt16, ack: UInt32) {
        horizontalPanSequence = max(horizontalPanSequence, ack)
        if let pending = pendingHorizontalPans[windowId], ack >= pending.inputSeq {
            pendingHorizontalPans.removeValue(forKey: windowId)
        }
    }

    private func horizontalPanOffset(for content: GUIWindowContent, residual: CGFloat) -> CGFloat {
        let columns = pendingHorizontalPans[content.windowId]?.columns(from: content.scrollLeft) ?? 0
        return CGFloat(columns) * cellWidth + residual
    }

    private func reconcilePendingHorizontalPans(in snapshot: CommittedEditorSnapshot) {
        var retired: [UInt16] = []
        for (windowId, pending) in pendingHorizontalPans {
            guard let scroll = snapshot.content(for: windowId)?.scrollPresentation,
                  scroll.canPanHorizontally, !scroll.isWrapped else {
                retired.append(windowId)
                continue
            }
            horizontalPanSequence = max(horizontalPanSequence, scroll.horizontalPanAck)
            if scroll.horizontalPanAck >= pending.inputSeq { retired.append(windowId) }
        }
        for windowId in retired {
            pendingHorizontalPans.removeValue(forKey: windowId)
        }
    }

    private func applyVerticalTrackpadDelta(_ deltaY: CGFloat, row: Int16, col: Int16, mods: UInt8, targetContent: GUIWindowContent?) {
        if let targetContent { reconcileUnconfirmedLines(against: targetContent) }
        let suppressLocalOffset = scrollTargetWindowId == nil || isSelectionDragActive
        var excessWrappedRows = 0
        let events = scrollAccumulator.accumulateVertical(deltaY: deltaY, cellHeight: effectiveCellHeight)
        if let windowId = scrollTargetWindowId {
            let wireDelta = Int16(clamping: events.reduce(0) { $0 + ($1 == .scrollDown ? 1 : -1) })
            if wireDelta != 0 {
                let direction: UInt8 = wireDelta > 0 ? 0 : 1
                let sent = encoder.send(.scrollBatch(windowID: windowId, deltaLines: wireDelta, direction: direction))
                if sent.wasAccepted {
                    let requested = Int(wireDelta)
                    if let targetContent, targetContent.scrollPresentation?.isWrapped == true {
                        if !suppressLocalOffset, targetContent.wrappedResidentAnchor != nil {
                            let reachable = wrappedScrollPrediction(requested, content: targetContent)
                            scrollUnconfirmedLines += reachable
                            excessWrappedRows = requested - reachable
                        }
                    } else {
                        scrollUnconfirmedLines += requested
                    }
                }
            }
        } else {
            for event in events {
                let button = event == .scrollDown ? MOUSE_SCROLL_DOWN : MOUSE_SCROLL_UP
                sendWheelMouse(button, row: row, col: col, mods: mods)
            }
        }
        let compensatedOffsetY = scrollAccumulator.pixelOffsetY + CGFloat(scrollUnconfirmedLines) * effectiveCellHeight
        if let targetContent, targetContent.scrollPresentation?.isWrapped == true {
            if targetContent.wrappedResidentAnchor != nil, !suppressLocalOffset {
                applyWrappedTrackpadOffset(
                    compensatedOffsetY + CGFloat(excessWrappedRows) * effectiveCellHeight,
                    content: targetContent, deltaY: deltaY
                )
            } else {
                // The windowed payload has no exact visual rank or global bounds.
                // Keep reporting intent but only present committed vertical movement.
                scrollPixelOffset.y = 0
            }
        } else {
            let scroll = targetContent?.scrollPresentation
            let bounds = Self.presentationScrollBounds(for: targetContent, scrollPresentation: scroll)
            let translation = Self.presentationScrollTranslation(
                scrollPresentation: scroll, scrollOffsetY: compensatedOffsetY,
                scrollDeltaY: deltaY,
                payloadOverscanBefore: bounds.payloadBefore, payloadOverscanAfter: bounds.payloadAfter,
                boundaryBefore: bounds.boundaryBefore, boundaryAfter: bounds.boundaryAfter
            )
            applyPresentationTranslation(translation, suppressLocalOffset: suppressLocalOffset)
        }
    }

    /// Ends a smooth-scroll gesture. With animations enabled this eases the residual sub-line
    /// offset and springs the rubber band back. Reduce Motion snaps the residual to the grid
    /// but keeps a reachable wrapped-row prediction until it commits.
    private func finishSmoothScrollGesture() {
        let needsConfirmation = scrollUnconfirmedLines != 0 || scrollWrappedTurningRank != nil
        let keepWrappedPrediction = needsConfirmation && scrollTargetWindowId.flatMap {
            dispatcher.committedEditorSnapshot?.content(for: $0)?.wrappedResidentAnchor
        } != nil
        guard scrollAnimateEnabled || keepWrappedPrediction else {
            scrollTargetWindowId = nil
            scrollPixelOffset.y = 0
            scrollElasticOffsetY = 0
            cancelScrollAnimations()
            resetScrollReconciliation()
            return
        }

        var startedAnimation = false

        // AC2: release at an overscrolled edge springs the elastic offset back to 0.
        if scrollElasticOffsetY != 0 {
            scrollElasticAnimator.start(offset: scrollElasticOffsetY, duration: Self.scrollElasticSpringBackDuration)
            scrollElasticRawDistance = 0
            // Keep applying the elastic to its pane after the gesture target is released.
            scrollElasticWindowId = scrollTargetWindowId ?? scrollElasticWindowId
            startedAnimation = true
        }

        // AC1: ease the residual sub-line offset to the grid while unconfirmed-line
        // reconciliation keeps the anchor easing forward (no back-then-forward stutter).
        if let windowId = scrollTargetWindowId, needsConfirmation || scrollAccumulator.pixelOffsetY != 0 {
            let residual = scrollAnimateEnabled ? scrollAccumulator.pixelOffsetY : 0
            beginScrollSettle(windowId: windowId, residual: residual, duration: scrollAnimateEnabled ? Self.scrollSettleDuration : 0)
            startedAnimation = true
        }

        // Release live-gesture-only state; the settle keeps reconciling via scrollSettleWindowId.
        scrollTargetWindowId = nil

        if !startedAnimation {
            scrollPixelOffset.y = 0
            scrollElasticOffsetY = 0
            scrollElasticRawDistance = 0
            resetScrollReconciliation()
            scrollSettleWindowId = nil
            scrollElasticWindowId = nil
        }
        needsDisplay = true
    }

    /// Instantly resets all smooth-scroll and animation state to the grid (Reduce Motion / cleanup).
    private func hardResetSmoothScroll() {
        // Trackpad and thumb-drag are mutually exclusive (the scrollWheel guard ignores wheel input
        // while a drag is button-held), so no session is expected here; drop it defensively.
        thumbDragSession = nil
        resetSmoothScrollState()
    }

    private func resetScrollReconciliation() {
        scrollUnconfirmedLines = 0
        scrollLastConfirmedAnchor = nil
        scrollWrappedTurningRank = nil
    }

    /// Cancels in-flight presentation scroll animations without moving the offset.
    /// Callers snap or reset the offset separately. Preserves unconfirmed-line bookkeeping
    /// so a resuming momentum gesture stays continuous.
    private func cancelScrollAnimations() {
        scrollSettleAnimator.cancel()
        scrollElasticAnimator.cancel()
        scrollSettleWindowId = nil
        scrollElasticWindowId = nil
        scrollElasticRawDistance = 0
    }

    /// Begins the AC1/AC3 settle: decays `residual` px to the grid while the draw loop
    /// reconciles unconfirmed lines against `windowId`'s committed anchor.
    private func beginScrollSettle(windowId: UInt16, residual: CGFloat, duration: CFTimeInterval) {
        scrollSettleWindowId = windowId
        if scrollLastConfirmedAnchor == nil, let content = dispatcher.committedEditorSnapshot?.content(for: windowId) {
            scrollLastConfirmedAnchor = Self.wheelAnchor(content)
        }
        scrollSettleAnimator.start(offset: residual, duration: duration)
        // Reflect the seeded offset immediately so this frame is continuous with the last.
        scrollPixelOffset = CGPoint(x: scrollPixelOffset.x, y: residual + CGFloat(scrollUnconfirmedLines) * effectiveCellHeight)
        needsDisplay = true
    }

    private static func wheelAnchor(_ content: GUIWindowContent) -> UInt32? {
        guard let scroll = content.scrollPresentation else { return nil }
        if scroll.isWrapped { return content.wrappedResidentAnchor.map { UInt32($0) } }
        return scroll.anchorTop
    }

    /// Reconciles only newly committed movement in the pane's wheel coordinate.
    private func reconcileUnconfirmedLines(against content: GUIWindowContent) {
        guard let anchor = Self.wheelAnchor(content) else { return }
        if let previous = scrollLastConfirmedAnchor, previous != anchor {
            let delta = Int(anchor) - Int(previous)
            if content.rowStore.mode == .sequentialWrapped {
                // A same-authority echo can land beyond the predicted target when
                // it acknowledges only the outward part of a mid-flight reversal.
                scrollUnconfirmedLines = isSelectionDragActive ? 0 : scrollUnconfirmedLines - delta
                if scrollWrappedTurningRank == anchor || isSelectionDragActive {
                    scrollWrappedTurningRank = nil
                }
            } else {
                scrollUnconfirmedLines = Self.reconciledUnconfirmedLines(current: scrollUnconfirmedLines, anchorDelta: delta)
            }
        }
        scrollLastConfirmedAnchor = anchor
    }

    private func wrappedScrollPrediction(_ requested: Int, content: GUIWindowContent) -> Int {
        guard let anchor = content.wrappedResidentAnchor, let maxTop = content.wrappedResidentMaxTop else { return 0 }
        let predictedTop = anchor + scrollUnconfirmedLines
        let reachable = min(max(predictedTop + requested, 0), maxTop) - predictedTop
        if (reachable < 0 && scrollUnconfirmedLines > 0) || (reachable > 0 && scrollUnconfirmedLines < 0) {
            scrollWrappedTurningRank = UInt32(predictedTop)
        }
        return reachable
    }

    /// Clamp the content at the visual EOF/top while keeping reachable movement
    /// pending. Extraneous precise input belongs only to the elastic transform.
    private func applyWrappedTrackpadOffset(_ requestedY: CGFloat, content: GUIWindowContent, deltaY: CGFloat) {
        let bounded = boundedScrollOffset(requestedY, content: content)
        let excess = requestedY - bounded
        scrollPixelOffset.y = bounded
        guard deltaY != 0 else { return }
        if excess != 0 {
            scrollAccumulator.snapVertical()
        }
        if excess != 0, scrollAnimateEnabled {
            scrollElasticRawDistance += excess
            scrollElasticWindowId = scrollTargetWindowId
            scrollElasticOffsetY = PresentationScrollAnimator.rubberBandOffset(
                rawDistance: scrollElasticRawDistance, limit: effectiveCellHeight * Self.scrollElasticLimitCells
            )
        } else {
            scrollElasticRawDistance = 0
            scrollElasticOffsetY = 0
            scrollElasticWindowId = nil
        }
    }

    /// Advances the settle and rubber-band spring-back animations one frame.
    ///
    /// The MTKView is paused, so this self-retriggers `needsDisplay` while an animation runs,
    /// mirroring the cursor animation's draw-loop self-retrigger. Discards always win: the state
    /// is cleared out from under this by `resetSmoothScrollState()` before it runs.
    private func advancePresentationScrollAnimation(snapshot: CommittedEditorSnapshot) {
        if let windowId = scrollTargetWindowId, let content = snapshot.content(for: windowId), content.scrollPresentation != nil {
            reconcileUnconfirmedLines(against: content)
            let offsetY = scrollAccumulator.pixelOffsetY + CGFloat(scrollUnconfirmedLines) * effectiveCellHeight
            scrollPixelOffset.y = boundedScrollOffset(offsetY, content: content)
        }
        let now = CACurrentMediaTime()
        var keepAnimating = false

        reconcilePendingHorizontalPans(in: snapshot)
        if let windowId = scrollHorizontalWindowId {
            if let content = snapshot.content(for: windowId),
               let scroll = content.scrollPresentation, scroll.canPanHorizontally, !scroll.isWrapped {
                let isLive = scrollTargetWindowId == windowId && trackpadGesture?.axis == .horizontal
                let residual = isLive ? scrollAccumulator.pixelOffsetX : scrollHorizontalAnimator.offset(now: now)
                scrollPixelOffset.x = horizontalPanOffset(for: content, residual: residual)
                if scrollHorizontalAnimator.isActive {
                    keepAnimating = true
                } else if !isLive, pendingHorizontalPans[windowId] == nil {
                    resetHorizontalScrollPresentation()
                }
            } else {
                resetHorizontalScrollPresentation()
            }
        }

        if let windowId = scrollSettleWindowId {
            if let content = snapshot.content(for: windowId) {
                reconcileUnconfirmedLines(against: content)
            }
            let residual = scrollSettleAnimator.offset(now: now)
            let offsetY = residual + CGFloat(scrollUnconfirmedLines) * effectiveCellHeight
            scrollPixelOffset.y = boundedScrollOffset(offsetY, content: snapshot.content(for: windowId))
            if scrollSettleAnimator.isActive {
                keepAnimating = true
            } else if scrollUnconfirmedLines == 0, scrollWrappedTurningRank == nil {
                // Fully settled: residual is exactly 0 and no unconfirmed lines remain.
                scrollSettleWindowId = nil
                scrollLastConfirmedAnchor = nil
                scrollPixelOffset = CGPoint(x: scrollPixelOffset.x, y: 0)
            }
            // Otherwise the residual is done but whole (on-grid) lines are still committing;
            // keep reconciling on future BEAM frames, which drive their own redraws.
        }

        if scrollElasticAnimator.isActive {
            scrollElasticOffsetY = scrollElasticAnimator.offset(now: now)
            if scrollElasticAnimator.isActive {
                keepAnimating = true
            } else {
                scrollElasticOffsetY = 0
                scrollElasticRawDistance = 0
                scrollElasticWindowId = nil
            }
        }

        if keepAnimating {
            needsDisplay = true
        }
    }

    /// Projects a reconciled offset without repeating an input event's elastic pull.
    private func boundedScrollOffset(_ offsetY: CGFloat, content: GUIWindowContent?) -> CGFloat {
        guard !isSelectionDragActive else { return 0 }
        guard let content, let presentation = content.scrollPresentation else { return offsetY }
        if presentation.isWrapped {
            guard let anchor = content.wrappedResidentAnchor, let maxTop = content.wrappedResidentMaxTop else { return 0 }
            return min(max(offsetY, -CGFloat(anchor) * effectiveCellHeight), CGFloat(maxTop - anchor) * effectiveCellHeight)
        }
        let bounds = Self.presentationScrollBounds(for: content, scrollPresentation: presentation)
        let translation = Self.presentationScrollTranslation(
            scrollPresentation: presentation, scrollOffsetY: offsetY, scrollDeltaY: -offsetY,
            payloadOverscanBefore: bounds.payloadBefore, payloadOverscanAfter: bounds.payloadAfter,
            boundaryBefore: bounds.boundaryBefore, boundaryAfter: bounds.boundaryAfter
        )
        guard case .content(let offset) = translation else { return 0 }
        return min(max(offset, -CGFloat(bounds.payloadBefore) * effectiveCellHeight), CGFloat(bounds.payloadAfter) * effectiveCellHeight)
    }

    /// Applies the pure translation decision to the live presentation offset and rubber band.
    private func applyPresentationTranslation(_ translation: ScrollTranslation, suppressLocalOffset: Bool) {
        switch translation {
        case .content(let offsetY):
            // Scrolling within real content: no rubber band.
            scrollElasticOffsetY = 0
            scrollElasticRawDistance = 0
            scrollPixelOffset.y = suppressLocalOffset ? 0 : offsetY

        case .elastic(let pullDelta):
            let limit = effectiveCellHeight * Self.scrollElasticLimitCells
            // AC2: on the frame the elastic engages, fold the residual sub-line offset into the
            // rubber band instead of popping it to 0. The whole-line overscroll can't be
            // predicted past the boundary, so it snaps (usually 0 near the edge).
            let enteringElastic = scrollElasticRawDistance == 0 && scrollElasticOffsetY == 0
            if enteringElastic {
                let residual = scrollAccumulator.pixelOffsetY
                scrollAccumulator.snapVertical()
                scrollUnconfirmedLines = 0
                if scrollAnimateEnabled, residual != 0 {
                    let sign: CGFloat = pullDelta >= 0 ? 1 : -1
                    scrollElasticRawDistance = sign * PresentationScrollAnimator.inverseRubberBandDistance(offset: abs(residual), limit: limit)
                }
            } else {
                scrollAccumulator.snapVertical()
                scrollUnconfirmedLines = 0
            }

            if scrollAnimateEnabled && !suppressLocalOffset {
                scrollElasticRawDistance += pullDelta
                scrollElasticOffsetY = PresentationScrollAnimator.rubberBandOffset(rawDistance: scrollElasticRawDistance, limit: limit)
            } else {
                scrollElasticOffsetY = 0
                scrollElasticRawDistance = 0
            }
            scrollPixelOffset.y = 0
        }
    }

    /// Discards local prediction when its pane receives an authoritative reset.
    func resetScrollPresentation(windowId: UInt16) {
        pendingHorizontalPans.removeValue(forKey: windowId)
        if let target = scrollIndicatorTarget, target.windowID == windowId, target.visualBasis != nil {
            scrollIndicatorTarget = nil
        }
        guard [scrollTargetWindowId, scrollSettleWindowId, scrollElasticWindowId, scrollHorizontalWindowId,
               trackpadGesture?.windowId, thumbDragSession?.windowId].contains(windowId) else { return }
        hardResetSmoothScroll()
    }

    /// Resets the trackpad smooth-scroll state (offset, target, animations). It deliberately does
    /// NOT clear an in-flight thumb drag. Reset paths that must discard a held thumb drag
    /// call `cancelThumbDragWithFlush()` instead so its position is never dropped.
    func resetSmoothScrollState() {
        scrollAccumulator.reset()
        scrollPixelOffset = .zero
        scrollElasticOffsetY = 0
        scrollTargetWindowId = nil
        trackpadGesture = nil
        resetHorizontalScrollPresentation()
        cancelScrollAnimations()
        resetScrollReconciliation()
        needsDisplay = true
    }

    private func clearSmoothScrollStateIfTargetWindowMissing() {
        guard let availableWindowIds = dispatcher.visibleEditorSnapshot?.windowIds else { return }
        clearSmoothScrollStateIfTargetWindowMissing(availableWindowIds: availableWindowIds)
    }

    private func clearSmoothScrollStateIfTargetWindowMissing(in snapshot: CommittedEditorSnapshot) {
        clearSmoothScrollStateIfTargetWindowMissing(availableWindowIds: snapshot.windowIds)
    }

    private func clearSmoothScrollStateIfTargetWindowMissing(availableWindowIds: Set<UInt16>) {
        // Covers the live gesture target, the thumb-drag pane, and the settle / elastic windows that
        // outlive it: if any pane owning presentation state has closed, drop the offset and cancel
        // its animation so a stale whole-cell offset can't linger after the animator finishes on a
        // vanished pane.
        if Self.missingPresentationWindow(
            candidateWindowIds: [scrollTargetWindowId, thumbDragSession?.windowId, scrollSettleWindowId,
                                 scrollElasticWindowId, scrollHorizontalWindowId, trackpadGesture?.windowId],
            availableWindowIds: availableWindowIds
        ) {
            // The thumb-drag pane vanished: drop the session (no flush; the window is gone).
            if let target = scrollIndicatorTarget, !availableWindowIds.contains(target.windowID) {
                scrollIndicatorTarget = nil
            }
            thumbDragSession = nil
            resetSmoothScrollState()
        }
    }

    /// Returns true when any non-nil presentation window is no longer available (frame missing or
    /// content dropped), so the caller can clear stale offset/animation state. Pure for testability.
    nonisolated static func missingPresentationWindow(candidateWindowIds: [UInt16?], availableWindowIds: Set<UInt16>) -> Bool {
        candidateWindowIds.compactMap { $0 }.contains { !availableWindowIds.contains($0) }
    }

    private func smoothScrollTargetWindowId(row: Int16, col: Int16) -> UInt16? {
        if let snapshot = editorPresentationSnapshot {
            let rowValue = Int(row)
            let colValue = Int(col)
            let geometry = snapshot.surfaces
                .map(\.paneGeometry)
                .filter { rowColInCellRect(row: rowValue, col: colValue, rect: $0.contentRect) }
                .max { lhs, rhs in lhs.contentRect.col < rhs.contentRect.col }
            if let geometry { return geometry.windowId }
            return EditorNSView.smoothScrollTargetWindowId(row: row, col: col, windowGutters: snapshot.windowGutters)
        }

        return EditorNSView.smoothScrollTargetWindowId(row: row, col: col, windowGutters: editorPresentationSnapshot?.windowGutters ?? [:])
    }

    /// Result of classifying a vertical scroll delta against the pane's content and boundaries.
    enum ScrollTranslation: Equatable {
        case content(offsetY: CGFloat)
        case elastic(pullDelta: CGFloat)
    }

    struct PresentationScrollBounds: Equatable {
        let payloadBefore: Int
        let payloadAfter: Int
        let boundaryBefore: Int
        let boundaryAfter: Int

        static let zero = PresentationScrollBounds(payloadBefore: 0, payloadAfter: 0, boundaryBefore: 0, boundaryAfter: 0)
    }

    /// Classifies a vertical scroll delta as in-content or overscroll (rubber band).
    ///
    /// The rubber-band magnitude is no longer computed here: the caller maps accumulated pull
    /// through `PresentationScrollAnimator.rubberBandOffset` so the curve is asymptotic and the
    /// spring-back animation can own the offset on release (AC2).
    nonisolated static func presentationScrollTranslation(
        scrollPresentation: GUIScrollPresentation?,
        scrollOffsetY: CGFloat,
        scrollDeltaY: CGFloat,
        payloadOverscanBefore: Int,
        payloadOverscanAfter: Int,
        boundaryBefore: Int,
        boundaryAfter: Int
    ) -> ScrollTranslation {
        guard scrollPresentation != nil else { return .content(offsetY: scrollOffsetY) }
        guard scrollDeltaY != 0 else { return .content(offsetY: scrollOffsetY) }

        let pullingTowardBefore = scrollDeltaY > 0
        let pullingTowardAfter = scrollDeltaY < 0
        let hasRenderablePayload =
            (pullingTowardBefore && payloadOverscanBefore > 0) ||
            (pullingTowardAfter && payloadOverscanAfter > 0)
        if hasRenderablePayload {
            return .content(offsetY: scrollOffsetY)
        }

        let pullingPastTop = pullingTowardBefore && boundaryBefore == 0
        let pullingPastBottom = pullingTowardAfter && boundaryAfter == 0
        guard pullingPastTop || pullingPastBottom else {
            return .content(offsetY: 0)
        }

        return .elastic(pullDelta: -scrollDeltaY)
    }

    /// Reconciles a predicted unconfirmed-line count against a committed anchor delta.
    ///
    /// Subtracts the delta and clamps to 0 when the confirmation overshoots (sign flip), which
    /// keeps the presentation from fighting an authoritative anchor jump. Pure for testability.
    nonisolated static func reconciledUnconfirmedLines(current: Int, anchorDelta: Int) -> Int {
        guard anchorDelta != 0 else { return current }
        let next = current - anchorDelta
        if current >= 0 && next < 0 { return 0 }
        if current <= 0 && next > 0 { return 0 }
        return next
    }

    nonisolated static func presentationScrollBounds(
        for windowContent: GUIWindowContent?,
        scrollPresentation: GUIScrollPresentation?
    ) -> PresentationScrollBounds {
        guard let scrollPresentation else { return .zero }
        if scrollPresentation.isWrapped {
            guard let anchor = windowContent?.wrappedResidentAnchor,
                  let maxTop = windowContent?.wrappedResidentMaxTop else { return .zero }
            let after = maxTop - anchor
            return PresentationScrollBounds(
                payloadBefore: anchor, payloadAfter: after,
                boundaryBefore: anchor > 0 ? 1 : 0, boundaryAfter: after > 0 ? 1 : 0
            )
        }

        let before = windowContent.map {
            CoreTextMetalRenderer.presentationOverscanBeforeRows($0)
        } ?? CoreTextMetalRenderer.scrollOverscanBefore(scrollPresentation)

        let totalLines = windowContent?.paneGeometry?.viewport.totalLines
        let isResident = totalLines.map {
            EditorScrollTrack.isUnwrappedResident(scrollPresentation, totalLines: $0)
        } ?? false

        let payloadAfter: Int
        if let windowContent {
            let visibleRows = presentationPayloadVisibleRows(for: windowContent)
            if visibleRows > 0 {
                let rawAfter = max(windowContent.rowStore.count - visibleRows - before, 0)
                if rawAfter > 0 {
                    payloadAfter = rawAfter
                } else if isResident {
                    payloadAfter = max(Int(totalLines!) - 1 - Int(scrollPresentation.anchorTop), 0)
                } else {
                    payloadAfter = 0
                }
            } else {
                payloadAfter = max(0, Int(scrollPresentation.overscanEndLine) - Int(scrollPresentation.visibleEndLine))
            }
        } else {
            payloadAfter = max(0, Int(scrollPresentation.overscanEndLine) - Int(scrollPresentation.visibleEndLine))
        }

        let hasContentBefore = scrollPresentation.anchorTop > 0 || scrollPresentation.anchorVisualRowOffset > 0 || before > 0
        let hasContentAfter: Bool
        if let totalLines, totalLines > 0 {
            if isResident {
                hasContentAfter = scrollPresentation.anchorTop < totalLines - 1 || payloadAfter > 0
            } else {
                hasContentAfter = scrollPresentation.visibleEndLine < totalLines || payloadAfter > 0
            }
        } else {
            hasContentAfter = payloadAfter > 0
        }

        return PresentationScrollBounds(
            payloadBefore: before,
            payloadAfter: payloadAfter,
            boundaryBefore: hasContentBefore ? 1 : 0,
            boundaryAfter: hasContentAfter ? 1 : 0
        )
    }

    nonisolated static func presentationScrollBoundaryAvailability(
        for windowContent: GUIWindowContent?,
        scrollPresentation: GUIScrollPresentation?
    ) -> (before: Int, after: Int) {
        let bounds = presentationScrollBounds(for: windowContent, scrollPresentation: scrollPresentation)
        return (bounds.boundaryBefore, bounds.boundaryAfter)
    }

    nonisolated static func presentationScrollPayloadOverscanBounds(
        for windowContent: GUIWindowContent?,
        scrollPresentation: GUIScrollPresentation?
    ) -> (before: Int, after: Int) {
        let bounds = presentationScrollBounds(for: windowContent, scrollPresentation: scrollPresentation)
        return (bounds.payloadBefore, bounds.payloadAfter)
    }

    nonisolated static func presentationPayloadVisibleRows(for windowContent: GUIWindowContent) -> Int {
        if let geometry = windowContent.paneGeometry {
            let textRows = Int(geometry.textRect.height)
            if textRows > 0 { return textRows }
            let viewportRows = Int(geometry.viewport.rows)
            if viewportRows > 0 { return viewportRows }
            let contentRows = Int(geometry.contentRect.height)
            if contentRows > 0 { return contentRows }
        }
        return 0
    }

    nonisolated static func presentationScrollOverscanBounds(
        for windowContent: GUIWindowContent?,
        scrollPresentation: GUIScrollPresentation?
    ) -> (before: Int, after: Int) {
        presentationScrollBoundaryAvailability(for: windowContent, scrollPresentation: scrollPresentation)
    }

    nonisolated static func smoothScrollTargetWindowId(row: Int16, col: Int16, windowGutters: [UInt16: Wire.WindowGutter]) -> UInt16? {
        guard row >= 0, col >= 0 else { return nil }
        let rowValue = Int(row)
        let colValue = Int(col)
        let rowMatches = windowGutters.values.filter { gutter in
            let startRow = Int(gutter.contentRow)
            let endRow = startRow + Int(gutter.contentHeight)
            let startCol = Int(gutter.contentCol)
            let endCol = startCol + Int(gutter.contentWidth)
            return rowValue >= startRow && rowValue < endRow && colValue >= startCol && colValue < endCol
        }
        guard !rowMatches.isEmpty else { return nil }

        return rowMatches
            .max { lhs, rhs in lhs.contentCol < rhs.contentCol }?
            .windowId
    }

    /// Discrete mouse wheel: one event per click, no accumulation.
    private func handleDiscreteScroll(event: NSEvent, row: Int16, col: Int16, mods: UInt8) {
        if scrollTargetWindowId == nil {
            trackpadGesture = nil
        }
        if event.scrollingDeltaY > 0 {
            if encoder.send(.mouse(row: row, column: col, button: MOUSE_SCROLL_UP, modifiers: mods, eventType: MOUSE_PRESS, clickCount: 1)).wasAccepted {
                seedDiscreteScrollAnimation(row: row, col: col, lineDelta: -1)
            }
        } else if event.scrollingDeltaY < 0 {
            if encoder.send(.mouse(row: row, column: col, button: MOUSE_SCROLL_DOWN, modifiers: mods, eventType: MOUSE_PRESS, clickCount: 1)).wasAccepted {
                seedDiscreteScrollAnimation(row: row, col: col, lineDelta: 1)
            }
        }
        guard event.scrollingDeltaX != 0 else { return }
        if let windowID = smoothScrollTargetWindowId(row: row, col: col) {
            guard let content = dispatcher.committedEditorSnapshot?.content(for: windowID),
                  let scroll = content.scrollPresentation, scroll.canPanHorizontally, !scroll.isWrapped else { return }
            scrollHorizontalAnimator.cancel()
            scrollAccumulator.snapHorizontal()
            let deltaX = event.scrollingDeltaX > 0 ? cellWidth : -cellWidth
            applyHorizontalWheelDelta(deltaX, content: content, scroll: scroll)
        } else {
            let button = event.scrollingDeltaX > 0 ? MOUSE_SCROLL_LEFT : MOUSE_SCROLL_RIGHT
            sendWheelMouse(button, row: row, col: col, mods: mods)
        }
    }

    /// Whether a discrete tick may seed a predicted line, given the boundary availability for the
    /// target pane. A tick INTO a document edge (scroll up at the top, scroll down at the bottom)
    /// seeds a line the BEAM can never commit: the eased residual decays to zero while
    /// `scrollUnconfirmedLines` sticks at ±1, parking content one cell off-grid until the next
    /// authoritative reset. Suppress the local prediction there; the scroll intent still sends, so
    /// an at-boundary tick simply does nothing visually, matching reality. `before`/`after` mirror
    /// `presentationScrollBoundaryAvailability`: `before` is content above (needed to scroll up,
    /// `lineDelta < 0`), `after` is content below (needed to scroll down, `lineDelta > 0`).
    nonisolated static func discreteTickSeedsPrediction(lineDelta: Int, boundaryBefore: Int, boundaryAfter: Int) -> Bool {
        if lineDelta < 0 { return boundaryBefore > 0 }
        if lineDelta > 0 { return boundaryAfter > 0 }
        return false
    }

    /// AC3: eases a discrete-wheel line motion locally on the same frame it arrives instead of
    /// teleporting at round-trip latency. The GUI scrolls exactly one line per wheel event
    /// (`@gui_scroll_lines`), so a `lineDelta` of ±1 is seeded as a predicted unconfirmed line;
    /// the draw loop reconciles it against the committed anchor and decays the residual to the
    /// grid. The scroll intent already sent above is unchanged: the BEAM sees an identical report.
    private func seedDiscreteScrollAnimation(row: Int16, col: Int16, lineDelta: Int) {
        guard scrollAnimateEnabled, !isSelectionDragActive else { return }
        // Never fight a live trackpad gesture; discrete and precise input are mutually exclusive.
        guard scrollTargetWindowId == nil else { return }
        guard effectiveCellHeight > 0 else { return }
        guard let windowId = smoothScrollTargetWindowId(row: row, col: col) else { return }

        let windowContent = dispatcher.committedEditorSnapshot?.content(for: windowId)
        if scrollSettleWindowId != windowId {
            scrollSettleAnimator.cancel()
            scrollSettleWindowId = nil
            scrollPixelOffset.y = 0
            scrollUnconfirmedLines = 0
            scrollLastConfirmedAnchor = nil
            scrollWrappedTurningRank = nil
        }
        let reachable: Int
        if let windowContent, windowContent.scrollPresentation?.isWrapped == true {
            guard windowContent.wrappedResidentAnchor != nil else { return }
            reconcileUnconfirmedLines(against: windowContent)
            reachable = wrappedScrollPrediction(lineDelta, content: windowContent)
            guard reachable != 0 else { return }
        } else {
            let boundary = Self.presentationScrollBoundaryAvailability(
                for: windowContent, scrollPresentation: windowContent?.scrollPresentation
            )
            guard Self.discreteTickSeedsPrediction(
                lineDelta: lineDelta, boundaryBefore: boundary.before, boundaryAfter: boundary.after
            ) else { return }
            reachable = lineDelta
        }

        // A discrete tick supersedes an elastic rebound. Clear it before seeding the settle so a
        // rebound owned by another pane cannot be combined with this pane's presentation offset.
        scrollElasticAnimator.cancel()
        scrollElasticWindowId = nil
        scrollElasticOffsetY = 0
        scrollElasticRawDistance = 0

        // Extend any in-flight settle from its current position so rapid ticks accumulate smoothly.
        let residualNow = scrollSettleAnimator.offset()
        scrollUnconfirmedLines += reachable
        let residual = residualNow - CGFloat(reachable) * effectiveCellHeight
        beginScrollSettle(windowId: windowId, residual: residual, duration: Self.scrollDiscreteTickDuration)
    }

    private func sendWheelMouse(_ button: UInt8, row: Int16, col: Int16, mods: UInt8) {
        encoder.send(.mouse(row: row, column: col, button: button, modifiers: mods, eventType: MOUSE_PRESS, clickCount: 1))
    }

    // MARK: - Pinch-to-zoom (magnification gesture)

    /// Accumulated magnification delta since the gesture began.
    private var magnifyAccumulator: CGFloat = 0

    /// Threshold for one font size step. ~0.1 matches a natural pinch increment.
    private let magnifyStepThreshold: CGFloat = 0.1

    /// Font size adjust direction constants matching the protocol.
    private let fontSizeDecrease: UInt8 = 0x00
    private let fontSizeIncrease: UInt8 = 0x01
    private let fontSizeReset: UInt8 = 0x02

    override func magnify(with event: NSEvent) {
        // Dropped during a live resize (see mouseDown): font-size changes mid-resize
        // would invalidate the committed grid the crop is presenting.
        guard !inLiveResize else { return }
        switch event.phase {
        case .began:
            magnifyAccumulator = 0
        default:
            break
        }

        magnifyAccumulator += event.magnification

        while magnifyAccumulator >= magnifyStepThreshold {
            magnifyAccumulator -= magnifyStepThreshold
            encoder.send(.fontSizeAdjust(direction: fontSizeIncrease))
        }

        while magnifyAccumulator <= -magnifyStepThreshold {
            magnifyAccumulator += magnifyStepThreshold
            encoder.send(.fontSizeAdjust(direction: fontSizeDecrease))
        }

        if event.phase == .ended || event.phase == .cancelled {
            magnifyAccumulator = 0
        }
    }

    /// Send committed text from IME to the BEAM as individual key presses.
    private func commitIMEText(_ text: String) {
        for scalar in text.unicodeScalars {
            sendKeyPress(codepoint: scalar.value, modifiers: 0)
        }
    }

    private var currentIMECommitTarget: IMECommitTarget {
        let surface = dispatcher.committedEditorSnapshot?.activeSurface
        return IMECommitTarget(
            connectionGeneration: inputConnectionGeneration,
            windowID: surface?.windowId,
            contentEpoch: surface?.content.contentEpoch
        )
    }

    private var imeCommitTargetIsCurrent: Bool {
        imeCommitTarget == currentIMECommitTarget
    }

    private func cancelIMECompositionIfTargetChanged() {
        guard imeComposition.hasMarkedText, !imeCommitTargetIsCurrent else { return }
        cancelIMEComposition()
    }

    private func cancelIMEComposition() {
        let hadMarkedText = imeComposition.hasMarkedText
        imeComposition.clear()
        imeCommitTarget = nil
        focusPolicy.nativeTextEditingDidEnd()
        textInputCallbacksSuppressed = true
        if hadMarkedText { inputContext?.discardMarkedText() }
        needsDisplay = true
    }

    @discardableResult
    private func handleInputMethodEvent(_ event: NSEvent) -> Bool {
        if let inputMethodEventHandlerForTesting {
            return inputMethodEventHandlerForTesting(event)
        }
        if let inputContext {
            return inputContext.handleEvent(event)
        }
        interpretKeyEvents([event])
        return true
    }

    private static func routesToInputMethodDuringComposition(_ event: NSEvent) -> Bool {
        guard !event.modifierFlags.contains(.control),
              !event.modifierFlags.contains(.command) else { return false }

        switch event.keyCode {
        case 36, 48, 51, 53, 76, 115, 116, 117, 119, 121, 123, 124, 125, 126:
            return true
        default:
            return false
        }
    }

    /// Sends a key press and updates recovery tracking in one place.
    ///
    /// Stamps a latency correlation sequence (ticket #2215) so the resulting
    /// frame's commit_frame resolves a keystroke-to-present sample on the shared
    /// dispatcher recorder.
    private func sendKeyPress(codepoint: UInt32, modifiers: UInt8) {
        updateOptimisticTextInputMode(codepoint: codepoint, modifiers: modifiers)
        dispatcher.previewCompletionNavigation(codepoint: codepoint, modifiers: modifiers)
        dispatcher.previewPickerNavigation(codepoint: codepoint, modifiers: modifiers)
        dispatcher.previewFileTreeNavigation(codepoint: codepoint, modifiers: modifiers)
        recoveryManager?.onKeySent()
        let seq = dispatcher.latency.stamp()
        let composerOffer = codepoint == 13 || codepoint == 102 ? dispatcher.guiState.agentChatState.draftAttachmentOffer : 0
        encoder.send(.keyPress(codepoint: codepoint, modifiers: modifiers, sequence: seq, composerOffer: composerOffer))
    }

    /// Clears stale local text-input prediction when the authoritative BEAM mode changes.
    func statusBarModeDidChange() {
        if !Self.statusModeUsesLiteralSpace(statusMode: statusBarState?.mode) {
            clearOptimisticTextInputMode()
        }
    }

    /// Returns whether frontend space-leader interception should stand down.
    /// BEAM state remains authoritative; this adds a short local prediction so text typed immediately after `i` is not misclassified as a normal-mode leader chord before the status bar message catches up.
    private func spaceLeaderShouldTreatSpaceLiterally() -> Bool {
        if Self.statusModeUsesLiteralSpace(statusMode: statusBarState?.mode) { return true }
        return optimisticTextInputMode
    }

    /// Returns true for BEAM modes where SPC is typed text, not a leader chord.
    /// CUA is encoded as normal mode, so it intentionally stays false here.
    nonisolated static func statusModeUsesLiteralSpace(statusMode: EditorMode?) -> Bool {
        switch statusMode {
        case .insert, .command, .search, .replace:
            return true
        default:
            return false
        }
    }

    /// Keeps the short-lived text-input prediction in sync with outgoing keys.
    private func updateOptimisticTextInputMode(codepoint: UInt32, modifiers: UInt8) {
        if codepoint == 27 {
            clearOptimisticTextInputMode()
            return
        }

        guard modifiers == 0 else { return }
        let statusMode = statusBarState?.mode
        guard !Self.statusModeUsesLiteralSpace(statusMode: statusMode) else { return }
        let cursorShape = dispatcher.committedEditorSnapshot?.metadata.cursorShape ?? .block
        guard Self.shouldOptimisticallyEnterTextInputMode(codepoint: codepoint, statusMode: statusMode, cursorShape: cursorShape) else { return }

        markOptimisticTextInputMode()
    }

    /// Returns true for Vim-normal keys that immediately enter insert-like text input.
    /// The cursor-shape gate avoids applying Vim assumptions while CUA mode is active.
    nonisolated static func shouldOptimisticallyEnterTextInputMode(codepoint: UInt32, statusMode: EditorMode?, cursorShape: CursorShape) -> Bool {
        guard statusMode == .normal, cursorShape == .block else { return false }

        switch codepoint {
        case 0x69, 0x49, 0x61, 0x41, 0x6F, 0x4F, 0x73, 0x53, 0x43, 0x52:
            return true
        default:
            return false
        }
    }

    /// Starts or refreshes the short optimistic text-input window.
    private func markOptimisticTextInputMode() {
        optimisticTextInputMode = true
        optimisticTextInputModeToken &+= 1
        let token = optimisticTextInputModeToken

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(optimisticTextInputModeTimeoutMs)) { [weak self] in
            guard let self, self.optimisticTextInputModeToken == token else { return }
            self.optimisticTextInputMode = false
        }
    }

    /// Clears the local text-input prediction immediately.
    private func clearOptimisticTextInputMode() {
        guard optimisticTextInputMode else { return }
        optimisticTextInputMode = false
        optimisticTextInputModeToken &+= 1
    }

    private func sendSpaceLeaderChord(codepoint: UInt32, modifiers: UInt8) {
        recoveryManager?.onKeySent()
        encoder.send(.spaceLeaderChord(codepoint: codepoint, modifiers: modifiers))
    }

    private func sendSpaceLeaderRetract(codepoint: UInt32, modifiers: UInt8) {
        recoveryManager?.onKeySent()
        encoder.send(.spaceLeaderRetract(codepoint: codepoint, modifiers: modifiers))
    }

    // MARK: - Helpers

    private var effectiveCellHeight: CGFloat {
        let lineSpacing = editorPresentationSnapshot?.frameState.lineSpacing ?? dispatcher.committedEditorSnapshot?.frameState.lineSpacing ?? dispatcher.frameState.lineSpacing
        return cellHeight * CGFloat(lineSpacing)
    }

    private func shouldSendTextDrag(for event: NSEvent) -> Bool {
        if leftMouseDragStarted {
            return true
        }

        let point = convert(event.locationInWindow, from: nil)
        guard let downPoint = leftMouseDownPoint else {
            leftMouseDownPoint = point
            leftMouseDragStarted = true
            return true
        }

        let dx = point.x - downPoint.x
        let dy = point.y - downPoint.y
        let distance = sqrt(dx * dx + dy * dy)
        guard distance >= textDragThreshold else { return false }

        leftMouseDragStarted = true
        return true
    }

    private var dividerHitHalfTolerance: CGFloat {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0
        return 2.5 / scale
    }

    private func dividerHitState(at point: NSPoint) -> DividerCursorState {
        if let region = dividerHitRegion(at: point) {
            return region.rect.height > region.rect.width ? .vertical : .horizontal
        }

        if verticalSeparatorColFromFrameState(at: point) != nil { return .vertical }
        if horizontalSeparatorRowFromFrameState(at: point) != nil { return .horizontal }
        return .none
    }

    private func setDividerCursorState(_ nextState: DividerCursorState) {
        guard dividerCursorState != nextState else { return }
        if dividerCursorState != .none {
            NSCursor.pop()
        }

        switch nextState {
        case .none:
            break
        case .vertical:
            NSCursor.resizeLeftRight.push()
        case .horizontal:
            NSCursor.resizeUpDown.push()
        }

        dividerCursorState = nextState
    }

    private func handleFoldChevronClick(at point: NSPoint) -> Bool {
        guard let (gutter, entry) = foldChevronEntry(at: point),
              let content = editorPresentationSnapshot?.content(for: gutter.windowId) else { return false }
        encoder.send(.foldToggleAtLine(windowID: gutter.windowId, generation: content.accessibilityGeneration, bufferLine: entry.bufLine))
        return true
    }

    private func foldChevronEntry(at point: NSPoint) -> (gutter: Wire.WindowGutter, entry: Wire.GutterEntry)? {
        guard let (gutter, _, entry) = resolvedGutterHit(at: point) else { return nil }
        guard Int(gutter.signColWidth) >= 3 else { return nil }

        let gutterX = CGFloat(gutter.contentCol) * cellWidth + CoreTextMetalRenderer.gutterLeftMarginPt
        let foldColumnOffset = CGFloat(Int(gutter.signColWidth) - 1)
        let foldStartX = gutterX + foldColumnOffset * cellWidth
        guard point.x >= foldStartX && point.x < foldStartX + cellWidth else { return nil }

        switch entry.displayType {
        case .foldOpen, .foldStart:
            return (gutter, entry)
        case .normal, .foldContinuation, .wrapContinuation, .blank:
            return nil
        }
    }

    private func updateGutterHover(at point: NSPoint) {
        let hit = resolvedGutterHit(at: point)
        let nextInGutter = hit != nil
        let nextWindowId = hit?.gutter.windowId
        let nextRowIndex = hit?.rowIndex

        guard nextInGutter != isMouseInGutter || nextWindowId != gutterHoverWindowId || nextRowIndex != gutterHoverRowIndex else { return }
        isMouseInGutter = nextInGutter
        gutterHoverWindowId = nextWindowId
        gutterHoverRowIndex = nextRowIndex
        needsDisplay = true
    }

    private func clearGutterHover() {
        guard isMouseInGutter || gutterHoverWindowId != nil || gutterHoverRowIndex != nil else { return }
        isMouseInGutter = false
        gutterHoverWindowId = nil
        gutterHoverRowIndex = nil
        needsDisplay = true
    }

    private func resolvedGutterHit(at point: NSPoint) -> (gutter: Wire.WindowGutter, rowIndex: Int, entry: Wire.GutterEntry)? {
        guard let (surface, gutter) = gutterHit(at: point) else { return nil }

        // Clip the physical point first, then invert the displayed vertical transform.
        // Rows just outside the committed viewport may now be visible at either edge.
        var y = point.y
        if let presentation = visibleLocalScrollPresentation, presentation.windowId == gutter.windowId {
            y += presentation.offset.y
        }
        let presentationRow = Int(floor(y / effectiveCellHeight)) - Int(gutter.contentRow)
        let rowIndex = surface.content.presentationRowOrigin + presentationRow
        guard let entry = surface.gutterEntry(atRowIndex: rowIndex) else { return nil }
        return (gutter, rowIndex, entry)
    }

    private func gutterHit(at point: NSPoint) -> (surface: PresentedWindowSurface, gutter: Wire.WindowGutter)? {
        guard point.x >= 0, point.y >= 0 else { return nil }
        let screenRow = Int(point.y / effectiveCellHeight)

        guard let snapshot = editorPresentationSnapshot else { return nil }

        if let geometry = paneGeometryGutterHit(at: point, screenRow: screenRow),
           let surface = snapshot.surface(for: geometry.windowId),
           let gutter = surface.gutter.gutter {
            return (surface, gutter)
        }

        for surface in snapshot.surfaces {
            guard let gutter = surface.gutter.gutter else { continue }
            let startRow = Int(gutter.contentRow)
            let endRow = startRow + Int(gutter.contentHeight)
            guard screenRow >= startRow && screenRow < endRow else { continue }

            let gutterX = CGFloat(gutter.contentCol) * cellWidth + CoreTextMetalRenderer.gutterLeftMarginPt
            let gutterWidth = CGFloat(gutter.lineNumberWidth) + CGFloat(gutter.signColWidth)
            let gutterEndX = gutterX + gutterWidth * cellWidth
            guard point.x >= gutterX && point.x < gutterEndX else { continue }

            return (surface, gutter)
        }

        return nil
    }

    private func cellPosition(from event: NSEvent) -> (row: Int16, col: Int16) {
        clearSmoothScrollStateIfTargetWindowMissing()
        let rawPoint = convert(event.locationInWindow, from: nil)
        let point = presentationNormalizedPoint(rawPoint)
        let row = Int16(point.y / effectiveCellHeight)
        let col = cellColumn(at: point, row: row)
        return (row, col)
    }

    private func presentationNormalizedPoint(_ point: NSPoint) -> NSPoint {
        let presentation = visibleLocalScrollPresentation
        let rawRow = Int16(point.y / effectiveCellHeight)
        let rawCol = max(0, Int16(point.x / cellWidth))
        let rawPointWindowId = smoothScrollTargetWindowId(row: rawRow, col: rawCol)
        let content = presentation.flatMap { editorPresentationSnapshot?.content(for: $0.windowId) }
        return Self.presentationNormalizedPoint(
            point,
            rawPointWindowId: rawPointWindowId,
            presentation: presentation,
            targetContentRect: content?.paneGeometry?.contentRect,
            scrollLeft: content?.scrollLeft ?? 0,
            cellWidth: cellWidth,
            cellHeight: effectiveCellHeight
        )
    }

    /// Maps a raw pointer point through the exact local transform used to draw its pane.
    nonisolated static func presentationNormalizedPoint(
        _ point: NSPoint,
        rawPointWindowId: UInt16?,
        presentation: LocalScrollPresentation?,
        targetContentRect: GUICellRect?,
        scrollLeft: UInt16,
        cellWidth: CGFloat,
        cellHeight: CGFloat
    ) -> NSPoint {
        guard let presentation, rawPointWindowId == presentation.windowId else { return point }
        guard hasActivePresentationOffset(scrollPixelOffset: presentation.offset, scrollElasticOffsetY: 0) else { return point }
        let offset = presentationScrollOffset(scrollLeft: scrollLeft, scrollOffset: presentation.offset)
        let normalized = NSPoint(x: point.x + offset.x, y: point.y + offset.y)
        guard let targetContentRect else { return normalized }
        return clampPresentationPoint(normalized, to: targetContentRect, cellWidth: cellWidth, cellHeight: cellHeight)
    }

    nonisolated static func hasActivePresentationOffset(scrollPixelOffset: CGPoint, scrollElasticOffsetY: CGFloat) -> Bool {
        scrollPixelOffset.x != 0 || scrollPixelOffset.y != 0 || scrollElasticOffsetY != 0
    }

    nonisolated static func presentationScrollOffset(scrollLeft: UInt16, scrollOffset: CGPoint) -> CGPoint {
        let x = scrollLeft == 0 && scrollOffset.x < 0 ? 0 : scrollOffset.x
        return CGPoint(x: x, y: scrollOffset.y)
    }

    nonisolated static func clampPresentationPoint(_ point: NSPoint, to rect: GUICellRect, cellWidth: CGFloat, cellHeight: CGFloat) -> NSPoint {
        guard rect.width > 0, rect.height > 0, cellWidth > 0, cellHeight > 0 else { return point }
        let minX = CGFloat(rect.col) * cellWidth
        let maxX = CGFloat(Int(rect.col) + Int(rect.width)) * cellWidth - 0.001
        let minY = CGFloat(rect.row) * cellHeight
        let maxY = CGFloat(Int(rect.row) + Int(rect.height)) * cellHeight - 0.001
        return NSPoint(x: min(max(point.x, minX), maxX), y: min(max(point.y, minY), maxY))
    }

    private func rawCellPosition(at point: NSPoint) -> (row: Int16, col: Int16) {
        let row = max(0, Int16(point.y / effectiveCellHeight))
        let col = max(0, Int16(point.x / cellWidth))
        return (row, col)
    }

    private func dividerPressCellPosition(at point: NSPoint, state: DividerCursorState) -> (row: Int16, col: Int16) {
        let raw = rawCellPosition(at: point)

        switch state {
        case .vertical:
            guard let separatorCol = verticalSeparatorCol(at: point) else { return raw }
            return (raw.row, Int16(separatorCol))
        case .horizontal:
            guard let separatorRow = horizontalSeparatorRow(at: point) else { return raw }
            return (Int16(separatorRow), raw.col)
        case .none:
            return raw
        }
    }

    private func verticalSeparatorCol(at point: NSPoint) -> UInt16? {
        if let region = dividerHitRegion(at: point), region.rect.height > region.rect.width {
            return region.rect.col
        }
        return verticalSeparatorColFromFrameState(at: point)
    }

    private func horizontalSeparatorRow(at point: NSPoint) -> UInt16? {
        if let region = dividerHitRegion(at: point), region.rect.width >= region.rect.height {
            return region.rect.row
        }
        return horizontalSeparatorRowFromFrameState(at: point)
    }

    private func cellColumn(at point: NSPoint, row: Int16) -> Int16 {
        guard let gutter = gutterForCellPosition(at: point, row: row) else {
            return fallbackCellColumn(at: point)
        }

        let windowLeft = CGFloat(gutter.contentCol) * cellWidth
        let localX = point.x - windowLeft
        let gutterCols = CGFloat(gutter.lineNumberWidth) + CGFloat(gutter.signColWidth)
        guard gutterCols > 0 else {
            return max(0, Int16(point.x / cellWidth))
        }

        let localCol = localCellColumn(at: localX, gutterCols: gutterCols)
        return max(0, Int16(gutter.contentCol) + localCol)
    }

    private func gutterForCellPosition(at point: NSPoint, row: Int16) -> Wire.WindowGutter? {
        guard row >= 0 else { return nil }
        let rowValue = Int(row)
        guard let snapshot = editorPresentationSnapshot else { return nil }
        let gutters = snapshot.windowGutters

        if let geometry = paneGeometryHit(at: point, screenRow: rowValue),
           let gutter = gutters[geometry.windowId] {
            return gutter
        }

        return snapshot.windowIds.compactMap { gutters[$0] }
            .filter { gutter in
                let startRow = Int(gutter.contentRow)
                let endRow = startRow + Int(gutter.contentHeight)
                let startX = CGFloat(gutter.contentCol) * cellWidth
                let endX = startX + CGFloat(CoreTextMetalRenderer.windowWidthCols(gutter: gutter, frameCols: snapshot.frameState.cols)) * cellWidth
                return rowValue >= startRow && rowValue < endRow && point.x >= startX && point.x < endX
            }
            .max { lhs, rhs in lhs.contentCol < rhs.contentCol }
    }

    private func paneGeometryGutterHit(at point: NSPoint, screenRow: Int) -> GUIPaneGeometry? {
        paneGeometries(at: point, screenRow: screenRow)
            .filter { geometry in
                geometry.hitRegions.contains { region in
                    (region.kind == .gutter || region.kind == .foldControl) && pointInCellRect(point, screenRow: screenRow, rect: region.rect)
                }
            }
            .max { lhs, rhs in lhs.gutterRect.col < rhs.gutterRect.col }
    }

    private func paneGeometryHit(at point: NSPoint, screenRow: Int) -> GUIPaneGeometry? {
        paneGeometries(at: point, screenRow: screenRow)
            .max { lhs, rhs in lhs.totalRect.col < rhs.totalRect.col }
    }

    private func paneGeometries(at point: NSPoint, screenRow: Int) -> [GUIPaneGeometry] {
        guard let snapshot = editorPresentationSnapshot else { return [] }
        let rawCol = Int(point.x / cellWidth)

        return snapshot.surfaces.map(\.paneGeometry).filter { geometry in
            rowColInCellRect(row: screenRow, col: rawCol, rect: geometry.totalRect)
        }
    }

    private func hitRegion(at point: NSPoint, kind: GUIHitRegion.Kind) -> GUIHitRegion? {
        guard let snapshot = editorPresentationSnapshot else { return nil }
        let screenRow = Int(point.y / effectiveCellHeight)
        let rawCol = Int(point.x / cellWidth)

        return snapshot.surfaces
            .map(\.paneGeometry)
            .flatMap(\.hitRegions)
            .filter { region in
                region.kind == kind && rowColInCellRect(row: screenRow, col: rawCol, rect: region.rect)
            }
            .max { lhs, rhs in lhs.rect.col < rhs.rect.col }
    }

    private func dividerHitRegion(at point: NSPoint) -> GUIHitRegion? {
        guard let snapshot = editorPresentationSnapshot else { return nil }
        let screenRow = Int(point.y / effectiveCellHeight)
        let rawCol = Int(point.x / cellWidth)

        return snapshot.surfaces
            .map(\.paneGeometry)
            .flatMap(\.hitRegions)
            .filter { region in
                region.kind == .divider && pointInDividerHitBounds(point, screenRow: screenRow, rawCol: rawCol, region: region)
            }
            .max { lhs, rhs in lhs.rect.col < rhs.rect.col }
    }

    private func pointInDividerHitBounds(_ point: NSPoint, screenRow: Int, rawCol: Int, region: GUIHitRegion) -> Bool {
        if region.rect.height > region.rect.width {
            let startRow = Int(region.rect.row)
            let endRow = startRow + Int(region.rect.height)
            return screenRow >= startRow && screenRow < endRow && pointInDividerLineTolerance(point, region: region)
        }

        let startCol = Int(region.rect.col)
        let endCol = startCol + Int(region.rect.width)
        return rawCol >= startCol && rawCol < endCol && pointInDividerLineTolerance(point, region: region)
    }

    private func pointInDividerLineTolerance(_ point: NSPoint, region: GUIHitRegion) -> Bool {
        if region.rect.height > region.rect.width {
            let lineX = CGFloat(region.rect.col) * cellWidth
            return abs(point.x - lineX) <= dividerHitHalfTolerance
        }

        let lineY = CGFloat(region.rect.row) * effectiveCellHeight + effectiveCellHeight * 0.5
        return abs(point.y - lineY) <= dividerHitHalfTolerance
    }

    private func verticalSeparatorColFromFrameState(at point: NSPoint) -> UInt16? {
        let screenRow = Int(point.y / effectiveCellHeight)
        guard let snapshot = editorPresentationSnapshot else { return nil }
        return snapshot.metadata.verticalSeparators.first { separator in
            let lineX = CGFloat(separator.col) * cellWidth
            return screenRow >= Int(separator.startRow) && screenRow <= Int(separator.endRow) && abs(point.x - lineX) <= dividerHitHalfTolerance
        }?.col
    }

    private func horizontalSeparatorRowFromFrameState(at point: NSPoint) -> UInt16? {
        let rawCol = Int(point.x / cellWidth)
        guard let snapshot = editorPresentationSnapshot else { return nil }
        return snapshot.metadata.horizontalSeparators.first { separator in
            let lineY = CGFloat(separator.row) * effectiveCellHeight + effectiveCellHeight * 0.5
            let startCol = Int(separator.col)
            let endCol = startCol + Int(separator.width)
            return rawCol >= startCol && rawCol < endCol && abs(point.y - lineY) <= dividerHitHalfTolerance
        }?.row
    }

    private func pointInCellRect(_ point: NSPoint, screenRow: Int, rect: GUICellRect) -> Bool {
        let rawCol = Int(point.x / cellWidth)
        return rowColInCellRect(row: screenRow, col: rawCol, rect: rect)
    }

    private func rowColInCellRect(row: Int, col: Int, rect: GUICellRect) -> Bool {
        let startRow = Int(rect.row)
        let endRow = startRow + Int(rect.height)
        let startCol = Int(rect.col)
        let endCol = startCol + Int(rect.width)
        return row >= startRow && row < endRow && col >= startCol && col < endCol
    }

    private func fallbackCellColumn(at point: NSPoint) -> Int16 {
        let gutterCols = CGFloat(editorPresentationSnapshot?.gutterCol ?? 0)
        guard gutterCols > 0 else {
            return max(0, Int16(point.x / cellWidth))
        }

        return localCellColumn(at: point.x, gutterCols: gutterCols)
    }

    private func localCellColumn(at localX: CGFloat, gutterCols: CGFloat) -> Int16 {
        let leftMargin = CoreTextMetalRenderer.gutterLeftMarginPt
        let rightGap = CoreTextMetalRenderer.gutterRightGapPt
        let gutterPixelEnd = leftMargin + gutterCols * cellWidth

        if localX < gutterPixelEnd {
            return max(0, Int16((localX - leftMargin) / cellWidth))
        }

        return max(0, Int16((localX - leftMargin - rightGap) / cellWidth))
    }
}

// MARK: - Key mapping

private func modifierBits(from flags: NSEvent.ModifierFlags) -> UInt8 {
    var mods: UInt8 = 0
    if flags.contains(.shift)   { mods |= 0x01 }
    if flags.contains(.control) { mods |= 0x02 }
    if flags.contains(.option)  { mods |= 0x04 }
    if flags.contains(.command) { mods |= 0x08 }
    return mods
}

// MARK: - NSTextInputClient (IME support)

@MainActor
extension EditorNSView: @MainActor NSTextInputClient {
    /// Called when the input method commits text (final result of composition).
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        if let attrStr = string as? NSAttributedString {
            text = attrStr.string
        } else if let str = string as? String {
            text = str
        } else {
            return
        }

        let wasComposing = imeComposition.hasMarkedText
        let targetIsCurrent = !wasComposing || imeCommitTargetIsCurrent
        imeComposition.clear()
        imeCommitTarget = nil
        focusPolicy.nativeTextEditingDidEnd()
        if wasComposing && !targetIsCurrent { textInputCallbacksSuppressed = true }

        // Send committed text to the BEAM.
        guard !textInputCallbacksSuppressed, targetIsCurrent, !text.isEmpty else { return }
        commitIMEText(text)
        needsDisplay = true
    }

    /// Called during IME composition to show intermediate text.
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text: String
        if let attrStr = string as? NSAttributedString {
            text = attrStr.string
        } else if let str = string as? String {
            text = str
        } else {
            return
        }

        guard !textInputCallbacksSuppressed else { return }
        if !imeComposition.hasMarkedText {
            imeCommitTarget = currentIMECommitTarget
        }
        guard imeCommitTargetIsCurrent else {
            cancelIMEComposition()
            return
        }
        imeComposition.setMarked(text: text, selectedRange: selectedRange,
                                 replacementRange: replacementRange)
        if !imeComposition.hasMarkedText { imeCommitTarget = nil }
        needsDisplay = true
    }

    /// Called to finalize/clear the composition.
    func unmarkText() {
        let targetIsCurrent = imeCommitTargetIsCurrent
        if !textInputCallbacksSuppressed, targetIsCurrent,
           let text = imeComposition.unmark()
        {
            commitIMEText(text)
        } else {
            imeComposition.clear()
            if !targetIsCurrent { textInputCallbacksSuppressed = true }
        }
        imeCommitTarget = nil
        focusPolicy.nativeTextEditingDidEnd()
        needsDisplay = true
    }

    /// Returns the range of the current composition text.
    func markedRange() -> NSRange {
        return imeComposition.markedRange
    }

    /// Returns the range of the current selection (cursor position as zero-length range).
    func selectedRange() -> NSRange {
        return NSRange(location: accessibilityCursorOffset(), length: 0)
    }

    func hasMarkedText() -> Bool {
        return imeComposition.hasMarkedText
    }

    /// Returns the screen rect for the given character range.
    /// Used by the IME to position the candidate window.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range

        let localRect = visibleCursorRect()

        // Convert to screen coordinates.
        guard let window else { return localRect }
        let windowRect = convert(localRect, to: nil)
        return window.convertToScreen(windowRect)
    }

    /// Returns the character index closest to a screen point.
    func characterIndex(for point: NSPoint) -> Int {
        guard let window else { return 0 }
        let windowPoint = window.convertPoint(fromScreen: point)
        let localPoint = convert(windowPoint, from: nil)
        if editorPresentation?.textLayout?.renderedWindowIDs.isEmpty == true { return 0 }
        synchronizeAccessibilityPresentation()
        if let hit = editorPresentation?.textLayout?.hit(at: localPoint),
           let projection = accessibilityProjections.first(where: { $0.identity.windowID == hit.target.windowID }),
           let row = projection.rows.first(where: { $0.absoluteRow == Int(hit.target.rowIndex) }) {
            return row.insertionRange(atSourceUTF16Offset: Int(hit.target.utf16Offset))?.location ?? 0
        }
        let point = presentationNormalizedPoint(localPoint)
        let row = max(0, Int(point.y / effectiveCellHeight))
        let col = max(0, Int(cellColumn(at: point, row: Int16(clamping: row))))
        return row * Int(editorPresentationSnapshot?.frameState.cols ?? 0) + col
    }

    /// Returns the attributed substring for the given range.
    /// Used by the IME to inspect surrounding text context.
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        // We don't have a local text model. Return nil gracefully.
        actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
        return nil
    }

    /// Attributes that can be applied to marked text.
    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return [.underlineStyle, .underlineColor]
    }

    private func visibleCursorRect() -> NSRect {
        guard let surface = editorPresentationSnapshot?.activeSurface else {
            return NSRect(x: 0, y: 0, width: cellWidth, height: effectiveCellHeight)
        }
        let content = surface.content
        if let layout = editorPresentation?.textLayout, !layout.renderedWindowIDs.contains(surface.windowId) {
            return .zero
        }
        if let cursor = content.accessibilityCursor,
           let layout = editorPresentation?.textLayout,
           let pane = layout.panes.first(where: { $0.windowID == surface.windowId }),
           let point = layout.cursor(windowID: surface.windowId, row: cursor.row, utf16: cursor.utf16) {
            return CGRect(x: point.x - pane.scrollOffset.x, y: point.y - pane.scrollOffset.y, width: cellWidth, height: effectiveCellHeight)
                .intersection(pane.rect)
        }
        let scrollLeft = CGFloat(content.scrollLeft) * cellWidth
        let localOffset = visibleLocalScrollPresentation?.windowId == surface.windowId ? visibleLocalScrollPresentation?.offset ?? .zero : .zero
        let cursorCol = surface.residentSemantics.map { UInt32($0.cursor.col) } ?? UInt32(content.cursorCol)
        let cursorRow = surface.residentSemantics.map { UInt32(clamping: Int($0.cursor.row) - surface.visibleRowRange.lowerBound) } ?? UInt32(content.cursorRow)
        let x = CGFloat(surface.paneGeometry.textRect.col) * cellWidth + CGFloat(cursorCol) * cellWidth - scrollLeft - localOffset.x
        let y = CGFloat(surface.paneGeometry.textRect.row) * effectiveCellHeight + CGFloat(cursorRow) * effectiveCellHeight - localOffset.y
        return NSRect(x: x, y: y, width: cellWidth, height: effectiveCellHeight)
    }

    private func accessibilityCursorOffset() -> Int {
        synchronizeAccessibilityPresentation()
        return accessibilityProjections.first(where: \.isActivePane)?.insertionRange?.location ?? 0
    }
}

// MARK: - NSAccessibility (VoiceOver support)

private struct AccessibilityProjectionKey: Equatable {
    let connectionID: UInt64
    let generation: UInt32
    let frameSeq: UInt32
    let localTransform: EditorLocalPresentationTransform?
    let promptTransform: AgentPromptPresentationTransform?
    let cellWidth: CGFloat
    let cellHeight: CGFloat
}

/// Bridges the main-actor pane projection to AppKit's nonisolated focused-element getter.
private final class AccessibilityFocusedElementSnapshot: @unchecked Sendable {
    // @unchecked: EditorPaneAccessibilityElement is an NSAccessibilityElement subclass and not Sendable; `lock` guards every access to `element`.
    private let lock = Mutex(())
    private var element: EditorPaneAccessibilityElement?

    func read() -> EditorPaneAccessibilityElement? {
        // Copy through a local so the result is not a `sending` value; the element is not Sendable.
        var current: EditorPaneAccessibilityElement?
        lock.withLock { _ in current = element }
        return current
    }

    func write(_ element: EditorPaneAccessibilityElement?) {
        lock.withLock { _ in self.element = element }
    }
}

extension EditorNSView {
    override func accessibilityRole() -> NSAccessibility.Role? {
        return .group
    }

    override func accessibilityRoleDescription() -> String? {
        return "editor panes"
    }

    override func accessibilityValue() -> Any? {
        return nil
    }

    override func accessibilityNumberOfCharacters() -> Int {
        return 0
    }

    override func accessibilityInsertionPointLineNumber() -> Int {
        return NSNotFound
    }

    override func accessibilitySelectedText() -> String? {
        return nil
    }

    override func accessibilitySelectedTextRange() -> NSRange {
        return NSRange(location: NSNotFound, length: 0)
    }

    override func accessibilityChildren() -> [Any]? {
        accessibilityPaneElements()
    }

    nonisolated override var accessibilityFocusedUIElement: Any? {
        accessibilityFocusedElementSnapshot.read()
    }

    override func isAccessibilityElement() -> Bool {
        return true
    }

    override func isAccessibilityEnabled() -> Bool {
        return true
    }

    var accessibilityHasNativeKeyboardFocus: Bool {
        NSApp.isActive && window?.isKeyWindow == true && window?.firstResponder === self
    }

    func accessibilityProjection(for identity: EditorAccessibilityIdentity) -> EditorAccessibilityProjection? {
        synchronizeAccessibilityPresentation()
        return accessibilityProjections.first { $0.identity == identity }
    }

    func accessibilityScreenRect(for localRect: CGRect) -> NSRect {
        guard let window else { return localRect }
        return window.convertToScreen(convert(localRect, to: nil))
    }

    func accessibilityLocalPoint(fromScreen point: NSPoint) -> NSPoint {
        guard let window else { return point }
        return convert(window.convertPoint(fromScreen: point), from: nil)
    }

    func requestAccessibilityFocus(for identity: EditorAccessibilityIdentity) {
        guard accessibilityProjection(for: identity) != nil,
              focusPolicy.requestAccessibilityFocus() else { return }
        refreshAccessibilityNativeFocus()
        encoder.send(.focusWindow(windowID: identity.windowID, generation: identity.generation))
    }

    func nativeApplicationFocusDidSettle() {
        refreshAccessibilityNativeFocus()
        guard let focusedPane = accessibilityFocusedUIElement else { return }
        NSAccessibility.post(element: focusedPane, notification: .focusedUIElementChanged)
    }

    private func accessibilityPaneElements() -> [EditorPaneAccessibilityElement] {
        synchronizeAccessibilityPresentation()
        let projections = accessibilityProjections
        let identities = Set(projections.map(\.identity))
        for (identity, element) in accessibilityPaneCache where !identities.contains(identity) {
            element.invalidate()
        }
        accessibilityPaneCache = accessibilityPaneCache.filter { identities.contains($0.key) }
        let paneElements = projections.map { projection in
            if let existing = accessibilityPaneCache[projection.identity] {
                existing.update(projection: projection, owner: self)
                return existing
            }
            let element = EditorPaneAccessibilityElement(owner: self, projection: projection)
            accessibilityPaneCache[projection.identity] = element
            return element
        }
        updateAccessibilityFocusedElement(paneElements)
        return paneElements
    }

    private func buildAccessibilityProjections() -> [EditorAccessibilityProjection] {
        guard let presentation = editorPresentation, cellWidth > 0, effectiveCellHeight > 0 else { return [] }
        let snapshot = presentation.snapshot
        return snapshot.surfaces
            .filter { presentation.textLayout?.renderedWindowIDs.contains($0.windowId) ?? true }
            .sorted { lhs, rhs in
                let left = lhs.paneGeometry.textRect
                let right = rhs.paneGeometry.textRect
                return (left.row, left.col, lhs.windowId) < (right.row, right.col, rhs.windowId)
            }
            .map { surface in
                EditorAccessibilityProjection.build(
                    surface: surface,
                    connectionID: dispatcher.connectionID,
                    isActivePane: snapshot.activeSurface?.windowId == surface.windowId,
                    localTransform: presentation.localTransform,
                    cellWidth: cellWidth,
                    cellHeight: effectiveCellHeight,
                    promptTransform: presentation.textLayout?.promptTransform
                )
            }
    }

    private func synchronizeAccessibilityPresentation() {
        guard let presentation = editorPresentation else {
            accessibilityProjectionKey = nil
            accessibilityProjections = []
            return
        }
        let snapshot = presentation.snapshot
        let key = AccessibilityProjectionKey(
            connectionID: dispatcher.connectionID,
            generation: snapshot.generation,
            frameSeq: snapshot.frameSeq,
            localTransform: presentation.localTransform,
            promptTransform: presentation.textLayout?.promptTransform,
            cellWidth: cellWidth,
            cellHeight: effectiveCellHeight
        )
        guard key != accessibilityProjectionKey else { return }
        accessibilityProjectionKey = key
        accessibilityProjections = buildAccessibilityProjections()
    }

    private func refreshAccessibilityNativeFocus() {
        let focused = accessibilityHasNativeKeyboardFocus
        for element in accessibilityPaneCache.values {
            element.updateNativeKeyboardFocus(focused)
        }
        _ = accessibilityPaneElements()
    }

    private func clearAccessibilityNativeFocus() {
        for element in accessibilityPaneCache.values {
            element.updateNativeKeyboardFocus(false)
        }
        accessibilityFocusedElementSnapshot.write(nil)
    }

    private func updateAccessibilityFocusedElement(_ paneElements: [EditorPaneAccessibilityElement]) {
        guard accessibilityHasNativeKeyboardFocus,
              let activeIdentity = accessibilityProjections.first(where: \.isActivePane)?.identity
        else {
            accessibilityFocusedElementSnapshot.write(nil)
            return
        }
        accessibilityFocusedElementSnapshot.write(
            paneElements.first(where: { $0.identity == activeIdentity })
        )
    }

    private func invalidateAccessibilityConnection() {
        for element in accessibilityPaneCache.values {
            element.invalidate()
        }
        accessibilityPaneCache.removeAll(keepingCapacity: true)
        accessibilityProjections.removeAll(keepingCapacity: true)
        accessibilityProjectionKey = nil
        accessibilityFocusedElementSnapshot.write(nil)
        lastAccessibilityIdentities.removeAll(keepingCapacity: true)
        lastAccessibilitySelections.removeAll(keepingCapacity: true)
        lastAccessibilityActiveIdentity = nil
    }

    private func publishAccessibilityPresentationChanges() {
        synchronizeAccessibilityPresentation()
        let projections = accessibilityProjections
        let paneElements = accessibilityPaneElements()
        let identities = Set(projections.map(\.identity))
        if identities != lastAccessibilityIdentities {
            lastAccessibilityIdentities = identities
            NSAccessibility.post(element: self, notification: .layoutChanged)
        }

        let selections = Dictionary(uniqueKeysWithValues: projections.map { projection in
            let ranges = projection.selectedRanges.isEmpty ? projection.insertionRange.map { [$0] } ?? [] : projection.selectedRanges
            return (projection.identity, ranges.map(NSStringFromRange).joined(separator: ","))
        })
        for projection in projections where selections[projection.identity] != lastAccessibilitySelections[projection.identity] {
            if let element = paneElements.first(where: { $0.identity == projection.identity }) {
                NSAccessibility.post(element: element, notification: .selectedTextChanged)
            }
        }
        lastAccessibilitySelections = selections

        let activeIdentity = projections.first(where: \.isActivePane)?.identity
        if activeIdentity != lastAccessibilityActiveIdentity {
            lastAccessibilityActiveIdentity = activeIdentity
            if let focusedPane = accessibilityFocusedUIElement {
                NSAccessibility.post(element: focusedPane, notification: .focusedUIElementChanged)
            }
        }
    }
}

/// Map special keys to Kitty keyboard protocol codepoints.
private func mapKeyCode(_ event: NSEvent) -> UInt32? {
    switch event.keyCode {
    case 36:  return 13     // Return
    case 48:  return 9      // Tab
    case 51:  return 127    // Backspace / Delete
    case 53:  return 27     // Escape
    case 123: return 57350  // Left arrow
    case 124: return 57351  // Right arrow
    case 125: return 57353  // Down arrow
    case 126: return 57352  // Up arrow
    case 115: return 57360  // Home
    case 119: return 57361  // End
    case 116: return 57362  // Page Up
    case 121: return 57363  // Page Down
    case 117: return 57376  // Forward Delete
    case 122: return 57364  // F1
    case 120: return 57365  // F2
    case 99:  return 57366  // F3
    case 118: return 57367  // F4
    case 96:  return 57368  // F5
    case 97:  return 57369  // F6
    case 98:  return 57370  // F7
    case 100: return 57371  // F8
    case 101: return 57372  // F9
    case 109: return 57373  // F10
    case 103: return 57374  // F11
    case 111: return 57375  // F12
    default:  return nil
    }
}

// MARK: - Drag and drop

extension EditorNSView {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) else {
            return []
        }
        showDropHighlight()
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideDropHighlight()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hideDropHighlight()

        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else {
            return false
        }

        for url in urls {
            encoder.send(.openFile(path: url.path))
        }

        focusPolicy.fileDropDidComplete()
        return true
    }

    private func showDropHighlight() {
        guard dropHighlightLayer == nil, let metalLayer = layer else { return }
        let highlight = CAShapeLayer()
        highlight.path = CGPath(
            roundedRect: bounds.insetBy(dx: 2, dy: 2),
            cornerWidth: 6,
            cornerHeight: 6,
            transform: nil
        )
        highlight.strokeColor = NSColor.controlAccentColor.cgColor
        highlight.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        highlight.lineWidth = 3
        metalLayer.addSublayer(highlight)
        dropHighlightLayer = highlight
    }

    private func hideDropHighlight() {
        dropHighlightLayer?.removeFromSuperlayer()
        dropHighlightLayer = nil
    }
}
