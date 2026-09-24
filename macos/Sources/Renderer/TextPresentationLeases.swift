import Foundation
import MingaUI

/// Retains exactly the immutable input snapshots referenced by commit, native attempts, and display.
@MainActor
final class TextPresentationLeases {
    struct Reference: Hashable {
        let windowID: UInt16
        let presentationID: UInt64
    }

    private var counts: [Reference: Int] = [:]
    private var committed: Set<Reference> = []
    private var visible: Set<Reference> = []
    var onState: ((UInt16, UInt64, TextPresentationState) -> Void)?

    private func references(_ snapshot: CommittedEditorSnapshot) -> Set<Reference> {
        Set(snapshot.metadata.textPresentations.map { Reference(windowID: $0.key, presentationID: $0.value) })
    }

    func commit(_ snapshot: CommittedEditorSnapshot) {
        let next = references(snapshot)
        retain(next)
        release(committed)
        committed = next
    }

    func beginAttempt(_ snapshot: CommittedEditorSnapshot) -> Set<Reference> {
        let refs = references(snapshot)
        retain(refs)
        return refs
    }

    func finishAttempt(_ refs: Set<Reference>) { release(refs) }

    func present(_ snapshot: CommittedEditorSnapshot) {
        let next = references(snapshot)
        retain(next)
        for ref in next.subtracting(visible) {
            onState?(ref.windowID, ref.presentationID, .active)
        }
        release(visible)
        visible = next
    }

    func replaceConnection() {
        counts = [:]
        committed = []
        visible = []
    }

    private func retain(_ refs: Set<Reference>) {
        for ref in refs { counts[ref, default: 0] += 1 }
    }

    private func release(_ refs: Set<Reference>) {
        for ref in refs {
            guard let count = counts[ref] else { continue }
            if count == 1 {
                counts.removeValue(forKey: ref)
                onState?(ref.windowID, ref.presentationID, .discarded)
            } else {
                counts[ref] = count - 1
            }
        }
    }
}
