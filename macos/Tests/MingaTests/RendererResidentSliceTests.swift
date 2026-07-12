import MingaProtocol
import Testing

@Suite("Renderer resident row slicing")
struct RendererResidentSliceTests {
    @Test("fixed viewport visits the same rows for 5,000 and 65,536 row documents")
    func boundedVisitedRows() {
        let small = content(rowCount: 5_000, visibleStart: 2_000, visibleRows: 40)
        let large = content(rowCount: 65_536, visibleStart: 2_000, visibleRows: 40)

        let smallSlice = RendererSignposts.visibleSlice(for: small, fallbackVisibleRows: 40)
        let largeSlice = RendererSignposts.visibleSlice(for: large, fallbackVisibleRows: 40)

        #expect(smallSlice.rows.count == 44)
        #expect(largeSlice.rows.count == 44)
        #expect(smallSlice.counters.rowsVisited == largeSlice.counters.rowsVisited)
        #expect(smallSlice.counters.chunksTouched <= 2)
        #expect(largeSlice.counters.chunksTouched <= 2)
        #expect(smallSlice.rows.first?.bufLine == 1_998)
        #expect(largeSlice.rows.last?.bufLine == 2_041)
    }

    @Test("content, gutters, and atlas demand stay bounded to one identical range")
    func boundedCompletePreparation() {
        let small = content(rowCount: 5_000, visibleStart: 2_000, visibleRows: 40, visualOffset: 3)
        let large = content(rowCount: 65_536, visibleStart: 2_000, visibleRows: 40, visualOffset: 3)
        let entries = (0..<65_536).map {
            Wire.GutterEntry(bufLine: UInt32($0), displayType: .normal, signType: $0.isMultiple(of: 7) ? .diagError : .none)
        }
        let smallGutter = gutter(entries: Array(entries.prefix(5_000)))
        let largeGutter = gutter(entries: entries)
        let smallSlice = RendererSignposts.visibleSlice(for: small, fallbackVisibleRows: 40)
        let largeSlice = RendererSignposts.visibleSlice(for: large, fallbackVisibleRows: 40)

        #expect(smallSlice.range == 2_001..<2_045)
        #expect(largeSlice.range == smallSlice.range)
        #expect(RendererSignposts.gutterRange(for: smallGutter, slice: smallSlice) == smallSlice.range)
        #expect(RendererSignposts.gutterRange(for: largeGutter, slice: largeSlice) == largeSlice.range)
        #expect(large.cursorRow == 0)
        #expect(large.selection?.startRow == 0)
        #expect(large.lineAnnotations[0].row == 0)

        var smallFrame = FrameState(cols: 80, rows: 40)
        smallFrame.windowGutters = [1: smallGutter]
        var largeFrame = FrameState(cols: 80, rows: 40)
        largeFrame.windowGutters = [1: largeGutter]
        let smallDemand = CoreTextMetalRenderer.atlasSlotDemand(frameState: smallFrame, windowContents: [1: small])
        let largeDemand = CoreTextMetalRenderer.atlasSlotDemand(frameState: largeFrame, windowContents: [1: large])
        #expect(smallDemand == largeDemand)
        #expect(largeDemand < 200)
    }

    @Test("idle and overlay-only frames report zero reset and reference work")
    func perFrameOperationCounters() throws {
        let resident = content(rowCount: 65_536, visibleStart: 2_000, visibleRows: 40)
        var identities: [UInt16: ObjectIdentifier] = [:]
        let first = RendererSignposts.operationCounters(for: resident, lastContentIdentities: &identities)
        let idle = RendererSignposts.operationCounters(for: resident, lastContentIdentities: &identities)
        #expect(first.fullResets == 1)
        #expect(idle.fullResets == 0)
        #expect(idle.idsResolved == 0)

        let overlay = GUIWindowOverlayDelta(windowId: 1, contentEpoch: 8, cursorVisible: true,
            cursorRow: 3, cursorCol: 4, cursorShape: .beam, cursorline: nil)
        let updated = try #require(resident.applyingOverlayDelta(overlay))
        let overlayWork = RendererSignposts.operationCounters(for: updated, lastContentIdentities: &identities)
        #expect(overlayWork == ResidentRowStoreCounters())
        #expect(updated.rowStore.count == 65_536)
        #expect(updated.rowStore.counters == resident.rowStore.counters)

        let rowsDelta = GUIWindowRowsDelta(windowId: 1, contentEpoch: 8, cursorVisible: true,
            cursorRow: 3, cursorCol: 4, cursorShape: .beam, scrollLeft: 0,
            rows: [.reference(rowId: 2_004, contentHash: 2_004),
                   .reference(rowId: 2_005, contentHash: 2_005)],
            selection: nil, searchMatches: [], diagnosticUnderlines: [], documentHighlights: [],
            lineAnnotations: [], paneGeometry: nil, cursorline: nil)
        let rowsUpdated = try updated.applyingRowsDeltaChecked(rowsDelta).get()
        let rowWork = RendererSignposts.operationCounters(for: rowsUpdated, lastContentIdentities: &identities)
        let rowsIdle = RendererSignposts.operationCounters(for: rowsUpdated, lastContentIdentities: &identities)
        #expect(rowWork.idsResolved == 4)
        #expect(rowsIdle.idsResolved == 0)
        #expect(rowsIdle.fullResets == 0)
    }

    @Test("far-down resident viewport keeps cursor, selection, and annotation rows viewport-local")
    func viewportLocalOverlayCoordinates() throws {
        let resident = content(rowCount: 65_536, visibleStart: 50_000, visibleRows: 40, visualOffset: 3)
        let slice = RendererSignposts.visibleSlice(for: resident, fallbackVisibleRows: 40)
        #expect(slice.visibleStartIndex == 50_003)

        var frame = FrameState(cols: 80, rows: 40)
        frame.windowGutters = [1: gutter(entries: [])]
        let cursor = try #require(CoreTextMetalRenderer.resolveCursor(
            frameState: frame,
            windowContents: [1: resident],
            cellW: 8,
            displayCellH: 20,
            scale: 1,
            gutterLeftMarginPx: 0,
            gutterPaddingPx: 0
        ))
        #expect(cursor.y == 0)

        let locallyScrolledOrigin: Float = -7
        let selectionRow = Int(try #require(resident.selection?.startRow))
        let annotationRow = Int(try #require(resident.lineAnnotations.first?.row))
        #expect(CoreTextMetalRenderer.viewportLocalRowY(
            localRow: selectionRow, origin: locallyScrolledOrigin, cellHeight: 20, scale: 1
        ) == -7)
        #expect(CoreTextMetalRenderer.viewportLocalRowY(
            localRow: annotationRow, origin: locallyScrolledOrigin, cellHeight: 20, scale: 1
        ) == -7)
    }

    @Test("slice origin preserves wraps and decorations sharing a buffer line")
    func wrappedRows() {
        let rows = [
            row(id: 1, line: 9),
            row(id: 2, line: 10),
            row(id: 3, line: 10, type: .wrapContinuation),
            row(id: 4, line: 10, type: .virtualLine),
            row(id: 5, line: 11),
            row(id: 6, line: 12)
        ]
        let content = GUIWindowContent(
            windowId: 1, fullRefresh: true, contentEpoch: 8,
            cursorRow: 0, cursorCol: 0, cursorShape: .block,
            rows: rows, selection: nil, searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: [],
            scrollPresentation: presentation(visibleStart: 10, visibleRows: 2, totalRows: 6)
        )

        let slice = RendererSignposts.visibleSlice(for: content, fallbackVisibleRows: 2, overscanRows: 0)
        #expect(slice.visibleStartIndex == 1)
        #expect(slice.rows.map(\.rowId) == [2, 3, 4, 5])
        #expect(slice.overscanBeforeRows == 0)
    }

    private func content(rowCount: Int, visibleStart: Int, visibleRows: Int, visualOffset: Int = 0) -> GUIWindowContent {
        GUIWindowContent(
            windowId: 1, fullRefresh: true, contentEpoch: 8,
            cursorRow: 0, cursorCol: 0, cursorShape: .block,
            rows: (0..<rowCount).map { row(id: UInt64($0 + 1), line: UInt32($0)) },
            selection: GUISelectionOverlay(type: .char,
                startRow: 0, startCol: 0,
                endRow: 0, endCol: 1),
            searchMatches: [], diagnosticUnderlines: [], documentHighlights: [],
            lineAnnotations: [GUILineAnnotation(row: 0,
                kind: .inlineText, fg: 0xFFFFFF, bg: 0, text: "hint")],
            scrollPresentation: presentation(
                visibleStart: visibleStart,
                visibleRows: visibleRows,
                totalRows: rowCount,
                visualOffset: visualOffset
            )
        )
    }

    private func presentation(visibleStart: Int, visibleRows: Int, totalRows: Int, visualOffset: Int = 0) -> GUIScrollPresentation {
        GUIScrollPresentation(
            windowId: 1,
            resetRequired: false,
            anchorTop: UInt32(visibleStart),
            anchorLeft: 0,
            anchorVisualRowOffset: UInt16(visualOffset),
            visibleStartLine: UInt32(visibleStart),
            visibleEndLine: UInt32(visibleStart + visibleRows),
            overscanStartLine: 0,
            overscanEndLine: UInt32(totalRows),
            contentEpoch: 8,
            layoutGeneration: 1
        )
    }

    private func gutter(entries: [Wire.GutterEntry]) -> Wire.WindowGutter {
        Wire.WindowGutter(windowId: 1, contentRow: 0, contentCol: 0, contentHeight: 40,
            isActive: true, contentWidth: 80, cursorLine: 2_003, lineNumberStyle: .absolute,
            lineNumberWidth: 5, signColWidth: 2, entries: entries)
    }

    private func row(id: UInt64, line: UInt32, type: GUIVisualRowType = .normal) -> GUIVisualRow {
        GUIVisualRow(
            rowType: type, rowId: id, bufLine: line,
            contentHash: UInt32(truncatingIfNeeded: id), text: "row \(id)", spans: []
        )
    }
}
