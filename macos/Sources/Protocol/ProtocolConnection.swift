import Darwin
import Foundation
import MingaProtocol

/// Owns one protocol handle pair and every resource whose lifetime is tied to it.
///
/// `stop()` retires delivery immediately, but it does not claim to interrupt a `FileHandle` read already blocked in `ProtocolReader`. The transport owner must close the pipe or let the peer finish so that retired read can return.
@MainActor
final class ProtocolConnection {
    typealias CurrentConnection = @MainActor (UInt64) -> Bool
    typealias Consumer = @MainActor (DecodedFrameEvent, UInt64) -> Void
    typealias Decoder = @Sendable (Data) throws -> DecodedFrame
    typealias EncoderFactory = @MainActor (FileHandle) throws -> ProtocolEncoder

    let connectionID: UInt64
    let encoder: ProtocolEncoder

    private let reader: ProtocolReader
    private let handoff: ProtocolEventHandoff
    private var consumerTask: Task<Void, Never>?
    private var started = false
    private var stopped = false

    init(
        connectionID: UInt64,
        readHandle: FileHandle,
        writeHandle: FileHandle,
        resourcePolicy: FrameResourcePolicy,
        isCurrent: @escaping CurrentConnection,
        consume: @escaping Consumer,
        onTransportFailure: @escaping @MainActor @Sendable (OutboundTransportFailureReport) -> Void,
        onInputRejection: @escaping @MainActor @Sendable (OutboundInputRejection) -> Void,
        onReaderDisconnect: @escaping @MainActor @Sendable (ProtocolEncoder, UInt64) -> Void,
        decoder: Decoder? = nil,
        encoderFactory: EncoderFactory? = nil
    ) throws {
        self.connectionID = connectionID

        let encoder: ProtocolEncoder
        if let encoderFactory {
            encoder = try encoderFactory(writeHandle)
        } else {
            encoder = try ProtocolEncoder(
                output: writeHandle,
                onTransportFailure: onTransportFailure,
                onInputRejection: onInputRejection
            )
        }
        self.encoder = encoder

        let handoff = ProtocolEventHandoff(connectionID: connectionID)
        self.handoff = handoff
        let decode: Decoder = decoder ?? { [resourcePolicy] data in
            try decodeFrame(from: data, policy: resourcePolicy)
        }
        reader = ProtocolReader(
            input: readHandle,
            maxPayloadLength: resourcePolicy.wire.payloadBytes,
            decoder: decode,
            handler: { frame in
                handoff.deliver(frame)
            },
            onDecodeFailure: { failure in
                handoff.deliver(failure)
            },
            onDisconnect: {
                Task { @MainActor in
                    onReaderDisconnect(encoder, connectionID)
                }
            },
            acquireAdmission: { handoff.acquireAdmission() },
            cancelAdmission: { handoff.cancel() }
        )
        consumerTask = Task { @MainActor in
            for await event in handoff.events {
                handoff.releaseAdmission()
                guard !Task.isCancelled, isCurrent(connectionID) else { continue }
                consume(event, connectionID)
            }
        }
    }

    /// Retires the current owner before attempting construction, then reports initialization failure without reviving retired delivery.
    static func replacing(
        _ current: ProtocolConnection?,
        connectionID: UInt64,
        readHandle: FileHandle,
        writeHandle: FileHandle,
        resourcePolicy: FrameResourcePolicy,
        invalidate: @MainActor () -> Void,
        isCurrent: @escaping CurrentConnection,
        consume: @escaping Consumer,
        onTransportFailure: @escaping @MainActor @Sendable (OutboundTransportFailureReport) -> Void,
        onInputRejection: @escaping @MainActor @Sendable (OutboundInputRejection) -> Void,
        onReaderDisconnect: @escaping @MainActor @Sendable (ProtocolEncoder, UInt64) -> Void,
        onInitializationFailure: @MainActor (OutboundTransportInitializationError) -> Void,
        decoder: Decoder? = nil,
        encoderFactory: EncoderFactory? = nil
    ) -> ProtocolConnection? {
        current?.stop()
        invalidate()

        do {
            return try ProtocolConnection(
                connectionID: connectionID,
                readHandle: readHandle,
                writeHandle: writeHandle,
                resourcePolicy: resourcePolicy,
                isCurrent: isCurrent,
                consume: consume,
                onTransportFailure: onTransportFailure,
                onInputRejection: onInputRejection,
                onReaderDisconnect: onReaderDisconnect,
                decoder: decoder,
                encoderFactory: encoderFactory
            )
        } catch let error as OutboundTransportInitializationError {
            onInitializationFailure(error)
            return nil
        } catch {
            onInitializationFailure(.nonBlockingSetupFailed(errorCode: EIO))
            return nil
        }
    }

    /// Starts the sole reader after the application has installed all consumers.
    func start() {
        guard !started, !stopped else { return }
        started = true
        reader.start()
    }

    /// Retires admission, ordered delivery, outbound writes, and future reads. Idempotent and nonblocking.
    func stop() {
        guard !stopped else { return }
        stopped = true
        handoff.cancel()
        consumerTask?.cancel()
        consumerTask = nil
        reader.stop()
        encoder.disconnect(reason: .expectedTeardown)
    }

    func waitForReaderAdmissionForTesting() {
        handoff.waitForAdmissionOwnershipForTesting()
    }

    func waitForBlockedReaderAdmissionForTesting() {
        handoff.waitForBlockedAdmissionForTesting()
    }

    func acquireReaderAdmissionForTesting() -> Bool {
        handoff.acquireAdmission()
    }

    var isStoppedForTesting: Bool { stopped }
}
