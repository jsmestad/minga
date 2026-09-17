/// Observable completion state driven by BEAM gui_completion messages.

import SwiftUI
import MingaProtocol

public struct CompletionItem: Identifiable {
    public init(id: String, source: String, kind: CompletionKind, label: String, detail: String, matchRanges: [Wire.CompletionMatchRange]) {
        self.id = id
        self.source = source
        self.kind = kind
        self.label = label
        self.detail = detail
        self.matchRanges = matchRanges
    }
    public let id: String
    public let source: String
    public let kind: CompletionKind
    public let label: String
    public let detail: String
    public let matchRanges: [Wire.CompletionMatchRange]
}

/// Complete presentation value for one visible completion popup.
public struct CompletionContent {
    fileprivate init(presentationRevision: UInt64, anchorRow: Int, anchorCol: Int, selectedItemID: String, previewSelectedItemID: String? = nil, items: [CompletionItem], documentation: String, totalCount: UInt32, matchedCount: UInt32, incomplete: Bool) {
        self.presentationRevision = presentationRevision
        self.anchorRow = anchorRow
        self.anchorCol = anchorCol
        self.selectedItemID = selectedItemID
        self.previewSelectedItemID = previewSelectedItemID
        self.items = items
        self.documentation = documentation
        self.totalCount = totalCount
        self.matchedCount = matchedCount
        self.incomplete = incomplete
    }

    public let presentationRevision: UInt64
    public let anchorRow: Int
    public let anchorCol: Int
    public let selectedItemID: String
    public fileprivate(set) var previewSelectedItemID: String?
    public let items: [CompletionItem]
    /// Documentation preview for the selected item.
    public let documentation: String
    public let totalCount: UInt32
    public let matchedCount: UInt32
    public let incomplete: Bool

    public var selectedIndex: Int {
        items.firstIndex(where: { $0.id == selectedItemID }) ?? 0
    }

    public var previewSelectedIndex: Int? {
        previewSelectedItemID.flatMap { preview in items.firstIndex(where: { $0.id == preview }) }
    }

    public var effectiveSelectedIndex: Int {
        items.firstIndex(where: { $0.id == effectiveSelectedItemID }) ?? 0
    }

    public var effectiveSelectedItemID: String {
        if let preview = previewSelectedItemID, items.contains(where: { $0.id == preview }) {
            return preview
        }
        return selectedItemID
    }
}

@MainActor
@Observable
public final class CompletionState {
    public init() {}

    /// The complete visible presentation, or `nil` when hidden.
    public private(set) var content: CompletionContent?
    public private(set) var presentationRevision: UInt64 = 0

    public func update(visible: Bool, anchorRow: UInt16, anchorCol: UInt16, selectedIndex: UInt16, selectedItemID: String = "", rawItems: [Wire.CompletionItem], documentation: String, totalCount: UInt32 = 0, matchedCount: UInt32 = 0, incomplete: Bool = false) {
        guard visible else {
            hide()
            return
        }

        let items = rawItems.enumerated().map { i, item in
            CompletionItem(id: item.id.isEmpty ? "legacy-\(i)" : item.id, source: item.source, kind: item.kind, label: item.label, detail: item.detail, matchRanges: item.matchRanges)
        }
        let resolvedSelectedID = selectedItemID.isEmpty ? items[safe: Int(selectedIndex)]?.id ?? "" : selectedItemID
        let retainedPreviewID = content?.previewSelectedItemID.flatMap { preview in
            preview != resolvedSelectedID && items.contains(where: { $0.id == preview }) ? preview : nil
        }
        presentationRevision += 1
        content = CompletionContent(
            presentationRevision: presentationRevision,
            anchorRow: Int(anchorRow), anchorCol: Int(anchorCol),
            selectedItemID: resolvedSelectedID, previewSelectedItemID: retainedPreviewID,
            items: items, documentation: documentation,
            totalCount: totalCount, matchedCount: matchedCount, incomplete: incomplete
        )
    }

    public func previewNavigation(delta: Int) -> Bool {
        guard var content, !content.items.isEmpty else { return false }
        let current = content.effectiveSelectedIndex
        let next = min(max(current + delta, 0), content.items.count - 1)
        guard next != current else { return false }
        content.previewSelectedItemID = content.items[next].id
        self.content = content
        return true
    }

    public func hide() {
        content = nil
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
