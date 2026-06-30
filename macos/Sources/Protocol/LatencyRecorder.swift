import Foundation

/// Records end-to-end keystroke-to-present latency for the macOS GUI (ticket
/// #2215).
///
/// The renderer stamps a monotonically increasing correlation sequence into each
/// key packet at input time (``stamp()``). The BEAM echoes that sequence back on
/// the `commit_frame` of the resulting frame; the renderer resolves the sample when
/// the frame is presented (``resolve(seq:)``). Samples live in a fixed-size ring
/// buffer so the recorder never grows unbounded.
///
/// This is the minimal sample recorder for the GUI. The on-screen latency HUD is
/// a deliberate follow-up (see the ticket report); the BEAM telemetry spans and
/// the bench harness already capture the BEAM-side numbers, and this recorder
/// makes the GUI keystroke-to-present sample available for a future overlay or
/// log dump.
public final class LatencyRecorder: @unchecked Sendable {
    /// Bounds the in-flight stamps and recorded samples.
    private let ringSize = 4096

    private let lock = NSLock()
    private let now: () -> DispatchTime

    private var nextSeq: UInt32 = 0
    private var pending: [UInt32: DispatchTime] = [:]
    private var pendingOrder: [UInt32] = []

    private var samples: [Double]  // nanoseconds
    private var head = 0
    private var count = 0

    public private(set) var resolvedCount: UInt64 = 0
    public private(set) var droppedCount: UInt64 = 0

    public init(now: @escaping () -> DispatchTime = { DispatchTime.now() }) {
        self.now = now
        self.samples = [Double](repeating: 0, count: ringSize)
    }

    /// Allocates the next correlation sequence and records the current time.
    /// Sequences start at 1 so 0 stays the "no correlation" sentinel.
    public func stamp() -> UInt32 {
        lock.lock()
        defer { lock.unlock() }

        nextSeq &+= 1
        if nextSeq == 0 { nextSeq = 1 }
        let seq = nextSeq

        pending[seq] = now()
        pendingOrder.append(seq)
        while pendingOrder.count > ringSize {
            let oldest = pendingOrder.removeFirst()
            if pending.removeValue(forKey: oldest) != nil {
                droppedCount &+= 1
            }
        }
        return seq
    }

    /// Resolves the elapsed time for a sequence echoed on a frame boundary.
    /// Sequence 0 (no correlation) and unknown sequences are ignored; the BEAM
    /// coalesces rapid keystrokes into one frame, so only the latest sequence in
    /// a frame resolves and earlier ones fall out of `pending` naturally.
    public func resolve(seq: UInt32) {
        guard seq != 0 else { return }

        lock.lock()
        defer { lock.unlock() }

        guard let stampedAt = pending.removeValue(forKey: seq) else { return }
        if let index = pendingOrder.firstIndex(of: seq) {
            pendingOrder.remove(at: index)
        }

        let elapsed = Double(now().uptimeNanoseconds &- stampedAt.uptimeNanoseconds)
        samples[head] = elapsed
        head = (head + 1) % ringSize
        if count < ringSize { count += 1 }
        resolvedCount &+= 1
    }

    /// Percentile statistics over the buffered samples, in microseconds.
    public struct Stats: Equatable, Sendable {
        public var count: Int = 0
        public var p50Micros: Double = 0
        public var p99Micros: Double = 0
        public var maxMicros: Double = 0

        public init(count: Int = 0, p50Micros: Double = 0, p99Micros: Double = 0, maxMicros: Double = 0) {
            self.count = count
            self.p50Micros = p50Micros
            self.p99Micros = p99Micros
            self.maxMicros = maxMicros
        }
    }

    /// Returns percentile statistics over the buffered samples. Copies the live
    /// window before sorting so the hot path never blocks on a sort of the
    /// shared buffer.
    public func snapshot() -> Stats {
        lock.lock()
        var window = [Double]()
        window.reserveCapacity(count)
        for i in 0..<count {
            let idx = (head - count + i + ringSize) % ringSize
            window.append(samples[idx])
        }
        lock.unlock()

        guard !window.isEmpty else { return Stats() }
        window.sort()
        return Stats(
            count: window.count,
            p50Micros: percentile(window, 0.50) / 1000.0,
            p99Micros: percentile(window, 0.99) / 1000.0,
            maxMicros: (window.last ?? 0) / 1000.0
        )
    }

    /// Nearest-rank percentile over a pre-sorted slice, matching the BEAM bench.
    private func percentile(_ sorted: [Double], _ ratio: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        var index = Int((Double(sorted.count) * ratio).rounded(.up)) - 1
        if index < 0 { index = 0 }
        if index >= sorted.count { index = sorted.count - 1 }
        return sorted[index]
    }
}
