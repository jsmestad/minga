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
    /// Monotonic scroll-authority sequence (#2661). Advances only when the BEAM
    /// commits a new anchor for a reason other than an echoed frontend scroll
    /// report, so a frontend can tell a genuine jump apart from its own report
    /// being reflected back even when the jump coincidentally lands on the same
    /// `anchorTop`.
    public let scrollSeq: UInt32

    public init(windowId: UInt16, resetRequired: Bool, anchorTop: UInt32, anchorLeft: UInt16, anchorVisualRowOffset: UInt16, visibleStartLine: UInt32, visibleEndLine: UInt32, overscanStartLine: UInt32, overscanEndLine: UInt32, contentEpoch: UInt32, layoutGeneration: UInt32, scrollSeq: UInt32 = 0) {
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
        self.scrollSeq = scrollSeq
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

/// A retained reference or complete row carried by an A1/A2 update.
public enum GUIWindowRowDeltaEntry: Sendable, Equatable {
    /// Reuses an immutable-base row by durable identity and content hash.
    case reference(rowId: UInt64, contentHash: UInt32)
    /// Carries a complete semantic visual row.
    case full(GUIVisualRow)
}

/// One protocol-v11 A2 splice expressed in immutable-base coordinates.
public struct GUIWindowRowSplice: Sendable, Equatable {
    /// Zero-based start coordinate in the immutable base.
    public let startIndex: UInt32
    /// Number of immutable-base rows deleted.
    public let deleteCount: UInt32
    /// Ref-or-full entries inserted at `startIndex`.
    public let insertEntries: [GUIWindowRowDeltaEntry]

    /// Creates one decoded A2 row splice.
    public init(startIndex: UInt32, deleteCount: UInt32,
                insertEntries: [GUIWindowRowDeltaEntry]) {
        self.startIndex = startIndex
        self.deleteCount = deleteCount
        self.insertEntries = insertEntries
    }
}

/// A decoded A1 complete snapshot, legacy-v10 A2 snapshot, or v11 A2 splice plan.
public struct GUIWindowRowsDelta: Sendable, Equatable {
    public let windowId: UInt16
    public let contentEpoch: UInt32
    public let cursorVisible: Bool
    public let cursorRow: UInt16
    public let cursorCol: UInt16
    public let cursorShape: CursorShape
    public let scrollLeft: UInt16
    /// Complete entries for A1 or legacy-v10 A2; empty for v11 A2.
    public let rows: [GUIWindowRowDeltaEntry]
    /// Immutable base row count for v11 A2.
    public let baseRowCount: UInt32?
    /// Exact result row count for v11 A2.
    public let resultRowCount: UInt32?
    /// V11 A2 row splices; nil for complete snapshots.
    public let rowSplices: [GUIWindowRowSplice]?
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
        self.baseRowCount = nil
        self.resultRowCount = nil
        self.rowSplices = nil
        self.selection = selection
        self.searchMatches = searchMatches
        self.diagnosticUnderlines = diagnosticUnderlines
        self.documentHighlights = documentHighlights
        self.lineAnnotations = lineAnnotations
        self.paneGeometry = paneGeometry
        self.cursorline = cursorline
        self.scrollPresentation = scrollPresentation
    }

    /// Creates a protocol-v11 A2 delta containing immutable-base row splices.
    public init(windowId: UInt16, contentEpoch: UInt32, cursorVisible: Bool, cursorRow: UInt16,
         cursorCol: UInt16, cursorShape: CursorShape, scrollLeft: UInt16,
         baseRowCount: UInt32, resultRowCount: UInt32, rowSplices: [GUIWindowRowSplice],
         selection: GUISelectionOverlay?, searchMatches: [GUISearchMatch],
         diagnosticUnderlines: [GUIDiagnosticUnderline],
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
        self.rows = []
        self.baseRowCount = baseRowCount
        self.resultRowCount = resultRowCount
        self.rowSplices = rowSplices
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
    /// Chunked owner for both resident and explicitly windowed row content.
    public let rowStore: ResidentRowStore
    /// Work performed while producing this immutable content value. Lifetime
    /// totals remain available from `rowStore.counters`.
    public let rowStoreOperationCounters: ResidentRowStoreCounters

    #if DEBUG
    /// Compatibility view for protocol tests and non-rendering diagnostics.
    /// Renderer hot paths must request a bounded slice from `rowStore`; Release builds do not expose full resident-document materialization.
    public var rows: [GUIVisualRow] { rowStore.rows(in: 0..<rowStore.count).rows }
    #endif
    public let selection: GUISelectionOverlay?
    public let searchMatches: [GUISearchMatch]
    public let diagnosticUnderlines: [GUIDiagnosticUnderline]
    public let documentHighlights: [GUIDocumentHighlight]
    public let lineAnnotations: [GUILineAnnotation]
    public let paneGeometry: GUIPaneGeometry?
    public let cursorline: GUICursorline?
    public let scrollPresentation: GUIScrollPresentation?
    /// Exact immutable ownership retained by this published window.
    public let resourceWeight: FrameResourceWeight

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
         residentLimit: FrameResourceWeight = FrameResourcePolicy.default.resident.weightPerWindow) throws {
        let rowWeight = try ResidentRowStore.weight(of: rows)
        let completeWeight = try Self.resourceWeight(
            rowWeight: rowWeight, selection: selection, searchMatches: searchMatches,
            diagnosticUnderlines: diagnosticUnderlines,
            documentHighlights: documentHighlights, lineAnnotations: lineAnnotations,
            paneGeometry: paneGeometry
        )
        try Self.validate(completeWeight, limit: residentLimit)
        let store = try ResidentRowStore(
            decodedRows: rows, resourceWeight: rowWeight, limit: residentLimit
        )
        self.windowId = windowId
        self.fullRefresh = fullRefresh
        self.contentEpoch = contentEpoch
        self.cursorVisible = cursorVisible
        self.cursorRow = cursorRow
        self.cursorCol = cursorCol
        self.cursorShape = cursorShape
        self.scrollLeft = scrollLeft
        self.rowStore = store
        self.rowStoreOperationCounters = store.counters
        self.selection = selection
        self.searchMatches = searchMatches
        self.diagnosticUnderlines = diagnosticUnderlines
        self.documentHighlights = documentHighlights
        self.lineAnnotations = lineAnnotations
        self.paneGeometry = paneGeometry
        self.cursorline = cursorline
        self.scrollPresentation = scrollPresentation
        self.resourceWeight = completeWeight
    }

    private init(windowId: UInt16, fullRefresh: Bool, contentEpoch: UInt32,
         cursorVisible: Bool, cursorRow: UInt16, cursorCol: UInt16, cursorShape: CursorShape,
         scrollLeft: UInt16, rowStore: ResidentRowStore,
         rowStoreOperationCounters: ResidentRowStoreCounters,
         selection: GUISelectionOverlay?, searchMatches: [GUISearchMatch],
         diagnosticUnderlines: [GUIDiagnosticUnderline], documentHighlights: [GUIDocumentHighlight],
         lineAnnotations: [GUILineAnnotation], paneGeometry: GUIPaneGeometry?,
         cursorline: GUICursorline?, scrollPresentation: GUIScrollPresentation?,
         resourceWeight: FrameResourceWeight) {
        self.windowId = windowId
        self.fullRefresh = fullRefresh
        self.contentEpoch = contentEpoch
        self.cursorVisible = cursorVisible
        self.cursorRow = cursorRow
        self.cursorCol = cursorCol
        self.cursorShape = cursorShape
        self.scrollLeft = scrollLeft
        self.rowStore = rowStore
        self.rowStoreOperationCounters = rowStoreOperationCounters
        self.selection = selection
        self.searchMatches = searchMatches
        self.diagnosticUnderlines = diagnosticUnderlines
        self.documentHighlights = documentHighlights
        self.lineAnnotations = lineAnnotations
        self.paneGeometry = paneGeometry
        self.cursorline = cursorline
        self.scrollPresentation = scrollPresentation
        self.resourceWeight = resourceWeight
    }

    /// Returns the same immutable content while replacing per-frame operation counters.
    public func reportingOperationCounters(_ counters: ResidentRowStoreCounters) -> GUIWindowContent {
        GUIWindowContent(
            windowId: windowId, fullRefresh: fullRefresh, contentEpoch: contentEpoch,
            cursorVisible: cursorVisible, cursorRow: cursorRow, cursorCol: cursorCol,
            cursorShape: cursorShape, scrollLeft: scrollLeft, rowStore: rowStore,
            rowStoreOperationCounters: counters, selection: selection,
            searchMatches: searchMatches, diagnosticUnderlines: diagnosticUnderlines,
            documentHighlights: documentHighlights, lineAnnotations: lineAnnotations,
            paneGeometry: paneGeometry, cursorline: cursorline,
            scrollPresentation: scrollPresentation, resourceWeight: resourceWeight
        )
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
            rowStore: rowStore,
            rowStoreOperationCounters: .init(),
            selection: selection,
            searchMatches: searchMatches,
            diagnosticUnderlines: diagnosticUnderlines,
            documentHighlights: documentHighlights,
            lineAnnotations: lineAnnotations,
            paneGeometry: paneGeometry,
            cursorline: delta.cursorline,
            scrollPresentation: scrollPresentation,
            resourceWeight: resourceWeight
        )
    }

    public func applyingRowsDelta(_ delta: GUIWindowRowsDelta) -> GUIWindowContent? {
        try? applyingRowsDeltaChecked(delta).get()
    }

    /// Exact ownership retained by this immutable window value in O(1).
    public func exactResourceWeight() -> FrameResourceWeight { resourceWeight }

    /// Applies A1/A2 entries directly to a COW store copy. References resolve
    /// through durable IDs; no second full resident-row array is materialized.
    public func applyingRowsDeltaChecked(
        _ delta: GUIWindowRowsDelta,
        residentLimit: FrameResourceWeight? = nil,
        stagingLimit: FrameResourceWeight? = nil
    ) -> Result<GUIWindowContent, ResidentRowStoreError> {
        let effectiveResidentLimit = residentLimit ?? FrameResourcePolicy.default.resident.weightPerWindow
        let effectiveStagingLimit = stagingLimit ?? FrameResourcePolicy.default.staging.weight
        guard delta.windowId == windowId, delta.contentEpoch == contentEpoch else {
            return .failure(.invalidRange(index: 0, removeCount: 0, rowCount: rowStore.count))
        }
        if delta.rowSplices != nil {
            return applyingRowSplices(
                delta, residentLimit: effectiveResidentLimit, stagingLimit: effectiveStagingLimit
            )
        }

        let stagingUsage = FrameResourceUsageBuilder(limit: effectiveStagingLimit)
        var sourceStore = rowStore
        var nextStore = rowStore
        do {
            // Validate the complete result against the immutable base using
            // identity/hash/order metadata only. Keeping metadata here avoids
            // constructing a second document-sized GUIVisualRow array.
            try stagingUsage.reserve(.arrayEntries, delta.rows.count)
            try stagingUsage.reserve(.arrayEntries, delta.rows.count)
            try stagingUsage.reserve(.rows, delta.rows.count)
            var metadata: [ResidentRowMetadata] = []
            metadata.reserveCapacity(delta.rows.count)
            var seenRowIDs = Set<UInt64>()
            seenRowIDs.reserveCapacity(delta.rows.count)
            var previousBufferLine: UInt32?

            for entry in delta.rows {
                sourceStore.recordRowsVisited(1)
                let item: ResidentRowMetadata
                switch entry {
                case .reference(let rowID, let contentHash):
                    item = try sourceStore.inspectReference(rowID: rowID, contentHash: contentHash)
                case .full(let row):
                    item = ResidentRowMetadata(
                        rowID: row.rowId,
                        contentHash: row.contentHash,
                        bufferLine: row.bufLine
                    )
                }

                guard seenRowIDs.insert(item.rowID).inserted else {
                    throw ResidentRowStoreError.duplicateRowID(item.rowID)
                }
                if let previousBufferLine, previousBufferLine > item.bufferLine {
                    throw ResidentRowStoreError.unsortedBufferLine(
                        previous: previousBufferLine,
                        next: item.bufferLine
                    )
                }
                previousBufferLine = item.bufferLine
                metadata.append(item)
            }

            // Identity plus content hash is the retained-reference wire contract.
            // Full entries remain authoritative for positional metadata such as
            // bufLine, so they are unchanged only when their payload also matches.
            var prefix = 0
            while prefix < min(rowStore.count, metadata.count) {
                sourceStore.recordRowsVisited(1)
                guard let base = rowStore.row(at: prefix),
                      base.rowId == metadata[prefix].rowID,
                      base.contentHash == metadata[prefix].contentHash else { break }
                if case .full(let row) = delta.rows[prefix], row != base { break }
                prefix += 1
            }

            var suffix = 0
            while suffix < rowStore.count - prefix, suffix < metadata.count - prefix {
                let baseIndex = rowStore.count - suffix - 1
                let finalIndex = metadata.count - suffix - 1
                sourceStore.recordRowsVisited(1)
                guard let base = rowStore.row(at: baseIndex),
                      base.rowId == metadata[finalIndex].rowID,
                      base.contentHash == metadata[finalIndex].contentHash else { break }
                if case .full(let row) = delta.rows[finalIndex], row != base { break }
                suffix += 1
            }

            let removedCount = rowStore.count - prefix - suffix
            let insertedEnd = metadata.count - suffix
            if removedCount > 0 || prefix < insertedEnd {
                try stagingUsage.reserve(.arrayEntries, insertedEnd - prefix)
                var insertedRows: [GUIVisualRow] = []
                insertedRows.reserveCapacity(insertedEnd - prefix)
                for entry in delta.rows[prefix..<insertedEnd] {
                    switch entry {
                    case .reference(let rowID, let contentHash):
                        insertedRows.append(try sourceStore.resolve(rowID: rowID, contentHash: contentHash))
                    case .full(let row):
                        insertedRows.append(row)
                    }
                }
                try nextStore.splice(
                    at: prefix, removeCount: removedCount, inserting: insertedRows,
                    limit: effectiveResidentLimit
                )
            }

            nextStore.recordStagingCounters(sourceStore.counters - rowStore.counters)
        } catch let error as ResidentRowStoreError {
            return .failure(error)
        } catch is FrameResourceError {
            return .failure(.resourcePolicy)
        } catch {
            return .failure(.invalidRange(index: 0, removeCount: 0, rowCount: rowStore.count))
        }

        let nextScrollPresentation = delta.scrollPresentation?.belongsTo(
            windowId: windowId, contentEpoch: contentEpoch
        ) == true ? delta.scrollPresentation : nil

        do {
            return .success(try content(
                afterApplying: delta, store: nextStore,
                scrollPresentation: nextScrollPresentation, residentLimit: effectiveResidentLimit
            ))
        } catch {
            return .failure(.resourcePolicy)
        }
    }

    private func applyingRowSplices(
        _ delta: GUIWindowRowsDelta,
        residentLimit: FrameResourceWeight,
        stagingLimit: FrameResourceWeight
    ) -> Result<GUIWindowContent, ResidentRowStoreError> {
        guard let baseRowCount = delta.baseRowCount,
              let resultRowCount = delta.resultRowCount,
              let wireSplices = delta.rowSplices else {
            return .failure(.invalidRange(index: 0, removeCount: 0, rowCount: rowStore.count))
        }

        let stagingUsage = FrameResourceUsageBuilder(limit: stagingLimit)
        var sourceStore = rowStore
        var resolvedSplices: [ResidentRowSplice] = []
        do {
            try stagingUsage.reserve(.arrayEntries, wireSplices.count)
            try stagingUsage.reserve(.spliceEntries, wireSplices.count)
            resolvedSplices.reserveCapacity(wireSplices.count)
            for splice in wireSplices {
                try stagingUsage.reserve(.arrayEntries, splice.insertEntries.count)
                try stagingUsage.reserve(.rows, splice.insertEntries.count)
                try stagingUsage.reserve(.locatorEntries, splice.insertEntries.count)
                var rows: [GUIVisualRow] = []
                rows.reserveCapacity(splice.insertEntries.count)
                for entry in splice.insertEntries {
                    sourceStore.recordRowsVisited(1)
                    switch entry {
                    case .reference(let rowID, let contentHash):
                        rows.append(try sourceStore.resolve(rowID: rowID, contentHash: contentHash))
                    case .full(let row):
                        rows.append(row)
                    }
                }
                resolvedSplices.append(ResidentRowSplice(
                    startIndex: Int(splice.startIndex),
                    deleteCount: Int(splice.deleteCount),
                    insertedRows: rows
                ))
            }

            var nextStore = rowStore
            try nextStore.applyBatch(
                resolvedSplices,
                baseRowCount: Int(baseRowCount),
                resultRowCount: Int(resultRowCount),
                limit: residentLimit
            )
            nextStore.recordStagingCounters(sourceStore.counters - rowStore.counters)
            let nextScroll = delta.scrollPresentation?.belongsTo(
                windowId: windowId, contentEpoch: contentEpoch
            ) == true ? delta.scrollPresentation : nil
            return .success(try content(
                afterApplying: delta, store: nextStore,
                scrollPresentation: nextScroll, residentLimit: residentLimit
            ))
        } catch let error as ResidentRowStoreError {
            return .failure(error)
        } catch is FrameResourceError {
            return .failure(.resourcePolicy)
        } catch {
            return .failure(.invalidRange(index: 0, removeCount: 0, rowCount: rowStore.count))
        }
    }

    private func content(
        afterApplying delta: GUIWindowRowsDelta, store: ResidentRowStore,
        scrollPresentation: GUIScrollPresentation?, residentLimit: FrameResourceWeight
    ) throws -> GUIWindowContent {
        let nextPaneGeometry = delta.paneGeometry ?? paneGeometry
        let resultingWeight = try Self.resourceWeight(
            rowWeight: store.resourceWeight, selection: delta.selection,
            searchMatches: delta.searchMatches,
            diagnosticUnderlines: delta.diagnosticUnderlines,
            documentHighlights: delta.documentHighlights,
            lineAnnotations: delta.lineAnnotations, paneGeometry: nextPaneGeometry
        )
        try Self.validate(resultingWeight, limit: residentLimit)
        return GUIWindowContent(
            windowId: windowId,
            fullRefresh: false,
            contentEpoch: contentEpoch,
            cursorVisible: delta.cursorVisible,
            cursorRow: delta.cursorRow,
            cursorCol: delta.cursorCol,
            cursorShape: delta.cursorShape,
            scrollLeft: delta.scrollLeft,
            rowStore: store,
            rowStoreOperationCounters: store.counters - rowStore.counters,
            selection: delta.selection,
            searchMatches: delta.searchMatches,
            diagnosticUnderlines: delta.diagnosticUnderlines,
            documentHighlights: delta.documentHighlights,
            lineAnnotations: delta.lineAnnotations,
            paneGeometry: nextPaneGeometry,
            cursorline: delta.cursorline,
            scrollPresentation: scrollPresentation,
            resourceWeight: resultingWeight
        )
    }

    private static func resourceWeight(
        rowWeight: FrameResourceWeight, selection: GUISelectionOverlay?,
        searchMatches: [GUISearchMatch],
        diagnosticUnderlines: [GUIDiagnosticUnderline],
        documentHighlights: [GUIDocumentHighlight],
        lineAnnotations: [GUILineAnnotation], paneGeometry: GUIPaneGeometry?
    ) throws -> FrameResourceWeight {
        let overlayCount = try [
            searchMatches.count, diagnosticUnderlines.count, documentHighlights.count,
            lineAnnotations.count, selection == nil ? 0 : 1
        ].reduce(into: 0) { total, count in
            let (next, overflow) = total.addingReportingOverflow(count)
            guard !overflow else { throw FrameResourceError.arithmeticOverflow }
            total = next
        }
        let hitRegionCount = paneGeometry?.hitRegions.count ?? 0
        let (arrayEntries, arrayOverflow) = overlayCount.addingReportingOverflow(hitRegionCount)
        guard !arrayOverflow else { throw FrameResourceError.arithmeticOverflow }
        let annotationBytes = try lineAnnotations.reduce(into: 0) { total, annotation in
            let (next, overflow) = total.addingReportingOverflow(annotation.text.utf8.count)
            guard !overflow else { throw FrameResourceError.arithmeticOverflow }
            total = next
        }
        return try rowWeight.adding(FrameResourceWeight(
            ownedUTF8Bytes: annotationBytes,
            arrayEntries: arrayEntries,
            overlays: overlayCount
        ))
    }

    private static func validate(
        _ weight: FrameResourceWeight, limit: FrameResourceWeight
    ) throws {
        guard let dimension = weight.firstExceeded(limit: limit) else { return }
        throw FrameResourceError.limitExceeded(
            dimension: dimension, used: 0, requested: weight.value(dimension),
            limit: limit.value(dimension)
        )
    }
}
