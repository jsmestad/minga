/// Tests for WindowContentRenderer's display column mapping and attributed string building.
///
/// These tests verify the critical coordinate mapping logic that converts
/// BEAM display columns (CJK = 2 cols) to Swift String.Index positions.

import MingaUI
import Testing
import Foundation
import Metal
import MingaProtocol

@Suite("Window Content Renderer - Display Column Mapping")
struct DisplayColumnMappingTests {

    /// Helper to create a WindowContentRenderer for testing.
    /// Uses a real Metal device but the tests only exercise pure functions.
    @MainActor
    private func makeRenderer() -> WindowContentRenderer? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let fm = FontManager(name: "Menlo", size: 13.0, scale: 2.0)
        let rasterizer = BitmapRasterizer()
        return WindowContentRenderer(device: device, fontManager: fm, rasterizer: rasterizer)
    }

    @Test("ASCII text: each char maps to one display column")
    @MainActor func asciiMapping() throws {
        guard let renderer = makeRenderer() else { return }
        let map = renderer.buildDisplayColumnMap(for: "hello")

        // "hello" = 5 display columns + 1 sentinel
        #expect(map.count == 6)
    }

    @Test("CJK text: each char maps to two display columns")
    @MainActor func cjkMapping() throws {
        guard let renderer = makeRenderer() else { return }
        let text = "日本語"
        let map = renderer.buildDisplayColumnMap(for: text)

        // 3 CJK chars × 2 display columns = 6 display columns + 1 sentinel
        #expect(map.count == 7)

        // Column 0 and 1 both map to the first character
        #expect(map[0] == text.startIndex)
        #expect(map[1] == text.startIndex)

        // Column 2 and 3 map to the second character
        let secondIdx = text.index(text.startIndex, offsetBy: 1)
        #expect(map[2] == secondIdx)
        #expect(map[3] == secondIdx)
    }

    @Test("Mixed ASCII and CJK: correct column mapping")
    @MainActor func mixedMapping() throws {
        guard let renderer = makeRenderer() else { return }
        let text = "ab日c"
        // a=1col, b=1col, 日=2col, c=1col = 5 display columns
        let map = renderer.buildDisplayColumnMap(for: text)

        #expect(map.count == 6) // 5 cols + sentinel

        // col 0 = 'a', col 1 = 'b', col 2,3 = '日', col 4 = 'c'
        let indices = Array(text.indices) + [text.endIndex]
        #expect(map[0] == indices[0]) // 'a'
        #expect(map[1] == indices[1]) // 'b'
        #expect(map[2] == indices[2]) // '日'
        #expect(map[3] == indices[2]) // '日' (second column)
        #expect(map[4] == indices[3]) // 'c'
        #expect(map[5] == indices[4]) // endIndex (sentinel)
    }

    @Test("Empty text: single sentinel entry")
    @MainActor func emptyMapping() throws {
        guard let renderer = makeRenderer() else { return }
        let map = renderer.buildDisplayColumnMap(for: "")

        #expect(map.count == 1) // just the sentinel
    }

    @Test("buildAttributedString with no spans uses default fg color")
    @MainActor func noSpansUsesDefaultFg() throws {
        guard let renderer = makeRenderer() else { return }
        renderer.defaultFgRGB = 0xBBC2CF

        let attrStr = renderer.buildAttributedString(text: "hello", spans: [])

        #expect(attrStr.string == "hello")
        #expect(attrStr.length == 5)
    }

    @Test("buildAttributedString with spans produces correct text")
    @MainActor func spansProduceCorrectText() throws {
        guard let renderer = makeRenderer() else { return }
        renderer.defaultFgRGB = 0xBBC2CF

        let spans = [
            GUIHighlightSpan(startCol: 0, endCol: 3, fg: 0xFF0000, bg: 0, attrs: 0, fontWeight: 0, fontId: 0),
            GUIHighlightSpan(startCol: 3, endCol: 5, fg: 0x00FF00, bg: 0, attrs: 0, fontWeight: 0, fontId: 0),
        ]

        let attrStr = renderer.buildAttributedString(text: "hello", spans: spans)

        #expect(attrStr.string == "hello")
    }

    @Test("buildAttributedString with CJK spans maps columns correctly")
    @MainActor func cjkSpanMapping() throws {
        guard let renderer = makeRenderer() else { return }
        renderer.defaultFgRGB = 0xBBC2CF

        // "ab日c" -> display cols: a=0, b=1, 日=2-3, c=4
        // Span covering "日" needs display cols 2-4
        let spans = [
            GUIHighlightSpan(startCol: 2, endCol: 4, fg: 0xFF0000, bg: 0, attrs: 0, fontWeight: 0, fontId: 0),
        ]

        let attrStr = renderer.buildAttributedString(text: "ab日c", spans: spans)

        // The full text should be preserved
        #expect(attrStr.string == "ab日c")
    }

    @Test("buildAttributedString with gap between spans fills with default style")
    @MainActor func gapBetweenSpans() throws {
        guard let renderer = makeRenderer() else { return }
        renderer.defaultFgRGB = 0xBBC2CF

        // "hello world" with spans on "hello" (0-5) and "world" (6-11)
        // Gap at col 5 (the space) should be filled with default style
        let spans = [
            GUIHighlightSpan(startCol: 0, endCol: 5, fg: 0xFF0000, bg: 0, attrs: 0, fontWeight: 0, fontId: 0),
            GUIHighlightSpan(startCol: 6, endCol: 11, fg: 0x00FF00, bg: 0, attrs: 0, fontWeight: 0, fontId: 0),
        ]

        let attrStr = renderer.buildAttributedString(text: "hello world", spans: spans)

        #expect(attrStr.string == "hello world")
    }
}

@Suite("Window Content Renderer - Frame Metrics")
struct WindowContentFrameMetricsTests {
    @MainActor
    private func makeRendererAndAtlas() -> (WindowContentRenderer, LineTextureAtlas)? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let fm = FontManager(name: "Menlo", size: 13.0, scale: 2.0)
        let rasterizer = BitmapRasterizer()
        let renderer = WindowContentRenderer(device: device, fontManager: fm, rasterizer: rasterizer)
        let atlas = LineTextureAtlas(device: device, slotHeight: renderer.linePixelHeight)
        atlas.ensureCapacity(maxSlots: 8, width: 1024)
        return (renderer, atlas)
    }

    @Test("Buffer row metrics distinguish rasterized rows from reused rows")
    @MainActor func bufferRowMetrics() throws {
        guard let (renderer, atlas) = makeRendererAndAtlas() else { return }
        let row = GUIVisualRow(rowType: .normal, rowId: 100, bufLine: 0, contentHash: 42, text: "hello", spans: [])

        atlas.beginFrame()
        var metrics = FrameMetrics()
        let first = renderer.renderRowToAtlas(displayRow: 0, row: row, windowId: 1, atlas: atlas, metrics: &metrics)
        #expect(first != nil)
        #expect(metrics.bufferRowsRasterized == 1)
        #expect(metrics.bufferRowsReused == 0)
        #expect(metrics.atlasNewKeys == 1)
        #expect(atlas.frameTextureUploads == 1)

        atlas.beginFrame()
        metrics.reset()
        let second = renderer.renderRowToAtlas(displayRow: 0, row: row, windowId: 1, atlas: atlas, metrics: &metrics)
        #expect(second != nil)
        #expect(metrics.bufferRowsRasterized == 0)
        #expect(metrics.bufferRowsReused == 1)
        #expect(atlas.frameTextureUploads == 0)
    }

    @Test("Same row identity reuses atlas slot after display row changes")
    @MainActor func sameRowIdentityReusesAfterScroll() throws {
        guard let (renderer, atlas) = makeRendererAndAtlas() else { return }
        let row = GUIVisualRow(rowType: .normal, rowId: 200, bufLine: 10, contentHash: 42, text: "same", spans: [])

        atlas.beginFrame()
        var metrics = FrameMetrics()
        let first = renderer.renderRowToAtlas(displayRow: 0, row: row, windowId: 1, atlas: atlas, metrics: &metrics)
        #expect(first != nil)
        #expect(metrics.bufferRowsRasterized == 1)

        atlas.beginFrame()
        metrics.reset()
        let second = renderer.renderRowToAtlas(displayRow: 1, row: row, windowId: 1, atlas: atlas, metrics: &metrics)
        #expect(second?.slotIndex == first?.slotIndex)
        #expect(metrics.bufferRowsRasterized == 0)
        #expect(metrics.bufferRowsReused == 1)
        #expect(atlas.frameTextureUploads == 0)
    }

    @Test("Different row identity rasterizes even on the same display row")
    @MainActor func differentRowIdentityMissesOnSameDisplayRow() throws {
        guard let (renderer, atlas) = makeRendererAndAtlas() else { return }
        let firstRow = GUIVisualRow(rowType: .normal, rowId: 300, bufLine: 0, contentHash: 42, text: "same", spans: [])
        let secondRow = GUIVisualRow(rowType: .normal, rowId: 301, bufLine: 1, contentHash: 42, text: "same", spans: [])

        atlas.beginFrame()
        var metrics = FrameMetrics()
        let first = renderer.renderRowToAtlas(displayRow: 0, row: firstRow, windowId: 1, atlas: atlas, metrics: &metrics)
        #expect(first != nil)

        atlas.beginFrame()
        metrics.reset()
        let second = renderer.renderRowToAtlas(displayRow: 0, row: secondRow, windowId: 1, atlas: atlas, metrics: &metrics)
        #expect(second != nil)
        #expect(second?.slotIndex != first?.slotIndex)
        #expect(metrics.bufferRowsRasterized == 1)
        #expect(metrics.atlasNewKeys == 1)
    }

    @Test("Same display row in different windows uses distinct atlas slots")
    @MainActor func sameRowDifferentWindowsUsesDistinctSlots() throws {
        guard let (renderer, atlas) = makeRendererAndAtlas() else { return }
        let left = GUIVisualRow(rowType: .normal, rowId: 400, bufLine: 0, contentHash: 42, text: "left", spans: [])
        let right = GUIVisualRow(rowType: .normal, rowId: 400, bufLine: 0, contentHash: 99, text: "right", spans: [])

        atlas.beginFrame()
        var metrics = FrameMetrics()
        let leftEntry = renderer.renderRowToAtlas(displayRow: 0, row: left, windowId: 1, atlas: atlas, metrics: &metrics)
        let rightEntry = renderer.renderRowToAtlas(displayRow: 0, row: right, windowId: 2, atlas: atlas, metrics: &metrics)

        #expect(leftEntry != nil)
        #expect(rightEntry != nil)
        #expect(leftEntry?.slotIndex != rightEntry?.slotIndex)
        #expect(metrics.bufferRowsRasterized == 2)
        #expect(metrics.atlasHashChanges == 0)
    }

    @Test("Changed row hash records hash-change miss reason")
    @MainActor func changedHashMetrics() throws {
        guard let (renderer, atlas) = makeRendererAndAtlas() else { return }
        let original = GUIVisualRow(rowType: .normal, rowId: 500, bufLine: 0, contentHash: 42, text: "hello", spans: [])
        let changed = GUIVisualRow(rowType: .normal, rowId: 500, bufLine: 0, contentHash: 43, text: "hello!", spans: [])

        atlas.beginFrame()
        var metrics = FrameMetrics()
        _ = renderer.renderRowToAtlas(displayRow: 0, row: original, windowId: 1, atlas: atlas, metrics: &metrics)

        atlas.beginFrame()
        metrics.reset()
        _ = renderer.renderRowToAtlas(displayRow: 0, row: changed, windowId: 1, atlas: atlas, metrics: &metrics)
        #expect(metrics.bufferRowsRasterized == 1)
        #expect(metrics.atlasHashChanges == 1)
    }

    @Test("Changed content epoch rerasterizes a row with the same row hash")
    @MainActor func changedContentEpochMetrics() throws {
        guard let (renderer, atlas) = makeRendererAndAtlas() else { return }
        let row = GUIVisualRow(rowType: .normal, rowId: 600, bufLine: 0, contentHash: 42, text: "hello", spans: [])

        atlas.beginFrame()
        var metrics = FrameMetrics()
        _ = renderer.renderRowToAtlas(displayRow: 0, row: row, windowId: 1, contentEpoch: 10, atlas: atlas, metrics: &metrics)

        atlas.beginFrame()
        metrics.reset()
        _ = renderer.renderRowToAtlas(displayRow: 0, row: row, windowId: 1, contentEpoch: 11, atlas: atlas, metrics: &metrics)
        #expect(metrics.bufferRowsRasterized == 1)
        #expect(metrics.atlasHashChanges == 1)
    }

    @Test("Full-refresh window content invalidates retained atlas rows")
    @MainActor func fullRefreshWindowInvalidatesAtlasRows() throws {
        guard let (renderer, atlas) = makeRendererAndAtlas() else { return }
        let row = GUIVisualRow(rowType: .normal, rowId: 650, bufLine: 0, contentHash: 42, text: "hello", spans: [])

        atlas.beginFrame()
        var metrics = FrameMetrics()
        let first = renderer.renderRowToAtlas(displayRow: 0, row: row, windowId: 1, atlas: atlas, metrics: &metrics)
        #expect(first != nil)
        #expect(metrics.bufferRowsRasterized == 1)

        let content = try GUIWindowContent(windowId: 1, fullRefresh: true, cursorRow: 0, cursorCol: 0, cursorShape: .block, rows: [row], selection: nil, searchMatches: [], diagnosticUnderlines: [], documentHighlights: [])
        atlas.beginFrame()
        CoreTextMetalRenderer.invalidateFullRefreshWindows(in: atlas, windowContents: [1: content])
        metrics.reset()
        let second = renderer.renderRowToAtlas(displayRow: 0, row: row, windowId: 1, atlas: atlas, metrics: &metrics)
        #expect(second != nil)
        #expect(metrics.bufferRowsRasterized == 1)
        #expect(metrics.bufferRowsReused == 0)
        #expect(metrics.atlasNewKeys == 1)
    }

    @Test("Horizontal scroll keeps row identity but changes the atlas hash")
    @MainActor func horizontalScrollChangesAtlasHash() throws {
        guard let (renderer, atlas) = makeRendererAndAtlas() else { return }
        let row = GUIVisualRow(rowType: .normal, rowId: 675, bufLine: 0, contentHash: 42, text: "abcdef", spans: [])
        let left = renderer.clipRowToViewport(row, scrollLeft: 0, viewportCols: 3)
        let scrolled = renderer.clipRowToViewport(row, scrollLeft: 2, viewportCols: 3)

        #expect(left.rowId == row.rowId)
        #expect(scrolled.rowId == row.rowId)
        #expect(left.text == "abc")
        #expect(scrolled.text == "cde")
        #expect(left.contentHash != scrolled.contentHash)

        atlas.beginFrame()
        var metrics = FrameMetrics()
        _ = renderer.renderRowToAtlas(displayRow: 0, row: left, windowId: 1, atlas: atlas, metrics: &metrics)
        #expect(metrics.bufferRowsRasterized == 1)

        atlas.beginFrame()
        metrics.reset()
        _ = renderer.renderRowToAtlas(displayRow: 0, row: scrolled, windowId: 1, atlas: atlas, metrics: &metrics)
        #expect(metrics.bufferRowsRasterized == 1)
        #expect(metrics.bufferRowsReused == 0)
        #expect(metrics.atlasHashChanges == 1)
    }

    @Test("Atlas slot demand accounts for split-window texture entries")
    func atlasDemandCountsSplitWindows() throws {
        let rows = [GUIVisualRow(rowType: .normal, rowId: 700, bufLine: 0, contentHash: 1, text: "row", spans: [])]
        let left = try GUIWindowContent(windowId: 1, fullRefresh: true, cursorRow: 0, cursorCol: 0, cursorShape: .block, rows: rows, selection: nil, searchMatches: [], diagnosticUnderlines: [], documentHighlights: [], lineAnnotations: [GUILineAnnotation(row: 0, kind: .inlineText, fg: 0xFFFFFF, bg: 0, text: "hint")])
        let right = try GUIWindowContent(windowId: 2, fullRefresh: true, cursorRow: 0, cursorCol: 0, cursorShape: .block, rows: rows, selection: nil, searchMatches: [], diagnosticUnderlines: [], documentHighlights: [])

        var frameState = FrameState(cols: 80, rows: 2)
        frameState.windowGutters = [
            1: Wire.WindowGutter(windowId: 1, contentRow: 0, contentCol: 0, contentHeight: 2, isActive: true, contentWidth: 40, cursorLine: 0, lineNumberStyle: .absolute, lineNumberWidth: 2, signColWidth: 2, entries: [Wire.GutterEntry(bufLine: 0, displayType: .normal, signType: .diagError)]),
            2: Wire.WindowGutter(windowId: 2, contentRow: 0, contentCol: 40, contentHeight: 2, isActive: false, contentWidth: 40, cursorLine: 0, lineNumberStyle: .absolute, lineNumberWidth: 2, signColWidth: 2, entries: [Wire.GutterEntry(bufLine: 0, displayType: .normal, signType: .annotation, signFg: 0xFFFFFF, signText: "●")])
        ]
        frameState.horizontalSeparators = [Wire.HorizontalSeparator(row: 1, col: 0, width: 80, filename: "split.ex")]

        let demand = CoreTextMetalRenderer.atlasSlotDemand(frameState: frameState, windowContents: [1: left, 2: right])

        #expect(demand >= 2 + 1 + 4 + 1 + 32)
    }

    @Test("Atlas slot demand ignores retained rows outside the visible pane")
    func atlasDemandIgnoresOffscreenRecoveryRows() throws {
        let rows = (0..<5_000).map { index in
            GUIVisualRow(rowType: .normal, rowId: UInt64(index + 1), bufLine: UInt32(index), contentHash: UInt32(index), text: "row", spans: [])
        }

        let geometry = GUIPaneGeometry(
            windowId: 1,
            totalRect: GUICellRect(row: 0, col: 0, width: 80, height: 40),
            contentRect: GUICellRect(row: 0, col: 0, width: 80, height: 40),
            textRect: GUICellRect(row: 0, col: 0, width: 80, height: 40),
            gutterRect: GUICellRect(row: 0, col: 0, width: 0, height: 40),
            clipRect: GUICellRect(row: 0, col: 0, width: 80, height: 40),
            viewport: GUIViewportSummary(top: 0, left: 0, rows: 40, cols: 80, totalLines: 5_000, visualRowOffset: 0, totalVisualRows: 5_000),
            gutterMetrics: GUIGutterMetrics(lineNumberWidth: 0, signColWidth: 0),
            hitRegions: []
        )

        let content = try GUIWindowContent(
            windowId: 1, fullRefresh: true, cursorRow: 0, cursorCol: 0, cursorShape: .block,
            rows: rows, selection: nil, searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: [], paneGeometry: geometry
        )
        let frameState = FrameState(cols: 80, rows: 40)

        let demand = CoreTextMetalRenderer.atlasSlotDemand(frameState: frameState, windowContents: [1: content])

        #expect(demand < 5_000)
        #expect(demand >= 40)
    }

    @Test("extreme pill width fails before raster allocation or atlas reservation")
    @MainActor func extremePillWidthFailsBeforeAllocation() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let policy = FrameResourcePolicy.NativeRendererLimits(
            rasterBytes: 1_048_576, atlasBytes: 16_777_216,
            aggregateDrawBufferBytes: 1_048_576,
            textureWidth: 32, textureHeight: 1_024
        )
        let fm = FontManager(name: "Menlo", size: 13.0, scale: 2.0)
        var allocations = 0
        let production = BitmapRasterizer.Factories.production
        let rasterizer = BitmapRasterizer(factories: .init(
            allocate: { byteCount in
                allocations += 1
                return malloc(byteCount)
            },
            deallocate: { free($0) },
            makeContext: production.makeContext
        ))
        let renderer = WindowContentRenderer(
            device: device, fontManager: fm, rasterizer: rasterizer,
            resourcePolicy: policy
        )
        let atlas = LineTextureAtlas(device: device, slotHeight: renderer.linePixelHeight)
        guard case .success = atlas.ensureCapacity(maxSlots: 4, width: 1_024) else { return }
        atlas.beginFrame()
        let allocatorBefore = atlas.allocator
        var metrics = FrameMetrics()
        let annotation = GUILineAnnotation(
            row: 0, kind: .inlinePill, fg: 0xFFFFFF, bg: 0x112233,
            text: String(repeating: "W", count: 1_024)
        )

        let entry = renderer.renderAnnotationToAtlas(
            annotation: annotation,
            key: .lineAnnotation(windowId: 1, row: 0, subIndex: 0),
            atlas: atlas, metrics: &metrics
        )

        #expect(entry == nil)
        #expect(renderer.nativePresentationFailure?.dimension == .textureWidth)
        #expect(allocations == 0)
        #expect(atlas.frameTextureUploads == 0)
        #expect(atlas.allocator == allocatorBefore)
        #expect(metrics.otherTexturesRasterized == 0)
    }

    @Test("pill raster byte excess fails before allocation and partial upload")
    @MainActor func pillRasterBytesFailBeforeAllocation() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let policy = FrameResourcePolicy.NativeRendererLimits(
            rasterBytes: 64, atlasBytes: 16_777_216,
            aggregateDrawBufferBytes: 1_048_576,
            textureWidth: 1_024, textureHeight: 1_024
        )
        let fm = FontManager(name: "Menlo", size: 13.0, scale: 2.0)
        var allocations = 0
        let production = BitmapRasterizer.Factories.production
        let rasterizer = BitmapRasterizer(factories: .init(
            allocate: { byteCount in
                allocations += 1
                return malloc(byteCount)
            },
            deallocate: { free($0) },
            makeContext: production.makeContext
        ))
        let renderer = WindowContentRenderer(
            device: device, fontManager: fm, rasterizer: rasterizer,
            resourcePolicy: policy
        )
        let atlas = LineTextureAtlas(device: device, slotHeight: renderer.linePixelHeight)
        guard case .success = atlas.ensureCapacity(maxSlots: 4, width: 1_024) else { return }
        atlas.beginFrame()
        let allocatorBefore = atlas.allocator
        var metrics = FrameMetrics()
        let annotation = GUILineAnnotation(
            row: 0, kind: .inlinePill, fg: 0xFFFFFF, bg: 0x112233,
            text: "oversized raster"
        )

        let entry = renderer.renderAnnotationToAtlas(
            annotation: annotation,
            key: .lineAnnotation(windowId: 1, row: 0, subIndex: 0),
            atlas: atlas, metrics: &metrics
        )

        #expect(entry == nil)
        #expect(renderer.nativePresentationFailure?.dimension == .rasterBytes)
        #expect(allocations == 0)
        #expect(atlas.frameTextureUploads == 0)
        #expect(atlas.allocator == allocatorBefore)
        #expect(metrics.otherTexturesRasterized == 0)
    }

    @Test("LineTextureAtlas refuses rather than truncates over device height")
    @MainActor func lineTextureAtlasRefusesCapacityOverTextureHeight() {
        guard let (_, atlas) = makeRendererAndAtlas() else { return }
        let originalSlots = atlas.slotCount
        let originalHeight = atlas.atlasHeight
        let oversizedSlots = atlas.maxSlotCapacity + 1_000

        let result = atlas.ensureCapacity(maxSlots: oversizedSlots, width: 1024)

        guard case .failure = result else {
            Issue.record("oversized atlas unexpectedly succeeded")
            return
        }
        #expect(atlas.slotCount == originalSlots)
        #expect(atlas.atlasHeight == originalHeight)
    }

    @Test("FrameMetrics reset clears all counters")
    func frameMetricsReset() {
        var metrics = FrameMetrics(bufferRowsRasterized: 1, bufferRowsReused: 2, otherTexturesRasterized: 3, otherTexturesReused: 4, textureUploads: 5, textureUploadBytes: 6, atlasNewKeys: 7, atlasHashChanges: 8, atlasEvictions: 9)
        metrics.reset()
        #expect(metrics == FrameMetrics())
    }
}

@Suite("GUIState Frame Lifecycle")
struct GUIStateFrameTests {
    @Test("beginFrame preserves windowContents as fallback")
    @MainActor func beginFramePreservesContents() throws {
        let state = GUIState()
        let content = try GUIWindowContent(
            windowId: 1, fullRefresh: true,
            cursorRow: 0, cursorCol: 0, cursorShape: .block,
            rows: [], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: []
        )
        state.windowContents[1] = content
        // Stale window content persists across frames by design: it is the
        // fallback that prevents blank-viewport flashes if frame delivery is
        // interrupted. The guiWindowContent dispatch overwrites per-window
        // data each frame (the cell-era beginFrame no-op was removed with
        // the clear opcode).
        #expect(state.windowContents.count == 1)
        #expect(state.windowContents[1]?.windowId == 1)
    }
}
