import Testing
import CoreGraphics
import MingaProtocol

@Suite("Editor scroll-track geometry (issue #2358)")
struct EditorScrollTrackTests {
    private func unwrappedSurface(top: UInt32) throws -> PresentedWindowSurface {
        let viewport = GUIViewportSummary(
            top: top, left: 0, rows: 20, cols: 80,
            totalLines: 100, visualRowOffset: 0, totalVisualRows: 100
        )
        let rect = GUICellRect(row: 0, col: 0, width: 80, height: 20)
        let geometry = GUIPaneGeometry(
            windowId: 1, totalRect: rect, contentRect: rect, textRect: rect,
            gutterRect: GUICellRect(row: 0, col: 0, width: 0, height: 20),
            clipRect: rect, viewport: viewport,
            gutterMetrics: GUIGutterMetrics(lineNumberWidth: 0, signColWidth: 0),
            hitRegions: []
        )
        let presentation = GUIScrollPresentation(
            windowId: 1, resetRequired: false, anchorTop: 40, anchorLeft: 0,
            anchorVisualRowOffset: 0, visibleStartLine: 40, visibleEndLine: 60,
            overscanStartLine: 0, overscanEndLine: 100, contentEpoch: 7,
            layoutGeneration: 1
        )
        let content = try GUIWindowContent(
            windowId: 1, fullRefresh: true, contentEpoch: 7,
            cursorRow: 0, cursorCol: 0, cursorShape: .block,
            rows: [], selection: nil, searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: [], paneGeometry: geometry,
            scrollPresentation: presentation
        )
        return PresentedWindowSurface(
            content: content, gutter: .none, paneGeometry: geometry, indentGuides: nil
        )
    }

    @Test("active surface viewport and local transform produce one thumb metric")
    func surfaceMetricsIncludeLocalScroll() throws {
        let surface = try unwrappedSurface(top: 40)
        let local = EditorLocalPresentationTransform(
            windowId: 1, offset: CGPoint(x: 0, y: 25)
        )

        let metrics = try #require(EditorScrollTrack.metrics(
            surface: surface, localTransform: local, rowPitch: 10
        ))
        #expect(metrics.coordinate == .logicalLine)
        #expect(metrics.displayedTop == 42.5)
        #expect(metrics.totalRows == 100)
        #expect(metrics.visibleRows == 20)
        #expect(metrics.presentsLocally)

        let thumb = try #require(EditorScrollTrack.thumb(
            viewHeight: 100, metrics: metrics
        ))
        #expect(abs(thumb.y - (42.5 / 99 * 80)) < 0.001)
    }

    @Test("wrapped residence uses rank and clamps only the matching pane's offset")
    @MainActor func wrappedThumbUsesResidentRank() throws {
        let fixture = WrappedScrollFixture()
        let content = try fixture.content(top: 0, continuation: 1)
        let geometry = try #require(content.paneGeometry)
        let surface = PresentedWindowSurface(content: content, gutter: .none, paneGeometry: geometry, indentGuides: nil)
        func metrics(windowID: UInt16, offset: CGFloat) throws -> EditorScrollTrack.Metrics {
            try #require(EditorScrollTrack.metrics(
                surface: surface,
                localTransform: EditorLocalPresentationTransform(windowId: windowID, offset: CGPoint(x: 0, y: offset)),
                rowPitch: 20
            ))
        }

        let matching = try metrics(windowID: 1, offset: 30)
        #expect(matching.coordinate == .visualRank)
        #expect(matching.totalRows == 8)
        #expect(matching.visibleRows == 3)
        #expect(matching.displayedTop == 2.5)
        #expect(matching.maxTop == 5)
        #expect(matching.presentsLocally)
        #expect(try metrics(windowID: 2, offset: 30).displayedTop == 1)
        #expect(try metrics(windowID: 1, offset: 200).displayedTop == 5)
        #expect(try metrics(windowID: 1, offset: -200).displayedTop == 0)
        #expect(EditorScrollTrack.target(forDraggedY: 100, dragOffset: 0, viewHeight: 100, metrics: matching) == 5)
    }

    @Test("windowed wrapping has no track without an absolute visual rank")
    @MainActor func windowedWrappedThumbIsUnavailable() throws {
        let fixture = WrappedScrollFixture(fittedRows: 2)
        let content = try fixture.content(top: 1, continuation: 0, resident: false)
        let geometry = try #require(content.paneGeometry)
        let surface = PresentedWindowSurface(content: content, gutter: .none, paneGeometry: geometry, indentGuides: nil)
        let local = EditorLocalPresentationTransform(windowId: 1, offset: CGPoint(x: 0, y: 20))
        #expect(EditorScrollTrack.metrics(surface: surface, localTransform: local, rowPitch: 20) == nil)
    }

    private let windowedTrack = EditorScrollTrack.Metrics(
        coordinate: .logicalLine, totalRows: 200, visibleRows: 50, top: 10, maxTop: 150, presentsLocally: false
    )
    private let fittingTrack = EditorScrollTrack.Metrics(
        coordinate: .logicalLine, totalRows: 50, visibleRows: 50, top: 0, maxTop: 0, presentsLocally: false
    )
    private let dragTrack = EditorScrollTrack.Metrics(
        coordinate: .logicalLine, totalRows: 1_000, visibleRows: 100, top: 450, maxTop: 900, presentsLocally: false
    )

    @Test("track click maps proportionally and clamps out-of-bounds pointers")
    func clickMapsToTop() {
        #expect(EditorScrollTrack.target(forY: -50, viewHeight: 100, metrics: windowedTrack) == 0)
        #expect(EditorScrollTrack.target(forY: 0, viewHeight: 100, metrics: windowedTrack) == 0)
        #expect(EditorScrollTrack.target(forY: 50, viewHeight: 100, metrics: windowedTrack) == 75)
        #expect(EditorScrollTrack.target(forY: 100, viewHeight: 100, metrics: windowedTrack) == 150)
        #expect(EditorScrollTrack.target(forY: 200, viewHeight: 100, metrics: windowedTrack) == 150)
    }

    @Test("track click reaches a single overflowing wrapped row")
    func clickReachesSingleWrappedOverflowRow() {
        let track = EditorScrollTrack.Metrics(
            coordinate: .visualRank, totalRows: 4, visibleRows: 3, top: 0, maxTop: 1, presentsLocally: true
        )
        #expect(EditorScrollTrack.target(forY: 90, viewHeight: 100, metrics: track) == 1)
    }

    @Test("a fitting document or zero-height view never scrolls")
    func degenerateTrack() {
        #expect(EditorScrollTrack.target(forY: 50, viewHeight: 100, metrics: fittingTrack) == 0)
        #expect(EditorScrollTrack.target(forY: 50, viewHeight: 0, metrics: windowedTrack) == 0)
        #expect(EditorScrollTrack.thumb(viewHeight: 100, metrics: fittingTrack) == nil)
        #expect(EditorScrollTrack.thumb(viewHeight: 0, metrics: windowedTrack) == nil)
    }

    @Test("the hit region covers the right edge but not the content area")
    func hitRegion() {
        let width: CGFloat = 800
        // Just inside the right edge → in track.
        #expect(EditorScrollTrack.isInTrack(x: width - 5, viewWidth: width))
        #expect(EditorScrollTrack.isInTrack(x: width, viewWidth: width))
        // Well left of the track → not in track.
        #expect(!EditorScrollTrack.isInTrack(x: width - EditorScrollTrack.hitWidth - 1, viewWidth: width))
        #expect(!EditorScrollTrack.isInTrack(x: 10, viewWidth: width))
    }

    @Test("scroll-track capture follows visibility and scrollability rules")
    func captureRules() throws {
        #expect(!EditorScrollTrack.shouldCaptureTrackClick(
            metrics: windowedTrack, scrollIndicatorAlpha: 0, alwaysShowScrollbar: false
        ))
        #expect(EditorScrollTrack.shouldCaptureTrackClick(
            metrics: windowedTrack, scrollIndicatorAlpha: 1, alwaysShowScrollbar: false
        ))
        #expect(EditorScrollTrack.shouldCaptureTrackClick(
            metrics: windowedTrack, scrollIndicatorAlpha: 0, alwaysShowScrollbar: true
        ))
        #expect(!EditorScrollTrack.shouldCaptureTrackClick(
            metrics: fittingTrack, scrollIndicatorAlpha: 1, alwaysShowScrollbar: true
        ))
        let invalidSurface = try unwrappedSurface(top: UInt32.max)
        #expect(EditorScrollTrack.metrics(surface: invalidSurface, localTransform: nil, rowPitch: 20) == nil)
    }

    @Test("thumb geometry matches renderer sizing and travel range")
    func thumbGeometryMatchesRenderer() throws {
        let thumb = try #require(EditorScrollTrack.thumb(viewHeight: 100, metrics: dragTrack))

        #expect(thumb.height == 20)
        #expect(thumb.travelHeight == 80)
        #expect(thumb.y == 40)
    }

    @Test("dragging a grabbed thumb preserves the grabbed offset")
    func draggingThumbPreservesGrabbedOffset() throws {
        let thumb = try #require(EditorScrollTrack.thumb(viewHeight: 100, metrics: dragTrack))
        let pointerY = thumb.y + 5
        let dragOffset = try #require(EditorScrollTrack.dragOffset(forY: pointerY, thumb: thumb))

        let lineWithoutOffset = EditorScrollTrack.target(forY: pointerY, viewHeight: 100, metrics: dragTrack)
        let lineWithOffset = EditorScrollTrack.target(
            forDraggedY: pointerY, dragOffset: dragOffset, viewHeight: 100, metrics: dragTrack
        )

        #expect(lineWithoutOffset == 405)
        #expect(lineWithOffset == 450)
    }

    @Test("dragging a grabbed thumb clamps to the rendered travel range")
    func draggingThumbClampsToTravelRange() {
        #expect(EditorScrollTrack.target(forDraggedY: -40, dragOffset: 5, viewHeight: 100, metrics: dragTrack) == 0)
        #expect(EditorScrollTrack.target(forDraggedY: 140, dragOffset: 5, viewHeight: 100, metrics: dragTrack) == 900)
    }
}
