import Testing
@testable import MingaUI
import MingaProtocol
@testable import Minga

@MainActor
@Suite("CompletionState local preview")
struct CompletionStateTests {
    private func makeItems(_ count: Int) -> [Wire.CompletionItem] {
        (0..<count).map { i in Wire.CompletionItem(kind: 1, label: "item\(i)", detail: "", id: "item-\(i)") }
    }

    @Test("previewNavigation increments without mutating selectedIndex")
    func previewNavigationDown() {
        let state = CompletionState()
        state.update(visible: true, anchorRow: 0, anchorCol: 0, selectedIndex: 0, rawItems: makeItems(5), documentation: "", generation: 7)

        let handled = state.previewNavigation(delta: 1)

        #expect(handled == true)
        #expect(state.content?.effectiveSelectedIndex == 1)
        #expect(state.content?.selectedIndex == 0)
    }

    @Test("previewNavigation decrements from committed index")
    func previewNavigationUp() {
        let state = CompletionState()
        state.update(visible: true, anchorRow: 0, anchorCol: 0, selectedIndex: 3, rawItems: makeItems(5), documentation: "", generation: 7)

        let handled = state.previewNavigation(delta: -1)

        #expect(handled == true)
        #expect(state.content?.effectiveSelectedIndex == 2)
        #expect(state.content?.selectedIndex == 3)
    }

    @Test("previewNavigation clamps at list boundaries")
    func previewNavigationClamps() {
        let state = CompletionState()
        state.update(visible: true, anchorRow: 0, anchorCol: 0, selectedIndex: 0, rawItems: makeItems(3), documentation: "", generation: 7)

        let handledUp = state.previewNavigation(delta: -1)
        #expect(handledUp == false)
        #expect(state.content?.previewSelectedIndex == nil)

        state.update(visible: true, anchorRow: 0, anchorCol: 0, selectedIndex: 2, rawItems: makeItems(3), documentation: "", generation: 7)

        let handledDown = state.previewNavigation(delta: 1)
        #expect(handledDown == false)
        #expect(state.content?.previewSelectedIndex == nil)
    }

    @Test("update clears preview index")
    func updateClearsPreview() {
        let state = CompletionState()
        state.update(visible: true, anchorRow: 0, anchorCol: 0, selectedIndex: 0, rawItems: makeItems(5), documentation: "", generation: 7)

        _ = state.previewNavigation(delta: 1)
        #expect(state.content?.previewSelectedIndex != nil)

        state.updateSelection(generation: 7, selectedItemID: "item-1", documentation: "item 1 docs")
        #expect(state.content?.previewSelectedIndex == nil)
        #expect(state.content?.documentation == "item 1 docs")
    }

    @Test("update retains preview by stable ID when ranking changes")
    func updateRetainsPreviewByStableID() {
        let state = CompletionState()
        let items = makeItems(5)
        state.update(visible: true, anchorRow: 0, anchorCol: 0, selectedIndex: 0, rawItems: items, documentation: "", generation: 7)

        _ = state.previewNavigation(delta: 1)
        let reordered = [items[4], items[1], items[0]]
        state.update(visible: true, anchorRow: 0, anchorCol: 0, selectedIndex: 2, selectedItemID: "item-0", rawItems: reordered, documentation: "", totalCount: 50_000, matchedCount: 3, incomplete: true, generation: 7)

        #expect(state.content?.effectiveSelectedItemID == "item-1")
        #expect(state.content?.effectiveSelectedIndex == 1)
        #expect(state.content?.totalCount == 50_000)
        #expect(state.content?.matchedCount == 3)
        #expect(state.content?.incomplete == true)
    }

    @Test("selection-only documentation frame retains a different local preview")
    func selectionOnlyDocumentationRetainsPreview() {
        let state = CompletionState()
        state.update(visible: true, anchorRow: 0, anchorCol: 0, selectedIndex: 0, rawItems: makeItems(3), documentation: "old", generation: 7)
        _ = state.previewNavigation(delta: 2)

        state.updateSelection(generation: 7, selectedItemID: "item-1", documentation: "new")

        #expect(state.content?.selectedItemID == "item-1")
        #expect(state.content?.effectiveSelectedItemID == "item-2")
        #expect(state.content?.documentation == "new")
    }

    @Test("generation change and retained-item miss discard preview")
    func stalePreviewDiscard() {
        let state = CompletionState()
        let items = makeItems(3)
        state.update(visible: true, anchorRow: 0, anchorCol: 0, selectedIndex: 0, rawItems: items, documentation: "", generation: 7)
        _ = state.previewNavigation(delta: 1)

        state.update(visible: true, anchorRow: 0, anchorCol: 0, selectedIndex: 0, rawItems: items, documentation: "", generation: 8)
        #expect(state.content?.previewSelectedIndex == nil)

        _ = state.previewNavigation(delta: 1)
        state.update(visible: true, anchorRow: 0, anchorCol: 0, selectedIndex: 0, rawItems: [items[0], items[2]], documentation: "", generation: 8)
        #expect(state.content?.previewSelectedIndex == nil)
    }

    @Test("hide clears preview index")
    func hideClearsPreview() {
        let state = CompletionState()
        state.update(visible: true, anchorRow: 0, anchorCol: 0, selectedIndex: 0, rawItems: makeItems(5), documentation: "")
        _ = state.previewNavigation(delta: 1)

        state.hide()
        #expect(state.content == nil)
    }

    @Test("effectiveSelectedIndex falls back to committed when no preview")
    func effectiveIndexFallback() {
        let state = CompletionState()
        state.update(visible: true, anchorRow: 0, anchorCol: 0, selectedIndex: 2, rawItems: makeItems(5), documentation: "")

        #expect(state.content?.effectiveSelectedIndex == 2)
    }

    @Test("previewNavigation ignored when popup is hidden")
    func previewNavigationIgnoredWhenHidden() {
        let state = CompletionState()
        state.update(visible: true, anchorRow: 0, anchorCol: 0, selectedIndex: 0, rawItems: makeItems(5), documentation: "")
        state.hide()

        let handled = state.previewNavigation(delta: 1)
        #expect(handled == false)
    }

    @Test("consecutive preview moves chain correctly")
    func consecutivePreviewMoves() {
        let state = CompletionState()
        state.update(visible: true, anchorRow: 0, anchorCol: 0, selectedIndex: 0, rawItems: makeItems(5), documentation: "")

        _ = state.previewNavigation(delta: 1)
        _ = state.previewNavigation(delta: 1)
        _ = state.previewNavigation(delta: 1)

        #expect(state.content?.effectiveSelectedIndex == 3)
        #expect(state.content?.selectedIndex == 0)
    }

    @Test("replacement and hide discard prior preview and documentation")
    func replacementAndHideDiscardPriorContent() {
        let state = CompletionState()
        state.update(visible: true, anchorRow: 2, anchorCol: 3, selectedIndex: 0, rawItems: [
            Wire.CompletionItem(kind: 1, label: "old", detail: "A"),
            Wire.CompletionItem(kind: 1, label: "stale preview", detail: ""),
        ], documentation: "old docs")
        _ = state.previewNavigation(delta: 1)

        state.update(visible: true, anchorRow: 7, anchorCol: 8, selectedIndex: 0, rawItems: [Wire.CompletionItem(kind: 2, label: "replacement", detail: "B")], documentation: "new docs")

        #expect(state.content?.anchorRow == 7)
        #expect(state.content?.items.map(\.label) == ["replacement"])
        #expect(state.content?.previewSelectedIndex == nil)
        #expect(state.content?.documentation == "new docs")

        state.update(visible: false, anchorRow: 0, anchorCol: 0, selectedIndex: 0, rawItems: [], documentation: "")
        #expect(state.content == nil)

        state.update(visible: true, anchorRow: 1, anchorCol: 1, selectedIndex: 0, rawItems: [Wire.CompletionItem(kind: 3, label: "fresh", detail: "")], documentation: "")
        #expect(state.content?.items.map(\.label) == ["fresh"])
        #expect(state.content?.previewSelectedIndex == nil)
        #expect(state.content?.documentation == "")
    }
}
