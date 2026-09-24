import Foundation

/// Rasterization-independent command for one row consumed by the CoreText renderer.
/// It contains the viewport-clipped text/styles and the gutter source line needed
/// before any atlas lookup or Metal buffer allocation occurs.
public struct ResidentPreparedRowCommand: Sendable, Equatable {
    public let rowIndex: UInt32
    public let composedUTF16Start: Int
    public let composedUTF16End: Int
    public let displayRow: UInt16
    public let presentationRow: Int
    public let gutterBufferLine: UInt32
    public let row: GUIVisualRow
}

/// Production visible-range and CoreText command preparation shared by the
/// shipping renderer and optimized release harness.
public struct ResidentRenderPreparationResult: Sendable {
    public let range: Range<Int>
    public let rows: [GUIVisualRow]
    public let commands: [ResidentPreparedRowCommand]
    /// Index of the committed anchor; local scrolling changes the selected range, not this origin.
    public let visibleStartIndex: Int
    /// Signed distance from the selected range's start to the committed anchor, negative when the range starts below it.
    public let overscanBeforeRows: Int
    public let counters: ResidentRowStoreCounters
    public let decorationsVisited: Int
}

/// Metal-free portion of the shipping CoreText command-preparation path.
public enum ResidentRenderPreparation {
    public static func decorationCount(content: GUIWindowContent) -> Int {
        (content.selection == nil ? 0 : 1) + content.searchMatches.count +
            content.diagnosticUnderlines.count + content.documentHighlights.count +
            content.lineAnnotations.count
    }

    public static func prepare(
        content: GUIWindowContent,
        fallbackVisibleRows: Int,
        overscanRows: Int,
        localOffsetRows: Double = 0,
        scrollLeft: Int = 0,
        viewportCols: Int = Int(UInt16.max)
    ) -> ResidentRenderPreparationResult {
        let store = content.rowStore
        let visibleStart: Int

        if let presentation = content.scrollPresentation {
            let indexedStart = store.lowerBound(bufferLine: presentation.visibleStartLine)
            let anchorStart = store.lowerBound(bufferLine: presentation.anchorTop)
            let anchoredVisualStart = min(anchorStart + Int(presentation.anchorVisualRowOffset), store.count)
            visibleStart = anchoredVisualStart < store.count ? anchoredVisualStart : min(indexedStart, store.count)
        } else {
            visibleStart = 0
        }

        let overscan = max(overscanRows, 0)
        // Select the local viewport, but keep row coordinates relative to the committed anchor.
        // Fractional scrolling exposes one extra row. Work stays bounded regardless of travel distance.
        let localStart = Double(visibleStart) + localOffsetRows
        let lower = min(max(Int(floor(localStart)) - overscan, 0), store.count)
        let upper = min(max(Int(ceil(localStart + Double(fallbackVisibleRows))) + overscan, lower), store.count)
        let result = store.rows(in: lower..<upper)
        let clipStart = max(scrollLeft, 0)
        let clipWidth = max(viewportCols, 0)
        let commands = result.rows.enumerated().map { index, row in
            let slice = clipped(row: row, scrollLeft: clipStart, viewportCols: clipWidth)
            return ResidentPreparedRowCommand(
                rowIndex: UInt32(lower + index),
                composedUTF16Start: slice.startUTF16,
                composedUTF16End: slice.startUTF16 + slice.row.text.utf16.count,
                displayRow: UInt16(clamping: index),
                presentationRow: index - (visibleStart - lower),
                gutterBufferLine: row.bufLine,
                row: slice.row
            )
        }

        return ResidentRenderPreparationResult(
            range: lower..<upper,
            rows: result.rows,
            commands: commands,
            visibleStartIndex: visibleStart,
            overscanBeforeRows: visibleStart - lower,
            counters: result.counters,
            decorationsVisited: decorationCount(content: content)
        )
    }

    /// Shipping viewport clipping for CoreText rows and their style spans.
    public static func clip(row: GUIVisualRow, scrollLeft: Int, viewportCols: Int) -> GUIVisualRow {
        clipped(row: row, scrollLeft: scrollLeft, viewportCols: viewportCols).row
    }

    private static func clipped(row: GUIVisualRow, scrollLeft: Int, viewportCols: Int) -> (row: GUIVisualRow, startUTF16: Int) {
        let text = row.text
        guard !text.isEmpty else { return (row, 0) }
        let clipStart = max(scrollLeft, 0)
        let clipLimit = clipStart + max(viewportCols, 0)
        var column = 0
        var index = text.startIndex
        var start = text.endIndex
        var end = text.endIndex
        // Walk only as far as the viewport edge; retain the existing wide-character clipping semantics.
        while index < text.endIndex {
            if column >= clipLimit {
                end = index
                break
            }
            let nextColumn = column + displayColumnWidth(text[index])
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
            return (rebuilt(row, text: "", spans: [], scrollLeft: scrollLeft), text.utf16.count)
        }
        let clippedText = String(text[start..<end])
        let clippedSpans = row.spans.compactMap { span -> GUIHighlightSpan? in
            let start = Int(span.startCol)
            let end = Int(span.endCol)
            guard end > clipStart, start < clipEnd else { return nil }
            let newStart = UInt16(clamping: max(start - clipStart, 0))
            let newEnd = UInt16(clamping: min(end - clipStart, clipEnd - clipStart))
            guard newStart < newEnd else { return nil }
            return GUIHighlightSpan(startCol: newStart, endCol: newEnd, fg: span.fg, bg: span.bg,
                                    attrs: span.attrs, fontWeight: span.fontWeight, fontId: span.fontId)
        }
        return (rebuilt(row, text: clippedText, spans: clippedSpans, scrollLeft: scrollLeft), start.utf16Offset(in: text))
    }

    private static func rebuilt(_ row: GUIVisualRow, text: String,
                                spans: [GUIHighlightSpan], scrollLeft: Int) -> GUIVisualRow {
        var hasher = Hasher()
        hasher.combine(row.contentHash)
        hasher.combine(scrollLeft)
        let hash = scrollLeft > 0 ? UInt32(truncatingIfNeeded: hasher.finalize()) : row.contentHash
        return GUIVisualRow(rowType: row.rowType, rowId: row.rowId, bufLine: row.bufLine,
                            contentHash: hash, text: text, spans: spans)
    }

    private static func displayColumnWidth(_ character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 1 }
        let value = scalar.value
        if (value >= 0x1100 && value <= 0x115F) || (value >= 0x2E80 && value <= 0x303E)
            || (value >= 0x3040 && value <= 0x33BF) || (value >= 0x3400 && value <= 0x4DBF)
            || (value >= 0x4E00 && value <= 0xA4CF) || (value >= 0xAC00 && value <= 0xD7AF)
            || (value >= 0xF900 && value <= 0xFAFF) || (value >= 0xFE30 && value <= 0xFE6F)
            || (value >= 0xFF01 && value <= 0xFF60) || (value >= 0xFFE0 && value <= 0xFFE6)
            || (value >= 0x20000 && value <= 0x2FA1F) { return 2 }
        return 1
    }
}
