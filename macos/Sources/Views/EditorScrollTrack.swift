import CoreGraphics

/// Pure geometry for the main editor's custom scroll track.
///
/// Factored out of `EditorNSView` so the click/drag → target-line mapping can be
/// unit-tested without AppKit (issue #2358). The live hit-testing and drag
/// handling still live in `EditorNSView`; only this math is shared.
enum EditorScrollTrack {
    /// Width of the scroll-indicator hit region along the view's right edge.
    /// Wider than the drawn indicator so it is easy to grab.
    static let hitWidth: CGFloat = 20.0

    /// Whether a point falls within the scroll-track hit region of a view whose
    /// width is `viewWidth`.
    static func isInTrack(x: CGFloat, viewWidth: CGFloat) -> Bool {
        let trackX = viewWidth - hitWidth
        return x >= trackX && x <= viewWidth
    }

    /// Maps a click/drag Y within a track of height `viewHeight` to a target top
    /// line, clamped to the valid scroll range.
    ///
    /// `y` is in AppKit's bottom-up coordinates (origin at the bottom), matching
    /// `NSView` mouse events; the top of the document maps to the top of the
    /// track. Returns 0 when the document fits entirely on screen.
    static func line(
        forY y: CGFloat,
        viewHeight: CGFloat,
        totalLines: UInt32,
        visibleRows: UInt32
    ) -> UInt32 {
        guard totalLines > visibleRows, viewHeight > 0 else { return 0 }

        let flippedY = viewHeight - y
        let proportion = max(0, min(1, flippedY / viewHeight))
        let maxTop = Int64(totalLines) - Int64(visibleRows)
        return UInt32(max(0, min(maxTop, Int64(Double(proportion) * Double(maxTop)))))
    }
}
