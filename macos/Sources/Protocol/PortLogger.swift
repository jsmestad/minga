import Foundation
import os
import Synchronization

/// Writes macOS diagnostics to unified logging and forwards them to the editor's Messages pane.
nonisolated public final class PortLogger: Sendable {
    /// Singleton accessed via static methods below.
    private static let shared = PortLogger()

    /// The unified logging subsystem used by the app, including development builds.
    public static let subsystem = "com.minga.editor"
    private static let osLog = Logger(subsystem: subsystem, category: "runtime")

    /// Log severity. Raw values match the frontend protocol.
    public enum Level: UInt8, Sendable {
        case error = 0
        case warning = 1
        case info = 2
        case debug = 3

        fileprivate var osLogType: OSLogType {
            switch self {
            case .error: .error
            case .warning: .default
            case .info: .info
            case .debug: .debug
            }
        }
    }

    /// Set `MINGA_DISABLE_OSLOG=1` to suppress os_log output (e.g., in CI
    /// or automated builds where Console.app output is unwanted).
    private static let osLogEnabled: Bool = {
        ProcessInfo.processInfo.environment["MINGA_DISABLE_OSLOG"] == nil
    }()

    private struct Entry {
        let level: Level
        let message: String
    }

    private struct Connection {
        var encoder: (any OutboundActionEncoding)?
        var pending: [Entry] = []
    }

    private let state = Mutex(Connection())

    /// Installs a ready encoder and forwards recent diagnostics recorded without a core.
    public static func setup(encoder: any OutboundActionEncoding) {
        let pending = shared.state.withLock {
            $0.encoder = encoder
            let pending = $0.pending
            $0.pending = []
            return pending
        }
        for entry in pending {
            send(entry)
        }
    }

    /// Clears the route only if it still uses the retiring encoder.
    public static func clearEncoder(_ encoder: (any OutboundActionEncoding)? = nil) {
        shared.state.withLock { connection in
            if encoder == nil || connection.encoder === encoder {
                connection.encoder = nil
            }
        }
    }

    private static func send(_ entry: Entry) {
        let action = OutboundAction.log(level: entry.level.rawValue, message: entry.message)
        while let encoder = shared.state.withLock({ connection in
            if connection.encoder == nil, entry.message.utf8.count <= 1024 {
                // Bound both retained memory and the burst sent on reconnection.
                if connection.pending.count == 32 { connection.pending.removeFirst() }
                connection.pending.append(entry)
            }
            return connection.encoder
        }) {
            // Admission is best effort. A known disconnect must not consume the record.
            guard encoder.send(action) == .rejected(.disconnected) else { return }
            clearEncoder(encoder)
        }
    }

    /// Reports a categorized diagnostic and forwards the public summary to the core on a best-effort basis.
    /// Private details stay in unified logging and are not copied into Messages or the BEAM log file.
    public static func report(_ level: Level, _ message: String, to logger: Logger, privateDetail: String? = nil) {
        if osLogEnabled {
            if let privateDetail {
                logger.log(level: level.osLogType, "\(message, privacy: .public): \(privateDetail, privacy: .private)")
            } else {
                logger.log(level: level.osLogType, "\(message, privacy: .public)")
            }
        }
        send(Entry(level: level, message: message))
    }

    public static func error(_ message: String) {
        report(.error, message, to: osLog)
    }

    public static func warn(_ message: String) {
        report(.warning, message, to: osLog)
    }

    /// Reports a runtime warning with details kept out of the Messages pane and BEAM log.
    public static func warn(_ message: String, privateDetail: String) {
        report(.warning, message, to: osLog, privateDetail: privateDetail)
    }

    public static func info(_ message: String) {
        report(.info, message, to: osLog)
    }

    /// Reports a runtime message with details kept out of the Messages pane and BEAM log.
    public static func info(_ message: String, privateDetail: String) {
        report(.info, message, to: osLog, privateDetail: privateDetail)
    }

    public static func debug(_ message: String) {
        report(.debug, message, to: osLog)
    }
}
