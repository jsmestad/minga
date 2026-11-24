import MingaProtocol
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
}
