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
        let store = content.rowStore
        let visibleStart: Int
        let visibleEnd: Int

        if let presentation = content.scrollPresentation {
            let indexedStart = store.lowerBound(bufferLine: presentation.visibleStartLine)
            let anchorStart = store.lowerBound(bufferLine: presentation.anchorTop)
            let anchoredVisualStart = min(
                anchorStart + Int(presentation.anchorVisualRowOffset),
                store.count
            )
            visibleStart = anchoredVisualStart < store.count ? anchoredVisualStart : min(indexedStart, store.count)
            let indexedEnd = store.lowerBound(bufferLine: presentation.visibleEndLine)
            visibleEnd = max(indexedEnd, min(visibleStart + fallbackVisibleRows, store.count))
        } else {
            visibleStart = 0
            visibleEnd = min(fallbackVisibleRows, store.count)
        }

        let lower = max(visibleStart - max(overscanRows, 0), 0)
        let upper = min(max(visibleEnd, visibleStart) + max(overscanRows, 0), store.count)
        let result = store.rows(in: lower..<upper)
        return RendererRowSlice(
            range: lower..<upper,
            rows: result.rows,
            visibleStartIndex: visibleStart,
            overscanBeforeRows: visibleStart - lower,
            counters: result.counters
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

    static func record(_ counters: ResidentRowStoreCounters, in metrics: inout FrameMetrics) {
        metrics.residentRowsVisited += counters.rowsVisited
        metrics.residentChunksTouched += counters.chunksTouched
        metrics.residentIDsResolved += counters.idsResolved
        metrics.residentSplices += counters.splices
        metrics.residentChangedRowsValidated += counters.changedRowsValidated
        metrics.residentLocatorNodesCopied += counters.locatorNodesCopied
        metrics.residentFullResets += counters.fullResets
    }
}
