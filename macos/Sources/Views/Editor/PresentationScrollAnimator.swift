import CoreGraphics
import QuartzCore

/// Shared presentation-only scroll animation ticker.
///
/// The editor's MTKView is paused (`enableSetNeedsDisplay`), so nothing redraws on its own.
/// This animator decays a pixel offset toward the line grid (0) over a short duration and the
/// owner self-retriggers `setNeedsDisplay` while `isActive` is true, mirroring the ~35ms cursor
/// animation in `CoreTextMetalRenderer`. It is intentionally free of AppKit/NSView dependencies
/// so the easing and rubber-band math can be unit tested.
///
/// All three gesture-boundary polish animations (settle at gesture end, rubber-band spring-back,
/// eased discrete-wheel ticks) are the same shape: an offset that eases to exactly 0 (the grid).
/// The animation is purely visual and discardable: it never changes what scroll intent the BEAM
/// sees, and it always terminates on the grid.
struct PresentationScrollAnimator {
    /// True while an animation is in flight. The owner keeps redrawing while this holds.
    private(set) var isActive = false

    private var startTime: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0
    private var startOffset: CGFloat = 0

    /// Offsets smaller than this (in points) are not worth animating; snap instead.
    static let minAnimatableOffset: CGFloat = 0.5

    /// Begins an ease-out decay from `offset` px to exactly 0 over `duration` seconds.
    /// A tiny offset or non-positive duration deactivates instead of animating.
    mutating func start(offset: CGFloat, duration: CFTimeInterval, now: CFTimeInterval = CACurrentMediaTime()) {
        guard duration > 0, abs(offset) >= Self.minAnimatableOffset else {
            isActive = false
            startOffset = 0
            return
        }
        self.startOffset = offset
        self.duration = duration
        self.startTime = now
        self.isActive = true
    }

    /// Immediately stops the animation. The owner is responsible for snapping to the grid.
    mutating func cancel() {
        isActive = false
        startOffset = 0
    }

    /// Returns the current animated offset, deactivating and returning exactly 0 when finished.
    mutating func offset(now: CFTimeInterval = CACurrentMediaTime()) -> CGFloat {
        guard isActive else { return 0 }
        let progress = Self.progress(now: now, startTime: startTime, duration: duration)
        if progress >= 1 {
            isActive = false
            startOffset = 0
            return 0
        }
        return Self.easedOffset(startOffset: startOffset, progress: progress)
    }

    // MARK: - Pure math (unit tested)

    /// Normalized [0, 1] animation progress, clamped to the timeline bounds.
    nonisolated static func progress(now: CFTimeInterval, startTime: CFTimeInterval, duration: CFTimeInterval) -> CGFloat {
        guard duration > 0 else { return 1 }
        return min(max(CGFloat((now - startTime) / duration), 0), 1)
    }

    /// Ease-out cubic decay of `startOffset` toward 0.
    ///
    /// Guarantees the endpoints exactly: `progress 0` returns `startOffset`, `progress 1` returns 0.
    /// This is what makes the settle land precisely on the line grid regardless of the start value.
    nonisolated static func easedOffset(startOffset: CGFloat, progress: CGFloat) -> CGFloat {
        let clamped = min(max(progress, 0), 1)
        let eased = 1 - pow(1 - clamped, 3) // ease-out cubic: 0 -> 1
        return startOffset * (1 - eased)    // startOffset -> 0
    }

    /// macOS-native rubber-band map: asymptotic, monotonic, bounded, passes through the origin.
    ///
    /// As `rawDistance` grows the returned offset approaches `±limit` but never reaches it, so a
    /// hard overscroll pull settles to roughly `limit` (about 3-4 cells) instead of a stiff clamp.
    nonisolated static func rubberBandOffset(rawDistance: CGFloat, limit: CGFloat) -> CGFloat {
        guard limit > 0 else { return 0 }
        let sign: CGFloat = rawDistance < 0 ? -1 : 1
        let magnitude = abs(rawDistance)
        return sign * (1 - 1 / (magnitude / limit + 1)) * limit
    }

    /// Inverse of `rubberBandOffset`: the raw distance that produces a given displayed `offset`.
    ///
    /// Used to fold a residual sub-line offset into the rubber band on the frame elastic engages,
    /// so the transition is continuous (no one-frame pop). Only valid for `|offset| < limit`.
    nonisolated static func inverseRubberBandDistance(offset: CGFloat, limit: CGFloat) -> CGFloat {
        guard limit > 0 else { return 0 }
        let sign: CGFloat = offset < 0 ? -1 : 1
        let magnitude = min(abs(offset), limit * 0.999)
        return sign * magnitude / (1 - magnitude / limit)
    }
}
