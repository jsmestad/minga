import Foundation
import MingaProtocol

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
