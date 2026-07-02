import CoreGraphics
import QuartzCore

/// Pure state machine for a scrollbar thumb drag over a resident pane (#2665).
///
/// Bundles the drag's gate (`windowId`, fixed at drag start), the drag target, the per-frame
/// throttle bookkeeping, the release-time scroll-authority baselines, and the reconcile watchdog
/// into one value with a single clear path. `EditorNSView` owns an optional session and translates
/// its per-frame `Outcome` into encoder sends, the presentation offset, and redraw scheduling; the
/// session is free of AppKit / Metal / protocol IO so the whole state machine is unit-testable.
///
/// **Gate policy.** `windowId` and the resident-vs-windowed decision are fixed when the drag starts
/// (see `EditorNSView.beginThumbDragPresentation`) and are never re-evaluated. Residence is a
/// document-size property that does not flip mid-drag, and re-checking it would let a same-frame
/// residency change silently switch the gesture to the round-trip path. A residency change that
/// arrives mid-drag therefore leaves the gate intact; only an authoritative anchor move (interrupt)
/// or the reconcile completing tears the session down.
///
/// **No release animator.** The reconcile drains the offset by tracking the committed anchor, not by
/// easing on a timer. The BEAM echo-marks the drag's own commits, so the committed anchor lands
/// exactly on the target; easing a residual to zero would fight the authoritative-interrupt
/// discriminator (an eased offset would diverge from `target - anchorTop` and look like a jump).
struct ThumbDragSession {
    /// Committed scroll presentation observed for the dragged pane on a given frame.
    struct Committed: Equatable {
        let anchorTop: UInt32
        let scrollSeq: UInt32
        let contentEpoch: UInt32
        let layoutGeneration: UInt32

        init(anchorTop: UInt32, scrollSeq: UInt32, contentEpoch: UInt32, layoutGeneration: UInt32) {
            self.anchorTop = anchorTop
            self.scrollSeq = scrollSeq
            self.contentEpoch = contentEpoch
            self.layoutGeneration = layoutGeneration
        }
    }

    /// The per-frame decision the owner applies.
    struct Outcome: Equatable {
        /// A target line to send on the ordered channel this frame (throttled), or nil.
        var intent: UInt32?
        /// Signed line offset to present (multiplied by cell height by the owner).
        var offsetLines: Int64
        /// The session is done: the owner drops it and zeroes the offset.
        var finished: Bool
        /// The owner should schedule another frame.
        var needsRedraw: Bool
    }

    enum Phase: Equatable {
        /// Button held; the user is driving the target.
        case dragging
        /// Released; the local offset drains as the committed anchor catches up to the target.
        case reconciling
    }

    /// Reconcile watchdog deadline. A thumb-drag reconcile is a single BEAM round trip, so this is
    /// deliberately generous; it only fires when a stranding path stalls the reconcile (a dropped
    /// final flush under backpressure / disconnect, a vanished presentation) so the gate cannot stay
    /// open forever and keep suppressing the BEAM's own `onScrollPresentationReset` recovery signal.
    static let watchdogDeadline: CFTimeInterval = 0.5

    let windowId: UInt16
    private(set) var phase: Phase = .dragging
    private(set) var targetLine: UInt32
    private(set) var lastSentLine: UInt32?
    private(set) var pendingLine: UInt32?

    private var baselineScrollSeq: UInt32 = 0
    private var baselineContentEpoch: UInt32 = 0
    private var baselineLayoutGeneration: UInt32 = 0
    private var prevAnchorTop: UInt32 = 0
    private var releaseOffsetSign: Int = 0
    private var lastProgressTime: CFTimeInterval = 0

    /// While the button is held the drag owns scroll presentation: the owner ignores concurrent
    /// wheel input so the two do not fight over the offset. A post-release reconcile does not (the
    /// button is up, so a fresh wheel gesture supersedes it).
    var ownsScrollInput: Bool { phase == .dragging }

    /// Begins a drag. The first intent is `targetLine`, pending until the owner flushes it (either
    /// immediately for a responsive click via `takeIntent`, or on the next frame via `advance`).
    init(windowId: UInt16, targetLine: UInt32) {
        self.windowId = windowId
        self.targetLine = targetLine
        self.pendingLine = targetLine
    }

    /// Updates the drag target (mouse moved). No-op once reconciling.
    mutating func updateTarget(_ line: UInt32) {
        guard phase == .dragging else { return }
        targetLine = line
        pendingLine = line
    }

    /// Throttle flush: returns the pending target when it differs from the last sent, at most once
    /// per call, and records it as sent. Coalesces multiple updates per frame into one intent (AC4).
    mutating func takeIntent() -> UInt32? {
        guard let pending = pendingLine, pending != lastSentLine else {
            pendingLine = nil
            return nil
        }
        lastSentLine = pending
        pendingLine = nil
        return pending
    }

    /// Releases the drag: flushes any un-sent final target, captures the authority baselines from
    /// the committed frame, and enters the reconcile phase. Returns the final intent to send, if any.
    mutating func release(committed: Committed?, now: CFTimeInterval) -> UInt32? {
        let intent = takeIntent()
        phase = .reconciling
        if let c = committed {
            baselineScrollSeq = c.scrollSeq
            baselineContentEpoch = c.contentEpoch
            baselineLayoutGeneration = c.layoutGeneration
            prevAnchorTop = c.anchorTop
            releaseOffsetSign = Int((Int64(targetLine) - Int64(c.anchorTop)).signum())
        } else {
            releaseOffsetSign = 0
        }
        lastProgressTime = now
        return intent
    }

    /// Forced discard that never silently drops the dragged position: flushes the final target so
    /// the BEAM still commits it, then the owner drops the session. If the button is still held the
    /// remainder of the gesture degrades to the round-trip path (the owner sees no session). Used by
    /// mid-hold reset paths that must discard local presentation (Reduce Motion, window resign-key).
    mutating func cancelWithFlush() -> UInt32? {
        takeIntent()
    }

    /// Advances one frame. `buttonHeld` guards a lost mouseUp (button physically up, no event): a
    /// gesture stuck in `.dragging` with the button released is treated as a release this frame so
    /// the reconcile and watchdog can run.
    mutating func advance(committed: Committed?, now: CFTimeInterval, buttonHeld: Bool) -> Outcome {
        if phase == .dragging {
            if !buttonHeld {
                let intent = release(committed: committed, now: now)
                return reconcileOutcome(committed: committed, now: now, pendingIntent: intent)
            }
            let intent = takeIntent()
            guard let c = committed else {
                // Presentation vanished mid-drag: finish rather than leak the gate. The last sent
                // target (flushed above) preserves position on the round-trip path.
                return Outcome(intent: intent, offsetLines: 0, finished: true, needsRedraw: true)
            }
            return Outcome(intent: intent, offsetLines: Int64(targetLine) - Int64(c.anchorTop), finished: false, needsRedraw: true)
        }
        return reconcileOutcome(committed: committed, now: now, pendingIntent: nil)
    }

    private mutating func reconcileOutcome(committed: Committed?, now: CFTimeInterval, pendingIntent: UInt32?) -> Outcome {
        guard let c = committed else {
            // Presentation gone for a still-open drag: clear instead of leaking (Critical 1c).
            return Outcome(intent: pendingIntent, offsetLines: 0, finished: true, needsRedraw: true)
        }
        if Self.authoritativeInterrupt(
            baselineScrollSeq: baselineScrollSeq, nextScrollSeq: c.scrollSeq,
            baselineContentEpoch: baselineContentEpoch, nextContentEpoch: c.contentEpoch,
            baselineLayoutGeneration: baselineLayoutGeneration, nextLayoutGeneration: c.layoutGeneration,
            previousAnchorTop: prevAnchorTop, nextAnchorTop: c.anchorTop, targetLine: targetLine
        ) {
            return Outcome(intent: pendingIntent, offsetLines: 0, finished: true, needsRedraw: true)
        }
        if Self.madeProgress(previousAnchorTop: prevAnchorTop, nextAnchorTop: c.anchorTop, targetLine: targetLine) {
            lastProgressTime = now
        }
        prevAnchorTop = c.anchorTop
        let offsetLines = Int64(targetLine) - Int64(c.anchorTop)
        if Self.reconciled(offsetLines: offsetLines, releaseSign: releaseOffsetSign) {
            return Outcome(intent: pendingIntent, offsetLines: 0, finished: true, needsRedraw: false)
        }
        if Self.watchdogExpired(now: now, lastProgress: lastProgressTime, deadline: Self.watchdogDeadline) {
            return Outcome(intent: pendingIntent, offsetLines: 0, finished: true, needsRedraw: true)
        }
        return Outcome(intent: pendingIntent, offsetLines: offsetLines, finished: false, needsRedraw: true)
    }

    // MARK: - Pure decision helpers

    /// Whether the post-release reconcile has landed: the committed anchor reached the target
    /// (offset 0) or crossed it (sign flipped away from the release direction). The cross case
    /// guards against a frontend/BEAM clamp mismatch stranding a non-zero offset. Pure.
    nonisolated static func reconciled(offsetLines: Int64, releaseSign: Int) -> Bool {
        if offsetLines == 0 { return true }
        if releaseSign > 0 { return offsetLines < 0 }
        if releaseSign < 0 { return offsetLines > 0 }
        return true
    }

    /// Whether the post-release reconcile must bail out because an authoritative event landed
    /// instead of the expected echo commit.
    ///
    /// An echo commit (the drag's own `scroll_to_line`, echo-marked BEAM-side) keeps `scrollSeq`
    /// flat and steps `anchorTop` toward the target without touching the content epoch or layout
    /// generation. Anything else — a `scrollSeq` bump (jump / cursor re-anchor), a content-epoch or
    /// layout-generation change (edit / resize / full refresh), or an anchor move away from the
    /// target — is an out-of-band jump that must discard the local offset immediately, since the
    /// gesture gate suppresses the normal reset while a thumb drag owns the pane. Pure.
    nonisolated static func authoritativeInterrupt(
        baselineScrollSeq: UInt32, nextScrollSeq: UInt32,
        baselineContentEpoch: UInt32, nextContentEpoch: UInt32,
        baselineLayoutGeneration: UInt32, nextLayoutGeneration: UInt32,
        previousAnchorTop: UInt32, nextAnchorTop: UInt32,
        targetLine: UInt32
    ) -> Bool {
        if nextScrollSeq > baselineScrollSeq { return true }
        if nextContentEpoch != baselineContentEpoch { return true }
        if nextLayoutGeneration != baselineLayoutGeneration { return true }
        let toTarget = Int64(targetLine) - Int64(previousAnchorTop)
        let step = Int64(nextAnchorTop) - Int64(previousAnchorTop)
        if step == 0 { return false }
        // The anchor moved: an echo step goes toward the target. A step away (or any move once
        // already on the target) is an authoritative anchor change.
        if toTarget == 0 { return true }
        return (step > 0) != (toTarget > 0)
    }

    /// Whether the committed anchor stepped toward the target this frame (an echo commit landing).
    /// Used to keep the reconcile watchdog alive while the BEAM is still catching up. Pure.
    nonisolated static func madeProgress(previousAnchorTop: UInt32, nextAnchorTop: UInt32, targetLine: UInt32) -> Bool {
        let toTarget = Int64(targetLine) - Int64(previousAnchorTop)
        let step = Int64(nextAnchorTop) - Int64(previousAnchorTop)
        if step == 0 || toTarget == 0 { return false }
        return (step > 0) == (toTarget > 0)
    }

    /// Whether the reconcile watchdog deadline has elapsed since the last progress. Pure.
    nonisolated static func watchdogExpired(now: CFTimeInterval, lastProgress: CFTimeInterval, deadline: CFTimeInterval) -> Bool {
        now - lastProgress > deadline
    }
}
