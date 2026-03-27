import Observation
import Foundation

/// State for the agent context bar shown when zoomed into an agent card.
///
/// Displays the agent's task, status, elapsed time, and review actions
/// (Approve, Request Changes, Dismiss). Replaces the breadcrumb bar
/// when the Board shell is zoomed into a non-You agent card.
///
/// Updated by the BEAM via the `gui_agent_context` opcode (0x88).
@MainActor
@Observable
final class AgentContextBarState {
    /// Whether the context bar is visible (zoomed into an agent card, not You card).
    var visible: Bool = false

    /// The agent's task description.
    var task: String = ""

    /// Unix timestamp when the task was dispatched.
    var dispatchTimestamp: Date = Date()

    /// The agent's current status.
    var status: CardStatus = .idle

    /// Whether the user can approve the agent's work (work is complete and awaiting approval).
    var canApprove: Bool = false

    /// Elapsed time since dispatch, computed from dispatchTimestamp.
    var elapsedSeconds: Int {
        Int(Date().timeIntervalSince(dispatchTimestamp))
    }

    /// Updates the context bar state from a decoded protocol command.
    func update(visible: Bool, task: String, dispatchTimestamp: Date, status: CardStatus, canApprove: Bool) {
        self.visible = visible
        self.task = task
        self.dispatchTimestamp = dispatchTimestamp
        self.status = status
        self.canApprove = canApprove
    }

    /// Hides the context bar. Called when zooming out or switching to the You card.
    func hide() {
        visible = false
        task = ""
        dispatchTimestamp = Date()
        status = .idle
        canApprove = false
    }
}
