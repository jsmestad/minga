/// Reads `{:packet, 4}` framed messages from stdin on a background thread.
///
/// Each message is a 4-byte big-endian length prefix followed by that many
/// bytes of payload. The payload may contain multiple concatenated commands
/// (the BEAM batches an entire render frame into one message).

import Foundation
import Synchronization

/// Reads framed protocol messages from an input file handle and dispatches them.
///
/// Defaults to stdin (BEAM is parent, spawned us). In bundle mode, the
/// BEAMProcessManager passes the child process's stdout pipe instead.
final class ProtocolReader: @unchecked Sendable {
    private var thread: Thread?
    private let input: FileHandle
    private let handler: @Sendable (Data) -> Void
    private let onDisconnect: @Sendable () -> Void
    private let running = Mutex(false)

    /// Create a reader that calls `handler` with each payload on a background thread.
    /// `onDisconnect` is called when the input closes (peer exited).
    ///
    /// - Parameters:
    ///   - input: File handle to read from. Defaults to `.standardInput`.
    ///   - handler: Called with each decoded payload.
    ///   - onDisconnect: Called when the input stream closes.
    init(input: FileHandle = .standardInput,
         handler: @escaping @Sendable (Data) -> Void,
         onDisconnect: @escaping @Sendable () -> Void) {
        self.input = input
        self.handler = handler
        self.onDisconnect = onDisconnect
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
    }

    // MARK: - Private

    private func readLoop() {
        while running.withLock({ $0 }) {
            // Read 4-byte length header.
            let lenData = input.readData(ofLength: 4)
            guard lenData.count == 4 else {
                // stdin closed or short read: BEAM has exited.
                onDisconnect()
                return
            }

            let length = Int(lenData[0]) << 24 | Int(lenData[1]) << 16 |
                         Int(lenData[2]) << 8 | Int(lenData[3])

            guard length > 0, length < 1_048_576 else {
                // Sanity check: skip zero-length or absurdly large messages.
                continue
            }

            // Read the payload.
            var payload = Data()
            var remaining = length
            while remaining > 0 {
                let chunk = input.readData(ofLength: remaining)
                guard !chunk.isEmpty else {
                    onDisconnect()
                    return
                }
                payload.append(chunk)
                remaining -= chunk.count
            }

            handler(payload)
        }
    }
}
