@testable import MingaProtocol
import Foundation
import Testing

@Suite("Latency Recorder")
struct LatencyRecorderTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var nanos: UInt64
        init(start: UInt64 = 1_000_000_000) { nanos = start }
        func advance(_ duration: UInt64) { lock.lock(); nanos &+= duration; lock.unlock() }
        func now() -> DispatchTime { lock.lock(); defer { lock.unlock() }; return DispatchTime(uptimeNanoseconds: nanos) }
    }

    @Test("semantic apply records apply but does not resolve presentation")
    func applyIsNotPresentation() {
        let clock = Clock()
        let recorder = LatencyRecorder(now: clock.now)
        let seq = recorder.stamp()
        clock.advance(750_000)
        recorder.markApplied(seq: seq)

        let stats = recorder.snapshot()
        #expect(stats.apply.count == 1)
        #expect(stats.apply.p50Micros == 750)
        #expect(stats.present.count == 0)
        #expect(stats.submittedCount == 0)
    }

    @Test("submission and GPU completion resolve presentation")
    func completionResolvesPresentation() {
        let clock = Clock()
        let recorder = LatencyRecorder(now: clock.now)
        let seq = recorder.stamp()
        clock.advance(1_000_000)
        recorder.markApplied(seq: seq)
        clock.advance(500_000)
        recorder.markSubmitted(seq: seq)
        clock.advance(500_000)
        recorder.markPresented(seq: seq)

        let stats = recorder.snapshot()
        #expect(stats.apply.p50Micros == 1_000)
        #expect(stats.present.p50Micros == 2_000)
        #expect(stats.submittedCount == 1)
    }

    @Test("presentation before submission is ignored")
    func completionRequiresSubmission() {
        let recorder = LatencyRecorder()
        let seq = recorder.stamp()
        recorder.markApplied(seq: seq)
        recorder.markPresented(seq: seq)
        #expect(recorder.snapshot().present.count == 0)
    }

    @Test("unpresentable samples retain typed discard reasons", arguments: LatencyRecorder.DiscardReason.allCases)
    func discardReasons(reason: LatencyRecorder.DiscardReason) {
        let recorder = LatencyRecorder()
        let seq = recorder.stamp()
        recorder.markApplied(seq: seq)
        recorder.discard(seq: seq, reason: reason)
        recorder.markSubmitted(seq: seq)
        recorder.markPresented(seq: seq)
        let stats = recorder.snapshot()
        #expect(stats.present.count == 0)
        #expect(stats.discardCounts[reason] == 1)
    }

    @Test("presentation preflight rejects sleep, hidden, and occluded surfaces")
    func presentationPreflight() {
        #expect(PresentationSamplePreflight.discardReason(
            screenAsleep: true, hidden: false, occluded: false) == .screenSleep)
        #expect(PresentationSamplePreflight.discardReason(
            screenAsleep: false, hidden: true, occluded: false) == .hidden)
        #expect(PresentationSamplePreflight.discardReason(
            screenAsleep: false, hidden: false, occluded: true) == .occluded)
        #expect(PresentationSamplePreflight.discardReason(
            screenAsleep: false, hidden: false, occluded: false) == nil)
    }

    @Test("preflight prioritizes screen sleep and hidden state over retained occluded drawables")
    func presentationPreflightPrecedence() {
        #expect(PresentationSamplePreflight.discardReason(
            screenAsleep: true, hidden: true, occluded: true) == .screenSleep)
        #expect(PresentationSamplePreflight.discardReason(
            screenAsleep: false, hidden: true, occluded: true) == .hidden)
    }

    @Test("percentiles use nearest rank")
    func percentiles() {
        let clock = Clock()
        let recorder = LatencyRecorder(now: clock.now)
        for value in 1...100 {
            let seq = recorder.stamp()
            clock.advance(UInt64(value) * 1_000)
            recorder.markApplied(seq: seq)
            recorder.markSubmitted(seq: seq)
            recorder.markPresented(seq: seq)
        }
        let stats = recorder.snapshot()
        #expect(stats.apply.p50Micros == 50)
        #expect(stats.apply.p95Micros == 95)
        #expect(stats.present.p99Micros == 99)
    }

    // MARK: - Ring buffer wraparound and capacity

    @Test("sample history wraps at capacity preserving only recent entries")
    func sampleHistoryWrapsAtCapacity() {
        let clock = Clock()
        let recorder = LatencyRecorder(now: clock.now)
        // Fill 4096 + 100 apply samples; only the last 4096 should survive.
        let total = 4096 + 100
        for i in 1...total {
            let seq = recorder.stamp()
            clock.advance(UInt64(i) * 1_000)
            recorder.markApplied(seq: seq)
        }
        let stats = recorder.snapshot()
        #expect(stats.apply.count == 4096)
        // The oldest retained sample is entry 101 (latency 101 us).
        // Median of 101...4196 is entry at nearest-rank p50.
        #expect(stats.apply.p50Micros > 0)
        #expect(stats.apply.maxMicros == Double(total))
    }

    @Test("pending eviction drops oldest stamps when capacity exceeded")
    func pendingEvictionDropsOldest() {
        let clock = Clock()
        let recorder = LatencyRecorder(now: clock.now)
        // Stamp 4097 entries without resolving any. The first should be evicted.
        var seqs: [UInt32] = []
        for _ in 1...4097 {
            seqs.append(recorder.stamp())
            clock.advance(1_000)
        }
        // The first stamp was evicted as "dropped".
        let stats = recorder.snapshot()
        #expect(stats.discardCounts[.dropped] == 1)
        // Applying the evicted sequence is a no-op.
        recorder.markApplied(seq: seqs[0])
        #expect(recorder.snapshot().apply.count == 0)
        // The last sequence is still pending and can be applied.
        recorder.markApplied(seq: seqs[4096])
        #expect(recorder.snapshot().apply.count == 1)
    }

    @Test("replaceConnection resets eviction cursor so new stamps work after clearing")
    func replaceConnectionResetsEviction() {
        let clock = Clock()
        let recorder = LatencyRecorder(now: clock.now)
        for _ in 1...10 {
            _ = recorder.stamp()
            clock.advance(1_000)
        }
        recorder.replaceConnection()
        let stats = recorder.snapshot()
        #expect(stats.discardCounts[.connectionReplaced] == 10)
        // New stamps after replaceConnection still work correctly.
        let seq = recorder.stamp()
        clock.advance(500_000)
        recorder.markApplied(seq: seq)
        recorder.markSubmitted(seq: seq)
        recorder.markPresented(seq: seq)
        let after = recorder.snapshot()
        #expect(after.apply.count == 1)
        #expect(after.present.count == 1)
        #expect(after.present.p50Micros == 500)
    }

    @Test("resolved and discarded entries do not block eviction cursor")
    func sparseEvictionAdvancesPastGaps() {
        let clock = Clock()
        let recorder = LatencyRecorder(now: clock.now)
        // Create 10 stamps, resolve the first 5.
        var seqs: [UInt32] = []
        for _ in 1...10 {
            seqs.append(recorder.stamp())
            clock.advance(1_000)
        }
        for i in 0..<5 {
            recorder.markApplied(seq: seqs[i])
            recorder.markSubmitted(seq: seqs[i])
            recorder.markPresented(seq: seqs[i])
        }
        // Stamp enough to force eviction of the remaining 5 unresolved entries.
        // Currently 5 pending (seqs 6..10). We need 4096 more stamps: the first
        // 4091 fill to capacity, then each of the next 5 evicts one old entry.
        for _ in 1...4096 {
            _ = recorder.stamp()
            clock.advance(1_000)
        }
        let stats = recorder.snapshot()
        // The 5 already-resolved entries were not in pending, so the eviction
        // cursor skips past them. The 5 unresolved entries (seqs 6..10) get dropped.
        #expect(stats.discardCounts[.dropped] == 5)
    }

    // MARK: - Constant per-recording cost

    private static let capacity = 4096

    private func resolve(_ recorder: LatencyRecorder, _ seq: UInt32) {
        recorder.markApplied(seq: seq)
        recorder.markSubmitted(seq: seq)
        recorder.markPresented(seq: seq)
    }

    /// Stamps once and returns the sequence with the pending entries that stamp inspected.
    private func measuredStamp(_ recorder: LatencyRecorder) -> (seq: UInt32, probes: UInt64) {
        let before = recorder.evictionProbeCountForTesting
        let seq = recorder.stamp()
        return (seq, recorder.evictionProbeCountForTesting - before)
    }

    @Test("each stamp inspects at most one pending entry before and after capacity, even after a long resolved run")
    func stampEvictionWorkIsConstant() {
        let recorder = LatencyRecorder()

        // A long healthy session: every sample resolves, so the pending set never fills.
        var healthy: [UInt64] = []
        for _ in 0..<20_000 {
            let stamped = measuredStamp(recorder)
            healthy.append(stamped.probes)
            resolve(recorder, stamped.seq)
        }
        #expect(Set(healthy) == [0])

        // Presentation stalls: unresolved stamps fill the pending set, then overflow it twice over.
        var stalled: [UInt64] = []
        for _ in 0..<(Self.capacity * 3) {
            stalled.append(measuredStamp(recorder).probes)
        }
        #expect(Set(stalled.prefix(Self.capacity)) == [0])
        #expect(Set(stalled.dropFirst(Self.capacity)) == [1])
        #expect(recorder.snapshot().discardCounts[.dropped] == UInt64(Self.capacity * 2))
    }

    @Test("capacity eviction drops the oldest still-pending entry after out-of-order resolution and discard")
    func evictionFollowsPendingOrder() {
        let recorder = LatencyRecorder()
        let seqs = (0..<Self.capacity).map { _ in recorder.stamp() }
        // Resolve the oldest entry, discard one from the middle, and resolve the newest.
        resolve(recorder, seqs[0])
        recorder.discard(seq: seqs[2], reason: .hidden)
        resolve(recorder, seqs[Self.capacity - 1])

        // Three stamps refill the pending set; the fourth must evict seqs[1], then seqs[3].
        var probes: [UInt64] = []
        for _ in 0..<5 { probes.append(measuredStamp(recorder).probes) }
        #expect(probes == [0, 0, 0, 1, 1])
        let discards = recorder.snapshot().discardCounts
        #expect(discards[.dropped] == 2)
        #expect(discards[.hidden] == 1)

        let before = recorder.snapshot().apply.count
        recorder.markApplied(seq: seqs[1])
        recorder.markApplied(seq: seqs[3])
        #expect(recorder.snapshot().apply.count == before)
        recorder.markApplied(seq: seqs[4])
        #expect(recorder.snapshot().apply.count == before + 1)
    }

    @Test("capacity eviction after a connection replacement starts with the first new stamp")
    func evictionAfterConnectionReplacement() {
        let recorder = LatencyRecorder()
        for _ in 0..<10 { _ = recorder.stamp() }
        recorder.replaceConnection()
        let seqs = (0...Self.capacity).map { _ in recorder.stamp() }
        let discards = recorder.snapshot().discardCounts
        #expect(discards[.connectionReplaced] == 10)
        #expect(discards[.dropped] == 1)
        recorder.markApplied(seq: seqs[0])
        #expect(recorder.snapshot().apply.count == 0)
        recorder.markApplied(seq: seqs[1])
        #expect(recorder.snapshot().apply.count == 1)
    }

    @Test("apply and presentation histories keep exactly the newest samples in nearest-rank order",
          arguments: [0, 1, 4_095, 4_096, 4_097, 4_096 * 3 + 17])
    func historiesKeepNewestSamples(total: Int) {
        let clock = Clock()
        let recorder = LatencyRecorder(now: clock.now)
        for value in stride(from: 1, through: total, by: 1) {
            let seq = recorder.stamp()
            clock.advance(UInt64(value) * 1_000)
            resolve(recorder, seq)
        }

        let retained = min(total, Self.capacity)
        let oldest = total - retained + 1
        func rank(_ percent: Int) -> Double {
            Double(oldest + max((retained * percent + 99) / 100, 1) - 1)
        }
        let expected = retained == 0
            ? LatencyRecorder.StageStats()
            : LatencyRecorder.StageStats(
                count: retained, p50Micros: rank(50), p95Micros: rank(95),
                p99Micros: rank(99), maxMicros: Double(total)
            )
        let stats = recorder.snapshot()
        #expect(stats.apply == expected)
        #expect(stats.present == expected)
    }
}
