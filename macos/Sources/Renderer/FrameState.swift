/// Lightweight per-frame metadata for the Metal render pass.
///
/// Extracted from LineBuffer to separate frame metadata (cursor, gutter,
/// cursorline, theme colors, grid dimensions) from styled run content.
/// CommandDispatcher owns this as a mutable value; CoreTextMetalRenderer
/// reads it synchronously during render().
///
/// No `clear()` method: metadata fields persist across frames and are
/// overwritten individually by protocol opcodes. Only `dirty` resets
/// at frame start via `beginFrame()`.

/// Gutter theme colors grouped for cleaner dispatch and rendering.
struct GutterThemeColors {
    var fg: UInt32 = 0x555555
    var currentFg: UInt32 = 0xBBC2CF
    var errorFg: UInt32 = 0xFF6C6B
    var warningFg: UInt32 = 0xECBE7B
    var infoFg: UInt32 = 0x51AFEF
    var hintFg: UInt32 = 0x555555
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

    // Per-window gutter data from gui_gutter (0x7B).
    // NOT cleared between frames: stale data serves as fallback to
    // prevent blank-gutter flash if the gutter command hasn't arrived yet.
    var windowGutters: [UInt16: Wire.WindowGutter] = [:]

    // Split separator data from gui_split_separators (0x84).
    var splitBorderColor: UInt32 = 0
    var verticalSeparators: [Wire.VerticalSeparator] = []
    var horizontalSeparators: [Wire.HorizontalSeparator] = []

    // Gutter theme colors
    var gutterColors: GutterThemeColors = GutterThemeColors()

    // Scroll indicator (derived from gutter + status bar data)
    /// Viewport top line (first visible buffer line, 0-indexed). Derived from the active
    /// window's first gutter entry. 0xFFFFFFFF = unknown.
    var viewportTopLine: UInt32 = 0xFFFF_FFFF
    /// Total line count in the active buffer. From StatusBarState.
    var totalLineCount: UInt32 = 0
    /// Foreground color for the scroll indicator (derived from theme gutter fg).
    var scrollIndicatorColor: UInt32 = 0x555555

    // Indent guides (from 0x91 opcode)
    var windowIndentGuides: [UInt16: IndentGuideData] = [:]

    // Dirty tracking
    var dirty: Bool = true

    init(cols: UInt16, rows: UInt16) {
        self.cols = cols
        self.rows = rows
    }

    /// Mark the frame as dirty at the start of a new batch.
    /// Does NOT clear windowGutters (prevents blank-gutter flash).
    mutating func beginFrame() {
        dirty = true
    }

    /// Resize the grid. Marks dirty.
    mutating func resize(newCols: UInt16, newRows: UInt16) {
        guard newCols != cols || newRows != rows else { return }
        guard newCols > 0, newRows > 0 else { return }
        cols = newCols
        rows = newRows
        dirty = true
    }
}
