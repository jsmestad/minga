/// Tests for CoreTextMetalRenderer cursor coordinate selection.

import Testing
import Foundation

@Suite("CoreTextMetalRenderer cursor geometry")
struct CoreTextMetalRendererCursorTests {
    @Test("semantic window cursor overrides legacy frameState cursor")
    func semanticCursorOverridesLegacyCursor() {
        let cellW: Float = 7.5
        let displayCellH: Float = 16.0
        let scale: Float = 2.0
        let gutterLeft: Float = 3.0
        let gutterPadding: Float = 5.0

        var frameState = FrameState(cols: 80, rows: 24)
        frameState.cursorRow = 20
        frameState.cursorCol = 70
        frameState.cursorShape = .block
        frameState.windowGutters[2] = Wire.WindowGutter(
            windowId: 2, contentRow: 4, contentCol: 1, contentHeight: 20,
            isActive: true, contentWidth: 80, cursorLine: 10, lineNumberStyle: .hybrid,
            lineNumberWidth: 4, signColWidth: 1, entries: []
        )

        let content = GUIWindowContent(
            windowId: 2, fullRefresh: true,
            cursorRow: 2, cursorCol: 10, cursorShape: .beam,
            scrollLeft: 3,
            rows: [], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: []
        )

        let cursor = CoreTextMetalRenderer.resolveCursor(
            frameState: frameState,
            windowContents: [2: content],
            cellW: cellW,
            displayCellH: displayCellH,
            scale: scale,
            gutterLeftMarginPx: gutterLeft,
            gutterPaddingPx: gutterPadding
        )

        let contentColOffset = (Float(1 + 4 + 1) * cellW * scale) + gutterLeft + gutterPadding
        let expectedX = contentColOffset + Float(10 - 3) * cellW * scale
        let expectedY = Float(4 + 2) * displayCellH * scale

        #expect(cursor?.shape == .beam)
        #expect(abs((cursor?.x ?? 0) - expectedX) < 0.001)
        #expect(abs((cursor?.y ?? 0) - expectedY) < 0.001)
    }

    @Test("semantic block cursor at end of line renders over final character")
    func semanticBlockCursorAtEndOfLineUsesFinalCharacterCell() {
        let content = GUIWindowContent(
            windowId: 1, fullRefresh: true,
            cursorRow: 0, cursorCol: 4, cursorShape: .block,
            rows: [GUIVisualRow(rowType: .normal, bufLine: 0, contentHash: 1, text: "this", spans: [])],
            selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: []
        )

        #expect(CoreTextMetalRenderer.resolvedSemanticCursorCol(content) == 3)
    }

    @Test("semantic beam cursor at end of line keeps insertion point column")
    func semanticBeamCursorAtEndOfLineKeepsInsertionPointColumn() {
        let content = GUIWindowContent(
            windowId: 1, fullRefresh: true,
            cursorRow: 0, cursorCol: 4, cursorShape: .beam,
            rows: [GUIVisualRow(rowType: .normal, bufLine: 0, contentHash: 1, text: "this", spans: [])],
            selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: []
        )

        #expect(CoreTextMetalRenderer.resolvedSemanticCursorCol(content) == 4)
    }

    @Test("semantic block cursor uses display width for wide characters")
    func semanticBlockCursorUsesDisplayWidthForWideCharacters() {
        let content = GUIWindowContent(
            windowId: 1, fullRefresh: true,
            cursorRow: 0, cursorCol: 2, cursorShape: .block,
            rows: [GUIVisualRow(rowType: .normal, bufLine: 0, contentHash: 1, text: "界", spans: [])],
            selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: []
        )

        #expect(CoreTextMetalRenderer.resolvedSemanticCursorCol(content) == 1)
    }

    @Test("legacy cursor is used when semantic content is unavailable")
    func legacyCursorFallback() {
        let cellW: Float = 7.5
        let displayCellH: Float = 16.0
        let scale: Float = 2.0
        let gutterLeft: Float = 3.0
        let gutterPadding: Float = 5.0

        var frameState = FrameState(cols: 80, rows: 24)
        frameState.cursorRow = 3
        frameState.cursorCol = 10
        frameState.cursorShape = .underline
        frameState.gutterCol = 5

        let cursor = CoreTextMetalRenderer.resolveCursor(
            frameState: frameState,
            windowContents: [:],
            cellW: cellW,
            displayCellH: displayCellH,
            scale: scale,
            gutterLeftMarginPx: gutterLeft,
            gutterPaddingPx: gutterPadding
        )

        let expectedX = Float(10) * cellW * scale + gutterLeft + gutterPadding
        let expectedY = Float(3) * displayCellH * scale

        #expect(cursor?.shape == .underline)
        #expect(abs((cursor?.x ?? 0) - expectedX) < 0.001)
        #expect(abs((cursor?.y ?? 0) - expectedY) < 0.001)
    }

    @Test("hidden semantic cursor suppresses legacy fallback after dispatcher sync")
    @MainActor func hiddenSemanticCursorSuppressesFallback() {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 80, rows: 24, guiState: gui)
        dispatcher.frameState.cursorRow = 3
        dispatcher.frameState.cursorCol = 10
        dispatcher.frameState.cursorShape = .block
        dispatcher.frameState.windowGutters[1] = Wire.WindowGutter(
            windowId: 1, contentRow: 0, contentCol: 0, contentHeight: 24,
            isActive: true, contentWidth: 80, cursorLine: 1, lineNumberStyle: .hybrid,
            lineNumberWidth: 4, signColWidth: 1, entries: []
        )

        let content = GUIWindowContent(
            windowId: 1, fullRefresh: true, cursorVisible: false,
            cursorRow: 0, cursorCol: 0, cursorShape: .beam,
            rows: [], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: []
        )
        dispatcher.dispatch(.guiWindowContent(data: content))

        let cursor = CoreTextMetalRenderer.resolveCursor(
            frameState: dispatcher.frameState,
            windowContents: gui.windowContents,
            cellW: 7.5,
            displayCellH: 16.0,
            scale: 2.0,
            gutterLeftMarginPx: 0,
            gutterPaddingPx: 0
        )

        #expect(dispatcher.frameState.cursorVisible == false)
        #expect(cursor == nil)
    }
}
