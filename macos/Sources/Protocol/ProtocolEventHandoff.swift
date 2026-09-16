/// Capacity-one, ordered delivery of decoded protocol events to the main actor.

import Foundation
import MingaProtocol
import MingaUI

/// A single-producer/single-consumer admission handoff. The producer must own
/// the sole slot before reading a payload. The consumer releases it immediately
/// after dequeue, so payload memory cannot accumulate behind the main actor.
final class ProtocolEventHandoff: @unchecked Sendable {
    let connectionID: UInt64
    let events: AsyncStream<DecodedFrameEvent>

    private let continuation: AsyncStream<DecodedFrameEvent>.Continuation
    private let condition = NSCondition()
    private var slotOccupied = false
    private var blockedAdmissionCount = 0
    private var cancelled = false

    init(connectionID: UInt64 = 0) {
        self.connectionID = connectionID
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
        while slotOccupied && !cancelled {
            blockedAdmissionCount += 1
            condition.broadcast()
            condition.wait()
            blockedAdmissionCount -= 1
        }
        guard !cancelled else {
            condition.unlock()
            return false
        }
        slotOccupied = true
        condition.broadcast()
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

    /// Waits until the reader owns the sole slot. Tests use this to prove teardown while the pipe read is blocked.
    func waitForAdmissionOwnershipForTesting() {
        condition.lock()
        while !slotOccupied && !cancelled { condition.wait() }
        condition.unlock()
    }

    /// Waits until a producer is blocked behind the occupied slot. Tests use this to synchronize without sleeps.
    func waitForBlockedAdmissionForTesting() {
        condition.lock()
        while blockedAdmissionCount == 0 && !cancelled { condition.wait() }
        condition.unlock()
    }
}
