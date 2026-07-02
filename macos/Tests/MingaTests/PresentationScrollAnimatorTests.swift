/// Tests for the shared presentation scroll animation ticker and its pure math (issue #2664).

import Testing
import Foundation
import CoreGraphics

@Suite("PresentationScrollAnimator easing")
struct PresentationScrollAnimatorEasingTests {

    @Test("progress clamps to the timeline bounds")
    func progressClamps() {
        #expect(PresentationScrollAnimator.progress(now: 0, startTime: 1, duration: 0.1) == 0)
        #expect(PresentationScrollAnimator.progress(now: 5, startTime: 1, duration: 0.1) == 1)
        let mid = PresentationScrollAnimator.progress(now: 1.05, startTime: 1, duration: 0.1)
        #expect(abs(mid - 0.5) < 1e-9)
    }

    @Test("zero duration is treated as complete")
    func zeroDurationComplete() {
        #expect(PresentationScrollAnimator.progress(now: 1, startTime: 1, duration: 0) == 1)
    }

    @Test("eased offset hits its endpoints exactly so the settle lands on the grid")
    func easedOffsetEndpoints() {
        // At progress 0 the full start offset is returned.
        #expect(PresentationScrollAnimator.easedOffset(startOffset: 12.5, progress: 0) == 12.5)
        #expect(PresentationScrollAnimator.easedOffset(startOffset: -7, progress: 0) == -7)
        // At progress 1 the offset is exactly 0 for any start value: always terminates on the grid.
        #expect(PresentationScrollAnimator.easedOffset(startOffset: 12.5, progress: 1) == 0)
        #expect(PresentationScrollAnimator.easedOffset(startOffset: -7, progress: 1) == 0)
        #expect(PresentationScrollAnimator.easedOffset(startOffset: 1234.5, progress: 1) == 0)
    }

    @Test("eased offset decays monotonically toward zero")
    func easedOffsetMonotonic() {
        let start: CGFloat = 20
        var previous = PresentationScrollAnimator.easedOffset(startOffset: start, progress: 0)
        var p: CGFloat = 0.05
        while p <= 1.0001 {
            let value = PresentationScrollAnimator.easedOffset(startOffset: start, progress: p)
            #expect(value <= previous)   // magnitude never increases for a positive start
            #expect(value >= 0)
            previous = value
            p += 0.05
        }
    }

    @Test("animator terminates exactly on the grid")
    func animatorTerminatesOnGrid() {
        var animator = PresentationScrollAnimator()
        animator.start(offset: 15, duration: 0.1, now: 0)
        #expect(animator.isActive)
        // Mid-flight the offset is between the start and the grid.
        let mid = animator.offset(now: 0.05)
        #expect(mid > 0 && mid < 15)
        #expect(animator.isActive)
        // Past the end it snaps to exactly 0 and deactivates.
        let end = animator.offset(now: 0.2)
        #expect(end == 0)
        #expect(!animator.isActive)
    }

    @Test("tiny offsets do not start an animation")
    func tinyOffsetNoAnimation() {
        var animator = PresentationScrollAnimator()
        animator.start(offset: 0.1, duration: 0.1, now: 0)
        #expect(!animator.isActive)
        #expect(animator.offset(now: 0.05) == 0)
    }

    @Test("cancel stops the animation without reporting an offset")
    func cancelStops() {
        var animator = PresentationScrollAnimator()
        animator.start(offset: 15, duration: 0.1, now: 0)
        animator.cancel()
        #expect(!animator.isActive)
        #expect(animator.offset(now: 0.05) == 0)
    }
}

@Suite("PresentationScrollAnimator rubber band")
struct PresentationScrollAnimatorRubberBandTests {

    @Test("rubber band passes through the origin")
    func passesThroughOrigin() {
        #expect(PresentationScrollAnimator.rubberBandOffset(rawDistance: 0, limit: 70) == 0)
    }

    @Test("rubber band is monotonic and bounded by the limit")
    func monotonicAndBounded() {
        let limit: CGFloat = 70 // ~3.5 cells at cellHeight 20
        var previous = PresentationScrollAnimator.rubberBandOffset(rawDistance: 0, limit: limit)
        var raw: CGFloat = 5
        while raw <= 2000 {
            let value = PresentationScrollAnimator.rubberBandOffset(rawDistance: raw, limit: limit)
            #expect(value > previous)      // strictly increasing with pull
            #expect(value < limit)         // never reaches the asymptote
            previous = value
            raw += 5
        }
        // A very large pull approaches but stays under the limit.
        let huge = PresentationScrollAnimator.rubberBandOffset(rawDistance: 100_000, limit: limit)
        #expect(huge < limit)
        #expect(huge > limit * 0.99)
    }

    @Test("rubber band is symmetric across the origin")
    func symmetric() {
        let limit: CGFloat = 70
        let positive = PresentationScrollAnimator.rubberBandOffset(rawDistance: 40, limit: limit)
        let negative = PresentationScrollAnimator.rubberBandOffset(rawDistance: -40, limit: limit)
        #expect(abs(positive + negative) < 1e-9)
    }

    @Test("inverse rubber band round-trips within the limit")
    func inverseRoundTrips() {
        let limit: CGFloat = 70
        for offset: CGFloat in [1, 5, 12.5, 30, 55] {
            let raw = PresentationScrollAnimator.inverseRubberBandDistance(offset: offset, limit: limit)
            let backToOffset = PresentationScrollAnimator.rubberBandOffset(rawDistance: raw, limit: limit)
            #expect(abs(backToOffset - offset) < 1e-6)
        }
    }
}
