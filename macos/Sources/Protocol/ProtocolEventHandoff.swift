/// Capacity-one, ordered delivery of decoded protocol events to the main actor.

import Foundation

/// A single-producer/single-consumer admission handoff. The producer must own
/// the sole slot before reading a payload. The consumer releases it immediately
/// after dequeue, so payload memory cannot accumulate behind the main actor.
final class ProtocolEventHandoff: @unchecked Sendable {
    let events: AsyncStream<DecodedFrameEvent>

    private let continuation: AsyncStream<DecodedFrameEvent>.Continuation
    private let condition = NSCondition()
    private var slotOccupied = false
    private var cancelled = false

    init() {
        let pair = AsyncStream.makeStream(
            of: DecodedFrameEvent.self,
            bufferingPolicy: .bufferingOldest(1)
        )
        events = pair.stream
        continuation = pair.continuation
    }

    /// Blocks only for the one FIFO permit. Returns false after shutdown.
    func acquireAdmission() -> Bool {
        condition.lock()
        while slotOccupied && !cancelled { condition.wait() }
        guard !cancelled else {
            condition.unlock()
            return false
        }
        slotOccupied = true
        condition.unlock()
        return true
    }

    /// Releases admission after the consumer has dequeued the event.
    func releaseAdmission() {
        condition.lock()
        slotOccupied = false
        condition.signal()
        condition.unlock()
    }

    @discardableResult
    func deliver(_ frame: DecodedFrame) -> DecodedFrame {
        let deliveredFrame = frame.recordingActorHop()
        continuation.yield(.frame(deliveredFrame))
        return deliveredFrame
    }

    func deliver(_ failure: DecodedFrameFailure) {
        continuation.yield(.failure(failure))
    }

    /// Wakes a blocked producer and ends a blocked consumer. Idempotent.
    func cancel() {
        condition.lock()
        cancelled = true
        slotOccupied = false
        condition.broadcast()
        condition.unlock()
        continuation.finish()
    }

    func finish() { cancel() }
}
