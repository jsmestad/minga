/// Tests for the ScrollAccumulator used in smooth trackpad scrolling.

import Testing
import Foundation

@Suite("ScrollAccumulator vertical")
struct ScrollAccumulatorVerticalTests {

    @Test("small delta below cellHeight produces no events")
    func smallDeltaNoEvent() {
        var acc = ScrollAccumulator()
        let events = acc.accumulateVertical(deltaY: -5, cellHeight: 20)
        #expect(events.isEmpty)
        #expect(acc.pixelOffsetY == 5) // -deltaY = positive offset (scroll down)
    }

    @Test("delta exactly equal to cellHeight produces one scrollDown")
    func exactCellHeight() {
        var acc = ScrollAccumulator()
        let events = acc.accumulateVertical(deltaY: -20, cellHeight: 20)
        #expect(events == [.scrollDown])
        #expect(acc.pixelOffsetY == 0)
    }

    @Test("delta larger than cellHeight produces multiple events")
    func multipleCellHeights() {
        var acc = ScrollAccumulator()
        let events = acc.accumulateVertical(deltaY: -50, cellHeight: 20)
        #expect(events == [.scrollDown, .scrollDown])
        #expect(acc.pixelOffsetY == 10) // 50 - 40 = 10 remainder
    }

    @Test("positive deltaY (scroll up) produces scrollUp events")
    func scrollUp() {
        var acc = ScrollAccumulator()
        let events = acc.accumulateVertical(deltaY: 20, cellHeight: 20)
        #expect(events == [.scrollUp])
        #expect(acc.pixelOffsetY == 0)
    }

    @Test("accumulation across multiple calls")
    func accumulationAcrossCalls() {
        var acc = ScrollAccumulator()
        // 8 pixels down, no event yet
        let e1 = acc.accumulateVertical(deltaY: -8, cellHeight: 20)
        #expect(e1.isEmpty)
        #expect(acc.pixelOffsetY == 8)

        // 8 more, still no event (16 total)
        let e2 = acc.accumulateVertical(deltaY: -8, cellHeight: 20)
        #expect(e2.isEmpty)
        #expect(acc.pixelOffsetY == 16)

        // 8 more = 24 total, crosses cellHeight
        let e3 = acc.accumulateVertical(deltaY: -8, cellHeight: 20)
        #expect(e3 == [.scrollDown])
        #expect(acc.pixelOffsetY == 4) // 24 - 20
    }

    @Test("direction reversal during scroll")
    func directionReversal() {
        var acc = ScrollAccumulator()
        // Scroll down 15px
        _ = acc.accumulateVertical(deltaY: -15, cellHeight: 20)
        #expect(acc.pixelOffsetY == 15)

        // Now scroll up 25px (net: -10px from start)
        let events = acc.accumulateVertical(deltaY: 25, cellHeight: 20)
        #expect(events == [.scrollUp])
        // 15 - 25 = -10, wraps to +10 after emitting scrollUp
        #expect(acc.pixelOffsetY == 10)
    }

    @Test("pixelOffsetY stays in [0, cellHeight) range")
    func offsetRange() {
        var acc = ScrollAccumulator()
        // Many small increments
        for _ in 0..<100 {
            _ = acc.accumulateVertical(deltaY: -3, cellHeight: 20)
            #expect(acc.pixelOffsetY >= 0)
            #expect(acc.pixelOffsetY < 20)
        }
    }

    @Test("zero cellHeight returns no events")
    func zeroCellHeight() {
        var acc = ScrollAccumulator()
        let events = acc.accumulateVertical(deltaY: -50, cellHeight: 0)
        #expect(events.isEmpty)
    }

    @Test("snapVertical resets offset to zero")
    func snapVertical() {
        var acc = ScrollAccumulator()
        _ = acc.accumulateVertical(deltaY: -10, cellHeight: 20)
        #expect(acc.pixelOffsetY == 10)

        acc.snapVertical()
        #expect(acc.pixelOffsetY == 0)
    }

    @Test("reset clears both accumulators")
    func reset() {
        var acc = ScrollAccumulator()
        _ = acc.accumulateVertical(deltaY: -10, cellHeight: 20)
        _ = acc.accumulateHorizontal(deltaX: 5, cellWidth: 10)

        acc.reset()
        #expect(acc.pixelOffsetY == 0)
        #expect(acc.accumulatorX == 0)
    }
}

@Suite("ScrollAccumulator horizontal")
struct ScrollAccumulatorHorizontalTests {

    @Test("small delta below cellWidth produces no events")
    func smallDelta() {
        var acc = ScrollAccumulator()
        let events = acc.accumulateHorizontal(deltaX: 5, cellWidth: 10)
        #expect(events.isEmpty)
        #expect(acc.accumulatorX == 5)
    }

    @Test("positive delta crossing cellWidth produces scrollLeft")
    func scrollLeft() {
        var acc = ScrollAccumulator()
        let events = acc.accumulateHorizontal(deltaX: 15, cellWidth: 10)
        #expect(events == [.scrollLeft])
        #expect(acc.accumulatorX == 5)
    }

    @Test("negative delta crossing cellWidth produces scrollRight")
    func scrollRight() {
        var acc = ScrollAccumulator()
        let events = acc.accumulateHorizontal(deltaX: -15, cellWidth: 10)
        #expect(events == [.scrollRight])
        #expect(acc.accumulatorX == -5)
    }

    @Test("large delta produces multiple events")
    func multipleEvents() {
        var acc = ScrollAccumulator()
        let events = acc.accumulateHorizontal(deltaX: -35, cellWidth: 10)
        #expect(events == [.scrollRight, .scrollRight, .scrollRight])
        #expect(acc.accumulatorX == -5)
    }

    @Test("zero cellWidth returns no events")
    func zeroCellWidth() {
        var acc = ScrollAccumulator()
        let events = acc.accumulateHorizontal(deltaX: 50, cellWidth: 0)
        #expect(events.isEmpty)
    }
}
