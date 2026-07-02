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

    @Test("reconcile lands when the committed anchor reaches the target after release")
    func reconcileLandsOnExactMatch() {
        // Released while dragging down (positive residual): lands at offset 0.
        #expect(ThumbDragSession.reconciled(offsetLines: 0, releaseSign: 1))
        // Still catching up: not yet reconciled.
        #expect(!ThumbDragSession.reconciled(offsetLines: 5, releaseSign: 1))
    }

    @Test("reconcile lands when the committed anchor overshoots the target (clamp-mismatch guard)")
    func reconcileLandsOnOvershoot() {
        // Released dragging down but the anchor committed past the target: sign flipped → land.
        #expect(ThumbDragSession.reconciled(offsetLines: -2, releaseSign: 1))
        // Released dragging up but the anchor committed above the target: sign flipped → land.
        #expect(ThumbDragSession.reconciled(offsetLines: 3, releaseSign: -1))
        // Released already on grid.
        #expect(ThumbDragSession.reconciled(offsetLines: 0, releaseSign: 0))
    }

    // Baseline captured at release: seq 5, epoch 2, layout 1, dragging down toward line 100.
    private func interrupt(
        nextScrollSeq: UInt32 = 5, nextContentEpoch: UInt32 = 2, nextLayoutGeneration: UInt32 = 1,
        previousAnchorTop: UInt32 = 40, nextAnchorTop: UInt32
    ) -> Bool {
        ThumbDragSession.authoritativeInterrupt(
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

    @Test("progress tracks only steps toward the target (feeds the watchdog)")
    func madeProgressDirectionality() {
        #expect(ThumbDragSession.madeProgress(previousAnchorTop: 40, nextAnchorTop: 55, targetLine: 100))
        #expect(!ThumbDragSession.madeProgress(previousAnchorTop: 40, nextAnchorTop: 30, targetLine: 100))
        #expect(!ThumbDragSession.madeProgress(previousAnchorTop: 55, nextAnchorTop: 55, targetLine: 100))
        #expect(!ThumbDragSession.madeProgress(previousAnchorTop: 100, nextAnchorTop: 100, targetLine: 100))
    }

    @Test("watchdog expiry is a simple deadline since last progress")
    func watchdogDeadline() {
        #expect(!ThumbDragSession.watchdogExpired(now: 1.0, lastProgress: 0.8, deadline: 0.5))
        #expect(ThumbDragSession.watchdogExpired(now: 1.4, lastProgress: 0.8, deadline: 0.5))
    }
}

@Suite("Thumb-drag session state machine (issue #2665)")
struct ThumbDragSessionTests {

    private func committed(
        anchorTop: UInt32, scrollSeq: UInt32 = 5, contentEpoch: UInt32 = 2, layoutGeneration: UInt32 = 1
    ) -> ThumbDragSession.Committed {
        ThumbDragSession.Committed(anchorTop: anchorTop, scrollSeq: scrollSeq, contentEpoch: contentEpoch, layoutGeneration: layoutGeneration)
    }

    @Test("release-flush / throttle interaction: coalesce to one intent per frame, flush the final")
    func throttleAndReleaseFlush() {
        var s = ThumbDragSession(windowId: 1, targetLine: 10)
        // First intent (the click) flushes immediately, un-throttled.
        #expect(s.takeIntent() == 10)
        #expect(s.takeIntent() == nil)
        // Several drag updates within one frame coalesce to the last target.
        s.updateTarget(11)
        s.updateTarget(12)
        s.updateTarget(13)
        #expect(s.takeIntent() == 13)
        #expect(s.takeIntent() == nil)
        // A newer un-sent target at release is flushed so the final position is never dropped.
        s.updateTarget(20)
        #expect(s.release(committed: committed(anchorTop: 5), now: 0) == 20)
        #expect(s.phase == .reconciling)
        // No further intents once reconciling.
        s.updateTarget(30)
        #expect(s.takeIntent() == nil)
    }

    @Test("gate persists across normal frames while dragging (residency decided at start, not re-checked)")
    func gatePersistsWhileDragging() {
        var s = ThumbDragSession(windowId: 7, targetLine: 100)
        _ = s.takeIntent()
        // Many ordinary frames arrive; the session keeps its gate and tracks the offset.
        for anchor: UInt32 in [40, 50, 60] {
            let out = s.advance(committed: committed(anchorTop: anchor), now: 0, buttonHeld: true)
            #expect(!out.finished)
            #expect(out.offsetLines == Int64(100) - Int64(anchor))
        }
        #expect(s.phase == .dragging)
    }

    @Test("residency lost mid-drag (presentation nil) finishes instead of leaking the gate")
    func residencyLostMidDragFinishes() {
        var s = ThumbDragSession(windowId: 1, targetLine: 100)
        _ = s.takeIntent()
        let out = s.advance(committed: nil, now: 0, buttonHeld: true)
        #expect(out.finished)
        #expect(out.offsetLines == 0)
    }

    @Test("a BEAM jump landing while dragging is suppressed (live drag keeps presenting)")
    func liveDragSuppressesAuthoritativeJump() {
        var s = ThumbDragSession(windowId: 1, targetLine: 100)
        _ = s.takeIntent()
        // A seq bump / backward anchor jump mid-hold would interrupt a reconcile, but during the
        // live drag the offset keeps tracking (interrupt only runs post-release).
        let out = s.advance(committed: committed(anchorTop: 20, scrollSeq: 99), now: 0, buttonHeld: true)
        #expect(!out.finished)
        #expect(out.offsetLines == 80)
        #expect(s.phase == .dragging)
    }

    @Test("wheel ownership: the drag owns scroll input only while the button is held")
    func ownsScrollInputWhileDragging() {
        var s = ThumbDragSession(windowId: 1, targetLine: 100)
        #expect(s.ownsScrollInput)
        _ = s.release(committed: committed(anchorTop: 40), now: 0)
        #expect(!s.ownsScrollInput)
    }

    @Test("happy-path release reconcile drains to grid without a premature finish")
    func happyPathReleaseReconcile() {
        var s = ThumbDragSession(windowId: 1, targetLine: 100)
        #expect(s.takeIntent() == 100)
        // Release with the committed anchor still lagging at 40.
        #expect(s.release(committed: committed(anchorTop: 40), now: 0) == nil)
        // Echo commits step the anchor toward the target; the offset drains and never finishes early.
        let f1 = s.advance(committed: committed(anchorTop: 70), now: 0.01, buttonHeld: false)
        #expect(!f1.finished)
        #expect(f1.offsetLines == 30)
        // The final echo lands exactly on the target: offset 0, finished, no settle-jump.
        let f2 = s.advance(committed: committed(anchorTop: 100), now: 0.02, buttonHeld: false)
        #expect(f2.finished)
        #expect(f2.offsetLines == 0)
    }

    @Test("lost mouseUp: a button-up frame in the dragging phase releases and reconciles")
    func lostMouseUpReleasesAndReconciles() {
        var s = ThumbDragSession(windowId: 1, targetLine: 100)
        _ = s.takeIntent()
        // No mouseUp arrived, but the button is physically up: advance treats it as a release.
        let out = s.advance(committed: committed(anchorTop: 40), now: 0, buttonHeld: false)
        #expect(s.phase == .reconciling)
        #expect(!out.finished)
        #expect(out.offsetLines == 60)
        // The anchor then reaches the target and the reconcile lands.
        let done = s.advance(committed: committed(anchorTop: 100), now: 0.01, buttonHeld: false)
        #expect(done.finished)
    }

    @Test("reconcile watchdog clears a stranded drag when no progress arrives (dropped final flush)")
    func watchdogClearsStrandedReconcile() {
        var s = ThumbDragSession(windowId: 1, targetLine: 100)
        _ = s.takeIntent()
        _ = s.release(committed: committed(anchorTop: 40), now: 0)
        // The final flush was dropped (disconnected port / backpressure): the anchor never moves.
        let within = s.advance(committed: committed(anchorTop: 40), now: 0.1, buttonHeld: false)
        #expect(!within.finished)
        // After the watchdog deadline with no progress, the drag clears so the gate cannot stay open.
        let expired = s.advance(committed: committed(anchorTop: 40), now: ThumbDragSession.watchdogDeadline + 0.1, buttonHeld: false)
        #expect(expired.finished)
        #expect(expired.offsetLines == 0)
    }

    @Test("an authoritative interrupt post-release finishes immediately (discard wins)")
    func authoritativeInterruptFinishes() {
        var s = ThumbDragSession(windowId: 1, targetLine: 100)
        _ = s.takeIntent()
        _ = s.release(committed: committed(anchorTop: 40, scrollSeq: 5), now: 0)
        // A seq bump lands mid-reconcile: finish now so the BEAM's discard wins.
        let out = s.advance(committed: committed(anchorTop: 55, scrollSeq: 6), now: 0.01, buttonHeld: false)
        #expect(out.finished)
        #expect(out.offsetLines == 0)
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
