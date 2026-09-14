import MingaProtocol
import MingaUI
import Testing

@Suite("Operation readiness correlation")
@MainActor
struct OperationReadinessTests {
    @Test("unrelated and stale frames cannot satisfy an operation")
    func unrelatedAndStaleFramesFailClosed() throws {
        let tracker = OperationReadinessTracker()
        var results: [NativeOperationResult] = []
        tracker.onResult = { results.append($0) }
        tracker.register(operation(id: 1, token: 11, window: 2, revision: 8))

        tracker.observeCommitted(target: target(token: 11, window: 2, revision: 7), generation: 1, frameSeq: 1)
        tracker.observePresented(target: target(token: 11, window: 2, revision: 7), generation: 1, frameSeq: 1, focusReady: true)
        tracker.observeCommitted(target: target(token: 99, window: 2, revision: 7), generation: 1, frameSeq: 2)
        #expect(results.isEmpty)

        tracker.observeCommitted(target: target(token: 11, window: 2, revision: 8), generation: 1, frameSeq: 3)
        tracker.observePresented(target: target(token: 11, window: 2, revision: 8), generation: 1, frameSeq: 3, focusReady: true)

        let result = try #require(results.only)
        #expect(result.operationID == 1)
        #expect(result.outcome == .ready)
        #expect(result.evidence.frameSeq == 3)
        #expect(result.evidence.boundary == .metalDrawableCompleted)
    }

    @Test("a verified no-op requires the exact target, window, focus, and current revision")
    func verifiedNoOpReadiness() throws {
        let tracker = OperationReadinessTracker()
        var results: [NativeOperationResult] = []
        tracker.onResult = { results.append($0) }

        tracker.observePresented(target: target(token: 20, window: 4, revision: 10), generation: 2, frameSeq: 5, focusReady: true)
        tracker.register(
            operation(id: 1, token: 20, window: 4, revision: 10),
            currentFocusReady: true
        )
        #expect(results.only?.outcome == .ready)
        #expect(results.only?.evidence.frameSeq == 5)

        results.removeAll()
        tracker.register(operation(id: 2, token: 20, window: 4, revision: 11))
        #expect(results.isEmpty)
        tracker.observeCommitted(target: target(token: 20, window: 4, revision: 11), generation: 2, frameSeq: 6)
        tracker.observePresented(target: target(token: 20, window: 4, revision: 11), generation: 2, frameSeq: 6, focusReady: true)
        #expect(results.only?.operationID == 2)

        results.removeAll()
        tracker.register(operation(id: 3, token: 20, window: 4, revision: 11))
        #expect(results.isEmpty)
        tracker.observeCommitted(target: target(token: 20, window: 4, revision: 11), generation: 2, frameSeq: 7)
        tracker.observePresented(target: target(token: 20, window: 4, revision: 11), generation: 2, frameSeq: 7, focusReady: true)
        #expect(results.only?.operationID == 3)
    }

    @Test("a newer mismatched presentation supersedes the operation")
    func newerMismatchedPresentationSupersedes() throws {
        let tracker = OperationReadinessTracker()
        var results: [NativeOperationResult] = []
        tracker.onResult = { results.append($0) }
        tracker.register(operation(id: 8, token: 80, window: 1, revision: 4))

        tracker.observeCommitted(target: target(token: 81, window: 1, revision: 5), generation: 1, frameSeq: 9)

        let result = try #require(results.only)
        #expect(result.operationID == 8)
        #expect(result.outcome == .superseded)
        #expect(result.evidence.targetToken == 80)
        #expect(result.evidence.boundary == .none)
    }

    @Test("a newer visible target supersedes a stale operation at registration")
    func visibleTargetSupersedesAtRegistration() throws {
        let tracker = OperationReadinessTracker()
        var results: [NativeOperationResult] = []
        tracker.onResult = { results.append($0) }
        tracker.observePresented(
            target: target(token: 81, window: 1, revision: 5),
            generation: 1,
            frameSeq: 9,
            focusReady: true
        )

        tracker.register(operation(id: 8, token: 80, window: 1, revision: 4))

        let result = try #require(results.only)
        #expect(result.outcome == .superseded)
        #expect(result.operationID == 8)
    }

    @Test("focus failure returns unavailable and preserves the last good target")
    func focusFailurePreservesLastGood() throws {
        let tracker = OperationReadinessTracker()
        var results: [NativeOperationResult] = []
        tracker.onResult = { results.append($0) }

        tracker.observePresented(target: target(token: 41, window: 1, revision: 1), generation: 1, frameSeq: 1, focusReady: true)
        tracker.register(operation(id: 2, token: 42, window: 2, revision: 2))
        tracker.observeCommitted(target: target(token: 42, window: 2, revision: 2), generation: 1, frameSeq: 2)
        tracker.observePresented(target: target(token: 42, window: 2, revision: 2), generation: 1, frameSeq: 2, focusReady: false)

        let result = try #require(results.only)
        #expect(result.outcome == .unavailable)
        #expect(result.evidence.targetToken == 42)
        #expect(result.evidence.focusReady == false)
        #expect(result.lastVisible?.targetToken == 41)
        #expect(result.lastVisible?.applicationRevision == 1)
        #expect(result.lastVisible?.frameSeq == 1)
    }

    @Test("presentation rejection and frame discard remain distinct")
    func failureOutcomesRemainDistinct() throws {
        let rejected = OperationReadinessTracker()
        var rejectedResults: [NativeOperationResult] = []
        rejected.onResult = { rejectedResults.append($0) }
        rejected.register(operation(id: 1, token: 5, window: 1, revision: 2))
        rejected.reject(target: target(token: 5, window: 1, revision: 2))
        #expect(rejectedResults.only?.outcome == .presentationFailed)

        let discarded = OperationReadinessTracker()
        var discardedResults: [NativeOperationResult] = []
        discarded.onResult = { discardedResults.append($0) }
        discarded.register(operation(id: 2, token: 6, window: 1, revision: 3))
        discarded.observeCommitted(target: target(token: 6, window: 1, revision: 3), generation: 4, frameSeq: 7)
        discarded.discard(frame: GUICommittedFrame(generation: 4, frameSeq: 7), outcome: .hidden)
        #expect(discardedResults.only?.outcome == .hidden)
    }

    @Test("duplicate callbacks and connection replacement cannot resolve stale operations")
    func lateCallbacksAndReplacementFailClosed() {
        let tracker = OperationReadinessTracker()
        var results: [NativeOperationResult] = []
        tracker.onResult = { results.append($0) }
        let firstOperation = operation(id: 7, token: 77, window: 1, revision: 1)
        let firstTarget = target(token: 77, window: 1, revision: 1)
        tracker.register(firstOperation)
        tracker.observeCommitted(target: firstTarget, generation: 1, frameSeq: 1)
        tracker.observePresented(target: firstTarget, generation: 1, frameSeq: 1, focusReady: true)
        tracker.observePresented(target: firstTarget, generation: 1, frameSeq: 1, focusReady: true)
        #expect(results.count == 1)

        tracker.register(operation(id: 8, token: 88, window: 1, revision: 2))
        tracker.replaceConnection()
        tracker.observeCommitted(target: target(token: 88, window: 1, revision: 2), generation: 2, frameSeq: 2)
        tracker.observePresented(target: target(token: 88, window: 1, revision: 2), generation: 2, frameSeq: 2, focusReady: true)
        #expect(results.count == 1)
    }

    @Test("pending and completed operation memory is bounded")
    func boundedOperationMemory() {
        let tracker = OperationReadinessTracker()
        var results: [NativeOperationResult] = []
        tracker.onResult = { results.append($0) }

        for id in 1...65 {
            tracker.register(operation(id: UInt64(id), token: UInt64(id), window: 1, revision: 1))
        }
        #expect(results.count == 1)
        #expect(results.only?.operationID == 65)
        #expect(results.only?.outcome == .unavailable)

        for id in 1...64 {
            tracker.reject(target: target(token: UInt64(id), window: 1, revision: 1))
        }
        #expect(results.count == 65)

        for id in 66...194 {
            let pendingOperation = operation(id: UInt64(id), token: UInt64(id), window: 1, revision: 1)
            tracker.register(pendingOperation)
            tracker.reject(target: target(token: UInt64(id), window: 1, revision: 1))
        }

        tracker.register(operation(id: 1, token: 201, window: 1, revision: 1))
        tracker.reject(target: target(token: 201, window: 1, revision: 1))
        #expect(results.last?.operationID == 1)
        #expect(results.last?.targetToken == 201)
    }

    @Test("expired native operations release capacity without emitting false results")
    func expirationReleasesCapacity() async throws {
        let tracker = OperationReadinessTracker(pendingLifetimeNanoseconds: 1_000_000)
        var results: [NativeOperationResult] = []
        tracker.onResult = { results.append($0) }
        for id in 1...64 {
            tracker.register(operation(id: UInt64(id), token: UInt64(id), window: 1, revision: 1))
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        tracker.register(operation(id: 65, token: 65, window: 1, revision: 2))
        tracker.observeCommitted(target: target(token: 65, window: 1, revision: 2), generation: 2, frameSeq: 2)
        tracker.observePresented(target: target(token: 65, window: 1, revision: 2), generation: 2, frameSeq: 2, focusReady: true)

        #expect(results.count == 1)
        #expect(results.only?.operationID == 65)
        #expect(results.only?.outcome == .ready)
    }

    private func operation(id: UInt64, token: UInt64, window: UInt16, revision: UInt32) -> PresentationOperation {
        PresentationOperation(operationID: id, targetToken: token, windowID: window, applicationRevision: revision, focusRequired: true)
    }

    private func target(token: UInt64, window: UInt16, revision: UInt32) -> PresentationTarget {
        PresentationTarget(token: token, windowID: window, applicationRevision: revision, focusRequired: true)
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
