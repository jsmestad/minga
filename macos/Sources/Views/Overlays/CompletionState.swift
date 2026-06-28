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
    var previewSelectedIndex: Int?
    var items: [CompletionItem] = []
    /// Documentation preview for the selected item (markdown or plaintext from the
    /// LSP completion item). Empty when the selected item has no docs.
    var documentation: String = ""

    var effectiveSelectedIndex: Int {
        if let preview = previewSelectedIndex, preview >= 0, preview < items.count {
            return preview
        }
        return selectedIndex
    }

    func update(visible: Bool, anchorRow: UInt16, anchorCol: UInt16, selectedIndex: UInt16, rawItems: [Wire.CompletionItem], documentation: String) {
        self.visible = visible
        self.anchorRow = Int(anchorRow)
        self.anchorCol = Int(anchorCol)
        self.selectedIndex = Int(selectedIndex)
        self.previewSelectedIndex = nil
        self.documentation = documentation
        self.items = rawItems.enumerated().map { i, item in
            CompletionItem(id: i, kind: item.kind, label: item.label, detail: item.detail)
        }
    }

    func previewNavigation(delta: Int) -> Bool {
        guard visible, !items.isEmpty else { return false }
        let current = previewSelectedIndex ?? selectedIndex
        let next = min(max(current + delta, 0), items.count - 1)
        guard next != current else { return false }
        previewSelectedIndex = next
        return true
    }

    func hide() {
        visible = false
        items = []
        previewSelectedIndex = nil
        documentation = ""
    }
}
