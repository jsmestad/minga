/// Ordered, single-hop delivery of decoded protocol events to the main actor.

import Foundation

enum ProtocolDeliveryEvent: Sendable {
    case frame(DecodedFrame)
    case decodeFailure(ProtocolDecodeError)
}

/// A thread-safe FIFO handoff from the serial protocol reader to one consumer.
///
/// `AsyncStream.Continuation.yield` records each event synchronously in call
/// order. The app owns exactly one main-actor consumer task for the stream, so
/// packets and failures cannot overtake one another through independently
/// scheduled tasks.
struct ProtocolEventHandoff: Sendable {
    let events: AsyncStream<ProtocolDeliveryEvent>
    private let continuation: AsyncStream<ProtocolDeliveryEvent>.Continuation

    init() {
        let pair = AsyncStream.makeStream(
            of: ProtocolDeliveryEvent.self,
            bufferingPolicy: .unbounded
        )
        self.events = pair.stream
        self.continuation = pair.continuation
    }

    /// Enqueues a decoded frame at the real reader-to-main-actor boundary.
    @discardableResult
    func deliver(_ frame: DecodedFrame) -> DecodedFrame {
        let deliveredFrame = frame.recordingActorHop()
        continuation.yield(.frame(deliveredFrame))
        return deliveredFrame
    }

    /// Enqueues a decode failure in the same wire-order stream as frames.
    func deliver(_ error: ProtocolDecodeError) {
        continuation.yield(.decodeFailure(error))
    }

    func finish() {
        continuation.finish()
    }
}
