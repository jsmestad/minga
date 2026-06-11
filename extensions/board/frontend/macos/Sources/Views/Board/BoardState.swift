import Observation

/// State for The Board card grid view.
///
/// Updated by the BEAM via the generic `gui_extension_runtime` envelope carrying the extension-owned Board payload. Drives
/// `BoardView` which renders cards in a responsive SwiftUI grid.
///
/// Card data types are split between `Protocol/BoardTypes.swift` for `BoardCard` and `Protocol/AgentSurfaceTypes.swift` for `CardStatus`, so the headless test harness can compile them without SwiftUI dependencies.
@MainActor
@Observable
final class BoardState {
    /// Whether the Board grid is visible (vs zoomed into a card).
    var visible: Bool = false

    /// ID of the currently focused card (keyboard selection).
    var focusedCardId: UInt32 = 0

    /// The cards on the board, in display order.
    var cards: [BoardCard] = []

    /// Whether the search filter is active.
    var filterMode: Bool = false

    /// Current search filter text.
    var filterText: String = ""

    /// ID of the card being zoomed. Set when transitioning from Board
    /// to editor (visible true→false) or editor to Board (visible false→true).
    /// Used by matchedGeometryEffect for spatial zoom animation and by the zoom
    /// header. This is now authoritative from the wire (`zoomed_card_id`, #2328)
    /// rather than inferred from the visible transition.
    var zoomedCardId: UInt32? = nil

    /// The card the user is zoomed into, looked up from the current cards. The
    /// BEAM sends all cards every frame, so this resolves even while the grid is
    /// hidden. Drives the zoom header (status icon, task, model, ESC affordance).
    var zoomedCard: BoardCard? {
        guard let id = zoomedCardId, id != 0 else { return nil }
        return cards.first { $0.id == id }
    }

    /// Updates the board state from a decoded protocol command.
    ///
    /// `zoomedCardId` is authoritative from the wire: non-zero while a card is
    /// zoomed (grid hidden), zero in grid view.
    func update(visible: Bool, focusedCardId: UInt32, cards: [BoardCard],
                filterMode: Bool, filterText: String, zoomedCardId: UInt32 = 0) {
        self.zoomedCardId = zoomedCardId == 0 ? nil : zoomedCardId

        self.visible = visible
        self.focusedCardId = focusedCardId
        self.cards = cards
        self.filterMode = filterMode
        self.filterText = filterText
    }
}
