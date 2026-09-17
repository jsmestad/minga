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
    let selectedRanges: [NSRange]
    let hasSelection: Bool
    let insertionRange: NSRange?
    let insertionPointLineNumber: Int?
    let isActivePane: Bool
    let rowsVisited: Int
    let utf16UnitsVisited: Int

    var selectedText: String? {
        guard !selectedRanges.isEmpty else { return nil }
        let string = value as NSString
        return selectedRanges.map { string.substring(with: $0) }.joined(separator: "\n")
    }

    func localRect(for range: NSRange) -> CGRect? {
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
        cellHeight: CGFloat
    ) -> EditorAccessibilityProjection {
        let content = surface.content
        let geometry = surface.paneGeometry
        let paneFrame = CGRect(
            x: CGFloat(geometry.textRect.col) * cellWidth,
            y: CGFloat(geometry.textRect.row) * cellHeight,
            width: CGFloat(geometry.textRect.width) * cellWidth,
            height: CGFloat(geometry.textRect.height) * cellHeight
        )
        let offset = localTransform?.windowId == surface.windowId ? localTransform?.offset ?? .zero : .zero
        let baseRange = surface.visibleRowRange
        let extraRows = Int(ceil(abs(offset.y) / max(cellHeight, 1))) + 1
        let candidateRange = max(0, baseRange.lowerBound - extraRows)..<min(content.rowStore.count, baseRange.upperBound + extraRows)
        let resident = content.rowStore.rows(in: candidateRange)
        let textOriginX = paneFrame.minX - CGFloat(content.scrollLeft) * cellWidth - offset.x
        let clipStart = Int(floor((paneFrame.minX - textOriginX) / max(cellWidth, 1)))
        let clipEnd = Int(ceil((paneFrame.maxX - textOriginX) / max(cellWidth, 1)))

        struct PendingRow {
            let viewportRow: Int
            let text: String
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
            let y = paneFrame.minY + CGFloat(viewportRow) * cellHeight - offset.y
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
                viewportRow: viewportRow,
                text: text,
                sourceDisplayRange: sourceStart..<sourceEnd,
                sourceMap: map,
                exposedUTF16Range: exposedUTF16,
                localOrigin: CGPoint(x: textOriginX + CGFloat(sourceStart) * cellWidth, y: y)
            ))
        }

        var valueParts: [String] = []
        valueParts.reserveCapacity(pending.count)
        var rows: [Row] = []
        rows.reserveCapacity(pending.count)
        var valueOffset = 0
        for (index, row) in pending.enumerated() {
            valueParts.append(row.text)
            let length = row.text.utf16.count
            rows.append(Row(
                viewportRow: row.viewportRow,
                valueRange: NSRange(location: valueOffset, length: length),
                sourceDisplayRange: row.sourceDisplayRange,
                sourceMap: row.sourceMap,
                exposedUTF16Range: row.exposedUTF16Range,
                localOrigin: row.localOrigin,
                cellWidth: cellWidth,
                cellHeight: cellHeight
            ))
            valueOffset += length + (index == pending.count - 1 ? 0 : 1)
        }

        let value = valueParts.joined(separator: "\n")
        let selectedRanges = selectionRanges(content: content, rows: rows)
        let insertion = content.selection == nil ? insertionRange(content: content, rows: rows) : nil
        let insertionLine = insertion.flatMap { insertion in
            rows.firstIndex { NSLocationInRange(insertion.location, $0.valueRange) || insertion.location == NSMaxRange($0.valueRange) }
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
            selectedRanges: selectedRanges,
            hasSelection: content.selection != nil,
            insertionRange: insertion,
            insertionPointLineNumber: insertionLine,
            isActivePane: isActivePane,
            rowsVisited: resident.counters.rowsVisited,
            utf16UnitsVisited: pending.reduce(into: 0) { $0 += $1.sourceMap.utf16UnitsVisited }
        )
    }

    private static func insertionRange(content: GUIWindowContent, rows: [Row]) -> NSRange? {
        guard content.cursorVisible,
              let cursor = content.accessibilityCursor,
              let row = rows.first(where: { $0.viewportRow == Int(cursor.row) }) else { return nil }
        return row.insertionRange(atSourceUTF16Offset: Int(cursor.utf16))
    }

    private static func selectionRanges(content: GUIWindowContent, rows: [Row]) -> [NSRange] {
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

        for selected in ranges {
            if let previous = groups.last,
               let previousViewportRow,
               selected.row.viewportRow == previousViewportRow + 1,
               selected.range.location == NSMaxRange(previous) + 1 {
                groups[groups.count - 1] = NSRange(
                    location: previous.location,
                    length: NSMaxRange(selected.range) - previous.location
                )
            } else {
                groups.append(selected.range)
            }
            previousViewportRow = selected.row.viewportRow
        }

        return groups
    }
}
