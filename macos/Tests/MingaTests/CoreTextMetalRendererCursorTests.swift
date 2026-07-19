/// Tests for CoreTextMetalRenderer cursor coordinate selection.

import MingaUI
import Testing
import Foundation
import QuartzCore
import MingaProtocol

@Suite("CoreTextMetalRenderer cursor geometry")
struct CoreTextMetalRendererCursorTests {
    @Test("semantic window cursor overrides legacy frameState cursor")
    func semanticCursorOverridesLegacyCursor() throws {
        let cellW: Float = 7.5
        let displayCellH: Float = 16.0
        let scale: Float = 2.0
        let gutterLeft: Float = 3.0
        let gutterPadding: Float = 5.0

        var frameState = FrameState(cols: 80, rows: 24)
        frameState.cursorRow = 20
        frameState.cursorCol = 70
        frameState.cursorShape = .block
        frameState.windowGutters[2] = Wire.WindowGutter(
            windowId: 2, contentRow: 4, contentCol: 1, contentHeight: 20,
            isActive: true, contentWidth: 80, cursorLine: 10, lineNumberStyle: .hybrid,
            lineNumberWidth: 4, signColWidth: 1, entries: []
        )

        let content = try GUIWindowContent(
            windowId: 2, fullRefresh: true,
            cursorRow: 2, cursorCol: 10, cursorShape: .beam,
            scrollLeft: 3,
            rows: [], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: []
        )

        let cursor = CoreTextMetalRenderer.resolveCursor(
            windowContents: [2: content],
            gutters: frameState.windowGutters,
            cellW: cellW,
            displayCellH: displayCellH,
            scale: scale,
            gutterLeftMarginPx: gutterLeft,
            gutterPaddingPx: gutterPadding
        )

        let contentColOffset = (Float(1 + 4 + 1) * cellW * scale) + gutterLeft + gutterPadding
        let expectedX = contentColOffset + Float(10 - 3) * cellW * scale
        let expectedY = Float(4 + 2) * displayCellH * scale

        #expect(cursor?.shape == .beam)
        #expect(cursor?.windowId == 2)
        #expect(abs((cursor?.x ?? 0) - expectedX) < 0.001)
        #expect(abs((cursor?.y ?? 0) - expectedY) < 0.001)
    }

    @Test("smooth scroll offset applies only to its target window")
    func smoothScrollOffsetAppliesOnlyToTargetWindow() {
        let offset = SIMD2<Float>(0, 7)

        #expect(CoreTextMetalRenderer.smoothScrollOffset(for: 2, targetWindowId: 2, scrollOffsetPx: offset) == offset)
        #expect(CoreTextMetalRenderer.smoothScrollOffset(for: 1, targetWindowId: 2, scrollOffsetPx: offset) == .zero)
        #expect(CoreTextMetalRenderer.smoothScrollOffset(for: 2, targetWindowId: nil, scrollOffsetPx: offset) == .zero)
        #expect(CoreTextMetalRenderer.smoothScrollOffset(for: nil, targetWindowId: 2, scrollOffsetPx: offset) == .zero)
    }

    @Test("cursorline smooth scroll offset stays disabled without an owning window id")
    func cursorlineSmoothScrollOffsetStaysDisabledWithoutOwningWindowId() {
        let offset = SIMD2<Float>(0, 7)

        #expect(CoreTextMetalRenderer.smoothScrollOffset(for: nil, targetWindowId: 1, scrollOffsetPx: offset) == .zero)
    }

    @Test("boundary availability uses BEAM document position")
    func boundaryAvailabilityUsesBeamDocumentPosition() throws {
        let geometry = GUIPaneGeometry(
            windowId: 7,
            totalRect: GUICellRect(row: 0, col: 0, width: 10, height: 5),
            contentRect: GUICellRect(row: 0, col: 0, width: 10, height: 5),
            textRect: GUICellRect(row: 0, col: 0, width: 10, height: 2),
            gutterRect: GUICellRect(row: 0, col: 0, width: 2, height: 5),
            clipRect: GUICellRect(row: 0, col: 0, width: 10, height: 5),
            viewport: GUIViewportSummary(top: 10, left: 0, rows: 2, cols: 10, totalLines: 100, visualRowOffset: 1, totalVisualRows: 5),
            gutterMetrics: GUIGutterMetrics(lineNumberWidth: 1, signColWidth: 1),
            hitRegions: []
        )
        let content = try GUIWindowContent(
            windowId: 7, fullRefresh: true, contentEpoch: 1, cursorVisible: true, cursorRow: 0, cursorCol: 0, cursorShape: .block,
            scrollLeft: 0, rows: [], selection: nil, searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: [], lineAnnotations: [], paneGeometry: geometry, cursorline: nil,
            scrollPresentation: GUIScrollPresentation(
                windowId: 7, resetRequired: false, anchorTop: 10, anchorLeft: 0, anchorVisualRowOffset: 1,
                visibleStartLine: 10, visibleEndLine: 12, overscanStartLine: 10, overscanEndLine: 12,
                contentEpoch: 1, layoutGeneration: 1
            )
        )

        let bounds = EditorNSView.presentationScrollBoundaryAvailability(for: content, scrollPresentation: content.scrollPresentation)
        #expect(bounds.before == 1)
        #expect(bounds.after == 1)
    }

    @Test("split label texture is clipped horizontally to separator bounds")
    func splitLabelTextureIsClippedHorizontallyToSeparatorBounds() {
        let clipped = CoreTextMetalRenderer.clippedHorizontalLineGPU(
            x: 80,
            y: 12,
            width: 60,
            height: 16,
            uvOrigin: SIMD2<Float>(0.20, 0.10),
            uvSize: SIMD2<Float>(0.60, 0.30),
            clipLeft: 100,
            clipRight: 130
        )

        #expect(clipped?.position.x == 100)
        #expect(clipped?.position.y == 12)
        #expect(clipped?.size.x == 30)
        #expect(clipped?.size.y == 16)
        #expect(abs((clipped?.uvOrigin.x ?? 0) - 0.40) < 0.0001)
        #expect(abs((clipped?.uvSize.x ?? 0) - 0.30) < 0.0001)
        #expect(clipped?.uvOrigin.y == 0.10)
        #expect(clipped?.uvSize.y == 0.30)
    }

    @Test("renderer row origin includes document visual row offset")
    func rendererRowOriginIncludesDocumentVisualRowOffset() throws {
        let geometry = GUIPaneGeometry(
            windowId: 7,
            totalRect: GUICellRect(row: 0, col: 0, width: 10, height: 5),
            contentRect: GUICellRect(row: 0, col: 0, width: 10, height: 5),
            textRect: GUICellRect(row: 0, col: 0, width: 10, height: 2),
            gutterRect: GUICellRect(row: 0, col: 0, width: 2, height: 5),
            clipRect: GUICellRect(row: 0, col: 0, width: 10, height: 5),
            viewport: GUIViewportSummary(top: 0, left: 0, rows: 2, cols: 10, totalLines: 5, visualRowOffset: 1, totalVisualRows: 5),
            gutterMetrics: GUIGutterMetrics(lineNumberWidth: 1, signColWidth: 1),
            hitRegions: []
        )
        let content = try GUIWindowContent(
            windowId: 7, fullRefresh: true, contentEpoch: 1, cursorVisible: true, cursorRow: 0, cursorCol: 0, cursorShape: .block,
            scrollLeft: 0,
            rows: [
                GUIVisualRow(rowType: .normal, rowId: 1, bufLine: 10, contentHash: 1, text: "first", spans: []),
                GUIVisualRow(rowType: .normal, rowId: 2, bufLine: 10, contentHash: 2, text: "second", spans: []),
                GUIVisualRow(rowType: .normal, rowId: 3, bufLine: 11, contentHash: 3, text: "third", spans: [])
            ],
            selection: nil, searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: [], lineAnnotations: [], paneGeometry: geometry, cursorline: nil,
            scrollPresentation: GUIScrollPresentation(
                windowId: 7, resetRequired: false, anchorTop: 10, anchorLeft: 0, anchorVisualRowOffset: 1,
                visibleStartLine: 10, visibleEndLine: 12, overscanStartLine: 10, overscanEndLine: 12,
                contentEpoch: 1, layoutGeneration: 1
            )
        )

        let payload = EditorNSView.presentationScrollPayloadOverscanBounds(for: content, scrollPresentation: content.scrollPresentation)
        #expect(payload.before == 1)
        #expect(payload.after == 0)
        #expect(CoreTextMetalRenderer.presentationOverscanBeforeRows(content) == 1)
    }

    @Test("payload overscan preserves line-delta rows before viewport")
    func payloadOverscanPreservesLineDeltaRowsBeforeViewport() throws {
        let content = try GUIWindowContent(
            windowId: 7, fullRefresh: true, contentEpoch: 1, cursorVisible: true, cursorRow: 0, cursorCol: 0, cursorShape: .block,
            scrollLeft: 0,
            rows: [
                GUIVisualRow(rowType: .normal, rowId: 1, bufLine: 9, contentHash: 1, text: "above", spans: []),
                GUIVisualRow(rowType: .normal, rowId: 2, bufLine: 10, contentHash: 2, text: "top", spans: []),
                GUIVisualRow(rowType: .normal, rowId: 3, bufLine: 11, contentHash: 3, text: "bottom", spans: [])
            ],
            selection: nil, searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: [], lineAnnotations: [], paneGeometry: nil, cursorline: nil,
            scrollPresentation: GUIScrollPresentation(
                windowId: 7, resetRequired: false, anchorTop: 10, anchorLeft: 0, anchorVisualRowOffset: 0,
                visibleStartLine: 10, visibleEndLine: 12, overscanStartLine: 9, overscanEndLine: 12,
                contentEpoch: 1, layoutGeneration: 1
            )
        )

        let payload = EditorNSView.presentationScrollPayloadOverscanBounds(for: content, scrollPresentation: content.scrollPresentation)
        #expect(payload.before == 1)
        #expect(CoreTextMetalRenderer.presentationOverscanBeforeRows(content) == 1)
    }

    @Test("payload overscan counts wrapped visual rows before viewport")
    func payloadOverscanCountsWrappedVisualRowsBeforeViewport() throws {
        let content = try GUIWindowContent(
            windowId: 7, fullRefresh: true, contentEpoch: 1, cursorVisible: true, cursorRow: 0, cursorCol: 0, cursorShape: .block,
            scrollLeft: 0,
            rows: [
                GUIVisualRow(rowType: .normal, rowId: 1, bufLine: 9, contentHash: 1, text: "above first wrap", spans: []),
                GUIVisualRow(rowType: .wrapContinuation, rowId: 2, bufLine: 9, contentHash: 2, text: "above second wrap", spans: []),
                GUIVisualRow(rowType: .normal, rowId: 3, bufLine: 10, contentHash: 3, text: "visible", spans: []),
                GUIVisualRow(rowType: .normal, rowId: 4, bufLine: 11, contentHash: 4, text: "below", spans: [])
            ],
            selection: nil, searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: [], lineAnnotations: [], paneGeometry: nil, cursorline: nil,
            scrollPresentation: GUIScrollPresentation(
                windowId: 7, resetRequired: false, anchorTop: 10, anchorLeft: 0, anchorVisualRowOffset: 0,
                visibleStartLine: 10, visibleEndLine: 12, overscanStartLine: 9, overscanEndLine: 12,
                contentEpoch: 1, layoutGeneration: 1
            )
        )

        let payload = EditorNSView.presentationScrollPayloadOverscanBounds(for: content, scrollPresentation: content.scrollPresentation)
        #expect(payload.before == 2)
        #expect(CoreTextMetalRenderer.presentationOverscanBeforeRows(content) == 2)
    }

    @Test("right split gutter separator uses per-window screen coordinates")
    func rightSplitGutterSeparatorUsesPerWindowScreenCoordinates() {
        var frameState = FrameState(cols: 100, rows: 40)
        frameState.gutterSeparatorColor = 0x334455
        frameState.windowGutters[2] = Wire.WindowGutter(
            windowId: 2, contentRow: 3, contentCol: 40, contentHeight: 10,
            isActive: true, contentWidth: 40, cursorLine: 0, lineNumberStyle: .hybrid,
            lineNumberWidth: 4, signColWidth: 1, entries: []
        )

        let rects = CoreTextMetalRenderer.gutterChromeRects(
            frameState: frameState,
            gutters: frameState.windowGutters,
            cellW: 8,
            cellH: 16,
            scale: 2,
            gutterLeftMarginPx: 12,
            gutterPaddingPx: 16,
            viewportHeight: 300
        )

        #expect(rects.leftFills.count == 1)
        #expect(rects.leftFills[0].x == 640)
        #expect(rects.leftFills[0].y == 96)
        #expect(rects.leftFills[0].height == 204)
        #expect(rects.rightFills.count == 1)
        #expect(rects.rightFills[0].x == 732)
        #expect(rects.rightFills[0].height == 204)
        #expect(rects.separators.count == 1)
        #expect(rects.separators[0].x == 740)
        #expect(rects.separators[0].y == 96)
        #expect(rects.separators[0].height == 204)
    }

    @Test("split panes use per-window text width for semantic clipping")
    func splitPanesUsePerWindowTextWidthForSemanticClipping() {
        let gutter = Wire.WindowGutter(
            windowId: 1, contentRow: 0, contentCol: 0, contentHeight: 20,
            isActive: true, contentWidth: 40, cursorLine: 3, lineNumberStyle: .hybrid,
            lineNumberWidth: 4, signColWidth: 1, entries: []
        )

        #expect(CoreTextMetalRenderer.visibleTextCols(
            geometry: nil,
            gutter: gutter,
            frameCols: 100,
            cellW: 8,
            scale: 2,
            gutterLeftMarginPx: 0,
            gutterPaddingPx: 0
        ) == 35)
    }

    @Test("cursorline is clipped to the active split pane")
    func cursorlineIsClippedToActiveSplitPane() {
        let gutters: [UInt16: Wire.WindowGutter] = [
            1: Wire.WindowGutter(
                windowId: 1, contentRow: 0, contentCol: 0, contentHeight: 20,
                isActive: true, contentWidth: 40, cursorLine: 3, lineNumberStyle: .hybrid,
                lineNumberWidth: 4, signColWidth: 1, entries: []
            ),
            2: Wire.WindowGutter(
                windowId: 2, contentRow: 0, contentCol: 41, contentHeight: 20,
                isActive: false, contentWidth: 39, cursorLine: 3, lineNumberStyle: .hybrid,
                lineNumberWidth: 4, signColWidth: 1, entries: []
            )
        ]

        let bounds = CoreTextMetalRenderer.cursorlineHorizontalBounds(
            row: 5,
            gutters: gutters,
            frameCols: 80,
            cellW: 8,
            scale: 2,
            viewportWidth: 1_600
        )

        #expect(bounds.x == 0)
        #expect(bounds.width == 640)
    }

    @Test("committed visible rows prefer the pane geometry height")
    func committedVisibleRowsPreferPaneGeometryHeight() {
        let geometry = GUIPaneGeometry(
            windowId: 1,
            totalRect: GUICellRect(row: 2, col: 4, width: 10, height: 14),
            contentRect: GUICellRect(row: 2, col: 4, width: 10, height: 14),
            textRect: GUICellRect(row: 3, col: 6, width: 8, height: 9),
            gutterRect: GUICellRect(row: 2, col: 4, width: 2, height: 14),
            clipRect: GUICellRect(row: 2, col: 4, width: 10, height: 14),
            viewport: GUIViewportSummary(top: 10, left: 0, rows: 9, cols: 80, totalLines: 100, visualRowOffset: 0, totalVisualRows: 100),
            gutterMetrics: GUIGutterMetrics(lineNumberWidth: 4, signColWidth: 1),
            hitRegions: []
        )
        let gutter = Wire.WindowGutter(
            windowId: 1, contentRow: 2, contentCol: 4, contentHeight: 14,
            isActive: true, contentWidth: 80, cursorLine: 3, lineNumberStyle: .hybrid,
            lineNumberWidth: 4, signColWidth: 1, entries: []
        )

        #expect(CoreTextMetalRenderer.committedVisibleRows(paneGeometry: geometry, gutter: gutter, fallback: 99) == 9)
    }

    @Test("pane vertical bounds use the pane text rect")
    func paneVerticalBoundsUsePaneTextRect() throws {
        let geometry = GUIPaneGeometry(
            windowId: 1,
            totalRect: GUICellRect(row: 2, col: 4, width: 10, height: 14),
            contentRect: GUICellRect(row: 2, col: 4, width: 10, height: 14),
            textRect: GUICellRect(row: 3, col: 6, width: 8, height: 9),
            gutterRect: GUICellRect(row: 2, col: 4, width: 2, height: 14),
            clipRect: GUICellRect(row: 2, col: 4, width: 10, height: 14),
            viewport: GUIViewportSummary(top: 10, left: 0, rows: 9, cols: 80, totalLines: 100, visualRowOffset: 0, totalVisualRows: 100),
            gutterMetrics: GUIGutterMetrics(lineNumberWidth: 4, signColWidth: 1),
            hitRegions: []
        )
        let content = try GUIWindowContent(
            windowId: 1,
            fullRefresh: true,
            cursorRow: 0,
            cursorCol: 0,
            cursorShape: .block,
            rows: [],
            selection: nil,
            searchMatches: [],
            diagnosticUnderlines: [],
            documentHighlights: [],
            paneGeometry: geometry
        )
        let gutter = Wire.WindowGutter(
            windowId: 1, contentRow: 2, contentCol: 4, contentHeight: 14,
            isActive: true, contentWidth: 80, cursorLine: 3, lineNumberStyle: .hybrid,
            lineNumberWidth: 4, signColWidth: 1, entries: []
        )

        let bounds = CoreTextMetalRenderer.paneVerticalBounds(
            for: 1,
            windowContents: [1: content],
            gutters: [1: gutter],
            displayCellH: 16,
            scale: 2,
            viewportHeight: 1_000
        )

        #expect(bounds?.top == 96)
        #expect(bounds?.bottom == 384)
    }

    // MARK: - Editor background remainder fill (#2687)

    @Test("background fill absorbs the effective-rows remainder at 1.2 spacing")
    func backgroundFillAbsorbsEffectiveRowsRemainder() {
        // rawRows 21 at 1.2 spacing -> floor(21/1.2) = 17 effective rows.
        // Cell height 10pt raw -> 12pt spaced. View height = 21 raw cells = 210px.
        // The 17 spaced rows only reach 17 * 12 = 204px, leaving a 6px band that
        // the fill must absorb by extending the bottom-most pane to 210px.
        let fill = CoreTextMetalRenderer.windowBackgroundFillBounds(
            paneTopRow: 0,
            paneRows: 17,
            totalRows: 17,
            displayCellH: 12,
            scale: 1,
            viewportHeight: 210
        )

        #expect(fill?.top == 0)
        #expect(fill?.bottom == 210)
        // The remainder below the last spaced row is painted, not exposed.
        #expect((fill?.bottom ?? 0) > 17 * 12)
    }

    @Test("background fill matches the view height at 1.0 spacing baseline")
    func backgroundFillIdentityAtUnitSpacing() {
        // At 1.0 spacing 21 rows * 10px = 210px exactly equals the view height.
        let fill = CoreTextMetalRenderer.windowBackgroundFillBounds(
            paneTopRow: 0,
            paneRows: 21,
            totalRows: 21,
            displayCellH: 10,
            scale: 1,
            viewportHeight: 210
        )

        #expect(fill?.top == 0)
        #expect(fill?.bottom == 210)
    }

    @Test("background fill absorbs the raw-cell remainder")
    func backgroundFillAbsorbsRawCellRemainder() {
        // View height 215px is not a multiple of the 10px cell height: floor gives
        // 21 rows reaching 210px, leaving a 5px raw-cell remainder the fill covers.
        let fill = CoreTextMetalRenderer.windowBackgroundFillBounds(
            paneTopRow: 0,
            paneRows: 21,
            totalRows: 21,
            displayCellH: 10,
            scale: 1,
            viewportHeight: 215
        )

        #expect(fill?.bottom == 215)
        #expect((fill?.bottom ?? 0) > 21 * 10)
    }

    @Test("interior split pane stops at its neighbor instead of the view bottom")
    func backgroundFillInteriorPaneStopsAtNeighbor() {
        // Stacked split: top pane rows 0..<10, bottom pane rows 10..<17 of a
        // 17-row grid. displayCellH 12, view height 210.
        let top = CoreTextMetalRenderer.windowBackgroundFillBounds(
            paneTopRow: 0,
            paneRows: 10,
            totalRows: 17,
            displayCellH: 12,
            scale: 1,
            viewportHeight: 210
        )
        // The top pane ends at the separator (10 * 12 = 120), never the view bottom.
        #expect(top?.top == 0)
        #expect(top?.bottom == 120)

        let bottom = CoreTextMetalRenderer.windowBackgroundFillBounds(
            paneTopRow: 10,
            paneRows: 7,
            totalRows: 17,
            displayCellH: 12,
            scale: 1,
            viewportHeight: 210
        )
        // The bottom pane absorbs the remainder down to the view bottom, so the
        // two fills tile the full height with no gap above the separator.
        #expect(bottom?.top == 120)
        #expect(bottom?.bottom == 210)
    }

    @Test("background fill applies the backing scale to the pane top")
    func backgroundFillAppliesScale() {
        // Retina: paneTopRow 10 at 12pt spaced height, scale 2 -> top = 240px.
        let fill = CoreTextMetalRenderer.windowBackgroundFillBounds(
            paneTopRow: 10,
            paneRows: 7,
            totalRows: 17,
            displayCellH: 12,
            scale: 2,
            viewportHeight: 500
        )

        #expect(fill?.top == 240)
        #expect(fill?.bottom == 500)
    }

    @Test("presentation scroll offset keeps negative x clamped when horizontal scroll is at zero")
    func presentationScrollOffsetKeepsNegativeXClampedAtLeftEdge() {
        let suppressed = CoreTextMetalRenderer.presentationScrollOffset(scrollLeft: 0, scrollOffsetPx: SIMD2<Float>(-12, 5))
        #expect(suppressed.x == 0)
        #expect(suppressed.y == 5)

        let preserved = CoreTextMetalRenderer.presentationScrollOffset(scrollLeft: 3, scrollOffsetPx: SIMD2<Float>(-12, 5))
        #expect(preserved.x == -12)
        #expect(preserved.y == 5)
    }

    @Test("horizontal rect clipping trims to pane text bounds")
    func horizontalRectClippingTrimsToPaneTextBounds() {
        let clipped = CoreTextMetalRenderer.clipHorizontalRect(x: 120, width: 40, left: 128, right: 160)
        #expect(clipped?.x == 128)
        #expect(clipped?.width == 32)
        #expect(CoreTextMetalRenderer.clipHorizontalRect(x: 0, width: 10, left: 20, right: 30) == nil)
    }

    @Test("cursor horizontal bounds start at semantic text rect")
    func cursorHorizontalBoundsStartAtSemanticTextRect() {
        let geometry = GUIPaneGeometry(
            windowId: 1,
            totalRect: GUICellRect(row: 0, col: 4, width: 20, height: 10),
            contentRect: GUICellRect(row: 0, col: 4, width: 20, height: 10),
            textRect: GUICellRect(row: 0, col: 8, width: 16, height: 10),
            gutterRect: GUICellRect(row: 0, col: 4, width: 4, height: 10),
            clipRect: GUICellRect(row: 0, col: 4, width: 20, height: 10),
            viewport: GUIViewportSummary(top: 0, left: 0, rows: 10, cols: 80, totalLines: 100, visualRowOffset: 0, totalVisualRows: 100),
            gutterMetrics: GUIGutterMetrics(lineNumberWidth: 3, signColWidth: 1),
            hitRegions: []
        )
        let gutter = Wire.WindowGutter(
            windowId: 1, contentRow: 0, contentCol: 4, contentHeight: 10,
            isActive: true, contentWidth: 20, cursorLine: 0, lineNumberStyle: .hybrid,
            lineNumberWidth: 3, signColWidth: 1, entries: []
        )

        let bounds = CoreTextMetalRenderer.cursorHorizontalBounds(
            geometry: geometry,
            gutter: gutter,
            frameCols: 80,
            cellW: 8,
            scale: 2,
            gutterLeftMarginPx: 3,
            gutterPaddingPx: 5,
            viewportWidth: 1_600
        )

        #expect(bounds.x == 136)
        #expect(bounds.width == 248)
    }

    @Test("smooth scroll target requires content column even for one row match")
    func smoothScrollTargetRequiresContentColumnForSingleRowMatch() {
        let gutters: [UInt16: Wire.WindowGutter] = [
            1: Wire.WindowGutter(
                windowId: 1, contentRow: 0, contentCol: 10, contentHeight: 20,
                isActive: true, contentWidth: 30, cursorLine: 3, lineNumberStyle: .hybrid,
                lineNumberWidth: 4, signColWidth: 1, entries: []
            )
        ]

        #expect(EditorNSView.smoothScrollTargetWindowId(row: 5, col: 9, windowGutters: gutters) == nil)
        #expect(EditorNSView.smoothScrollTargetWindowId(row: 5, col: 10, windowGutters: gutters) == 1)
        #expect(EditorNSView.smoothScrollTargetWindowId(row: 5, col: 40, windowGutters: gutters) == nil)
    }

    @Test("smooth scroll target chooses rightmost content hit for split panes")
    func smoothScrollTargetChoosesRightmostContentHitForSplitPanes() {
        let gutters: [UInt16: Wire.WindowGutter] = [
            1: Wire.WindowGutter(
                windowId: 1, contentRow: 0, contentCol: 0, contentHeight: 20,
                isActive: false, contentWidth: 40, cursorLine: 3, lineNumberStyle: .hybrid,
                lineNumberWidth: 4, signColWidth: 1, entries: []
            ),
            2: Wire.WindowGutter(
                windowId: 2, contentRow: 0, contentCol: 40, contentHeight: 20,
                isActive: true, contentWidth: 40, cursorLine: 3, lineNumberStyle: .hybrid,
                lineNumberWidth: 4, signColWidth: 1, entries: []
            )
        ]

        #expect(EditorNSView.smoothScrollTargetWindowId(row: 5, col: 39, windowGutters: gutters) == 1)
        #expect(EditorNSView.smoothScrollTargetWindowId(row: 5, col: 40, windowGutters: gutters) == 2)
        #expect(EditorNSView.smoothScrollTargetWindowId(row: -1, col: 40, windowGutters: gutters) == nil)
    }

    @Test("semantic block cursor at end of line renders over final character")
    func semanticBlockCursorAtEndOfLineUsesFinalCharacterCell() throws {
        let content = try GUIWindowContent(
            windowId: 1, fullRefresh: true,
            cursorRow: 0, cursorCol: 4, cursorShape: .block,
            rows: [GUIVisualRow(rowType: .normal, rowId: 1, bufLine: 0, contentHash: 1, text: "this", spans: [])],
            selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: []
        )

        #expect(CoreTextMetalRenderer.resolvedSemanticCursorCol(content) == 3)
    }

    @Test("semantic beam cursor at end of line keeps insertion point column")
    func semanticBeamCursorAtEndOfLineKeepsInsertionPointColumn() throws {
        let content = try GUIWindowContent(
            windowId: 1, fullRefresh: true,
            cursorRow: 0, cursorCol: 4, cursorShape: .beam,
            rows: [GUIVisualRow(rowType: .normal, rowId: 1, bufLine: 0, contentHash: 1, text: "this", spans: [])],
            selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: []
        )

        #expect(CoreTextMetalRenderer.resolvedSemanticCursorCol(content) == 4)
    }

    @Test("semantic block cursor uses display width for wide characters")
    func semanticBlockCursorUsesDisplayWidthForWideCharacters() throws {
        let content = try GUIWindowContent(
            windowId: 1, fullRefresh: true,
            cursorRow: 0, cursorCol: 2, cursorShape: .block,
            rows: [GUIVisualRow(rowType: .normal, rowId: 1, bufLine: 0, contentHash: 1, text: "界", spans: [])],
            selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: []
        )

        #expect(CoreTextMetalRenderer.resolvedSemanticCursorCol(content) == 1)
    }

    @Test("semantic block cursor accounts for overscan rows before the viewport")
    func semanticBlockCursorAccountsForOverscanRowsBeforeTheViewport() throws {
        let content = try GUIWindowContent(
            windowId: 1, fullRefresh: true,
            cursorRow: 0, cursorCol: 4, cursorShape: .block,
            rows: [
                GUIVisualRow(rowType: .normal, rowId: 1, bufLine: 9, contentHash: 1, text: "above", spans: []),
                GUIVisualRow(rowType: .normal, rowId: 2, bufLine: 10, contentHash: 2, text: "this", spans: [])
            ],
            selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: [],
            scrollPresentation: GUIScrollPresentation(windowId: 1, resetRequired: false, anchorTop: 10, anchorLeft: 0, anchorVisualRowOffset: 0, visibleStartLine: 10, visibleEndLine: 11, overscanStartLine: 9, overscanEndLine: 11, contentEpoch: 1, layoutGeneration: 1)
        )

        #expect(CoreTextMetalRenderer.resolvedSemanticCursorCol(content) == 3)
    }

    @Test("wrapped block cursor uses anchored visual-row width at end of line")
    func wrappedBlockCursorUsesAnchoredVisualRowWidth() throws {
        let content = try GUIWindowContent(
            windowId: 1, fullRefresh: true, contentEpoch: 1,
            cursorRow: 0, cursorCol: 4, cursorShape: .block,
            rows: [
                GUIVisualRow(rowType: .normal, rowId: 1, bufLine: 10, contentHash: 1,
                             text: "longtext", spans: []),
                GUIVisualRow(rowType: .wrapContinuation, rowId: 2, bufLine: 10, contentHash: 2,
                             text: "x", spans: [])
            ],
            selection: nil, searchMatches: [], diagnosticUnderlines: [], documentHighlights: [],
            scrollPresentation: GUIScrollPresentation(
                windowId: 1, resetRequired: false, anchorTop: 10, anchorLeft: 0,
                anchorVisualRowOffset: 1, visibleStartLine: 10, visibleEndLine: 11,
                overscanStartLine: 10, overscanEndLine: 11, contentEpoch: 1,
                layoutGeneration: 1
            )
        )

        #expect(CoreTextMetalRenderer.resolvedSemanticCursorCol(content) == 0)
    }

    @Test("vertical clipping helper preserves partial quads and drops fully hidden ones")
    func verticalClippingHelperPreservesPartialQuadsAndDropsFullyHiddenOnes() {
        let clipped = CoreTextMetalRenderer.clipVerticalQuad(y: 8, height: 12, top: 10, bottom: 20)
        #expect(clipped?.y == 10)
        #expect(clipped?.height == 10)

        #expect(CoreTextMetalRenderer.clipVerticalQuad(y: 0, height: 5, top: 10, bottom: 20) == nil)
    }

    @Test("legacy frameState cursor is not used when semantic content is unavailable")
    func legacyCursorFallback() {
        var frameState = FrameState(cols: 80, rows: 24)
        frameState.cursorRow = 3
        frameState.cursorCol = 10
        frameState.cursorShape = .underline
        frameState.gutterCol = 5

        let cursor = CoreTextMetalRenderer.resolveCursor(
            windowContents: [:],
            gutters: [:],
            cellW: 7.5,
            displayCellH: 16,
            scale: 2,
            gutterLeftMarginPx: 3,
            gutterPaddingPx: 5
        )

        #expect(cursor == nil)
    }

    @Test("semantic cursor row Y uses spaced cell height at line spacing 1.2")
    func cursorRowYUsesSpacedCellHeightAtSpacing1_2() throws {
        let cellW: Float = 7.5
        let baseCellH: Float = 16.0
        let lineSpacing: Float = 1.2
        let displayCellH = baseCellH * lineSpacing
        let scale: Float = 2.0

        var frameState = FrameState(cols: 80, rows: 24)
        frameState.lineSpacing = lineSpacing
        frameState.windowGutters[1] = Wire.WindowGutter(
            windowId: 1, contentRow: 0, contentCol: 0, contentHeight: 20,
            isActive: true, contentWidth: 80, cursorLine: 10, lineNumberStyle: .none,
            lineNumberWidth: 0, signColWidth: 0, entries: []
        )
        let content = try GUIWindowContent(
            windowId: 1, fullRefresh: true,
            cursorRow: 10, cursorCol: 4, cursorShape: .block,
            rows: [], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: []
        )

        let cursor = CoreTextMetalRenderer.resolveCursor(
            windowContents: [1: content],
            gutters: frameState.windowGutters,
            cellW: cellW,
            displayCellH: displayCellH,
            scale: scale,
            gutterLeftMarginPx: 0,
            gutterPaddingPx: 0
        )

        let spacedY = Float(10) * displayCellH * scale
        let unspacedY = Float(10) * baseCellH * scale
        #expect(abs((cursor?.y ?? 0) - spacedY) < 0.001)
        #expect(abs((cursor?.y ?? 0) - unspacedY) > 0.001)
    }

    @Test("semantic cursor row Y at line spacing 1.0 matches the unspaced baseline")
    func cursorRowYAtSpacing1_0MatchesUnspacedBaseline() throws {
        let cellW: Float = 7.5
        let baseCellH: Float = 16.0
        let lineSpacing: Float = 1.0
        let displayCellH = baseCellH * lineSpacing
        let scale: Float = 2.0

        var frameState = FrameState(cols: 80, rows: 24)
        frameState.lineSpacing = lineSpacing
        frameState.windowGutters[1] = Wire.WindowGutter(
            windowId: 1, contentRow: 0, contentCol: 0, contentHeight: 20,
            isActive: true, contentWidth: 80, cursorLine: 10, lineNumberStyle: .none,
            lineNumberWidth: 0, signColWidth: 0, entries: []
        )
        let content = try GUIWindowContent(
            windowId: 1, fullRefresh: true,
            cursorRow: 10, cursorCol: 4, cursorShape: .block,
            rows: [], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: []
        )

        let cursor = CoreTextMetalRenderer.resolveCursor(
            windowContents: [1: content],
            gutters: frameState.windowGutters,
            cellW: cellW,
            displayCellH: displayCellH,
            scale: scale,
            gutterLeftMarginPx: 0,
            gutterPaddingPx: 0
        )

        let expectedY = Float(10) * baseCellH * scale
        #expect(abs((cursor?.y ?? 0) - expectedY) < 0.001)
    }

    @Test("semantic window rows land on spaced positions at line spacing 1.2")
    func semanticWindowRowsLandOnSpacedPositionsAtSpacing1_2() throws {
        // The semantic content path positions each row at rowIndex * displayCellH.
        // resolveCursor shares that formula through the window's contentRow +
        // cursorRow, so a spaced computation must place the cursor's row on the
        // spaced grid rather than compacting rows into the unspaced top band.
        let cellW: Float = 8.0
        let baseCellH: Float = 16.0
        let lineSpacing: Float = 1.2
        let displayCellH = baseCellH * lineSpacing
        let scale: Float = 2.0

        var frameState = FrameState(cols: 80, rows: 24)
        frameState.lineSpacing = lineSpacing
        frameState.cursorRow = 0
        frameState.cursorCol = 0
        frameState.cursorShape = .block
        frameState.windowGutters[1] = Wire.WindowGutter(
            windowId: 1, contentRow: 0, contentCol: 0, contentHeight: 20,
            isActive: true, contentWidth: 80, cursorLine: 5, lineNumberStyle: .none,
            lineNumberWidth: 0, signColWidth: 0, entries: []
        )

        // Cursor is on the 6th visible row of the window content.
        let content = try GUIWindowContent(
            windowId: 1, fullRefresh: true,
            cursorRow: 5, cursorCol: 0, cursorShape: .block,
            rows: [], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: []
        )

        let cursor = CoreTextMetalRenderer.resolveCursor(
            windowContents: [1: content],
            gutters: frameState.windowGutters,
            cellW: cellW,
            displayCellH: displayCellH,
            scale: scale,
            gutterLeftMarginPx: 0,
            gutterPaddingPx: 0
        )

        let expectedY = Float(0 + 5) * displayCellH * scale
        #expect(cursor?.windowId == 1)
        #expect(abs((cursor?.y ?? 0) - expectedY) < 0.001)
    }

    @Test("cursor animation progress clamps to timeline bounds")
    func cursorAnimationProgressClamps() {
        #expect(CoreTextMetalRenderer.cursorAnimationProgress(now: 0.0, startTime: 1.0, duration: 0.035) == 0.0)
        #expect(abs(CoreTextMetalRenderer.cursorAnimationProgress(now: 1.0175, startTime: 1.0, duration: 0.035) - 0.5) < 0.001)
        #expect(CoreTextMetalRenderer.cursorAnimationProgress(now: 1.2, startTime: 1.0, duration: 0.035) == 1.0)
    }

    @Test("cursor animation uses linear interpolation")
    func cursorAnimationUsesLinearInterpolation() {
        let start = RenderCursor(x: 0, y: 0, shape: .block)
        let target = RenderCursor(x: 100, y: 40, shape: .beam)

        let atStart = CoreTextMetalRenderer.interpolateCursor(start: start, target: target, progress: 0)
        let halfway = CoreTextMetalRenderer.interpolateCursor(start: start, target: target, progress: 0.5)
        let atEnd = CoreTextMetalRenderer.interpolateCursor(start: start, target: target, progress: 1)

        #expect(atStart == RenderCursor(x: 0, y: 0, shape: .beam))
        #expect(abs(halfway.x - 50.0) < 0.001)
        #expect(abs(halfway.y - 20.0) < 0.001)
        #expect(atEnd == target)
    }

    @Test("first cursor render snaps without animating from origin")
    @MainActor func firstCursorRenderSnapsWithoutAnimatingFromOrigin() {
        guard let renderer = CoreTextMetalRenderer() else { return }
        let first = RenderCursor(x: 120, y: 64, shape: .beam)

        let rendered = renderer.animatedCursor(for: first, teleportLineThresholdPx: 1_000)

        #expect(rendered == first)
        #expect(renderer.cursorAnimating == false)
        #expect(renderer.cursorAnimationGeneration == 0)
    }

    @Test("small cursor move starts and completes animation")
    @MainActor func smallCursorMoveStartsAndCompletesAnimation() {
        guard let renderer = CoreTextMetalRenderer() else { return }
        let start = RenderCursor(x: 10, y: 10, shape: .block)
        let target = RenderCursor(x: 20, y: 20, shape: .beam)

        _ = renderer.animatedCursor(for: start, teleportLineThresholdPx: 1_000)
        let firstAnimatedFrame = renderer.animatedCursor(for: target, teleportLineThresholdPx: 1_000)

        #expect(firstAnimatedFrame?.shape == .beam)
        #expect(renderer.cursorAnimating == true)
        #expect(renderer.cursorAnimationGeneration == 1)

        let completed = renderer.updateCursorAnimation(now: CACurrentMediaTime() + 1.0)

        #expect(completed == target)
        #expect(renderer.cursorAnimating == false)
    }

    @Test("disabled cursor animation snaps to new target")
    @MainActor func disabledCursorAnimationSnapsToNewTarget() {
        guard let renderer = CoreTextMetalRenderer() else { return }
        let start = RenderCursor(x: 10, y: 10, shape: .block)
        let target = RenderCursor(x: 20, y: 20, shape: .beam)

        _ = renderer.animatedCursor(for: start, teleportLineThresholdPx: 1_000)
        renderer.setCursorAnimateConfigEnabled(false)
        let rendered = renderer.animatedCursor(for: target, teleportLineThresholdPx: 1_000)

        #expect(rendered == target)
        #expect(renderer.cursorAnimateEnabled == false)
        #expect(renderer.cursorAnimating == false)
        #expect(renderer.updateCursorAnimation() == target)
    }

    @Test("Reduce Motion override snaps even when config enables animation")
    @MainActor func reduceMotionOverrideSnapsWhenConfigEnablesAnimation() {
        guard let renderer = CoreTextMetalRenderer() else { return }
        let start = RenderCursor(x: 10, y: 10, shape: .block)
        let target = RenderCursor(x: 20, y: 20, shape: .beam)

        renderer.setCursorAnimateConfigEnabled(true)
        _ = renderer.animatedCursor(for: start, teleportLineThresholdPx: 1_000)
        renderer.setCursorAnimationReduceMotionDisabled(true)
        let rendered = renderer.animatedCursor(for: target, teleportLineThresholdPx: 1_000)

        #expect(rendered == target)
        #expect(renderer.cursorAnimateEnabled == false)
        #expect(renderer.cursorAnimating == false)
        #expect(renderer.updateCursorAnimation() == target)
    }

    @Test("large vertical cursor jumps teleport instead of animating")
    @MainActor func largeVerticalCursorJumpsTeleport() {
        guard let renderer = CoreTextMetalRenderer() else { return }
        let start = RenderCursor(x: 10, y: 10, shape: .block)
        let farTarget = RenderCursor(x: 10, y: 2_000, shape: .block)

        _ = renderer.animatedCursor(for: start, teleportLineThresholdPx: 100)
        let rendered = renderer.animatedCursor(for: farTarget, teleportLineThresholdPx: 100)

        #expect(rendered == farTarget)
        #expect(renderer.cursorAnimating == false)
        #expect(renderer.cursorAnimationGeneration == 0)
    }

    @Test("hidden active semantic cursor is skipped so visible prompt cursor wins")
    func hiddenActiveSemanticCursorIsSkippedSoPromptWins() throws {
        var frameState = FrameState(cols: 80, rows: 24)
        frameState.windowGutters[1] = Wire.WindowGutter(
            windowId: 1, contentRow: 0, contentCol: 0, contentHeight: 20,
            isActive: true, contentWidth: 80, cursorLine: 1, lineNumberStyle: .none,
            lineNumberWidth: 0, signColWidth: 0, entries: []
        )
        frameState.windowGutters[65_534] = Wire.WindowGutter(
            windowId: 65_534, contentRow: 21, contentCol: 2, contentHeight: 2,
            isActive: true, contentWidth: 40, cursorLine: 0, lineNumberStyle: .none,
            lineNumberWidth: 0, signColWidth: 0, entries: []
        )

        let hiddenChat = try GUIWindowContent(
            windowId: 1, fullRefresh: true, cursorVisible: false,
            cursorRow: 0, cursorCol: 0, cursorShape: .block,
            rows: [], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: []
        )
        let visiblePrompt = try GUIWindowContent(
            windowId: 65_534, fullRefresh: true, cursorVisible: true,
            cursorRow: 0, cursorCol: 3, cursorShape: .beam,
            rows: [], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: []
        )

        let cursor = CoreTextMetalRenderer.resolveCursor(
            windowContents: [1: hiddenChat, 65_534: visiblePrompt],
            gutters: frameState.windowGutters,
            cellW: 8,
            displayCellH: 16,
            scale: 1,
            gutterLeftMarginPx: 0,
            gutterPaddingPx: 0
        )

        #expect(cursor?.windowId == 65_534)
        #expect(cursor?.shape == .beam)
        #expect(cursor?.x == 40)
        #expect(cursor?.y == 336)
    }

    @Test("hidden semantic cursor suppresses legacy fallback after dispatcher sync")
    @MainActor func hiddenSemanticCursorSuppressesFallback() throws {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 80, rows: 24, guiState: gui)
        dispatcher.frameState.cursorRow = 3
        dispatcher.frameState.cursorCol = 10
        dispatcher.frameState.cursorShape = .block
        dispatcher.frameState.windowGutters[1] = Wire.WindowGutter(
            windowId: 1, contentRow: 0, contentCol: 0, contentHeight: 24,
            isActive: true, contentWidth: 80, cursorLine: 1, lineNumberStyle: .hybrid,
            lineNumberWidth: 4, signColWidth: 1, entries: []
        )

        let content = try GUIWindowContent(
            windowId: 1, fullRefresh: true, cursorVisible: false,
            cursorRow: 0, cursorCol: 0, cursorShape: .beam,
            rows: [], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: []
        )
        dispatcher.applyForTesting(.guiWindowContent(data: content))

        let cursor = CoreTextMetalRenderer.resolveCursor(
            windowContents: gui.windowContents,
            gutters: dispatcher.frameState.windowGutters,
            cellW: 7.5,
            displayCellH: 16.0,
            scale: 2.0,
            gutterLeftMarginPx: 0,
            gutterPaddingPx: 0
        )

        #expect(dispatcher.frameState.cursorVisible == false)
        #expect(cursor == nil)
    }
}
