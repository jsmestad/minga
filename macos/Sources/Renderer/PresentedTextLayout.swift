import Foundation
import MingaUI
import CoreText

/// Immutable native geometry captured by a successful Metal presentation.
/// Coordinates are view points after the captured local scroll transform.
@MainActor
final class PresentedTextLayout {
    struct Row {
        let rowIndex: UInt32
        let rowID: UInt64
        let presentationRow: Int
        let composedUTF16Start: Int
        let composedUTF16End: Int
        let line: CTLine
        let origin: CGPoint
        let rect: CGRect

        func x(at utf16: UInt32) -> CGFloat {
            let offset = min(max(Int(utf16) - composedUTF16Start, 0), CTLineGetStringRange(line).length)
            return origin.x + CTLineGetOffsetForStringIndex(line, offset, nil)
        }

        func utf16(at x: CGFloat) -> UInt32 {
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            let localX = x - origin.x
            let index: Int
            if localX <= 0 {
                index = 0
            } else if localX >= width {
                index = CTLineGetStringRange(line).length
            } else {
                let hit = CTLineGetStringIndexForPosition(line, CGPoint(x: localX, y: 0))
                index = hit == kCFNotFound ? CTLineGetStringRange(line).length : hit
            }
            return UInt32(clamping: min(composedUTF16Start + index, composedUTF16End))
        }
    }

    struct Pane {
        let windowID: UInt16
        let presentationID: UInt64
        let rect: CGRect
        let scrollOffset: CGPoint
        let rows: [Row]
    }

    struct Hit {
        let target: EditorTextTarget
        let scrollX: Int8
        let scrollY: Int8
    }

    let panes: [Pane]

    init(panes: [Pane]) { self.panes = panes }

    func hit(at point: CGPoint, capturedWindowID: UInt16? = nil) -> Hit? {
        let pane: Pane?
        if let capturedWindowID {
            pane = panes.first { $0.windowID == capturedWindowID }
        } else {
            pane = panes.first { $0.rect.contains(point) }
        }
        guard let pane, !pane.rows.isEmpty else { return nil }
        let x = min(max(point.x, pane.rect.minX), pane.rect.maxX.nextDown)
        let y = min(max(point.y, pane.rect.minY), pane.rect.maxY.nextDown)
        let row = pane.rows.first { y >= $0.rect.minY && y < $0.rect.maxY }
            ?? (y < pane.rows[0].rect.minY ? pane.rows[0] : pane.rows[pane.rows.count - 1])
        return Hit(
            target: EditorTextTarget(windowID: pane.windowID, presentationID: pane.presentationID, rowIndex: row.rowIndex, rowID: row.rowID, utf16Offset: row.utf16(at: x)),
            scrollX: point.x < pane.rect.minX ? -1 : (point.x >= pane.rect.maxX ? 1 : 0),
            scrollY: point.y < pane.rect.minY ? -1 : (point.y >= pane.rect.maxY ? 1 : 0)
        )
    }

    func cursor(windowID: UInt16, row: UInt16, utf16: UInt32) -> CGPoint? {
        guard let pane = panes.first(where: { $0.windowID == windowID }),
              let row = pane.rows.first(where: { $0.presentationRow == Int(row) }) else { return nil }
        // The cursor pass applies the captured scroll offset after cursor animation.
        return CGPoint(x: row.x(at: utf16) + pane.scrollOffset.x, y: row.rect.minY + pane.scrollOffset.y)
    }
}
