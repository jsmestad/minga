import Testing
import Foundation
import AppKit
import MingaUI
import MingaProtocol

/// Tests for the pure live-resize debounce decision and the crop-fill guarantee (#2655).
@Suite("Live-resize presentation (#2655)")
struct LiveResizeDebounceTests {
    // The production tuning, not a copy: a retune cannot silently desync the suite.
    private let config = LiveResizeDebounce.Config.liveResize

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

    @Test("drag-away-and-back-and-away-again restarts the max-wait clock from the second departure")
    func dragAwayBackAwayRestartsBurstClock() {
        var bk = LiveResizeBookkeeping()
        let g0 = grid(100, 50)

        // First departure at t=0 starts a burst.
        #expect(bk.onFrame(live: grid(80, 50), committed: g0, now: 0.0, config: config) == .schedule(0.075))
        // Back to committed at t=0.02 cancels it entirely.
        #expect(bk.onFrame(live: g0, committed: g0, now: 0.02, config: config) == .cancelPending)
        // Second departure at t=0.03 must start a FRESH burst: trailing edge from the new
        // now (0.105), not clamped against the stale t=0 burst start. A regression that
        // fails to reset the burst clock on cancel would fire the max-wait cap early here.
        #expect(bk.onFrame(live: grid(70, 50), committed: g0, now: 0.03, config: config) == .schedule(0.105))
        #expect(bk.firstPendingAt == 0.03)
    }

    @Test("a trailing flush mid-pause commits, then a resumed drag opens a fresh burst")
    func trailingFlushMidPauseThenResumedDrag() {
        var bk = LiveResizeBookkeeping()
        var committed = grid(100, 50)
        let g1 = grid(80, 50)

        // Drag, then pause: the trailing timer fires and takes the flush while the live
        // resize is still in progress (user is holding the edge, not moving).
        #expect(bk.onFrame(live: g1, committed: committed, now: 0.0, config: config) == .schedule(0.075))
        #expect(bk.takeFlush(committed: committed) == g1)
        committed = g1 // sendLiveResize applied the viewport resize

        // Drag resumes 200ms later: a genuinely fresh burst against the new committed
        // grid, with the max-wait cap anchored at the resumed time.
        let g2 = grid(60, 50)
        #expect(bk.onFrame(live: g2, committed: committed, now: 0.2, config: config) == .schedule(0.275))
        #expect(bk.firstPendingAt == 0.2)

        // Release commits the second burst's grid.
        #expect(bk.takeFlush(committed: committed) == g2)
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

/// Integration tests for the EditorNSView live-resize wiring: the exactly-once flush and
/// the gesture teardown at resize start. These drive the real view methods headlessly
/// (viewWillStartLiveResize / flushPendingResize are plain overrides/internal methods),
/// pinning the guarantees the pure state machine alone cannot: Task bookkeeping, encoder
/// sends, and the press-release contract with the BEAM.
@Suite("Live-resize view wiring (#2655)")
struct LiveResizeWiringTests {
    @MainActor
    private func makeView(spy: SpyEncoder) -> EditorNSView? {
        let face = FontFace(name: "Menlo", size: 13.0, scale: 1.0)
        let fm = FontManager(name: "Menlo", size: 13.0, scale: 1.0)
        let guiState = GUIState()
        let disp = CommandDispatcher(cols: 80, rows: 24, guiState: guiState)
        guard let ctRenderer = CoreTextMetalRenderer() else { return nil }
        ctRenderer.setupRenderers(fontManager: fm)
        let view = EditorNSView(encoder: spy, fontFace: face, dispatcher: disp,
                                coreTextRenderer: ctRenderer, fontManager: fm)
        view.editorInput = guiState.editorInput
        view.frame = NSRect(x: 0, y: 0,
                            width: CGFloat(face.cellWidth) * 80,
                            height: CGFloat(face.cellHeight) * 24)
        return view
    }

    @MainActor
    @Test("flushPendingResize sends the pending grid exactly once and is then idempotent")
    func flushPendingResizeIsExactlyOnce() throws {
        let spy = SpyEncoder()
        // Skip gracefully when Metal is unavailable (headless local runs), like
        // MouseInputTests; CI runs these for real.
        guard let view = makeView(spy: spy) else { return }

        // Seed a pending grid through the real state machine against the committed 80x24.
        let committed = LiveResizeBookkeeping.Grid(cols: 80, rows: 24)
        let dragged = LiveResizeBookkeeping.Grid(cols: 100, rows: 30)
        _ = view.resizeBookkeeping.onFrame(live: dragged, committed: committed, now: 0.0,
                                           config: .liveResize)

        view.flushPendingResize()
        #expect(spy.resizeCalls.count == 1)
        #expect(spy.resizeCalls.first?.cols == 100)
        #expect(spy.resizeCalls.first?.rows == 30)
        #expect(view.resizeDebounceTask == nil)

        // A second flush (e.g. the release path racing a fired trailing task) sends nothing.
        view.flushPendingResize()
        #expect(spy.resizeCalls.count == 1)
    }

    @MainActor
    @Test("resize start releases an outstanding left press so the BEAM never keeps a stuck press")
    func resizeStartReleasesOutstandingPress() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }

        let down = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 40, y: 40), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1,
            clickCount: 1, pressure: 1))
        view.mouseDown(with: down)
        #expect(spy.mouseEventCalls.last?.eventType == MOUSE_PRESS)
        let pressCount = spy.mouseEventCalls.count

        // The resize begins before any mouseUp is delivered; the up will be dropped by the
        // inLiveResize guard, so the teardown must complete the gesture itself.
        view.viewWillStartLiveResize()

        let release = try #require(spy.mouseEventCalls.last)
        #expect(spy.mouseEventCalls.count == pressCount + 1)
        #expect(release.button == MOUSE_BUTTON_LEFT)
        #expect(release.eventType == MOUSE_RELEASE)

        // The teardown is idempotent: a second resize start (no press outstanding) sends nothing.
        view.viewWillStartLiveResize()
        #expect(spy.mouseEventCalls.count == pressCount + 1)
    }

    @MainActor
    @Test("resize start with no outstanding press sends no synthetic release")
    func resizeStartWithoutPressSendsNothing() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }
        view.viewWillStartLiveResize()
        #expect(spy.mouseEventCalls.isEmpty)
    }
}
