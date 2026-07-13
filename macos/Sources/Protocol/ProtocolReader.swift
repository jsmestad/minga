/// Reads `{:packet, 4}` framed messages from stdin on a background thread.
///
/// Each message is a 4-byte big-endian length prefix followed by that many
/// bytes of payload. The payload may contain multiple concatenated commands
/// (the BEAM batches an entire render frame into one message).

import Foundation
import MingaProtocol
import os
import Synchronization

/// Reads framed protocol messages from an input file handle and dispatches them.
///
/// Defaults to stdin (BEAM is parent, spawned us). In bundle mode, the
/// BEAMProcessManager passes the child process's stdout pipe instead.
final class ProtocolReader: @unchecked Sendable {
    private static let defaultMaxPayloadLength = FrameResourcePolicy.default.wire.payloadBytes

    private var thread: Thread?
    private let input: FileHandle
    private let decoder: @Sendable (Data) throws -> DecodedFrame
    private let handler: @Sendable (DecodedFrame) -> Void
    private let onDecodeFailure: @Sendable (DecodedFrameFailure) -> Void
    private let onDisconnect: @Sendable () -> Void
    private let acquireAdmission: @Sendable () -> Bool
    private let cancelAdmission: @Sendable () -> Void
    private let maxPayloadLength: Int
    private let running = Mutex(false)

    /// Creates a reader that decodes complete packets on its background thread.
    /// Only one immutable `DecodedFrame` is delivered for each successful packet.
    init(
        input: FileHandle = .standardInput,
        maxPayloadLength: Int = ProtocolReader.defaultMaxPayloadLength,
        decoder: @escaping @Sendable (Data) throws -> DecodedFrame = { data in try decodeFrame(from: data) },
        handler: @escaping @Sendable (DecodedFrame) -> Void,
        onDecodeFailure: @escaping @Sendable (DecodedFrameFailure) -> Void,
        onDisconnect: @escaping @Sendable () -> Void,
        acquireAdmission: @escaping @Sendable () -> Bool = { true },
        cancelAdmission: @escaping @Sendable () -> Void = {}
    ) {
        self.input = input
        self.maxPayloadLength = maxPayloadLength
        self.decoder = decoder
        self.handler = handler
        self.onDecodeFailure = onDecodeFailure
        self.onDisconnect = onDisconnect
        self.acquireAdmission = acquireAdmission
        self.cancelAdmission = cancelAdmission
    }

    /// Start reading on a background thread.
    func start() {
        let alreadyRunning = running.withLock { val -> Bool in
            if val { return true }
            val = true
            return false
        }
        guard !alreadyRunning else { return }

        let t = Thread { [weak self] in
            self?.readLoop()
        }
        t.name = "minga-protocol-reader"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    /// Stop the reader. Note: the thread blocks on read(), so this
    /// only takes effect after the current read completes or stdin closes.
    func stop() {
        running.withLock { $0 = false }
        cancelAdmission()
    }

    // MARK: - Private

    private func readLoop() {
        while running.withLock({ $0 }) {
            // Reserve the sole reader-to-main slot before reading any payload bytes.
            guard acquireAdmission() else { return }
            // Read 4-byte length header.
            let lenData = input.readData(ofLength: 4)
            guard lenData.count == 4 else {
                // stdin closed or short read: BEAM has exited.
                cancelAdmission()
                onDisconnect()
                return
            }

            let length = Int(lenData[0]) << 24 | Int(lenData[1]) << 16 |
                         Int(lenData[2]) << 8 | Int(lenData[3])

            guard length > 0, length <= maxPayloadLength else {
                os_log(.error, log: protocolLog, "Protocol payload length %{public}d outside valid range 1...%{public}d; disconnecting to avoid stream desync", length, maxPayloadLength)
                cancelAdmission()
                onDisconnect()
                return
            }

            // Read the payload.
            var payload = Data()
            var remaining = length
            while remaining > 0 {
                let chunk = input.readData(ofLength: remaining)
                guard !chunk.isEmpty else {
                    cancelAdmission()
                    onDisconnect()
                    return
                }
                payload.append(chunk)
                remaining -= chunk.count
            }

            os_signpost(.event, log: protocolLog, name: "ProtocolPayloadReceived", "bytes=%{public}d", payload.count)
            do {
                let frame = try decoder(payload)
                os_signpost(
                    .event,
                    log: protocolLog,
                    name: "ProtocolPayloadDecoded",
                    "bytes=%{public}d copied=%{public}d allocations=%{public}d",
                    frame.metrics.packetBytes,
                    frame.metrics.bytesCopied,
                    frame.metrics.allocations
                )
                handler(frame)
            } catch let failure as DecodedFrameFailure {
                onDecodeFailure(failure)
            } catch let error as ProtocolDecodeError {
                onDecodeFailure(DecodedFrameFailure(
                    error: error.unwrappedFrameFailure,
                    envelope: error.frameEnvelope
                ))
            } catch {
                onDecodeFailure(DecodedFrameFailure(error: .malformed, envelope: nil))
            }
        }
    }
}
