import Foundation

/// Resolves process death, ordered protocol closure, and the application quit handshake for one connection.
@MainActor
final class EditorCoreLifecycle {
    private enum State {
        case connected
        case awaitingProcessExit
        case awaitingQuitConfirmation
        case terminated
    }

    private let quitCoordinator: ApplicationQuitCoordinator
    private let processManager: BEAMProcessManager?
    private let retireConnection: () -> Void
    private let presentTransportFailure: (String) -> Void
    private let presentCoreStopped: () -> Void
    private let terminateApplication: () -> Void
    private let closureTimeout: TimeInterval
    private var state = State.connected
    private var deadlineToken: UInt64?
    private var nextDeadlineToken: UInt64 = 0

    init(
        quitCoordinator: ApplicationQuitCoordinator,
        processManager: BEAMProcessManager?,
        closureTimeout: TimeInterval = 2,
        retireConnection: @escaping () -> Void,
        presentTransportFailure: @escaping (String) -> Void,
        presentCoreStopped: @escaping () -> Void,
        terminateApplication: @escaping () -> Void
    ) {
        self.quitCoordinator = quitCoordinator
        self.processManager = processManager
        self.closureTimeout = closureTimeout
        self.retireConnection = retireConnection
        self.presentTransportFailure = presentTransportFailure
        self.presentCoreStopped = presentCoreStopped
        self.terminateApplication = terminateApplication
    }

    /// Drains a final response even when the independent process callback arrived first.
    func receive(_ response: ApplicationQuitResponse) {
        guard state != .terminated else { return }
        if let disposition = quitCoordinator.receive(response) {
            finishCoreTermination(disposition)
        }
    }

    /// Stops neither final reader delivery nor a pending quit when a writer fails before EOF.
    func transportDidFail(message: String) {
        guard state == .connected || state == .awaitingProcessExit else { return }
        state = .awaitingProcessExit
        awaitCoreTermination(message: message)
    }

    /// EOF follows final response delivery. Bundle mode also waits for owned process death; dev mode has no separate process observer.
    func readerDidClose() {
        guard state != .terminated else { return }
        if let disposition = quitCoordinator.transportDidDisconnect() {
            finishCoreTermination(disposition)
        } else if processManager != nil {
            state = .awaitingProcessExit
            awaitCoreTermination(message: "The editor core connection closed unexpectedly.")
        } else {
            let disposition = quitCoordinator.coreDidExit()
            finishCoreTermination(disposition)
            if disposition == .noPendingQuit { terminateApplication() }
        }
    }

    /// Claims pending application quits before the process manager applies its automatic restart policy.
    func coreDidExit() -> Bool {
        guard state != .terminated else { return false }
        deadlineToken = nil
        let disposition = quitCoordinator.coreDidExit()
        if disposition == .awaitingConfirmation {
            state = .awaitingQuitConfirmation
            awaitCoreTermination(message: "The editor core exited before it confirmed quit.")
            return true
        }
        finishCoreTermination(disposition)
        return disposition != .noPendingQuit
    }

    /// Retires deadline callbacks and quit identity before the replacement starts delivering events.
    func replaceConnection() {
        deadlineToken = nil
        state = .connected
        quitCoordinator.replaceConnection()
    }

    /// Prevents queued deadlines or failures from reviving recovery during application termination.
    func stop() {
        deadlineToken = nil
        state = .terminated
    }

    private func finishCoreTermination(_ disposition: ApplicationQuitCoordinator.CoreExitDisposition) {
        guard disposition != .awaitingConfirmation else { return }
        stop()
        retireConnection()
        switch disposition {
        case .approvedTermination:
            processManager?.beginAppShutdown()
        case .cancelledTermination:
            if processManager != nil {
                presentCoreStopped()
            } else {
                presentTransportFailure("The editor core disconnected before it confirmed quit.")
            }
        case .noPendingQuit, .awaitingConfirmation:
            break
        }
    }

    private func awaitCoreTermination(message: String) {
        guard deadlineToken == nil else { return }
        nextDeadlineToken &+= 1
        let token = nextDeadlineToken
        deadlineToken = token
        // Main-actor Tasks are not guaranteed to run in terminateLater's modal loop. Use the same native delivery path as protocol and process callbacks.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + closureTimeout) { [weak self] in
            MainRunLoopAction {
                guard let self, self.deadlineToken == token else { return }
                self.deadlineToken = nil
                if self.state == .awaitingQuitConfirmation,
                   let disposition = self.quitCoordinator.transportDidDisconnect() {
                    self.finishCoreTermination(disposition)
                } else {
                    self.quitCoordinator.transportRecoveryDidExpire()
                    self.stop()
                    self.retireConnection()
                    self.presentTransportFailure(message)
                }
            }.enqueue()
        }
    }
}
