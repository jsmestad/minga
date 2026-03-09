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

    /// Accumulated horizontal pixel delta. Emits discrete column events
    /// when it crosses cellWidth boundaries.
    var accumulatorX: CGFloat = 0

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
        accumulatorX = 0
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

        accumulatorX += deltaX

        var events: [Event] = []

        while accumulatorX >= cellWidth {
            events.append(.scrollLeft)
            accumulatorX -= cellWidth
        }
        while accumulatorX <= -cellWidth {
            events.append(.scrollRight)
            accumulatorX += cellWidth
        }

        return events
    }

    /// Snap the vertical pixel offset to zero (call at end of gesture/momentum).
    mutating func snapVertical() {
        pixelOffsetY = 0
    }
}
