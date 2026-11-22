/// Reads `{:packet, 4}` framed messages from stdin on a background thread.
///
/// Each message is a 4-byte big-endian length prefix followed by that many
/// bytes of payload. The payload may contain multiple concatenated commands
/// (the BEAM batches an entire render frame into one message).

import Foundation
import MingaProtocol
import MingaUI
import os
import Synchronization

/// Reads framed protocol messages from an input file handle and dispatches them.
///
/// Defaults to stdin (BEAM is parent, spawned us). In bundle mode, the
/// BEAMProcessManager passes the child process's stdout pipe instead.
final class ProtocolReader: @unchecked Sendable {
    // @unchecked: `thread` is a mutable var, written only by start() after the `running` Mutex admits it, and never read.
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

    /// Reads a complete header or payload even when the pipe splits it across writes.
    private func readExactly(_ length: Int) throws -> Data? {
        guard var data = try input.read(upToCount: length), !data.isEmpty else { return nil }
        while data.count < length {
            guard let chunk = try input.read(upToCount: length - data.count), !chunk.isEmpty else { return nil }
            data.append(chunk)
        }
        return data
    }

    private func readLoop() {
        while running.withLock({ $0 }) {
            // FileHandle returns autoreleased NSData; drain each packet so read buffers do not live until this thread exits.
            guard autoreleasepool(invoking: readPacket) else { return }
        }
    }

    private func readPacket() -> Bool {
        // Reserve the sole reader-to-main slot before reading any payload bytes.
        guard acquireAdmission() else { return false }
        let lenData: Data
        do {
            guard let header = try readExactly(4) else { return disconnect() }
            lenData = header
        } catch {
            return disconnect(readError: error)
        }

        let length = Int(lenData[0]) << 24 | Int(lenData[1]) << 16 |
                     Int(lenData[2]) << 8 | Int(lenData[3])

        guard length > 0, length <= maxPayloadLength else {
            return disconnect(message: "Protocol payload length \(length) outside valid range 1...\(maxPayloadLength); disconnecting to avoid stream desync")
        }

        let payload: Data
        do {
            guard let body = try readExactly(length) else { return disconnect() }
            payload = body
        } catch {
            return disconnect(readError: error)
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
        return true
    }

    private func disconnect(message: String? = nil, readError: (any Error)? = nil) -> Bool {
        // Intentional retirement can close the descriptor while the blocking read unwinds.
        let reportReadError = readError != nil && running.withLock { $0 }
        cancelAdmission()
        onDisconnect()
        if let message {
            PortLogger.report(.error, message, to: protocolLogger)
        } else if let readError, reportReadError {
            PortLogger.report(.error, "Protocol read failed", to: protocolLogger, privateDetail: readError.localizedDescription)
        }
        return false
    }
}
