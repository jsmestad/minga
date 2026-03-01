/// MingaApp.swift — AppKit window, view, and event handling for the Minga GUI backend.
///
/// This file is compiled by swiftc into a .o that Zig links against.
/// Communication with Zig is via C-ABI functions declared in minga_gui.h.

import AppKit

// ── Constants ─────────────────────────────────────────────────────────────────

/// Hardcoded cell dimensions until font loading (#61) provides real metrics.
private let cellWidth: CGFloat = 8.0
private let cellHeight: CGFloat = 16.0

/// Background color for the window (dark gray, matching typical editor themes).
private let backgroundColor = NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0)

// ── Modifier mapping ──────────────────────────────────────────────────────────

/// Convert NSEvent modifier flags to the Minga protocol modifier bitmask.
private func modifierBits(from flags: NSEvent.ModifierFlags) -> UInt8 {
    var mods: UInt8 = 0
    if flags.contains(.shift)   { mods |= 0x01 }
    if flags.contains(.control) { mods |= 0x02 }
    if flags.contains(.option)  { mods |= 0x04 }
    if flags.contains(.command) { mods |= 0x08 }
    return mods
}

// ── Special key mapping ───────────────────────────────────────────────────────

/// Map NSEvent function key codepoints to the codepoints that libvaxis uses
/// (which match the Kitty keyboard protocol / Unicode PUA).
private func mapSpecialKey(_ char: UInt16) -> UInt32? {
    switch char {
    case 0xF700: return 0x1B5B41  // Up arrow (not a real codepoint — we use vaxis encoding)
    case 0xF701: return 0x1B5B42  // Down
    case 0xF702: return 0x1B5B44  // Left
    case 0xF703: return 0x1B5B43  // Right
    default: return nil
    }
}

/// Map special key codes to simple codepoints matching the Port protocol.
/// These use the same values as libvaxis key constants.
private func mapKeyCode(_ event: NSEvent) -> UInt32? {
    switch event.keyCode {
    case 36:  return 13    // Return
    case 48:  return 9     // Tab
    case 51:  return 127   // Backspace / Delete
    case 53:  return 27    // Escape
    case 123: return 57419 // Left arrow (vaxis)
    case 124: return 57421 // Right arrow (vaxis)
    case 125: return 57424 // Down arrow (vaxis)
    case 126: return 57422 // Up arrow (vaxis)
    case 115: return 57360 // Home (vaxis)
    case 119: return 57367 // End (vaxis)
    case 116: return 57365 // Page Up (vaxis)
    case 121: return 57366 // Page Down (vaxis)
    case 117: return 57376 // Forward Delete (vaxis)
    case 122: return 57364 // F1 (vaxis)
    case 120: return 57365 // F2
    case 99:  return 57366 // F3
    case 118: return 57367 // F4
    case 96:  return 57368 // F5
    case 97:  return 57369 // F6
    case 98:  return 57370 // F7
    case 100: return 57371 // F8
    case 101: return 57372 // F9
    case 109: return 57373 // F10
    case 103: return 57374 // F11
    case 111: return 57375 // F12
    default:  return nil
    }
}

// ── MingaView ─────────────────────────────────────────────────────────────────

/// Custom NSView that handles keyboard and mouse input for the editor.
class MingaView: NSView {

    // MARK: - First responder

    override var acceptsFirstResponder: Bool { true }

    /// Use flipped coordinates (origin at top-left) to match terminal convention.
    override var isFlipped: Bool { true }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        dirtyRect.fill()
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let mods = modifierBits(from: event.modifierFlags)

        // Try special key mapping first (arrows, function keys, etc.)
        if let codepoint = mapKeyCode(event) {
            minga_on_key_event(codepoint, mods)
            return
        }

        // For regular characters, use the characters string.
        // With ctrl held, use charactersIgnoringModifiers to get the base key.
        let chars: String?
        if event.modifierFlags.contains(.control) {
            chars = event.charactersIgnoringModifiers
        } else {
            chars = event.characters
        }

        guard let characters = chars, !characters.isEmpty else {
            return
        }

        for scalar in characters.unicodeScalars {
            minga_on_key_event(scalar.value, mods)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        // We don't send standalone modifier presses to BEAM.
        // Modifiers are captured as part of key/mouse events.
    }

    // MARK: - Mouse helpers

    /// Convert a point in view coordinates to cell (row, col).
    private func cellPosition(from point: NSPoint) -> (row: Int16, col: Int16) {
        let col = Int16(point.x / cellWidth)
        let row = Int16(point.y / cellHeight)
        return (row, col)
    }

    // MARK: - Mouse clicks

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let (row, col) = cellPosition(from: point)
        let mods = modifierBits(from: event.modifierFlags)
        minga_on_mouse_event(row, col, 0x00, mods, 0x00) // left, press
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let (row, col) = cellPosition(from: point)
        let mods = modifierBits(from: event.modifierFlags)
        minga_on_mouse_event(row, col, 0x00, mods, 0x01) // left, release
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let (row, col) = cellPosition(from: point)
        let mods = modifierBits(from: event.modifierFlags)
        minga_on_mouse_event(row, col, 0x02, mods, 0x00) // right, press
    }

    override func rightMouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let (row, col) = cellPosition(from: point)
        let mods = modifierBits(from: event.modifierFlags)
        minga_on_mouse_event(row, col, 0x02, mods, 0x01) // right, release
    }

    // MARK: - Mouse movement

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let (row, col) = cellPosition(from: point)
        let mods = modifierBits(from: event.modifierFlags)
        minga_on_mouse_event(row, col, 0x00, mods, 0x03) // left, drag
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let (row, col) = cellPosition(from: point)
        let mods = modifierBits(from: event.modifierFlags)
        minga_on_mouse_event(row, col, 0x03, mods, 0x02) // none, motion
    }

    // MARK: - Scroll

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let (row, col) = cellPosition(from: point)
        let mods = modifierBits(from: event.modifierFlags)

        if event.scrollingDeltaY > 0 {
            minga_on_mouse_event(row, col, 0x40, mods, 0x00) // wheel_up, press
        } else if event.scrollingDeltaY < 0 {
            minga_on_mouse_event(row, col, 0x41, mods, 0x00) // wheel_down, press
        }
        // Horizontal scroll could be added later (0x42 right, 0x43 left)
    }
}

// ── MingaWindowDelegate ───────────────────────────────────────────────────────

/// Handles window lifecycle events (resize, close).
class MingaWindowDelegate: NSObject, NSWindowDelegate {

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let size = window.contentView?.bounds.size ?? window.frame.size
        let cols = UInt16(size.width / cellWidth)
        let rows = UInt16(size.height / cellHeight)
        if cols > 0 && rows > 0 {
            minga_on_resize(cols, rows)
        }
    }

    func windowWillClose(_ notification: Notification) {
        minga_on_window_close()
        // Terminate the NSApp run loop. This unblocks minga_gui_start()
        // and lets the Zig side clean up.
        NSApp.terminate(nil)
    }
}

// ── Entry point (called from Zig) ─────────────────────────────────────────────

/// Strong reference to the window delegate to prevent deallocation.
private var windowDelegate: MingaWindowDelegate?

/// Starts the macOS GUI application. Called from Zig's GuiRuntime.run().
/// Blocks on NSApp.run() until the application terminates.
@_cdecl("minga_gui_start")
public func mingaGuiStart(_ initialWidth: UInt16, _ initialHeight: UInt16) {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    // Create the window.
    let contentRect = NSRect(
        x: 0, y: 0,
        width: CGFloat(initialWidth),
        height: CGFloat(initialHeight)
    )
    let styleMask: NSWindow.StyleMask = [
        .titled, .closable, .resizable, .miniaturizable
    ]
    let window = NSWindow(
        contentRect: contentRect,
        styleMask: styleMask,
        backing: .buffered,
        defer: false
    )
    window.title = "Minga"
    window.minSize = NSSize(width: cellWidth * 20, height: cellHeight * 5)
    window.center()

    // Create and set the custom view.
    let view = MingaView(frame: contentRect)
    window.contentView = view
    // Enable mouse moved events for mouseMoved handler.
    window.acceptsMouseMovedEvents = true

    // Set window delegate.
    let delegate = MingaWindowDelegate()
    windowDelegate = delegate  // prevent deallocation
    window.delegate = delegate

    // Show window and activate.
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)

    // Run the event loop. This blocks until NSApp.terminate() is called.
    app.run()
}
