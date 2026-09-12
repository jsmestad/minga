import AppKit

/// Save, Discard, or Cancel selected in the native application-quit prompt.
enum ApplicationQuitDecision: UInt8, Sendable {
    case save = 0
    case discard = 1
    case cancel = 2
}

/// Maps one synchronous AppKit delegate callback to the correlated quit handshake.
@MainActor
enum ApplicationTerminationPolicy {
    static func reply(
        coreIsLive: Bool,
        coordinator: ApplicationQuitCoordinator?
    ) -> NSApplication.TerminateReply {
        guard coreIsLive else { return .terminateNow }
        guard let coordinator else { return .terminateCancel }
        return coordinator.begin() == .pending ? .terminateLater : .terminateCancel
    }
}

/// Owns the AppKit side of one correlated application termination handshake.
///
/// The coordinator tracks only transport and request identity.
/// Dirty-buffer inventory and every save or discard decision remain authoritative on the BEAM.
@MainActor
final class ApplicationQuitCoordinator {
    typealias DecisionPresenter = (_ dirtyCount: UInt16, _ completion: @escaping (ApplicationQuitDecision) -> Void) -> Void

    enum State: Equatable {
        case idle
        case awaitingResponse(requestID: UInt32, connectionID: UInt64)
        case awaitingDecision(requestID: UInt32, connectionID: UInt64)
        case proceeding(requestID: UInt32, connectionID: UInt64)
    }

    enum CoreExitDisposition: Equatable {
        case noPendingQuit
        case approvedTermination
        case cancelledTermination
    }

    enum BeginDisposition: Equatable {
        case pending
        case rejected
    }

    private(set) var state: State = .idle
    private var nextRequestID: UInt32 = 1
    private var connectionID: UInt64 = 1
    private let sendRequest: (UInt32) -> Bool
    private let sendDecision: (UInt32, ApplicationQuitDecision) -> Bool
    private let presentDecision: DecisionPresenter
    private let dismissDecision: () -> Void
    private let replyToAppKit: (Bool) -> Void
    private let presentFailure: (String) -> Void
    private let restoreFocus: () -> Void

    init(
        sendRequest: @escaping (UInt32) -> Bool,
        sendDecision: @escaping (UInt32, ApplicationQuitDecision) -> Bool,
        presentDecision: @escaping DecisionPresenter,
        dismissDecision: @escaping () -> Void = {},
        replyToAppKit: @escaping (Bool) -> Void,
        presentFailure: @escaping (String) -> Void,
        restoreFocus: @escaping () -> Void
    ) {
        self.sendRequest = sendRequest
        self.sendDecision = sendDecision
        self.presentDecision = presentDecision
        self.dismissDecision = dismissDecision
        self.replyToAppKit = replyToAppKit
        self.presentFailure = presentFailure
        self.restoreFocus = restoreFocus
    }

    /// Begins one request or reuses the request already pending with AppKit.
    func begin() -> BeginDisposition {
        guard state == .idle else { return .pending }

        let requestID = allocateRequestID()
        let requestConnectionID = connectionID
        state = .awaitingResponse(requestID: requestID, connectionID: requestConnectionID)

        guard sendRequest(requestID) else {
            state = .idle
            presentFailure("Minga could not contact the editor core. Quit was cancelled.")
            restoreFocus()
            return .rejected
        }

        return .pending
    }

    /// Applies one response only when both the connection and request still match.
    func receive(_ response: ApplicationQuitResponse) {
        let expectedConnectionID = connectionID
        guard requestMatches(response.requestID, connectionID: expectedConnectionID) else { return }

        switch response.outcome {
        case .needsDecision:
            guard case let .awaitingResponse(activeRequestID, activeConnectionID) = state,
                  activeRequestID == response.requestID,
                  activeConnectionID == expectedConnectionID else { return }
            state = .awaitingDecision(requestID: response.requestID, connectionID: expectedConnectionID)
            presentDecision(response.dirtyCount) { [weak self] decision in
                self?.resolveDecision(
                    decision,
                    requestID: response.requestID,
                    connectionID: expectedConnectionID
                )
            }

        case .proceeding:
            guard case let .awaitingResponse(activeRequestID, activeConnectionID) = state,
                  activeRequestID == response.requestID,
                  activeConnectionID == expectedConnectionID else { return }
            state = .proceeding(requestID: response.requestID, connectionID: expectedConnectionID)

        case .cancelled:
            cancel(requestID: response.requestID, connectionID: expectedConnectionID, message: nil)

        case .saveFailed:
            let subject = response.bufferName.isEmpty ? "A buffer" : response.bufferName
            let reason = response.detail.isEmpty ? "could not be saved" : response.detail
            cancel(
                requestID: response.requestID,
                connectionID: expectedConnectionID,
                message: "Quit was cancelled. \(subject): \(reason)"
            )
        }
    }

    /// Completes AppKit termination only after the matching core actually exits.
    func coreDidExit() -> CoreExitDisposition {
        switch state {
        case .proceeding(_, let expectedConnectionID) where expectedConnectionID == connectionID:
            state = .idle
            replyToAppKit(true)
            return .approvedTermination

        case .awaitingResponse(let requestID, let expectedConnectionID),
             .awaitingDecision(let requestID, let expectedConnectionID):
            cancel(
                requestID: requestID,
                connectionID: expectedConnectionID,
                message: "The editor core disconnected before it confirmed quit. Quit was cancelled."
            )
            return .cancelledTermination

        case .idle, .proceeding:
            return .noPendingQuit
        }
    }

    /// Rejects every pending response from an old transport after reconnection.
    func replaceConnection() {
        let previousState = state

        switch previousState {
        case .awaitingResponse(let requestID, let oldConnectionID),
             .awaitingDecision(let requestID, let oldConnectionID):
            cancel(
                requestID: requestID,
                connectionID: oldConnectionID,
                message: "The editor core connection changed before quit completed. Quit was cancelled."
            )

        case .proceeding:
            state = .idle
            replyToAppKit(false)
            presentFailure("The editor core restarted before quit completed. Quit was cancelled.")
            restoreFocus()

        case .idle:
            break
        }

        connectionID &+= 1
    }

    /// Cancels a pending AppKit attempt when a live transport disappears without a confirmed core exit.
    func transportDidDisconnect() {
        switch state {
        case .awaitingResponse(let requestID, let expectedConnectionID),
             .awaitingDecision(let requestID, let expectedConnectionID):
            cancel(
                requestID: requestID,
                connectionID: expectedConnectionID,
                message: "The editor core connection closed before the process exited. Quit was cancelled."
            )

        case .proceeding:
            state = .idle
            replyToAppKit(false)
            presentFailure("The editor core connection closed before the process exited. Quit was cancelled.")
            restoreFocus()

        case .idle:
            break
        }
    }

    private func resolveDecision(
        _ decision: ApplicationQuitDecision,
        requestID: UInt32,
        connectionID expectedConnectionID: UInt64
    ) {
        guard case let .awaitingDecision(activeRequestID, activeConnectionID) = state,
              activeRequestID == requestID,
              activeConnectionID == expectedConnectionID,
              connectionID == expectedConnectionID else { return }

        state = .awaitingResponse(requestID: requestID, connectionID: expectedConnectionID)
        guard sendDecision(requestID, decision) else {
            cancel(
                requestID: requestID,
                connectionID: expectedConnectionID,
                message: "Minga could not send the quit decision to the editor core. Quit was cancelled."
            )
            return
        }
    }

    private func requestMatches(_ requestID: UInt32, connectionID expectedConnectionID: UInt64) -> Bool {
        switch state {
        case let .awaitingResponse(activeRequestID, activeConnectionID),
             let .awaitingDecision(activeRequestID, activeConnectionID),
             let .proceeding(activeRequestID, activeConnectionID):
            return activeRequestID == requestID
                && activeConnectionID == expectedConnectionID
                && connectionID == expectedConnectionID
        case .idle:
            return false
        }
    }

    private func cancel(requestID: UInt32, connectionID expectedConnectionID: UInt64, message: String?) {
        guard requestMatches(requestID, connectionID: expectedConnectionID) else { return }
        let shouldDismissDecision: Bool
        if case .awaitingDecision = state {
            shouldDismissDecision = true
        } else {
            shouldDismissDecision = false
        }
        state = .idle
        if shouldDismissDecision { dismissDecision() }
        replyToAppKit(false)
        if let message { presentFailure(message) }
        restoreFocus()
    }

    private func allocateRequestID() -> UInt32 {
        let allocated = nextRequestID
        nextRequestID = nextRequestID == UInt32.max ? 1 : nextRequestID + 1
        return allocated
    }
}
