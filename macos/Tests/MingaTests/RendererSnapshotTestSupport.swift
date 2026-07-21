import Foundation
import QuartzCore
import MingaProtocol
import MingaUI
import Testing

@MainActor
func rendererSnapshot(
    generation: UInt32 = 1,
    frameSeq: UInt32 = 1,
    frameState: FrameState,
    themeColors: ThemeColors? = nil,
    windowContents: [UInt16: GUIWindowContent]
) -> CommittedEditorSnapshot {
    let normalizedContents = Dictionary(uniqueKeysWithValues: windowContents.map { windowId, content in
        (windowId, normalizedRendererContent(content, frameState: frameState))
    })

    switch CommittedEditorSnapshot.make(
        generation: generation,
        frameSeq: frameSeq,
        frameState: frameState,
        themeColors: themeColors,
        windowContents: normalizedContents,
        windowGutters: frameState.windowGutters,
        windowIndentGuides: frameState.windowIndentGuides
    ) {
    case .success(let snapshot):
        return snapshot
    case .failure(let rejection):
        let message = "Invalid renderer snapshot fixture: \(String(describing: rejection.logDescription))"
        Issue.record(Comment(rawValue: message))
        fatalError(message)
    }
}

private func normalizedRendererContent(_ content: GUIWindowContent, frameState: FrameState) -> GUIWindowContent {
    guard content.paneGeometry == nil,
          let gutter = frameState.windowGutters[content.windowId] else { return content }

    let geometry = rendererPaneGeometry(windowId: content.windowId, gutter: gutter, frameState: frameState)
    let rows = content.rows.map(GUIWindowRowDeltaEntry.full)
    let delta = GUIWindowRowsDelta(
        windowId: content.windowId,
        contentEpoch: content.contentEpoch,
        cursorVisible: content.cursorVisible,
        cursorRow: content.cursorRow,
        cursorCol: content.cursorCol,
        cursorShape: content.cursorShape,
        scrollLeft: content.scrollLeft,
        rows: rows,
        selection: content.selection,
        searchMatches: content.searchMatches,
        diagnosticUnderlines: content.diagnosticUnderlines,
        documentHighlights: content.documentHighlights,
        lineAnnotations: content.lineAnnotations,
        paneGeometry: geometry,
        cursorline: content.cursorline,
        scrollPresentation: content.scrollPresentation
    )
    return content.applyingRowsDelta(delta) ?? content
}

private func rendererPaneGeometry(windowId: UInt16, gutter: Wire.WindowGutter, frameState: FrameState) -> GUIPaneGeometry {
    let gutterWidth = min(UInt16(gutter.lineNumberWidth) + UInt16(gutter.signColWidth), gutter.contentWidth)
    let totalRect = GUICellRect(row: gutter.contentRow, col: gutter.contentCol, width: max(gutter.contentWidth, 1), height: gutter.contentHeight)
    let textRect = GUICellRect(row: gutter.contentRow, col: gutter.contentCol + gutterWidth, width: gutter.contentWidth - gutterWidth, height: gutter.contentHeight)
    let gutterRect = GUICellRect(row: gutter.contentRow, col: gutter.contentCol, width: gutterWidth, height: gutter.contentHeight)
    let viewportRows = gutter.contentHeight == 0 ? frameState.rows : gutter.contentHeight
    let totalLines = max(frameState.totalLineCount, UInt32(viewportRows))
    let hitRegions = gutterWidth == 0 ? [] : [GUIHitRegion(kind: .gutter, rect: gutterRect, windowId: windowId)]

    return GUIPaneGeometry(
        windowId: windowId,
        totalRect: totalRect,
        contentRect: totalRect,
        textRect: textRect,
        gutterRect: gutterRect,
        clipRect: totalRect,
        viewport: GUIViewportSummary(top: 0, left: 0, rows: viewportRows, cols: textRect.width, totalLines: totalLines, visualRowOffset: 0, totalVisualRows: totalLines),
        gutterMetrics: GUIGutterMetrics(lineNumberWidth: UInt16(gutter.lineNumberWidth), signColWidth: UInt16(gutter.signColWidth)),
        hitRegions: hitRegions
    )
}

extension CoreTextMetalRenderer {
    @MainActor
    func render(
        frameState: FrameState,
        fontManager: FontManager,
        cursorBlinkVisible: Bool = true,
        windowContents: [UInt16: GUIWindowContent] = [:],
        themeColors: ThemeColors? = nil,
        isMouseInGutter: Bool = false,
        gutterHoverWindowId: UInt16? = nil,
        gutterHoverRow: UInt16? = nil,
        drawableProvider: @escaping @MainActor () -> CAMetalDrawable?,
        viewportSize: CGSize,
        contentScale: Float,
        scrollOffset: SIMD2<Float> = .zero,
        presentationWindowId: UInt16? = nil,
        presentationInputSeq: UInt32 = 0,
        presentationFrame: GUICommittedFrame? = nil,
        latencyRecorder: LatencyRecorder? = nil,
        onPresented: @escaping @MainActor (CommittedEditorSnapshot) -> Void = { _ in }
    ) {
        let snapshot = rendererSnapshot(
            generation: presentationFrame?.generation ?? 1,
            frameSeq: presentationFrame?.frameSeq ?? presentationInputSeq,
            frameState: frameState,
            themeColors: themeColors,
            windowContents: windowContents
        )
        render(
            snapshot: snapshot,
            fontManager: fontManager,
            cursorBlinkVisible: cursorBlinkVisible,
            isMouseInGutter: isMouseInGutter,
            gutterHoverWindowId: gutterHoverWindowId,
            gutterHoverRow: gutterHoverRow,
            drawableProvider: drawableProvider,
            viewportSize: viewportSize,
            contentScale: contentScale,
            scrollOffset: scrollOffset,
            presentationWindowId: presentationWindowId,
            presentationInputSeq: presentationInputSeq,
            latencyRecorder: latencyRecorder,
            onPresented: onPresented
        )
    }
}
