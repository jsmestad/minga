import SwiftUI

@MainActor
@Observable
public final class FeedbackState {
    public init(showTask: Task<Void, Never>? = nil, holdTask: Task<Void, Never>? = nil, spinnerOnTime: ContinuousClock.Instant? = nil) {
        self.showTask = showTask
        self.holdTask = holdTask
        self.spinnerOnTime = spinnerOnTime
    }
    public private(set) var isPending = false
    public private(set) var showingSpinner = false

    @ObservationIgnored private var showTask: Task<Void, Never>?
    @ObservationIgnored private var holdTask: Task<Void, Never>?
    @ObservationIgnored private var spinnerOnTime: ContinuousClock.Instant?
    @ObservationIgnored private var lastMessage = ""

    nonisolated static let spinnerDelay: Duration = .milliseconds(100)
    nonisolated static let spinnerHold: Duration = .milliseconds(500)
    nonisolated static let successDwell: Duration = .milliseconds(1_500)

    public func update(message: String) {
        guard message != lastMessage else { return }
        lastMessage = message
        let pending = Self.isInflight(message)

        if pending {
            guard !isPending else { return }
            isPending = true
            holdTask?.cancel()
            holdTask = nil
            showTask?.cancel()
            showTask = Task {
                try? await Task.sleep(for: Self.spinnerDelay)
                guard !Task.isCancelled, isPending else { return }
                showingSpinner = true
                spinnerOnTime = .now
            }
        } else {
            let wasSpinning = showingSpinner
            isPending = false
            showTask?.cancel()
            showTask = nil

            if wasSpinning {
                let elapsed = spinnerOnTime.map { ContinuousClock.now - $0 } ?? .zero
                let remaining = Self.spinnerHold - elapsed
                if remaining > .zero {
                    holdTask?.cancel()
                    holdTask = Task {
                        try? await Task.sleep(for: remaining)
                        guard !Task.isCancelled else { return }
                        showingSpinner = false
                        spinnerOnTime = nil
                    }
                } else {
                    showingSpinner = false
                    spinnerOnTime = nil
                }
            }
        }
    }

    public func cancel() {
        isPending = false
        showingSpinner = false
        showTask?.cancel()
        holdTask?.cancel()
        showTask = nil
        holdTask = nil
        spinnerOnTime = nil
        lastMessage = ""
    }

    nonisolated static func isInflight(_ message: String) -> Bool {
        message.hasSuffix("…") || message.contains("… [")
    }
}
