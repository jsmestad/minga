import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MingaUI

@Suite("Search session reconciliation")
@MainActor
struct SearchSessionReconciliationTests {
    @Test("delayed query and option echoes do not replace newer local input")
    func ignoresDelayedEcho() {
        let state = SearchState()
        state.update(active: true, matchCount: 1, currentIndex: 1, flags: 0, query: "", sessionID: 4, acknowledgedEditSeq: 0)

        let editA = state.recordQueryEdit("A")
        let editB = state.recordQueryEdit("B")
        let optionEdit = state.toggle(.wholeWord)

        #expect(editA?.sequence == 1)
        #expect(editB?.sequence == 2)
        #expect(optionEdit?.sequence == 3)
        state.update(active: true, matchCount: 10, currentIndex: 2, flags: SearchFlags.caseSensitive, query: "A", sessionID: 4, acknowledgedEditSeq: 1)

        #expect(state.query == "B")
        #expect(state.wholeWord)
        #expect(!state.caseSensitive)
        #expect(state.latestSentSequence == 3)
    }

    @Test("an old session echo cannot replace a reopened session")
    func ignoresOldSession() {
        let state = SearchState()
        state.update(active: true, matchCount: 1, currentIndex: 1, flags: 0, query: "old", sessionID: 8, acknowledgedEditSeq: 0)
        _ = state.recordQueryEdit("unacknowledged local edit")
        state.update(active: true, matchCount: 2, currentIndex: 1, flags: SearchFlags.regex, query: "new", sessionID: 9, acknowledgedEditSeq: 0)
        state.update(active: true, matchCount: 99, currentIndex: 9, flags: SearchFlags.caseSensitive, query: "stale", sessionID: 8, acknowledgedEditSeq: 4)

        #expect(state.sessionID == 9)
        #expect(state.query == "new")
        #expect(state.regex)
        #expect(!state.caseSensitive)
    }

    @Test("acknowledgement installs authoritative Unicode query and match counters")
    func acceptsAcknowledgement() {
        let state = SearchState()
        state.update(active: true, matchCount: 0, currentIndex: 0, flags: 0, query: "", sessionID: 2, acknowledgedEditSeq: 0)
        let edit = state.recordQueryEdit("茶🙂")
        state.update(active: true, matchCount: 3, currentIndex: 2, flags: SearchFlags.regex, query: "茶🙂", sessionID: 2, acknowledgedEditSeq: edit?.sequence ?? 0)

        #expect(state.query == "茶🙂")
        #expect(state.matchCount == 3)
        #expect(state.currentIndex == 2)
        #expect(state.regex)
    }

    @Test("marked text stays local until IME commit")
    func preservesMarkedTextUntilCommit() {
        let state = SearchState()
        state.update(active: true, matchCount: 0, currentIndex: 0, flags: 0, query: "", sessionID: 5, acknowledgedEditSeq: 0)
        let encoder = SpyEncoder()
        let style = InlineEditFieldStyle(textColor: .white, selectionBackgroundColor: .blue, selectionForegroundColor: .white, insertionPointColor: .blue)
        let coordinator = SearchQueryField.Coordinator(searchState: state, encoder: encoder, style: style)
        let field = SearchNSTextField()
        field.isEditable = true
        let editor = NSTextView()

        field.stringValue = "に"
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        coordinator.handleTextChange(field: field, editor: editor)
        #expect(encoder.searchQueryCalls.isEmpty)
        #expect(state.query == "")

        editor.unmarkText()
        field.stringValue = "日本🙂"
        coordinator.handleTextChange(field: field, editor: editor)

        #expect(encoder.searchQueryCalls == [.init(sessionID: 5, editSeq: 1, query: "日本🙂", flags: 0)])
        #expect(state.query == "日本🙂")
    }

    @Test("wire limit and UTF-16 selection clamp are exact")
    func wireLimitAndSelectionClamp() {
        #expect(SearchState.queryFitsWire(String(repeating: "a", count: Int(UInt16.max))))
        #expect(!SearchState.queryFitsWire(String(repeating: "🙂", count: 16_384)))
        #expect(SearchState.clampSelection(NSRange(location: 9, length: 4), to: "a🙂") == NSRange(location: 3, length: 0))
    }

    @Test("decoder carries the complete authoritative search state")
    func decoderCarriesCompleteState() throws {
        let query = Data("café".utf8)
        var payload = Data([1, 0, 4, 0, 2, SearchFlags.caseSensitive])
        payload.append(UInt8(query.count >> 8))
        payload.append(UInt8(query.count & 0xFF))
        payload.append(query)
        payload.append(contentsOf: [0, 0, 0, 7, 0, 0, 0, 3])
        var data = Data([OP_GUI_SEARCH_STATE, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        data.append(payload)

        let (command, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)
        guard case .guiSearchState(let active, let count, let index, let flags, let decodedQuery, let sessionID, let acknowledgedEditSeq) = command else {
            Issue.record("Expected guiSearchState")
            return
        }
        #expect(active)
        #expect(count == 4)
        #expect(index == 2)
        #expect(flags == SearchFlags.caseSensitive)
        #expect(decodedQuery == "café")
        #expect(sessionID == 7)
        #expect(acknowledgedEditSeq == 3)
    }
}
