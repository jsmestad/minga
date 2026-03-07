/// In-memory cell grid representing the editor's screen state.
///
/// Each cell holds a Unicode grapheme cluster, foreground/background colors,
/// and text attributes. The grid is updated by the CommandDispatcher as
/// render commands arrive from the BEAM, then read by MetalRenderer to
/// build GPU cell data each frame.

import Foundation

/// A single cell in the grid.
struct Cell {
    /// The character to display (a Unicode grapheme cluster, or empty for blank).
    var grapheme: String = ""
    /// Display width in cells (1 for normal, 2 for wide/CJK).
    var width: UInt8 = 1
    /// Foreground color as 24-bit RGB (0 = default).
    var fg: UInt32 = 0
    /// Background color as 24-bit RGB (0 = default).
    var bg: UInt32 = 0
    /// Text attributes bitmask (bold, italic, underline, reverse).
    var attrs: UInt8 = 0
}

/// The cell grid with cursor state. Not thread-safe; all access should
/// happen on the main thread (the protocol reader dispatches to main).
final class CellGrid {
    private(set) var cells: [Cell]
    private(set) var cols: UInt16
    private(set) var rows: UInt16

    var cursorCol: UInt16 = 0
    var cursorRow: UInt16 = 0
    var cursorShape: CursorShape = .block
    var cursorVisible: Bool = true

    /// Track whether the grid was modified since last render.
    var dirty: Bool = true

    init(cols: UInt16, rows: UInt16) {
        self.cols = cols
        self.rows = rows
        self.cells = Array(repeating: Cell(), count: Int(cols) * Int(rows))
    }

    /// Clear all cells to blank.
    func clear() {
        for i in cells.indices {
            cells[i] = Cell()
        }
        dirty = true
    }

    /// Write a cell at the given grid position. Out-of-bounds writes are ignored.
    func writeCell(col: UInt16, row: UInt16, cell: Cell) {
        guard col < cols, row < rows else { return }
        let idx = Int(row) * Int(cols) + Int(col)
        cells[idx] = cell
        dirty = true
    }

    /// Update cursor position.
    func showCursor(col: UInt16, row: UInt16) {
        cursorCol = col
        cursorRow = row
        dirty = true
    }

    /// Resize the grid. Allocates a new cell array and resets all cells to blank.
    func resize(newCols: UInt16, newRows: UInt16) {
        guard newCols != cols || newRows != rows else { return }
        guard newCols > 0, newRows > 0 else { return }
        cols = newCols
        rows = newRows
        cells = Array(repeating: Cell(), count: Int(newCols) * Int(newRows))
        dirty = true
    }

    /// Clear all cells within a rectangular region.
    func clearRect(col: UInt16, row: UInt16, width: UInt16, height: UInt16) {
        let rowEnd = min(row &+ height, rows)
        let colEnd = min(col &+ width, cols)
        var r = row
        while r < rowEnd {
            var c = col
            while c < colEnd {
                let idx = Int(r) * Int(cols) + Int(c)
                cells[idx] = Cell(grapheme: " ", width: 1)
                c &+= 1
            }
            r &+= 1
        }
        dirty = true
    }
}
