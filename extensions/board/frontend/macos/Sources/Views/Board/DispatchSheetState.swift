import Observation

/// State for the agent dispatch sheet modal.
///
/// Drives the UI for creating new agent sessions on The Board.
/// The BEAM sends model availability data; the Swift side only
/// captures user input and sends it back as a gui_action.
@MainActor
@Observable
final class DispatchSheetState {
    /// Whether the dispatch sheet is visible.
    var visible: Bool = false

    /// The task description text entered by the user.
    var taskText: String = ""

    /// Selected model index in the models array.
    var selectedModelIndex: Int = 0

    /// Available models with their capability hints.
    /// Updated from the BEAM when the sheet is shown.
    var models: [(name: String, hint: String)] = []

    /// Updates the state when the BEAM shows or refreshes the sheet.
    func update(visible: Bool, models: [(name: String, hint: String)]) {
        self.visible = visible
        self.models = models
        // Reset selection to first model if we have models, preserve user's text
        if !models.isEmpty && selectedModelIndex >= models.count {
            selectedModelIndex = 0
        }
    }

    /// Resets the sheet to initial state when dismissed.
    func reset() {
        taskText = ""
        selectedModelIndex = 0
        visible = false
    }
}
