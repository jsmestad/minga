/// Observable completion state driven by BEAM gui_completion messages.

import SwiftUI

struct CompletionItem: Identifiable {
    let id: Int
    let kind: UInt8
    let label: String
    let detail: String
}

@MainActor
@Observable
final class CompletionState {
    var visible: Bool = false
    var anchorRow: Int = 0
    var anchorCol: Int = 0
    var selectedIndex: Int = 0
    var items: [CompletionItem] = []

    func update(visible: Bool, anchorRow: UInt16, anchorCol: UInt16, selectedIndex: UInt16, rawItems: [GUICompletionItem]) {
        self.visible = visible
        self.anchorRow = Int(anchorRow)
        self.anchorCol = Int(anchorCol)
        self.selectedIndex = Int(selectedIndex)
        self.items = rawItems.enumerated().map { i, item in
            CompletionItem(id: i, kind: item.kind, label: item.label, detail: item.detail)
        }
    }

    func hide() {
        visible = false
        items = []
    }
}
