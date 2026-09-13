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

/// Owns the single main-actor consumer for the current protocol connection.
@MainActor
final class ProtocolEventDelivery {
    typealias CurrentConnection = @MainActor (UInt64) -> Bool
    typealias Consumer = @MainActor (DecodedFrameEvent, UInt64) -> Void

    private var handoff: ProtocolEventHandoff?
    private var task: Task<Void, Never>?
    private(set) var activeConnectionID: UInt64?

    /// Replaces any earlier consumer and returns the capacity-one handoff for the new reader.
    func replace(
        connectionID: UInt64,
        isCurrent: @escaping CurrentConnection,
        consume: @escaping Consumer
    ) -> ProtocolEventHandoff {
        cancel()
        let handoff = ProtocolEventHandoff(connectionID: connectionID)
        self.handoff = handoff
        activeConnectionID = connectionID
        task = Task { @MainActor in
            for await event in handoff.events {
                handoff.releaseAdmission()
                guard !Task.isCancelled, isCurrent(handoff.connectionID) else { continue }
                consume(event, handoff.connectionID)
            }
        }
        return handoff
    }

    /// Cancels queued delivery and wakes any reader waiting for admission. Idempotent.
    func cancel() {
        handoff?.cancel()
        task?.cancel()
        handoff = nil
        task = nil
        activeConnectionID = nil
    }
}

/// Executes the ordered transport replacement used by `AppDelegate.reconnectProtocol`.
@MainActor
enum ProtocolReconnectWorkflow {
    struct EncoderRequest {
        let output: FileHandle
        let onTransportFailure: @MainActor @Sendable (OutboundTransportFailureReport) -> Void
    }

    struct Connection {
        let encoder: ProtocolEncoder
        let reader: ProtocolReader
    }

    typealias EncoderFactory = @MainActor (EncoderRequest) throws -> ProtocolEncoder
    typealias DeliveryInstaller = @MainActor (UInt64) -> ProtocolEventHandoff

    /// Invalidates the old connection before the only fallible replacement step.
    static func replace(
        connectionID: UInt64,
        readHandle: FileHandle,
        writeHandle: FileHandle,
        oldEncoder: ProtocolEncoder?,
        oldReader: ProtocolReader?,
        resourcePolicy: FrameResourcePolicy,
        invalidate: @MainActor () -> Void,
        encoderFactory: EncoderFactory = { request in
            try ProtocolEncoder(
                output: request.output,
                onTransportFailure: request.onTransportFailure
            )
        },
        onTransportFailure: @escaping @MainActor @Sendable (OutboundTransportFailureReport) -> Void,
        installEncoder: @MainActor (ProtocolEncoder) -> Void,
        installDelivery: DeliveryInstaller,
        onReaderDisconnect: @escaping @Sendable (ProtocolEncoder, UInt64) -> Void
    ) throws -> Connection {
        oldEncoder?.disconnect(reason: .expectedTeardown)
        oldReader?.stop()
        invalidate()

        let encoder = try encoderFactory(EncoderRequest(
            output: writeHandle,
            onTransportFailure: onTransportFailure
        ))
        installEncoder(encoder)

        let handoff = installDelivery(connectionID)
        let reader = ProtocolReader(
            input: readHandle,
            maxPayloadLength: resourcePolicy.wire.payloadBytes,
            decoder: { [resourcePolicy] data in
                try decodeFrame(from: data, policy: resourcePolicy)
            },
            handler: { frame in
                handoff.deliver(frame)
            },
            onDecodeFailure: { error in
                handoff.deliver(error)
            },
            onDisconnect: {
                onReaderDisconnect(encoder, connectionID)
            },
            acquireAdmission: { handoff.acquireAdmission() },
            cancelAdmission: { handoff.cancel() }
        )
        reader.start()
        return Connection(encoder: encoder, reader: reader)
    }
}
