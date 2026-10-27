import MingaProtocol
import Testing

/// Differential parity between shipping viewport clipping and a reference that always rebuilds the clipped row, so retained-row reuse cannot change output.
@Suite("Resident clip reuse parity")
struct ResidentClipParityTests {
    private static let texts: [String] = [
        "", "a", "abcdef", "a界b", "界界abc", "é🙂z", "e\u{301}e\u{301}x", "👩‍👩‍👧z",
        "a\r\nb", "\r\n", "🇺🇸🇨🇦", "\tx y", "ｱ全角Ａ", "한글", "𠀀b", "x\u{20DD}y",
    ]

    private static let graphemes: [String] = [
        "a", "Z", " ", "\t", "é", "e\u{301}", "界", "한", "🙂", "👩‍👩‍👧", "🇺🇸", "\r\n", "ｱ", "𠀀", "x\u{20DD}",
    ]

    @Test("clip matches the rebuilding reference across offsets, widths, and span boundaries")
    func clipMatchesReferenceCorpus() {
        var mismatches: [String] = []
        for text in Self.texts {
            let width = Self.referenceDisplayWidth(text)
            for spans in Self.spanSets(displayWidth: width) {
                let row = Self.row(text: text, spans: spans)
                for scrollLeft in Self.scrollOffsets(displayWidth: width) {
                    for viewportCols in Self.viewportWidths(text: text, displayWidth: width) {
                        let expected = Self.referenceClip(row: row, scrollLeft: scrollLeft, viewportCols: viewportCols).row
                        let actual = ResidentRenderPreparation.clip(row: row, scrollLeft: scrollLeft, viewportCols: viewportCols)
                        if actual != expected, mismatches.count < 8 {
                            mismatches.append("\(text.debugDescription) spans=\(spans.map { ($0.startCol, $0.endCol) }) left=\(scrollLeft) cols=\(viewportCols)")
                        }
                    }
                }
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches)")
    }

    @Test("prepared commands keep reference rows and composed UTF-16 bounds")
    func prepareMatchesReferenceCommands() throws {
        var mismatches: [String] = []
        for spanCase in 0..<Self.spanSets(displayWidth: 1).count {
            let rows = Self.texts.enumerated().map { line, text in
                Self.row(text: text, spans: Self.spanSets(displayWidth: Self.referenceDisplayWidth(text))[spanCase], line: line)
            }
            let content = try GUIWindowContent(
                windowId: 1, fullRefresh: true, cursorRow: 0, cursorCol: 0, cursorShape: .block,
                rows: rows, selection: nil, searchMatches: [], diagnosticUnderlines: [], documentHighlights: []
            )
            for scrollLeft in [-3, 0, 1, 2, 5] {
                for viewportCols in [-1, 0, 1, 2, 3, 4, 7, 80] {
                    let prepared = ResidentRenderPreparation.prepare(
                        content: content, fallbackVisibleRows: rows.count, overscanRows: 0,
                        scrollLeft: scrollLeft, viewportCols: viewportCols
                    )
                    #expect(prepared.commands.count == rows.count)
                    for (command, source) in zip(prepared.commands, rows) {
                        let expected = Self.referenceClip(row: source, scrollLeft: max(scrollLeft, 0), viewportCols: max(viewportCols, 0))
                        let matches = command.row == expected.row
                            && command.composedUTF16Start == expected.startUTF16
                            && command.composedUTF16End == expected.startUTF16 + expected.row.text.utf16.count
                            && command.gutterBufferLine == source.bufLine
                        if !matches, mismatches.count < 8 {
                            mismatches.append("\(source.text.debugDescription) span=\(spanCase) left=\(scrollLeft) cols=\(viewportCols)")
                        }
                    }
                }
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches)")
    }

    @Test("random rows clip identically to the rebuilding reference")
    func randomRowsMatchReference() {
        var random = SplitMix64(seed: 0x5EED_C11F)
        var mismatches: [String] = []
        for _ in 0..<4_000 {
            let text = (0..<random.next(below: 14)).map { _ in Self.graphemes[random.next(below: Self.graphemes.count)] }.joined()
            let width = Self.referenceDisplayWidth(text)
            let spans = (0..<random.next(below: 5)).map { _ in
                Self.span(UInt16(random.next(below: width + 4)), UInt16(random.next(below: width + 4)))
            }
            let row = Self.row(text: text, spans: spans)
            let scrollLeft = random.next(below: width + 6) - 3
            // Bias widths toward the UTF-8 fit bound where reuse and rebuild meet.
            let viewportCols = random.next(below: 2) == 0
                ? random.next(below: width + 6) - 2
                : text.utf8.count + random.next(below: 3) - 1
            let expected = Self.referenceClip(row: row, scrollLeft: scrollLeft, viewportCols: viewportCols).row
            if ResidentRenderPreparation.clip(row: row, scrollLeft: scrollLeft, viewportCols: viewportCols) != expected,
               mismatches.count < 8 {
                mismatches.append("\(text.debugDescription) spans=\(spans.map { ($0.startCol, $0.endCol) }) left=\(scrollLeft) cols=\(viewportCols)")
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches)")
    }

    @Test("retained rows keep content while dropped, overflowing, and scrolled spans are normalized")
    func retainedAndNormalizedRows() {
        let plain = Self.row(text: "a界👩‍👩‍👧\r\n", spans: [])
        #expect(ResidentRenderPreparation.clip(row: plain, scrollLeft: 0, viewportCols: plain.text.utf8.count) == plain)
        #expect(ResidentRenderPreparation.clip(row: plain, scrollLeft: -4, viewportCols: 5) == plain)
        #expect(ResidentRenderPreparation.clip(row: plain, scrollLeft: 0, viewportCols: 2).text == "a")

        let styled = Self.row(text: "let x", spans: [Self.span(0, 3), Self.span(4, 5)])
        #expect(ResidentRenderPreparation.clip(row: styled, scrollLeft: 0, viewportCols: 5) == styled)

        let overflowing = ResidentRenderPreparation.clip(
            row: Self.row(text: "let x", spans: [Self.span(0, 3), Self.span(4, 9), Self.span(2, 2), Self.span(4, 1)]),
            scrollLeft: 0, viewportCols: 80
        )
        #expect(overflowing.text == "let x")
        #expect(overflowing.spans.map { [$0.startCol, $0.endCol] } == [[0, 3], [4, 5]])

        let scrolled = ResidentRenderPreparation.clip(row: styled, scrollLeft: 1, viewportCols: 80)
        #expect(scrolled.text == "et x")
        #expect(scrolled == Self.referenceClip(row: styled, scrollLeft: 1, viewportCols: 80).row)
        #expect(scrolled.spans.map { [$0.startCol, $0.endCol] } == [[0, 2], [3, 4]])
    }

    // MARK: - Reference

    /// Rebuilding clip semantics: every non-empty row is re-sliced, re-spanned, and re-hashed.
    private static func referenceClip(row: GUIVisualRow, scrollLeft: Int, viewportCols: Int) -> (row: GUIVisualRow, startUTF16: Int) {
        let text = row.text
        guard !text.isEmpty else { return (row, 0) }
        let clipStart = max(scrollLeft, 0)
        let clipLimit = clipStart + max(viewportCols, 0)
        var column = 0
        var index = text.startIndex
        var start = text.endIndex
        var end = text.endIndex
        while index < text.endIndex {
            if column >= clipLimit {
                end = index
                break
            }
            let nextColumn = column + referenceWidth(text[index])
            if column <= clipStart && clipStart < nextColumn { start = index }
            if clipLimit < nextColumn {
                end = index
                column = clipLimit
                break
            }
            column = nextColumn
            index = text.index(after: index)
        }
        let clipEnd = min(clipLimit, column)
        guard clipStart < clipEnd else {
            return (referenceRebuilt(row, text: "", spans: [], scrollLeft: scrollLeft), text.utf16.count)
        }
        let spans = row.spans.compactMap { span -> GUIHighlightSpan? in
            let start = Int(span.startCol)
            let end = Int(span.endCol)
            guard end > clipStart, start < clipEnd else { return nil }
            let newStart = UInt16(clamping: max(start - clipStart, 0))
            let newEnd = UInt16(clamping: min(end - clipStart, clipEnd - clipStart))
            guard newStart < newEnd else { return nil }
            return GUIHighlightSpan(startCol: newStart, endCol: newEnd, fg: span.fg, bg: span.bg,
                                    attrs: span.attrs, fontWeight: span.fontWeight, fontId: span.fontId)
        }
        return (referenceRebuilt(row, text: String(text[start..<end]), spans: spans, scrollLeft: scrollLeft),
                start.utf16Offset(in: text))
    }

    private static func referenceRebuilt(_ row: GUIVisualRow, text: String, spans: [GUIHighlightSpan], scrollLeft: Int) -> GUIVisualRow {
        var hasher = Hasher()
        hasher.combine(row.contentHash)
        hasher.combine(scrollLeft)
        let hash = scrollLeft > 0 ? UInt32(truncatingIfNeeded: hasher.finalize()) : row.contentHash
        return GUIVisualRow(rowType: row.rowType, rowId: row.rowId, bufLine: row.bufLine,
                            contentHash: hash, text: text, spans: spans)
    }

    private static func referenceWidth(_ character: Character) -> Int {
        guard let value = character.unicodeScalars.first?.value else { return 1 }
        if (value >= 0x1100 && value <= 0x115F) || (value >= 0x2E80 && value <= 0x303E)
            || (value >= 0x3040 && value <= 0x33BF) || (value >= 0x3400 && value <= 0x4DBF)
            || (value >= 0x4E00 && value <= 0xA4CF) || (value >= 0xAC00 && value <= 0xD7AF)
            || (value >= 0xF900 && value <= 0xFAFF) || (value >= 0xFE30 && value <= 0xFE6F)
            || (value >= 0xFF01 && value <= 0xFF60) || (value >= 0xFFE0 && value <= 0xFFE6)
            || (value >= 0x20000 && value <= 0x2FA1F) { return 2 }
        return 1
    }

    private static func referenceDisplayWidth(_ text: String) -> Int {
        text.reduce(0) { $0 + referenceWidth($1) }
    }

    // MARK: - Fixtures

    private static func spanSets(displayWidth width: Int) -> [[GUIHighlightSpan]] {
        let end = UInt16(width)
        return [
            [],
            [span(0, end)],
            [span(0, 1), span(1, end)],
            [span(1, 2)],
            [span(0, end + 1)],
            [span(0, UInt16.max)],
            [span(end, end + 2)],
            [span(1, 1)],
            [span(3, 1)],
            [span(0, end), span(2, 2)],
        ]
    }

    private static func scrollOffsets(displayWidth width: Int) -> [Int] {
        [-5, -1, 0, 1, 2, 3, width - 1, width, width + 1, 100]
    }

    private static func viewportWidths(text: String, displayWidth width: Int) -> [Int] {
        let bytes = text.utf8.count
        return [-2, 0, 1, 2, 3, width - 1, width, width + 1, bytes - 1, bytes, bytes + 1, 80, Int(UInt16.max)]
    }

    private static func row(text: String, spans: [GUIHighlightSpan], line: Int = 3) -> GUIVisualRow {
        GUIVisualRow(rowType: .normal, rowId: UInt64(line + 1), bufLine: UInt32(line),
                     contentHash: 0xC0FFEE &+ UInt32(line), text: text, spans: spans)
    }

    private static func span(_ start: UInt16, _ end: UInt16) -> GUIHighlightSpan {
        GUIHighlightSpan(startCol: start, endCol: end, fg: 0x112233, bg: 0x445566, attrs: 0x05, fontWeight: 3, fontId: 1)
    }
}

/// Deterministic generator so random parity failures reproduce.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next(below bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return Int(value % UInt64(max(bound, 1)))
    }
}
