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

/// Complete presentation value for one visible completion popup.
public struct CompletionContent {
    fileprivate init(anchorRow: Int, anchorCol: Int, selectedIndex: Int, previewSelectedIndex: Int? = nil, items: [CompletionItem], documentation: String) {
        self.anchorRow = anchorRow
        self.anchorCol = anchorCol
        self.selectedIndex = selectedIndex
        self.previewSelectedIndex = previewSelectedIndex
        self.items = items
        self.documentation = documentation
    }

    public let anchorRow: Int
    public let anchorCol: Int
    public let selectedIndex: Int
    public fileprivate(set) var previewSelectedIndex: Int?
    public let items: [CompletionItem]
    /// Documentation preview for the selected item.
    public let documentation: String

    public var effectiveSelectedIndex: Int {
        if let preview = previewSelectedIndex, preview >= 0, preview < items.count {
            return preview
        }
        return selectedIndex
    }
}

@MainActor
@Observable
public final class CompletionState {
    public init() {}

    /// The complete visible presentation, or `nil` when hidden.
    public private(set) var content: CompletionContent?

    public func update(visible: Bool, anchorRow: UInt16, anchorCol: UInt16, selectedIndex: UInt16, rawItems: [Wire.CompletionItem], documentation: String) {
        guard visible else {
            hide()
            return
        }

        let items = rawItems.enumerated().map { i, item in
            CompletionItem(id: i, kind: item.kind, label: item.label, detail: item.detail)
        }
        content = CompletionContent(
            anchorRow: Int(anchorRow), anchorCol: Int(anchorCol),
            selectedIndex: Int(selectedIndex), items: items,
            documentation: documentation
        )
    }

    public func previewNavigation(delta: Int) -> Bool {
        guard var content, !content.items.isEmpty else { return false }
        let current = content.previewSelectedIndex ?? content.selectedIndex
        let next = min(max(current + delta, 0), content.items.count - 1)
        guard next != current else { return false }
        content.previewSelectedIndex = next
        self.content = content
        return true
    }

    public func hide() {
        content = nil
    }
}
