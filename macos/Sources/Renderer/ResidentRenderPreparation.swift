import Foundation

/// Rasterization-independent command for one row consumed by the CoreText renderer.
/// It contains the viewport-clipped text/styles and the gutter source line needed
/// before any atlas lookup or Metal buffer allocation occurs.
public struct ResidentPreparedRowCommand: Sendable, Equatable {
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
    public let visibleStartIndex: Int
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
        scrollLeft: Int = 0,
        viewportCols: Int = Int(UInt16.max)
    ) -> ResidentRenderPreparationResult {
        let store = content.rowStore
        let visibleStart: Int
        let visibleEnd: Int

        if let presentation = content.scrollPresentation {
            let indexedStart = store.lowerBound(bufferLine: presentation.visibleStartLine)
            let anchorStart = store.lowerBound(bufferLine: presentation.anchorTop)
            let anchoredVisualStart = min(anchorStart + Int(presentation.anchorVisualRowOffset), store.count)
            visibleStart = anchoredVisualStart < store.count ? anchoredVisualStart : min(indexedStart, store.count)
            let indexedEnd = store.lowerBound(bufferLine: presentation.visibleEndLine)
            visibleEnd = max(indexedEnd, min(visibleStart + fallbackVisibleRows, store.count))
        } else {
            visibleStart = 0
            visibleEnd = min(fallbackVisibleRows, store.count)
        }

        let overscan = max(overscanRows, 0)
        let lower = max(visibleStart - overscan, 0)
        let upper = min(max(visibleEnd, visibleStart) + overscan, store.count)
        let result = store.rows(in: lower..<upper)
        let clipStart = max(scrollLeft, 0)
        let clipWidth = max(viewportCols, 0)
        let commands = result.rows.enumerated().map { index, row in
            ResidentPreparedRowCommand(
                displayRow: UInt16(clamping: index),
                presentationRow: index - (visibleStart - lower),
                gutterBufferLine: row.bufLine,
                row: clip(row: row, scrollLeft: clipStart, viewportCols: clipWidth)
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
        let text = row.text
        guard !text.isEmpty else { return row }
        let columnMap = displayColumnMap(for: text)
        let totalColumns = max(columnMap.count - 1, 0)
        let clipStart = min(max(scrollLeft, 0), totalColumns)
        let clipEnd = min(clipStart + max(viewportCols, 0), totalColumns)
        guard clipStart < clipEnd else {
            return rebuilt(row, text: "", spans: [], scrollLeft: scrollLeft)
        }
        let clippedText = String(text[columnMap[clipStart]..<columnMap[clipEnd]])
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
        return rebuilt(row, text: clippedText, spans: clippedSpans, scrollLeft: scrollLeft)
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

    private static func displayColumnMap(for text: String) -> [String.Index] {
        var map: [String.Index] = []
        map.reserveCapacity(text.count + text.count / 4)
        for index in text.indices {
            map.append(index)
            if displayColumnWidth(text[index]) == 2 { map.append(index) }
        }
        map.append(text.endIndex)
        return map
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
