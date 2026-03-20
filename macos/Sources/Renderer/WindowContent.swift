/// Semantic window content decoded from the gui_window_content (0x80) opcode.
///
/// Replaces LineBuffer-based rendering for buffer windows. The BEAM sends
/// pre-resolved visual rows with composed text, highlight spans, selection,
/// search matches, and diagnostic ranges. Swift renders this directly via
/// CoreText without interpreting cell-grid draw_text commands.
///
/// Phase 2: stored alongside LineBuffer, not yet used for rendering.
/// Phase 3: replaces LineBuffer for buffer window content.

import Foundation

// MARK: - Row type

/// What kind of content a visual row represents.
enum GUIVisualRowType: UInt8, Sendable {
    case normal = 0
    case foldStart = 1
    case virtualLine = 2
    case block = 3
    case wrapContinuation = 4
}

// MARK: - Highlight span

/// A pre-resolved highlight span from the BEAM's syntax highlighter.
///
/// Colors are already resolved to 24-bit RGB. Swift applies them directly
/// when building NSAttributedString; no syntax-token-to-theme mapping.
struct GUIHighlightSpan: Sendable, Equatable {
    let startCol: UInt16
    let endCol: UInt16
    let fg: UInt32      // 24-bit RGB
    let bg: UInt32      // 24-bit RGB (0 = transparent)
    let attrs: UInt8    // bit 0: bold, 1: italic, 2: underline, 3: strikethrough, 4: curl
    let fontWeight: UInt8
    let fontId: UInt8

    var isBold: Bool { attrs & 0x01 != 0 }
    var isItalic: Bool { attrs & 0x02 != 0 }
    var isUnderline: Bool { attrs & 0x04 != 0 }
    var isStrikethrough: Bool { attrs & 0x08 != 0 }
    var isCurl: Bool { attrs & 0x10 != 0 }
}

// MARK: - Visual row

/// A single visual row as the GUI should render it.
///
/// The BEAM has already resolved word wrap, folding, virtual text splicing,
/// and conceal ranges. The `text` field is the final composed UTF-8 string.
struct GUIVisualRow: Sendable, Equatable {
    let rowType: GUIVisualRowType
    let bufLine: UInt32
    let contentHash: UInt32
    let text: String
    let spans: [GUIHighlightSpan]
}

// MARK: - Selection overlay

/// Visual selection in display coordinates, rendered as Metal quads.
enum GUISelectionType: UInt8, Sendable {
    case char = 1
    case line = 2
    case block = 3
}

struct GUISelectionOverlay: Sendable, Equatable {
    let type: GUISelectionType
    let startRow: UInt16
    let startCol: UInt16
    let endRow: UInt16
    let endCol: UInt16
}

// MARK: - Search match

/// A search match in display coordinates, rendered as a highlight quad.
struct GUISearchMatch: Sendable, Equatable {
    let row: UInt16
    let startCol: UInt16
    let endCol: UInt16
    let isCurrent: Bool
}

// MARK: - Diagnostic underline

/// Diagnostic severity for underline rendering.
enum GUIDiagnosticSeverity: UInt8, Sendable {
    case error = 0
    case warning = 1
    case info = 2
    case hint = 3
}

/// A diagnostic range in display coordinates, rendered as an underline.
struct GUIDiagnosticUnderline: Sendable, Equatable {
    let startRow: UInt16
    let startCol: UInt16
    let endRow: UInt16
    let endCol: UInt16
    let severity: GUIDiagnosticSeverity
}

// MARK: - Document highlight

/// LSP document highlight kind (matches LSP spec values).
enum GUIDocumentHighlightKind: UInt8, Sendable {
    case text = 1
    case read = 2
    case write = 3
}

/// A document highlight range in display coordinates.
/// Rendered as a subtle background quad behind text, similar to search matches.
struct GUIDocumentHighlight: Sendable, Equatable {
    let startRow: UInt16
    let startCol: UInt16
    let endRow: UInt16
    let endCol: UInt16
    let kind: GUIDocumentHighlightKind
}

// MARK: - Window content

/// Complete semantic content for one editor window.
///
/// Decoded from the gui_window_content (0x80) opcode. During Phase 2,
/// this is stored but not yet used for rendering (draw_text still active).
/// Phase 3 will switch rendering to use this data directly.
final class GUIWindowContent: Sendable {
    let windowId: UInt16
    let fullRefresh: Bool
    let cursorRow: UInt16
    let cursorCol: UInt16
    let cursorShape: CursorShape
    let rows: [GUIVisualRow]
    let selection: GUISelectionOverlay?
    let searchMatches: [GUISearchMatch]
    let diagnosticUnderlines: [GUIDiagnosticUnderline]
    let documentHighlights: [GUIDocumentHighlight]

    init(windowId: UInt16, fullRefresh: Bool,
         cursorRow: UInt16, cursorCol: UInt16, cursorShape: CursorShape,
         rows: [GUIVisualRow], selection: GUISelectionOverlay?,
         searchMatches: [GUISearchMatch],
         diagnosticUnderlines: [GUIDiagnosticUnderline],
         documentHighlights: [GUIDocumentHighlight]) {
        self.windowId = windowId
        self.fullRefresh = fullRefresh
        self.cursorRow = cursorRow
        self.cursorCol = cursorCol
        self.cursorShape = cursorShape
        self.rows = rows
        self.selection = selection
        self.searchMatches = searchMatches
        self.diagnosticUnderlines = diagnosticUnderlines
        self.documentHighlights = documentHighlights
    }
}
