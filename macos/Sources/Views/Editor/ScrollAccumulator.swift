import CoreGraphics

/// Pure accumulator for smooth trackpad scrolling.
///
/// Converts AppKit's signed deltas to whole cells while retaining sub-cell motion.
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

    enum VerticalEvent: Equatable {
        case scrollDown
        case scrollUp
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
    mutating func accumulateVertical(deltaY: CGFloat, cellHeight: CGFloat) -> [VerticalEvent] {
        guard cellHeight > 0 else { return [] }

        // scrollingDeltaY is positive when scrolling up (content down),
        // but pixelOffsetY is positive when content shifts up (scrolling down).
        pixelOffsetY -= deltaY

        var events: [VerticalEvent] = []

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

    /// AppKit positive X moves the content right; positive viewport motion moves it left.
    /// Keep only the accepted sub-cell residual at a viewport edge or after i16 saturation.
    mutating func accumulateHorizontal(
        deltaX: CGFloat, cellWidth: CGFloat, left: Int = Int(UInt16.max), right: Int = Int(UInt16.max)
    ) -> Int16 {
        guard cellWidth > 0 else { return 0 }
        let offset = pixelOffsetX - deltaX
        let columns = offset / cellWidth
        guard columns > -CGFloat(left) else {
            snapHorizontal()
            return Int16(clamping: -left)
        }
        guard columns < CGFloat(right) else {
            snapHorizontal()
            return Int16(clamping: right)
        }
        let wholeColumns = Int(columns)
        pixelOffsetX = offset - CGFloat(wholeColumns) * cellWidth
        return Int16(clamping: wholeColumns)
    }

    mutating func snapHorizontal() {
        pixelOffsetX = 0
    }

    /// Snap the vertical pixel offset to zero (call at end of gesture/momentum).
    mutating func snapVertical() {
        pixelOffsetY = 0
    }
}

/// The endpoint and latest sequence of the accepted pan input for one pane.
struct HorizontalScrollPrediction {
    let left: Int
    let inputSeq: UInt32

    func columns(from committedLeft: UInt16) -> Int {
        left - Int(committedLeft)
    }
}
