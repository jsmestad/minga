import CoreGraphics

/// Pure accumulator for smooth trackpad scrolling.
///
/// Tracks a fractional pixel offset and emits discrete line/column events
/// when the offset crosses a cell boundary. The pixel offset (vertical)
/// gives the Metal renderer a sub-cell-height shift for smooth visual scrolling.
///
/// This struct is intentionally free of NSEvent and encoder dependencies
/// so the accumulation logic can be unit tested.
struct ScrollAccumulator {
    /// Fractional vertical pixel offset within the current top line.
    /// Always in range [0, cellHeight). The Metal renderer uses this to
    /// shift content by a sub-line amount.
    var pixelOffsetY: CGFloat = 0

    /// Fractional horizontal pixel offset within the current left column.
    /// Positive = content shifted left, negative = content shifted right.
    var pixelOffsetX: CGFloat = 0

    /// Scroll direction emitted to the BEAM.
    enum Event: Equatable {
        case scrollDown
        case scrollUp
        case scrollLeft
        case scrollRight
    }

    /// Reset both accumulators (call at the start of a new gesture).
    mutating func reset() {
        pixelOffsetY = 0
        pixelOffsetX = 0
    }

    /// Accumulate a vertical pixel delta from a trackpad event.
    ///
    /// `deltaY` follows AppKit convention: positive = scroll up (content moves down).
    /// Returns an array of discrete scroll events to send to the BEAM.
    mutating func accumulateVertical(deltaY: CGFloat, cellHeight: CGFloat) -> [Event] {
        guard cellHeight > 0 else { return [] }

        // scrollingDeltaY is positive when scrolling up (content down),
        // but pixelOffsetY is positive when content shifts up (scrolling down).
        pixelOffsetY -= deltaY

        var events: [Event] = []

        while pixelOffsetY >= cellHeight {
            events.append(.scrollDown)
            pixelOffsetY -= cellHeight
        }
        while pixelOffsetY < 0 {
            events.append(.scrollUp)
            pixelOffsetY += cellHeight
        }

        return events
    }

    /// Accumulate a horizontal pixel delta from a trackpad event.
    ///
    /// `deltaX` follows AppKit convention: positive = scroll left.
    /// Returns an array of discrete scroll events to send to the BEAM.
    mutating func accumulateHorizontal(deltaX: CGFloat, cellWidth: CGFloat) -> [Event] {
        guard cellWidth > 0 else { return [] }

        pixelOffsetX += deltaX

        var events: [Event] = []

        while pixelOffsetX >= cellWidth {
            events.append(.scrollLeft)
            pixelOffsetX -= cellWidth
        }
        while pixelOffsetX <= -cellWidth {
            events.append(.scrollRight)
            pixelOffsetX += cellWidth
        }

        return events
    }

    /// Snap the vertical pixel offset to zero (call at end of gesture/momentum).
    mutating func snapVertical() {
        pixelOffsetY = 0
    }
}
