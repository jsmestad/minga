/// Tests for gesture-end settle / discrete-tick reconciliation math (issue #2664).

import Testing
import Foundation
import CoreGraphics
import simd

@Suite("Scroll settle unconfirmed-line reconciliation")
struct ScrollSettleReconcileTests {

    @Test("no anchor delta leaves the prediction untouched")
    func noDelta() {
        #expect(EditorNSView.reconciledUnconfirmedLines(current: 3, anchorDelta: 0) == 3)
        #expect(EditorNSView.reconciledUnconfirmedLines(current: -2, anchorDelta: 0) == -2)
    }

    @Test("a matching commit brings the prediction to zero")
    func matchingCommit() {
        #expect(EditorNSView.reconciledUnconfirmedLines(current: 3, anchorDelta: 3) == 0)
        #expect(EditorNSView.reconciledUnconfirmedLines(current: -2, anchorDelta: -2) == 0)
    }

    @Test("a partial commit reduces the prediction toward zero")
    func partialCommit() {
        #expect(EditorNSView.reconciledUnconfirmedLines(current: 3, anchorDelta: 1) == 2)
        #expect(EditorNSView.reconciledUnconfirmedLines(current: -3, anchorDelta: -1) == -2)
    }

    @Test("an overshooting commit clamps to zero instead of flipping sign")
    func overshootClamps() {
        // A BEAM jump larger than the prediction (e.g. ctrl-d racing a settle) must not
        // invert the prediction and animate the wrong way; it clamps to the grid.
        #expect(EditorNSView.reconciledUnconfirmedLines(current: 2, anchorDelta: 5) == 0)
        #expect(EditorNSView.reconciledUnconfirmedLines(current: -2, anchorDelta: -5) == 0)
    }
}

@Suite("Discrete-tick easing converges to the committed anchor")
struct DiscreteTickEasingTests {

    /// Rendered presentation offset during a discrete tick: the decaying residual plus the
    /// whole-line prediction still awaiting the BEAM's committed anchor.
    private func renderedOffset(residualStart: CGFloat, unconfirmed: Int, cellHeight: CGFloat, progress: CGFloat) -> CGFloat {
        PresentationScrollAnimator.easedOffset(startOffset: residualStart, progress: progress)
            + CGFloat(unconfirmed) * cellHeight
    }

    @Test("a one-line tick starts at rest and slides exactly one line")
    func slidesOneLine() {
        let cell: CGFloat = 20
        // Seed: predict +1 line (scroll down), residual = -cell so the content starts unmoved.
        let residualStart = -cell
        let unconfirmed = 1

        // At the first frame the content is still at its old position (no jump).
        let atStart = renderedOffset(residualStart: residualStart, unconfirmed: unconfirmed, cellHeight: cell, progress: 0)
        #expect(atStart == 0)

        // As the residual decays (before the anchor commits) it slides toward one full line.
        let atEnd = renderedOffset(residualStart: residualStart, unconfirmed: unconfirmed, cellHeight: cell, progress: 1)
        #expect(atEnd == cell)
    }

    @Test("the slide is monotonic toward the target line")
    func monotonicSlide() {
        let cell: CGFloat = 20
        var previous = renderedOffset(residualStart: -cell, unconfirmed: 1, cellHeight: cell, progress: 0)
        var p: CGFloat = 0.05
        while p <= 1.0001 {
            let value = renderedOffset(residualStart: -cell, unconfirmed: 1, cellHeight: cell, progress: p)
            #expect(value >= previous)
            #expect(value <= cell + 1e-9)
            previous = value
            p += 0.05
        }
    }

    @Test("once the anchor commits, the offset rests exactly on the grid")
    func restsOnGrid() {
        let cell: CGFloat = 20
        // The BEAM commits the predicted line: reconcile to zero unconfirmed lines.
        let unconfirmedAfterCommit = EditorNSView.reconciledUnconfirmedLines(current: 1, anchorDelta: 1)
        #expect(unconfirmedAfterCommit == 0)
        // With the residual fully decayed and the anchor committed, the presentation is on the grid.
        let rested = renderedOffset(residualStart: -cell, unconfirmed: unconfirmedAfterCommit, cellHeight: cell, progress: 1)
        #expect(rested == 0)
    }

    @Test("a scroll-up tick slides the opposite direction and still rests on the grid")
    func scrollUpRestsOnGrid() {
        let cell: CGFloat = 20
        // Scroll up: predict -1 line, residual = +cell.
        let atStart = renderedOffset(residualStart: cell, unconfirmed: -1, cellHeight: cell, progress: 0)
        #expect(atStart == 0)
        let atEnd = renderedOffset(residualStart: cell, unconfirmed: -1, cellHeight: cell, progress: 1)
        #expect(atEnd == -cell)
        let unconfirmedAfterCommit = EditorNSView.reconciledUnconfirmedLines(current: -1, anchorDelta: -1)
        let rested = renderedOffset(residualStart: cell, unconfirmed: unconfirmedAfterCommit, cellHeight: cell, progress: 1)
        #expect(rested == 0)
    }
}

@Suite("Momentum resume restores the tentative-settle residual (no handoff hitch)")
struct MomentumResumeResidualTests {

    /// Composed fractional offset the renderer would show: accumulator residual plus the
    /// unconfirmed-line compensation. (Elastic is 0 during an ordinary in-content settle.)
    private func composedOffset(pixelOffsetY: CGFloat, unconfirmed: Int, cellHeight: CGFloat) -> CGFloat {
        pixelOffsetY + CGFloat(unconfirmed) * cellHeight
    }

    @Test("a live sub-cell residual is handed back so momentum continues from it")
    func restoresSubCellResidual() {
        let cell: CGFloat = 16
        // Finger-lift: tentative settle active carrying an 11pt residual (barely decayed).
        let residual = EditorNSView.momentumResumeAccumulatorResidual(settleActive: true, settleOffset: 11, cellHeight: cell)
        #expect(residual == 11)

        // Without the restore the accumulator would start at 0 and the first momentum frame would
        // render the fractional short by the whole residual: a backward hitch.
        let unconfirmed = 2
        let lastLive = composedOffset(pixelOffsetY: 11, unconfirmed: unconfirmed, cellHeight: cell)

        // With the restore, seed the accumulator, then apply the first momentum delta (4pt down).
        var acc = ScrollAccumulator()
        acc.pixelOffsetY = residual!
        let events = acc.accumulateVertical(deltaY: -4, cellHeight: cell) // down = content up
        #expect(events.isEmpty) // 11 + 4 = 15 stays within the current cell
        let firstMomentum = composedOffset(pixelOffsetY: acc.pixelOffsetY, unconfirmed: unconfirmed, cellHeight: cell)

        // The offset advances forward by exactly the momentum delta: no backward jump.
        #expect(firstMomentum == lastLive + 4)
        #expect(firstMomentum > lastLive)
    }

    @Test("crossing a cell boundary during resume emits the line event at the true position")
    func restoreKeepsBoundaryAligned() {
        let cell: CGFloat = 16
        let residual = EditorNSView.momentumResumeAccumulatorResidual(settleActive: true, settleOffset: 12, cellHeight: cell)!
        var acc = ScrollAccumulator()
        acc.pixelOffsetY = residual
        // A 6pt down delta pushes 12 + 6 = 18 across the 16pt boundary: exactly one line event,
        // remainder 2pt. Restarting from 0 would have needed 16pt to cross, mis-timing the report.
        let events = acc.accumulateVertical(deltaY: -6, cellHeight: cell)
        #expect(events == [.scrollDown])
        #expect(abs(acc.pixelOffsetY - 2) < 1e-9)
    }

    @Test("no active settle hands back nothing")
    func inactiveSettleReturnsNil() {
        #expect(EditorNSView.momentumResumeAccumulatorResidual(settleActive: false, settleOffset: 8, cellHeight: 16) == nil)
    }

    @Test("a discrete-tick settle offset is out of range and is not handed back")
    func discreteResidualRejected() {
        let cell: CGFloat = 16
        // A discrete down-tick seeds residual near -cell; an up-tick near +cell. Both must be
        // rejected so momentum resume never pushes the accumulator across a boundary spuriously.
        #expect(EditorNSView.momentumResumeAccumulatorResidual(settleActive: true, settleOffset: -cell, cellHeight: cell) == nil)
        #expect(EditorNSView.momentumResumeAccumulatorResidual(settleActive: true, settleOffset: cell, cellHeight: cell) == nil)
        #expect(EditorNSView.momentumResumeAccumulatorResidual(settleActive: true, settleOffset: cell + 3, cellHeight: cell) == nil)
    }

    @Test("a zero cell height is rejected")
    func zeroCellRejected() {
        #expect(EditorNSView.momentumResumeAccumulatorResidual(settleActive: true, settleOffset: 0, cellHeight: 0) == nil)
    }
}

@Suite("Presentation offset reaches the settling pane (render-path gate)")
struct PresentationScrollWindowResolutionTests {

    @Test("live gesture target owns the offset")
    func livePreferred() {
        let resolved = EditorNSView.presentationScrollWindowId(targetWindowId: 3, settleWindowId: 9, elasticWindowId: 8)
        #expect(resolved == 3)
    }

    @Test("target nil falls back to the settling window so the settle stays visible")
    func settleFallback() {
        let resolved = EditorNSView.presentationScrollWindowId(targetWindowId: nil, settleWindowId: 5, elasticWindowId: nil)
        #expect(resolved == 5)
        // The renderer gate applies the offset to exactly that pane, not to every window.
        let offset = SIMD2<Float>(0, 12)
        #expect(CoreTextMetalRenderer.smoothScrollOffset(for: 5, targetWindowId: resolved, scrollOffsetPx: offset) == offset)
        #expect(CoreTextMetalRenderer.smoothScrollOffset(for: 6, targetWindowId: resolved, scrollOffsetPx: offset) == .zero)
    }

    @Test("target nil and no settle falls back to the elastic spring-back window")
    func elasticFallback() {
        let resolved = EditorNSView.presentationScrollWindowId(targetWindowId: nil, settleWindowId: nil, elasticWindowId: 7)
        #expect(resolved == 7)
    }

    @Test("all windows nil resolves to nil so the renderer zeroes the offset")
    func allNilZeroes() {
        let resolved = EditorNSView.presentationScrollWindowId(targetWindowId: nil, settleWindowId: nil, elasticWindowId: nil)
        #expect(resolved == nil)
        // Mirrors the state after a discard cancels an in-flight settle: no pane shows the offset.
        #expect(CoreTextMetalRenderer.smoothScrollOffset(for: 5, targetWindowId: resolved, scrollOffsetPx: SIMD2<Float>(0, 12)) == .zero)
    }
}

@Suite("Settle state clears when its pane closes (cleanup guard)")
struct PresentationScrollCleanupGuardTests {

    @Test("no presentation windows means nothing to clean up")
    func noneToClean() {
        #expect(EditorNSView.missingPresentationWindow(candidateWindowIds: [nil, nil, nil], availableWindowIds: [1, 2]) == false)
    }

    @Test("a present settle window is not treated as missing")
    func settleWindowPresent() {
        // target nil (settling), settle window 2 still live.
        #expect(EditorNSView.missingPresentationWindow(candidateWindowIds: [nil, 2, nil], availableWindowIds: [1, 2]) == false)
    }

    @Test("a settle window that closed mid-settle is detected as missing")
    func settleWindowClosed() {
        // The settling pane 9 is gone from the live set: the guard must reset.
        #expect(EditorNSView.missingPresentationWindow(candidateWindowIds: [nil, 9, nil], availableWindowIds: [1, 2]) == true)
    }

    @Test("a closed elastic spring-back window is detected as missing")
    func elasticWindowClosed() {
        #expect(EditorNSView.missingPresentationWindow(candidateWindowIds: [nil, nil, 4], availableWindowIds: [1, 2]) == true)
    }
}
