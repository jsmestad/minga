/// Routes log messages to the BEAM via the port protocol.
///
/// Call `PortLogger.setup(encoder:)` once at startup with the real
/// ProtocolEncoder. After that, use the module-level functions to log
/// at each level. Messages appear in the editor's `*Messages*` buffer
/// prefixed with `[GUI/{level}]`.
///
/// Before setup (or if encoder is nil), messages are silently dropped.
/// This avoids crashes during early init when stdout isn't ready yet.

import Foundation
import os

/// Thread-safe log router. Uses OSAllocatedUnfairLock to protect the
/// encoder reference so PortLogger can be called from any thread.
final class PortLogger: Sendable {
    /// Singleton accessed via static methods below.
    private static let shared = PortLogger()

    /// OSAllocatedUnfairLock wraps the mutable state and is Sendable,
    /// so the compiler can verify thread safety without @unchecked.
    private let state = OSAllocatedUnfairLock<(any InputEncoder)?>(initialState: nil)

    /// Set the encoder used for all subsequent log calls.
    /// Call once during app startup after the ProtocolEncoder is created.
    static func setup(encoder: any InputEncoder) {
        shared.state.withLock { $0 = encoder }
    }

    private static func send(level: UInt8, message: String) {
        let encoder: (any InputEncoder)? = shared.state.withLock { $0 }
        encoder?.sendLog(level: level, message: message)
    }

    static func error(_ message: String) {
        send(level: LOG_LEVEL_ERR, message: message)
    }

    static func warn(_ message: String) {
        send(level: LOG_LEVEL_WARN, message: message)
    }

    static func info(_ message: String) {
        send(level: LOG_LEVEL_INFO, message: message)
    }

    static func debug(_ message: String) {
        send(level: LOG_LEVEL_DEBUG, message: message)
    }
}
