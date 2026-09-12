/// Tests for macOS freeze recovery state detection.

import Foundation
import Testing

@MainActor
@Suite("RecoveryManager")
struct RecoveryManagerTests {
    @Test("not unresponsive initially")
    func notUnresponsiveInitially() {
        let manager = RecoveryManager()

        #expect(manager.isUnresponsive() == false)
        #expect(manager.keysSinceLastRender == 0)
    }

    @Test("not unresponsive if no keys were sent")
    func notUnresponsiveWithoutPendingKeys() {
        let manager = RecoveryManager()
        manager.setLastFramePresentedTimeForTesting(CFAbsoluteTimeGetCurrent() - 10.0)

        #expect(manager.isUnresponsive() == false)
    }

    @Test("becomes unresponsive after timeout with pending keys")
    func unresponsiveAfterTimeoutWithPendingKeys() {
        let manager = RecoveryManager()
        manager.onKeySent()
        manager.setLastFramePresentedTimeForTesting(CFAbsoluteTimeGetCurrent() - 4.0)

        #expect(manager.isUnresponsive() == true)
    }

    @Test("render receipt resets pending keys and responsiveness")
    func renderReceiptResetsState() {
        let manager = RecoveryManager()
        manager.onKeySent()
        manager.setLastFramePresentedTimeForTesting(CFAbsoluteTimeGetCurrent() - 4.0)
        #expect(manager.isUnresponsive() == true)

        manager.onRenderReceived()

        #expect(manager.isUnresponsive() == false)
        #expect(manager.keysSinceLastRender == 0)
    }

    @Test("transport failure offers explicit restart and clears only after reconnect")
    func transportFailureRestartAndRecovery() throws {
        var presentedMessages: [String] = []
        var canRestartValues: [Bool] = []
        var completion: ((RecoveryManager.TransportFailureDecision) -> Void)?
        var restarts = 0
        var quits = 0
        let manager = RecoveryManager(
            transportFailurePresenter: { message, canRestart, decision in
                presentedMessages.append(message)
                canRestartValues.append(canRestart)
                completion = decision
                return {}
            },
            quitAction: { quits += 1 }
        )
        manager.onKeySent()
        let capacityFailure = OutboundTransportFailure.capacityExhausted(
            limit: 128,
            attemptedFrameBytes: 14
        )

        manager.presentTransportFailure(
            message: capacityFailure.userFacingMessage,
            restartAction: { restarts += 1 }
        )
        manager.presentTransportFailure(
            message: OutboundTransportFailure.writeFailed(errorCode: EPIPE).userFacingMessage,
            restartAction: { restarts += 1 }
        )

        #expect(presentedMessages == [capacityFailure.userFacingMessage])
        #expect(canRestartValues == [true])
        #expect(manager.transportFailureMessage == capacityFailure.userFacingMessage)
        let chooseRestart = try #require(completion)
        chooseRestart(.restart)
        #expect(restarts == 1)
        #expect(quits == 0)
        #expect(manager.transportFailureMessage != nil)

        manager.transportDidReconnect()
        #expect(manager.transportFailureMessage == nil)
        #expect(manager.keysSinceLastRender == 1)
        #expect(manager.isShowingAlert == false)
    }

    @Test("development transport failure offers quit without a fake restart")
    func developmentTransportFailureQuits() throws {
        var canRestartValues: [Bool] = []
        var completion: ((RecoveryManager.TransportFailureDecision) -> Void)?
        var quits = 0
        let manager = RecoveryManager(
            transportFailurePresenter: { _, canRestart, decision in
                canRestartValues.append(canRestart)
                completion = decision
                return {}
            },
            quitAction: { quits += 1 }
        )

        manager.presentTransportFailure(
            message: OutboundTransportFailure.writeFailed(errorCode: EPIPE).userFacingMessage,
            restartAction: nil
        )
        let chooseQuit = try #require(completion)
        chooseQuit(.quit)

        #expect(canRestartValues == [false])
        #expect(quits == 1)
    }

    @Test("automatic reconnect dismisses stale recovery without running its action")
    func reconnectDismissesStaleRecovery() throws {
        var completion: ((RecoveryManager.TransportFailureDecision) -> Void)?
        var dismissals = 0
        var restarts = 0
        let manager = RecoveryManager(
            transportFailurePresenter: { _, _, decision in
                completion = decision
                return { dismissals += 1 }
            }
        )

        manager.presentTransportFailure(
            message: OutboundTransportFailure.peerDisconnected.userFacingMessage,
            restartAction: { restarts += 1 }
        )
        manager.transportDidReconnect()
        let staleCompletion = try #require(completion)
        staleCompletion(.restart)

        #expect(dismissals == 1)
        #expect(restarts == 0)
        #expect(manager.transportFailureMessage == nil)
        #expect(manager.isShowingAlert == false)
    }

    @Test("a dismissed pending transport alert never begins presentation")
    func dismissedPendingTransportAlertDoesNotPresent() {
        let presentation = RecoveryManager.TransportFailureAlertPresentation()

        presentation.dismiss()

        #expect(presentation.beginPresentation() == false)
        #expect(presentation.finish() == false)
    }

    @Test("initialization recovery warns about buffers without claiming accepted input loss")
    func initializationRecoveryCopy() {
        let message = OutboundTransportInitializationError
            .nonBlockingSetupFailed(errorCode: EPERM)
            .userFacingMessage
        let informativeText = RecoveryManager.transportFailureInformativeText(
            message: message,
            canRestart: false
        )

        #expect(informativeText.contains("accepted input") == false)
        #expect(informativeText.contains("Unsaved changes may be lost"))
        #expect(informativeText.contains("relaunch"))
    }
}

@Suite("Outbound connection identity")
struct OutboundConnectionStateTests {
    @Test("delayed old failure is ignored after reconnect and current failure is accepted once")
    func staleFailureAfterReconnect() {
        var state = OutboundConnectionState()
        let oldID = state.issueID()
        state.install(id: oldID)
        let currentID = state.issueID()
        state.install(id: currentID)

        #expect(state.isCurrent(oldID) == false)
        #expect(state.isCurrent(currentID))

        let acceptedOldFailure = state.acceptFailure(for: oldID)
        let acceptedCurrentFailure = state.acceptFailure(for: currentID)
        let acceptedDuplicateFailure = state.acceptFailure(for: currentID)
        #expect(acceptedOldFailure == false)
        #expect(acceptedCurrentFailure)
        #expect(acceptedDuplicateFailure == false)
    }
}
