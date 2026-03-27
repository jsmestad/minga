import Observation

/// State for the change summary sidebar shown when zoomed into an agent card.
///
/// Updated by the BEAM via the `gui_board` opcode (0x87) with per-file diff
/// stats. Drives `ChangeSummaryView` which renders a list of changed files
/// with their status and line counts.
@MainActor
@Observable
final class ChangeSummaryState {
    /// Whether the change summary sidebar is visible.
    var visible: Bool = false

    /// The list of changed files with their diff stats.
    var entries: [ChangeSummaryEntry] = []

    /// Index of the currently selected file (0-based).
    var selectedIndex: Int = 0

    /// Updates the change summary state from decoded protocol data.
    func update(visible: Bool, entries: [ChangeSummaryEntry], selectedIndex: Int) {
        self.visible = visible
        self.entries = entries
        self.selectedIndex = selectedIndex
    }

    /// Hides the change summary sidebar.
    func hide() {
        self.visible = false
        self.entries = []
        self.selectedIndex = 0
    }
}
