/// Tests for mouse event handling in EditorNSView.
///
/// Verifies that mouse events (click, drag, scroll, right-click, middle-click)
/// are correctly converted to protocol events with the right button, modifiers,
/// event type, click count, and cell coordinates.
///
/// Uses SpyEncoder to capture the protocol events sent by the view.
/// NSEvent.mouseEvent creates synthetic events at known pixel positions;
/// the view's cellPosition divides by cell dimensions to get grid coordinates.

import MingaUI
import Testing
import Foundation
import AppKit
import MingaProtocol

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
    private func makeWindowedView(spy: SpyEncoder) -> (view: EditorNSView, window: NSWindow, textField: NSTextField)? {
        guard let view = makeView(spy: spy) else { return nil }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: view.frame.width, height: view.frame.height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: view.frame)
        let textField = NSTextField(frame: NSRect(x: 16, y: 16, width: 160, height: 24))
        container.addSubview(view)
        container.addSubview(textField)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        return (view, window, textField)
    }

    @MainActor
    private func installPaneGeometryDivider(view: EditorNSView, dividerCol: UInt16) throws {
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

        view.guiState?.windowContents[1] = try GUIWindowContent(
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

    @Test("claimFirstResponder respects active text input")
    @MainActor func claimFirstResponderRespectsActiveTextInput() throws {
        let spy = SpyEncoder()
        guard let (view, window, textField) = makeWindowedView(spy: spy) else { return }

        #expect(window.makeFirstResponder(textField))
        #expect(window.firstResponder is NSText)

        view.reclaimFirstResponderIfNeeded(respectingTextInput: true)

        #expect(window.firstResponder is NSText)
        #expect(spy.mouseEventCalls.isEmpty)
    }

    @Test("mouseDown sends left button press and reclaims first responder")
    @MainActor func leftMouseDown() throws {
        let spy = SpyEncoder()
        guard let (view, window, textField) = makeWindowedView(spy: spy) else { return }
        let cw = view.cellWidth
        let ch = view.cellHeight

        #expect(window.makeFirstResponder(textField))
        #expect(window.firstResponder is NSText)

        // Click at pixel (cw * 10, ch * 5) = cell (row=5, col=10)
        guard let event = mouseEvent(type: .leftMouseDown,
                                     location: NSPoint(x: cw * 10, y: ch * 5)) else { return }
        view.mouseDown(with: event)

        #expect(window.firstResponder === view)
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

        view.dispatcher.applyForTesting(.guiSplitSeparators(
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

        view.dispatcher.applyForTesting(.guiSplitSeparators(
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
        try installPaneGeometryDivider(view: view, dividerCol: 40)

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
        view.dispatcher.applyForTesting(.guiGutter(data: clickedGutter))
        view.dispatcher.applyForTesting(.guiGutter(data: activeWideGutter))

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
            entries: [
                Wire.GutterEntry(bufLine: 41, displayType: .normal, signType: .none),
                Wire.GutterEntry(bufLine: 42, displayType: .foldStart, signType: .none, foldEndLine: 50)
            ]
        )
        view.dispatcher.applyForTesting(.guiGutter(data: activeGutter))
        view.dispatcher.applyForTesting(.guiGutter(data: inactiveGutter))
        view.guiState?.windowContents[7] = try GUIWindowContent(
            windowId: 7, fullRefresh: true,
            cursorRow: 0, cursorCol: 0, cursorShape: .block,
            rows: [], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: [],
            scrollPresentation: GUIScrollPresentation(
                windowId: 7, resetRequired: false, anchorTop: 42, anchorLeft: 0, anchorVisualRowOffset: 0,
                visibleStartLine: 42, visibleEndLine: 43, overscanStartLine: 41, overscanEndLine: 43,
                contentEpoch: 1, layoutGeneration: 1
            )
        )

        guard let event = mouseEvent(type: .leftMouseDown,
                                     location: NSPoint(x: cw * 22.2, y: ch * 0.5)) else { return }
        view.mouseDown(with: event)

        #expect(spy.guiActions == [.foldToggleAtLine(windowId: 7, bufferLine: 42)])
        #expect(spy.mouseEventCalls.isEmpty)
    }

    @Test("fold chevron hit testing uses payload-local overscan for wrapped rows")
    @MainActor func foldChevronHitTestingUsesPayloadLocalOverscanForWrappedRows() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }
        let cw = view.cellWidth
        let ch = view.cellHeight

        let gutter = Wire.WindowGutter(
            windowId: 7, contentRow: 0, contentCol: 0, contentHeight: 2,
            isActive: true, contentWidth: 20, cursorLine: 10, lineNumberStyle: .hybrid,
            lineNumberWidth: 4, signColWidth: 3,
            entries: [
                Wire.GutterEntry(bufLine: 10, displayType: .foldStart, signType: .none, foldEndLine: 12),
                Wire.GutterEntry(bufLine: 11, displayType: .foldStart, signType: .none, foldEndLine: 13)
            ]
        )
        let geometry = GUIPaneGeometry(
            windowId: 7,
            totalRect: GUICellRect(row: 0, col: 0, width: 20, height: 2),
            contentRect: GUICellRect(row: 0, col: 0, width: 20, height: 2),
            textRect: GUICellRect(row: 0, col: 7, width: 13, height: 2),
            gutterRect: GUICellRect(row: 0, col: 0, width: 7, height: 2),
            clipRect: GUICellRect(row: 0, col: 0, width: 20, height: 2),
            viewport: GUIViewportSummary(top: 10, left: 0, rows: 2, cols: 20, totalLines: 20, visualRowOffset: 1, totalVisualRows: 5),
            gutterMetrics: GUIGutterMetrics(lineNumberWidth: 4, signColWidth: 3),
            hitRegions: []
        )

        view.dispatcher.applyForTesting(.guiGutter(data: gutter))
        view.guiState?.windowContents[7] = try GUIWindowContent(
            windowId: 7, fullRefresh: true,
            cursorRow: 0, cursorCol: 0, cursorShape: .block,
            rows: [
                GUIVisualRow(rowType: .normal, rowId: 1, bufLine: 10, contentHash: 1, text: "first", spans: []),
                GUIVisualRow(rowType: .normal, rowId: 2, bufLine: 10, contentHash: 2, text: "second", spans: []),
                GUIVisualRow(rowType: .normal, rowId: 3, bufLine: 11, contentHash: 3, text: "third", spans: [])
            ],
            selection: nil, searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: [], paneGeometry: geometry,
            scrollPresentation: GUIScrollPresentation(
                windowId: 7, resetRequired: false, anchorTop: 10, anchorLeft: 0, anchorVisualRowOffset: 1,
                visibleStartLine: 10, visibleEndLine: 12, overscanStartLine: 10, overscanEndLine: 12,
                contentEpoch: 1, layoutGeneration: 1
            )
        )

        guard let event = mouseEvent(type: .leftMouseDown,
                                     location: NSPoint(x: cw * 6.2, y: ch * 0.5)) else { return }
        view.mouseDown(with: event)

        #expect(spy.guiActions == [.foldToggleAtLine(windowId: 7, bufferLine: 10)])
        #expect(spy.mouseEventCalls.isEmpty)
    }

    @Test("presentation scroll normalization shifts fold hit testing vertically only")
    @MainActor func presentationScrollNormalizationShiftsFoldHitTestingVerticallyOnly() {
        let normalized = EditorNSView.presentationNormalizedGutterPoint(
            NSPoint(x: 18.0, y: 3.0),
            presentation: EditorNSView.LocalScrollPresentation(windowId: 7, offset: CGPoint(x: 0, y: 8.0)),
            targetGutterRect: GUICellRect(row: 0, col: 2, width: 6, height: 4),
            cellWidth: 8.0,
            cellHeight: 8.0
        )

        #expect(normalized.x == 18.0)
        #expect(Int(normalized.y / 8.0) == 1)
        #expect(normalized.y > 3.0)
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
        #expect(EditorNSView.shouldResetSmoothScrollTarget(currentTargetWindowId: 1, pointerWindowId: 2, hasPixelOffset: true) == true)
        #expect(EditorNSView.shouldResetSmoothScrollTarget(currentTargetWindowId: 1, pointerWindowId: nil, hasPixelOffset: true) == true)
        #expect(EditorNSView.shouldResetSmoothScrollTarget(currentTargetWindowId: 1, pointerWindowId: 1, hasPixelOffset: true) == false)
        #expect(EditorNSView.shouldResetSmoothScrollTarget(currentTargetWindowId: 1, pointerWindowId: 2, hasPixelOffset: false) == false)
        #expect(EditorNSView.shouldResetSmoothScrollTarget(currentTargetWindowId: nil, pointerWindowId: 2, hasPixelOffset: true) == false)
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

    @Test("presentation scroll offset suppresses negative horizontal normalization when scrollLeft is zero")
    func presentationScrollOffsetSuppressesNegativeHorizontalNormalization() {
        let suppressed = EditorNSView.presentationScrollOffset(scrollLeft: 0, scrollOffset: CGPoint(x: -8, y: 3))
        #expect(suppressed.x == 0)
        #expect(suppressed.y == 3)

        let preserved = EditorNSView.presentationScrollOffset(scrollLeft: 2, scrollOffset: CGPoint(x: -8, y: 3))
        #expect(preserved.x == -8)
        #expect(preserved.y == 3)
    }

    @Test("elastic-only presentation offsets still count as active for pointer normalization")
    func elasticOnlyPresentationOffsetCountsAsActive() {
        #expect(EditorNSView.hasActivePresentationOffset(scrollPixelOffset: .zero, scrollElasticOffsetY: 4) == true)
        #expect(EditorNSView.hasActivePresentationOffset(scrollPixelOffset: CGPoint(x: 3, y: 0), scrollElasticOffsetY: 0) == true)
        #expect(EditorNSView.hasActivePresentationOffset(scrollPixelOffset: .zero, scrollElasticOffsetY: 0) == false)
    }

    @Test("gesture-end settle uses the presented pane and effective offset")
    func gestureEndSettleNormalizesPresentedRow() throws {
        let presentation = try #require(EditorNSView.localScrollPresentation(
            targetWindowId: nil,
            thumbDragWindowId: nil,
            settleWindowId: 7,
            elasticWindowId: nil,
            scrollPixelOffset: CGPoint(x: 0, y: 12),
            scrollElasticOffsetY: 0
        ))

        let normalized = normalizedPoint(NSPoint(x: 25, y: 25), rawPointWindowId: 7, presentation: presentation)
        #expect(presentation.windowId == 7)
        #expect(normalized.y == 37)
        #expect(Int(normalized.y / 10) == 3)
    }

    @Test("elastic rebound is included in the effective pointer offset")
    func elasticReboundNormalizesPresentedRow() throws {
        let presentation = try #require(EditorNSView.localScrollPresentation(
            targetWindowId: nil,
            thumbDragWindowId: nil,
            settleWindowId: nil,
            elasticWindowId: 7,
            scrollPixelOffset: .zero,
            scrollElasticOffsetY: 8
        ))

        let normalized = normalizedPoint(NSPoint(x: 25, y: 25), rawPointWindowId: 7, presentation: presentation)
        #expect(presentation.offset.y == 8)
        #expect(normalized.y == 33)
    }

    @Test("elastic offset contributes only to its presentation owner")
    func elasticOffsetStaysWithItsOwner() throws {
        let differentOwner = try #require(EditorNSView.localScrollPresentation(
            targetWindowId: nil,
            thumbDragWindowId: nil,
            settleWindowId: 7,
            elasticWindowId: 8,
            scrollPixelOffset: CGPoint(x: 0, y: 6),
            scrollElasticOffsetY: 9
        ))
        let sharedOwner = try #require(EditorNSView.localScrollPresentation(
            targetWindowId: nil,
            thumbDragWindowId: nil,
            settleWindowId: 7,
            elasticWindowId: 7,
            scrollPixelOffset: CGPoint(x: 0, y: 6),
            scrollElasticOffsetY: 9
        ))

        #expect(differentOwner.offset.y == 6)
        #expect(sharedOwner.offset.y == 15)
    }

    @Test("thumb-drag reconciliation uses its presented pane")
    func thumbDragReconciliationNormalizesPresentedRow() throws {
        let presentation = try #require(EditorNSView.localScrollPresentation(
            targetWindowId: nil,
            thumbDragWindowId: 7,
            settleWindowId: 8,
            elasticWindowId: 9,
            scrollPixelOffset: CGPoint(x: 0, y: -10),
            scrollElasticOffsetY: 0
        ))

        let normalized = normalizedPoint(NSPoint(x: 25, y: 35), rawPointWindowId: 7, presentation: presentation)
        #expect(presentation.windowId == 7)
        #expect(normalized.y == 25)
    }

    @Test("authoritative re-anchor removes pointer normalization")
    func authoritativeReanchorRemovesPointerTransform() {
        let presentation = EditorNSView.localScrollPresentation(
            targetWindowId: nil,
            thumbDragWindowId: nil,
            settleWindowId: nil,
            elasticWindowId: nil,
            scrollPixelOffset: CGPoint(x: 0, y: 12),
            scrollElasticOffsetY: 4
        )
        let point = NSPoint(x: 25, y: 25)

        #expect(presentation == nil)
        #expect(normalizedPoint(point, rawPointWindowId: 7, presentation: presentation) == point)
    }

    @Test("pointer normalization classifies the raw pane before translation")
    func rawPaneOwnershipPreventsCrossPaneTranslation() {
        let presentation = EditorNSView.LocalScrollPresentation(windowId: 7, offset: CGPoint(x: 0, y: 12))
        let point = NSPoint(x: 25, y: 25)

        #expect(normalizedPoint(point, rawPointWindowId: 8, presentation: presentation) == point)
    }

    @Test("pointer normalization clamps clicks at visible top and bottom boundaries")
    func boundaryClicksStayInPresentedPane() {
        let down = EditorNSView.LocalScrollPresentation(windowId: 7, offset: CGPoint(x: 0, y: 15))
        let up = EditorNSView.LocalScrollPresentation(windowId: 7, offset: CGPoint(x: 0, y: -15))
        let top = normalizedPoint(NSPoint(x: 25, y: 20.001), rawPointWindowId: 7, presentation: up)
        let bottom = normalizedPoint(NSPoint(x: 25, y: 49.999), rawPointWindowId: 7, presentation: down)

        #expect(Int(top.y / 10) == 2)
        #expect(Int(bottom.y / 10) == 4)
        #expect(top.y >= 20)
        #expect(bottom.y < 50)
    }

    private func normalizedPoint(
        _ point: NSPoint,
        rawPointWindowId: UInt16?,
        presentation: EditorNSView.LocalScrollPresentation?
    ) -> NSPoint {
        EditorNSView.presentationNormalizedPoint(
            point,
            rawPointWindowId: rawPointWindowId,
            presentation: presentation,
            targetContentRect: GUICellRect(row: 2, col: 2, width: 4, height: 3),
            scrollLeft: 0,
            cellWidth: 10,
            cellHeight: 10
        )
    }

    @Test("selection drag active only while the mouse button is down for a plain text drag (#2661)")
    func selectionDragActiveOnlyForPlainTextDrag() {
        // No mouse button down: never a drag.
        #expect(EditorNSView.isSelectionDragActive(hasMouseDownPoint: false, isDividerDragActive: false, isDraggingScrollIndicator: false) == false)

        // Plain left-mouse-down drag with no divider/scrollbar interaction: a selection drag.
        #expect(EditorNSView.isSelectionDragActive(hasMouseDownPoint: true, isDividerDragActive: false, isDraggingScrollIndicator: false) == true)

        // Pane-divider drag also holds the mouse button down but is not a selection drag.
        #expect(EditorNSView.isSelectionDragActive(hasMouseDownPoint: true, isDividerDragActive: true, isDraggingScrollIndicator: false) == false)

        // Scrollbar-thumb drag also holds the mouse button down but is not a selection drag.
        #expect(EditorNSView.isSelectionDragActive(hasMouseDownPoint: true, isDividerDragActive: false, isDraggingScrollIndicator: true) == false)
    }

    @Test("presentation-normalized points stay inside the target pane")
    func presentationNormalizedPointClampsToTargetPane() {
        let rect = GUICellRect(row: 2, col: 4, width: 10, height: 3)
        let point = EditorNSView.clampPresentationPoint(NSPoint(x: 200, y: 200), to: rect, cellWidth: 10, cellHeight: 20)
        #expect(point.x < 140)
        #expect(point.x >= 40)
        #expect(point.y < 100)
        #expect(point.y >= 40)
    }

    @Test("top boundary smooth scroll becomes bounded elastic while content stays clamped")
    func topBoundarySmoothScrollBecomesBoundedElastic() {
        let presentation = GUIScrollPresentation(
            windowId: 1,
            resetRequired: false,
            anchorTop: 10,
            anchorLeft: 0,
            anchorVisualRowOffset: 0,
            visibleStartLine: 10,
            visibleEndLine: 20,
            overscanStartLine: 10,
            overscanEndLine: 21,
            contentEpoch: 1,
            layoutGeneration: 1
        )

        let translation = EditorNSView.presentationScrollTranslation(
            scrollPresentation: presentation,
            scrollOffsetY: 8,
            scrollDeltaY: 120,
            payloadOverscanBefore: 0,
            payloadOverscanAfter: 1,
            boundaryBefore: 0,
            boundaryAfter: 1
        )

        // Pulling past the top: the caller feeds the negative pull into the rubber-band curve.
        #expect(translation == .elastic(pullDelta: -120))
    }

    @Test("bottom boundary smooth scroll becomes bounded elastic while content stays clamped")
    func bottomBoundarySmoothScrollBecomesBoundedElastic() {
        let presentation = GUIScrollPresentation(
            windowId: 1,
            resetRequired: false,
            anchorTop: 10,
            anchorLeft: 0,
            anchorVisualRowOffset: 0,
            visibleStartLine: 10,
            visibleEndLine: 20,
            overscanStartLine: 9,
            overscanEndLine: 20,
            contentEpoch: 1,
            layoutGeneration: 1
        )

        let translation = EditorNSView.presentationScrollTranslation(
            scrollPresentation: presentation,
            scrollOffsetY: 8,
            scrollDeltaY: -120,
            payloadOverscanBefore: 1,
            payloadOverscanAfter: 0,
            boundaryBefore: 1,
            boundaryAfter: 0
        )

        // Pulling past the bottom: the caller feeds the positive pull into the rubber-band curve.
        #expect(translation == .elastic(pullDelta: 120))
    }

    @Test("middle smooth scroll keeps normal content offset")
    func middleSmoothScrollKeepsNormalContentOffset() {
        let presentation = GUIScrollPresentation(
            windowId: 1,
            resetRequired: false,
            anchorTop: 10,
            anchorLeft: 0,
            anchorVisualRowOffset: 0,
            visibleStartLine: 10,
            visibleEndLine: 20,
            overscanStartLine: 9,
            overscanEndLine: 21,
            contentEpoch: 1,
            layoutGeneration: 1
        )

        let translation = EditorNSView.presentationScrollTranslation(
            scrollPresentation: presentation,
            scrollOffsetY: 8,
            scrollDeltaY: 12,
            payloadOverscanBefore: 1,
            payloadOverscanAfter: 1,
            boundaryBefore: 1,
            boundaryAfter: 1
        )

        // Renderable payload exists in the pull direction: present the content offset, no elastic.
        #expect(translation == .content(offsetY: 8))
    }

    @Test("smooth scroll clamps when document has rows but payload cannot render them")
    func smoothScrollClampsWhenPayloadCannotRenderDocumentRows() {
        let presentation = GUIScrollPresentation(
            windowId: 1,
            resetRequired: false,
            anchorTop: 10,
            anchorLeft: 0,
            anchorVisualRowOffset: 5,
            visibleStartLine: 10,
            visibleEndLine: 20,
            overscanStartLine: 10,
            overscanEndLine: 20,
            contentEpoch: 1,
            layoutGeneration: 1
        )

        let translation = EditorNSView.presentationScrollTranslation(
            scrollPresentation: presentation,
            scrollOffsetY: 8,
            scrollDeltaY: 12,
            payloadOverscanBefore: 0,
            payloadOverscanAfter: 0,
            boundaryBefore: 5,
            boundaryAfter: 7
        )

        // No renderable payload but content still exists at the boundary: clamp to grid, no elastic.
        #expect(translation == .content(offsetY: 0))
    }

    @Test("mid-document wrapped scroll with no payload rows before does not bounce at top")
    func midDocumentWrappedScrollWithoutPayloadBeforeDoesNotBounceAtTop() throws {
        let geometry = GUIPaneGeometry(
            windowId: 1,
            totalRect: GUICellRect(row: 0, col: 0, width: 10, height: 5),
            contentRect: GUICellRect(row: 0, col: 0, width: 10, height: 5),
            textRect: GUICellRect(row: 0, col: 0, width: 10, height: 2),
            gutterRect: GUICellRect(row: 0, col: 0, width: 2, height: 5),
            clipRect: GUICellRect(row: 0, col: 0, width: 10, height: 5),
            viewport: GUIViewportSummary(top: 20, left: 0, rows: 2, cols: 10, totalLines: 100, visualRowOffset: 0, totalVisualRows: 300),
            gutterMetrics: GUIGutterMetrics(lineNumberWidth: 1, signColWidth: 1),
            hitRegions: []
        )
        let presentation = GUIScrollPresentation(
            windowId: 1,
            resetRequired: false,
            anchorTop: 20,
            anchorLeft: 0,
            anchorVisualRowOffset: 0,
            visibleStartLine: 20,
            visibleEndLine: 22,
            overscanStartLine: 20,
            overscanEndLine: 22,
            contentEpoch: 1,
            layoutGeneration: 1
        )
        let content = try GUIWindowContent(
            windowId: 1, fullRefresh: true, contentEpoch: 1, cursorVisible: true, cursorRow: 0, cursorCol: 0, cursorShape: .block,
            scrollLeft: 0,
            rows: [
                GUIVisualRow(rowType: .normal, rowId: 1, bufLine: 20, contentHash: 1, text: "visible", spans: []),
                GUIVisualRow(rowType: .normal, rowId: 2, bufLine: 21, contentHash: 2, text: "visible", spans: [])
            ],
            selection: nil, searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: [], lineAnnotations: [], paneGeometry: geometry, cursorline: nil,
            scrollPresentation: presentation
        )

        let payload = EditorNSView.presentationScrollPayloadOverscanBounds(for: content, scrollPresentation: presentation)
        let boundary = EditorNSView.presentationScrollBoundaryAvailability(for: content, scrollPresentation: presentation)
        let translation = EditorNSView.presentationScrollTranslation(
            scrollPresentation: presentation,
            scrollOffsetY: 8,
            scrollDeltaY: 120,
            payloadOverscanBefore: payload.before,
            payloadOverscanAfter: payload.after,
            boundaryBefore: boundary.before,
            boundaryAfter: boundary.after
        )

        #expect(payload.before == 0)
        #expect(boundary.before == 1)
        // Content still exists above (boundary.before == 1), so no top rubber band.
        #expect(translation == .content(offsetY: 0))
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
