import Foundation
import MingaProtocol
import Testing
@testable import Minga

@Suite("Editor pane accessibility projection")
struct EditorAccessibilityTests {
    @Test("UTF-16 ranges follow exact composed text instead of display columns")
    func unicodeSelectionRange() throws {
        let surface = try makeSurface(
            texts: ["aé🙂e\u{301}界"],
            selection: GUISelectionOverlay(type: .char, startRow: 0, startCol: 2, endRow: 0, endCol: 4),
            cols: 10
        )
        let projection = EditorAccessibilityProjection.build(surface: surface, connectionID: 7, isActivePane: true, localTransform: nil, cellWidth: 8, cellHeight: 16)

        #expect(projection.value == "aé🙂e\u{301}界")
        #expect(projection.label == "sample.ex, pane 1")
        #expect(projection.value.utf16.count == 7)
        #expect(projection.selectedRanges == [NSRange(location: 2, length: 2)])
        #expect(projection.selectedText == "🙂")
    }

    @Test("character line and block selections expose only visible text")
    func selectionShapes() throws {
        let texts = ["alpha", "bravo", "charlie"]
        let character = EditorAccessibilityProjection.build(
            surface: try makeSurface(texts: texts, selection: GUISelectionOverlay(type: .char, startRow: 0, startCol: 2, endRow: 1, endCol: 3)),
            connectionID: 1, isActivePane: true, localTransform: nil, cellWidth: 8, cellHeight: 16
        )
        #expect(character.selectedRanges == [NSRange(location: 2, length: 7)])
        #expect(character.selectedText == "pha\nbra")

        let line = EditorAccessibilityProjection.build(
            surface: try makeSurface(texts: texts, selection: GUISelectionOverlay(type: .line, startRow: 1, startCol: 0, endRow: 2, endCol: 0)),
            connectionID: 1, isActivePane: true, localTransform: nil, cellWidth: 8, cellHeight: 16
        )
        #expect(line.selectedRanges == [NSRange(location: 6, length: 13)])
        #expect(line.selectedText == "bravo\ncharlie")

        let block = EditorAccessibilityProjection.build(
            surface: try makeSurface(texts: texts, selection: GUISelectionOverlay(type: .block, startRow: 0, startCol: 1, endRow: 2, endCol: 3)),
            connectionID: 1, isActivePane: true, localTransform: nil, cellWidth: 8, cellHeight: 16
        )
        #expect(block.selectedRanges == [NSRange(location: 1, length: 2), NSRange(location: 7, length: 2), NSRange(location: 13, length: 2)])
        #expect(block.selectedText == "lp\nra\nha")
    }

    @Test("a selection outside the presented rows never becomes an insertion range")
    func offscreenSelection() throws {
        let projection = EditorAccessibilityProjection.build(
            surface: try makeSurface(texts: ["only"], selection: GUISelectionOverlay(type: .char, startRow: 4, startCol: 0, endRow: 4, endCol: 2)),
            connectionID: 1, isActivePane: true, localTransform: nil, cellWidth: 8, cellHeight: 16
        )
        #expect(projection.hasSelection)
        #expect(projection.selectedRanges.isEmpty)
        #expect(projection.insertionRange == nil)
        #expect(projection.selectedText == nil)
    }

    @Test("local scrolling updates exposed rows without changing pane identity")
    func localScrollAndIdentity() throws {
        let surface = try makeSurface(texts: ["zero", "one", "two", "three"], rows: 2, contentEpoch: 9)
        let baseline = EditorAccessibilityProjection.build(surface: surface, connectionID: 4, isActivePane: true, localTransform: nil, cellWidth: 8, cellHeight: 16)
        let scrolled = EditorAccessibilityProjection.build(
            surface: surface,
            connectionID: 4,
            isActivePane: true,
            localTransform: EditorLocalPresentationTransform(windowId: 1, offset: CGPoint(x: 0, y: 16)),
            cellWidth: 8,
            cellHeight: 16
        )
        #expect(baseline.value == "zero\none")
        #expect(scrolled.value == "one\ntwo")
        #expect(scrolled.identity == baseline.identity)
        #expect(scrolled.rowsVisited <= 4)
        #expect(EditorAccessibilityProjection.build(surface: surface, connectionID: 5, isActivePane: true, localTransform: nil, cellWidth: 8, cellHeight: 16).identity != baseline.identity)
    }

    @Test("horizontal clipping preserves grapheme boundaries and UTF-16 offsets")
    func horizontalClipping() throws {
        let surface = try makeSurface(texts: ["ab🙂界cd"], cursorCol: 4, scrollLeft: 2, cols: 3)
        let projection = EditorAccessibilityProjection.build(surface: surface, connectionID: 1, isActivePane: true, localTransform: nil, cellWidth: 8, cellHeight: 16)
        #expect(projection.value == "🙂界")
        #expect(projection.value.utf16.count == 3)
        #expect(projection.insertionRange == NSRange(location: 2, length: 0))
    }

    @Test("horizontal clipping retains zero-width graphemes on both slice boundaries")
    func zeroWidthSliceBoundaries() throws {
        let leading = EditorAccessibilityProjection.build(
            surface: try makeSurface(
                texts: ["\ta🙂b"],
                selection: GUISelectionOverlay(
                    type: .char, startRow: 0, startCol: 0, endRow: 0, endCol: 0
                ),
                cols: 1,
                accessibilitySelectionRanges: [
                    GUIAccessibilityRange(row: 0, startUTF16: 0, endUTF16: 1)
                ]
            ),
            connectionID: 1,
            isActivePane: true,
            localTransform: nil,
            cellWidth: 8,
            cellHeight: 16
        )
        #expect(leading.value == "\ta")
        #expect(leading.selectedRanges == [NSRange(location: 0, length: 1)])
        #expect(leading.selectedText == "\t")

        let trailing = EditorAccessibilityProjection.build(
            surface: try makeSurface(texts: ["a\tb"], cols: 1),
            connectionID: 1,
            isActivePane: true,
            localTransform: nil,
            cellWidth: 8,
            cellHeight: 16
        )
        #expect(trailing.value == "a\t")
    }

    @Test("horizontal mapping stops at the exposed prefix of a legal payload long line")
    func boundedLongLineMapping() throws {
        let sourceBytes = FrameResourcePolicy.default.wire.payloadBytes - 4_096
        let surface = try makeSurface(texts: [String(repeating: "x", count: sourceBytes)], cols: 80)
        let projection = EditorAccessibilityProjection.build(
            surface: surface,
            connectionID: 1,
            isActivePane: true,
            localTransform: nil,
            cellWidth: 8,
            cellHeight: 16
        )

        #expect(projection.value.utf16.count == 80)
        #expect(projection.utf16UnitsVisited == 80)
        #expect(projection.utf16UnitsVisited < sourceBytes)
    }

    @Test("range bounds exclude rows outside the requested UTF-16 range")
    func rangeBoundsExcludeDisjointRows() throws {
        let projection = EditorAccessibilityProjection.build(
            surface: try makeSurface(texts: ["a", "b"]),
            connectionID: 1,
            isActivePane: true,
            localTransform: nil,
            cellWidth: 8,
            cellHeight: 16
        )

        #expect(projection.localRect(for: NSRange(location: 2, length: 1)) == CGRect(x: 0, y: 16, width: 8, height: 16))
        #expect(projection.localRect(for: NSRange(location: 8, length: 1)) == nil)
    }

    @Test("variable rows tabs wraps folds and virtual rows preserve exact text")
    func composedRowKinds() throws {
        let projection = EditorAccessibilityProjection.build(
            surface: try makeSurface(
                texts: ["a\tb", "wrap 🙂", "folded text", "virtual note"],
                rowTypes: [.normal, .wrapContinuation, .foldStart, .virtualLine],
                selection: GUISelectionOverlay(type: .char, startRow: 0, startCol: 1, endRow: 0, endCol: 1),
                accessibilitySelectionRanges: [GUIAccessibilityRange(row: 0, startUTF16: 1, endUTF16: 2)]
            ),
            connectionID: 1,
            isActivePane: true,
            localTransform: nil,
            cellWidth: 8,
            cellHeight: 16
        )
        #expect(projection.value == "a\tb\nwrap 🙂\nfolded text\nvirtual note")
        #expect(projection.selectedRanges == [NSRange(location: 1, length: 1)])
        #expect(projection.selectedText == "\t")
        #expect(projection.rows.map(\.viewportRow) == [0, 1, 2, 3])
    }

    @Test("selection ranges do not absorb an excluded virtual row")
    func selectionSkipsVirtualRow() throws {
        let projection = EditorAccessibilityProjection.build(
            surface: try makeSurface(
                texts: ["first", "virtual", "third"],
                rowTypes: [.normal, .virtualLine, .normal],
                selection: GUISelectionOverlay(
                    type: .char, startRow: 0, startCol: 0, endRow: 2, endCol: 5
                ),
                accessibilitySelectionRanges: [
                    GUIAccessibilityRange(row: 0, startUTF16: 0, endUTF16: 5),
                    GUIAccessibilityRange(row: 2, startUTF16: 0, endUTF16: 5)
                ]
            ),
            connectionID: 1,
            isActivePane: true,
            localTransform: nil,
            cellWidth: 8,
            cellHeight: 16
        )

        #expect(projection.selectedRanges == [
            NSRange(location: 0, length: 5),
            NSRange(location: 14, length: 5)
        ])
        #expect(projection.selectedText == "first\nthird")
    }

    private func makeSurface(
        texts: [String],
        rowTypes: [GUIVisualRowType]? = nil,
        selection: GUISelectionOverlay? = nil,
        cursorCol: UInt16 = 0,
        scrollLeft: UInt16 = 0,
        cols: UInt16 = 80,
        rows: UInt16? = nil,
        contentEpoch: UInt32 = 1,
        accessibilitySelectionRanges: [GUIAccessibilityRange]? = nil
    ) throws -> PresentedWindowSurface {
        let visibleRows = rows ?? UInt16(clamping: texts.count)
        let geometry = GUIPaneGeometry(
            windowId: 1,
            totalRect: GUICellRect(row: 0, col: 0, width: cols, height: visibleRows),
            contentRect: GUICellRect(row: 0, col: 0, width: cols, height: visibleRows),
            textRect: GUICellRect(row: 0, col: 0, width: cols, height: visibleRows),
            gutterRect: GUICellRect(row: 0, col: 0, width: 0, height: visibleRows),
            clipRect: GUICellRect(row: 0, col: 0, width: cols, height: visibleRows),
            viewport: GUIViewportSummary(top: 0, left: scrollLeft, rows: visibleRows, cols: cols, totalLines: UInt32(texts.count), visualRowOffset: 0, totalVisualRows: UInt32(texts.count)),
            gutterMetrics: GUIGutterMetrics(lineNumberWidth: 0, signColWidth: 0),
            hitRegions: []
        )
        let content = try GUIWindowContent(
            windowId: 1,
            fullRefresh: true,
            contentEpoch: contentEpoch,
            cursorRow: 0,
            cursorCol: cursorCol,
            cursorShape: .block,
            scrollLeft: scrollLeft,
            rows: texts.enumerated().map { index, text in
                GUIVisualRow(rowType: rowTypes?[index] ?? .normal, rowId: UInt64(index + 1), bufLine: UInt32(index), contentHash: UInt32(index), text: text, spans: [])
            },
            selection: selection,
            searchMatches: [],
            diagnosticUnderlines: [],
            documentHighlights: [],
            paneGeometry: geometry,
            accessibilityLabel: "sample.ex",
            accessibilityGeneration: UInt64(contentEpoch),
            accessibilityCursor: GUIAccessibilityCursor(row: 0, utf16: UInt32(GUIDisplayColumnMap(texts.first ?? "").utf16Offset(at: Int(cursorCol)))),
            accessibilitySelectionRanges: accessibilitySelectionRanges ?? selectionRanges(selection, texts: texts)
        )
        return PresentedWindowSurface(content: content, gutter: .none, paneGeometry: geometry, indentGuides: nil)
    }

    private func selectionRanges(_ selection: GUISelectionOverlay?, texts: [String]) -> [GUIAccessibilityRange] {
        guard let selection else { return [] }
        return (selection.startRow...selection.endRow).compactMap { rowValue in
            let row = Int(rowValue)
            guard row < texts.count else { return nil }
            let map = GUIDisplayColumnMap(texts[row])
            let startColumn = selection.type == .block || rowValue == selection.startRow
                ? Int(selection.startCol)
                : 0
            let endColumn: Int
            if selection.type == .line {
                endColumn = map.displayWidth
            } else if selection.type == .block {
                endColumn = Int(selection.endCol)
            } else if rowValue != selection.endRow {
                endColumn = map.displayWidth
            } else {
                endColumn = Int(selection.endCol)
            }
            let start = map.utf16Offset(at: startColumn)
            let end = map.utf16Offset(at: endColumn)
            return end > start
                ? GUIAccessibilityRange(row: rowValue, startUTF16: UInt32(start), endUTF16: UInt32(end))
                : nil
        }
    }
}
