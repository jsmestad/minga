/// Detects frontend-to-BEAM stalls and presents a native recovery dialog.
///
/// The macOS frontend keeps accepting keyboard events even when the BEAM stops
/// reading from its port. If key events have been sent and no frame has
/// committed (`commit_frame`) for a few seconds, Ctrl-G becomes an explicit
/// recovery gesture.

import AppKit
import Darwin
import Foundation

struct OutboundConnectionState {
    private(set) var currentID: UInt64?
    private var nextID: UInt64 = 0
    private var failedCurrentConnection = false

    mutating func issueID() -> UInt64 {
        nextID &+= 1
        return nextID
    }

    mutating func install(id: UInt64) {
        currentID = id
        failedCurrentConnection = false
    }

    mutating func acceptFailure(for id: UInt64) -> Bool {
        guard currentID == id, !failedCurrentConnection else { return false }
        failedCurrentConnection = true
        return true
    }

    func isCurrent(_ id: UInt64) -> Bool {
        currentID == id
    }
}

@MainActor
final class RecoveryManager {
    enum TransportFailureDecision: Equatable {
        case restart
        case quit
    }

    typealias TransportFailurePresenter = @MainActor (
        _ message: String,
        _ canRestart: Bool,
        _ completion: @escaping @MainActor (TransportFailureDecision) -> Void
    ) -> @MainActor () -> Void

    @MainActor
    final class TransportFailureAlertPresentation {
        private enum State: Equatable {
            case pending
            case presenting
            case finished
        }

        let alert = NSAlert()
        private var state = State.pending

        func beginPresentation() -> Bool {
            guard state == .pending else { return false }
            state = .presenting
            return true
        }

        func finish() -> Bool {
            guard state == .presenting else { return false }
            state = .finished
            return true
        }

        func dismiss() {
            switch state {
            case .pending:
                state = .finished
            case .presenting:
                state = .finished
                NSApp.abortModal()
                alert.window.orderOut(nil)
            case .finished:
                break
            }
        }
    }

    private let timeoutSeconds: CFTimeInterval
    private let restartAction: @MainActor () -> Void
    private let transportFailurePresenter: TransportFailurePresenter
    private let quitAction: @MainActor () -> Void

    private(set) var lastFramePresentedTime: CFAbsoluteTime
    private(set) var keysSinceLastRender: Int = 0
    private(set) var isShowingAlert: Bool = false
    private(set) var transportFailureMessage: String?
    private var isShowingTransportFailure = false
    private var dismissTransportFailurePresentation: (@MainActor () -> Void)?

    init(
        timeoutSeconds: CFTimeInterval = 3.0,
        restartAction: @escaping @MainActor () -> Void = RecoveryManager.sendRestartSignalToParent,
        transportFailurePresenter: @escaping TransportFailurePresenter = RecoveryManager.presentTransportFailureAlert,
        quitAction: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.restartAction = restartAction
        self.transportFailurePresenter = transportFailurePresenter
        self.quitAction = quitAction
        self.lastFramePresentedTime = CFAbsoluteTimeGetCurrent()
    }

    /// Records that a frame committed (`commit_frame`) and presented.
    func onRenderReceived() {
        lastFramePresentedTime = CFAbsoluteTimeGetCurrent()
        keysSinceLastRender = 0
        isShowingAlert = false
    }

    /// Records that a key event was sent to the BEAM.
    func onKeySent() {
        keysSinceLastRender += 1
    }

    /// Returns true when user input is pending and the BEAM has not rendered within the timeout.
    func isUnresponsive(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Bool {
        keysSinceLastRender > 0 && now - lastFramePresentedTime > timeoutSeconds
    }

    /// Handles Ctrl-G. Returns true when the recovery gesture was consumed.
    @discardableResult
    func handleCtrlG() -> Bool {
        guard isUnresponsive() else { return false }
        guard !isShowingAlert else { return true }
        showRecoveryAlert()
        return true
    }

    /// Presents the recovery surface after the BEAM child process has exited and
    /// automatic restart gave up.
    ///
    /// Non-blocking by contract: the alert is scheduled on the next main-actor
    /// turn, so the caller (the process manager's termination handler) returns
    /// immediately and the main actor is never blocked by the termination path
    /// (#2698). The alert itself remains fully interactive and quittable.
    func presentEditorCoreStopped(onRestart: @escaping @MainActor () -> Void) {
        guard !isShowingAlert else { return }
        isShowingAlert = true

        Task { @MainActor in
            defer { self.isShowingAlert = false }

            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Editor Core Stopped"
            alert.informativeText = "The Minga editor core exited and could not be restarted automatically. Restart it to continue editing, or quit Minga."
            alert.addButton(withTitle: "Restart Editor")
            alert.addButton(withTitle: "Quit Minga")

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                onRestart()
            default:
                NSApp.terminate(nil)
            }
        }
    }

    /// Presents one actionable recovery choice for a terminal outbound transport.
    /// The failure stays latched until AppDelegate installs a replacement connection.
    func presentTransportFailure(
        message: String,
        restartAction: (@MainActor () -> Void)?
    ) {
        guard !isShowingTransportFailure else { return }
        transportFailureMessage = message
        isShowingAlert = true
        isShowingTransportFailure = true

        dismissTransportFailurePresentation = transportFailurePresenter(
            message,
            restartAction != nil
        ) { [weak self] decision in
            guard let self, self.transportFailureMessage != nil else { return }
            self.dismissTransportFailurePresentation = nil
            self.isShowingAlert = false
            self.isShowingTransportFailure = false
            switch decision {
            case .restart:
                if let restartAction {
                    restartAction()
                } else {
                    self.quitAction()
                }
            case .quit:
                self.quitAction()
            }
        }
    }

    /// Clears only recoverable transport state after a replacement connection is installed.
    func transportDidReconnect() {
        dismissTransportFailurePresentation?()
        dismissTransportFailurePresentation = nil
        transportFailureMessage = nil
        if isShowingTransportFailure {
            isShowingTransportFailure = false
            isShowingAlert = false
        }
    }

    /// Test helper for deterministic timeout checks.
    func setLastFramePresentedTimeForTesting(_ time: CFAbsoluteTime) {
        lastFramePresentedTime = time
    }

    private func showRecoveryAlert() {
        isShowingAlert = true
        defer { isShowingAlert = false }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Editor Unresponsive"
        alert.informativeText = "Minga has sent input to the editor core, but no render response has arrived. You can restart the editor core while preserving buffers, quit Minga, or wait for it to recover."
        alert.addButton(withTitle: "Restart Editor")
        alert.addButton(withTitle: "Quit Minga")
        alert.addButton(withTitle: "Wait")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            restartAction()
        case .alertSecondButtonReturn:
            NSApp.terminate(nil)
        default:
            break
        }
    }

    private static func sendRestartSignalToParent() {
        let parentPid = getppid()
        guard parentPid > 1 else { return }
        kill(parentPid, SIGUSR2)
    }

    private static func presentTransportFailureAlert(
        message: String,
        canRestart: Bool,
        completion: @escaping @MainActor (TransportFailureDecision) -> Void
    ) -> @MainActor () -> Void {
        let presentation = TransportFailureAlertPresentation()
        Task { @MainActor in
            guard presentation.beginPresentation() else { return }
            let alert = presentation.alert
            alert.alertStyle = .critical
            alert.messageText = "Editor Connection Failed"
            alert.informativeText = transportFailureInformativeText(
                message: message,
                canRestart: canRestart
            )
            if canRestart {
                alert.addButton(withTitle: "Restart Editor")
                alert.addButton(withTitle: "Quit Minga")
                let decision: TransportFailureDecision = alert.runModal() == .alertFirstButtonReturn ? .restart : .quit
                if presentation.finish() { completion(decision) }
            } else {
                alert.addButton(withTitle: "Quit Minga")
                _ = alert.runModal()
                if presentation.finish() { completion(.quit) }
            }
        }
        return { presentation.dismiss() }
    }

    nonisolated static func transportFailureInformativeText(
        message: String,
        canRestart: Bool
    ) -> String {
        let unsavedWarning = "Unsaved changes may be lost. Only the latest autosave or swap can recover them."
        guard !canRestart else { return message + " " + unsavedWarning }
        return message + " " + unsavedWarning + " Quit Minga, then relaunch it from your terminal."
    }
}
