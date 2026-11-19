import Foundation

/// Resolves process death, ordered protocol closure, and the application quit handshake for one connection.
@MainActor
final class EditorCoreLifecycle {
    private enum State: Equatable {
        case connected
        case awaitingFirstFrame
        case startupTimedOut
        case awaitingProcessExit
        case awaitingProcessExitDuringStartup(timedOut: Bool)
        case awaitingQuitConfirmation
        case terminated
    }

    enum FirstFrameDisposition {
        case committed
        case recovered
        case ignored
    }

    private let quitCoordinator: ApplicationQuitCoordinator
    private let processManager: BEAMProcessManager?
    private let retireConnection: () -> Void
    private let presentTransportFailure: (String) -> Void
    private let presentCoreStopped: () -> Void
    private let terminateApplication: () -> Void
    private let closureTimeout: TimeInterval
    private let startupTimeout: TimeInterval
    private var state = State.connected
    private var deadlineToken: UInt64?
    private var nextDeadlineToken: UInt64 = 0

    init(
        quitCoordinator: ApplicationQuitCoordinator,
        processManager: BEAMProcessManager?,
        closureTimeout: TimeInterval = 2,
        startupTimeout: TimeInterval = 20,
        retireConnection: @escaping () -> Void,
        presentTransportFailure: @escaping (String) -> Void,
        presentCoreStopped: @escaping () -> Void,
        terminateApplication: @escaping () -> Void
    ) {
        self.quitCoordinator = quitCoordinator
        self.processManager = processManager
        self.closureTimeout = closureTimeout
        self.startupTimeout = startupTimeout
        self.retireConnection = retireConnection
        self.presentTransportFailure = presentTransportFailure
        self.presentCoreStopped = presentCoreStopped
        self.terminateApplication = terminateApplication
    }

    var isAwaitingFirstFrame: Bool { state == .awaitingFirstFrame }
    var startupHasTimedOut: Bool {
        state == .startupTimedOut || state == .awaitingProcessExitDuringStartup(timedOut: true)
    }

    private var isStarting: Bool {
        switch state {
        case .awaitingFirstFrame, .startupTimedOut, .awaitingProcessExitDuringStartup:
            return true
        case .connected, .awaitingProcessExit, .awaitingQuitConfirmation, .terminated:
            return false
        }
    }

    /// Keeps the startup wait bounded even if the peer leaves both pipes open.
    func waitForFirstFrame(onTimeout: @escaping @MainActor @Sendable () -> Void) {
        guard state == .connected else { return }
        state = .awaitingFirstFrame
        scheduleDeadline(after: startupTimeout) { lifecycle in
            lifecycle.state = .startupTimedOut
            lifecycle.quitCoordinator.startupDidFail()
            onTimeout()
        }
    }

    /// Does not complete startup when a transport failure has already won the race.
    func firstFrameDidCommit() -> FirstFrameDisposition {
        switch state {
        case .awaitingFirstFrame, .startupTimedOut:
            let recovered = startupHasTimedOut
            deadlineToken = nil
            state = .connected
            quitCoordinator.startupDidFinish()
            return recovered ? .recovered : .committed
        case .connected, .awaitingProcessExit, .awaitingProcessExitDuringStartup, .awaitingQuitConfirmation, .terminated:
            return .ignored
        }
    }

    /// Retires the connection only after the user chooses to quit.
    func abandonTimedOutStartup() -> Bool {
        guard startupHasTimedOut else { return false }
        stop()
        retireConnection()
        return true
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
        guard state != .terminated, state != .awaitingQuitConfirmation else { return }
        waitForProcessExit(message: message)
    }

    /// EOF follows final response delivery. Bundle mode also waits for owned process death; dev mode has no separate process observer.
    func readerDidClose() {
        guard state != .terminated else { return }
        if let disposition = quitCoordinator.transportDidDisconnect() {
            finishCoreTermination(disposition)
        } else if processManager != nil {
            waitForProcessExit(message: "The editor core connection closed unexpectedly.")
        } else if isStarting {
            failStartup(message: "The editor core connection closed before the first frame.")
        } else {
            let disposition = quitCoordinator.coreDidExit()
            finishCoreTermination(disposition)
            if disposition == .noPendingQuit { terminateApplication() }
        }
    }

    /// Claims startup failures and pending quits before the process manager applies its restart policy.
    func coreDidExit() -> Bool {
        guard state != .terminated else { return false }
        if isStarting {
            failStartup(message: "The editor core exited before the first frame.")
            return true
        }
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

    private func waitForProcessExit(message: String) {
        if state == .awaitingFirstFrame { deadlineToken = nil }
        state = isStarting ? .awaitingProcessExitDuringStartup(timedOut: startupHasTimedOut) : .awaitingProcessExit
        awaitCoreTermination(message: message)
    }

    private func failStartup(message: String) {
        quitCoordinator.startupDidFail()
        processManager?.beginAppShutdown()
        stop()
        retireConnection()
        presentTransportFailure(message)
    }

    private func awaitCoreTermination(message: String) {
        scheduleDeadline(after: closureTimeout) { lifecycle in
            if lifecycle.state == .awaitingQuitConfirmation,
               let disposition = lifecycle.quitCoordinator.transportDidDisconnect() {
                lifecycle.finishCoreTermination(disposition)
            } else if lifecycle.isStarting {
                lifecycle.failStartup(message: message)
            } else {
                lifecycle.quitCoordinator.transportRecoveryDidExpire()
                lifecycle.stop()
                lifecycle.retireConnection()
                lifecycle.presentTransportFailure(message)
            }
        }
    }

    private func scheduleDeadline(
        after timeout: TimeInterval,
        action: @escaping @MainActor @Sendable (EditorCoreLifecycle) -> Void
    ) {
        guard deadlineToken == nil else { return }
        nextDeadlineToken &+= 1
        let token = nextDeadlineToken
        deadlineToken = token
        // Main-actor Tasks are not guaranteed to run in terminateLater's modal loop. Use the same native delivery path as protocol and process callbacks.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { [weak self] in
            MainRunLoopAction {
                guard let self, self.deadlineToken == token else { return }
                self.deadlineToken = nil
                action(self)
            }.enqueue()
        }
    }
}
