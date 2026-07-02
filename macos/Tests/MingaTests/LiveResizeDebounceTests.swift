import Testing
import Foundation
import MingaUI

/// Tests for the pure live-resize debounce decision and the crop-fill guarantee (#2655).
@Suite("Live-resize presentation (#2655)")
struct LiveResizeDebounceTests {
    private let config = LiveResizeDebounce.Config(interval: 0.075, maxWait: 0.25)

    /// Unwraps a `.deferUntil` deadline, failing the test on `.flushNow`.
    private func deadline(_ decision: LiveResizeDebounce.Decision) -> TimeInterval? {
        if case .deferUntil(let d) = decision { return d }
        return nil
    }

    @Test("first event of a burst defers a pure trailing interval")
    func firstEventDefersTrailing() {
        let decision = LiveResizeDebounce.onResize(now: 100.0, firstPendingAt: nil, config: config)
        let d = try? #require(deadline(decision))
        #expect(abs((d ?? 0) - 100.075) < 1e-9)
    }

    @Test("a rapid follow-up event pushes the trailing edge out, still under the cap")
    func rapidEventExtendsTrailing() {
        // Burst started at 100.0; a second event 50ms in. Trailing edge 100.125 is
        // still well under the 100.25 max-wait cap, so it wins.
        let decision = LiveResizeDebounce.onResize(now: 100.05, firstPendingAt: 100.0, config: config)
        let d = try? #require(deadline(decision))
        #expect(abs((d ?? 0) - 100.125) < 1e-9)
    }

    @Test("the trailing edge is clamped to the max-wait cap during a continuous drag")
    func trailingClampedToCap() {
        // 200ms into the burst: raw trailing edge 100.275 would exceed the cap, so the
        // deadline is pinned to firstPendingAt + maxWait = 100.25. This is what bounds
        // re-layout rate during a never-pausing drag (AC3).
        let decision = LiveResizeDebounce.onResize(now: 100.2, firstPendingAt: 100.0, config: config)
        let d = try? #require(deadline(decision))
        #expect(abs((d ?? 0) - 100.25) < 1e-9)
    }

    @Test("once the max-wait cap is reached the event flushes immediately")
    func capReachedFlushesNow() {
        let atCap = LiveResizeDebounce.onResize(now: 100.25, firstPendingAt: 100.0, config: config)
        #expect(atCap == .flushNow)

        let pastCap = LiveResizeDebounce.onResize(now: 100.26, firstPendingAt: 100.0, config: config)
        #expect(pastCap == .flushNow)
    }

    @Test("a 3s continuous 60Hz drag is bounded by the debounce rate, not the event rate")
    func continuousDragBoundedByDebounceRate() {
        // Replay a 3-second drag at 60Hz (one resize event every ~16.7ms), feeding the
        // decision the same way EditorNSView does: a flush resets the burst start to nil.
        // Count flushes; they must be bounded by ceil(3.0 / maxWait), far below 180 events.
        var firstPendingAt: TimeInterval? = nil
        var flushes = 0
        let start = 0.0
        let step = 1.0 / 60.0
        var t = start
        while t <= start + 3.0 + 1e-9 {
            switch LiveResizeDebounce.onResize(now: t, firstPendingAt: firstPendingAt, config: config) {
            case .flushNow:
                flushes += 1
                firstPendingAt = nil // flush clears the burst; next event restarts it
            case .deferUntil:
                if firstPendingAt == nil { firstPendingAt = t }
            }
            t += step
        }

        let eventCount = 181 // ~3s at 60Hz
        let bound = Int((3.0 / config.maxWait).rounded(.up)) + 1
        #expect(flushes <= bound)
        #expect(flushes < eventCount / 4) // dramatically fewer re-layouts than raw events
    }

    // MARK: - Pending-grid bookkeeping

    private func grid(_ cols: UInt16, _ rows: UInt16) -> LiveResizeBookkeeping.Grid {
        LiveResizeBookkeeping.Grid(cols: cols, rows: rows)
    }

    @Test("a normal drag defers, then the end-of-drag flush commits the pending grid")
    func normalDragDefersThenFlushes() {
        var bk = LiveResizeBookkeeping()
        let g0 = grid(100, 50) // committed
        let g1 = grid(80, 50)  // dragged-to

        let frame = bk.onFrame(live: g1, committed: g0, now: 0.0, config: config)
        #expect(frame == .schedule(0.075))
        #expect(bk.pending == g1)

        // viewDidEndLiveResize path: flush against the still-committed g0.
        #expect(bk.takeFlush(committed: g0) == g1)
        #expect(bk.pending == nil)
    }

    @Test("drag-away-and-back drops the pending grid so no stale resize is committed")
    func dragAwayAndBackCancelsPending() {
        var bk = LiveResizeBookkeeping()
        let g0 = grid(100, 50) // committed (frameState never moved during pure defer)
        let g1 = grid(80, 50)  // dragged away

        // 1) Drag away: g1 is pending.
        #expect(bk.onFrame(live: g1, committed: g0, now: 0.0, config: config) == .schedule(0.075))
        #expect(bk.pending == g1)

        // 2) Drag back so the live grid equals the committed grid within the trailing window.
        //    This must drop the pending g1, otherwise a later flush would send g1 for a g0 window.
        #expect(bk.onFrame(live: g0, committed: g0, now: 0.02, config: config) == .cancelPending)
        #expect(bk.pending == nil)
        #expect(bk.firstPendingAt == nil)

        // 3) Release: nothing pending, so no resize is committed.
        #expect(bk.takeFlush(committed: g0) == nil)
    }

    @Test("returning to the committed grid with nothing pending is a no-op")
    func returnToCommittedWithoutPendingIsNoop() {
        var bk = LiveResizeBookkeeping()
        let g0 = grid(100, 50)
        #expect(bk.onFrame(live: g0, committed: g0, now: 0.0, config: config) == .noop)
        #expect(bk.pending == nil)
    }

    @Test("the max-wait cap flushes the latest grid immediately and clears pending")
    func maxWaitCapFlushesLatest() {
        var bk = LiveResizeBookkeeping()
        let g0 = grid(100, 50)

        // Burst starts at t=0.
        #expect(bk.onFrame(live: grid(90, 50), committed: g0, now: 0.0, config: config) == .schedule(0.075))
        // 260ms in: past the 250ms cap → flush the newest grid now, pending cleared.
        let latest = grid(70, 50)
        #expect(bk.onFrame(live: latest, committed: g0, now: 0.26, config: config) == .flushNow(latest))
        #expect(bk.pending == nil)
        #expect(bk.firstPendingAt == nil)
    }

    @Test("takeFlush is a no-op when the pending grid already matches the committed grid")
    func takeFlushNoopWhenPendingMatchesCommitted() {
        var bk = LiveResizeBookkeeping()
        let g0 = grid(100, 50)
        _ = bk.onFrame(live: grid(80, 50), committed: g0, now: 0.0, config: config)
        // The BEAM committed g0-equivalent out from under us before release.
        #expect(bk.takeFlush(committed: grid(80, 50)) == nil)
    }

    // MARK: - Crop-fill guarantee

    @Test("growing the window mid-drag fills the newly exposed region below the committed rows")
    func grownRegionIsFilledDuringCrop() {
        // During a live drag the frontend keeps rendering the last committed frame while
        // the drawable grows. frameState still holds the committed (smaller) grid, so the
        // bottom-most pane's background fill must absorb the grown region down to the new
        // drawable height, leaving no blank band (AC1: no blank regions during the drag).
        let committedRows = 20
        let displayCellH: Float = 12
        let committedHeight = Float(committedRows) * displayCellH // 240px committed
        let grownHeight = committedHeight + 90                    // window dragged 90px taller

        let fill = CoreTextMetalRenderer.windowBackgroundFillBounds(
            paneTopRow: 0,
            paneRows: committedRows,
            totalRows: committedRows,
            displayCellH: displayCellH,
            scale: 1,
            viewportHeight: grownHeight
        )

        #expect(fill?.top == 0)
        // The fill reaches the grown drawable edge, not just the committed content bottom.
        #expect(fill?.bottom == grownHeight)
        #expect((fill?.bottom ?? 0) > committedHeight)
    }
}
