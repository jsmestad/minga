import CoreGraphics
import MingaProtocol

/// Pure geometry for the main editor's custom scroll track.
///
/// Shared by the renderer and pointer handling so the thumb travels in the same
/// coordinate space that a click or drag targets.
enum EditorScrollTrack {
    enum Coordinate: Equatable {
        case logicalLine
        case visualRank
    }

    /// The document extent, scrollable top range, and displayed position of one pane.
    struct Metrics: Equatable {
        let coordinate: Coordinate
        let totalRows: UInt32
        let visibleRows: UInt32
        let displayedTop: CGFloat
        let maxTop: UInt32
        let presentsLocally: Bool

        init(coordinate: Coordinate, totalRows: UInt32, visibleRows: UInt32, top: CGFloat,
             maxTop: UInt32, presentsLocally: Bool) {
            self.coordinate = coordinate
            self.totalRows = totalRows
            self.visibleRows = visibleRows
            self.displayedTop = min(max(top, 0), CGFloat(maxTop))
            self.maxTop = maxTop
            self.presentsLocally = presentsLocally
        }

        var canScroll: Bool { maxTop > 0 && totalRows > visibleRows }
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

    /// Minimum thumb height in view points.
    static let minThumbHeight: CGFloat = 20.0

    /// Resolves scroll metrics from the active pane and the local transform used for this draw.
    static func metrics(
        surface: PresentedWindowSurface,
        localTransform: EditorLocalPresentationTransform?,
        rowPitch: CGFloat
    ) -> Metrics? {
        let viewport = surface.paneGeometry.viewport
        guard viewport.totalLines > 0, viewport.rows > 0, rowPitch > 0 else { return nil }
        let visibleRows = UInt32(viewport.rows)
        let localRows = localTransform.flatMap { transform in
            transform.windowId == surface.windowId ? transform.offset.y / rowPitch : nil
        } ?? 0
        let content = surface.content
        if let anchor = content.wrappedResidentAnchor, let maxTop = content.wrappedResidentMaxTop {
            return Metrics(
                coordinate: .visualRank, totalRows: viewport.totalVisualRows, visibleRows: visibleRows,
                top: CGFloat(anchor) + localRows, maxTop: UInt32(maxTop), presentsLocally: true
            )
        }

        // A wrapped windowed payload has no absolute rank. A logical thumb would
        // claim a position and travel range that do not describe the displayed rows.
        let scroll = content.scrollPresentation
        guard scroll?.isWrapped != true, viewport.top != UInt32.max else { return nil }
        let resident = isUnwrappedResident(scroll, totalLines: viewport.totalLines)
        let maxTop = viewport.totalLines > visibleRows ? viewport.totalLines - (resident ? 1 : visibleRows) : 0
        return Metrics(
            coordinate: .logicalLine, totalRows: viewport.totalLines, visibleRows: visibleRows,
            top: CGFloat(viewport.top) + localRows, maxTop: maxTop, presentsLocally: resident
        )
    }

    /// Unwrapped resident panes cover the whole document, including the last logical line.
    static func isUnwrappedResident(_ scroll: GUIScrollPresentation?, totalLines: UInt32) -> Bool {
        guard let scroll, !scroll.isWrapped, totalLines > 0 else { return false }
        return scroll.overscanStartLine == 0 && scroll.overscanEndLine >= totalLines
    }

    /// Returns true when the editor should intercept a right-edge click for these metrics.
    static func shouldCaptureTrackClick(
        metrics: Metrics,
        scrollIndicatorAlpha: Float,
        alwaysShowScrollbar: Bool
    ) -> Bool {
        guard metrics.canScroll else { return false }
        return alwaysShowScrollbar || scrollIndicatorAlpha > 0
    }

    /// Computes thumb geometry from the same metrics used by renderer and pointer handling.
    static func thumb(
        viewHeight: CGFloat,
        metrics: Metrics
    ) -> Thumb? {
        guard metrics.canScroll, viewHeight > 0 else { return nil }
        let proportion = CGFloat(metrics.visibleRows) / CGFloat(metrics.totalRows)
        let thumbHeight = min(viewHeight, max(proportion * viewHeight, minThumbHeight))
        let travelHeight = viewHeight - thumbHeight
        let y = metrics.displayedTop / CGFloat(metrics.maxTop) * travelHeight
        return Thumb(y: y, height: thumbHeight, travelHeight: travelHeight)
    }

    /// Whether a point falls within the scroll-track hit region of a view whose
    /// width is `viewWidth`.
    static func isInTrack(x: CGFloat, viewWidth: CGFloat) -> Bool {
        let trackX = viewWidth - hitWidth
        return x >= trackX && x <= viewWidth
    }

    /// Returns the pointer offset inside the current thumb when the pointer is grabbing the thumb.
    static func dragOffset(forY y: CGFloat, thumb: Thumb) -> CGFloat? {
        guard y >= thumb.y, y <= thumb.y + thumb.height else { return nil }
        return y - thumb.y
    }

    /// Maps a grabbed thumb's pointer position back to its absolute line or visual rank.
    static func target(forDraggedY y: CGFloat, dragOffset: CGFloat, viewHeight: CGFloat, metrics: Metrics) -> UInt32 {
        guard let thumb = thumb(viewHeight: viewHeight, metrics: metrics), thumb.travelHeight > 0 else { return 0 }
        let fraction = min(max((y - dragOffset) / thumb.travelHeight, 0), 1)
        let position = fraction * CGFloat(metrics.maxTop)
        // Invert the displayed visual rank even if floating-point arithmetic leaves
        // the result infinitesimally below an integer.
        return UInt32(metrics.coordinate == .visualRank ? position.rounded() : position)
    }

    /// Maps a top-down track click to the absolute line or rank in the same scroll range.
    static func target(forY y: CGFloat, viewHeight: CGFloat, metrics: Metrics) -> UInt32 {
        guard metrics.canScroll, viewHeight > 0 else { return 0 }
        let position = min(max(y / viewHeight, 0), 1) * CGFloat(metrics.maxTop)
        return UInt32(metrics.coordinate == .visualRank ? position.rounded() : position)
    }
}
