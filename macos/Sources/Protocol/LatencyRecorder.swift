import Foundation

/// Pure preflight used before requesting a drawable or claiming a presentation sequence.
public enum PresentationSamplePreflight {
    /// Returns why a view cannot schedule a presentation sample, or nil when it may draw.
    public static func discardReason(screenAsleep: Bool, hidden: Bool,
                                     occluded: Bool) -> LatencyRecorder.DiscardReason? {
        if screenAsleep { return .screenSleep }
        if hidden { return .hidden }
        if occluded { return .occluded }
        return nil
    }
}

/// Records honest native input latency milestones without treating semantic apply
/// as presentation. Input sequences remain pending after apply until Metal submits
/// and completes the matching drawable, or until an explicit discard reason wins.
public final class LatencyRecorder: @unchecked Sendable {
    private let ringSize = 4096
    private let lock = NSLock()
    private let now: () -> DispatchTime

    private struct Pending {
        let received: DispatchTime
        var applied: DispatchTime?
        var submitted: DispatchTime?
    }

    /// Stable reason that a pending presentation sample could not reach the display path.
    public enum DiscardReason: String, CaseIterable, Sendable {
        case screenSleep = "screen_sleep"
        case hidden
        case occluded
        case nilDrawable = "nil_drawable"
        case superseded
        case schedulingImpossible = "scheduling_impossible"
        case nativeResourceFailure = "native_resource_failure"
        case dropped
        case gpuFailure = "gpu_failure"
    }

    /// Percentile summary for one latency milestone.
    public struct StageStats: Equatable, Sendable {
        /// Number of retained samples.
        public var count: Int = 0
        /// Median latency in microseconds.
        public var p50Micros: Double = 0
        /// P95 latency in microseconds.
        public var p95Micros: Double = 0
        /// P99 latency in microseconds.
        public var p99Micros: Double = 0
        /// Maximum retained latency in microseconds.
        public var maxMicros: Double = 0

        /// Creates a stage summary from its count and percentile values.
        public init(count: Int = 0, p50Micros: Double = 0, p95Micros: Double = 0,
                    p99Micros: Double = 0, maxMicros: Double = 0) {
            self.count = count
            self.p50Micros = p50Micros
            self.p95Micros = p95Micros
            self.p99Micros = p99Micros
            self.maxMicros = maxMicros
        }
    }

    /// Snapshot of apply, presentation, submission, and discard telemetry.
    public struct Stats: Equatable, Sendable {
        /// Semantic-apply latency summary.
        public var apply: StageStats = StageStats()
        /// GPU-completion presentation latency summary.
        public var present: StageStats = StageStats()
        /// Number of matching Metal command buffers submitted.
        public var submittedCount: UInt64 = 0
        /// Number of samples discarded for each stable reason.
        public var discardCounts: [DiscardReason: UInt64] = [:]

        /// Creates a complete recorder snapshot.
        public init(apply: StageStats = StageStats(), present: StageStats = StageStats(),
                    submittedCount: UInt64 = 0,
                    discardCounts: [DiscardReason: UInt64] = [:]) {
            self.apply = apply
            self.present = present
            self.submittedCount = submittedCount
            self.discardCounts = discardCounts
        }
    }

    private var nextSeq: UInt32 = 0
    private var pending: [UInt32: Pending] = [:]
    private var pendingOrder: [UInt32] = []
    private var applySamples: [Double] = []
    private var presentSamples: [Double] = []
    private var submittedCount: UInt64 = 0
    private var discardCounts: [DiscardReason: UInt64] = [:]

    /// Creates a recorder using the supplied monotonic clock.
    public init(now: @escaping () -> DispatchTime = { DispatchTime.now() }) {
        self.now = now
    }

    /// Marks input receipt and returns a non-zero correlation sequence.
    public func stamp() -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        nextSeq &+= 1
        if nextSeq == 0 { nextSeq = 1 }
        let seq = nextSeq
        pending[seq] = Pending(received: now())
        pendingOrder.append(seq)
        while pendingOrder.count > ringSize {
            let oldest = pendingOrder.removeFirst()
            if pending.removeValue(forKey: oldest) != nil {
                discardCounts[.dropped, default: 0] &+= 1
            }
        }
        return seq
    }

    /// Marks frontend semantic publication. This records apply latency but does
    /// not resolve or remove the presentation sample.
    public func markApplied(seq: UInt32) {
        guard seq != 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard var entry = pending[seq], entry.applied == nil else { return }
        let applied = now()
        entry.applied = applied
        pending[seq] = entry
        append(Double(applied.uptimeNanoseconds &- entry.received.uptimeNanoseconds), to: &applySamples)
    }

    /// Marks command-buffer submission for a semantically applied sequence.
    public func markSubmitted(seq: UInt32) {
        guard seq != 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard var entry = pending[seq], entry.applied != nil, entry.submitted == nil else { return }
        entry.submitted = now()
        pending[seq] = entry
        submittedCount &+= 1
    }

    /// Resolves presentation only after the submitted Metal command buffer
    /// completes successfully. Apply acknowledgement alone never calls this.
    public func markPresented(seq: UInt32) {
        guard seq != 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let entry = pending[seq], entry.submitted != nil else { return }
        _ = removePending(seq)
        append(Double(now().uptimeNanoseconds &- entry.received.uptimeNanoseconds), to: &presentSamples)
    }

    /// Removes an unpresentable sample with a typed diagnostic reason.
    public func discard(seq: UInt32, reason: DiscardReason) {
        guard seq != 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard removePending(seq) != nil else { return }
        discardCounts[reason, default: 0] &+= 1
    }

    /// Returns an immutable percentile and discard-count snapshot.
    public func snapshot() -> Stats {
        lock.lock()
        let apply = applySamples
        let present = presentSamples
        let submissions = submittedCount
        let discards = discardCounts
        lock.unlock()
        return Stats(
            apply: stageStats(apply),
            present: stageStats(present),
            submittedCount: submissions,
            discardCounts: discards
        )
    }

    private func removePending(_ seq: UInt32) -> Pending? {
        guard let entry = pending.removeValue(forKey: seq) else { return nil }
        if let index = pendingOrder.firstIndex(of: seq) { pendingOrder.remove(at: index) }
        return entry
    }

    private func append(_ sample: Double, to samples: inout [Double]) {
        if samples.count == ringSize { samples.removeFirst() }
        samples.append(sample)
    }

    private func stageStats(_ samples: [Double]) -> StageStats {
        guard !samples.isEmpty else { return StageStats() }
        let sorted = samples.sorted()
        return StageStats(
            count: sorted.count,
            p50Micros: percentile(sorted, 0.50) / 1000.0,
            p95Micros: percentile(sorted, 0.95) / 1000.0,
            p99Micros: percentile(sorted, 0.99) / 1000.0,
            maxMicros: (sorted.last ?? 0) / 1000.0
        )
    }

    private func percentile(_ sorted: [Double], _ ratio: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(max(Int((Double(sorted.count) * ratio).rounded(.up)) - 1, 0), sorted.count - 1)]
    }
}
