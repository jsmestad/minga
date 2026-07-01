import Testing
@testable import MingaUI
import MingaProtocol
@testable import Minga

@MainActor
@Suite("PickerState local preview")
struct PickerStateTests {
    private func makeItems(_ count: Int) -> [Wire.PickerItem] {
        (0..<count).map { i in
            Wire.PickerItem(iconColor: 0, flags: 0, label: "item\(i)", description: "", annotation: "", matchPositions: [])
        }
    }

    private func populateState(_ state: PickerState, selected: UInt16 = 0, count: Int = 5) {
        state.update(visible: true, selectedIndex: selected, filteredCount: UInt16(count), totalCount: UInt16(count), markedCount: 0, title: "Test", query: "", hasPreview: false, rawItems: makeItems(count), actionMenu: nil)
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

        populateState(state, selected: 1)
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

    @Test("items change discards preview")
    func itemsChangeDiscardsPreview() {
        let state = PickerState()
        populateState(state, selected: 0)
        _ = state.previewNavigation(delta: 2)
        #expect(state.previewSelectedIndex != nil)

        populateState(state, selected: 0, count: 3)
        #expect(state.previewSelectedIndex == nil)
    }
}
