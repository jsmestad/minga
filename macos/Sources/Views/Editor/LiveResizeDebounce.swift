import Foundation

/// Pure trailing-edge debounce decision for live window-resize → BEAM re-layout (#2655).
///
/// During a macOS window-edge drag, `EditorNSView.setFrameSize` fires many times
/// per second. Each distinct grid size would otherwise send a `resize` event to the
/// BEAM, forcing the most expensive render path (full re-layout + full re-send of
/// every visible window) and thrashing residence promotion (each `layout_generation`
/// rebuild re-defers residence via `RenderCache.reset`, then re-promotes next frame).
///
/// The debounce lives entirely on the GUI side: since #2699 the frontend already
/// owns rows-that-fit and sends the resize event, so throttling that outgoing event
/// keeps the BEAM completely ignorant of drag mechanics. The frontend presents the
/// last committed frame cropped top-left while the drag is in motion (no re-layout),
/// then flushes one resize on the trailing edge so the view snaps once.
///
/// The decision is trailing-edge with a `maxWait` cap: rapid consecutive resizes keep
/// pushing the flush deadline out, but never past `firstPendingAt + maxWait`. The cap
/// guarantees that even a pathological never-pausing drag still re-lays out at a rate
/// bounded by `maxWait` (AC3: bumps bounded by the debounce rate, not the event rate)
/// rather than cropping a stale frame indefinitely.
enum LiveResizeDebounce {
    /// Tuning for the trailing-edge debounce. Times are in seconds (`CACurrentMediaTime` units).
    struct Config: Equatable {
        /// Trailing quiescence window: flush this long after the last resize event.
        var interval: TimeInterval
        /// Cap measured from the first unflushed event in a burst. Bounds re-layout
        /// rate during a continuous drag so the crop can't go stale forever.
        var maxWait: TimeInterval

        init(interval: TimeInterval, maxWait: TimeInterval) {
            self.interval = interval
            self.maxWait = maxWait
        }

        /// The one production tuning for window live-resize (75ms trailing, 250ms cap).
        /// Tests reference this same value so a retune can never silently desync the
        /// suite from what ships.
        static let liveResize = Config(interval: 0.075, maxWait: 0.25)
    }

    /// What to do with a resize event observed at a given time.
    enum Decision: Equatable {
        /// The `maxWait` cap has been reached; send the resize immediately.
        case flushNow
        /// Defer the resize; (re)schedule the trailing flush for this absolute deadline.
        case deferUntil(TimeInterval)
    }

    /// Decide how to handle a resize event observed at `now`.
    ///
    /// - Parameters:
    ///   - now: the event time in `CACurrentMediaTime` units.
    ///   - firstPendingAt: when the current unflushed burst began, or `nil` if nothing is pending
    ///     (i.e. this is the first event since the last flush).
    ///   - config: trailing interval and max-wait cap.
    /// - Returns: `.flushNow` when the cap is already reached, otherwise `.deferUntil(deadline)`
    ///   where `deadline` is the trailing edge clamped to the burst's max-wait cap.
    static func onResize(now: TimeInterval, firstPendingAt: TimeInterval?, config: Config) -> Decision {
        guard let start = firstPendingAt else {
            // First event of a burst: pure trailing edge.
            return .deferUntil(now + config.interval)
        }
        let cap = start + config.maxWait
        if cap <= now {
            return .flushNow
        }
        return .deferUntil(min(now + config.interval, cap))
    }
}

/// Pure state machine for the live-resize pending-grid bookkeeping (#2655).
///
/// Mirrors the deferred-resize state that `EditorNSView` holds during a window-edge drag
/// so the tricky gestures (especially drag-away-and-back) can be tested without AppKit.
/// The view delegates every live-resize frame and every flush to this value type and just
/// executes the returned side effects (schedule a timer, send a resize, cancel a timer).
///
/// The load-bearing case is drag-away-and-back: `frameState` stays at the pre-drag committed
/// grid G0 while the drag is deferred. If the drag moves to G1 (pending = G1) and then returns
/// so the live grid equals G0 again, the pending G1 must be dropped. Otherwise a later flush
/// would send G1 for a window that is really G0, committing the wrong row/col count.
struct LiveResizeBookkeeping: Equatable {
    /// A viewport grid in cells. Kept tiny and value-typed so it is trivially comparable.
    struct Grid: Equatable {
        var cols: UInt16
        var rows: UInt16
        init(cols: UInt16, rows: UInt16) {
            self.cols = cols
            self.rows = rows
        }
    }

    /// The two legal states, as one value: either nothing is pending, or a grid is pending
    /// with the burst-start time that feeds the max-wait cap. An enum spine (same convention
    /// as `ThumbDragSession.Phase`) makes "pending grid without a burst start" — the state a
    /// desynced optional pair could reach — unrepresentable by construction.
    private enum State: Equatable {
        case idle
        case pending(Grid, since: TimeInterval)
    }

    private var state: State = .idle

    /// The latest live grid awaiting a flush, or nil when nothing is pending.
    var pending: Grid? {
        guard case .pending(let grid, _) = state else { return nil }
        return grid
    }

    /// When the current unflushed burst began (`CACurrentMediaTime`), or nil when idle.
    var firstPendingAt: TimeInterval? {
        guard case .pending(_, let since) = state else { return nil }
        return since
    }

    init() {}

    /// Side effect the caller should perform after observing one live-resize frame.
    /// The caller always repaints (crop) regardless of which case is returned.
    enum Frame: Equatable {
        /// Max-wait cap reached: send this grid immediately (and cancel any pending timer).
        case flushNow(Grid)
        /// (Re)schedule the trailing flush for this absolute deadline.
        case schedule(TimeInterval)
        /// The live grid returned to the committed grid: a pending resize was dropped; cancel the timer.
        case cancelPending
        /// Nothing to do (grid already matches committed and nothing was pending).
        case noop
    }

    /// Observe one live-resize frame: the freshly measured `live` grid against the currently
    /// committed `committed` grid (i.e. `frameState`). Mutates the pending bookkeeping and
    /// returns the side effect to run.
    mutating func onFrame(live: Grid, committed: Grid, now: TimeInterval, config: LiveResizeDebounce.Config) -> Frame {
        guard live != committed else {
            // Drag returned to the committed size: there is nothing to commit. Drop any pending
            // resize so a later flush can't send a stale (dragged-away) grid for the committed one.
            let hadPending = pending != nil
            state = .idle
            return hadPending ? .cancelPending : .noop
        }

        let decision = LiveResizeDebounce.onResize(now: now, firstPendingAt: firstPendingAt, config: config)
        switch decision {
        case .flushNow:
            state = .idle
            return .flushNow(live)
        case .deferUntil(let deadline):
            state = .pending(live, since: firstPendingAt ?? now)
            return .schedule(deadline)
        }
    }

    /// Take the pending grid to flush against the current `committed` grid, clearing all state.
    /// Returns nil when there is nothing to send: no pending grid, or the pending grid already
    /// matches the committed grid (the drag-away-and-back guard, applied again at flush time).
    mutating func takeFlush(committed: Grid) -> Grid? {
        guard case .pending(let grid, _) = state else { return nil }
        state = .idle
        guard grid != committed else { return nil }
        return grid
    }
}
