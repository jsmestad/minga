import Foundation
import Testing

@testable import Minga

@Suite("FeedbackState")
struct FeedbackStateTests {

    // MARK: - isInflight detection

    @Test("detects inflight from ellipsis suffix")
    func inflightEllipsis() {
        #expect(FeedbackState.isInflight("Formatting…"))
        #expect(FeedbackState.isInflight("Finding references…"))
        #expect(FeedbackState.isInflight("Renaming…"))
    }

    @Test("detects inflight with cancel hint")
    func inflightCancelHint() {
        #expect(FeedbackState.isInflight("Formatting… [Esc to cancel]"))
    }

    @Test("non-inflight messages")
    func notInflight() {
        #expect(!FeedbackState.isInflight("Formatted"))
        #expect(!FeedbackState.isInflight("Format error: LSP request failed"))
        #expect(!FeedbackState.isInflight(""))
    }

    // MARK: - Pending state

    @Test("isPending set synchronously on inflight message")
    @MainActor func pendingSetSync() {
        let state = FeedbackState()
        state.update(message: "Formatting…")
        #expect(state.isPending)
        #expect(!state.showingSpinner)
    }

    @Test("isPending cleared on non-inflight message")
    @MainActor func pendingCleared() {
        let state = FeedbackState()
        state.update(message: "Formatting…")
        #expect(state.isPending)
        state.update(message: "Formatted")
        #expect(!state.isPending)
    }

    @Test("duplicate message does not reset state")
    @MainActor func duplicateIgnored() {
        let state = FeedbackState()
        state.update(message: "Formatting…")
        let wasPending = state.isPending
        state.update(message: "Formatting…")
        #expect(state.isPending == wasPending)
    }

    // MARK: - Cancel

    @Test("cancel clears all state immediately")
    @MainActor func cancelClears() {
        let state = FeedbackState()
        state.update(message: "Formatting…")
        #expect(state.isPending)
        state.cancel()
        #expect(!state.isPending)
        #expect(!state.showingSpinner)
    }

    // MARK: - Threshold constants

    @Test("spinner delay matches D4a contract")
    func spinnerDelay() {
        #expect(FeedbackState.spinnerDelay == .milliseconds(100))
    }

    @Test("spinner hold matches D4a contract")
    func spinnerHold() {
        #expect(FeedbackState.spinnerHold == .milliseconds(500))
    }

    @Test("success dwell matches D4a contract")
    func successDwell() {
        #expect(FeedbackState.successDwell == .milliseconds(1_500))
    }

    // MARK: - Async spinner behavior

    @MainActor
    private func waitForSpinner(_ state: FeedbackState, timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !state.showingSpinner && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    private func waitForSpinnerDismiss(_ state: FeedbackState, timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now + timeout
        while state.showingSpinner && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("spinner appears after delay threshold")
    @MainActor func spinnerAppearsAfterDelay() async throws {
        let state = FeedbackState()
        state.update(message: "Formatting…")
        #expect(!state.showingSpinner)
        try await waitForSpinner(state)
        #expect(state.showingSpinner)
    }

    @Test("spinner holds after fast completion then clears")
    @MainActor func spinnerHoldsAfterCompletion() async throws {
        let state = FeedbackState()
        state.update(message: "Formatting…")
        try await waitForSpinner(state)
        #expect(state.showingSpinner)
        state.update(message: "Formatted")
        #expect(state.showingSpinner)
        try await waitForSpinnerDismiss(state)
        #expect(!state.showingSpinner)
    }

    @Test("fast completion prevents spinner from appearing")
    @MainActor func fastCompletionPreventsSpinner() async throws {
        let state = FeedbackState()
        state.update(message: "Formatting…")
        try await Task.sleep(for: .milliseconds(50))
        state.update(message: "Formatted")
        #expect(!state.showingSpinner)
    }

    @Test("cancel during spinner hold clears immediately")
    @MainActor func cancelDuringSpinnerHold() async throws {
        let state = FeedbackState()
        state.update(message: "Formatting…")
        try await waitForSpinner(state)
        #expect(state.showingSpinner)
        state.cancel()
        #expect(!state.showingSpinner)
    }
}
