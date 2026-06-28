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
}
