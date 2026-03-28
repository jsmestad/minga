/// MTKView subclass that handles Metal rendering and keyboard/mouse input.
///
/// This is the core editor surface. It receives raw key events and translates
/// them to protocol encoder calls. Rendering is event-driven: BEAM frame
/// updates and scroll events call `setNeedsDisplay(_:)`, and MTKView's
/// built-in display link coalesces them into one GPU frame per vsync.
///
/// Wrapped by EditorView (NSViewRepresentable) for use in SwiftUI.

import AppKit
import os
import MetalKit

/// The main editor view. Uses MTKView's built-in display link for
/// vsync-driven rendering with automatic frame coalescing.
final class EditorNSView: MTKView {
    var encoder: InputEncoder
    private(set) var fontFace: FontFace

    /// Command dispatcher owning frame metadata.
    let dispatcher: CommandDispatcher

    /// CoreText-based renderer.
    let coreTextRenderer: CoreTextMetalRenderer

    /// Font manager for per-span font family support.
    let fontManager: FontManager

    /// GUI state for semantic window content (0x80) and theme colors.
    var guiState: GUIState?

    private var trackingArea: NSTrackingArea?

    /// IME composition state (marked text tracking).
    private var imeComposition = IMEComposition()

    /// Cell dimensions in points (used for mouse → cell coordinate mapping).
    var cellWidth: CGFloat { CGFloat(fontFace.cellWidth) }
    var cellHeight: CGFloat { CGFloat(fontFace.cellHeight) }

    /// Track last reported cell position to avoid flooding the Port with
    /// redundant mouse move events.
    private var lastMoveRow: Int16 = -1
    private var lastMoveCol: Int16 = -1

    /// Whether the ready event has been sent to the BEAM. Deferred until
    /// setFrameSize so we send the actual window dimensions, not hardcoded defaults.
    private var readySent = false

    /// Last viewport top used for scroll indicator change detection.
    private var lastViewportTopForScroll: UInt32 = 0xFFFF_FFFF

    /// First responder guard that prevents SwiftUI from stealing keyboard focus.
    /// Installed when the view moves to a window.
    private var firstResponderGuard: FirstResponderGuard?

    /// When true, the agent chat SwiftUI overlay is visible. The Metal
    /// surface is at opacity(0) so the SwiftUI overlay is not occluded
    /// by the NSView layer. A local key event monitor forwards keyboard
    /// events to keyDown since opacity(0) disconnects normal event
    /// delivery from the SwiftUI hosting layer.
    private(set) var agentChatVisible: Bool = false

    /// Local event monitor that forwards keyboard events to keyDown
    /// when the agent chat overlay is visible. Installed/removed by
    /// setAgentChatVisible. This is Apple's documented API for event
    /// interception when NSWindow subclassing isn't available.
    private var agentKeyMonitor: Any?

    /// Status bar state from the BEAM. Used by the space leader key-chord
    /// logic to check whether insert mode is active (SPC is always literal
    /// in insert mode, never a leader key).
    var statusBarState: StatusBarState?

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
    private(set) var cursorBlinkVisible: Bool = true

    /// The async task driving the blink timer. Cancelled on focus loss,
    /// cursor hide, or dealloc.
    private var blinkTask: Task<Void, Never>?

    /// Observation token for accessibility display options changes.
    private var accessibilityObserver: NSObjectProtocol?

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

        // Standard Metal layer config.
        colorPixelFormat = .bgra8Unorm_srgb
        layer?.isOpaque = true

        // Observe system scroller style preference.
        observeScrollerStyle()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Not implemented") }

    /// Cleans up blink timer and accessibility observer.
    /// Called from viewDidMoveToWindow when window is nil (view removed).
    private func cleanupBlinkResources() {
        blinkTask?.cancel()
        blinkTask = nil
        if let observer = accessibilityObserver {
            NotificationCenter.default.removeObserver(observer)
            accessibilityObserver = nil
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    // MARK: - Cursor blink control

    /// Resets the cursor to visible and restarts the blink cycle.
    /// Called on keystrokes, cursor movement, and focus gain.
    func resetCursorBlink() {
        blinkTask?.cancel()
        cursorBlinkVisible = true

        // Don't blink when Accessibility > Reduce Motion is on.
        guard !SystemBlinkTiming.blinkingDisabled else { return }

        let timing = SystemBlinkTiming.system

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

    /// Stops the blink timer and shows the cursor as solid.
    /// Called on focus loss and when the cursor is hidden (minibuffer active).
    func stopCursorBlink() {
        blinkTask?.cancel()
        cursorBlinkVisible = true
        needsDisplay = true
    }

    /// Starts observing Accessibility display option changes so the blink
    /// timer responds to live Reduce Motion toggles. Idempotent: only
    /// registers once (guards against repeated viewDidMoveToWindow calls).
    private func observeAccessibilityChanges() {
        guard accessibilityObserver == nil else { return }
        accessibilityObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // queue: .main guarantees main thread, but Swift 6 strict
            // concurrency can't verify this statically. Use
            // assumeIsolated to bridge the gap.
            MainActor.assumeIsolated {
                if SystemBlinkTiming.blinkingDisabled {
                    self?.stopCursorBlink()
                } else {
                    self?.resetCursorBlink()
                }
            }
        }
    }

    // MARK: - Rendering

    /// Sub-cell-height vertical pixel offset for smooth trackpad scrolling.
    /// Positive = content shifted up (scrolled down). Always in [0, cellHeight).
    private var scrollPixelOffset: CGFloat = 0

    /// Schedule a render on the next vsync. Multiple calls between vsyncs
    /// are coalesced by MTKView into a single draw() call.
    func renderFrame() {
        needsDisplay = true
    }

    /// Previous cursor position for accessibility change detection.
    private var lastAccessibilityCursorRow: UInt16 = 0
    private var lastAccessibilityCursorCol: UInt16 = 0

    /// Called by MTKView's display link at vsync when needsDisplay is true.
    override func draw(_ dirtyRect: NSRect) {
        guard let drawable = currentDrawable else { return }
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
        if fs.viewportTopLine != lastViewportTopForScroll && fs.viewportTopLine != 0xFFFF_FFFF {
            lastViewportTopForScroll = fs.viewportTopLine
            flashScrollIndicator()
        }

        coreTextRenderer.render(frameState: fs, fontManager: fontManager,
                                cursorBlinkVisible: cursorBlinkVisible,
                                windowContents: guiState?.windowContents ?? [:],
                                themeColors: guiState?.themeColors,
                                drawable: drawable, viewportSize: drawableSize,
                                contentScale: scale)
        dispatcher.frameState.dirty = false
    }

    // MARK: - Font update

    /// Called when the BEAM sends a set_font command. Replaces the font face,
    /// resizes the grid to match new cell dimensions, and sends a resize event
    /// to the BEAM so it re-renders with the new grid size.
    func updateFont(_ newFace: FontFace) {
        self.fontFace = newFace

        // Recompute grid dimensions with the new cell size.
        let newCellW = CGFloat(newFace.cellWidth)
        let newCellH = CGFloat(newFace.cellHeight)
        guard newCellW > 0, newCellH > 0 else { return }

        let newCols = UInt16(max(frame.width / newCellW, 1))
        let newRows = UInt16(max(frame.height / newCellH, 1))

        if newCols != dispatcher.frameState.cols || newRows != dispatcher.frameState.rows {
            dispatcher.frameState.resize(newCols: newCols, newRows: newRows)
            encoder.sendResize(cols: newCols, rows: newRows)
        }

        // Force a full re-render.
        renderFrame()
    }

    // MARK: - Window lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = window else {
            cleanupBlinkResources()
            return
        }

        // Match the Metal layer's scale to the window's backing scale.
        (layer as? CAMetalLayer)?.contentsScale = window.backingScaleFactor

        // Restore window position and size from previous session.
        // This fires before the window is made key/visible, so the
        // saved frame is applied without a visible position jump.
        window.setFrameAutosaveName("MingaEditorWindow")

        // Observe window becoming/losing key to manage first responder
        // and cursor blink. SwiftUI can reassign first responder during
        // layout passes.
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

        // Install the first responder guard. This uses KVO to monitor
        // first responder changes and immediately redirect them back
        // to this editor view. Combined with .focusable(false) on all
        // SwiftUI chrome, this ensures vim keybindings always work.
        firstResponderGuard = FirstResponderGuard(window: window, editorView: self)

        updateTrackingArea()
        claimFirstResponder()
        observeAccessibilityChanges()
        resetCursorBlink()
    }

    /// Claim first responder after a short delay so SwiftUI's layout pass
    /// completes first. Without the async dispatch, SwiftUI can immediately
    /// reassign first responder to its own focus system.
    func claimFirstResponder() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            if window.firstResponder !== self {
                window.makeFirstResponder(self)
            }
        }
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        claimFirstResponder()
        resetCursorBlink()
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        stopCursorBlink()
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

        let newCols = UInt16(max(newSize.width / cellWidth, 1))
        let newRows = UInt16(max(newSize.height / cellHeight, 1))

        if !readySent {
            // First real frame size: send the ready event with actual
            // window dimensions so the BEAM never sees wrong defaults.
            readySent = true
            dispatcher.frameState.resize(newCols: newCols, newRows: newRows)
            encoder.sendReady(cols: newCols, rows: newRows)
            os_signpost(.event, log: startupLog, name: "ReadySent", "%{public}dx%{public}d", newCols, newRows)
            PortLogger.info("Window ready: \(newCols)x\(newRows) cells (\(Int(newSize.width))x\(Int(newSize.height))pt)")
        } else if newCols != dispatcher.frameState.cols || newRows != dispatcher.frameState.rows {
            dispatcher.frameState.resize(newCols: newCols, newRows: newRows)
            encoder.sendResize(cols: newCols, rows: newRows)
            PortLogger.info("Window resized: \(newCols)x\(newRows) cells")
        }
    }

    // MARK: - Tracking area

    private func updateTrackingArea() {
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Agent chat key forwarding

    /// Activates Board overlay mode: suspends the first responder guard
    /// so SwiftUI card interactions work, but keys still flow to the BEAM
    /// through the EditorNSView (it remains in the responder chain at
    /// opacity 0 behind the BoardView).
    func setBoardVisible(_ visible: Bool) {
        firstResponderGuard?.suspended = visible
    }

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

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command {
            switch event.charactersIgnoringModifiers {
            case "q", "h", "m":
                return false  // Let the system handle Quit, Hide, Minimize
            default:
                break
            }
        }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        resetCursorBlink()
        let mods = modifierBits(from: event.modifierFlags)

        // ── Space leader key-chord interception ──
        // When SPC is pending or held, intercept chord keys before any
        // other processing. Skip when:
        // - IME is composing (SPC is the commit key in CJK input methods)
        // - Insert mode is active (SPC is always a literal space, never a leader)
        let isInsertMode = statusBarState?.isInsertMode ?? false
        if !imeComposition.hasMarkedText && !isInsertMode {
            if let chars = event.charactersIgnoringModifiers, chars == " ", mods == 0 {
                // Bare SPC keyDown (no modifiers)
                if event.isARepeat {
                    // User holding SPC for repeated spaces. Cancel chord detection.
                    cancelSpaceGrace()
                    spaceKeyDown = false
                    encoder.sendKeyPress(codepoint: 0x20, modifiers: 0)
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
                    self.encoder.sendKeyPress(codepoint: 0x20, modifiers: 0)
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
                encoder.sendSpaceLeaderChord(codepoint: codepoint(from: event, mods: mods), modifiers: mods)
                return
            }

            if spaceKeyDown {
                // Fallback chord: SPC was already sent (grace timer fired).
                // Tell BEAM to retract the space and enter leader.
                spaceKeyDown = false
                encoder.sendSpaceLeaderRetract(codepoint: codepoint(from: event, mods: mods), modifiers: mods)
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
            encoder.sendKeyPress(codepoint: codepoint, modifiers: mods)
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
                    encoder.sendKeyPress(codepoint: scalar.value, modifiers: textMods)
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
                encoder.sendKeyPress(codepoint: 0x20, modifiers: 0)
            }
            spaceKeyDown = false
        }
    }

    override func flagsChanged(with event: NSEvent) {
        // No action needed for bare modifier presses.
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
        resetCursorBlink()
        let (row, col) = cellPosition(from: event)
        let cc = UInt8(clamping: event.clickCount)
        encoder.sendMouseEvent(row: row, col: col, button: MOUSE_BUTTON_LEFT,
                               modifiers: modifierBits(from: event.modifierFlags),
                               eventType: MOUSE_PRESS, clickCount: cc)
    }

    override func mouseUp(with event: NSEvent) {
        let (row, col) = cellPosition(from: event)
        encoder.sendMouseEvent(row: row, col: col, button: MOUSE_BUTTON_LEFT,
                               modifiers: modifierBits(from: event.modifierFlags),
                               eventType: MOUSE_RELEASE)
    }

    override func rightMouseDown(with event: NSEvent) {
        let (row, col) = cellPosition(from: event)
        encoder.sendMouseEvent(row: row, col: col, button: MOUSE_BUTTON_RIGHT,
                               modifiers: modifierBits(from: event.modifierFlags),
                               eventType: MOUSE_PRESS)
    }

    override func rightMouseUp(with event: NSEvent) {
        let (row, col) = cellPosition(from: event)
        encoder.sendMouseEvent(row: row, col: col, button: MOUSE_BUTTON_RIGHT,
                               modifiers: modifierBits(from: event.modifierFlags),
                               eventType: MOUSE_RELEASE)
    }

    override func otherMouseDown(with event: NSEvent) {
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
        let (row, col) = cellPosition(from: event)
        encoder.sendMouseEvent(row: row, col: col, button: MOUSE_BUTTON_LEFT,
                               modifiers: modifierBits(from: event.modifierFlags),
                               eventType: MOUSE_DRAG)
    }

    override func mouseMoved(with event: NSEvent) {
        let (row, col) = cellPosition(from: event)
        guard row != lastMoveRow || col != lastMoveCol else { return }
        lastMoveRow = row
        lastMoveCol = col
        encoder.sendMouseEvent(row: row, col: col, button: MOUSE_BUTTON_NONE,
                               modifiers: modifierBits(from: event.modifierFlags),
                               eventType: MOUSE_MOTION)
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
        alwaysShowScrollbar = NSScroller.preferredScrollerStyle == .legacy
        if alwaysShowScrollbar {
            coreTextRenderer.scrollIndicatorAlpha = 1.0
        }

        Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSScroller.preferredScrollerStyleDidChangeNotification) {
                guard let self else { return }
                self.alwaysShowScrollbar = NSScroller.preferredScrollerStyle == .legacy
                if self.alwaysShowScrollbar {
                    self.coreTextRenderer.scrollIndicatorAlpha = 1.0
                    self.setNeedsDisplay(self.bounds)
                } else {
                    self.flashScrollIndicator()
                }
            }
        }
    }

    override func scrollWheel(with event: NSEvent) {
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
    private func handleTrackpadScroll(event: NSEvent, row: Int16, col: Int16, mods: UInt8) {
        if event.phase == .began {
            scrollAccumulator.reset()
        }

        // Vertical: smooth sub-line pixel offset
        let vEvents = scrollAccumulator.accumulateVertical(
            deltaY: event.scrollingDeltaY, cellHeight: cellHeight)
        for e in vEvents {
            sendScrollEvent(e, row: row, col: col, mods: mods)
        }
        scrollPixelOffset = scrollAccumulator.pixelOffsetY

        // Horizontal: discrete column events
        let hEvents = scrollAccumulator.accumulateHorizontal(
            deltaX: event.scrollingDeltaX, cellWidth: cellWidth)
        for e in hEvents {
            sendScrollEvent(e, row: row, col: col, mods: mods)
        }

        // Snap to zero when gesture/momentum ends
        if (event.phase == .ended || event.phase == .cancelled) && event.momentumPhase == [] {
            scrollAccumulator.snapVertical()
            scrollPixelOffset = 0
        }
        if event.momentumPhase == .ended {
            scrollAccumulator.snapVertical()
            scrollPixelOffset = 0
        }

        // Tell MTKView we need a frame. The display link coalesces
        // multiple scroll events between vsyncs into one draw() call.
        needsDisplay = true
    }

    /// Discrete mouse wheel: one event per click, no accumulation.
    private func handleDiscreteScroll(event: NSEvent, row: Int16, col: Int16, mods: UInt8) {
        if event.scrollingDeltaY > 0 {
            encoder.sendMouseEvent(row: row, col: col, button: MOUSE_SCROLL_UP,
                                   modifiers: mods, eventType: MOUSE_PRESS)
        } else if event.scrollingDeltaY < 0 {
            encoder.sendMouseEvent(row: row, col: col, button: MOUSE_SCROLL_DOWN,
                                   modifiers: mods, eventType: MOUSE_PRESS)
        }
        if event.scrollingDeltaX > 0 {
            encoder.sendMouseEvent(row: row, col: col, button: MOUSE_SCROLL_LEFT,
                                   modifiers: mods, eventType: MOUSE_PRESS)
        } else if event.scrollingDeltaX < 0 {
            encoder.sendMouseEvent(row: row, col: col, button: MOUSE_SCROLL_RIGHT,
                                   modifiers: mods, eventType: MOUSE_PRESS)
        }
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

    /// Send committed text from IME to the BEAM as individual key presses.
    private func commitIMEText(_ text: String) {
        for scalar in text.unicodeScalars {
            encoder.sendKeyPress(codepoint: scalar.value, modifiers: 0)
        }
    }

    // MARK: - Helpers

    private func cellPosition(from event: NSEvent) -> (row: Int16, col: Int16) {
        let point = convert(event.locationInWindow, from: nil)
        let col = Int16(point.x / cellWidth)
        let row = Int16(point.y / cellHeight)
        return (row, col)
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
        let localRect = NSRect(x: col * cellWidth, y: row * cellHeight,
                                width: cellWidth, height: cellHeight)

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
        let col = Int(localPoint.x / cellWidth)
        let row = Int(localPoint.y / cellHeight)
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
        guard let contents = guiState?.windowContents else { return "" }
        var lines: [String] = []
        for (_, content) in contents.sorted(by: { $0.key < $1.key }) {
            for row in content.rows {
                lines.append(row.text)
            }
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n")
    }

    override func accessibilityNumberOfCharacters() -> Int {
        guard let contents = guiState?.windowContents else { return 0 }
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
