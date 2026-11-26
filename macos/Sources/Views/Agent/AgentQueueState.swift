import MingaProtocol
import Observation

/// The last accepted queue projection. Nil removes the entire surface.
@Observable
public final class AgentQueueState {
    public private(set) var snapshot: Wire.AgentQueue?

    public init() {}

    public func update(_ snapshot: Wire.AgentQueue?) {
        if self.snapshot != snapshot { self.snapshot = snapshot }
    }
}

/// A control's immutable request, tied to the snapshot that drew it.
nonisolated public struct AgentQueueRequest: Sendable, Equatable {
    let action: Wire.AgentQueue.Action
    let origin: Wire.AgentQueue.Origin
    let row: Wire.AgentQueue.RowIdentity?
    let removed: Wire.AgentQueue.RowIdentity?

    init(
        action: Wire.AgentQueue.Action, origin: Wire.AgentQueue.Origin,
        row: Wire.AgentQueue.RowIdentity? = nil, removed: Wire.AgentQueue.RowIdentity? = nil
    ) {
        self.action = action
        self.origin = origin
        self.row = row
        self.removed = removed
    }
}

extension Wire.AgentQueue {
    /// Selection refers only to the pending list, never to a removed row.
    var selectedRow: Row? {
        guard let selectedID else { return nil }
        return pending.first { $0.id == selectedID }
    }

    func request(for action: Action) -> AgentQueueRequest? {
        switch action {
        case .close, .composer:
            return AgentQueueRequest(action: action, origin: origin)
        case .select, .remove, .edit:
            guard let selectedRow else { return nil }
            return AgentQueueRequest(action: action, origin: origin, row: selectedRow.identity)
        case .pasteAfter, .pasteBefore:
            guard let selectedRow, let source = removed.first else { return nil }
            return AgentQueueRequest(action: action, origin: origin, row: selectedRow.identity, removed: source.identity)
        }
    }

    func select(_ row: Row) -> AgentQueueRequest {
        AgentQueueRequest(action: .select, origin: origin, row: row.identity)
    }

    func request(forEmptyAction action: Wire.EmptyListAction) -> AgentQueueRequest? {
        guard action.id == "queue_return_to_composer" else { return nil }
        return request(for: .composer)
    }
}
