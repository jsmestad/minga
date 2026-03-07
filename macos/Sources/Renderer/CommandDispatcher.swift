/// Routes decoded protocol commands to the CellGrid and triggers rendering.
///
/// Handles region tracking (define/clear/destroy/set_active) with coordinate
/// offset and clipping, matching the Zig renderer.zig logic.

import Foundation
import AppKit

/// Tracks a defined region for coordinate offset/clipping.
struct Region {
    let id: UInt16
    let parentId: UInt16
    let role: UInt8
    let row: UInt16
    let col: UInt16
    let width: UInt16
    let height: UInt16
    let zOrder: UInt8
}

/// Dispatches render commands to a CellGrid and notifies when a frame is complete.
final class CommandDispatcher {
    let grid: CellGrid
    private var regions: [UInt16: Region] = [:]
    private var activeRegion: Region?

    /// Called after each `batch_end` command. The MetalRenderer hooks into
    /// this to trigger a GPU frame.
    var onFrameReady: (() -> Void)?

    /// Called when the window title should change.
    var onTitleChanged: ((String) -> Void)?

    /// Called when the BEAM sends a window background color.
    var onWindowBgChanged: ((NSColor) -> Void)?

    init(grid: CellGrid) {
        self.grid = grid
    }

    /// Process a single render command.
    func dispatch(_ command: RenderCommand) {
        switch command {
        case .clear:
            grid.clear()

        case .drawText(let row, let col, let fg, let bg, let attrs, let text):
            drawText(row: row, col: col, fg: fg, bg: bg, attrs: attrs, text: text)

        case .setCursor(let row, let col):
            var absRow = row
            var absCol = col
            if let region = activeRegion {
                absRow &+= region.row
                absCol &+= region.col
            }
            grid.showCursor(col: absCol, row: absRow)

        case .setCursorShape(let shape):
            grid.cursorShape = shape

        case .batchEnd:
            onFrameReady?()

        case .setTitle(let title):
            onTitleChanged?(title)

        case .setWindowBg(let r, let g, let b):
            let color = NSColor(
                red: CGFloat(r) / 255.0,
                green: CGFloat(g) / 255.0,
                blue: CGFloat(b) / 255.0,
                alpha: 1.0
            )
            onWindowBgChanged?(color)

        case .defineRegion(let id, let parentId, let role, let row, let col, let width, let height, let zOrder):
            let region = Region(id: id, parentId: parentId, role: role, row: row, col: col, width: width, height: height, zOrder: zOrder)
            regions[id] = region

        case .clearRegion(let id):
            if let region = regions[id] {
                grid.clearRect(col: region.col, row: region.row, width: region.width, height: region.height)
            }

        case .destroyRegion(let id):
            if let region = regions[id] {
                grid.clearRect(col: region.col, row: region.row, width: region.width, height: region.height)
            }
            regions.removeValue(forKey: id)
            if activeRegion?.id == id {
                activeRegion = nil
            }

        case .setActiveRegion(let id):
            if id == 0 {
                activeRegion = nil
            } else {
                activeRegion = regions[id]
            }
        }
    }

    // MARK: - Private

    private func drawText(row: UInt16, col: UInt16, fg: UInt32, bg: UInt32, attrs: UInt8, text: String) {
        var absRow = row
        var absCol = col
        var maxCol = grid.cols

        if let region = activeRegion {
            absRow &+= region.row
            absCol &+= region.col
            // Clip to region bounds.
            if absRow >= region.row &+ region.height { return }
            maxCol = min(grid.cols, region.col &+ region.width)
        }

        var currentCol = absCol

        // Iterate grapheme clusters (Swift's Character type is a grapheme cluster).
        for char in text {
            guard currentCol < maxCol else { break }

            let grapheme = String(char)
            // Simple width heuristic: CJK and emoji are 2 cells wide.
            let w = graphemeWidth(grapheme)

            grid.writeCell(col: currentCol, row: absRow, cell: Cell(
                grapheme: grapheme,
                width: UInt8(w),
                fg: fg,
                bg: bg,
                attrs: attrs
            ))

            currentCol &+= UInt16(w)
        }
    }

    /// Estimate display width of a grapheme. Full-width CJK characters and
    /// emoji occupy 2 cells; most others occupy 1.
    private func graphemeWidth(_ grapheme: String) -> Int {
        guard let scalar = grapheme.unicodeScalars.first else { return 1 }
        let cp = scalar.value

        // CJK Unified Ideographs and related blocks
        if (cp >= 0x1100 && cp <= 0x115F) ||   // Hangul Jamo
           cp == 0x2329 || cp == 0x232A ||
           (cp >= 0x2E80 && cp <= 0x303E) ||    // CJK Radicals
           (cp >= 0x3040 && cp <= 0x33BF) ||    // Hiragana, Katakana, CJK
           (cp >= 0x3400 && cp <= 0x4DBF) ||    // CJK Extension A
           (cp >= 0x4E00 && cp <= 0xA4CF) ||    // CJK Unified Ideographs
           (cp >= 0xAC00 && cp <= 0xD7AF) ||    // Hangul Syllables
           (cp >= 0xF900 && cp <= 0xFAFF) ||    // CJK Compatibility Ideographs
           (cp >= 0xFE30 && cp <= 0xFE6F) ||    // CJK Compatibility Forms
           (cp >= 0xFF01 && cp <= 0xFF60) ||     // Fullwidth Forms
           (cp >= 0xFFE0 && cp <= 0xFFE6) ||
           (cp >= 0x1F000 && cp <= 0x1FFFF) ||  // Emoji, Mahjong, Domino
           (cp >= 0x20000 && cp <= 0x2FFFF) ||  // CJK Extension B+
           (cp >= 0x30000 && cp <= 0x3FFFF) {   // CJK Extension G+
            return 2
        }

        return 1
    }
}
