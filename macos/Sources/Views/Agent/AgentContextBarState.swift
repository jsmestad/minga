import Observation
import Foundation
import MingaProtocol

/// State for the agent context bar shown when zoomed into an agent card.
///
/// Displays the agent's task, status, elapsed time, and review actions
/// (Approve, Reject Changes, Dismiss). Replaces the breadcrumb bar
/// when the active agent surface exposes a non-user agent context.
///
/// Updated by the BEAM via the `gui_agent_context` opcode (0x88).
@MainActor
@Observable
public final class AgentContextBarState {
    public init(visible: Bool = false, task: String = "", dispatchTimestamp: Date = Date(), status: CardStatus = .idle, canApprove: Bool = false, progress: Wire.AgentProgress = .init(activeAction: "", toolCount: 0, fileCount: 0, reviewHint: ""), todos: [Wire.AgentTodo] = []) {
        self.visible = visible
        self.task = task
        self.dispatchTimestamp = dispatchTimestamp
        self.status = status
        self.canApprove = canApprove
        self.progress = progress
        self.todos = todos
    }
    /// Whether the context bar is visible (zoomed into an agent card, not You card).
    public var visible: Bool = false

    /// The agent's task description.
    public var task: String = ""

    /// Unix timestamp when the task was dispatched.
    public var dispatchTimestamp: Date = Date()

    /// The agent's current status.
    public var status: CardStatus = .idle

    /// Whether the user can approve the agent's work (work is complete and awaiting approval).
    public var canApprove: Bool = false

    /// Current turn activity summary.
    public var progress: Wire.AgentProgress = .init(activeAction: "", toolCount: 0, fileCount: 0, reviewHint: "")

    /// Latest agent todo plan projection.
    public var todos: [Wire.AgentTodo] = []

    /// Elapsed time since dispatch, computed from dispatchTimestamp.
    public var elapsedSeconds: Int {
        Int(Date().timeIntervalSince(dispatchTimestamp))
    }

    /// Updates the context bar state from a decoded protocol command.
    public func update(visible: Bool, task: String, dispatchTimestamp: Date, status: CardStatus, canApprove: Bool, progress: Wire.AgentProgress, todos: [Wire.AgentTodo]) {
        self.visible = visible
        self.task = task
        self.dispatchTimestamp = dispatchTimestamp
        self.status = status
        self.canApprove = canApprove
        self.progress = progress
        self.todos = todos
    }

    /// Hides the context bar. Called when zooming out or switching to the You card.
    public func hide() {
        visible = false
        task = ""
        dispatchTimestamp = Date()
        status = .idle
        canApprove = false
        progress = .init(activeAction: "", toolCount: 0, fileCount: 0, reviewHint: "")
        todos = []
    }
}
