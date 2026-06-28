import Testing
@testable import Minga

@MainActor
@Suite("CompletionState local preview")
struct CompletionStateTests {
    private func makeItems(_ count: Int) -> [Wire.CompletionItem] {
        (0..<count).map { i in Wire.CompletionItem(kind: 1, label: "item\(i)", detail: "") }
    }

    @Test("previewNavigation increments without mutating selectedIndex")
    func previewNavigationDown() {
        let state = CompletionState()
        state.update(visible: true, anchorRow: 0, anchorCol: 0, selectedIndex: 0, rawItems: makeItems(5), documentation: "")

        let handled = state.previewNavigation(delta: 1)

        #expect(handled == true)
        #expect(state.effectiveSelectedIndex == 1)
        #expect(state.selectedIndex == 0)
    }

    @Test("previewNavigation decrements from committed index")
    func previewNavigationUp() {
        let state = CompletionState()
        state.update(visible: true, anchorRow: 0, anchorCol: 0, selectedIndex: 3, rawItems: makeItems(5), documentation: "")

        let handled = state.previewNavigation(delta: -1)

        #expect(handled == true)
        #expect(state.effectiveSelectedIndex == 2)
        #expect(state.selectedIndex == 3)
    }

    @Test("previewNavigation clamps at list boundaries")
    func previewNavigationClamps() {
        let state = CompletionState()
        state.update(visible: true, anchorRow: 0, anchorCol: 0, selectedIndex: 0, rawItems: makeItems(3), documentation: "")

        let handledUp = state.previewNavigation(delta: -1)
        #expect(handledUp == false)
        #expect(state.previewSelectedIndex == nil)

        state.update(visible: true, anchorRow: 0, anchorCol: 0, selectedIndex: 2, rawItems: makeItems(3), documentation: "")

        let handledDown = state.previewNavigation(delta: 1)
        #expect(handledDown == false)
        #expect(state.previewSelectedIndex == nil)
    }

    @Test("update clears preview index")
    func updateClearsPreview() {
        let state = CompletionState()
        state.update(visible: true, anchorRow: 0, anchorCol: 0, selectedIndex: 0, rawItems: makeItems(5), documentation: "")

        _ = state.previewNavigation(delta: 1)
        #expect(state.previewSelectedIndex != nil)

        state.update(visible: true, anchorRow: 0, anchorCol: 0, selectedIndex: 1, rawItems: makeItems(5), documentation: "")
        #expect(state.previewSelectedIndex == nil)
    }

    @Test("hide clears preview index")
    func hideClearsPreview() {
        let state = CompletionState()
        state.update(visible: true, anchorRow: 0, anchorCol: 0, selectedIndex: 0, rawItems: makeItems(5), documentation: "")
        _ = state.previewNavigation(delta: 1)

        state.hide()
        #expect(state.previewSelectedIndex == nil)
    }

    @Test("effectiveSelectedIndex falls back to committed when no preview")
    func effectiveIndexFallback() {
        let state = CompletionState()
        state.update(visible: true, anchorRow: 0, anchorCol: 0, selectedIndex: 2, rawItems: makeItems(5), documentation: "")

        #expect(state.effectiveSelectedIndex == 2)
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

        #expect(state.effectiveSelectedIndex == 3)
        #expect(state.selectedIndex == 0)
    }
}
