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
public enum GUIVisualRowType: UInt8, Sendable {
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
public struct GUIHighlightSpan: Sendable, Equatable {
    public let startCol: UInt16
    public let endCol: UInt16
    public let fg: UInt32      // 24-bit RGB
    public let bg: UInt32      // 24-bit RGB (0 = transparent)
    public let attrs: UInt8    // bit 0: bold, 1: italic, 2: underline, 3: strikethrough, 4: curl
    public let fontWeight: UInt8
    public let fontId: UInt8

    public init(startCol: UInt16, endCol: UInt16, fg: UInt32, bg: UInt32, attrs: UInt8, fontWeight: UInt8, fontId: UInt8) {
        self.startCol = startCol
        self.endCol = endCol
        self.fg = fg
        self.bg = bg
        self.attrs = attrs
        self.fontWeight = fontWeight
        self.fontId = fontId
    }

    public var isBold: Bool { attrs & 0x01 != 0 }
    public var isItalic: Bool { attrs & 0x02 != 0 }
    public var isUnderline: Bool { attrs & 0x04 != 0 }
    public var isStrikethrough: Bool { attrs & 0x08 != 0 }
    public var isCurl: Bool { attrs & 0x10 != 0 }
}

// MARK: - Visual row

/// A single visual row as the GUI should render it.
///
/// The BEAM has already resolved word wrap, folding, virtual text splicing,
/// and conceal ranges. The `text` field is the final composed UTF-8 string.
public struct GUIVisualRow: Sendable, Equatable {
    public let rowType: GUIVisualRowType
    public let rowId: UInt64
    public let bufLine: UInt32
    public let contentHash: UInt32
    public let text: String
    public let spans: [GUIHighlightSpan]

    public init(rowType: GUIVisualRowType, rowId: UInt64, bufLine: UInt32, contentHash: UInt32, text: String, spans: [GUIHighlightSpan]) {
        self.rowType = rowType
        self.rowId = rowId
        self.bufLine = bufLine
        self.contentHash = contentHash
        self.text = text
        self.spans = spans
    }
}

// MARK: - Selection overlay

/// Visual selection in display coordinates, rendered as Metal quads.
public enum GUISelectionType: UInt8, Sendable {
    case char = 1
    case line = 2
    case block = 3
}

public struct GUISelectionOverlay: Sendable, Equatable {
    public let type: GUISelectionType
    public let startRow: UInt16
    public let startCol: UInt16
    public let endRow: UInt16
    public let endCol: UInt16

    public init(type: GUISelectionType, startRow: UInt16, startCol: UInt16, endRow: UInt16, endCol: UInt16) {
        self.type = type
        self.startRow = startRow
        self.startCol = startCol
        self.endRow = endRow
        self.endCol = endCol
    }
}

// MARK: - Search match

/// A search match in display coordinates, rendered as a highlight quad.
public struct GUISearchMatch: Sendable, Equatable {
    public let row: UInt16
    public let startCol: UInt16
    public let endCol: UInt16
    public let isCurrent: Bool

    public init(row: UInt16, startCol: UInt16, endCol: UInt16, isCurrent: Bool) {
        self.row = row
        self.startCol = startCol
        self.endCol = endCol
        self.isCurrent = isCurrent
    }
}

// MARK: - Diagnostic underline

/// Diagnostic severity for underline rendering.
public enum GUIDiagnosticSeverity: UInt8, Sendable {
    case error = 0
    case warning = 1
    case info = 2
    case hint = 3
}

/// A diagnostic range in display coordinates, rendered as an underline.
public struct GUIDiagnosticUnderline: Sendable, Equatable {
    public let startRow: UInt16
    public let startCol: UInt16
    public let endRow: UInt16
    public let endCol: UInt16
    public let severity: GUIDiagnosticSeverity

    public init(startRow: UInt16, startCol: UInt16, endRow: UInt16, endCol: UInt16, severity: GUIDiagnosticSeverity) {
        self.startRow = startRow
        self.startCol = startCol
        self.endRow = endRow
        self.endCol = endCol
        self.severity = severity
    }
}

// MARK: - Document highlight

/// LSP document highlight kind (matches LSP spec values).
public enum GUIDocumentHighlightKind: UInt8, Sendable {
    case text = 1
    case read = 2
    case write = 3
}

/// A document highlight range in display coordinates.
/// Rendered as a subtle background quad behind text, similar to search matches.
public struct GUIDocumentHighlight: Sendable, Equatable {
    public let startRow: UInt16
    public let startCol: UInt16
    public let endRow: UInt16
    public let endCol: UInt16
    public let kind: GUIDocumentHighlightKind

    public init(startRow: UInt16, startCol: UInt16, endRow: UInt16, endCol: UInt16, kind: GUIDocumentHighlightKind) {
        self.startRow = startRow
        self.startCol = startCol
        self.endRow = endRow
        self.endCol = endCol
        self.kind = kind
    }
}

// MARK: - Line annotation

/// The visual kind of a line annotation.
public enum GUILineAnnotationKind: UInt8, Sendable {
    case inlinePill = 0
    case inlineText = 1
    case gutterIcon = 2
}

/// A line annotation in display coordinates.
///
/// Pill badges render as rounded-rect pills after line content.
/// Inline text renders as styled text after line content (no background).
/// Gutter icons render in the sign column.
public struct GUILineAnnotation: Sendable, Equatable {
    public let row: UInt16
    public let kind: GUILineAnnotationKind
    public let fg: UInt32      // 24-bit RGB
    public let bg: UInt32      // 24-bit RGB
    public let text: String

    public init(row: UInt16, kind: GUILineAnnotationKind, fg: UInt32, bg: UInt32, text: String) {
        self.row = row
        self.kind = kind
        self.fg = fg
        self.bg = bg
        self.text = text
    }
}

// MARK: - Pane geometry

public struct GUICellRect: Sendable, Equatable {
    public let row: UInt16
    public let col: UInt16
    public let width: UInt16
    public let height: UInt16

    public init(row: UInt16, col: UInt16, width: UInt16, height: UInt16) {
        self.row = row
        self.col = col
        self.width = width
        self.height = height
    }
}

public struct GUIViewportSummary: Sendable, Equatable {
    public let top: UInt32
    public let left: UInt16
    public let rows: UInt16
    public let cols: UInt16
    public let totalLines: UInt32
    public let visualRowOffset: UInt16
    public let totalVisualRows: UInt32

    public init(top: UInt32, left: UInt16, rows: UInt16, cols: UInt16, totalLines: UInt32, visualRowOffset: UInt16, totalVisualRows: UInt32) {
        self.top = top
        self.left = left
        self.rows = rows
        self.cols = cols
        self.totalLines = totalLines
        self.visualRowOffset = visualRowOffset
        self.totalVisualRows = totalVisualRows
    }
}

/// Metadata for client-local presentation scrolling.
///
/// The visible and overscan line ranges are half-open: start is inclusive and end is exclusive.
public struct GUIScrollPresentation: Sendable, Equatable {
    public let windowId: UInt16
    public let resetRequired: Bool
    public let anchorTop: UInt32
    public let anchorLeft: UInt16
    public let anchorVisualRowOffset: UInt16
    public let visibleStartLine: UInt32
    public let visibleEndLine: UInt32
    public let overscanStartLine: UInt32
    public let overscanEndLine: UInt32
    public let contentEpoch: UInt32
    public let layoutGeneration: UInt32

    public init(windowId: UInt16, resetRequired: Bool, anchorTop: UInt32, anchorLeft: UInt16, anchorVisualRowOffset: UInt16, visibleStartLine: UInt32, visibleEndLine: UInt32, overscanStartLine: UInt32, overscanEndLine: UInt32, contentEpoch: UInt32, layoutGeneration: UInt32) {
        self.windowId = windowId
        self.resetRequired = resetRequired
        self.anchorTop = anchorTop
        self.anchorLeft = anchorLeft
        self.anchorVisualRowOffset = anchorVisualRowOffset
        self.visibleStartLine = visibleStartLine
        self.visibleEndLine = visibleEndLine
        self.overscanStartLine = overscanStartLine
        self.overscanEndLine = overscanEndLine
        self.contentEpoch = contentEpoch
        self.layoutGeneration = layoutGeneration
    }

    public func isSameAnchorKey(as other: GUIScrollPresentation) -> Bool {
        contentEpoch == other.contentEpoch
            && layoutGeneration == other.layoutGeneration
            && anchorTop == other.anchorTop
            && anchorLeft == other.anchorLeft
    }

    public func belongsTo(windowId: UInt16, contentEpoch: UInt32) -> Bool {
        self.windowId == windowId && self.contentEpoch == contentEpoch
    }
}

public struct GUIGutterMetrics: Sendable, Equatable {
    public let lineNumberWidth: UInt16
    public let signColWidth: UInt16

    public init(lineNumberWidth: UInt16, signColWidth: UInt16) {
        self.lineNumberWidth = lineNumberWidth
        self.signColWidth = signColWidth
    }
}

public struct GUIHitRegion: Sendable, Equatable {
    public enum Kind: UInt8, Sendable {
        case text = 1
        case gutter = 2
        case foldControl = 3
        case modeline = 4
        case divider = 5
        case statusBar = 6
    }

    public let kind: Kind
    public let rect: GUICellRect
    public let windowId: UInt16

    public init(kind: Kind, rect: GUICellRect, windowId: UInt16) {
        self.kind = kind
        self.rect = rect
        self.windowId = windowId
    }
}

public struct GUICursorline: Sendable, Equatable {
    public let row: UInt16
    public let bg: UInt32

    public init(row: UInt16, bg: UInt32) {
        self.row = row
        self.bg = bg
    }
}

public struct GUIWindowOverlayDelta: Sendable, Equatable {
    public let windowId: UInt16
    public let contentEpoch: UInt32
    public let cursorVisible: Bool
    public let cursorRow: UInt16
    public let cursorCol: UInt16
    public let cursorShape: CursorShape
    public let cursorline: GUICursorline?

    public init(windowId: UInt16, contentEpoch: UInt32, cursorVisible: Bool, cursorRow: UInt16, cursorCol: UInt16, cursorShape: CursorShape, cursorline: GUICursorline?) {
        self.windowId = windowId
        self.contentEpoch = contentEpoch
        self.cursorVisible = cursorVisible
        self.cursorRow = cursorRow
        self.cursorCol = cursorCol
        self.cursorShape = cursorShape
        self.cursorline = cursorline
    }
}

public enum GUIWindowRowDeltaEntry: Sendable, Equatable {
    case reference(rowId: UInt64, contentHash: UInt32)
    case full(GUIVisualRow)
}

public struct GUIWindowRowsDelta: Sendable, Equatable {
    public let windowId: UInt16
    public let contentEpoch: UInt32
    public let cursorVisible: Bool
    public let cursorRow: UInt16
    public let cursorCol: UInt16
    public let cursorShape: CursorShape
    public let scrollLeft: UInt16
    public let rows: [GUIWindowRowDeltaEntry]
    public let selection: GUISelectionOverlay?
    public let searchMatches: [GUISearchMatch]
    public let diagnosticUnderlines: [GUIDiagnosticUnderline]
    public let documentHighlights: [GUIDocumentHighlight]
    public let lineAnnotations: [GUILineAnnotation]
    public let paneGeometry: GUIPaneGeometry?
    public let cursorline: GUICursorline?
    public let scrollPresentation: GUIScrollPresentation?

    public init(windowId: UInt16, contentEpoch: UInt32, cursorVisible: Bool, cursorRow: UInt16,
         cursorCol: UInt16, cursorShape: CursorShape, scrollLeft: UInt16,
         rows: [GUIWindowRowDeltaEntry], selection: GUISelectionOverlay?,
         searchMatches: [GUISearchMatch], diagnosticUnderlines: [GUIDiagnosticUnderline],
         documentHighlights: [GUIDocumentHighlight], lineAnnotations: [GUILineAnnotation],
         paneGeometry: GUIPaneGeometry?, cursorline: GUICursorline?,
         scrollPresentation: GUIScrollPresentation? = nil) {
        self.windowId = windowId
        self.contentEpoch = contentEpoch
        self.cursorVisible = cursorVisible
        self.cursorRow = cursorRow
        self.cursorCol = cursorCol
        self.cursorShape = cursorShape
        self.scrollLeft = scrollLeft
        self.rows = rows
        self.selection = selection
        self.searchMatches = searchMatches
        self.diagnosticUnderlines = diagnosticUnderlines
        self.documentHighlights = documentHighlights
        self.lineAnnotations = lineAnnotations
        self.paneGeometry = paneGeometry
        self.cursorline = cursorline
        self.scrollPresentation = scrollPresentation
    }
}

public struct GUIPaneGeometry: Sendable, Equatable {
    public let windowId: UInt16
    public let totalRect: GUICellRect
    public let contentRect: GUICellRect
    public let textRect: GUICellRect
    public let gutterRect: GUICellRect
    public let clipRect: GUICellRect
    public let viewport: GUIViewportSummary
    public let gutterMetrics: GUIGutterMetrics
    public let hitRegions: [GUIHitRegion]

    public init(windowId: UInt16, totalRect: GUICellRect, contentRect: GUICellRect, textRect: GUICellRect, gutterRect: GUICellRect, clipRect: GUICellRect, viewport: GUIViewportSummary, gutterMetrics: GUIGutterMetrics, hitRegions: [GUIHitRegion]) {
        self.windowId = windowId
        self.totalRect = totalRect
        self.contentRect = contentRect
        self.textRect = textRect
        self.gutterRect = gutterRect
        self.clipRect = clipRect
        self.viewport = viewport
        self.gutterMetrics = gutterMetrics
        self.hitRegions = hitRegions
    }
}

// MARK: - Retained row key

/// Key for the retained-row lookup used by delta application.
/// Combines row identity with a content hash so the renderer can reuse
/// previously decoded rows when only overlays change.
public struct GUIRetainedRowKey: Hashable, Sendable {
    public let rowId: UInt64
    public let contentHash: UInt32

    public init(rowId: UInt64, contentHash: UInt32) {
        self.rowId = rowId
        self.contentHash = contentHash
    }
}

// MARK: - Window content

/// Complete semantic content for one editor window.
///
/// Decoded from the gui_window_content (0x80) opcode. During Phase 2,
/// this is stored but not yet used for rendering (draw_text still active).
/// Phase 3 will switch rendering to use this data directly.
public final class GUIWindowContent: Sendable {
    public let windowId: UInt16
    public let fullRefresh: Bool
    public let contentEpoch: UInt32
    /// Whether the BEAM wants the cursor visible in this window.
    /// False when the minibuffer or other overlay has focus.
    public let cursorVisible: Bool
    public let cursorRow: UInt16
    public let cursorCol: UInt16
    public let cursorShape: CursorShape
    /// Horizontal scroll offset in display columns. When > 0, line textures
    /// and overlay quads must be shifted left by `scrollLeft * cellWidth` pixels
    /// so content past the viewport edge becomes visible.
    public let scrollLeft: UInt16
    public let rows: [GUIVisualRow]
    public let selection: GUISelectionOverlay?
    public let searchMatches: [GUISearchMatch]
    public let diagnosticUnderlines: [GUIDiagnosticUnderline]
    public let documentHighlights: [GUIDocumentHighlight]
    public let lineAnnotations: [GUILineAnnotation]
    public let paneGeometry: GUIPaneGeometry?
    public let cursorline: GUICursorline?
    public let scrollPresentation: GUIScrollPresentation?

    /// Pre-built index mapping retained-row keys to their visual rows.
    /// Used by `applyingRowsDelta` to resolve reference entries without
    /// rebuilding the dictionary on every delta application.
    public let retainedRowIndex: [GUIRetainedRowKey: GUIVisualRow]

    public init(windowId: UInt16, fullRefresh: Bool, contentEpoch: UInt32 = 0, cursorVisible: Bool = true,
         cursorRow: UInt16, cursorCol: UInt16, cursorShape: CursorShape,
         scrollLeft: UInt16 = 0,
         rows: [GUIVisualRow], selection: GUISelectionOverlay?,
         searchMatches: [GUISearchMatch],
         diagnosticUnderlines: [GUIDiagnosticUnderline],
         documentHighlights: [GUIDocumentHighlight],
         lineAnnotations: [GUILineAnnotation] = [],
         paneGeometry: GUIPaneGeometry? = nil,
         cursorline: GUICursorline? = nil,
         scrollPresentation: GUIScrollPresentation? = nil,
         retainedRowIndex existingIndex: [GUIRetainedRowKey: GUIVisualRow]? = nil) {
        self.windowId = windowId
        self.fullRefresh = fullRefresh
        self.contentEpoch = contentEpoch
        self.cursorVisible = cursorVisible
        self.cursorRow = cursorRow
        self.cursorCol = cursorCol
        self.cursorShape = cursorShape
        self.scrollLeft = scrollLeft
        self.rows = rows
        self.selection = selection
        self.searchMatches = searchMatches
        self.diagnosticUnderlines = diagnosticUnderlines
        self.documentHighlights = documentHighlights
        self.lineAnnotations = lineAnnotations
        self.paneGeometry = paneGeometry
        self.cursorline = cursorline
        self.scrollPresentation = scrollPresentation

        if let existingIndex {
            self.retainedRowIndex = existingIndex
        } else {
            var index: [GUIRetainedRowKey: GUIVisualRow] = [:]
            index.reserveCapacity(rows.count)
            for row in rows {
                index[GUIRetainedRowKey(rowId: row.rowId, contentHash: row.contentHash)] = row
            }
            self.retainedRowIndex = index
        }
    }

    public func applyingOverlayDelta(_ delta: GUIWindowOverlayDelta) -> GUIWindowContent? {
        guard delta.windowId == windowId, delta.contentEpoch == contentEpoch else {
            return nil
        }

        return GUIWindowContent(
            windowId: windowId,
            fullRefresh: false,
            contentEpoch: contentEpoch,
            cursorVisible: delta.cursorVisible,
            cursorRow: delta.cursorRow,
            cursorCol: delta.cursorCol,
            cursorShape: delta.cursorShape,
            scrollLeft: scrollLeft,
            rows: rows,
            selection: selection,
            searchMatches: searchMatches,
            diagnosticUnderlines: diagnosticUnderlines,
            documentHighlights: documentHighlights,
            lineAnnotations: lineAnnotations,
            paneGeometry: paneGeometry,
            cursorline: delta.cursorline,
            scrollPresentation: scrollPresentation,
            retainedRowIndex: retainedRowIndex
        )
    }

    public func applyingRowsDelta(_ delta: GUIWindowRowsDelta) -> GUIWindowContent? {
        guard delta.windowId == windowId, delta.contentEpoch == contentEpoch else {
            return nil
        }

        var resolvedRows: [GUIVisualRow] = []
        resolvedRows.reserveCapacity(delta.rows.count)

        for entry in delta.rows {
            switch entry {
            case .reference(let rowId, let contentHash):
                let key = GUIRetainedRowKey(rowId: rowId, contentHash: contentHash)
                guard let row = retainedRowIndex[key] else { return nil }
                resolvedRows.append(row)
            case .full(let row):
                resolvedRows.append(row)
            }
        }

        let nextScrollPresentation = delta.scrollPresentation?.belongsTo(windowId: windowId, contentEpoch: contentEpoch) == true ? delta.scrollPresentation : nil

        return GUIWindowContent(
            windowId: windowId,
            fullRefresh: false,
            contentEpoch: contentEpoch,
            cursorVisible: delta.cursorVisible,
            cursorRow: delta.cursorRow,
            cursorCol: delta.cursorCol,
            cursorShape: delta.cursorShape,
            scrollLeft: delta.scrollLeft,
            rows: resolvedRows,
            selection: delta.selection,
            searchMatches: delta.searchMatches,
            diagnosticUnderlines: delta.diagnosticUnderlines,
            documentHighlights: delta.documentHighlights,
            lineAnnotations: delta.lineAnnotations,
            paneGeometry: delta.paneGeometry,
            cursorline: delta.cursorline,
            scrollPresentation: nextScrollPresentation
        )
    }
}
