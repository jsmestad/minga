/// A consumer-owned action sink used by SwiftUI views.
public typealias ViewActionHandler<Action: Sendable> = @MainActor @Sendable (Action) -> Void
