import Testing

@Suite("Application quit coordinator")
struct ApplicationQuitCoordinatorTests {
    @Test("clean quit waits for matching core exit before approving AppKit")
    @MainActor func cleanQuitWaitsForCoreExit() {
        var requests: [UInt32] = []
        var replies: [Bool] = []
        let coordinator = ApplicationQuitCoordinator(
            sendRequest: { requests.append($0); return true },
            sendDecision: { _, _ in true },
            presentDecision: { _, _ in },
            replyToAppKit: { replies.append($0) },
            presentFailure: { _ in },
            restoreFocus: {}
        )

        #expect(coordinator.begin() == .pending)
        #expect(requests == [1])

        coordinator.receive(response(requestID: 1, outcome: .proceeding))
        #expect(replies.isEmpty)

        #expect(coordinator.coreDidExit() == .approvedTermination)
        #expect(replies == [true])
    }

    @Test("cancel replies false once and permits a fresh attempt")
    @MainActor func cancelAndRetry() throws {
        var requests: [UInt32] = []
        var decisions: [(UInt32, ApplicationQuitDecision)] = []
        var replies: [Bool] = []
        var focusRestores = 0
        var presentedDirtyCounts: [UInt16] = []
        var completion: ((ApplicationQuitDecision) -> Void)?
        let coordinator = ApplicationQuitCoordinator(
            sendRequest: { requests.append($0); return true },
            sendDecision: { decisions.append(($0, $1)); return true },
            presentDecision: { dirtyCount, callback in
                presentedDirtyCounts.append(dirtyCount)
                completion = callback
            },
            replyToAppKit: { replies.append($0) },
            presentFailure: { _ in },
            restoreFocus: { focusRestores += 1 }
        )

        #expect(coordinator.begin() == .pending)
        #expect(coordinator.begin() == .pending)
        #expect(requests == [1])
        coordinator.receive(response(requestID: 1, outcome: .needsDecision, dirtyCount: 2))
        #expect(presentedDirtyCounts == [2])
        let cancel = try #require(completion)
        cancel(.cancel)
        #expect(decisions.map(\.0) == [1])
        #expect(decisions.map { $0.1.rawValue } == [ApplicationQuitDecision.cancel.rawValue])
        coordinator.receive(response(requestID: 1, outcome: .cancelled))
        coordinator.receive(response(requestID: 1, outcome: .cancelled))
        #expect(replies == [false])
        #expect(focusRestores == 1)

        #expect(coordinator.begin() == .pending)
        #expect(requests == [1, 2])
    }

    @Test("stale responses and stale chooser completions cannot resolve another attempt")
    @MainActor func rejectsStaleWork() throws {
        var requests: [UInt32] = []
        var decisions: [UInt32] = []
        var replies: [Bool] = []
        var dismissals = 0
        var firstCompletion: ((ApplicationQuitDecision) -> Void)?
        let coordinator = ApplicationQuitCoordinator(
            sendRequest: { requests.append($0); return true },
            sendDecision: { requestID, _ in decisions.append(requestID); return true },
            presentDecision: { _, callback in firstCompletion = callback },
            dismissDecision: { dismissals += 1 },
            replyToAppKit: { replies.append($0) },
            presentFailure: { _ in },
            restoreFocus: {}
        )

        #expect(coordinator.begin() == .pending)
        coordinator.receive(response(requestID: 1, outcome: .needsDecision, dirtyCount: 1))
        coordinator.replaceConnection()
        #expect(replies == [false])
        #expect(dismissals == 1)

        let staleCompletion = try #require(firstCompletion)
        staleCompletion(.discard)
        coordinator.receive(response(requestID: 1, outcome: .proceeding))
        #expect(decisions.isEmpty)
        #expect(replies == [false])

        #expect(coordinator.begin() == .pending)
        coordinator.receive(response(requestID: 1, outcome: .cancelled))
        #expect(requests == [1, 2])
        #expect(replies == [false])
    }

    @Test("save failure is visible, cancels once, and preserves failure detail")
    @MainActor func saveFailureCancelsVisibly() {
        var replies: [Bool] = []
        var failures: [String] = []
        var focusRestores = 0
        let coordinator = ApplicationQuitCoordinator(
            sendRequest: { _ in true },
            sendDecision: { _, _ in true },
            presentDecision: { _, _ in },
            replyToAppKit: { replies.append($0) },
            presentFailure: { failures.append($0) },
            restoreFocus: { focusRestores += 1 }
        )

        #expect(coordinator.begin() == .pending)
        coordinator.receive(response(
            requestID: 1,
            outcome: .saveFailed,
            dirtyCount: 1,
            bufferName: "notes.txt",
            detail: "file changed outside Minga"
        ))

        #expect(replies == [false])
        #expect(failures == ["Quit was cancelled. notes.txt: file changed outside Minga"])
        #expect(focusRestores == 1)
    }

    @Test("live communication failure cancels instead of approving")
    @MainActor func communicationFailureCancels() {
        var replies: [Bool] = []
        var failures: [String] = []
        let coordinator = ApplicationQuitCoordinator(
            sendRequest: { _ in false },
            sendDecision: { _, _ in true },
            presentDecision: { _, _ in },
            replyToAppKit: { replies.append($0) },
            presentFailure: { failures.append($0) },
            restoreFocus: {}
        )

        #expect(coordinator.begin() == .rejected)

        #expect(replies.isEmpty)
        #expect(failures.count == 1)
        #expect(coordinator.state == .idle)
    }

    @Test("decision communication failure cancels instead of waiting forever")
    @MainActor func decisionCommunicationFailureCancels() throws {
        var replies: [Bool] = []
        var failures: [String] = []
        var completion: ((ApplicationQuitDecision) -> Void)?
        let coordinator = ApplicationQuitCoordinator(
            sendRequest: { _ in true },
            sendDecision: { _, _ in false },
            presentDecision: { _, callback in completion = callback },
            replyToAppKit: { replies.append($0) },
            presentFailure: { failures.append($0) },
            restoreFocus: {}
        )

        #expect(coordinator.begin() == .pending)
        coordinator.receive(response(requestID: 1, outcome: .needsDecision, dirtyCount: 1))
        let chooseSave = try #require(completion)
        chooseSave(.save)

        #expect(replies == [false])
        #expect(failures == ["Minga could not send the quit decision to the editor core. Quit was cancelled."])
        #expect(coordinator.state == .idle)
    }

    @Test("connection replacement while proceeding cancels exactly once")
    @MainActor func proceedingConnectionReplacementCancelsOnce() {
        var replies: [Bool] = []
        let coordinator = ApplicationQuitCoordinator(
            sendRequest: { _ in true },
            sendDecision: { _, _ in true },
            presentDecision: { _, _ in },
            replyToAppKit: { replies.append($0) },
            presentFailure: { _ in },
            restoreFocus: {}
        )

        #expect(coordinator.begin() == .pending)
        coordinator.receive(response(requestID: 1, outcome: .proceeding))
        coordinator.replaceConnection()
        coordinator.replaceConnection()

        #expect(replies == [false])
        #expect(coordinator.state == .idle)
    }

    @Test("core exit while decision sheet is open dismisses and cancels")
    @MainActor func earlyCoreExitDismissesAndCancels() {
        var replies: [Bool] = []
        var dismissals = 0
        var completion: ((ApplicationQuitDecision) -> Void)?
        let coordinator = ApplicationQuitCoordinator(
            sendRequest: { _ in true },
            sendDecision: { _, _ in true },
            presentDecision: { _, callback in completion = callback },
            dismissDecision: { dismissals += 1 },
            replyToAppKit: { replies.append($0) },
            presentFailure: { _ in },
            restoreFocus: {}
        )

        #expect(coordinator.begin() == .pending)
        coordinator.receive(response(requestID: 1, outcome: .needsDecision, dirtyCount: 1))

        #expect(coordinator.coreDidExit() == .cancelledTermination)
        #expect(replies == [false])
        #expect(dismissals == 1)

        completion?(.discard)
        #expect(replies == [false])
    }

    @Test("live bundle transport EOF cancels but matching process exit approves")
    @MainActor func bundleTransportAndProcessExitRemainDistinct() {
        var eofReplies: [Bool] = []
        let eofCoordinator = ApplicationQuitCoordinator(
            sendRequest: { _ in true },
            sendDecision: { _, _ in true },
            presentDecision: { _, _ in },
            replyToAppKit: { eofReplies.append($0) },
            presentFailure: { _ in },
            restoreFocus: {}
        )

        #expect(eofCoordinator.begin() == .pending)
        eofCoordinator.receive(response(requestID: 1, outcome: .proceeding))
        eofCoordinator.transportDidDisconnect()
        #expect(eofReplies == [false])

        var exitReplies: [Bool] = []
        let exitCoordinator = ApplicationQuitCoordinator(
            sendRequest: { _ in true },
            sendDecision: { _, _ in true },
            presentDecision: { _, _ in },
            replyToAppKit: { exitReplies.append($0) },
            presentFailure: { _ in },
            restoreFocus: {}
        )

        #expect(exitCoordinator.begin() == .pending)
        exitCoordinator.receive(response(requestID: 1, outcome: .proceeding))
        #expect(exitCoordinator.coreDidExit() == .approvedTermination)
        #expect(exitReplies == [true])
    }

    @Test("delegate maps immediate send rejection directly to terminateCancel")
    @MainActor func delegateImmediateRejectionOrdering() {
        var events: [String] = []
        let coordinator = ApplicationQuitCoordinator(
            sendRequest: { _ in events.append("send"); return false },
            sendDecision: { _, _ in true },
            presentDecision: { _, _ in },
            replyToAppKit: { _ in events.append("appkit-reply") },
            presentFailure: { _ in events.append("failure") },
            restoreFocus: { events.append("focus") }
        )

        let reply = ApplicationTerminationPolicy.reply(coreIsLive: true, coordinator: coordinator)
        events.append("returned")

        #expect(reply == .terminateCancel)
        #expect(events == ["send", "failure", "focus", "returned"])
    }

    @Test("delegate returns terminateNow for an already exited core")
    @MainActor func delegateAlreadyExitedCore() {
        var requests = 0
        let coordinator = ApplicationQuitCoordinator(
            sendRequest: { _ in requests += 1; return true },
            sendDecision: { _, _ in true },
            presentDecision: { _, _ in },
            replyToAppKit: { _ in },
            presentFailure: { _ in },
            restoreFocus: {}
        )

        let reply = ApplicationTerminationPolicy.reply(coreIsLive: false, coordinator: coordinator)

        #expect(reply == .terminateNow)
        #expect(requests == 0)
    }

    private func response(
        requestID: UInt32,
        outcome: ApplicationQuitResponse.Outcome,
        dirtyCount: UInt16 = 0,
        bufferName: String = "",
        detail: String = ""
    ) -> ApplicationQuitResponse {
        ApplicationQuitResponse(
            requestID: requestID,
            outcome: outcome,
            dirtyCount: dirtyCount,
            bufferName: bufferName,
            detail: detail
        )
    }
}
