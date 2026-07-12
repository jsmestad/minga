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
}
