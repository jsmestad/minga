/// MTKView subclass that handles Metal rendering and keyboard/mouse input.
///
/// This is the core editor surface. It receives raw key events and translates
/// them to protocol encoder calls. Rendering is event-driven: BEAM frame
/// updates and scroll events call `setNeedsDisplay(_:)`, and MTKView's
/// built-in display link coalesces them into one GPU frame per vsync.
///
/// Wrapped by EditorView (NSViewRepresentable) for use in SwiftUI.

import AppKit
import MetalKit

/// The main editor view. Uses MTKView's built-in display link for
/// vsync-driven rendering with automatic frame coalescing.
final class EditorNSView: MTKView {
    let encoder: InputEncoder
    private(set) var fontFace: FontFace

    /// Line-based styled run buffer for CoreText rendering.
    let lineBuffer: LineBuffer

    /// CoreText-based renderer.
    let coreTextRenderer: CoreTextMetalRenderer

    /// Font manager for per-span font family support.
    let fontManager: FontManager

    private var trackingArea: NSTrackingArea?

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

    /// First responder guard that prevents SwiftUI from stealing keyboard focus.
    /// Installed when the view moves to a window.
    private var firstResponderGuard: FirstResponderGuard?

    /// When true, the agent chat SwiftUI overlay is visible. A local key
    /// event monitor intercepts all keyboard input and forwards it to
    /// `keyDown` so the BEAM still receives keys even though the
    /// FirstResponderGuard is suspended (needed for SwiftUI text selection).
    private(set) var agentChatVisible: Bool = false
    private var agentKeyMonitor: Any?

    init(encoder: InputEncoder, fontFace: FontFace, lineBuffer: LineBuffer,
         coreTextRenderer: CoreTextMetalRenderer, fontManager: FontManager) {
        self.encoder = encoder
        self.fontFace = fontFace
        self.lineBuffer = lineBuffer
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
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Not implemented") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    // MARK: - Rendering

    /// Sub-cell-height vertical pixel offset for smooth trackpad scrolling.
    /// Positive = content shifted up (scrolled down). Always in [0, cellHeight).
    private var scrollPixelOffset: CGFloat = 0

    /// Schedule a render on the next vsync. Multiple calls between vsyncs
    /// are coalesced by MTKView into a single draw() call.
    func renderFrame() {
        needsDisplay = true
    }

    /// Called by MTKView's display link at vsync when needsDisplay is true.
    override func draw(_ dirtyRect: NSRect) {
        guard let drawable = currentDrawable else { return }
        let scale = Float(window?.backingScaleFactor ?? 2.0)

        coreTextRenderer.render(lineBuffer: lineBuffer, fontManager: fontManager,
                                drawable: drawable, viewportSize: drawableSize,
                                contentScale: scale)
        lineBuffer.dirty = false
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

        if newCols != lineBuffer.cols || newRows != lineBuffer.rows {
            lineBuffer.resize(newCols: newCols, newRows: newRows)
            encoder.sendResize(cols: newCols, rows: newRows)
        }

        // Force a full re-render.
        renderFrame()
    }

    // MARK: - Window lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = window {
            // Match the Metal layer's scale to the window's backing scale.
            (layer as? CAMetalLayer)?.contentsScale = window.backingScaleFactor

            // Observe window becoming key to reclaim first responder.
            // SwiftUI can reassign it during layout passes.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidBecomeKey),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )

            // Install the first responder guard. This uses KVO to monitor
            // first responder changes and immediately redirect them back
            // to this editor view. Combined with .focusable(false) on all
            // SwiftUI chrome, this ensures vim keybindings always work.
            firstResponderGuard = FirstResponderGuard(window: window, editorView: self)
        }
        updateTrackingArea()
        claimFirstResponder()
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
            lineBuffer.resize(newCols: newCols, newRows: newRows)
            encoder.sendReady(cols: newCols, rows: newRows)
            PortLogger.info("Window ready: \(newCols)x\(newRows) cells (\(Int(newSize.width))x\(Int(newSize.height))pt)")
        } else if newCols != lineBuffer.cols || newRows != lineBuffer.rows {
            lineBuffer.resize(newCols: newCols, newRows: newRows)
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

    /// Activates the agent chat overlay mode: suspends the first responder
    /// guard (so SwiftUI text selection works) and installs a local key
    /// monitor that forwards all keyboard input to `keyDown` (so the BEAM
    /// still receives keys for vim navigation and prompt typing).
    func setAgentChatVisible(_ visible: Bool) {
        agentChatVisible = visible
        firstResponderGuard?.suspended = visible

        if visible {
            installAgentKeyMonitor()
        } else {
            removeAgentKeyMonitor()
            claimFirstResponder()
        }
    }

    private func installAgentKeyMonitor() {
        guard agentKeyMonitor == nil else { return }
        agentKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            // CMD+C: trigger system copy for SwiftUI text selection
            if event.modifierFlags.contains(.command),
               let chars = event.charactersIgnoringModifiers,
               chars == "c"
            {
                NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                return nil
            }

            // `y` with no modifiers: trigger copy, swallow the event.
            // Without swallowing, the BEAM enters operator-pending yank
            // mode and the next keypress is misinterpreted as a motion.
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.characters == "y" && flags.isEmpty {
                NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                return nil
            }

            // Forward all other keys to keyDown so the BEAM receives them
            self.keyDown(with: event)
            return nil
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
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        let mods = modifierBits(from: event.modifierFlags)

        // Cmd+V: intercept paste and send as a single paste_event instead
        // of decomposing into individual key_press events. This lets the
        // BEAM side detect multi-line pastes and collapse them.
        if event.modifierFlags.contains(.command),
           let chars = event.charactersIgnoringModifiers,
           chars == "v"
        {
            if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
                encoder.sendPasteEvent(text: text)
            }
            return
        }

        // Special keys (arrows, Enter, Escape, etc.)
        if let codepoint = mapKeyCode(event) {
            encoder.sendKeyPress(codepoint: codepoint, modifiers: mods)
            return
        }

        // Text characters: use event.characters which reflects Shift.
        // Strip Shift bit since the codepoint already encodes it.
        let textMods = mods & ~0x01

        let chars: String?
        if event.modifierFlags.contains(.control) {
            chars = event.charactersIgnoringModifiers
        } else {
            chars = event.characters
        }

        guard let characters = chars, !characters.isEmpty else { return }

        for scalar in characters.unicodeScalars {
            encoder.sendKeyPress(codepoint: scalar.value, modifiers: textMods)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        // No action needed for bare modifier presses.
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
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

    override func scrollWheel(with event: NSEvent) {
        let (row, col) = cellPosition(from: event)
        let mods = modifierBits(from: event.modifierFlags)

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
    case 119: return 57367  // End
    case 116: return 57365  // Page Up
    case 121: return 57366  // Page Down
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
