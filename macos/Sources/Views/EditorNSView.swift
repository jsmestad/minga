/// NSView subclass that handles Metal rendering and keyboard/mouse input.
///
/// This is the core editor surface: a CAMetalLayer-backed view that receives
/// raw key events and translates them to protocol encoder calls. Wrapped by
/// EditorView (NSViewRepresentable) for use in SwiftUI.

import AppKit
import Metal
import QuartzCore

/// The main editor view. Owns the Metal layer, receives all input events,
/// and triggers rendering when the CommandDispatcher signals a frame is ready.
final class EditorNSView: NSView {
    let encoder: InputEncoder
    let metalRenderer: MetalRenderer
    let fontFace: FontFace
    let cellGrid: CellGrid

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

    init(encoder: InputEncoder, metalRenderer: MetalRenderer, fontFace: FontFace, cellGrid: CellGrid) {
        self.encoder = encoder
        self.metalRenderer = metalRenderer
        self.fontFace = fontFace
        self.cellGrid = cellGrid
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not implemented") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = metalRenderer.device
        layer.pixelFormat = .bgra8Unorm
        layer.contentsScale = window?.backingScaleFactor ?? 2.0
        layer.framebufferOnly = true
        return layer
    }

    override func updateLayer() {
        // Rendering is triggered by CommandDispatcher.onFrameReady, not updateLayer.
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = window {
            metalLayer?.contentsScale = window.backingScaleFactor

            // Observe window becoming key to reclaim first responder.
            // SwiftUI can reassign it during layout passes.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidBecomeKey),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
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
        metalLayer?.drawableSize = convertToBacking(bounds.size)

        guard newSize.width > 0, newSize.height > 0 else { return }

        let newCols = UInt16(max(newSize.width / cellWidth, 1))
        let newRows = UInt16(max(newSize.height / cellHeight, 1))

        if !readySent {
            // First real frame size: send the ready event with actual
            // window dimensions so the BEAM never sees wrong defaults.
            readySent = true
            cellGrid.resize(newCols: newCols, newRows: newRows)
            encoder.sendReady(cols: newCols, rows: newRows)
            PortLogger.info("Window ready: \(newCols)x\(newRows) cells (\(Int(newSize.width))x\(Int(newSize.height))pt)")
        } else if newCols != cellGrid.cols || newRows != cellGrid.rows {
            cellGrid.resize(newCols: newCols, newRows: newRows)
            encoder.sendResize(cols: newCols, rows: newRows)
            PortLogger.info("Window resized: \(newCols)x\(newRows) cells")
        }
    }

    /// Sub-cell-height vertical pixel offset for smooth trackpad scrolling.
    /// Positive = content shifted up (scrolled down). Always in range [0, cellHeight).
    private var scrollPixelOffset: CGFloat = 0

    /// Render the current cell grid state to the Metal layer.
    func renderFrame() {
        guard let layer = metalLayer else { return }
        let offset = SIMD2<Float>(0, Float(scrollPixelOffset))
        metalRenderer.render(grid: cellGrid, face: fontFace, layer: layer, scrollOffset: offset)
        cellGrid.dirty = false
    }

    var metalLayer: CAMetalLayer? {
        layer as? CAMetalLayer
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

    // MARK: - Keyboard

    /// Intercept key equivalents (Cmd+key, etc.) before AppKit/SwiftUI
    /// can consume them for menus or focus navigation.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        let mods = modifierBits(from: event.modifierFlags)

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

        // Re-render immediately with the new fractional offset
        renderFrame()
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
