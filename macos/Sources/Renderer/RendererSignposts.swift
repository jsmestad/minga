import MingaProtocol

/// Deterministic resident-row work recorded at the renderer boundary.
struct RendererRowSlice: Sendable, Equatable {
    let range: Range<Int>
    let rows: [GUIVisualRow]
    let visibleStartIndex: Int
    let overscanBeforeRows: Int
    let counters: ResidentRowStoreCounters
}

/// Shared instrumentation and test seam for bounded renderer row preparation.
enum RendererSignposts {
    static let configuredOverscanRows = 2

    /// Selects only visible rows plus fixed visual-row overscan.
    static func visibleSlice(
        for content: GUIWindowContent,
        fallbackVisibleRows: Int,
        overscanRows: Int = configuredOverscanRows
    ) -> RendererRowSlice {
        let prepared = ResidentRenderPreparation.prepare(
            content: content,
            fallbackVisibleRows: fallbackVisibleRows,
            overscanRows: overscanRows
        )
        return rowSlice(for: prepared)
    }

    /// Adapts shared preparation output for gutter and atlas range consumers
    /// without traversing the resident store again.
    static func rowSlice(for prepared: ResidentRenderPreparationResult) -> RendererRowSlice {
        RendererRowSlice(
            range: prepared.range,
            rows: prepared.rows,
            visibleStartIndex: prepared.visibleStartIndex,
            overscanBeforeRows: prepared.overscanBeforeRows,
            counters: prepared.counters
        )
    }

    /// Returns staging work once for each immutable content value. Reusing the
    /// same value on an idle frame therefore reports zero reset/reference work.
    static func operationCounters(
        for content: GUIWindowContent,
        lastContentIdentities: inout [UInt16: ObjectIdentifier]
    ) -> ResidentRowStoreCounters {
        let identity = ObjectIdentifier(content)
        guard lastContentIdentities[content.windowId] != identity else { return .init() }
        lastContentIdentities[content.windowId] = identity
        return content.rowStoreOperationCounters
    }

    /// Gutter entries share the exact resident range and row origin selected
    /// for content. The returned range is bounded without scanning entries.
    static func gutterRange(for gutter: Wire.WindowGutter, slice: RendererRowSlice) -> Range<Int> {
        let lower = min(max(slice.range.lowerBound, 0), gutter.entries.count)
        let upper = min(max(slice.range.upperBound, lower), gutter.entries.count)
        return lower..<upper
    }

    /// Records visible-range traversal separately from semantic update work.
    static func recordVisibleSlice(_ slice: RendererRowSlice, in metrics: inout FrameMetrics) {
        metrics.editorRowsVisited += slice.counters.rowsVisited
    }

    /// Counts overlay records the renderer's decoration passes traverse.
    static func decorationCount(for content: GUIWindowContent) -> Int {
        ResidentRenderPreparation.decorationCount(content: content)
    }

    static func recordOperation(_ counters: ResidentRowStoreCounters, in metrics: inout FrameMetrics) {
        metrics.residentRowsVisited += counters.rowsVisited
        metrics.residentChunksTouched += counters.chunksTouched
        metrics.residentIDsResolved += counters.idsResolved
        metrics.residentSplices += counters.splices
        metrics.residentChangedRowsValidated += counters.changedRowsValidated
        metrics.residentLocatorNodesCopied += counters.locatorNodesCopied
        metrics.residentFullResets += counters.fullResets
    }
}
