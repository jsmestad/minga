/// Lightweight editor metadata captured inside `CommittedEditorSnapshot`.
///
/// CommandDispatcher still owns this mutable value while applying a prepared transaction, but production draw and input code read it only through the committed or visible editor snapshot. Missing or incompatible gutter, geometry, cursor, active-window, and split combinations must reject before snapshot publication instead of falling back during render.

import MingaProtocol

/// Gutter theme colors grouped for cleaner dispatch and rendering.
struct GutterThemeColors {
    var fg: UInt32 = 0x555555
    var currentFg: UInt32 = 0xBBC2CF
    var errorFg: UInt32 = 0xFF6C6B
    var warningFg: UInt32 = 0xECBE7B
    var infoFg: UInt32 = 0x51AFEF
    var hintFg: UInt32 = 0x555555
    var foldFg: UInt32 = 0x555555
    var gitAddedFg: UInt32 = 0x98BE65
    var gitModifiedFg: UInt32 = 0x51AFEF
    var gitDeletedFg: UInt32 = 0xFF6C6B
}

/// Per-frame rendering metadata read by the Metal render pass.
///
/// All fields are set by CommandDispatcher from protocol opcodes.
/// The Metal renderer reads these synchronously during `draw()`.
struct FrameState {
    // Grid dimensions
    var cols: UInt16
    var rows: UInt16

    // Cursor
    var cursorRow: UInt16 = 0
    var cursorCol: UInt16 = 0
    var cursorShape: CursorShape = .block
    // Always true: protocol has no hideCursor command yet. Reserved for future use.
    var cursorVisible: Bool = true

    // Background
    var defaultBg: UInt32 = 0

    // Gutter geometry
    var gutterCol: UInt16 = 0
    var gutterSeparatorColor: UInt32 = 0

    // Cursorline
    /// `0xFFFF` = no active cursorline (sentinel; set by gui_cursorline opcode).
    var cursorlineRow: UInt16 = 0xFFFF
    var cursorlineBg: UInt32 = 0

    // Per-window gutter data from gui_gutter (0x7B). Keyframes prune this map inside the successful prepared transaction, and snapshot freeze rejects content that requires a missing or incompatible gutter.
    var windowGutters: [UInt16: Wire.WindowGutter] = [:]
    var activeWindowId: UInt16?

    // Split separator data from gui_split_separators (0x84).
    var splitBorderColor: UInt32 = 0
    var verticalSeparators: [Wire.VerticalSeparator] = []
    var horizontalSeparators: [Wire.HorizontalSeparator] = []

    // Gutter theme colors
    var gutterColors: GutterThemeColors = GutterThemeColors()

    // Scroll indicator (derived from gutter + status bar data)
    var viewportTopLine: UInt32 = 0xFFFF_FFFF
    var totalLineCount: UInt32 = 0
    var scrollIndicatorColor: UInt32 = 0x555555

    // Indent guides (from 0x91 opcode)
    var windowIndentGuides: [UInt16: IndentGuideData] = [:]

    // Line spacing multiplier (from gui_line_spacing opcode).
    var lineSpacing: Float = 1.0

    init(cols: UInt16, rows: UInt16) {
        self.cols = cols
        self.rows = rows
    }

    /// Resize the grid.
    mutating func resize(newCols: UInt16, newRows: UInt16) {
        guard newCols != cols || newRows != rows else { return }
        guard newCols > 0, newRows > 0 else { return }
        cols = newCols
        rows = newRows
    }
}
