import AppKit
import CoreText
import MingaUI
import MingaProtocol
import Testing

@Suite("Displayed text targets")
@MainActor
struct PresentedTextLayoutTests {
    private func row(text: String, rank: UInt32 = 70_000, id: UInt64 = 88, y: CGFloat = 20, start: Int = 0) -> PresentedTextLayout.Row {
        let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)])
        return PresentedTextLayout.Row(rowIndex: rank, rowID: id, presentationRow: 0, composedUTF16Start: start, composedUTF16End: start + text.utf16.count, line: CTLineCreateWithAttributedString(attributed), origin: CGPoint(x: 40, y: y), rect: CGRect(x: 40, y: y, width: 200, height: 20))
    }

    @Test("CoreText hit returns composed UTF16 and exact resident rank after accented text")
    func unicodeAndResidentRank() throws {
        let row = row(text: "ééé A界😀z")
        let layout = PresentedTextLayout(panes: [.init(windowID: 2, presentationID: 44, rect: CGRect(x: 40, y: 20, width: 200, height: 40), scrollOffset: .zero, rows: [row])])
        let hit = try #require(layout.hit(at: CGPoint(x: row.x(at: 4) + 0.01, y: 25)))
        #expect(hit.target == EditorTextTarget(windowID: 2, presentationID: 44, rowIndex: 70_000, rowID: 88, utf16Offset: 4))
        #expect(layout.hit(at: CGPoint(x: 239, y: 55))?.target.utf16Offset == 9)
    }

    @Test("clipped row retains its original composed offset")
    func horizontalSlice() {
        let row = row(text: "界abc", start: 12)
        #expect(row.utf16(at: row.x(at: 13) + 0.01) == 13)
        #expect(row.utf16(at: -10) == 12)
        #expect(row.utf16(at: 500) == 16)
    }

    @Test("drag stays in its origin pane and reports edge direction")
    func dragOrigin() throws {
        let first = row(text: "abc")
        let second = row(text: "xyz", rank: 8, id: 99, y: 80)
        let layout = PresentedTextLayout(panes: [
            .init(windowID: 1, presentationID: 10, rect: CGRect(x: 40, y: 20, width: 200, height: 40), scrollOffset: .zero, rows: [first]),
            .init(windowID: 2, presentationID: 11, rect: CGRect(x: 40, y: 80, width: 200, height: 40), scrollOffset: .zero, rows: [second])
        ])
        let point = CGPoint(x: 100, y: 90)
        #expect(layout.hit(at: point)?.target.windowID == 2)
        let drag = try #require(layout.hit(at: point, capturedWindowID: 1))
        #expect(drag.target.windowID == 1)
        #expect(drag.scrollY == 1)
        #expect(layout.hit(at: point, capturedWindowID: 3) == nil)
    }

    @Test("empty rows and captured scroll use the displayed geometry")
    func emptyAndScroll() throws {
        let empty = row(text: "", y: 7)
        let layout = PresentedTextLayout(panes: [.init(windowID: 1, presentationID: 1, rect: CGRect(x: 40, y: 5, width: 200, height: 40), scrollOffset: CGPoint(x: 3, y: 13), rows: [empty])])
        #expect(layout.hit(at: CGPoint(x: 60, y: 10))?.target.utf16Offset == 0)
        #expect(layout.cursor(windowID: 1, row: 0, utf16: 0) == CGPoint(x: 43, y: 20))
    }
}

@Suite("Accessibility selection overlay")
@MainActor
struct AccessibilitySelectionOverlayTests {
    private let scale: Float = 2
    private let rowHeight: Float = 40
    private let color = SIMD3<Float>(0.9, 0.1, 0.2)

    private func row(_ text: String, at presentationRow: Int, start: Int = 0, originX: CGFloat = 40) -> PresentedTextLayout.Row {
        let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)])
        return PresentedTextLayout.Row(
            rowIndex: UInt32(clamping: presentationRow), rowID: UInt64(clamping: presentationRow), presentationRow: presentationRow,
            composedUTF16Start: start, composedUTF16End: start + text.utf16.count,
            line: CTLineCreateWithAttributedString(attributed), origin: CGPoint(x: originX, y: 0), rect: .zero
        )
    }

    /// Device-pixel x of a composed UTF-16 offset, measured directly from the row's CoreText line.
    private func edge(_ row: PresentedTextLayout.Row, _ utf16: Int) -> Float {
        Float(row.origin.x + CTLineGetOffsetForStringIndex(row.line, utf16 - row.composedUTF16Start, nil)) * scale
    }

    private func rect(_ row: PresentedTextLayout.Row, _ start: Int, _ end: Int) -> SIMD4<Float> {
        let x = edge(row, start)
        return SIMD4(x, Float(row.presentationRow) * rowHeight, edge(row, end) - x, rowHeight)
    }

    /// Appends quads in prepared-row order and returns their (x, y, width, height) rectangles.
    private func rects(
        _ ranges: [GUIAccessibilityRange], selection: GUISelectionOverlay?, rows: [PresentedTextLayout.Row],
        yOffset: Float = 0, clipLeft: Float = 80, clipRight: Float = 600, clipTop: Float = 0, clipBottom: Float = 400
    ) -> [SIMD4<Float>] {
        let overlay = AccessibilitySelectionOverlay(ranges: ranges, selection: selection, color: color)
        var quads: [QuadGPU] = []
        for row in rows {
            overlay.appendQuads(
                for: row, y: yOffset + Float(row.presentationRow) * rowHeight, height: rowHeight, scale: scale,
                clipLeft: clipLeft, clipRight: clipRight, clipTop: clipTop, clipBottom: clipBottom,
                to: &quads
            )
        }
        #expect(quads.allSatisfy { $0.color == color && $0.alpha == 1 })
        return quads.map { SIMD4($0.position.x, $0.position.y, $0.size.x, $0.size.y) }
    }

    @Test("a nil selection paints ranges in input order within a row and command order across rows")
    func nilSelectionKeepsRangeAndCommandOrder() {
        let first = row("alpha beta", at: 0)
        let second = row("gamma", at: 1)
        let third = row("delta epsilon", at: 2)
        let ranges = [
            GUIAccessibilityRange(row: 2, startUTF16: 6, endUTF16: 13),
            GUIAccessibilityRange(row: 0, startUTF16: 0, endUTF16: 5),
            GUIAccessibilityRange(row: 2, startUTF16: 0, endUTF16: 5),
            GUIAccessibilityRange(row: 0, startUTF16: 0, endUTF16: 5),
            GUIAccessibilityRange(row: 1, startUTF16: 1, endUTF16: 3),
        ]

        #expect(rects(ranges, selection: nil, rows: [third, first, second]) == [
            rect(third, 6, 13), rect(third, 0, 5), rect(first, 0, 5), rect(first, 0, 5), rect(second, 1, 3),
        ])
    }

    @Test("characterwise rows before the end row extend through the newline and blockwise rows stop at the range")
    func newlineExtension() {
        let first = row("one two", at: 0)
        let last = row("three", at: 1)
        let ranges = [
            GUIAccessibilityRange(row: 0, startUTF16: 0, endUTF16: 3),
            GUIAccessibilityRange(row: 0, startUTF16: 4, endUTF16: 7),
            GUIAccessibilityRange(row: 1, startUTF16: 0, endUTF16: 2),
        ]
        let char = GUISelectionOverlay(type: .char, startRow: 0, startCol: 0, endRow: 1, endCol: 2)
        let block = GUISelectionOverlay(type: .block, startRow: 0, startCol: 0, endRow: 1, endCol: 2)

        #expect(rects(ranges, selection: char, rows: [first, last]) == [
            SIMD4(edge(first, 0), 0, 600 - edge(first, 0), rowHeight),
            SIMD4(edge(first, 4), 0, 600 - edge(first, 4), rowHeight),
            rect(last, 0, 2),
        ])
        #expect(rects(ranges, selection: block, rows: [first, last]) == [rect(first, 0, 3), rect(first, 4, 7), rect(last, 0, 2)])
    }

    @Test("scrolled and horizontally sliced rows clip to the content rect")
    func scrollAndClip() {
        let sliced = row("界abcdefgh", at: 0, start: 12, originX: 0)
        let below = row("hidden", at: 1)
        let ranges = [
            GUIAccessibilityRange(row: 0, startUTF16: 12, endUTF16: 13),
            GUIAccessibilityRange(row: 0, startUTF16: 12, endUTF16: 17),
            GUIAccessibilityRange(row: 0, startUTF16: 15, endUTF16: 21),
            GUIAccessibilityRange(row: 1, startUTF16: 0, endUTF16: 6),
        ]
        let clipLeft: Float = 40
        let clipRight = edge(sliced, 19)
        #expect(edge(sliced, 13) < clipLeft && edge(sliced, 15) > clipLeft, "fixture must straddle the left clip edge")

        #expect(rects(ranges, selection: nil, rows: [sliced, below], yOffset: -10, clipLeft: clipLeft, clipRight: clipRight, clipBottom: 30) == [
            SIMD4(clipLeft, 0, edge(sliced, 17) - clipLeft, 30),
            SIMD4(edge(sliced, 15), 0, clipRight - edge(sliced, 15), 30),
        ])
    }

    @Test("combining and non-BMP ranges use CoreText UTF-16 boundaries")
    func unicodeBoundaries() {
        let text = row("e\u{301}x😀界z", at: 0)
        let ranges = [
            GUIAccessibilityRange(row: 0, startUTF16: 0, endUTF16: 2),
            GUIAccessibilityRange(row: 0, startUTF16: 3, endUTF16: 5),
            GUIAccessibilityRange(row: 0, startUTF16: 5, endUTF16: 7),
        ]

        let quads = rects(ranges, selection: nil, rows: [text])
        #expect(quads == [rect(text, 0, 2), rect(text, 3, 5), rect(text, 5, 7)])
        #expect(quads.allSatisfy { $0.z > 0 })
        #expect(quads[0].x < quads[1].x && quads[1].x < quads[2].x)
    }

    @Test("empty ranges, linewise selections, and rows without ranges add no quads")
    func emptyAndLinewise() {
        let text = row("line", at: 0)
        let ranges = [GUIAccessibilityRange(row: 0, startUTF16: 0, endUTF16: 4)]
        let char = GUISelectionOverlay(type: .char, startRow: 0, startCol: 0, endRow: 0, endCol: 4)
        let line = GUISelectionOverlay(type: .line, startRow: 0, startCol: 0, endRow: 0, endCol: 0)

        #expect(rects([], selection: char, rows: [text]).isEmpty)
        #expect(rects(ranges, selection: line, rows: [text]).isEmpty)
        #expect(rects(ranges, selection: nil, rows: [row("overscan", at: -1), row("next", at: 1)]).isEmpty)
    }
}

@Suite("Text presentation lifetime")
@MainActor
struct TextPresentationLeasesTests {
    private func snapshot(_ id: UInt64) -> CommittedEditorSnapshot {
        var metadata = EditorSnapshotMetadata.empty
        metadata.textPresentations = [1: id]
        return CommittedEditorSnapshot(generation: 1, frameSeq: UInt32(id), frameState: FrameState(cols: 80, rows: 24), themeColors: nil, surfaces: [], activeWindowId: nil, metadata: metadata)
    }

    @Test("a visible frame survives commit and retirement waits for the last native attempt")
    func retainedVisibleAndAttempt() {
        let leases = TextPresentationLeases()
        var events: [String] = []
        leases.onState = { _, id, state in events.append("\(id):\(state.rawValue)") }
        leases.commit(snapshot(1))
        let firstAttempt = leases.beginAttempt(snapshot(1))
        leases.present(snapshot(1))
        leases.commit(snapshot(2))
        #expect(events == ["1:1"])
        leases.present(snapshot(2))
        #expect(events == ["1:1", "2:1"])
        leases.finishAttempt(firstAttempt)
        #expect(events == ["1:1", "2:1", "1:0"])
    }

    @Test("superseded unpresented candidates retire and duplicate redraws retain one active target")
    func discardedCandidates() {
        let leases = TextPresentationLeases()
        var events: [String] = []
        leases.onState = { _, id, state in events.append("\(id):\(state.rawValue)") }
        leases.commit(snapshot(1))
        leases.commit(snapshot(2))
        #expect(events == ["1:0"])
        let a = leases.beginAttempt(snapshot(2))
        let b = leases.beginAttempt(snapshot(2))
        leases.present(snapshot(2))
        leases.present(snapshot(2))
        leases.finishAttempt(a)
        leases.finishAttempt(b)
        #expect(events == ["1:0", "2:1"])
        leases.replaceConnection()
        #expect(events == ["1:0", "2:1"])
    }
}

@Suite("Displayed text protocol decoding")
struct DisplayedTextDecoderTests {
    @Test("presentation metadata decodes a full 64-bit identity")
    func presentation() throws {
        let bytes = Data([OP_GUI_TEXT_PRESENTATION, 2, 0, 1, 2, 3, 4, 5, 6, 7, 8])
        let (command, size) = try decodeCommand(data: bytes, offset: 0)
        guard case .guiTextPresentation(let window, let identity) = command else {
            Issue.record("Expected text presentation metadata")
            return
        }
        #expect(size == 11)
        #expect(window == 512)
        #expect(identity == 0x0102030405060708)
        #expect(throws: ProtocolDecodeError.self) { try decodeCommand(data: Data(bytes.dropLast()), offset: 0) }
    }
}
