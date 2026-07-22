/// Lightweight per-frame render metadata captured inside `CommittedEditorSnapshot`.
///
/// CommandDispatcher still owns this mutable value while applying a prepared transaction, but production draw and input code read it only through the committed or visible editor snapshot.
///
/// AC6 (#2999) removed the editor's semantic authority from this type: cursor,
/// gutter geometry (`windowGutters`/`gutterCol`), active window, split
/// separators, and per-window indent guides. Those authorities now live only on
/// `CommittedEditorSnapshot` (its surfaces, `activeWindowId`, and
/// `EditorSnapshotMetadata`). What remains here is chrome/theme render metadata
/// that persists across frames and is frozen into each snapshot's `frameState`.

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

    // Background
    var defaultBg: UInt32 = 0

    // Gutter separator chrome (color only; the active gutter column lives on
    // `EditorSnapshotMetadata.gutterCol`).
    var gutterSeparatorColor: UInt32 = 0

    // Cursorline
    /// `0xFFFF` = no active cursorline (sentinel; set by gui_cursorline opcode).
    var cursorlineRow: UInt16 = 0xFFFF
    var cursorlineBg: UInt32 = 0

    // Gutter theme colors
    var gutterColors: GutterThemeColors = GutterThemeColors()

    // Scroll indicator (derived from gutter + status bar data)
    var viewportTopLine: UInt32 = 0xFFFF_FFFF
    var totalLineCount: UInt32 = 0
    var scrollIndicatorColor: UInt32 = 0x555555

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
