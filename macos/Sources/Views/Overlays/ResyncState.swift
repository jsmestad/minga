/// Observable state for a pending frame-transaction resync (#2219 child D).
///
/// When `CommandDispatcher` invalidates an in-flight frame (truncation, seq
/// mismatch, base mismatch, or a decode failure inside a transaction) it
/// discards the staged commands, holds the last cleanly-committed frame on
/// screen, and asks the BEAM for a fresh keyframe. While that keyframe is in
/// flight, this state raises a subtle "resync pending" hint so the user knows a
/// brief recovery is underway rather than seeing a frozen frame with no
/// explanation. It clears the moment the next clean `commit_frame` lands.
///
/// This is deliberately the low-severity counterpart to `ProtocolErrorState`:
/// resync is recoverable and self-healing, so it is a small unobtrusive badge,
/// not a blocking full-window overlay.

import SwiftUI

@MainActor
@Observable
public final class ResyncState {
    public init() {}
    /// True between an invalidation and the next clean commit. Drives a small
    /// status-corner hint; the editor surface keeps showing the last good frame.
    public private(set) var pending: Bool = false

    /// Most recent frame_seq that committed cleanly before recovery began.
    /// Manual retry uses this to ask the BEAM for the same keyframe recovery the automatic path requested.
    public private(set) var lastGoodFrameSeq: UInt32 = 0
    public private(set) var generation: UInt32 = 0
    public private(set) var rejection: String?

    /// Raise the resync-pending hint and expose the active generation/rejection.
    public func markPending(lastGoodFrameSeq: UInt32, generation: UInt32, rejection: String) {
        self.lastGoodFrameSeq = lastGoodFrameSeq
        self.generation = generation
        self.rejection = rejection
        pending = true
    }

    /// Clear the hint. Called by `CommandDispatcher` when a clean `commit_frame`
    /// promotes a new frame.
    public func clear() {
        pending = false
        lastGoodFrameSeq = 0
        rejection = nil
    }
}
