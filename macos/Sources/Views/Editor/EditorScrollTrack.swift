import CoreGraphics

/// Pure geometry for the main editor's custom scroll track.
///
/// Factored out of `EditorNSView` so the click/drag → target-line mapping can be
/// unit-tested without AppKit (issue #2358). The live hit-testing and drag
/// handling still live in `EditorNSView`; only this math is shared.
enum EditorScrollTrack {
    /// One authoritative scroll presentation shared by drawing and hit testing.
    struct Metrics: Equatable {
        let totalLines: UInt32
        let visibleRows: UInt32
        let viewportTopLine: CGFloat
        let resident: Bool
    }

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

    /// Resolves scroll metrics from the active pane and the local transform used for this draw.
    static func metrics(
        surface: PresentedWindowSurface,
        localTransform: EditorLocalPresentationTransform?,
        cellHeight: CGFloat
    ) -> Metrics? {
        let viewport = surface.paneGeometry.viewport
        guard viewport.totalLines > 0, viewport.rows > 0, cellHeight > 0 else { return nil }
        let localOffset = localTransform?.windowId == surface.windowId
            ? localTransform?.offset.y ?? 0
            : 0
        let topLine = max(0, CGFloat(viewport.top) + localOffset / cellHeight)
        let resident = surface.content.scrollPresentation.map {
            $0.overscanStartLine == 0 && $0.overscanEndLine >= viewport.totalLines
        } ?? false
        return Metrics(
            totalLines: viewport.totalLines,
            visibleRows: UInt32(viewport.rows),
            viewportTopLine: topLine,
            resident: resident
        )
    }

    /// Returns true when the editor should intercept a right-edge click for these metrics.
    static func shouldCaptureTrackClick(
        metrics: Metrics,
        scrollIndicatorAlpha: Float,
        alwaysShowScrollbar: Bool
    ) -> Bool {
        guard metrics.totalLines > metrics.visibleRows else { return false }
        return alwaysShowScrollbar || scrollIndicatorAlpha > 0
    }

    /// Computes thumb geometry from the same metrics used by renderer and pointer handling.
    static func thumb(
        viewHeight: CGFloat,
        metrics: Metrics,
        minThumbHeight: CGFloat = Self.minThumbHeight
    ) -> Thumb? {
        guard metrics.totalLines > metrics.visibleRows, viewHeight > 0 else { return nil }
        let proportion = CGFloat(metrics.visibleRows) / CGFloat(metrics.totalLines)
        let thumbHeight = min(viewHeight, max(proportion * viewHeight, minThumbHeight))
        let travelHeight = max(viewHeight - thumbHeight, 0)
        let maxTop = maxScrollableTop(
            totalLines: metrics.totalLines,
            visibleRows: metrics.visibleRows,
            resident: metrics.resident
        )
        let clampedTopLine = min(metrics.viewportTopLine, CGFloat(maxTop))
        let y = travelHeight > 0 ? (clampedTopLine / CGFloat(maxTop)) * travelHeight : 0
        return Thumb(y: y, height: thumbHeight, travelHeight: travelHeight)
    }

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

        return thumb(
            viewHeight: viewHeight,
            metrics: Metrics(
                totalLines: totalLines,
                visibleRows: visibleRows,
                viewportTopLine: CGFloat(viewportTopLine),
                resident: resident
            ),
            minThumbHeight: minThumbHeight
        )
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
