import MingaProtocol
import Foundation
import Testing

@testable import Minga

/// Verifies the GUI latency recorder (ticket #2215): stamping, resolution, and
/// percentile statistics over a controllable clock.
@Suite("Latency Recorder")
struct LatencyRecorderTests {
    /// A controllable clock backing DispatchTime so durations are exact.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var nanos: UInt64
        init(start: UInt64 = 1_000_000_000) { self.nanos = start }
        func advance(_ d: UInt64) { lock.lock(); nanos &+= d; lock.unlock() }
        func now() -> DispatchTime { lock.lock(); defer { lock.unlock() }; return DispatchTime(uptimeNanoseconds: nanos) }
    }

    @Test("stamp returns monotonic non-zero sequences")
    func stampMonotonic() {
        let r = LatencyRecorder()
        let a = r.stamp()
        let b = r.stamp()
        #expect(a != 0)
        #expect(b == a + 1)
    }

    @Test("resolve records elapsed duration")
    func resolveRecords() {
        let clock = Clock()
        let r = LatencyRecorder(now: clock.now)
        let seq = r.stamp()
        clock.advance(750_000) // 750µs
        r.resolve(seq: seq)

        let stats = r.snapshot()
        #expect(stats.count == 1)
        #expect(abs(stats.p50Micros - 750.0) < 0.001)
        #expect(r.resolvedCount == 1)
    }

    @Test("resolve ignores zero and unknown sequences")
    func resolveIgnores() {
        let r = LatencyRecorder()
        r.resolve(seq: 0)
        r.resolve(seq: 999)
        #expect(r.snapshot().count == 0)
    }

    @Test("percentiles use nearest rank over 1..100µs")
    func percentiles() {
        let clock = Clock()
        let r = LatencyRecorder(now: clock.now)
        for i in 1...100 {
            let seq = r.stamp()
            clock.advance(UInt64(i) * 1000) // i µs
            r.resolve(seq: seq)
        }
        let stats = r.snapshot()
        #expect(stats.count == 100)
        #expect(abs(stats.p50Micros - 50.0) < 0.001)
        #expect(abs(stats.p99Micros - 99.0) < 0.001)
        #expect(abs(stats.maxMicros - 100.0) < 0.001)
    }
}
