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
        let guiState = GUIState()
        let disp = CommandDispatcher(cols: 80, rows: 24, guiState: guiState)
        guard let ctRenderer = CoreTextMetalRenderer() else { return nil }
        ctRenderer.setupRenderers(fontManager: fm)
        let view = EditorNSView(encoder: spy, fontFace: face, dispatcher: disp,
                                coreTextRenderer: ctRenderer, fontManager: fm)
        view.guiState = guiState
        // Give the view a real frame so cellPosition math works.
        // Without a window, convert(_:from:) returns the point unchanged,
        // so locationInWindow IS the local point.
        view.frame = NSRect(x: 0, y: 0,
                           width: CGFloat(face.cellWidth) * 80,
                           height: CGFloat(face.cellHeight) * 24)
        return view
    }

    @MainActor
    private func installPaneGeometryDivider(view: EditorNSView, dividerCol: UInt16) {
        let geometry = GUIPaneGeometry(
            windowId: 1,
            totalRect: GUICellRect(row: 0, col: 0, width: 80, height: 24),
            contentRect: GUICellRect(row: 0, col: 0, width: 80, height: 24),
            textRect: GUICellRect(row: 0, col: 0, width: 80, height: 24),
            gutterRect: GUICellRect(row: 0, col: 0, width: 0, height: 24),
            clipRect: GUICellRect(row: 0, col: 0, width: 80, height: 24),
            viewport: GUIViewportSummary(top: 0, left: 0, rows: 24, cols: 80, totalLines: 24, visualRowOffset: 0, totalVisualRows: 24),
            gutterMetrics: GUIGutterMetrics(lineNumberWidth: 0, signColWidth: 0),
            hitRegions: [
                GUIHitRegion(kind: .divider, rect: GUICellRect(row: 0, col: dividerCol, width: 0, height: 24), windowId: 1)
            ]
        )

        view.guiState?.windowContents[1] = GUIWindowContent(
            windowId: 1, fullRefresh: true,
            cursorRow: 0, cursorCol: 0, cursorShape: .block,
            rows: [], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: [],
            paneGeometry: geometry
        )
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

    @Test("mouseDown snaps vertical divider press to separator column")
    @MainActor func leftMouseDownSnapsVerticalDividerPress() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }
        let cw = view.cellWidth
        let ch = view.cellHeight

        view.dispatcher.dispatch(.guiSplitSeparators(
            borderColor: 0x555555,
            verticals: [Wire.VerticalSeparator(col: 40, startRow: 0, endRow: 23)],
            horizontals: []
        ))

        guard let event = mouseEvent(type: .leftMouseDown, location: NSPoint(x: cw * 40 - 1, y: ch * 5.5)) else { return }
        view.mouseDown(with: event)

        #expect(spy.mouseEventCalls.count == 1)
        #expect(spy.mouseEventCalls[0].row == 5)
        #expect(spy.mouseEventCalls[0].col == 40)
    }

    @Test("mouseDown outside divider pixel tolerance uses normal cell coordinates")
    @MainActor func leftMouseDownOutsideVerticalDividerToleranceDoesNotSnap() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }
        let cw = view.cellWidth
        let ch = view.cellHeight

        view.dispatcher.dispatch(.guiSplitSeparators(
            borderColor: 0x555555,
            verticals: [Wire.VerticalSeparator(col: 40, startRow: 0, endRow: 23)],
            horizontals: []
        ))

        guard let event = mouseEvent(type: .leftMouseDown, location: NSPoint(x: cw * 40 - cw * 0.75, y: ch * 5.5)) else { return }
        view.mouseDown(with: event)

        #expect(spy.mouseEventCalls.count == 1)
        #expect(spy.mouseEventCalls[0].row == 5)
        #expect(spy.mouseEventCalls[0].col == 39)
    }

    @Test("mouseDown uses paneGeometry divider tolerance without guiSplitSeparators")
    @MainActor func leftMouseDownUsesPaneGeometryDividerTolerance() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }
        let cw = view.cellWidth
        let ch = view.cellHeight
        installPaneGeometryDivider(view: view, dividerCol: 40)

        guard let leftEvent = mouseEvent(type: .leftMouseDown, location: NSPoint(x: cw * 40 - 1, y: ch * 5.5)) else { return }
        view.mouseDown(with: leftEvent)
        guard let rightEvent = mouseEvent(type: .leftMouseDown, location: NSPoint(x: cw * 40 + 1, y: ch * 6.5)) else { return }
        view.mouseDown(with: rightEvent)

        #expect(spy.mouseEventCalls.count == 2)
        #expect(spy.mouseEventCalls[0].row == 5)
        #expect(spy.mouseEventCalls[0].col == 40)
        #expect(spy.mouseEventCalls[1].row == 6)
        #expect(spy.mouseEventCalls[1].col == 40)
    }

    @Test("mouseDown maps split pane content with per-window gutter padding")
    @MainActor func leftMouseDownUsesPaneGutter() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }
        let cw = view.cellWidth
        let ch = view.cellHeight

        let clickedGutter = Wire.WindowGutter(
            windowId: 1, contentRow: 0, contentCol: 0, contentHeight: 12,
            isActive: false, contentWidth: 40, cursorLine: 3, lineNumberStyle: .hybrid,
            lineNumberWidth: 4, signColWidth: 1, entries: []
        )
        let activeWideGutter = Wire.WindowGutter(
            windowId: 2, contentRow: 0, contentCol: 41, contentHeight: 24,
            isActive: true, contentWidth: 39, cursorLine: 3, lineNumberStyle: .hybrid,
            lineNumberWidth: 8, signColWidth: 1, entries: []
        )
        view.dispatcher.dispatch(.guiGutter(data: clickedGutter))
        view.dispatcher.dispatch(.guiGutter(data: activeWideGutter))

        let firstTextColX = CoreTextMetalRenderer.gutterLeftMarginPt + CGFloat(clickedGutter.lineNumberWidth + clickedGutter.signColWidth) * cw + CoreTextMetalRenderer.gutterRightGapPt + cw * 0.2
        guard let event = mouseEvent(type: .leftMouseDown, location: NSPoint(x: firstTextColX, y: ch * 2.5)) else { return }
        view.mouseDown(with: event)

        #expect(spy.mouseEventCalls.count == 1)
        #expect(spy.mouseEventCalls[0].row == 2)
        #expect(spy.mouseEventCalls[0].col == 5)
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

    @Test("mouseDown on fold chevron sends fold toggle instead of generic mouse input")
    @MainActor func foldChevronClickUsesSpecialAction() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }
        let cw = view.cellWidth
        let ch = view.cellHeight

        let activeGutter = Wire.WindowGutter(
            windowId: 1, contentRow: 0, contentCol: 0, contentHeight: 24,
            isActive: true, contentWidth: 80, cursorLine: 11, lineNumberStyle: .hybrid,
            lineNumberWidth: 4, signColWidth: 3,
            entries: [Wire.GutterEntry(bufLine: 11, displayType: .normal, signType: .none)]
        )
        let inactiveGutter = Wire.WindowGutter(
            windowId: 7, contentRow: 0, contentCol: 20, contentHeight: 24,
            isActive: false, contentWidth: 80, cursorLine: 42, lineNumberStyle: .hybrid,
            lineNumberWidth: 4, signColWidth: 3,
            entries: [Wire.GutterEntry(bufLine: 42, displayType: .foldStart, signType: .none, foldEndLine: 50)]
        )
        view.dispatcher.dispatch(.guiGutter(data: activeGutter))
        view.dispatcher.dispatch(.guiGutter(data: inactiveGutter))

        guard let event = mouseEvent(type: .leftMouseDown,
                                     location: NSPoint(x: cw * 22.2, y: ch * 0.5)) else { return }
        view.mouseDown(with: event)

        #expect(spy.guiActions == [.foldToggleAtLine(windowId: 7, bufferLine: 42)])
        #expect(spy.mouseEventCalls.isEmpty)
    }

    @Test("mouseDown ignores stale gutter data from a previous frame")
    @MainActor func staleGutterIgnoredForHitTesting() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }
        let cw = view.cellWidth
        let ch = view.cellHeight

        view.dispatcher.frameState.windowGutters[9] = Wire.WindowGutter(
            windowId: 9, contentRow: 0, contentCol: 5, contentHeight: 24,
            isActive: true, contentWidth: 80, cursorLine: 42, lineNumberStyle: .hybrid,
            lineNumberWidth: 4, signColWidth: 3,
            entries: [Wire.GutterEntry(bufLine: 42, displayType: .foldStart, signType: .none, foldEndLine: 50)]
        )

        guard let event = mouseEvent(type: .leftMouseDown,
                                     location: NSPoint(x: cw * 7.2, y: ch * 0.5)) else { return }
        view.mouseDown(with: event)

        #expect(spy.guiActions.isEmpty)
        #expect(spy.mouseEventCalls.count == 1)
    }

    // MARK: - Mouse move (deduplication)

    @Test("smooth scroll target resets when pointer leaves target pane")
    func smoothScrollTargetResetsWhenPointerLeavesTargetPane() {
        #expect(EditorNSView.shouldResetSmoothScrollTarget(currentTargetWindowId: 1, pointerWindowId: 2, pixelOffset: 4) == true)
        #expect(EditorNSView.shouldResetSmoothScrollTarget(currentTargetWindowId: 1, pointerWindowId: nil, pixelOffset: 4) == true)
        #expect(EditorNSView.shouldResetSmoothScrollTarget(currentTargetWindowId: 1, pointerWindowId: 1, pixelOffset: 4) == false)
        #expect(EditorNSView.shouldResetSmoothScrollTarget(currentTargetWindowId: 1, pointerWindowId: 2, pixelOffset: 0) == false)
        #expect(EditorNSView.shouldResetSmoothScrollTarget(currentTargetWindowId: nil, pointerWindowId: 2, pixelOffset: 4) == false)
    }

    @Test("smooth scroll routing keeps the gesture target cell after the pointer moves")
    func smoothScrollRoutingKeepsGestureTargetCell() {
        let routedTarget = EditorNSView.smoothScrollEventCellPosition(targetCell: (row: 5, col: 12), row: 5, col: 40)
        #expect(routedTarget.row == 5)
        #expect(routedTarget.col == 12)

        let fallbackTarget = EditorNSView.smoothScrollEventCellPosition(targetCell: nil, row: 5, col: 40)
        #expect(fallbackTarget.row == 5)
        #expect(fallbackTarget.col == 40)
    }

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
