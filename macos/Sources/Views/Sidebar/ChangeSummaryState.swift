import Observation
import MingaProtocol

/// State for the change summary sidebar shown when zoomed into an agent card.
///
/// Updated by the BEAM via semantic change-summary commands with per-file diff
/// stats. Drives `ChangeSummaryView` which renders a list of changed files
/// with their status and line counts.
@MainActor
@Observable
public final class ChangeSummaryState {
    public init(visible: Bool = false, entries: [ChangeSummaryEntry] = [], selectedIndex: Int = 0) {
        self.visible = visible
        self.entries = entries
        self.selectedIndex = selectedIndex
    }
    /// Whether the change summary sidebar is visible.
    public var visible: Bool = false

    /// The list of changed files with their diff stats.
    public var entries: [ChangeSummaryEntry] = []

    /// Index of the currently selected file (0-based).
    public var selectedIndex: Int = 0

    /// Updates the change summary state from decoded protocol data.
    public func update(visible: Bool, entries: [ChangeSummaryEntry], selectedIndex: Int) {
        self.visible = visible
        self.entries = entries
        self.selectedIndex = selectedIndex
    }

    /// Hides the change summary sidebar.
    public func hide() {
        self.visible = false
        self.entries = []
        self.selectedIndex = 0
    }
}
