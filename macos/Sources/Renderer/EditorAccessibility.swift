import Foundation
import MingaProtocol

/// Stable identity for one accessible pane during one core and buffer lifetime.
struct EditorAccessibilityIdentity: Hashable, Sendable {
    let connectionID: UInt64
    let windowID: UInt16
    let generation: UInt64
}

/// One immutable accessibility projection derived from the visible presentation.
struct EditorAccessibilityProjection: Sendable {
    struct Row: Sendable {
        let absoluteRow: Int
        let viewportRow: Int
        let valueRange: NSRange
        let sourceDisplayRange: Range<Int>
        let sourceMap: GUIDisplayColumnMap
        let exposedUTF16Range: Range<Int>
        let localOrigin: CGPoint
        let cellWidth: CGFloat
        let cellHeight: CGFloat

        func valueRange(forSourceUTF16Range sourceRange: Range<Int>) -> NSRange? {
            let lower = max(sourceRange.lowerBound, exposedUTF16Range.lowerBound)
            let upper = min(sourceRange.upperBound, exposedUTF16Range.upperBound)
            guard lower < upper else { return nil }
            return NSRange(
                location: valueRange.location + lower - exposedUTF16Range.lowerBound,
                length: upper - lower
            )
        }

        func insertionRange(atSourceUTF16Offset sourceOffset: Int) -> NSRange? {
            guard sourceOffset >= exposedUTF16Range.lowerBound,
                  sourceOffset <= exposedUTF16Range.upperBound else { return nil }
            return NSRange(
                location: valueRange.location + sourceOffset - exposedUTF16Range.lowerBound,
                length: 0
            )
        }

        func localRect(forValueRange range: NSRange) -> CGRect? {
            let intersection: NSRange
            if range.length == 0,
               range.location >= valueRange.location,
               range.location <= NSMaxRange(valueRange) {
                intersection = range
            } else {
                intersection = NSIntersectionRange(valueRange, range)
            }
            guard intersection.location != NSNotFound,
                  range.length == 0 || intersection.length > 0 else { return nil }
            let localStart = intersection.location - valueRange.location
            let localEnd = localStart + intersection.length
            let sourceStart = sourceMap.displayColumn(atUTF16Offset: exposedUTF16Range.lowerBound + localStart)
            let sourceEnd = sourceMap.displayColumn(atUTF16Offset: exposedUTF16Range.lowerBound + localEnd)
            let x = localOrigin.x + CGFloat(sourceStart - sourceDisplayRange.lowerBound) * cellWidth
            let width = max(CGFloat(sourceEnd - sourceStart) * cellWidth, cellWidth)
            return CGRect(x: x, y: localOrigin.y, width: width, height: cellHeight)
        }
    }

    let identity: EditorAccessibilityIdentity
    let label: String
    let value: String
    let frameInView: CGRect
    let rows: [Row]
    let lineRanges: [NSRange]
    let selectedRanges: [NSRange]
    let hasSelection: Bool
    let insertionRange: NSRange?
    let insertionPointLineNumber: Int?
    let insertionViewportRow: Int?
    let isActivePane: Bool
    let rowsVisited: Int
    let utf16UnitsVisited: Int

    var selectedText: String? {
        guard !selectedRanges.isEmpty else { return nil }
        let string = value as NSString
        var text = ""
        text.reserveCapacity(selectedRanges.reduce(0) { $0 + $1.length + 1 })
        var previousEnd: Int?
        for range in selectedRanges {
            if let previousEnd,
               logicalLine(atUTF16Offset: previousEnd) != logicalLine(atUTF16Offset: range.location) {
                text.append("\n")
            }
            text.append(string.substring(with: range))
            previousEnd = NSMaxRange(range)
        }
        return text
    }

    /// AX text offsets count actual source newlines, not visual wrap boundaries.
    func logicalLine(atUTF16Offset offset: Int) -> Int? {
        guard offset >= 0, let last = lineRanges.last, offset <= NSMaxRange(last) else { return nil }
        return lineRanges.firstIndex { offset >= $0.location && offset <= NSMaxRange($0) }
    }

    func localRect(for range: NSRange) -> CGRect? {
        if range.length == 0 {
            let row: Row?
            if let insertionViewportRow, range == insertionRange {
                row = rows.first { $0.viewportRow == insertionViewportRow }
            } else {
                row = rows.first { range.location >= $0.valueRange.location && range.location < NSMaxRange($0.valueRange) }
                    ?? rows.last { range.location == NSMaxRange($0.valueRange) }
            }
            guard let rect = row?.localRect(forValueRange: range)?.intersection(frameInView), !rect.isNull else { return nil }
            return rect
        }
        let rects = rows.compactMap { $0.localRect(forValueRange: range) }
        guard let first = rects.first else { return nil }
        let clipped = rects.dropFirst().reduce(first) { $0.union($1) }.intersection(frameInView)
        return clipped.isNull ? nil : clipped
    }

    static func build(
        surface: PresentedWindowSurface,
        connectionID: UInt64,
        isActivePane: Bool,
        localTransform: EditorLocalPresentationTransform?,
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        promptTransform: AgentPromptPresentationTransform? = nil
    ) -> EditorAccessibilityProjection {
        let content = surface.content
        let geometry = surface.paneGeometry
        let sourceFrame = CGRect(
            x: CGFloat(geometry.textRect.col) * cellWidth,
            y: CGFloat(geometry.textRect.row) * cellHeight,
            width: CGFloat(geometry.textRect.width) * cellWidth,
            height: CGFloat(geometry.textRect.height) * cellHeight
        )
        let offset = localTransform?.windowId == surface.windowId ? localTransform?.offset ?? .zero : .zero
        let baseRange = surface.visibleRowRange
        let paneFrame = promptTransform.map { $0.rect(sourceFrame) } ?? sourceFrame
        let rowOffset = offset.y / max(cellHeight, 1)
        let localLower = Int(floor(CGFloat(baseRange.lowerBound) + rowOffset))
        let localUpper = Int(ceil(CGFloat(baseRange.upperBound) + rowOffset))
        let candidateLower = min(max(0, localLower - 1), content.rowStore.count)
        let candidateUpper = min(max(localUpper + 1, candidateLower), content.rowStore.count)
        let candidateRange = candidateLower..<candidateUpper
        let resident = content.rowStore.rows(in: candidateRange)
        let textOriginX = sourceFrame.minX + (promptTransform?.offset.x ?? 0) - CGFloat(content.scrollLeft) * cellWidth - offset.x
        let clipStart = Int(floor((paneFrame.minX - textOriginX) / max(cellWidth, 1)))
        let clipEnd = Int(ceil((paneFrame.maxX - textOriginX) / max(cellWidth, 1)))
        struct PendingRow {
            let absoluteRow: Int
            let viewportRow: Int
            let text: String
            let bufferLine: UInt32
            let isSourceText: Bool
            let sourceDisplayRange: Range<Int>
            let sourceMap: GUIDisplayColumnMap
            let exposedUTF16Range: Range<Int>
            let localOrigin: CGPoint
        }

        var pending: [PendingRow] = []
        pending.reserveCapacity(Int(geometry.viewport.rows))
        for (offsetIndex, row) in resident.rows.enumerated() {
            let residentIndex = candidateRange.lowerBound + offsetIndex
            let viewportRow = residentIndex - baseRange.lowerBound
            let y = sourceFrame.minY + (promptTransform?.offset.y ?? 0) + CGFloat(viewportRow) * cellHeight - offset.y
            guard y < paneFrame.maxY, y + cellHeight > paneFrame.minY else { continue }
            let map = GUIDisplayColumnMap(row.text, limitedTo: max(clipStart, 0)..<max(clipEnd, 0))
            let exposedLower = min(max(clipStart, 0), map.displayWidth)
            let exposedUpper = min(max(clipEnd, exposedLower), map.displayWidth)
            let exposedColumns = exposedLower..<exposedUpper
            let exposedUTF16 = map.utf16Range(intersecting: exposedColumns) ?? 0..<0
            let text = (row.text as NSString).substring(with: NSRange(location: exposedUTF16.lowerBound, length: exposedUTF16.count))
            let sourceStart = map.displayColumn(atUTF16Offset: exposedUTF16.lowerBound)
            let sourceEnd = map.displayColumn(atUTF16Offset: exposedUTF16.upperBound)
            pending.append(PendingRow(
                absoluteRow: residentIndex,
                viewportRow: viewportRow,
                text: text,
                bufferLine: row.bufLine,
                isSourceText: row.rowType == .normal || row.rowType == .wrapContinuation,
                sourceDisplayRange: sourceStart..<sourceEnd,
                sourceMap: map,
                exposedUTF16Range: exposedUTF16,
                localOrigin: CGPoint(x: textOriginX + CGFloat(sourceStart) * cellWidth, y: y)
            ))
        }

        var valueParts: [String] = []
        valueParts.reserveCapacity(pending.count * 2)
        var rows: [Row] = []
        rows.reserveCapacity(pending.count)
        var valueOffset = 0
        var lineRanges: [NSRange] = []
        lineRanges.reserveCapacity(pending.count)
        var logicalLineStart = 0
        for (index, row) in pending.enumerated() {
            if index > 0 {
                let previous = pending[index - 1]
                let continuesSourceLine = previous.isSourceText && row.isSourceText && previous.bufferLine == row.bufferLine
                if !continuesSourceLine {
                    lineRanges.append(NSRange(location: logicalLineStart, length: valueOffset - logicalLineStart))
                    valueParts.append("\n")
                    valueOffset += 1
                    logicalLineStart = valueOffset
                }
            }
            valueParts.append(row.text)
            let length = row.text.utf16.count
            rows.append(Row(
                absoluteRow: row.absoluteRow,
                viewportRow: row.viewportRow,
                valueRange: NSRange(location: valueOffset, length: length),
                sourceDisplayRange: row.sourceDisplayRange,
                sourceMap: row.sourceMap,
                exposedUTF16Range: row.exposedUTF16Range,
                localOrigin: row.localOrigin,
                cellWidth: cellWidth,
                cellHeight: cellHeight
            ))
            valueOffset += length
        }
        if !pending.isEmpty {
            lineRanges.append(NSRange(location: logicalLineStart, length: valueOffset - logicalLineStart))
        }

        let value = valueParts.joined()
        let selectedRanges = selectionRanges(surface: surface, rows: rows)
        let hasSelection = surface.residentSemantics?.selection != nil || content.selection != nil
        let insertion = hasSelection ? nil : insertionPoint(surface: surface, rows: rows)
        let insertionLine = insertion.flatMap { insertion in
            lineRanges.firstIndex { insertion.range.location >= $0.location && insertion.range.location <= NSMaxRange($0) }
        }
        let label = content.accessibilityLabel.isEmpty
            ? "Editor pane \(surface.windowId)"
            : "\(content.accessibilityLabel), pane \(surface.windowId)"
        return EditorAccessibilityProjection(
            identity: EditorAccessibilityIdentity(connectionID: connectionID, windowID: surface.windowId, generation: content.accessibilityGeneration),
            label: label,
            value: value,
            frameInView: paneFrame,
            rows: rows,
            lineRanges: lineRanges,
            selectedRanges: selectedRanges,
            hasSelection: hasSelection,
            insertionRange: insertion?.range,
            insertionPointLineNumber: insertionLine,
            insertionViewportRow: insertion?.viewportRow,
            isActivePane: isActivePane,
            rowsVisited: resident.counters.rowsVisited,
            utf16UnitsVisited: pending.reduce(into: 0) { $0 += $1.sourceMap.utf16UnitsVisited }
        )
    }

    private static func insertionPoint(surface: PresentedWindowSurface, rows: [Row]) -> (range: NSRange, viewportRow: Int)? {
        let content = surface.content
        if let semantics = surface.residentSemantics {
            guard semantics.cursor.eligible,
                  let row = rows.first(where: { $0.absoluteRow == Int(semantics.cursor.row) }),
                  let range = row.insertionRange(atSourceUTF16Offset: row.sourceMap.utf16Offset(at: Int(semantics.cursor.col))) else { return nil }
            return (range, row.viewportRow)
        }
        guard content.cursorVisible,
              let cursor = content.accessibilityCursor,
              let row = rows.first(where: { $0.viewportRow == Int(cursor.row) }),
              let range = row.insertionRange(atSourceUTF16Offset: Int(cursor.utf16)) else { return nil }
        return (range, row.viewportRow)
    }

    private static func selectionRanges(surface: PresentedWindowSurface, rows: [Row]) -> [NSRange] {
        let content = surface.content
        if let selection = surface.residentSemantics?.selection {
            let ranges = rows.compactMap { row -> (row: Row, range: NSRange)? in
                guard row.absoluteRow >= Int(selection.startRow), row.absoluteRow <= Int(selection.endRow) else { return nil }
                let startColumn = selection.type == .line || row.absoluteRow > Int(selection.startRow) ? 0 : Int(selection.startCol)
                let endColumn = selection.type == .line || row.absoluteRow < Int(selection.endRow) ? row.sourceMap.displayWidth : Int(selection.endCol)
                guard let range = row.valueRange(forSourceUTF16Range: row.sourceMap.utf16Offset(at: startColumn)..<row.sourceMap.utf16Offset(at: endColumn)) else { return nil }
                return (row, range)
            }
            return contiguousRanges(ranges)
        }
        guard let selection = content.selection else { return [] }
        let ranges = content.accessibilitySelectionRanges.compactMap { sourceRange -> (row: Row, range: NSRange)? in
            guard let row = rows.first(where: { $0.viewportRow == Int(sourceRange.row) }) else { return nil }
            guard let range = row.valueRange(
                forSourceUTF16Range: Int(sourceRange.startUTF16)..<Int(sourceRange.endUTF16)
            ) else { return nil }
            return (row, range)
        }
        return selection.type == .block ? ranges.map(\.range) : contiguousRanges(ranges)
    }

    private static func contiguousRanges(_ ranges: [(row: Row, range: NSRange)]) -> [NSRange] {
        var groups: [NSRange] = []
        var previousViewportRow: Int?
        var previousRowEnd: Int?

        for selected in ranges {
            if let previous = groups.last,
               let previousViewportRow,
               selected.row.viewportRow == previousViewportRow + 1,
               NSMaxRange(previous) == previousRowEnd,
               selected.range.location == selected.row.valueRange.location,
               selected.range.location >= NSMaxRange(previous),
               selected.range.location <= NSMaxRange(previous) + 1 {
                groups[groups.count - 1] = NSRange(
                    location: previous.location,
                    length: NSMaxRange(selected.range) - previous.location
                )
            } else {
                groups.append(selected.range)
            }
            previousViewportRow = selected.row.viewportRow
            previousRowEnd = NSMaxRange(selected.row.valueRange)
        }

        return groups
    }
}
