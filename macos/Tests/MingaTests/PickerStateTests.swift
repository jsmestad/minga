import Testing
@testable import MingaUI
import MingaProtocol
@testable import Minga

@MainActor
@Suite("PickerState local preview")
struct PickerStateTests {
    private func makeItems(_ count: Int) -> [Wire.PickerItem] {
        (0..<count).map { i in
            Wire.PickerItem(iconColor: 0, flags: 0, label: "item\(i)", description: "", annotation: "", matchPositions: [], activationID: UInt32(i + 1))
        }
    }

    private func populateState(_ state: PickerState, selected: UInt16 = 0, count: Int = 5) {
        state.update(visible: true, selectedIndex: selected, filteredCount: UInt16(count), totalCount: UInt16(count), markedCount: 0, title: "Test", query: "", hasPreview: false, rawItems: makeItems(count), actionMenu: nil, activationGeneration: 7)
    }

    @Test("previewNavigation increments without mutating selectedIndex")
    func previewNavigationDown() {
        let state = PickerState()
        populateState(state, selected: 0)

        let handled = state.previewNavigation(delta: 1)

        #expect(handled == true)
        #expect(state.effectiveSelectedIndex == 1)
        #expect(state.selectedIndex == 0)
    }

    @Test("previewNavigation decrements from committed index")
    func previewNavigationUp() {
        let state = PickerState()
        populateState(state, selected: 3)

        let handled = state.previewNavigation(delta: -1)

        #expect(handled == true)
        #expect(state.effectiveSelectedIndex == 2)
        #expect(state.selectedIndex == 3)
    }

    @Test("previewNavigation clamps at list boundaries")
    func previewNavigationClamps() {
        let state = PickerState()
        populateState(state, selected: 0, count: 3)

        let handledUp = state.previewNavigation(delta: -1)
        #expect(handledUp == false)
        #expect(state.previewSelectedIndex == nil)

        populateState(state, selected: 2, count: 3)

        let handledDown = state.previewNavigation(delta: 1)
        #expect(handledDown == false)
        #expect(state.previewSelectedIndex == nil)
    }

    @Test("update clears preview index")
    func updateClearsPreview() {
        let state = PickerState()
        populateState(state, selected: 0)

        _ = state.previewNavigation(delta: 1)
        #expect(state.previewSelectedIndex != nil)

        state.updateSelection(generation: 7, selectedItemID: 2, selectedActionID: 0)
        #expect(state.previewSelectedIndex == nil)
    }

    @Test("hide clears preview index")
    func hideClearsPreview() {
        let state = PickerState()
        populateState(state, selected: 0)
        _ = state.previewNavigation(delta: 1)

        state.hide()
        #expect(state.previewSelectedIndex == nil)
    }

    @Test("effectiveSelectedIndex falls back to committed when no preview")
    func effectiveIndexFallback() {
        let state = PickerState()
        populateState(state, selected: 2)

        #expect(state.effectiveSelectedIndex == 2)
    }

    @Test("previewNavigation ignored when picker is hidden")
    func previewNavigationIgnoredWhenHidden() {
        let state = PickerState()
        populateState(state, selected: 0)
        state.hide()

        let handled = state.previewNavigation(delta: 1)
        #expect(handled == false)
    }

    @Test("consecutive preview moves chain correctly")
    func consecutivePreviewMoves() {
        let state = PickerState()
        populateState(state, selected: 0)

        _ = state.previewNavigation(delta: 1)
        _ = state.previewNavigation(delta: 1)
        _ = state.previewNavigation(delta: 1)

        #expect(state.effectiveSelectedIndex == 3)
        #expect(state.selectedIndex == 0)
    }

    @Test("same-generation refilter retains preview by activation ID")
    func itemsChangeRetainsPreview() {
        let state = PickerState()
        populateState(state, selected: 0)
        _ = state.previewNavigation(delta: 2)
        #expect(state.previewSelectedIndex != nil)

        populateState(state, selected: 0, count: 3)
        #expect(state.previewSelectedIndex == 2)
    }

    @Test("generation change and retained-item miss discard preview")
    func stalePreviewDiscard() {
        let state = PickerState()
        populateState(state, selected: 0)
        _ = state.previewNavigation(delta: 2)

        let items = makeItems(5)
        state.update(visible: true, selectedIndex: 0, filteredCount: 5, totalCount: 5, markedCount: 0, title: "Test", query: "", hasPreview: false, rawItems: items, actionMenu: nil, activationGeneration: 8)
        #expect(state.previewSelectedIndex == nil)

        _ = state.previewNavigation(delta: 2)
        state.update(visible: true, selectedIndex: 0, filteredCount: 2, totalCount: 5, markedCount: 0, title: "Test", query: "", hasPreview: false, rawItems: [items[0], items[1]], actionMenu: nil, activationGeneration: 8)
        #expect(state.previewSelectedIndex == nil)
    }
}
