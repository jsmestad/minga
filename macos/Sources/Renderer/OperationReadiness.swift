import Foundation
import MingaProtocol
import MingaUI

/// Bounded, connection-local correlation between BEAM operations and exact editor presentations.
@MainActor
final class OperationReadinessTracker {
    private struct Pending {
        let operation: PresentationOperation
        var candidate: NativePresentationEvidence?
    }

    private struct Visible {
        let applicationRevision: UInt32
        let evidence: NativePresentationEvidence
    }

    private let maximumPending = 64
    private let maximumCompleted = 128
    private let pendingLifetimeNanoseconds: UInt64
    private var pending: [UInt64: Pending] = [:]
    private var expirationTasks: [UInt64: Task<Void, Never>] = [:]
    private var completedOrder: [UInt64] = []
    private var completed: Set<UInt64> = []
    private var visible: Visible?

    var onResult: ((NativeOperationResult) -> Void)?

    init(pendingLifetimeNanoseconds: UInt64 = 30_000_000_000) {
        self.pendingLifetimeNanoseconds = pendingLifetimeNanoseconds
    }

    func replaceConnection() {
        for task in expirationTasks.values { task.cancel() }
        expirationTasks.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
        completedOrder.removeAll(keepingCapacity: true)
        completed.removeAll(keepingCapacity: true)
        visible = nil
    }

    func register(_ operation: PresentationOperation, currentFocusReady: Bool = false) {
        guard !completed.contains(operation.operationID), pending[operation.operationID] == nil else { return }
        if let visible, visible.applicationRevision >= operation.applicationRevision {
            if satisfies(operation, evidence: visible.evidence) {
                if !operation.focusRequired || currentFocusReady {
                    complete(operation, outcome: .ready, evidence: visible.evidence)
                    return
                }
            } else {
                complete(operation, outcome: .superseded, evidence: emptyEvidence(for: operation))
                return
            }
        }
        guard pending.count < maximumPending else {
            complete(
                operation,
                outcome: .unavailable,
                evidence: emptyEvidence(for: operation)
            )
            return
        }
        pending[operation.operationID] = Pending(operation: operation, candidate: nil)
        scheduleExpiration(for: operation.operationID)
    }

    func observeCommitted(_ snapshot: CommittedEditorSnapshot) {
        guard let target = snapshot.metadata.presentationTarget else { return }
        observeCommitted(target: target, generation: snapshot.generation, frameSeq: snapshot.frameSeq)
    }

    func observeCommitted(target: PresentationTarget, generation: UInt32, frameSeq: UInt32) {
        let frame = NativePresentationEvidence(
            targetToken: target.token,
            applicationRevision: target.applicationRevision,
            generation: generation,
            frameSeq: frameSeq,
            windowID: target.windowID,
            focusReady: false,
            boundary: .none
        )
        var superseded: [PresentationOperation] = []
        for (operationID, var entry) in pending {
            guard target.applicationRevision >= entry.operation.applicationRevision else { continue }
            if target.token == entry.operation.targetToken, target.windowID == entry.operation.windowID {
                entry.candidate = frame
                pending[operationID] = entry
            } else {
                superseded.append(entry.operation)
            }
        }
        for operation in superseded {
            complete(operation, outcome: .superseded, evidence: emptyEvidence(for: operation))
        }
    }

    func observePresented(_ snapshot: CommittedEditorSnapshot, focusReady: Bool) {
        guard let target = snapshot.metadata.presentationTarget else { return }
        observePresented(
            target: target,
            generation: snapshot.generation,
            frameSeq: snapshot.frameSeq,
            focusReady: focusReady
        )
    }

    func observePresented(
        target: PresentationTarget,
        generation: UInt32,
        frameSeq: UInt32,
        focusReady: Bool
    ) {
        let evidence = NativePresentationEvidence(
            targetToken: target.token,
            applicationRevision: target.applicationRevision,
            generation: generation,
            frameSeq: frameSeq,
            windowID: target.windowID,
            focusReady: focusReady,
            boundary: .metalDrawableCompleted
        )
        let matching = pending.values.compactMap { entry -> PresentationOperation? in
            guard let candidate = entry.candidate,
                  candidate.generation == evidence.generation,
                  candidate.frameSeq == evidence.frameSeq,
                  entry.operation.targetToken == evidence.targetToken,
                  entry.operation.windowID == evidence.windowID
            else { return nil }
            return entry.operation
        }
        for operation in matching {
            let ready = !operation.focusRequired || focusReady
            complete(operation, outcome: ready ? .ready : .unavailable, evidence: evidence)
        }

        if !target.focusRequired || focusReady {
            visible = Visible(applicationRevision: target.applicationRevision, evidence: evidence)
        }
    }

    func discard(frame: GUICommittedFrame?, outcome: NativeOperationResult.Outcome) {
        guard let frame else { return }
        let matching = pending.values.compactMap { entry -> (PresentationOperation, NativePresentationEvidence)? in
            guard let candidate = entry.candidate,
                  candidate.generation == frame.generation,
                  candidate.frameSeq == frame.frameSeq
            else { return nil }
            return (entry.operation, candidate)
        }
        for (operation, evidence) in matching {
            complete(operation, outcome: outcome, evidence: evidence)
        }
    }

    func reject(target: PresentationTarget?) {
        guard let target else { return }
        let matching = pending.values.compactMap { entry -> PresentationOperation? in
            guard target.applicationRevision >= entry.operation.applicationRevision,
                  target.token == entry.operation.targetToken,
                  target.windowID == entry.operation.windowID
            else { return nil }
            return entry.operation
        }
        for operation in matching {
            complete(operation, outcome: .presentationFailed, evidence: emptyEvidence(for: operation))
        }
    }

    private func satisfies(_ operation: PresentationOperation, evidence: NativePresentationEvidence) -> Bool {
        operation.targetToken == evidence.targetToken &&
            operation.windowID == evidence.windowID &&
            (!operation.focusRequired || evidence.focusReady)
    }

    private func emptyEvidence(for operation: PresentationOperation) -> NativePresentationEvidence {
        NativePresentationEvidence(
            targetToken: operation.targetToken,
            applicationRevision: operation.applicationRevision,
            generation: 0,
            frameSeq: 0,
            windowID: operation.windowID,
            focusReady: false,
            boundary: .none
        )
    }

    private func complete(
        _ operation: PresentationOperation,
        outcome: NativeOperationResult.Outcome,
        evidence: NativePresentationEvidence
    ) {
        pending.removeValue(forKey: operation.operationID)
        expirationTasks.removeValue(forKey: operation.operationID)?.cancel()
        rememberCompleted(operation.operationID)
        onResult?(NativeOperationResult(
            operationID: operation.operationID,
            targetToken: operation.targetToken,
            outcome: outcome,
            evidence: evidence,
            lastVisible: visible?.evidence
        ))
    }

    private func scheduleExpiration(for operationID: UInt64) {
        let lifetime = pendingLifetimeNanoseconds
        expirationTasks[operationID] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: lifetime)
            guard !Task.isCancelled else { return }
            self?.expire(operationID)
        }
    }

    private func expire(_ operationID: UInt64) {
        guard pending.removeValue(forKey: operationID) != nil else { return }
        expirationTasks.removeValue(forKey: operationID)
        rememberCompleted(operationID)
    }

    private func rememberCompleted(_ operationID: UInt64) {
        completed.insert(operationID)
        completedOrder.append(operationID)
        while completedOrder.count > maximumCompleted {
            completed.remove(completedOrder.removeFirst())
        }
    }
}
