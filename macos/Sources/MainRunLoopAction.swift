import AppKit

/// Delivers native callbacks on the main actor during normal events and AppKit modal termination.
@MainActor
final class MainRunLoopAction: NSObject {
    private let action: @MainActor @Sendable () -> Void

    /// Captures one callback without requiring the producer to enter the main actor.
    nonisolated init(_ action: @escaping @MainActor @Sendable () -> Void) {
        self.action = action
        super.init()
    }

    /// Queues the callback in the native run loop, including the mode used by terminateLater.
    nonisolated func enqueue() {
        performSelector(onMainThread: #selector(invoke), with: nil, waitUntilDone: false, modes: [RunLoop.Mode.default.rawValue, RunLoop.Mode.modalPanel.rawValue, RunLoop.Mode.eventTracking.rawValue])
    }

    @objc private func invoke() {
        action()
    }
}
