/// Observable completion state driven by BEAM gui_completion messages.

import SwiftUI
import MingaProtocol

public struct CompletionItem: Identifiable {
    public init(id: Int, kind: UInt8, label: String, detail: String) {
        self.id = id
        self.kind = kind
        self.label = label
        self.detail = detail
    }
    public let id: Int
    public let kind: UInt8
    public let label: String
    public let detail: String
}

@MainActor
@Observable
public final class CompletionState {
    public init(visible: Bool = false, anchorRow: Int = 0, anchorCol: Int = 0, selectedIndex: Int = 0, previewSelectedIndex: Int? = nil, items: [CompletionItem] = [], documentation: String = "") {
        self.visible = visible
        self.anchorRow = anchorRow
        self.anchorCol = anchorCol
        self.selectedIndex = selectedIndex
        self.previewSelectedIndex = previewSelectedIndex
        self.items = items
        self.documentation = documentation
    }
    public var visible: Bool = false
    public var anchorRow: Int = 0
    public var anchorCol: Int = 0
    public var selectedIndex: Int = 0
    public var previewSelectedIndex: Int?
    public var items: [CompletionItem] = []
    /// Documentation preview for the selected item (markdown or plaintext from the
    /// LSP completion item). Empty when the selected item has no docs.
    public var documentation: String = ""

    public var effectiveSelectedIndex: Int {
        if let preview = previewSelectedIndex, preview >= 0, preview < items.count {
            return preview
        }
        return selectedIndex
    }

    public func update(visible: Bool, anchorRow: UInt16, anchorCol: UInt16, selectedIndex: UInt16, rawItems: [Wire.CompletionItem], documentation: String) {
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

    public func previewNavigation(delta: Int) -> Bool {
        guard visible, !items.isEmpty else { return false }
        let current = previewSelectedIndex ?? selectedIndex
        let next = min(max(current + delta, 0), items.count - 1)
        guard next != current else { return false }
        previewSelectedIndex = next
        return true
    }

    public func hide() {
        visible = false
        items = []
        previewSelectedIndex = nil
        documentation = ""
    }
}
