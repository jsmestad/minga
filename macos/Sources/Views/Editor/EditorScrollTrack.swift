import CoreGraphics

/// Pure geometry for the main editor's custom scroll track.
///
/// Factored out of `EditorNSView` so the click/drag → target-line mapping can be
/// unit-tested without AppKit (issue #2358). The live hit-testing and drag
/// handling still live in `EditorNSView`; only this math is shared.
enum EditorScrollTrack {
    /// Geometry of the rendered scrollbar thumb within the editor track.
    struct Thumb {
        /// Top-down Y position of the thumb within the track.
        let y: CGFloat

        /// Height of the thumb.
        let height: CGFloat

        /// Distance the thumb can travel from top to bottom.
        let travelHeight: CGFloat
    }

    /// Width of the scroll-indicator hit region along the view's right edge.
    /// Wider than the drawn indicator so it is easy to grab.
    static let hitWidth: CGFloat = 20.0

    /// Minimum thumb height, matching the renderer's 20px minimum translated into view coordinates.
    static let minThumbHeight: CGFloat = 20.0

    /// Whether a point falls within the scroll-track hit region of a view whose
    /// width is `viewWidth`.
    static func isInTrack(x: CGFloat, viewWidth: CGFloat) -> Bool {
        let trackX = viewWidth - hitWidth
        return x >= trackX && x <= viewWidth
    }

    /// Returns true when the editor should intercept a right-edge click for scroll-track interaction.
    ///
    /// The track only captures clicks when the document can actually scroll, the viewport top is valid,
    /// and either the indicator is visible or the macOS scrollbar setting forces it to stay visible.
    static func shouldCaptureTrackClick(
        totalLines: UInt32,
        visibleRows: UInt32,
        viewportTopLine: UInt32,
        scrollIndicatorAlpha: Float,
        alwaysShowScrollbar: Bool
    ) -> Bool {
        guard totalLines > visibleRows else { return false }
        guard viewportTopLine != 0xFFFF_FFFF else { return false }
        return alwaysShowScrollbar || scrollIndicatorAlpha > 0
    }

    /// Computes the visible thumb geometry with the same sizing and travel range used by the renderer.
    static func thumb(
        viewHeight: CGFloat,
        totalLines: UInt32,
        visibleRows: UInt32,
        viewportTopLine: UInt32,
        resident: Bool = false,
        minThumbHeight: CGFloat = Self.minThumbHeight
    ) -> Thumb? {
        guard totalLines > visibleRows, viewHeight > 0 else { return nil }
        guard viewportTopLine != 0xFFFF_FFFF else { return nil }

        let proportion = CGFloat(visibleRows) / CGFloat(totalLines)
        let thumbHeight = min(viewHeight, max(proportion * viewHeight, minThumbHeight))
        let travelHeight = max(viewHeight - thumbHeight, 0)
        let maxTop = maxScrollableTop(totalLines: totalLines, visibleRows: visibleRows, resident: resident)
        let clampedTopLine = min(viewportTopLine, maxTop)
        let y = travelHeight > 0 ? (CGFloat(clampedTopLine) / CGFloat(maxTop)) * travelHeight : 0
        return Thumb(y: y, height: thumbHeight, travelHeight: travelHeight)
    }

    /// Returns the pointer offset inside the current thumb when the pointer is grabbing the thumb.
    static func dragOffset(forY y: CGFloat, thumb: Thumb) -> CGFloat? {
        guard y >= thumb.y, y <= thumb.y + thumb.height else { return nil }
        return y - thumb.y
    }

    /// Maps a drag pointer Y to a target top line while preserving the offset captured inside the thumb on mouse down.
    static func line(
        forDraggedY y: CGFloat,
        dragOffset: CGFloat,
        viewHeight: CGFloat,
        totalLines: UInt32,
        visibleRows: UInt32,
        resident: Bool = false,
        minThumbHeight: CGFloat = Self.minThumbHeight
    ) -> UInt32 {
        guard let thumb = thumb(
            viewHeight: viewHeight,
            totalLines: totalLines,
            visibleRows: visibleRows,
            viewportTopLine: 0,
            resident: resident,
            minThumbHeight: minThumbHeight
        ) else { return 0 }
        guard thumb.travelHeight > 0 else { return 0 }

        let thumbY = max(0, min(thumb.travelHeight, y - dragOffset))
        let proportion = thumbY / thumb.travelHeight
        let maxTop = maxScrollableTop(totalLines: totalLines, visibleRows: visibleRows, resident: resident)
        return UInt32(max(0, min(Int64(maxTop), Int64(Double(proportion) * Double(maxTop)))))
    }

    /// Maps a track click Y within `viewHeight` to a target top line, clamped to the valid scroll range.
    ///
    /// `y` uses EditorNSView's flipped top-down coordinates, so 0 is the top of the view and
    /// `viewHeight` is the bottom. Returns 0 when the document fits entirely on screen.
    static func line(
        forY y: CGFloat,
        viewHeight: CGFloat,
        totalLines: UInt32,
        visibleRows: UInt32,
        resident: Bool = false
    ) -> UInt32 {
        guard totalLines > visibleRows, viewHeight > 0 else { return 0 }

        let clampedY = max(0, min(viewHeight, y))
        let proportion = clampedY / viewHeight
        let maxTop = maxScrollableTop(totalLines: totalLines, visibleRows: visibleRows, resident: resident)
        return UInt32(max(0, min(Int64(maxTop), Int64(Double(proportion) * Double(maxTop)))))
    }

    static func maxScrollableTop(totalLines: UInt32, visibleRows: UInt32, resident: Bool) -> UInt32 {
        let subtract: Int64 = resident ? 1 : Int64(visibleRows)
        return UInt32(max(Int64(totalLines) - subtract, 1))
    }
}
