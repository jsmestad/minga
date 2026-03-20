/// Tests for mouse event handling in EditorNSView.
///
/// Verifies that mouse events (click, drag, scroll, right-click, middle-click)
/// are correctly converted to protocol events with the right button, modifiers,
/// event type, click count, and cell coordinates.
///
/// Uses SpyEncoder to capture the protocol events sent by the view.
/// NSEvent.mouseEvent creates synthetic events at known pixel positions;
/// the view's cellPosition divides by cell dimensions to get grid coordinates.

import Testing
import Foundation
import AppKit

@Suite("EditorNSView Mouse Input")
struct MouseInputTests {

    /// Helper to create an EditorNSView with SpyEncoder for mouse testing.
    /// Uses scale=1.0 so cell dimensions are predictable (no Retina scaling
    /// of the coordinate math; cellWidth/cellHeight are in points).
    @MainActor
    private func makeView(spy: SpyEncoder) -> EditorNSView? {
        let face = FontFace(name: "Menlo", size: 13.0, scale: 1.0)
        let fm = FontManager(name: "Menlo", size: 13.0, scale: 1.0)
        let lineBuffer = LineBuffer(cols: 80, rows: 24)
        guard let ctRenderer = CoreTextMetalRenderer() else { return nil }
        ctRenderer.setupLineRenderer(fontManager: fm)
        let view = EditorNSView(encoder: spy, fontFace: face, lineBuffer: lineBuffer,
                                coreTextRenderer: ctRenderer, fontManager: fm)
        // Give the view a real frame so cellPosition math works.
        // Without a window, convert(_:from:) returns the point unchanged,
        // so locationInWindow IS the local point.
        view.frame = NSRect(x: 0, y: 0,
                           width: CGFloat(face.cellWidth) * 80,
                           height: CGFloat(face.cellHeight) * 24)
        return view
    }

    /// Creates a mouse event at the given pixel position.
    private func mouseEvent(
        type: NSEvent.EventType,
        location: NSPoint,
        modifiers: NSEvent.ModifierFlags = [],
        clickCount: Int = 1
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: type == .leftMouseUp ? 0.0 : 1.0
        )
    }

    // MARK: - Left click

    @Test("mouseDown sends left button press with cell coordinates")
    @MainActor func leftMouseDown() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }
        let cw = view.cellWidth
        let ch = view.cellHeight

        // Click at pixel (cw * 10, ch * 5) = cell (row=5, col=10)
        guard let event = mouseEvent(type: .leftMouseDown,
                                     location: NSPoint(x: cw * 10, y: ch * 5)) else { return }
        view.mouseDown(with: event)

        #expect(spy.mouseEventCalls.count == 1)
        let call = spy.mouseEventCalls[0]
        #expect(call.button == MOUSE_BUTTON_LEFT)
        #expect(call.eventType == MOUSE_PRESS)
        #expect(call.row == 5)
        #expect(call.col == 10)
        #expect(call.clickCount == 1)
    }

    @Test("mouseUp sends left button release")
    @MainActor func leftMouseUp() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }

        guard let event = mouseEvent(type: .leftMouseUp,
                                     location: NSPoint(x: 0, y: 0)) else { return }
        view.mouseUp(with: event)

        #expect(spy.mouseEventCalls.count == 1)
        #expect(spy.mouseEventCalls[0].button == MOUSE_BUTTON_LEFT)
        #expect(spy.mouseEventCalls[0].eventType == MOUSE_RELEASE)
    }

    @Test("double-click forwards clickCount=2")
    @MainActor func doubleClick() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }

        guard let event = mouseEvent(type: .leftMouseDown,
                                     location: NSPoint(x: 0, y: 0),
                                     clickCount: 2) else { return }
        view.mouseDown(with: event)

        #expect(spy.mouseEventCalls[0].clickCount == 2)
    }

    @Test("triple-click forwards clickCount=3")
    @MainActor func tripleClick() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }

        guard let event = mouseEvent(type: .leftMouseDown,
                                     location: NSPoint(x: 0, y: 0),
                                     clickCount: 3) else { return }
        view.mouseDown(with: event)

        #expect(spy.mouseEventCalls[0].clickCount == 3)
    }

    // MARK: - Right click

    @Test("rightMouseDown sends right button press")
    @MainActor func rightMouseDown() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }

        guard let event = mouseEvent(type: .rightMouseDown,
                                     location: NSPoint(x: 0, y: 0)) else { return }
        view.rightMouseDown(with: event)

        #expect(spy.mouseEventCalls.count == 1)
        #expect(spy.mouseEventCalls[0].button == MOUSE_BUTTON_RIGHT)
        #expect(spy.mouseEventCalls[0].eventType == MOUSE_PRESS)
    }

    // MARK: - Middle click

    @Test("otherMouseDown sends middle button press")
    @MainActor func middleMouseDown() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }

        guard let event = mouseEvent(type: .otherMouseDown,
                                     location: NSPoint(x: 0, y: 0)) else { return }
        view.otherMouseDown(with: event)

        #expect(spy.mouseEventCalls.count == 1)
        #expect(spy.mouseEventCalls[0].button == MOUSE_BUTTON_MIDDLE)
        #expect(spy.mouseEventCalls[0].eventType == MOUSE_PRESS)
    }

    // MARK: - Drag

    @Test("mouseDragged sends drag event with left button")
    @MainActor func mouseDrag() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }
        let cw = view.cellWidth
        let ch = view.cellHeight

        guard let event = mouseEvent(type: .leftMouseDragged,
                                     location: NSPoint(x: cw * 15, y: ch * 3)) else { return }
        view.mouseDragged(with: event)

        #expect(spy.mouseEventCalls.count == 1)
        let call = spy.mouseEventCalls[0]
        #expect(call.button == MOUSE_BUTTON_LEFT)
        #expect(call.eventType == MOUSE_DRAG)
        #expect(call.row == 3)
        #expect(call.col == 15)
    }

    // MARK: - Mouse move (deduplication)

    @Test("mouseMoved sends motion event")
    @MainActor func mouseMove() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }
        let cw = view.cellWidth
        let ch = view.cellHeight

        guard let event = mouseEvent(type: .mouseMoved,
                                     location: NSPoint(x: cw * 5, y: ch * 2)) else { return }
        view.mouseMoved(with: event)

        #expect(spy.mouseEventCalls.count == 1)
        #expect(spy.mouseEventCalls[0].button == MOUSE_BUTTON_NONE)
        #expect(spy.mouseEventCalls[0].eventType == MOUSE_MOTION)
    }

    @Test("mouseMoved deduplicates same cell position")
    @MainActor func mouseMoveDedup() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }
        let cw = view.cellWidth
        let ch = view.cellHeight

        // Two moves to the same cell: only first should send
        let pos = NSPoint(x: cw * 5 + 2, y: ch * 2 + 1)
        guard let e1 = mouseEvent(type: .mouseMoved, location: pos),
              let e2 = mouseEvent(type: .mouseMoved, location: pos) else { return }
        view.mouseMoved(with: e1)
        view.mouseMoved(with: e2)

        #expect(spy.mouseEventCalls.count == 1) // deduplicated
    }

    @Test("mouseMoved sends when cell position changes")
    @MainActor func mouseMoveDifferentCell() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }
        let cw = view.cellWidth
        let ch = view.cellHeight

        guard let e1 = mouseEvent(type: .mouseMoved, location: NSPoint(x: cw * 5, y: ch * 2)),
              let e2 = mouseEvent(type: .mouseMoved, location: NSPoint(x: cw * 6, y: ch * 2)) else { return }
        view.mouseMoved(with: e1)
        view.mouseMoved(with: e2)

        #expect(spy.mouseEventCalls.count == 2) // different cells
    }

    // MARK: - Modifier forwarding

    @Test("shift modifier is forwarded in mouse events")
    @MainActor func shiftModifier() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }

        guard let event = mouseEvent(type: .leftMouseDown,
                                     location: NSPoint(x: 0, y: 0),
                                     modifiers: .shift) else { return }
        view.mouseDown(with: event)

        #expect(spy.mouseEventCalls[0].modifiers & 0x01 != 0) // shift bit
    }

    @Test("command modifier is forwarded in mouse events")
    @MainActor func commandModifier() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }

        guard let event = mouseEvent(type: .leftMouseDown,
                                     location: NSPoint(x: 0, y: 0),
                                     modifiers: .command) else { return }
        view.mouseDown(with: event)

        #expect(spy.mouseEventCalls[0].modifiers & 0x08 != 0) // command bit
    }

    @Test("multiple modifiers are combined correctly")
    @MainActor func combinedModifiers() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }

        guard let event = mouseEvent(type: .leftMouseDown,
                                     location: NSPoint(x: 0, y: 0),
                                     modifiers: [.shift, .control, .option]) else { return }
        view.mouseDown(with: event)

        let mods = spy.mouseEventCalls[0].modifiers
        #expect(mods & 0x01 != 0) // shift
        #expect(mods & 0x02 != 0) // control
        #expect(mods & 0x04 != 0) // option
        #expect(mods & 0x08 == 0) // no command
    }
}
