/// Tests for gesture-end settle / discrete-tick reconciliation math (issue #2664).

import Testing
import Foundation
import CoreGraphics
import simd
import MingaProtocol

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

@Suite("Presentation offset reaches the settling pane (render-path gate)")
struct PresentationScrollWindowResolutionTests {

    @Test("live gesture target owns the offset")
    func livePreferred() {
        let resolved = EditorNSView.presentationScrollWindowId(targetWindowId: 3, thumbDragWindowId: 4, settleWindowId: 9, elasticWindowId: 8)
        #expect(resolved == 3)
    }

    @Test("thumb drag wins over settle and elastic when no trackpad gesture is live")
    func thumbDragPreferred() {
        let resolved = EditorNSView.presentationScrollWindowId(targetWindowId: nil, thumbDragWindowId: 4, settleWindowId: 9, elasticWindowId: 8)
        #expect(resolved == 4)
    }

    @Test("target nil falls back to the settling window so the settle stays visible")
    func settleFallback() {
        let resolved = EditorNSView.presentationScrollWindowId(targetWindowId: nil, thumbDragWindowId: nil, settleWindowId: 5, elasticWindowId: nil)
        #expect(resolved == 5)
        // The renderer gate applies the offset to exactly that pane, not to every window.
        let offset = SIMD2<Float>(0, 12)
        #expect(CoreTextMetalRenderer.smoothScrollOffset(for: 5, targetWindowId: resolved, scrollOffsetPx: offset) == offset)
        #expect(CoreTextMetalRenderer.smoothScrollOffset(for: 6, targetWindowId: resolved, scrollOffsetPx: offset) == .zero)
    }

    @Test("target nil and no settle falls back to the elastic spring-back window")
    func elasticFallback() {
        let resolved = EditorNSView.presentationScrollWindowId(targetWindowId: nil, thumbDragWindowId: nil, settleWindowId: nil, elasticWindowId: 7)
        #expect(resolved == 7)
    }

    @Test("all windows nil resolves to nil so the renderer zeroes the offset")
    func allNilZeroes() {
        let resolved = EditorNSView.presentationScrollWindowId(targetWindowId: nil, thumbDragWindowId: nil, settleWindowId: nil, elasticWindowId: nil)
        #expect(resolved == nil)
        // Mirrors the state after a discard cancels an in-flight settle: no pane shows the offset.
        #expect(CoreTextMetalRenderer.smoothScrollOffset(for: 5, targetWindowId: resolved, scrollOffsetPx: SIMD2<Float>(0, 12)) == .zero)
    }
}

@Suite("Scrollbar thumb-drag local presentation (issue #2665)")
struct ThumbDragPresentationTests {

    private func presentation(overscanStart: UInt32, overscanEnd: UInt32) -> GUIScrollPresentation {
        GUIScrollPresentation(
            windowId: 1, resetRequired: false, anchorTop: 0, anchorLeft: 0, anchorVisualRowOffset: 0,
            visibleStartLine: overscanStart, visibleEndLine: overscanEnd,
            overscanStartLine: overscanStart, overscanEndLine: overscanEnd,
            contentEpoch: 1, layoutGeneration: 1
        )
    }

    @Test("a resident pane (whole-document overscan) can present locally")
    func residentPresentsLocally() {
        // Overscan spans line 0 through totalLines: the whole document is resident.
        let sp = presentation(overscanStart: 0, overscanEnd: 1_000)
        #expect(EditorNSView.thumbDragCanPresentLocally(scrollPresentation: sp, totalLines: 1_000))
    }

    @Test("a windowed pane (partial band) keeps the round-trip path")
    func windowedStaysRoundTrip() {
        // A viewport-plus-overscan band that does not start at 0 or reach the end.
        let sp = presentation(overscanStart: 400, overscanEnd: 520)
        #expect(!EditorNSView.thumbDragCanPresentLocally(scrollPresentation: sp, totalLines: 1_000))
    }

    @Test("no presentation or empty document never presents locally")
    func degenerateNeverPresents() {
        #expect(!EditorNSView.thumbDragCanPresentLocally(scrollPresentation: nil, totalLines: 1_000))
        let sp = presentation(overscanStart: 0, overscanEnd: 0)
        #expect(!EditorNSView.thumbDragCanPresentLocally(scrollPresentation: sp, totalLines: 0))
    }

    @Test("presentation offset places the target line at the viewport top")
    func offsetPlacesTargetAtTop() {
        // Committed anchor at line 100, dragging to line 450, 18px cells: content shifts up 350 lines.
        let offset = EditorNSView.thumbDragPresentationOffsetY(targetLine: 450, committedAnchorTop: 100, cellHeight: 18)
        #expect(offset == CGFloat(350 * 18))
    }

    @Test("dragging above the committed anchor yields a negative (upward) offset")
    func offsetUpwardIsNegative() {
        let offset = EditorNSView.thumbDragPresentationOffsetY(targetLine: 40, committedAnchorTop: 100, cellHeight: 20)
        #expect(offset == CGFloat(-60 * 20))
    }

    @Test("offset is zero once the committed anchor reaches the target")
    func offsetZeroWhenCaughtUp() {
        #expect(EditorNSView.thumbDragPresentationOffsetY(targetLine: 300, committedAnchorTop: 300, cellHeight: 18) == 0)
    }

    @Test("a new target flushes at most one intent per frame")
    func throttleFlushesOncePerTarget() {
        // Pending differs from last-sent → flush this frame.
        #expect(EditorNSView.shouldFlushThumbDragIntent(pending: 42, lastSent: nil))
        #expect(EditorNSView.shouldFlushThumbDragIntent(pending: 42, lastSent: 10))
        // Already sent this target → no redundant intent.
        #expect(!EditorNSView.shouldFlushThumbDragIntent(pending: 42, lastSent: 42))
        // Nothing pending → nothing to send.
        #expect(!EditorNSView.shouldFlushThumbDragIntent(pending: nil, lastSent: 42))
    }

    @Test("reconcile lands when the committed anchor reaches the target after release")
    func reconcileLandsOnExactMatch() {
        // Released while dragging down (positive residual): lands at offset 0.
        #expect(EditorNSView.thumbDragReconciled(offsetLines: 0, releaseSign: 1))
        // Still catching up: not yet reconciled.
        #expect(!EditorNSView.thumbDragReconciled(offsetLines: 5, releaseSign: 1))
    }

    @Test("reconcile lands when the committed anchor overshoots the target (clamp-mismatch guard)")
    func reconcileLandsOnOvershoot() {
        // Released dragging down but the anchor committed past the target: sign flipped → land.
        #expect(EditorNSView.thumbDragReconciled(offsetLines: -2, releaseSign: 1))
        // Released dragging up but the anchor committed above the target: sign flipped → land.
        #expect(EditorNSView.thumbDragReconciled(offsetLines: 3, releaseSign: -1))
        // Released already on grid.
        #expect(EditorNSView.thumbDragReconciled(offsetLines: 0, releaseSign: 0))
    }

    // Baseline captured at release: seq 5, epoch 2, layout 1, dragging down toward line 100.
    private func interrupt(
        nextScrollSeq: UInt32 = 5, nextContentEpoch: UInt32 = 2, nextLayoutGeneration: UInt32 = 1,
        previousAnchorTop: UInt32 = 40, nextAnchorTop: UInt32
    ) -> Bool {
        EditorNSView.thumbDragAuthoritativeInterrupt(
            baselineScrollSeq: 5, nextScrollSeq: nextScrollSeq,
            baselineContentEpoch: 2, nextContentEpoch: nextContentEpoch,
            baselineLayoutGeneration: 1, nextLayoutGeneration: nextLayoutGeneration,
            previousAnchorTop: previousAnchorTop, nextAnchorTop: nextAnchorTop,
            targetLine: 100
        )
    }

    @Test("a scroll_seq bump mid-reconcile bails out even while the anchor looks like progress")
    func interruptOnSeqBump() {
        // Anchor stepping toward the target (echo-shaped) but seq advanced → authoritative jump.
        #expect(interrupt(nextScrollSeq: 6, nextAnchorTop: 55))
    }

    @Test("a non-crossing anchor jump away from the target mid-reconcile bails out")
    func interruptOnAnchorMovingAway() {
        // Seq/epoch flat, but the anchor moved backward (away from line 100): out-of-band scroll.
        #expect(interrupt(previousAnchorTop: 40, nextAnchorTop: 30))
        // Already on the target, then the anchor moves at all → authoritative.
        #expect(interrupt(previousAnchorTop: 100, nextAnchorTop: 98))
    }

    @Test("a content-epoch or layout-generation change mid-reconcile bails out")
    func interruptOnEpochOrLayoutChange() {
        #expect(interrupt(nextContentEpoch: 3, nextAnchorTop: 55))
        #expect(interrupt(nextLayoutGeneration: 2, nextAnchorTop: 55))
    }

    @Test("normal echo progress toward the target never bails out (release stays seamless)")
    func noInterruptOnEchoProgress() {
        // Seq/epoch/layout flat and the anchor stepping toward the target: the happy path.
        #expect(!interrupt(previousAnchorTop: 40, nextAnchorTop: 55))
        #expect(!interrupt(previousAnchorTop: 55, nextAnchorTop: 88))
        // Anchor unchanged this frame (no BEAM commit yet) is not an interrupt.
        #expect(!interrupt(previousAnchorTop: 55, nextAnchorTop: 55))
        // Reaching the target exactly is progress, not an interrupt (reconcile then clears it).
        #expect(!interrupt(previousAnchorTop: 90, nextAnchorTop: 100))
        // Overshooting the target is a crossing, handled by the reconcile, not an interrupt.
        #expect(!interrupt(previousAnchorTop: 90, nextAnchorTop: 105))
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
