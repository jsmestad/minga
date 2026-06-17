import Testing
import CoreGraphics

@Suite("Editor scroll-track geometry (issue #2358)")
struct EditorScrollTrackTests {
    @Test("clicking the top of the track maps to the first line")
    func topMapsToFirstLine() {
        // y == viewHeight is the top in AppKit's bottom-up coordinates.
        let line = EditorScrollTrack.line(
            forY: 100, viewHeight: 100, totalLines: 200, visibleRows: 50)
        #expect(line == 0)
    }

    @Test("clicking the bottom of the track maps to the last scrollable line")
    func bottomMapsToMaxTop() {
        let line = EditorScrollTrack.line(
            forY: 0, viewHeight: 100, totalLines: 200, visibleRows: 50)
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
                == 0)
        #expect(
            EditorScrollTrack.line(forY: -50, viewHeight: 100, totalLines: 200, visibleRows: 50)
                == 150)
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
}
