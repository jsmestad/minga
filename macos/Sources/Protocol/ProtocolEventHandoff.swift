/// Capacity-one, ordered delivery of decoded protocol events to the main actor.

import Foundation
import MingaProtocol
import MingaUI

/// A single-producer/single-consumer admission handoff. The producer must own the sole slot before reading a payload. Admission stays reserved until consumption returns, so nested modal loops cannot reorder events and payload memory cannot accumulate behind the main actor.
final class ProtocolEventHandoff: @unchecked Sendable {
    let connectionID: UInt64
    private let consume: @MainActor @Sendable (DecodedFrameEvent) -> Void
    private let condition = NSCondition()
    private var slotOccupied = false
    private var blockedAdmissionCount = 0
    private var cancelled = false

    init(connectionID: UInt64 = 0, consume: @escaping @MainActor @Sendable (DecodedFrameEvent) -> Void) {
        self.connectionID = connectionID
        self.consume = consume
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

    /// Releases admission after the consumer finishes applying the event.
    private func releaseAdmission() {
        condition.lock()
        slotOccupied = false
        condition.signal()
        condition.unlock()
    }

    @discardableResult
    func deliver(_ frame: DecodedFrame) -> DecodedFrame {
        let deliveredFrame = frame.recordingActorHop()
        deliverEvent(.frame(deliveredFrame))
        return deliveredFrame
    }

    func deliver(_ failure: DecodedFrameFailure) {
        deliverEvent(.failure(failure))
    }

    private func deliverEvent(_ event: DecodedFrameEvent) {
        MainRunLoopAction { [self] in
            condition.lock()
            let shouldDeliver = !cancelled
            condition.unlock()
            guard shouldDeliver else { return }
            defer { releaseAdmission() }
            consume(event)
        }.enqueue()
    }

    /// Wakes a blocked producer and retires queued delivery. Idempotent.
    func cancel() {
        condition.lock()
        cancelled = true
        slotOccupied = false
        condition.broadcast()
        condition.unlock()
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
