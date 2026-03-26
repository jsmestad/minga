import Observation

/// State for The Board card grid view.
///
/// Updated by the BEAM via the `gui_board` opcode (0x87). Drives
/// `BoardView` which renders cards in a responsive SwiftUI grid.
///
/// Card data types (`BoardCard`, `CardStatus`) live in
/// `Protocol/BoardTypes.swift` so the headless test harness can
/// compile them without SwiftUI dependencies.
@MainActor
@Observable
final class BoardState {
    /// Whether the Board grid is visible (vs zoomed into a card).
    var visible: Bool = false

    /// ID of the currently focused card (keyboard selection).
    var focusedCardId: UInt32 = 0

    /// The cards on the board, in display order.
    var cards: [BoardCard] = []

    /// Updates the board state from a decoded protocol command.
    func update(visible: Bool, focusedCardId: UInt32, cards: [BoardCard]) {
        self.visible = visible
        self.focusedCardId = focusedCardId
        self.cards = cards
    }
}
