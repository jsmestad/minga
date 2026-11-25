import Testing
@testable import MingaUI
import MingaProtocol
import CoreGraphics
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

    private let defaultKeys = [
        Wire.PickerKey(codepoint: 106, modifiers: 0x02, delta: 1),
        Wire.PickerKey(codepoint: 57_353, modifiers: 0, delta: 1),
        Wire.PickerKey(codepoint: 107, modifiers: 0x02, delta: -1),
        Wire.PickerKey(codepoint: 57_352, modifiers: 0, delta: -1),
        // Enter and the act menu run a command on the BEAM and show nothing ahead.
        Wire.PickerKey(codepoint: 13, modifiers: 0),
        Wire.PickerKey(codepoint: 46, modifiers: 0x02)
    ]

    @Test("a key moves the preview only when the BEAM listed that exact key as picker movement")
    func movementDeltaFollowsTheListedKeys() {
        let state = PickerState()
        state.update(visible: true, selectedIndex: 0, filteredCount: 5, totalCount: 5, markedCount: 0, title: "Test", query: "", hasPreview: false, rawItems: makeItems(5), actionMenu: nil, activationGeneration: 7, keys: defaultKeys)

        #expect(state.movementDelta(codepoint: 106, modifiers: 0x02) == 1)
        #expect(state.movementDelta(codepoint: 107, modifiers: 0x02) == -1)
        #expect(state.movementDelta(codepoint: 57_353, modifiers: 0) == 1)
        // Plain j and k type into the query on the BEAM.
        #expect(state.movementDelta(codepoint: 106, modifiers: 0) == nil)
        #expect(state.movementDelta(codepoint: 107, modifiers: 0) == nil)
        // The same codepoint with another modifier is another key.
        #expect(state.movementDelta(codepoint: 57_353, modifiers: 0x01) == nil)
        // A listed key without a preview moves nothing.
        #expect(state.movementDelta(codepoint: 13, modifiers: 0) == nil)
    }

    @Test("the picker binds exactly the keys the BEAM lists, with or without a preview", arguments: [
        (UInt32(106), UInt8(0x02), true),
        (57_352, 0, true),
        (13, 0, true),
        (46, 0x02, true),
        // Plain j types into the query, ⌃N is not bound here, and another modifier is another key.
        (106, 0, false),
        (110, 0x02, false),
        (13, 0x01, false)
    ] as [(UInt32, UInt8, Bool)])
    func bindsFollowsTheListedKeys(codepoint: UInt32, modifiers: UInt8, bound: Bool) {
        let state = PickerState()
        state.update(visible: true, selectedIndex: 0, filteredCount: 5, totalCount: 5, markedCount: 0, title: "Test", query: "", hasPreview: false, rawItems: makeItems(5), actionMenu: nil, activationGeneration: 7, keys: defaultKeys)

        #expect(state.binds(codepoint: codepoint, modifiers: modifiers) == bound)
    }

    @Test("a key press moves the highlight ahead only when the BEAM allows a preview for it")
    func previewNavigationByKey() {
        let state = PickerState()
        state.update(visible: true, selectedIndex: 1, filteredCount: 5, totalCount: 5, markedCount: 0, title: "Test", query: "", hasPreview: false, rawItems: makeItems(5), actionMenu: nil, activationGeneration: 7, keys: defaultKeys)

        #expect(state.previewNavigation(codepoint: 13, modifiers: 0) == false)
        #expect(state.previewNavigation(codepoint: 110, modifiers: 0x02) == false)
        #expect(state.effectiveSelectedIndex == 1)
        #expect(state.previewNavigation(codepoint: 106, modifiers: 0x02))
        #expect(state.effectiveSelectedIndex == 2)
    }

    @Test("without listed keys nothing moves the preview, and hiding forgets the keys")
    func movementKeysDefaultToNone() {
        let state = PickerState()
        populateState(state)
        #expect(state.movementDelta(codepoint: 57_353, modifiers: 0) == nil)

        state.update(visible: true, selectedIndex: 0, filteredCount: 5, totalCount: 5, markedCount: 0, title: "Test", query: "", hasPreview: false, rawItems: makeItems(5), actionMenu: nil, activationGeneration: 7, keys: defaultKeys)
        state.hide()
        #expect(state.keys.isEmpty)
    }

    @Test("the open act menu owns the list keys, so the picker row preview stays put")
    func previewNavigationYieldsToTheActionMenu() {
        let state = PickerState()
        let menu = Wire.PickerActionMenu(selectedIndex: 0, actions: ["Open", "Kill"], activationIDs: [41, 42])
        state.update(visible: true, selectedIndex: 1, filteredCount: 5, totalCount: 5, markedCount: 0, title: "Test", query: "", hasPreview: false, rawItems: makeItems(5), actionMenu: menu, activationGeneration: 7, keys: defaultKeys)

        #expect(state.previewNavigation(delta: 1) == false)
        #expect(state.effectiveSelectedIndex == 1)
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

    @Test("a one-row preview wraps at the ends only when the picker holds the whole list", arguments: [
        // rows, selected, filtered, next steps, deltas, expected row
        (3, 0, 3, false, [-1], 2),
        (3, 2, 3, false, [1], 0),
        (3, 0, 3, false, [-1, 1], 0),
        (3, 2, 3, false, [1, -1], 2),
        (1, 0, 1, false, [1], 0),
        // The BEAM offers a window of a long list: the row it moves to is not here.
        (5, 0, 250, false, [-1], 0),
        (5, 4, 250, false, [1], 4),
        (5, 3, 250, false, [1], 4),
        // Next-step rows are counted as no matches, and they are the whole list.
        (2, 1, 0, true, [1], 0),
        (2, 0, 0, true, [-1], 1)
    ])
    func previewNavigationWrapsLikeTheBEAM(rows: Int, selected: Int, filtered: Int, nextSteps: Bool, deltas: [Int], expected: Int) {
        let state = PickerState()
        let empty = nextSteps ? Wire.EmptyList(glyph: "", title: "No projects yet.", why: "", selected: 0, actions: []) : nil
        state.update(visible: true, selectedIndex: UInt16(selected), filteredCount: UInt16(filtered), totalCount: UInt16(filtered), markedCount: 0, title: "Test", query: "", hasPreview: false, rawItems: makeItems(rows), actionMenu: nil, activationGeneration: 7, empty: empty)

        for delta in deltas { _ = state.previewNavigation(delta: delta) }

        #expect(state.effectiveSelectedIndex == expected)
        #expect(state.selectedIndex == selected)
        // A key with nothing to preview leaves no preview behind, so the next frame's row is shown as it is.
        if deltas.count == 1 { #expect((state.previewSelectedIndex != nil) == (expected != selected)) }
    }

    @Test("a preview made before the act menu's frame arrived is dropped by that frame", arguments: [(false, 2), (true, 1)])
    func previewDoesNotOutliveTheActMenuFrame(menuOpens: Bool, expected: Int) {
        let state = PickerState()
        populateState(state, selected: 1)
        #expect(state.previewNavigation(delta: 1))
        #expect(state.effectiveSelectedIndex == 2)

        // The key moved the menu on the BEAM, so its frame still has the picker on row 1.
        let menu = menuOpens ? Wire.PickerActionMenu(selectedIndex: 1, actions: ["Open", "Kill"], activationIDs: [41, 42]) : nil
        state.update(visible: true, selectedIndex: 1, filteredCount: 5, totalCount: 5, markedCount: 0, title: "Test", query: "", hasPreview: false, rawItems: makeItems(5), actionMenu: menu, activationGeneration: 7)

        #expect(state.effectiveSelectedIndex == expected)
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

    @Test("a preview is kept only under the list it was made under", arguments: [
        // new revision, rows in the next frame, expected highlighted row
        // The same list: the preview stays until the BEAM catches up.
        (UInt32(3), [1, 2, 3, 4, 5], 2),
        // Another revision drops it although its row is still listed.
        (4, [1, 2, 3, 4, 5], 0),
        // A refiltered and a reordered list are other lists.
        (4, [1, 3, 5], 0),
        (4, [3, 2, 1, 4, 5], 0)
    ] as [(UInt32, [UInt32], Int)])
    func previewIsTiedToTheListRevision(revision: UInt32, rows: [UInt32], expected: Int) {
        let state = PickerState()
        let items = { (ids: [UInt32]) in ids.map { Wire.PickerItem(iconColor: 0, flags: 0, label: "item\($0)", description: "", annotation: "", matchPositions: [], activationID: $0) } }
        state.update(visible: true, selectedIndex: 0, filteredCount: 5, totalCount: 5, markedCount: 0, title: "Test", query: "", hasPreview: false, rawItems: items([1, 2, 3, 4, 5]), actionMenu: nil, activationGeneration: 7, listRevision: 3)
        _ = state.previewNavigation(delta: 2)
        #expect(state.effectiveSelectedIndex == 2)

        state.update(visible: true, selectedIndex: 0, filteredCount: UInt16(rows.count), totalCount: 5, markedCount: 0, title: "Test", query: "", hasPreview: false, rawItems: items(rows), actionMenu: nil, activationGeneration: 7, listRevision: revision)

        #expect(state.effectiveSelectedIndex == expected)
        #expect((state.previewSelectedIndex != nil) == (expected != 0))
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

@MainActor
@Suite("Picker section headers")
struct PickerSectionHeaderTests {
    private func items(_ groups: [String]) -> [PickerItem] {
        var result: [PickerItem] = []
        for (index, group) in groups.enumerated() {
            result.append(PickerItem(id: index, iconColor: 0, label: "item\(index)", description: "", annotation: "", matchPositions: [], isMarked: false, group: group))
        }
        return result
    }

    @Test("a header goes above the first item of each group and never above an ungrouped item")
    func headersAtGroupChanges() {
        let list = items(["A", "A", "", "B", "B", "A"])
        var headers: [String?] = []
        for index in list.indices {
            headers.append(PickerOverlay.sectionHeader(list, at: index))
        }
        let expected: [String?] = ["A", nil, nil, "B", nil, "A"]
        #expect(headers == expected)
        #expect(PickerOverlay.sectionHeader(list, at: 6) == nil)
    }

    @Test("ungrouped lists keep their height; each section header adds its own height")
    func listHeightCountsHeaders() {
        let ungrouped = items(["", "", ""])
        let rows: CGFloat = 3 * PickerOverlay.itemHeight
        #expect(PickerOverlay.listContentHeight(ungrouped) == rows)

        let grouped = items(["A", "A", "B"])
        let withHeaders: CGFloat = rows + 2 * PickerOverlay.sectionHeaderHeight
        #expect(PickerOverlay.listContentHeight(grouped) == withHeaders)
    }

    @Test("the reported fit counts the whole rows the list shows")
    func visibleRowCountForUniformRows() {
        let rows = items(Array(repeating: "", count: 65))
        let height = PickerOverlay.itemHeight

        #expect(PickerOverlay.visibleRowCount(rows, listHeight: 13 * height, selectedIndex: 0) == 13)
        // A partly shown row is not a row the user has seen whole.
        #expect(PickerOverlay.visibleRowCount(rows, listHeight: 13.6 * height, selectedIndex: 30) == 13)
        // The count does not depend on where the highlighted row is.
        #expect(PickerOverlay.visibleRowCount(rows, listHeight: 13 * height, selectedIndex: 64) == 13)
        #expect(PickerOverlay.visibleRowCount(items(["", "", ""]), listHeight: 13 * height, selectedIndex: 1) == 3)
    }

    @Test("section headers take list height, so fewer rows fit")
    func visibleRowCountCountsHeaders() {
        let grouped = items(["A", "A", "B", "B", "C", "C"])
        let height = 4 * PickerOverlay.itemHeight

        #expect(PickerOverlay.visibleRowCount(items(Array(repeating: "", count: 6)), listHeight: height, selectedIndex: 0) == 4)
        // Header A and its two rows fit. Header B fits too, but its first row does not, so that row is not counted.
        #expect(PickerOverlay.visibleRowCount(grouped, listHeight: height, selectedIndex: 0) == 2)

        // A list exactly as tall as two headers and three rows shows the first row of group B whole.
        let threeRows = 2 * PickerOverlay.sectionHeaderHeight + 3 * PickerOverlay.itemHeight
        #expect(PickerOverlay.visibleRowCount(grouped, listHeight: threeRows, selectedIndex: 0) == 3)
    }

    @Test("the highlighted row always counts, and an empty list has no fit")
    func visibleRowCountBounds() {
        let rows = items(["", ""])

        #expect(PickerOverlay.visibleRowCount(rows, listHeight: 1, selectedIndex: 0) == 1)
        #expect(PickerOverlay.visibleRowCount([], listHeight: 240, selectedIndex: 0) == 0)

        let state = PickerState()
        #expect(PickerOverlay.fit(state, listHeight: 240) == nil)
        state.update(visible: true, selectedIndex: 0, filteredCount: 2, totalCount: 2, markedCount: 0, title: "Grouped", query: "", hasPreview: false, rawItems: [
            Wire.PickerItem(iconColor: 0, flags: 0, label: "a", description: "", annotation: "", matchPositions: [], activationID: 1),
            Wire.PickerItem(iconColor: 0, flags: 0, label: "b", description: "", annotation: "", matchPositions: [], activationID: 2)
        ], actionMenu: nil, activationGeneration: 7)
        #expect(PickerOverlay.fit(state, listHeight: 240) == PickerOverlay.Fit(generation: 7, rows: 2))
    }

    @Test("moving the selection crosses a section boundary in one step because headers are not items")
    func previewNavigationSkipsHeaders() {
        let state = PickerState()
        var raw: [Wire.PickerItem] = []
        let groups = ["A", "A", "B"]
        for (index, group) in groups.enumerated() {
            raw.append(Wire.PickerItem(iconColor: 0, flags: 0, label: "item\(index)", description: "", annotation: "", matchPositions: [], activationID: UInt32(index + 1), group: group))
        }
        state.update(visible: true, selectedIndex: 1, filteredCount: 3, totalCount: 3, markedCount: 0, title: "Grouped", query: "", hasPreview: false, rawItems: raw, actionMenu: nil, activationGeneration: 7)

        #expect(state.items.count == 3)
        #expect(state.items[2].group == "B")
        #expect(state.previewNavigation(delta: 1))
        #expect(state.effectiveSelectedIndex == 2)
        #expect(state.items[state.effectiveSelectedIndex].activation.activationID == 3)
    }
}
