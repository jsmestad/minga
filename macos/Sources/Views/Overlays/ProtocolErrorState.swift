/// Observable state for a protocol_error (0x18) from the BEAM.
///
/// The BEAM emits protocol_error when this frontend's handshake
/// protocol_version does not match the BEAM's compiled-in version, so the
/// frontend will never reach ready. Instead of leaving a blank window, the UI
/// shows a blocking full-window overlay carrying the BEAM-supplied reason
/// (ticket #2237). Once set, the error latches for that protocol connection.

import SwiftUI

@MainActor
@Observable
public final class ProtocolErrorState {
    public init() {}
    /// The BEAM-supplied reason, or nil when no protocol_error has arrived.
    /// While non-nil, ContentView renders a blocking overlay over everything.
    public private(set) var message: String?

    /// Whether the blocking error overlay should be shown.
    public var isPresented: Bool { message != nil }

    /// Latches a protocol_error reason for the active connection.
    public func present(message: String) {
        self.message = message
    }

    /// Clears a prior connection's fatal handshake result before replacement admission starts.
    public func resetConnection() {
        message = nil
    }
}
