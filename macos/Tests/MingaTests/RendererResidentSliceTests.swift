import MingaProtocol
import Testing

@Suite("Renderer resident row slicing")
struct RendererResidentSliceTests {
    @Test("fixed viewport visits the same rows for 5,000 and 65,536 row documents")
    func boundedVisitedRows() throws {
        let small = try content(rowCount: 5_000, visibleStart: 2_000, visibleRows: 40)
        let large = try content(rowCount: 65_536, visibleStart: 2_000, visibleRows: 40)

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
    func boundedCompletePreparation() throws {
        let small = try content(rowCount: 5_000, visibleStart: 2_000, visibleRows: 40, visualOffset: 3)
        let large = try content(rowCount: 65_536, visibleStart: 2_000, visibleRows: 40, visualOffset: 3)
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

        let prepared = ResidentRenderPreparation.prepare(
            content: large, fallbackVisibleRows: 40,
            overscanRows: RendererSignposts.configuredOverscanRows,
            scrollLeft: 0, viewportCols: 80
        )
        let nativeDemand = try NativeRenderDemand.checked(
            textureWidth: 640, slotHeight: 20, atlasSlots: largeDemand,
            lineInstances: prepared.commands.count, lineStride: MemoryLayout<LineGPU>.stride,
            quadInstances: largeDemand * 4, quadStride: MemoryLayout<QuadGPU>.stride,
            quadBufferCount: 3, policy: .default,
            deviceTextureWidth: 16_384, deviceTextureHeight: 16_384,
            deviceMaxBufferLength: 1_073_741_824
        )
        #expect(prepared.commands.count == 44)
        #expect(nativeDemand.atlasSlots == largeDemand)
        #expect(nativeDemand.textureHeight < 16_384)
        #expect(nativeDemand.aggregateDrawBufferBytes < FrameResourcePolicy.NativeRendererLimits.default.aggregateDrawBufferBytes)
    }

    @Test("idle and overlay-only frames report zero reset and reference work")
    func perFrameOperationCounters() throws {
        let resident = try content(rowCount: 65_536, visibleStart: 2_000, visibleRows: 40)
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

    @Test("ordinary edit and visible preparation satisfy the deterministic native gate")
    func deterministicComplexityGate() throws {
        let visibleRows = 40
        for rowCount in [5_000, 65_536] {
            let content = try content(rowCount: rowCount, visibleStart: 2_000, visibleRows: visibleRows)
            let replacement = GUIVisualRow(
                rowType: .normal, rowId: 2_001, bufLine: 2_000,
                contentHash: 999_001, text: "edited", spans: []
            )
            let delta = GUIWindowRowsDelta(
                windowId: 1, contentEpoch: 8, cursorVisible: true,
                cursorRow: 0, cursorCol: 0, cursorShape: .block, scrollLeft: 0,
                baseRowCount: UInt32(rowCount), resultRowCount: UInt32(rowCount),
                rowSplices: [GUIWindowRowSplice(startIndex: 2_000, deleteCount: 1,
                    insertEntries: [.full(replacement)])],
                selection: content.selection, searchMatches: content.searchMatches,
                diagnosticUnderlines: content.diagnosticUnderlines,
                documentHighlights: content.documentHighlights,
                lineAnnotations: content.lineAnnotations, paneGeometry: content.paneGeometry,
                cursorline: content.cursorline, scrollPresentation: content.scrollPresentation
            )
            let updated = try content.applyingRowsDeltaChecked(delta).get()
            let slice = RendererSignposts.visibleSlice(for: updated, fallbackVisibleRows: visibleRows)
            var metrics = FrameMetrics()
            RendererSignposts.recordVisibleSlice(slice, in: &metrics)
            RendererSignposts.recordOperation(updated.rowStoreOperationCounters, in: &metrics)
            metrics.decorationsVisited = RendererSignposts.decorationCount(for: updated)

            let measurement = RendererComplexityMeasurement(
                fullResets: metrics.residentFullResets,
                chunksTouched: metrics.residentChunksTouched,
                editorRowsVisited: metrics.editorRowsVisited,
                visibleRows: visibleRows,
                overscanRows: RendererSignposts.configuredOverscanRows * 2,
                decorationsVisited: metrics.decorationsVisited
            )
            #expect(RendererComplexityGate.failures(measurement).isEmpty)
            #expect(metrics.editorRowsVisited == visibleRows + RendererSignposts.configuredOverscanRows * 2)
            #expect(metrics.decorationsVisited == 2)
            #expect(metrics.residentRowsVisited != metrics.editorRowsVisited)
        }
    }

    @Test("shared CoreText preparation clips text and spans with bounded gutter commands")
    func sharedCommandPreparationParity() throws {
        let resident = try content(rowCount: 65_536, visibleStart: 2_000, visibleRows: 40)
        let prepared = ResidentRenderPreparation.prepare(
            content: resident, fallbackVisibleRows: 40, overscanRows: 2,
            scrollLeft: 2, viewportCols: 4
        )

        #expect(prepared.commands.count == 44)
        #expect(prepared.commands.count == prepared.rows.count)
        #expect(prepared.commands.first?.presentationRow == -2)
        #expect(prepared.commands.first?.gutterBufferLine == prepared.rows.first?.bufLine)
        #expect(prepared.commands.allSatisfy { $0.row.text.count <= 4 })
        #expect(prepared.counters.chunksTouched <= 2)
        #expect(prepared.decorationsVisited == 2)

        let styled = GUIVisualRow(
            rowType: .normal, rowId: 1, bufLine: 7, contentHash: 9,
            text: "abcdef", spans: [GUIHighlightSpan(
                startCol: 1, endCol: 5, fg: 1, bg: 2,
                attrs: 0, fontWeight: 0, fontId: 0
            )]
        )
        let clipped = ResidentRenderPreparation.clip(row: styled, scrollLeft: 2, viewportCols: 3)
        #expect(clipped.text == "cde")
        #expect(clipped.spans.first?.startCol == 0)
        #expect(clipped.spans.first?.endCol == 3)
    }

    @Test("shared preparation feeds atlas demand and row counters once")
    func sharedPreparationCounterParity() throws {
        let resident = try content(rowCount: 65_536, visibleStart: 2_000, visibleRows: 40)
        let prepared = ResidentRenderPreparation.prepare(
            content: resident, fallbackVisibleRows: 40, overscanRows: RendererSignposts.configuredOverscanRows,
            scrollLeft: 0, viewportCols: 80
        )
        var metrics = FrameMetrics()
        RendererSignposts.recordVisibleSlice(RendererSignposts.rowSlice(for: prepared), in: &metrics)

        var frame = FrameState(cols: 80, rows: 40)
        frame.windowGutters = [1: gutter(entries: [])]
        let demand = CoreTextMetalRenderer.atlasSlotDemand(
            frameState: frame, windowContents: [1: resident], preparedRows: [1: prepared]
        )

        #expect(prepared.rows.count == 44)
        #expect(metrics.editorRowsVisited == prepared.counters.rowsVisited)
        #expect(metrics.editorRowsVisited == 44)
        #expect(demand > prepared.rows.count)
    }

    @Test("failure seams reject an extra reset, chunk, or full-row scan")
    func deterministicComplexityFailureSeams() throws {
        let boundary = RendererComplexityMeasurement(
            fullResets: 0, chunksTouched: 4, editorRowsVisited: 44,
            visibleRows: 40, overscanRows: 4, decorationsVisited: 10_000
        )
        #expect(RendererComplexityGate.failures(boundary).isEmpty)
        #expect(!RendererComplexityGate.failures(RendererComplexityMeasurement(
            fullResets: 1, chunksTouched: 4, editorRowsVisited: 44,
            visibleRows: 40, overscanRows: 4, decorationsVisited: 0)).isEmpty)
        #expect(!RendererComplexityGate.failures(RendererComplexityMeasurement(
            fullResets: 0, chunksTouched: 5, editorRowsVisited: 44,
            visibleRows: 40, overscanRows: 4, decorationsVisited: 0)).isEmpty)
        #expect(!RendererComplexityGate.failures(RendererComplexityMeasurement(
            fullResets: 0, chunksTouched: 4, editorRowsVisited: 65_536,
            visibleRows: 40, overscanRows: 4, decorationsVisited: 0)).isEmpty)
    }

    @Test("far-down resident viewport keeps cursor, selection, and annotation rows viewport-local")
    func viewportLocalOverlayCoordinates() throws {
        let resident = try content(rowCount: 65_536, visibleStart: 50_000, visibleRows: 40, visualOffset: 3)
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
    func wrappedRows() throws {
        let rows = [
            row(id: 1, line: 9),
            row(id: 2, line: 10),
            row(id: 3, line: 10, type: .wrapContinuation),
            row(id: 4, line: 10, type: .virtualLine),
            row(id: 5, line: 11),
            row(id: 6, line: 12)
        ]
        let content = try GUIWindowContent(
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

    private func content(rowCount: Int, visibleStart: Int, visibleRows: Int, visualOffset: Int = 0) throws -> GUIWindowContent {
        try GUIWindowContent(
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
