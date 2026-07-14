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
import MetalKit
import MingaProtocol

private enum DividerCursorState: Equatable {
    case none
    case vertical
    case horizontal
}

private enum EditorStatusMode {
    static let normal: UInt8 = 0
    static let insert: UInt8 = 1
    static let command: UInt8 = 3
    static let search: UInt8 = 5
    static let replace: UInt8 = 6
}

/// The main editor view. Uses MTKView's built-in display link for
/// vsync-driven rendering with automatic frame coalescing.
final class EditorNSView: MTKView {
    var encoder: InputEncoder
    public private(set) var fontFace: FontFace

    /// Command dispatcher owning frame metadata.
    let dispatcher: CommandDispatcher

    /// CoreText-based renderer.
    let coreTextRenderer: CoreTextMetalRenderer

    /// Narrow drawable acquisition seam. Production leaves this nil and uses
    /// MTKView.currentDrawable; tests may inject nil without retaining a drawable.
    var drawableProvider: (() -> CAMetalDrawable?)?

    /// Font manager for per-span font family support.
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

    /// IME composition state (marked text tracking).
    private var imeComposition = IMEComposition()

    /// Cell dimensions in points (used for mouse → cell coordinate mapping).
    var cellWidth: CGFloat { fontFace.cellWidth }
    var cellHeight: CGFloat { CGFloat(fontFace.cellHeight) }

    /// Track last reported cell position to avoid flooding the Port with
    /// redundant mouse move events.
    private var lastMoveRow: Int16 = -1
    private var lastMoveCol: Int16 = -1

    /// Gutter hover state used for fold chevron visibility and range highlight.
    private var isMouseInGutter: Bool = false
    private var gutterHoverWindowId: UInt16?
    private var gutterHoverRow: UInt16?

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

    /// Multiplier applied to system cursor blink timing under thermal or low-power pressure. A value of 0 keeps the cursor solid.
    private var cursorBlinkMultiplier: UInt64 = 1

    /// Last viewport top used for scroll indicator change detection.
    private var lastViewportTopForScroll: UInt32 = 0xFFFF_FFFF

    private struct GridDimensions {
        let cols: UInt16
        /// Content rows-that-fit at the current presentation metrics: one floor of
        /// content pixels by the spaced cell height (ADR-0001). This is the value
        /// reported on the wire and the value the BEAM lays out in; there is no
        /// separate unspaced "raw" row count anymore.
        let rows: UInt16
    }

    /// First responder guard that prevents SwiftUI from stealing keyboard focus.
    /// Installed when the view moves to a window.
    private var firstResponderGuard: FirstResponderGuard?

    /// Window currently registered for key/resign notifications.
    private weak var observedWindow: NSWindow?

    /// When true, the agent chat SwiftUI overlay is visible. The Metal
    /// surface is at opacity(0) so the SwiftUI overlay is not occluded
    /// by the NSView layer. A local key event monitor forwards keyboard
    /// events to keyDown since opacity(0) disconnects normal event
    /// delivery from the SwiftUI hosting layer.
    public private(set) var agentChatVisible: Bool = false

    /// Local event monitor that forwards keyboard events to keyDown
    /// when the agent chat overlay is visible. Installed/removed by
    /// setAgentChatVisible. This is Apple's documented API for event
    /// interception when NSWindow subclassing isn't available.
    private var agentKeyMonitor: Any?

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
    /// The Metal renderer ANDs this with `frameState.cursorVisible` to
    /// determine whether to draw the cursor.
    public private(set) var cursorBlinkVisible: Bool = true

    /// Whether Minga config allows blinking the editor cursor.
    private var cursorBlinkEnabled: Bool = true

    /// The async task driving the blink timer. Cancelled on focus loss,
    /// cursor hide, or dealloc.
    private var blinkTask: Task<Void, Never>?

    /// Task observing accessibility display options changes.
    private var accessibilityTask: Task<Void, Never>?

    /// Task observing system scroller style changes.
    private var scrollerStyleTask: Task<Void, Never>?

    init(encoder: InputEncoder, fontFace: FontFace, dispatcher: CommandDispatcher,
         coreTextRenderer: CoreTextMetalRenderer, fontManager: FontManager) {
        self.encoder = encoder
        self.fontFace = fontFace
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

        coreTextRenderer.setCursorAnimationReduceMotionDisabled(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        scrollAnimationsReduceMotionDisabled = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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
        dispatcher.discardPendingPresentation(reason: .hidden)
        cleanupBlinkResources()
        cancelThumbDragWithFlush()
        resetSmoothScrollState()
        scrollerStyleTask?.cancel()
        scrollerStyleTask = nil
        scrollFadeWorkItem?.cancel()
        scrollFadeWorkItem = nil
        scrollIndicatorDragOffset = nil
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
        removeAgentKeyMonitor()
        firstResponderGuard = nil
    }

    override var acceptsFirstResponder: Bool { true }
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

    /// Sub-cell vertical/horizontal pixel offset for smooth trackpad scrolling.
    /// Positive = content shifted up/left. Each component stays within one cell.
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
    struct LocalScrollPresentation: Equatable {
        let windowId: UInt16
        let offset: CGPoint
    }

    /// The local scroll presentation for this frame or input event.
    /// Decouples "which window shows the offset" from "a gesture is active": during a settle or
    /// spring-back the gesture target is nil (so `onScrollPresentationReset` discards can win),
    /// but the offset must still land on the settling/elastic pane.
    private var localScrollPresentation: LocalScrollPresentation? {
        Self.localScrollPresentation(
            targetWindowId: scrollTargetWindowId,
            thumbDragWindowId: thumbDragSession?.windowId,
            settleWindowId: scrollSettleWindowId,
            elasticWindowId: scrollElasticWindowId,
            scrollPixelOffset: scrollPixelOffset,
            scrollElasticOffsetY: scrollElasticOffsetY
        )
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
    /// button-held phase until the BEAM's echo-marked commit reaches the target (or an authoritative
    /// interrupt / watchdog fires), so discards stay gated (see `hasActiveScrollGesture`) through the
    /// reconcile.
    private var thumbDragSession: ThumbDragSession?

    /// True while a trackpad scroll gesture or a resident thumb-drag presentation is in
    /// progress. While true, authoritative-anchor discards (`onScrollPresentationReset`)
    /// are ignored so the reconcile owns the offset instead of a mid-gesture reset
    /// zeroing it. The thumb-drag half stays true through the post-release reconcile.
    var hasActiveScrollGesture: Bool { scrollTargetWindowId != nil || thumbDragSession != nil }

    /// Cell position that owns the current precise scroll gesture.
    /// Nil means the gesture has not latched onto a scroll target yet.
    private var scrollTargetCellPosition: (row: Int16, col: Int16)?

    private enum ScrollAxisLock { case undecided, vertical, horizontal }
    private var scrollAxisLock: ScrollAxisLock = .undecided
    private var scrollAxisAccumulatedX: CGFloat = 0
    private var scrollAxisAccumulatedY: CGFloat = 0
    private static let axisLockThreshold: CGFloat = 4

    private var scrollUnconfirmedLines: Int = 0
    private var scrollLastConfirmedAnchorTop: UInt32? = nil

    /// Schedule a render on the next vsync. Multiple calls between vsyncs
    /// are coalesced by MTKView into a single draw() call.
    func renderFrame() {
        guard !isScreenAsleep else { return }
        needsDisplay = true
    }

    /// Previous cursor position for accessibility change detection.
    private var lastAccessibilityCursorRow: UInt16 = 0
    private var lastAccessibilityCursorCol: UInt16 = 0

    /// Called by MTKView's display link at vsync when needsDisplay is true.
    override func draw(_ dirtyRect: NSRect) {
        // Reject known non-presentable states before claiming an input sequence.
        // The renderer acquires a drawable only after its offscreen candidate completes.
        if let reason = presentationPreflightDiscardReason() {
            dispatcher.discardPendingPresentation(reason: reason)
            return
        }
        let scale = Float(window?.backingScaleFactor ?? 2.0)

        // Check for cursor movement to post accessibility notifications.
        let fs = dispatcher.frameState

        if fs.cursorRow != lastAccessibilityCursorRow ||
           fs.cursorCol != lastAccessibilityCursorCol {
            lastAccessibilityCursorRow = fs.cursorRow
            lastAccessibilityCursorCol = fs.cursorCol
            NSAccessibility.post(element: self, notification: .selectedTextChanged)
            resetCursorBlink()
        }

        // Flash scroll indicator when viewport position changes (keyboard scroll, cursor movement).
        // Skip scroll indicator updates while the user is dragging to prevent feedback loops.
        if !isDraggingScrollIndicator &&
            fs.viewportTopLine != lastViewportTopForScroll && fs.viewportTopLine != 0xFFFF_FFFF {
            lastViewportTopForScroll = fs.viewportTopLine
            flashScrollIndicator()
        }

        clearSmoothScrollStateIfTargetWindowMissing()
        advancePresentationScrollAnimation()
        advanceThumbDragPresentation()

        let validGutterHoverWindowId = gutterHoverWindowId.flatMap { windowId in
            dispatcher.currentFrameWindowIds.contains(windowId) ? windowId : nil
        }
        let validGutterHoverRow = validGutterHoverWindowId == nil ? nil : gutterHoverRow
        let validMouseInGutter = isMouseInGutter && validGutterHoverWindowId != nil
        let cursorAnimationGeneration = coreTextRenderer.cursorAnimationGeneration
        let presentationInputSeq = dispatcher.takePresentationInputSeq()
        let presentationFrameSeq = dispatcher.pendingPresentationFrameSeq()
        let localScrollPresentation = localScrollPresentation
        coreTextRenderer.render(frameState: fs, fontManager: fontManager,
                                cursorBlinkVisible: cursorBlinkVisible,
                                windowContents: editorInput?.currentWindowContents ?? [:],
                                themeColors: editorInput?.currentTheme,
                                isMouseInGutter: validMouseInGutter,
                                gutterHoverWindowId: validGutterHoverWindowId,
                                gutterHoverRow: validGutterHoverRow,
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
                                presentationInputSeq: presentationInputSeq,
                                presentationFrameSeq: presentationFrameSeq,
                                latencyRecorder: dispatcher.latency)
        if coreTextRenderer.cursorAnimationGeneration != cursorAnimationGeneration {
            resetCursorBlink()
        }
        if coreTextRenderer.cursorAnimating {
            needsDisplay = true
        }
        dispatcher.markRendered()
        os_signpost(.event, log: renderLog, name: "DrawComplete")
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

        let gutterPad: CGFloat = dispatcher.frameState.gutterCol > 0 ? CoreTextMetalRenderer.gutterPixelPaddingPt : 0
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

    /// Called when the BEAM sends a set_font command or the display scale changes.
    /// Replaces the font face, resizes the grid to match new cell dimensions,
    /// and sends a resize event to the BEAM so it re-renders with the new grid size.
    func updateFont(_ newFace: FontFace) {
        self.fontFace = newFace

        // Recompute grid dimensions with the new cell size.
        let newCellW = newFace.cellWidth
        let newCellH = CGFloat(newFace.cellHeight)
        guard newCellW > 0, newCellH > 0 else { return }

        let grid = gridDimensions(width: frame.width, height: frame.height, cellWidth: newCellW, cellHeight: newCellH)

        if grid.cols != dispatcher.frameState.cols || grid.rows != dispatcher.frameState.rows {
            dispatcher.applyViewportResize(newCols: grid.cols, newRows: grid.rows)
            encoder.sendResize(cols: grid.cols, rows: grid.rows)
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
        window.setFrameAutosaveName("MingaEditorWindow")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)

        measureTrafficLightPosition(in: window)
        installWindowObserversIfNeeded(for: window)

        registerForDraggedTypes([.fileURL])

        updateTrackingArea()
        claimFirstResponder()
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
        dispatcher.discardPendingPresentation(reason: .hidden)
    }

    /// Applies a live display configuration update to the Metal surface.
    func displayConfigurationChanged(newScale: CGFloat, forceResizeEvent: Bool = false, sendDimensions: Bool = true) {
        updateMetalBackingScale(newScale)
        let scaleChanged = abs(fontFace.scale - newScale) > 0.001

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

    /// Sends the current grid dimensions to the BEAM after an external display change.
    private func sendCurrentGridSize(reason: String) {
        guard frame.width > 0, frame.height > 0 else { return }

        let grid = currentGridDimensions()
        dispatcher.applyViewportResize(newCols: grid.cols, newRows: grid.rows)

        if readySent {
            encoder.sendResize(cols: grid.cols, rows: grid.rows)
        } else {
            readySent = true
            encoder.sendReady(cols: grid.cols, rows: grid.rows)
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

        firstResponderGuard = FirstResponderGuard(window: window, editorView: self)
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

    /// Claim first responder after a short delay so SwiftUI's layout pass
    /// completes first. Without the async dispatch, SwiftUI can immediately
    /// reassign first responder to its own focus system.
    func claimFirstResponder() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reclaimFirstResponderIfNeeded(respectingTextInput: true)
        }
    }

    /// Reclaims first responder immediately when pointer interaction returns to the editor.
    func reclaimFirstResponderIfNeeded(respectingTextInput: Bool = false) {
        guard let window else { return }
        if respectingTextInput, window.firstResponder is NSText { return }
        if window.firstResponder !== self {
            window.makeFirstResponder(self)
        }
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        claimFirstResponder()
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
        stopCursorBlink()
        // The window lost key while the thumb may still be held (system modal, Cmd-Tab, Mission
        // Control): no mouseUp is guaranteed, so discard the drag with its final target flushed
        // rather than leave the reconcile gate stuck open (Critical 1b / Critical 2, policy b).
        cancelThumbDragWithFlush()
    }

    @objc private func windowPresentationAvailabilityDidChange(_ notification: Notification) {
        if let reason = presentationPreflightDiscardReason() {
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
        if result { resetCursorBlink() }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { stopCursorBlink() }
        return result
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)

        guard newSize.width > 0, newSize.height > 0 else { return }

        let grid = gridDimensions(width: newSize.width, height: newSize.height)

        if !readySent {
            // First real frame size: send the ready event with actual
            // window dimensions so the BEAM never sees wrong defaults.
            readySent = true
            dispatcher.applyViewportResize(newCols: grid.cols, newRows: grid.rows)
            encoder.sendReady(cols: grid.cols, rows: grid.rows)
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
            encoder.sendResize(cols: grid.cols, rows: grid.rows)
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
        scrollIndicatorDragOffset = nil
        // Pointer input is dropped during the resize (AC5), so a mouseUp that would
        // end an in-flight press may never reach the BEAM. Mirror the thumb-drag
        // rule: complete the gesture (send the release) before clearing its state.
        if leftMouseDownPoint != nil {
            let point = leftMouseDownPoint ?? .zero
            let (row, col) = rawCellPosition(at: point)
            encoder.sendMouseEvent(row: row, col: col, button: MOUSE_BUTTON_LEFT,
                                   modifiers: 0, eventType: MOUSE_RELEASE)
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
        encoder.sendResize(cols: cols, rows: rows)
        PortLogger.info("Window resized (debounced): \(cols)x\(rows) rows")
    }

    // MARK: - Scroll indicator interaction

    /// Whether the user is currently dragging the scroll indicator.
    private var isDraggingScrollIndicator = false

    /// Pointer offset from the rendered thumb's top edge captured at drag start.
    private var scrollIndicatorDragOffset: CGFloat?

    /// Tests whether a point should start scroll-track interaction.
    ///
    /// The track only captures clicks when the document can scroll, the viewport top is valid,
    /// and either the indicator is currently visible or the macOS setting forces it to stay visible.
    private func shouldCaptureScrollTrackClick(_ point: NSPoint) -> Bool {
        EditorScrollTrack.isInTrack(x: point.x, viewWidth: bounds.width)
            && EditorScrollTrack.shouldCaptureTrackClick(
                totalLines: dispatcher.frameState.totalLineCount,
                visibleRows: UInt32(dispatcher.frameState.rows),
                viewportTopLine: dispatcher.frameState.viewportTopLine,
                scrollIndicatorAlpha: coreTextRenderer.scrollIndicatorAlpha,
                alwaysShowScrollbar: alwaysShowScrollbar
            )
    }

    /// Captures the pointer's offset inside the rendered thumb when the user starts dragging on the thumb.
    private func scrollTrackDragOffset(forY y: CGFloat) -> CGFloat? {
        let fs = dispatcher.frameState
        guard let thumb = EditorScrollTrack.thumb(
            viewHeight: bounds.height,
            totalLines: fs.totalLineCount,
            visibleRows: UInt32(fs.rows),
            viewportTopLine: fs.viewportTopLine,
            resident: activeWindowIsResident
        ) else { return nil }
        return EditorScrollTrack.dragOffset(forY: y, thumb: thumb)
    }

    /// Converts a Y coordinate in the scroll track to a target line number.
    private func scrollTrackYToLine(_ y: CGFloat) -> UInt32 {
        let fs = dispatcher.frameState
        let visibleRows = UInt32(fs.rows)
        let resident = activeWindowIsResident

        if let scrollIndicatorDragOffset {
            return EditorScrollTrack.line(
                forDraggedY: y,
                dragOffset: scrollIndicatorDragOffset,
                viewHeight: bounds.height,
                totalLines: fs.totalLineCount,
                visibleRows: visibleRows,
                resident: resident
            )
        }

        return EditorScrollTrack.line(
            forY: y,
            viewHeight: bounds.height,
            totalLines: fs.totalLineCount,
            visibleRows: visibleRows,
            resident: resident
        )
    }

    // MARK: - Scrollbar thumb-drag local presentation (#2665)

    /// The active editor window's id, derived from the active gutter. The scroll track
    /// operates on the active pane (its metrics drive `scrollTrackYToLine`), so this is the
    /// window a thumb drag scrolls.
    private var activeWindowId: UInt16? {
        dispatcher.frameState.windowGutters.values
            .filter(\.isActive)
            .sorted { $0.windowId < $1.windowId }
            .first?
            .windowId
    }

    private var activeWindowIsResident: Bool {
        guard let windowId = activeWindowId,
              let content = editorInput?.currentWindowContents[windowId] else { return false }
        return Self.thumbDragCanPresentLocally(
            scrollPresentation: content.scrollPresentation,
            totalLines: content.paneGeometry?.viewport.totalLines ?? dispatcher.frameState.totalLineCount
        )
    }

    /// Establishes resident local presentation for a thumb drag if the active pane is resident,
    /// and sends the first intent immediately for a responsive click. Windowed / non-resident panes
    /// leave `thumbDragSession` nil and keep the round-trip path; the residency decision is made
    /// once here and never re-checked (see `ThumbDragSession` gate policy).
    private func beginThumbDragPresentation(targetLine: UInt32) {
        // A thumb interaction supersedes every trackpad/discrete presentation, including
        // accumulator and reconciliation bookkeeping. Reset before residency routing so the
        // round-trip path cannot leave an old settle or rebound visible either.
        resetSmoothScrollState()
        guard let windowId = activeWindowId,
              let content = editorInput?.currentWindowContents[windowId],
              Self.thumbDragCanPresentLocally(
                  scrollPresentation: content.scrollPresentation,
                  totalLines: content.paneGeometry?.viewport.totalLines ?? dispatcher.frameState.totalLineCount
              )
        else {
            thumbDragSession = nil
            // Windowed pane: send the initial jump on the round-trip path (today's behavior).
            encoder.sendScrollToLine(line: targetLine)
            return
        }
        var session = ThumbDragSession(windowId: windowId, targetLine: targetLine)
        if let intent = session.takeIntent() { encoder.sendScrollToLine(line: intent) }
        thumbDragSession = session
        applyThumbDragOffset(targetLine: targetLine, windowId: windowId)
        needsDisplay = true
    }

    /// Updates the drag target. Resident panes present same-frame and defer the intent to the
    /// per-frame throttle; windowed panes keep sending on every event (today's behavior).
    private func updateThumbDragPresentation(targetLine: UInt32) {
        if let windowId = thumbDragSession?.windowId {
            thumbDragSession?.updateTarget(targetLine)
            applyThumbDragOffset(targetLine: targetLine, windowId: windowId)
            needsDisplay = true
        } else {
            encoder.sendScrollToLine(line: targetLine)
        }
    }

    /// Handles thumb-drag release. Flushes any final throttled intent through the session, then
    /// hands off to the draw-loop reconcile: the offset keeps tracking the committed anchor until
    /// the BEAM's echo-marked commit reaches the target (offset 0), so there is no settle-jump.
    private func endThumbDragPresentation() {
        guard var session = thumbDragSession, session.phase == .dragging else { return }
        if let intent = session.release(committed: committedThumbDrag(for: session.windowId), now: CACurrentMediaTime()) {
            encoder.sendScrollToLine(line: intent)
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
        if let intent = session.cancelWithFlush() { encoder.sendScrollToLine(line: intent) }
        thumbDragSession = nil
        scrollPixelOffset = CGPoint(x: scrollPixelOffset.x, y: 0)
        needsDisplay = true
    }

    /// Presents the drag offset for `targetLine` against the pane's committed anchor.
    private func applyThumbDragOffset(targetLine: UInt32, windowId: UInt16) {
        guard let anchorTop = committedThumbDrag(for: windowId)?.anchorTop, effectiveCellHeight > 0 else { return }
        scrollPixelOffset = CGPoint(
            x: scrollPixelOffset.x,
            y: Self.thumbDragPresentationOffsetY(targetLine: targetLine, committedAnchorTop: anchorTop, cellHeight: effectiveCellHeight)
        )
    }

    /// The committed scroll presentation of the thumb-drag pane, or nil when it is gone.
    private func committedThumbDrag(for windowId: UInt16) -> ThumbDragSession.Committed? {
        guard let sp = editorInput?.currentWindowContents[windowId]?.scrollPresentation else { return nil }
        return ThumbDragSession.Committed(anchorTop: sp.anchorTop, scrollSeq: sp.scrollSeq, contentEpoch: sp.contentEpoch, layoutGeneration: sp.layoutGeneration)
    }

    /// Advances the thumb-drag session one frame and applies its decision: flushes at most one
    /// throttled intent (AC4), tracks the offset against the committed anchor, and finishes the
    /// session when the reconcile lands, an authoritative event interrupts it, the presentation
    /// vanishes, the button is released without a mouseUp, or the reconcile watchdog expires.
    private func advanceThumbDragPresentation() {
        guard var session = thumbDragSession else { return }
        let committed = committedThumbDrag(for: session.windowId)
        // The button check catches a lost mouseUp (system modal / Mission Control / Cmd-Tab mid-drag)
        // so a gesture cannot stay stuck in the dragging phase with the gate held open.
        let buttonHeld = NSEvent.pressedMouseButtons & 0x1 != 0
        let outcome = session.advance(committed: committed, now: CACurrentMediaTime(), buttonHeld: buttonHeld)

        if let intent = outcome.intent { encoder.sendScrollToLine(line: intent) }
        if outcome.finished {
            thumbDragSession = nil
            scrollPixelOffset = CGPoint(x: scrollPixelOffset.x, y: 0)
        } else {
            thumbDragSession = session
            if effectiveCellHeight > 0 {
                scrollPixelOffset = CGPoint(x: scrollPixelOffset.x, y: CGFloat(outcome.offsetLines) * effectiveCellHeight)
            }
        }
        if outcome.needsRedraw { needsDisplay = true }
    }

    /// Pixel offset that shifts resident rows so `targetLine` renders at the viewport top, given
    /// the BEAM's committed `anchorTop`. Positive shifts content up (scrolled toward the end),
    /// matching `scrollPixelOffset.y`. Pure for testability.
    nonisolated static func thumbDragPresentationOffsetY(targetLine: UInt32, committedAnchorTop: UInt32, cellHeight: CGFloat) -> CGFloat {
        CGFloat(Int64(targetLine) - Int64(committedAnchorTop)) * cellHeight
    }

    /// Whether a resident pane can present a thumb-drag target same-frame from resident rows.
    ///
    /// Resident panes carry the whole document (overscan spans line 0 through `totalLines`), so
    /// any drag target renders from resident rows. Windowed panes carry only a viewport band and
    /// must keep the round-trip path. Pure for testability.
    nonisolated static func thumbDragCanPresentLocally(scrollPresentation: GUIScrollPresentation?, totalLines: UInt32) -> Bool {
        guard let sp = scrollPresentation, totalLines > 0 else { return false }
        return sp.overscanStartLine == 0 && sp.overscanEndLine >= totalLines
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
            encoder.sendResize(cols: grid.cols, rows: grid.rows)
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

    /// Activates the agent chat overlay mode. The Metal surface goes to
    /// opacity(0) so the SwiftUI chat overlay is visible. Since opacity(0)
    /// disconnects normal event delivery, a local event monitor forwards
    /// keyboard events to keyDown. SwiftUI text selection still works
    /// because the monitor yields to NSText field editors.
    func setAgentChatVisible(_ visible: Bool) {
        agentChatVisible = visible

        if visible {
            installAgentKeyMonitor()
        } else {
            removeAgentKeyMonitor()
            claimFirstResponder()
        }
    }

    /// Installs a local key event monitor that forwards keyboard events
    /// to EditorNSView when the agent chat overlay is visible. This is
    /// needed because SwiftUI's opacity(0) on the NSViewRepresentable
    /// parent disconnects the underlying NSView from event delivery.
    ///
    /// Uses Apple's NSEvent.addLocalMonitorForEvents API, the documented
    /// approach for event interception when NSWindow subclassing isn't
    /// available. Chosen over NSPanel child windows (coordinate coupling,
    /// focus model mismatch, rendering seam on resize) and NSWindow
    /// sendEvent override (not possible with SwiftUI App lifecycle).
    ///
    /// Monitors keyDown, keyUp, and flagsChanged:
    /// - keyDown: all typing, Cmd+key combos (fires before responder chain,
    ///   so it catches performKeyEquivalent events too)
    /// - keyUp: needed for space leader chord cleanup (spacePending flag)
    /// - flagsChanged: bare modifier presses (no-op today, future-proofing)
    /// - Key repeat events arrive as keyDown with isARepeat=true and are
    ///   handled correctly by the existing keyDown space leader code path
    private func installAgentKeyMonitor() {
        guard agentKeyMonitor == nil else { return }
        agentKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, self.agentChatVisible else { return event }
            if event.type == .keyDown, Self.shouldYieldSystemCommandShortcut(event) {
                return event
            }
            // Yield to active text field editors (SwiftUI text selection).
            // The FirstResponderGuard also yields to NSText, but the
            // monitor fires before the responder chain so we check here too.
            if let window = self.window, window.firstResponder is NSText {
                return event
            }
            switch event.type {
            case .keyDown:
                self.keyDown(with: event)
            case .keyUp:
                self.keyUp(with: event)
            case .flagsChanged:
                self.flagsChanged(with: event)
            default:
                return event
            }
            return nil // consumed
        }
    }

    private func removeAgentKeyMonitor() {
        if let monitor = agentKeyMonitor {
            NSEvent.removeMonitor(monitor)
            agentKeyMonitor = nil
        }
    }

    // MARK: - Keyboard

    /// Returns true for shortcuts that the menu bar or AppKit should handle
    /// instead of being sent directly to the BEAM. The menu action sends
    /// the appropriate command to the BEAM, so the end result is the same
    /// but the menu item highlights visually.
    static func shouldYieldSystemCommandShortcut(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Bare Cmd+key: system shortcuts and menu bar items
        if mods == .command {
            switch event.charactersIgnoringModifiers {
            case "q", "h", "m":
                return true
            case "n", "o", "s", "w":
                return true
            case "z", "x", "c", "v", "a", "f":
                return true
            case "b", ",":
                return true
            case "=", "+", "-", "0":
                return true
            default:
                return false
            }
        }

        // Cmd+Shift variants: Redo (Cmd+Shift+Z), font size (Cmd+Shift+=)
        if mods == [.command, .shift] {
            switch event.charactersIgnoringModifiers {
            case "z", "Z":
                return true
            case "=", "+":
                return true
            default:
                return false
            }
        }

        // Cmd+Ctrl+F: Toggle Full Screen
        if mods == [.command, .control] {
            switch event.charactersIgnoringModifiers {
            case "f":
                return true
            default:
                return false
            }
        }

        return false
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
        if let window, window.firstResponder is NSText {
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
                encoder.sendPasteEvent(text: text)
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
                encoder.sendFindPasteboardSearch(text: findText, direction: direction)
            }
            return
        }

        // Special keys (arrows, Enter, Escape, etc.) bypass IME.
        if let codepoint = mapKeyCode(event) {
            // If IME is composing, Escape/Enter may need special handling.
            if imeComposition.hasMarkedText {
                if codepoint == 27 { // Escape: cancel composition
                    imeComposition.clear()
                    needsDisplay = true
                    return
                }
                if codepoint == 13 { // Enter: commit composition
                    if let text = imeComposition.unmark() {
                        commitIMEText(text)
                    }
                    needsDisplay = true
                    return
                }
            }
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
        if let ctx = inputContext {
            _ = ctx.handleEvent(event)
        } else {
            interpretKeyEvents([event])
        }
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
        encoder.sendMouseEvent(row: row, col: col, button: MOUSE_BUTTON_NONE,
                               modifiers: modifierBits(from: event.modifierFlags),
                               eventType: MOUSE_MOTION)
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

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        // Drop pointer input while a live resize is in flight (#2655, AC5): the view
        // geometry is changing and the on-screen content is a crop of the last committed
        // frame, so a hit-test would map against stale, in-flux geometry. Events are
        // discarded, not queued: nothing is replayed after the resize ends. The same
        // guard gates every geometry-hit-testing handler below; press/release pairs
        // that straddle a resize are completed by viewWillStartLiveResize instead.
        guard !inLiveResize else { return }
        reclaimFirstResponderIfNeeded()

        // Scroll indicator track: intercept clicks on the right edge.
        let point = convert(event.locationInWindow, from: nil)
        if shouldCaptureScrollTrackClick(point) {
            isDraggingScrollIndicator = true
            scrollIndicatorDragOffset = scrollTrackDragOffset(forY: point.y)
            let line = scrollTrackYToLine(point.y)
            // beginThumbDragPresentation sends the first intent itself (un-throttled) for a
            // responsive click, on either the resident or the round-trip path.
            beginThumbDragPresentation(targetLine: line)
            flashScrollIndicator()
            return
        }

        if handleFoldChevronClick(at: point) {
            return
        }

        resetCursorBlink()
        leftMouseDownPoint = point
        leftMouseDragStarted = false
        dividerDragState = dividerHitState(at: point)
        if dividerDragState != .none {
            setDividerCursorState(dividerDragState)
        }
        let (row, col) = dividerDragState == .none ? cellPosition(from: event) : dividerPressCellPosition(at: point, state: dividerDragState)
        let cc = UInt8(clamping: event.clickCount)
        encoder.sendMouseEvent(row: row, col: col, button: MOUSE_BUTTON_LEFT,
                               modifiers: modifierBits(from: event.modifierFlags),
                               eventType: MOUSE_PRESS, clickCount: cc)
    }

    override func mouseUp(with event: NSEvent) {
        guard !inLiveResize else { return }
        if isDraggingScrollIndicator {
            isDraggingScrollIndicator = false
            scrollIndicatorDragOffset = nil
            endThumbDragPresentation()
            flashScrollIndicator()
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let (row, col) = dividerDragState == .none ? cellPosition(from: event) : rawCellPosition(at: point)
        encoder.sendMouseEvent(row: row, col: col, button: MOUSE_BUTTON_LEFT,
                               modifiers: modifierBits(from: event.modifierFlags),
                               eventType: MOUSE_RELEASE)
        leftMouseDownPoint = nil
        leftMouseDragStarted = false
        if dividerDragState != .none {
            dividerDragState = .none
            setDividerCursorState(dividerHitState(at: point))
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        // Dropped during a live resize (see mouseDown). The matching rightMouseUp stays
        // ungated so a press that straddles the resize still delivers its release.
        guard !inLiveResize else { return }
        reclaimFirstResponderIfNeeded()
        resetCursorBlink()
        let (row, col) = cellPosition(from: event)
        let cc = UInt8(clamping: event.clickCount)
        encoder.sendMouseEvent(row: row, col: col, button: MOUSE_BUTTON_RIGHT,
                               modifiers: modifierBits(from: event.modifierFlags),
                               eventType: MOUSE_PRESS, clickCount: cc)
        contextMenuShownForRightClick = true
        NSMenu.popUpContextMenu(buildEditorContextMenu(), with: event, for: self)
    }

    override func rightMouseUp(with event: NSEvent) {
        if contextMenuShownForRightClick {
            contextMenuShownForRightClick = false
            return
        }

        let (row, col) = cellPosition(from: event)
        encoder.sendMouseEvent(row: row, col: col, button: MOUSE_BUTTON_RIGHT,
                               modifiers: modifierBits(from: event.modifierFlags),
                               eventType: MOUSE_RELEASE)
    }

    private func buildEditorContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Editor")
        menu.autoenablesItems = false
        addEditorMenuItem("Cut", action: "cut", to: menu)
        addEditorMenuItem("Copy", action: "copy", to: menu)
        addEditorMenuItem("Paste", action: "paste", to: menu)
        addEditorMenuItem("Select All", action: "select_all", to: menu)
        menu.addItem(.separator())

        let hasLsp = statusBarState?.hasLsp ?? false
        addEditorMenuItem("Go to Definition", action: "goto_definition", to: menu, enabled: hasLsp)
        addEditorMenuItem("Peek Definition", action: "peek_definition", to: menu, enabled: hasLsp)
        addEditorMenuItem("Find References", action: "find_references", to: menu, enabled: hasLsp)
        addEditorMenuItem("Rename Symbol", action: "rename_symbol", to: menu, enabled: hasLsp)
        menu.addItem(.separator())

        addEditorMenuItem("Toggle Comment", action: "toggle_comment_line", to: menu)
        addEditorMenuItem("Format Document", action: "format_buffer", to: menu)
        return menu
    }

    private func addEditorMenuItem(_ title: String, action: String, to menu: NSMenu, enabled: Bool = true) {
        let item = NSMenuItem(title: title, action: #selector(handleEditorContextMenuItem(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action
        item.isEnabled = enabled
        menu.addItem(item)
    }

    @objc private func handleEditorContextMenuItem(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? String else { return }

        switch action {
        case "cut":
            encoder.sendCmdCut()
        case "copy":
            encoder.sendCmdCopy()
        case "paste":
            pasteFromClipboard()
        default:
            encoder.sendExecuteCommand(name: action)
        }
    }

    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        encoder.sendPasteEvent(text: text)
    }

    override func otherMouseDown(with event: NSEvent) {
        // Dropped during a live resize (see mouseDown). otherMouseUp stays ungated so a
        // press that straddles the resize still delivers its release.
        guard !inLiveResize else { return }
        reclaimFirstResponderIfNeeded()
        let (row, col) = cellPosition(from: event)
        encoder.sendMouseEvent(row: row, col: col, button: MOUSE_BUTTON_MIDDLE,
                               modifiers: modifierBits(from: event.modifierFlags),
                               eventType: MOUSE_PRESS)
    }

    override func otherMouseUp(with event: NSEvent) {
        let (row, col) = cellPosition(from: event)
        encoder.sendMouseEvent(row: row, col: col, button: MOUSE_BUTTON_MIDDLE,
                               modifiers: modifierBits(from: event.modifierFlags),
                               eventType: MOUSE_RELEASE)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !inLiveResize else { return }
        if isDraggingScrollIndicator {
            let point = convert(event.locationInWindow, from: nil)
            let line = scrollTrackYToLine(point.y)
            updateThumbDragPresentation(targetLine: line)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        if dividerDragState != .none {
            setDividerCursorState(dividerDragState)
        } else if !shouldSendTextDrag(for: event) {
            return
        }
        let (row, col) = dividerDragState == .none ? cellPosition(from: event) : rawCellPosition(at: point)
        encoder.sendMouseEvent(row: row, col: col, button: MOUSE_BUTTON_LEFT,
                               modifiers: modifierBits(from: event.modifierFlags),
                               eventType: MOUSE_DRAG)
    }

    override func mouseMoved(with event: NSEvent) {
        guard !inLiveResize else { return }
        let point = convert(event.locationInWindow, from: nil)
        setDividerCursorState(dividerHitState(at: point))
        updateGutterHover(at: point)
        let (row, col) = cellPosition(from: event)
        clearSmoothScrollOffsetIfPointerLeftTarget(row: row, col: col)
        guard row != lastMoveRow || col != lastMoveCol else { return }
        lastMoveRow = row
        lastMoveCol = col
        encoder.sendMouseEvent(row: row, col: col, button: MOUSE_BUTTON_NONE,
                               modifiers: modifierBits(from: event.modifierFlags),
                               eventType: MOUSE_MOTION)
    }

    override func mouseExited(with event: NSEvent) {
        if dividerDragState == .none {
            setDividerCursorState(.none)
        }
        clearGutterHover()
        resetSmoothScrollState()
        super.mouseExited(with: event)
    }

    /// Scroll accumulator for smooth trackpad scrolling. Extracted into a
    /// pure struct so the accumulation math is unit-testable.
    private var scrollAccumulator = ScrollAccumulator()

    // MARK: - Scroll indicator fade

    /// Pending work item that fades the scroll indicator after idle.
    private var scrollFadeWorkItem: DispatchWorkItem?

    /// Whether the system prefers always-visible scrollers.
    private var alwaysShowScrollbar: Bool = false

    /// Shows the scroll indicator and starts a fade timer.
    /// Called on scroll events and when viewport position changes.
    func flashScrollIndicator() {
        coreTextRenderer.scrollIndicatorAlpha = 1.0
        setNeedsDisplay(bounds)

        // Cancel any pending fade.
        scrollFadeWorkItem?.cancel()
        scrollFadeWorkItem = nil

        // Don't fade if system preference is "Always show".
        guard !alwaysShowScrollbar else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Animate fade out over 0.3s using a simple step approach.
            // We could use CADisplayLink for smoother animation, but
            // a timer with 3 steps is sufficient for a scroll indicator.
            self.fadeScrollIndicator(steps: 6)
        }
        scrollFadeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// Gradually fades the scroll indicator alpha to zero.
    private func fadeScrollIndicator(steps remaining: Int) {
        guard !alwaysShowScrollbar else {
            scrollFadeWorkItem?.cancel()
            scrollFadeWorkItem = nil
            coreTextRenderer.scrollIndicatorAlpha = 1.0
            setNeedsDisplay(bounds)
            return
        }
        guard remaining > 0 else {
            coreTextRenderer.scrollIndicatorAlpha = 0.0
            setNeedsDisplay(bounds)
            return
        }
        coreTextRenderer.scrollIndicatorAlpha = Float(remaining) / 6.0
        setNeedsDisplay(bounds)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.fadeScrollIndicator(steps: remaining - 1)
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
                    self.scrollFadeWorkItem?.cancel()
                    self.scrollFadeWorkItem = nil
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
        // A resident thumb drag owns scroll presentation while the button is held: ignore concurrent
        // wheel input so the two do not fight over the offset. A post-release reconcile (button up)
        // is superseded by a fresh wheel gesture, so flush-and-drop it and let the wheel take over.
        if let session = thumbDragSession {
            if session.ownsScrollInput { return }
            cancelThumbDragWithFlush()
        }

        if event.hasPreciseScrollingDeltas && event.phase == .began {
            // A fresh trackpad gesture supersedes any in-flight settle; the `.began`
            // branch in handleTrackpadScroll performs the full reset.
            cancelScrollAnimations()
        }

        let (row, col) = cellPosition(from: event)
        let mods = modifierBits(from: event.modifierFlags)

        // Flash the scroll indicator on any scroll activity.
        flashScrollIndicator()

        if event.hasPreciseScrollingDeltas {
            handleTrackpadScroll(event: event, row: row, col: col, mods: mods)
        } else {
            handleDiscreteScroll(event: event, row: row, col: col, mods: mods)
        }
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
            scrollOffset: localScrollPresentation?.offset ?? .zero
        )
    }
#endif

    private func handleTrackpadScroll(event: NSEvent, row: Int16, col: Int16, mods: UInt8) {
        if event.phase == .began {
            cancelScrollAnimations()
            scrollAccumulator.reset()
            scrollPixelOffset = .zero
            scrollElasticOffsetY = 0
            scrollTargetWindowId = nil
            scrollTargetCellPosition = nil
            resetScrollTrackingState()
        } else if event.momentumPhase == .began || event.momentumPhase == .changed {
            // Momentum resuming after finger-lift: cancel the tentative settle started at
            // `.ended` so the animator and live momentum don't both drive the offset. The
            // unconfirmed-line bookkeeping is preserved for continuity; momentum re-latches
            // the target below via establishSmoothScrollTargetIfNeeded.
            cancelScrollAnimations()
        }

        let (lockedDeltaX, lockedDeltaY) = axisLockedDeltas(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY
        )

        establishSmoothScrollTargetIfNeeded(row: row, col: col)
        let targetCell = Self.smoothScrollEventCellPosition(targetCell: scrollTargetCellPosition, row: row, col: col)

        let vEvents = scrollAccumulator.accumulateVertical(
            deltaY: lockedDeltaY, cellHeight: effectiveCellHeight)
        if let windowId = scrollTargetWindowId {
            var deltaLines: Int16 = 0
            for e in vEvents {
                switch e {
                case .scrollDown: deltaLines += 1
                case .scrollUp: deltaLines -= 1
                default: break
                }
            }
            if deltaLines != 0 {
                let direction: UInt8 = deltaLines > 0 ? 0 : 1
                encoder.sendScrollBatch(windowId: windowId, deltaLines: deltaLines, direction: direction)
                scrollUnconfirmedLines += Int(deltaLines)
            }
        } else {
            for e in vEvents {
                sendScrollEvent(e, row: targetCell.row, col: targetCell.col, mods: mods)
            }
        }
        let hEvents = scrollAccumulator.accumulateHorizontal(
            deltaX: lockedDeltaX, cellWidth: cellWidth)
        for e in hEvents {
            sendScrollEvent(e, row: targetCell.row, col: targetCell.col, mods: mods)
        }
        let targetWindowContent = scrollTargetWindowId.flatMap { editorInput?.currentWindowContents[$0] }
        let targetScrollPresentation = targetWindowContent?.scrollPresentation
        let scrollBounds = Self.presentationScrollBounds(
            for: targetWindowContent,
            scrollPresentation: targetScrollPresentation
        )

        if let sp = targetScrollPresentation {
            reconcileUnconfirmedLines(against: sp)
        }

        let compensatedOffsetY = scrollAccumulator.pixelOffsetY + CGFloat(scrollUnconfirmedLines) * effectiveCellHeight
        let translation = Self.presentationScrollTranslation(
            scrollPresentation: targetScrollPresentation,
            scrollOffsetY: compensatedOffsetY,
            scrollDeltaY: lockedDeltaY,
            payloadOverscanBefore: scrollBounds.payloadBefore,
            payloadOverscanAfter: scrollBounds.payloadAfter,
            boundaryBefore: scrollBounds.boundaryBefore,
            boundaryAfter: scrollBounds.boundaryAfter
        )
        let suppressLocalOffset = scrollTargetWindowId == nil || isSelectionDragActive
        let offsetX = suppressLocalOffset ? 0 : scrollAccumulator.pixelOffsetX
        applyPresentationTranslation(translation, offsetX: offsetX, suppressLocalOffset: suppressLocalOffset)

        // Settle onto the grid when the gesture, then any following momentum, truly ends.
        if (event.phase == .ended || event.phase == .cancelled) && event.momentumPhase == [] {
            finishSmoothScrollGesture()
        }
        if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
            finishSmoothScrollGesture()
        }

        // Tell MTKView we need a frame. The display link coalesces
        // multiple scroll events between vsyncs into one draw() call.
        needsDisplay = true
    }

    /// Ends a smooth-scroll gesture. With animations enabled this eases the residual sub-line
    /// offset to the grid (AC1) and springs the rubber band back (AC2) instead of snapping;
    /// under Reduce Motion it hard-resets to the grid immediately.
    private func finishSmoothScrollGesture() {
        guard scrollAnimateEnabled else {
            hardResetSmoothScroll()
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
        if let windowId = scrollTargetWindowId, scrollUnconfirmedLines != 0 || scrollAccumulator.pixelOffsetY != 0 {
            let residual = scrollAccumulator.pixelOffsetY
            scrollAccumulator.reset()
            beginScrollSettle(windowId: windowId, residual: residual, duration: Self.scrollSettleDuration)
            startedAnimation = true
        }

        // Release live-gesture-only state; the settle keeps reconciling via scrollSettleWindowId.
        scrollTargetWindowId = nil
        scrollTargetCellPosition = nil
        scrollAxisLock = .undecided
        scrollAxisAccumulatedX = 0
        scrollAxisAccumulatedY = 0

        if !startedAnimation {
            scrollAccumulator.reset()
            scrollPixelOffset = .zero
            scrollElasticOffsetY = 0
            scrollElasticRawDistance = 0
            scrollUnconfirmedLines = 0
            scrollLastConfirmedAnchorTop = nil
            scrollSettleWindowId = nil
            scrollElasticWindowId = nil
        }
        needsDisplay = true
    }

    /// Instantly resets all smooth-scroll and animation state to the grid (Reduce Motion / cleanup).
    private func hardResetSmoothScroll() {
        scrollAccumulator.reset()
        scrollPixelOffset = .zero
        scrollElasticOffsetY = 0
        scrollTargetWindowId = nil
        scrollTargetCellPosition = nil
        // Trackpad and thumb-drag are mutually exclusive (the scrollWheel guard ignores wheel input
        // while a drag is button-held), so no session is expected here; drop it defensively.
        thumbDragSession = nil
        cancelScrollAnimations()
        resetScrollTrackingState()
        needsDisplay = true
    }

    private func resetScrollTrackingState() {
        scrollAxisLock = .undecided
        scrollAxisAccumulatedX = 0
        scrollAxisAccumulatedY = 0
        scrollUnconfirmedLines = 0
        scrollLastConfirmedAnchorTop = nil
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
        if let current = scrollSettleWindowId, current != windowId {
            // Settling switched panes: rebase the anchor reconciliation baseline.
            scrollLastConfirmedAnchorTop = nil
        }
        scrollSettleWindowId = windowId
        if scrollLastConfirmedAnchorTop == nil {
            scrollLastConfirmedAnchorTop = editorInput?.currentWindowContents[windowId]?.scrollPresentation?.anchorTop
        }
        scrollSettleAnimator.start(offset: residual, duration: duration)
        // Reflect the seeded offset immediately so this frame is continuous with the last.
        scrollPixelOffset = CGPoint(x: scrollPixelOffset.x, y: residual + CGFloat(scrollUnconfirmedLines) * effectiveCellHeight)
        needsDisplay = true
    }

    /// Reconciles the predicted unconfirmed-line count against a freshly committed anchor.
    /// Keeps the rendered position stable as the BEAM's anchor catches up to local prediction.
    private func reconcileUnconfirmedLines(against sp: GUIScrollPresentation) {
        guard let lastAnchor = scrollLastConfirmedAnchorTop else {
            scrollLastConfirmedAnchorTop = sp.anchorTop
            return
        }
        let anchorDelta = Int(sp.anchorTop) - Int(lastAnchor)
        guard anchorDelta != 0 else { return }
        scrollUnconfirmedLines = Self.reconciledUnconfirmedLines(current: scrollUnconfirmedLines, anchorDelta: anchorDelta)
        scrollLastConfirmedAnchorTop = sp.anchorTop
    }

    /// Advances the settle and rubber-band spring-back animations one frame.
    ///
    /// The MTKView is paused, so this self-retriggers `needsDisplay` while an animation runs,
    /// mirroring the cursor animation's draw-loop self-retrigger. Discards always win: the state
    /// is cleared out from under this by `resetSmoothScrollState()` before it runs.
    private func advancePresentationScrollAnimation() {
        guard scrollAnimateEnabled else { return }
        let now = CACurrentMediaTime()
        var keepAnimating = false

        if let windowId = scrollSettleWindowId {
            if let sp = editorInput?.currentWindowContents[windowId]?.scrollPresentation {
                reconcileUnconfirmedLines(against: sp)
            }
            let residual = scrollSettleAnimator.offset(now: now)
            let offsetY = residual + CGFloat(scrollUnconfirmedLines) * effectiveCellHeight
            scrollPixelOffset = CGPoint(x: scrollPixelOffset.x, y: offsetY)
            if scrollSettleAnimator.isActive {
                keepAnimating = true
            } else if scrollUnconfirmedLines == 0 {
                // Fully settled: residual is exactly 0 and no unconfirmed lines remain.
                scrollSettleWindowId = nil
                scrollLastConfirmedAnchorTop = nil
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

    /// Applies the pure translation decision to the live presentation offset and rubber band.
    private func applyPresentationTranslation(_ translation: ScrollTranslation, offsetX: CGFloat, suppressLocalOffset: Bool) {
        switch translation {
        case .content(let offsetY):
            // Scrolling within real content: no rubber band.
            scrollElasticOffsetY = 0
            scrollElasticRawDistance = 0
            scrollPixelOffset = CGPoint(x: offsetX, y: suppressLocalOffset ? 0 : offsetY)

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
            scrollPixelOffset = CGPoint(x: offsetX, y: 0)
        }
    }

    private func axisLockedDeltas(deltaX: CGFloat, deltaY: CGFloat) -> (CGFloat, CGFloat) {
        if scrollAxisLock == .undecided {
            scrollAxisAccumulatedX += abs(deltaX)
            scrollAxisAccumulatedY += abs(deltaY)
            let threshold = Self.axisLockThreshold
            if scrollAxisAccumulatedY >= threshold || scrollAxisAccumulatedX >= threshold {
                scrollAxisLock = scrollAxisAccumulatedY >= scrollAxisAccumulatedX ? .vertical : .horizontal
            } else {
                return (0, 0)
            }
        }
        switch scrollAxisLock {
        case .vertical: return (0, deltaY)
        case .horizontal: return (deltaX, 0)
        case .undecided: return (0, 0)
        }
    }

    private func establishSmoothScrollTargetIfNeeded(row: Int16, col: Int16) {
        if scrollTargetWindowId == nil {
            scrollTargetWindowId = smoothScrollTargetWindowId(row: row, col: col)
        }

        if scrollTargetWindowId != nil && scrollTargetCellPosition == nil {
            scrollTargetCellPosition = (row, col)
        }
    }

    /// Resets the trackpad smooth-scroll state (offset, target, animations). It deliberately does
    /// NOT clear an in-flight thumb drag: `mouseExited` routes here, and an NSView keeps tracking a
    /// drag outside its bounds, so the drag must survive (Critical 2, policy a). The one-frame offset
    /// zero is re-applied by the next `advanceThumbDragPresentation`. Reset paths that must discard a
    /// thumb drag mid-hold call `cancelThumbDragWithFlush()` instead so the position is never dropped.
    func resetSmoothScrollState() {
        scrollAccumulator.reset()
        scrollPixelOffset = .zero
        scrollElasticOffsetY = 0
        scrollTargetWindowId = nil
        scrollTargetCellPosition = nil
        cancelScrollAnimations()
        resetScrollTrackingState()
        needsDisplay = true
    }

    private func clearSmoothScrollStateIfTargetWindowMissing() {
        // Covers the live gesture target, the thumb-drag pane, and the settle / elastic windows that
        // outlive it: if any pane owning presentation state has closed, drop the offset and cancel
        // its animation so a stale whole-cell offset can't linger after the animator finishes on a
        // vanished pane.
        let available = Set(dispatcher.currentFrameWindowIds.filter { editorInput?.currentWindowContents[$0] != nil })
        if Self.missingPresentationWindow(
            candidateWindowIds: [scrollTargetWindowId, thumbDragSession?.windowId, scrollSettleWindowId, scrollElasticWindowId],
            availableWindowIds: available
        ) {
            // The thumb-drag pane vanished: drop the session (no flush; the window is gone).
            thumbDragSession = nil
            resetSmoothScrollState()
        }
    }

    /// Returns true when any non-nil presentation window is no longer available (frame missing or
    /// content dropped), so the caller can clear stale offset/animation state. Pure for testability.
    nonisolated static func missingPresentationWindow(candidateWindowIds: [UInt16?], availableWindowIds: Set<UInt16>) -> Bool {
        candidateWindowIds.compactMap { $0 }.contains { !availableWindowIds.contains($0) }
    }

    nonisolated static func smoothScrollEventCellPosition(targetCell: (row: Int16, col: Int16)?, row: Int16, col: Int16) -> (row: Int16, col: Int16) {
        targetCell ?? (row, col)
    }

    private func smoothScrollTargetWindowId(row: Int16, col: Int16) -> UInt16? {
        if let contents = editorInput?.currentWindowContents {
            let rowValue = Int(row)
            let colValue = Int(col)
            let geometry = contents.values
                .compactMap(\.paneGeometry)
                .filter { rowColInCellRect(row: rowValue, col: colValue, rect: $0.contentRect) }
                .max { lhs, rhs in lhs.contentRect.col < rhs.contentRect.col }
            if let geometry { return geometry.windowId }
        }

        return EditorNSView.smoothScrollTargetWindowId(row: row, col: col, windowGutters: dispatcher.frameState.windowGutters)
    }

    private func clearSmoothScrollOffsetIfPointerLeftTarget(row: Int16, col: Int16) {
        let pointerWindowId = smoothScrollTargetWindowId(row: row, col: col)
        guard Self.shouldResetSmoothScrollTarget(
            currentTargetWindowId: scrollTargetWindowId,
            pointerWindowId: pointerWindowId,
            hasPixelOffset: Self.hasActivePresentationOffset(scrollPixelOffset: scrollPixelOffset, scrollElasticOffsetY: scrollElasticOffsetY)
        ) else { return }

        resetSmoothScrollOffsetPreservingTarget()
        needsDisplay = true
    }

    private func resetSmoothScrollOffsetPreservingTarget() {
        scrollAccumulator.reset()
        scrollPixelOffset = CGPoint(x: 0, y: 0)
        scrollElasticOffsetY = 0
        cancelScrollAnimations()
    }

    nonisolated static func shouldResetSmoothScrollTarget(currentTargetWindowId: UInt16?, pointerWindowId: UInt16?, hasPixelOffset: Bool) -> Bool {
        guard hasPixelOffset else { return false }
        guard let currentTargetWindowId else { return false }
        return pointerWindowId != currentTargetWindowId
    }

    nonisolated static func presentationNormalizedGutterPoint(
        _ point: NSPoint,
        presentation: LocalScrollPresentation?,
        targetGutterRect: GUICellRect?,
        cellWidth: CGFloat,
        cellHeight: CGFloat
    ) -> NSPoint {
        guard let presentation, let targetGutterRect else { return point }
        guard cellWidth > 0, cellHeight > 0 else { return point }

        let rawCol = Int(point.x / cellWidth)
        let rawRow = Int(point.y / cellHeight)
        let startRow = Int(targetGutterRect.row)
        let endRow = startRow + Int(targetGutterRect.height)
        let startCol = Int(targetGutterRect.col)
        let endCol = startCol + Int(targetGutterRect.width)
        guard rawRow >= startRow && rawRow < endRow && rawCol >= startCol && rawCol < endCol else { return point }
        guard presentation.offset.y != 0 else { return point }

        let minY = CGFloat(startRow) * cellHeight
        let maxY = CGFloat(endRow) * cellHeight - 0.001
        let normalizedY = min(max(point.y + presentation.offset.y, minY), maxY)
        return NSPoint(x: point.x, y: normalizedY)
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

        let before = windowContent.map {
            CoreTextMetalRenderer.presentationOverscanBeforeRows($0)
        } ?? CoreTextMetalRenderer.scrollOverscanBefore(scrollPresentation)

        let totalLines = windowContent?.paneGeometry?.viewport.totalLines
        let isResident = totalLines.map {
            $0 > 0 && Self.thumbDragCanPresentLocally(scrollPresentation: scrollPresentation, totalLines: $0)
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
        if event.scrollingDeltaY > 0 {
            encoder.sendMouseEvent(row: row, col: col, button: MOUSE_SCROLL_UP,
                                   modifiers: mods, eventType: MOUSE_PRESS)
            seedDiscreteScrollAnimation(row: row, col: col, lineDelta: -1)
        } else if event.scrollingDeltaY < 0 {
            encoder.sendMouseEvent(row: row, col: col, button: MOUSE_SCROLL_DOWN,
                                   modifiers: mods, eventType: MOUSE_PRESS)
            seedDiscreteScrollAnimation(row: row, col: col, lineDelta: 1)
        }
        if event.scrollingDeltaX > 0 {
            encoder.sendMouseEvent(row: row, col: col, button: MOUSE_SCROLL_LEFT,
                                   modifiers: mods, eventType: MOUSE_PRESS)
        } else if event.scrollingDeltaX < 0 {
            encoder.sendMouseEvent(row: row, col: col, button: MOUSE_SCROLL_RIGHT,
                                   modifiers: mods, eventType: MOUSE_PRESS)
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

        // A tick into a document boundary can't be committed by the BEAM, so predicting it would
        // park content one cell off-grid; suppress the seed (the scroll intent already sent above).
        let windowContent = editorInput?.currentWindowContents[windowId]
        let boundary = Self.presentationScrollBoundaryAvailability(
            for: windowContent,
            scrollPresentation: windowContent?.scrollPresentation
        )
        guard Self.discreteTickSeedsPrediction(
            lineDelta: lineDelta,
            boundaryBefore: boundary.before,
            boundaryAfter: boundary.after
        ) else { return }

        // A discrete tick supersedes an elastic rebound. Clear it before seeding the settle so a
        // rebound owned by another pane cannot be combined with this pane's presentation offset.
        scrollElasticAnimator.cancel()
        scrollElasticWindowId = nil
        scrollElasticOffsetY = 0
        scrollElasticRawDistance = 0

        // Extend any in-flight settle from its current position so rapid ticks accumulate smoothly.
        let residualNow = scrollSettleAnimator.offset()
        scrollUnconfirmedLines += lineDelta
        let residual = residualNow - CGFloat(lineDelta) * effectiveCellHeight
        beginScrollSettle(windowId: windowId, residual: residual, duration: Self.scrollDiscreteTickDuration)
    }

    /// Maps a ScrollAccumulator.Event to a protocol mouse event.
    private func sendScrollEvent(_ event: ScrollAccumulator.Event, row: Int16, col: Int16, mods: UInt8) {
        let button: UInt8
        switch event {
        case .scrollDown:  button = MOUSE_SCROLL_DOWN
        case .scrollUp:    button = MOUSE_SCROLL_UP
        case .scrollLeft:  button = MOUSE_SCROLL_LEFT
        case .scrollRight: button = MOUSE_SCROLL_RIGHT
        }
        encoder.sendMouseEvent(row: row, col: col, button: button,
                               modifiers: mods, eventType: MOUSE_PRESS)
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
            encoder.sendFontSizeAdjust(direction: fontSizeIncrease)
        }

        while magnifyAccumulator <= -magnifyStepThreshold {
            magnifyAccumulator += magnifyStepThreshold
            encoder.sendFontSizeAdjust(direction: fontSizeDecrease)
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
        encoder.sendKeyPress(codepoint: codepoint, modifiers: modifiers, seq: seq)
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
    nonisolated static func statusModeUsesLiteralSpace(statusMode: UInt8?) -> Bool {
        switch statusMode {
        case EditorStatusMode.insert, EditorStatusMode.command, EditorStatusMode.search, EditorStatusMode.replace:
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
        guard Self.shouldOptimisticallyEnterTextInputMode(codepoint: codepoint, statusMode: statusMode, cursorShape: dispatcher.frameState.cursorShape) else { return }

        markOptimisticTextInputMode()
    }

    /// Returns true for Vim-normal keys that immediately enter insert-like text input.
    /// The cursor-shape gate avoids applying Vim assumptions while CUA mode is active.
    nonisolated static func shouldOptimisticallyEnterTextInputMode(codepoint: UInt32, statusMode: UInt8?, cursorShape: CursorShape) -> Bool {
        guard statusMode == EditorStatusMode.normal, cursorShape == .block else { return false }

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
        encoder.sendSpaceLeaderChord(codepoint: codepoint, modifiers: modifiers)
    }

    private func sendSpaceLeaderRetract(codepoint: UInt32, modifiers: UInt8) {
        recoveryManager?.onKeySent()
        encoder.sendSpaceLeaderRetract(codepoint: codepoint, modifiers: modifiers)
    }

    // MARK: - Helpers

    private var effectiveCellHeight: CGFloat {
        cellHeight * CGFloat(dispatcher.frameState.lineSpacing)
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
        guard let (gutter, entry) = foldChevronEntry(at: point) else { return false }
        encoder.sendFoldToggleAtLine(windowId: gutter.windowId, bufferLine: entry.bufLine)
        return true
    }

    private func foldChevronEntry(at point: NSPoint) -> (gutter: Wire.WindowGutter, entry: Wire.GutterEntry)? {
        let presentation = localScrollPresentation
        let point = Self.presentationNormalizedGutterPoint(
            point,
            presentation: presentation,
            targetGutterRect: presentation.flatMap { editorInput?.currentWindowContents[$0.windowId]?.paneGeometry?.gutterRect },
            cellWidth: cellWidth,
            cellHeight: effectiveCellHeight
        )
        guard let (gutter, rowIndex) = gutterHit(at: point) else { return nil }
        guard Int(gutter.signColWidth) >= 3 else { return nil }

        let content = editorInput?.currentWindowContents[gutter.windowId]
        let presentationBeforeRows = Self.presentationScrollPayloadOverscanBounds(
            for: content,
            scrollPresentation: content?.scrollPresentation
        ).before
        let presentationRowIndex = rowIndex + presentationBeforeRows
        guard presentationRowIndex >= 0 && presentationRowIndex < gutter.entries.count else { return nil }

        let gutterX = CGFloat(gutter.contentCol) * cellWidth + CoreTextMetalRenderer.gutterLeftMarginPt
        let foldColumnOffset = CGFloat(Int(gutter.signColWidth) - 1)
        let foldStartX = gutterX + foldColumnOffset * cellWidth
        guard point.x >= foldStartX && point.x < foldStartX + cellWidth else { return nil }

        let entry = gutter.entries[presentationRowIndex]
        switch entry.displayType {
        case .foldOpen, .foldStart:
            return (gutter, entry)
        case .normal, .foldContinuation, .wrapContinuation, .blank:
            return nil
        }
    }

    private func updateGutterHover(at point: NSPoint) {
        let presentation = localScrollPresentation
        let point = Self.presentationNormalizedGutterPoint(
            point,
            presentation: presentation,
            targetGutterRect: presentation.flatMap { editorInput?.currentWindowContents[$0.windowId]?.paneGeometry?.gutterRect },
            cellWidth: cellWidth,
            cellHeight: effectiveCellHeight
        )
        let next: (Bool, UInt16?, UInt16?)
        if let (gutter, rowIndex) = gutterHit(at: point), rowIndex >= 0 && rowIndex < gutter.entries.count {
            next = (true, gutter.windowId, gutter.contentRow + UInt16(rowIndex))
        } else {
            next = (false, nil, nil)
        }

        guard next.0 != isMouseInGutter || next.1 != gutterHoverWindowId || next.2 != gutterHoverRow else { return }
        isMouseInGutter = next.0
        gutterHoverWindowId = next.1
        gutterHoverRow = next.2
        needsDisplay = true
    }

    private func clearGutterHover() {
        guard isMouseInGutter || gutterHoverWindowId != nil || gutterHoverRow != nil else { return }
        isMouseInGutter = false
        gutterHoverWindowId = nil
        gutterHoverRow = nil
        needsDisplay = true
    }

    private func gutterHit(at point: NSPoint) -> (gutter: Wire.WindowGutter, rowIndex: Int)? {
        let screenRow = Int(point.y / effectiveCellHeight)

        if let geometry = paneGeometryGutterHit(at: point, screenRow: screenRow),
           let gutter = dispatcher.frameState.windowGutters[geometry.windowId] {
            return (gutter, screenRow - Int(geometry.gutterRect.row))
        }

        for windowId in dispatcher.currentFrameWindowIds {
            guard let gutter = dispatcher.frameState.windowGutters[windowId] else { continue }
            let startRow = Int(gutter.contentRow)
            let endRow = startRow + Int(gutter.contentHeight)
            guard screenRow >= startRow && screenRow < endRow else { continue }

            let gutterX = CGFloat(gutter.contentCol) * cellWidth + CoreTextMetalRenderer.gutterLeftMarginPt
            let gutterWidth = CGFloat(gutter.lineNumberWidth) + CGFloat(gutter.signColWidth)
            let gutterEndX = gutterX + gutterWidth * cellWidth
            guard point.x >= gutterX && point.x < gutterEndX else { continue }

            return (gutter, screenRow - startRow)
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
        let presentation = localScrollPresentation
        let rawRow = Int16(point.y / effectiveCellHeight)
        let rawCol = max(0, Int16(point.x / cellWidth))
        let rawPointWindowId = smoothScrollTargetWindowId(row: rawRow, col: rawCol)
        let content = presentation.flatMap { editorInput?.currentWindowContents[$0.windowId] }
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
        let frameState = dispatcher.frameState

        if let geometry = paneGeometryHit(at: point, screenRow: rowValue),
           let gutter = frameState.windowGutters[geometry.windowId] {
            return gutter
        }

        let windowIds = dispatcher.currentFrameWindowIds.isEmpty ? Set(frameState.windowGutters.keys) : dispatcher.currentFrameWindowIds

        return windowIds.compactMap { frameState.windowGutters[$0] }
            .filter { gutter in
                let startRow = Int(gutter.contentRow)
                let endRow = startRow + Int(gutter.contentHeight)
                let startX = CGFloat(gutter.contentCol) * cellWidth
                let endX = startX + CGFloat(CoreTextMetalRenderer.windowWidthCols(gutter: gutter, frameCols: frameState.cols)) * cellWidth
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
        guard let contents = editorInput?.currentWindowContents else { return [] }
        let rawCol = Int(point.x / cellWidth)

        return contents.values.compactMap(\.paneGeometry).filter { geometry in
            rowColInCellRect(row: screenRow, col: rawCol, rect: geometry.totalRect)
        }
    }

    private func hitRegion(at point: NSPoint, kind: GUIHitRegion.Kind) -> GUIHitRegion? {
        guard let contents = editorInput?.currentWindowContents else { return nil }
        let screenRow = Int(point.y / effectiveCellHeight)
        let rawCol = Int(point.x / cellWidth)

        return contents.values
            .compactMap(\.paneGeometry)
            .flatMap(\.hitRegions)
            .filter { region in
                region.kind == kind && rowColInCellRect(row: screenRow, col: rawCol, rect: region.rect)
            }
            .max { lhs, rhs in lhs.rect.col < rhs.rect.col }
    }

    private func dividerHitRegion(at point: NSPoint) -> GUIHitRegion? {
        guard let contents = editorInput?.currentWindowContents else { return nil }
        let screenRow = Int(point.y / effectiveCellHeight)
        let rawCol = Int(point.x / cellWidth)

        return contents.values
            .compactMap(\.paneGeometry)
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
        return dispatcher.frameState.verticalSeparators.first { separator in
            let lineX = CGFloat(separator.col) * cellWidth
            return screenRow >= Int(separator.startRow) && screenRow <= Int(separator.endRow) && abs(point.x - lineX) <= dividerHitHalfTolerance
        }?.col
    }

    private func horizontalSeparatorRowFromFrameState(at point: NSPoint) -> UInt16? {
        let rawCol = Int(point.x / cellWidth)
        return dispatcher.frameState.horizontalSeparators.first { separator in
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
        let gutterCols = CGFloat(dispatcher.frameState.gutterCol)
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
extension EditorNSView: @preconcurrency NSTextInputClient {
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

        // Clear any active composition.
        imeComposition.clear()

        // Send committed text to the BEAM.
        guard !text.isEmpty else { return }
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

        imeComposition.setMarked(text: text, selectedRange: selectedRange,
                                  replacementRange: replacementRange)
        needsDisplay = true
    }

    /// Called to finalize/clear the composition.
    func unmarkText() {
        if let text = imeComposition.unmark() {
            commitIMEText(text)
        }
        needsDisplay = true
    }

    /// Returns the range of the current composition text.
    func markedRange() -> NSRange {
        return imeComposition.markedRange
    }

    /// Returns the range of the current selection (cursor position as zero-length range).
    func selectedRange() -> NSRange {
        // The cursor position in terms of character offset from start of document.
        // For a cell-based editor, approximate as col + row * cols.
        let offset = Int(dispatcher.frameState.cursorRow) * Int(dispatcher.frameState.cols) + Int(dispatcher.frameState.cursorCol)
        return NSRange(location: offset, length: 0)
    }

    func hasMarkedText() -> Bool {
        return imeComposition.hasMarkedText
    }

    /// Returns the screen rect for the given character range.
    /// Used by the IME to position the candidate window.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range

        // Position at the cursor location.
        let col = CGFloat(dispatcher.frameState.cursorCol)
        let row = CGFloat(dispatcher.frameState.cursorRow)
        let gutterPad: CGFloat
        if dispatcher.frameState.gutterCol > 0 {
            if dispatcher.frameState.cursorCol >= dispatcher.frameState.gutterCol {
                gutterPad = CoreTextMetalRenderer.gutterLeftMarginPt + CoreTextMetalRenderer.gutterRightGapPt
            } else {
                gutterPad = CoreTextMetalRenderer.gutterLeftMarginPt
            }
        } else {
            gutterPad = 0
        }
        let displayCellHeight = effectiveCellHeight
        let localRect = NSRect(x: col * cellWidth + gutterPad, y: row * displayCellHeight,
                                width: cellWidth, height: displayCellHeight)

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
        let gutterCols = CGFloat(dispatcher.frameState.gutterCol)
        let col: Int
        if gutterCols > 0 {
            let leftMargin = CoreTextMetalRenderer.gutterLeftMarginPt
            let rightGap = CoreTextMetalRenderer.gutterRightGapPt
            let gutterPixelEnd = leftMargin + gutterCols * cellWidth
            if localPoint.x < gutterPixelEnd {
                col = max(0, Int((localPoint.x - leftMargin) / cellWidth))
            } else {
                col = max(0, Int((localPoint.x - leftMargin - rightGap) / cellWidth))
            }
        } else {
            col = max(0, Int(localPoint.x / cellWidth))
        }
        let row = Int(localPoint.y / effectiveCellHeight)
        return row * Int(dispatcher.frameState.cols) + col
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
}

// MARK: - NSAccessibility (VoiceOver support)

extension EditorNSView {
    override func accessibilityRole() -> NSAccessibility.Role? {
        return .textArea
    }

    override func accessibilityRoleDescription() -> String? {
        return "code editor"
    }

    /// Returns the full text content of all visible lines.
    /// Reads from GUIWindowContent (0x80 opcode) semantic data.
    override func accessibilityValue() -> Any? {
        guard let contents = editorInput?.currentWindowContents else { return "" }
        var lines: [String] = []
        for (_, content) in contents.sorted(by: { $0.key < $1.key }) {
            for row in content.rows {
                lines.append(row.text)
            }
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n")
    }

    override func accessibilityNumberOfCharacters() -> Int {
        guard let contents = editorInput?.currentWindowContents else { return 0 }
        var count = 0
        for (_, content) in contents.sorted(by: { $0.key < $1.key }) {
            for (i, row) in content.rows.enumerated() {
                count += row.text.count
                if i < content.rows.count - 1 {
                    count += 1  // newline between rows
                }
            }
        }
        return count
    }

    override func accessibilityInsertionPointLineNumber() -> Int {
        return Int(dispatcher.frameState.cursorRow)
    }

    override func accessibilitySelectedText() -> String? {
        // No visual selection tracking in the GUI (owned by BEAM).
        return ""
    }

    override func accessibilitySelectedTextRange() -> NSRange {
        let offset = Int(dispatcher.frameState.cursorRow) * Int(dispatcher.frameState.cols) + Int(dispatcher.frameState.cursorCol)
        return NSRange(location: offset, length: 0)
    }

    override func isAccessibilityElement() -> Bool {
        return true
    }

    override func isAccessibilityEnabled() -> Bool {
        return true
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
            encoder.sendOpenFile(path: url.path)
        }

        claimFirstResponder()
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
