/// Line-based styled text run buffer for CoreText rendering.
///
/// Accumulates styled text runs per screen line, preserving the run structure
/// that CoreText needs for proper shaping, kerning, and font smoothing.
/// This replaces the character-cell decomposition that CellGrid does.
///
/// Each line holds an array of `StyledRun` structs describing a contiguous
/// span of text with uniform styling. The BEAM sends `draw_text` commands
/// that append runs; `clear()` resets between frames.

import Foundation

/// A contiguous span of styled text within a single line.
///
/// Each run represents text that shares the same foreground color, background
/// color, text attributes, font weight, and font ID. Runs are ordered by
/// column position within their line.
struct StyledRun: Hashable, Equatable {
    /// Starting column (0-based, in cell units).
    let col: UInt16
    /// The text content of this run.
    let text: String
    /// Foreground color as 24-bit RGB (0 = default).
    let fg: UInt32
    /// Background color as 24-bit RGB (0 = default).
    let bg: UInt32
    /// Text attributes bitmask (bold, italic, underline, reverse, strikethrough).
    let attrs: UInt8
    /// Underline color as 24-bit RGB (0 = use fg color).
    let underlineColor: UInt32
    /// Underline style (0=line, 1=curl, 2=dashed, 3=dotted, 4=double).
    let underlineStyle: UInt8
    /// Font weight for per-span weight variation (0-7, maps thin through black).
    /// 2 = regular (default).
    let fontWeight: UInt8
    /// Font ID for per-span font family (0 = primary, 1-255 = registered secondary fonts).
    let fontId: UInt8

    init(col: UInt16, text: String, fg: UInt32, bg: UInt32, attrs: UInt8,
         underlineColor: UInt32 = 0, underlineStyle: UInt8 = 0,
         fontWeight: UInt8 = 2, fontId: UInt8 = 0) {
        self.col = col
        self.text = text
        self.fg = fg
        self.bg = bg
        self.attrs = attrs
        self.underlineColor = underlineColor
        self.underlineStyle = underlineStyle
        self.fontWeight = fontWeight
        self.fontId = fontId
    }
}

/// Cursor shape for the line buffer (mirrors CellGrid's CursorShape).
enum LineBufferCursorShape {
    case block
    case beam
    case underline
}

/// In-memory line buffer representing the editor's screen state as styled runs.
///
/// Each line is an array of `StyledRun` structs ordered by column. The buffer
/// is populated by `CommandDispatcher` alongside `CellGrid` during the CoreText
/// migration, then read by `CoreTextLineRenderer` to produce Metal textures.
///
/// Not thread-safe; all access should happen on the main thread.
final class LineBuffer {
    /// Styled runs per row. Keyed by row index for sparse access (only rows
    /// that received draw commands have entries).
    private(set) var lines: [UInt16: [StyledRun]] = [:]

    /// Grid dimensions (matches CellGrid).
    private(set) var cols: UInt16
    private(set) var rows: UInt16

    /// Cursor state.
    var cursorRow: UInt16 = 0
    var cursorCol: UInt16 = 0
    var cursorShape: LineBufferCursorShape = .block
    var cursorVisible: Bool = true

    /// Default background color (24-bit RGB) for the window.
    var defaultBg: UInt32 = 0

    /// Gutter separator: column position and color (mirrors CellGrid).
    var gutterCol: UInt16 = 0
    var gutterSeparatorColor: UInt32 = 0

    /// Cursorline: screen row and background color for native rendering.
    /// `cursorlineRow = 0xFFFF` means no cursorline (disabled or inactive).
    var cursorlineRow: UInt16 = 0xFFFF
    var cursorlineBg: UInt32 = 0

    /// Track whether the buffer was modified since last render.
    var dirty: Bool = true

    /// Per-line content hashes for cache invalidation.
    /// Updated when runs change; the renderer compares these against
    /// its cached texture hashes to decide which lines to re-rasterize.
    private(set) var lineHashes: [UInt16: Int] = [:]

    init(cols: UInt16, rows: UInt16) {
        self.cols = cols
        self.rows = rows
    }

    /// Clear all lines and reset cursor state for a new frame.
    func clear() {
        lines.removeAll(keepingCapacity: true)
        lineHashes.removeAll(keepingCapacity: true)
        dirty = true
    }

    /// Append a styled run to the given row.
    ///
    /// Runs are appended in draw order. The renderer assumes runs within
    /// a line don't overlap (the BEAM guarantees this). Out-of-bounds
    /// rows are silently ignored.
    func appendRun(row: UInt16, col: UInt16, text: String, fg: UInt32, bg: UInt32,
                   attrs: UInt8, underlineColor: UInt32 = 0, underlineStyle: UInt8 = 0,
                   fontWeight: UInt8 = 2, fontId: UInt8 = 0) {
        guard row < rows else { return }

        let run = StyledRun(
            col: col, text: text, fg: fg, bg: bg, attrs: attrs,
            underlineColor: underlineColor, underlineStyle: underlineStyle,
            fontWeight: fontWeight, fontId: fontId
        )

        lines[row, default: []].append(run)
        // Invalidate the hash for this line so the renderer knows to re-rasterize.
        lineHashes.removeValue(forKey: row)
        dirty = true
    }

    /// Update cursor position.
    func showCursor(col: UInt16, row: UInt16) {
        cursorCol = col
        cursorRow = row
        dirty = true
    }

    /// Resize the buffer. Clears all content.
    func resize(newCols: UInt16, newRows: UInt16) {
        guard newCols != cols || newRows != rows else { return }
        guard newCols > 0, newRows > 0 else { return }
        cols = newCols
        rows = newRows
        lines.removeAll(keepingCapacity: true)
        lineHashes.removeAll(keepingCapacity: true)
        dirty = true
    }

    /// Clear all runs within a rectangular region.
    ///
    /// Removes runs that fall entirely within the region. Runs that partially
    /// overlap are kept (the BEAM redraws the full line when needed).
    func clearRect(col: UInt16, row: UInt16, width: UInt16, height: UInt16) {
        let rowEnd = min(row &+ height, rows)
        let colEnd = min(col &+ width, cols)

        var r = row
        while r < rowEnd {
            if var lineRuns = lines[r] {
                lineRuns.removeAll { run in
                    run.col >= col && run.col < colEnd
                }
                if lineRuns.isEmpty {
                    lines.removeValue(forKey: r)
                } else {
                    lines[r] = lineRuns
                }
                lineHashes.removeValue(forKey: r)
            }
            r &+= 1
        }
        dirty = true
    }

    /// Compute and cache the content hash for a line.
    ///
    /// Returns the hash value. If the line has no runs, returns 0.
    /// The hash is cached so subsequent calls are O(1) until the line changes.
    @discardableResult
    func computeLineHash(row: UInt16) -> Int {
        if let cached = lineHashes[row] {
            return cached
        }

        guard let runs = lines[row], !runs.isEmpty else {
            lineHashes[row] = 0
            return 0
        }

        var hasher = Hasher()
        for run in runs {
            hasher.combine(run)
        }
        let hash = hasher.finalize()
        lineHashes[row] = hash
        return hash
    }

    /// Returns the styled runs for a given row, or an empty array if none.
    func runsForLine(_ row: UInt16) -> [StyledRun] {
        return lines[row] ?? []
    }

    /// Returns the total number of lines that have content.
    var activeLineCount: Int {
        return lines.count
    }
}
