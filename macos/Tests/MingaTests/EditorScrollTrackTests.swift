import Testing
import CoreGraphics

@Suite("Editor scroll-track geometry (issue #2358)")
struct EditorScrollTrackTests {
    @Test("clicking the top of the track maps to the first line")
    func topMapsToFirstLine() {
        let line = EditorScrollTrack.line(
            forY: 0, viewHeight: 100, totalLines: 200, visibleRows: 50)
        #expect(line == 0)
    }

    @Test("clicking the bottom of the track maps to the last scrollable line")
    func bottomMapsToMaxTop() {
        let line = EditorScrollTrack.line(
            forY: 100, viewHeight: 100, totalLines: 200, visibleRows: 50)
        #expect(line == 150)  // totalLines - visibleRows
    }

    @Test("clicking the middle maps to roughly the middle of the scroll range")
    func middleMapsToHalf() {
        let line = EditorScrollTrack.line(
            forY: 50, viewHeight: 100, totalLines: 200, visibleRows: 50)
        #expect(line == 75)  // 0.5 * (200 - 50)
    }

    @Test("a document that fits entirely on screen never scrolls")
    func fitsOnScreen() {
        #expect(
            EditorScrollTrack.line(forY: 0, viewHeight: 100, totalLines: 40, visibleRows: 50) == 0)
        #expect(
            EditorScrollTrack.line(forY: 0, viewHeight: 100, totalLines: 50, visibleRows: 50) == 0)
    }

    @Test("out-of-bounds Y is clamped to the valid range")
    func clampsOutOfBounds() {
        #expect(
            EditorScrollTrack.line(forY: 200, viewHeight: 100, totalLines: 200, visibleRows: 50)
                == 150)
        #expect(
            EditorScrollTrack.line(forY: -50, viewHeight: 100, totalLines: 200, visibleRows: 50)
                == 0)
    }

    @Test("a zero-height view never crashes and reports no scroll")
    func zeroHeight() {
        #expect(
            EditorScrollTrack.line(forY: 0, viewHeight: 0, totalLines: 200, visibleRows: 50) == 0)
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
    func captureRules() {
        let hiddenIndicator = EditorScrollTrack.shouldCaptureTrackClick(
            totalLines: 200,
            visibleRows: 50,
            viewportTopLine: 10,
            scrollIndicatorAlpha: 0,
            alwaysShowScrollbar: false
        )
        #expect(!hiddenIndicator)

        let visibleIndicator = EditorScrollTrack.shouldCaptureTrackClick(
            totalLines: 200,
            visibleRows: 50,
            viewportTopLine: 10,
            scrollIndicatorAlpha: 1,
            alwaysShowScrollbar: false
        )
        #expect(visibleIndicator)

        let alwaysVisible = EditorScrollTrack.shouldCaptureTrackClick(
            totalLines: 200,
            visibleRows: 50,
            viewportTopLine: 10,
            scrollIndicatorAlpha: 0,
            alwaysShowScrollbar: true
        )
        #expect(alwaysVisible)

        let notScrollable = EditorScrollTrack.shouldCaptureTrackClick(
            totalLines: 50,
            visibleRows: 50,
            viewportTopLine: 10,
            scrollIndicatorAlpha: 1,
            alwaysShowScrollbar: true
        )
        #expect(!notScrollable)

        let invalidViewportTop = EditorScrollTrack.shouldCaptureTrackClick(
            totalLines: 200,
            visibleRows: 50,
            viewportTopLine: UInt32.max,
            scrollIndicatorAlpha: 1,
            alwaysShowScrollbar: true
        )
        #expect(!invalidViewportTop)
    }

    @Test("thumb geometry matches renderer sizing and travel range")
    func thumbGeometryMatchesRenderer() throws {
        let thumb = try #require(EditorScrollTrack.thumb(
            viewHeight: 100,
            totalLines: 1_000,
            visibleRows: 100,
            viewportTopLine: 450
        ))

        #expect(thumb.height == 20)
        #expect(thumb.travelHeight == 80)
        #expect(thumb.y == 40)
    }

    @Test("dragging a grabbed thumb preserves the grabbed offset")
    func draggingThumbPreservesGrabbedOffset() throws {
        let thumb = try #require(EditorScrollTrack.thumb(
            viewHeight: 100,
            totalLines: 1_000,
            visibleRows: 100,
            viewportTopLine: 450
        ))
        let pointerY = thumb.y + 5
        let dragOffset = try #require(EditorScrollTrack.dragOffset(forY: pointerY, thumb: thumb))

        let lineWithoutOffset = EditorScrollTrack.line(
            forY: pointerY,
            viewHeight: 100,
            totalLines: 1_000,
            visibleRows: 100
        )
        let lineWithOffset = EditorScrollTrack.line(
            forDraggedY: pointerY,
            dragOffset: dragOffset,
            viewHeight: 100,
            totalLines: 1_000,
            visibleRows: 100
        )

        #expect(lineWithoutOffset == 405)
        #expect(lineWithOffset == 450)
    }

    @Test("dragging a grabbed thumb clamps to the rendered travel range")
    func draggingThumbClampsToTravelRange() {
        #expect(EditorScrollTrack.line(
            forDraggedY: -40,
            dragOffset: 5,
            viewHeight: 100,
            totalLines: 1_000,
            visibleRows: 100
        ) == 0)

        #expect(EditorScrollTrack.line(
            forDraggedY: 140,
            dragOffset: 5,
            viewHeight: 100,
            totalLines: 1_000,
            visibleRows: 100
        ) == 900)
    }
}
