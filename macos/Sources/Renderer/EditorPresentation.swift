import Foundation
import MingaProtocol
import MingaUI

/// Immutable gutter state owned by one committed editor surface.
enum GutterPresentation: Sendable {
    case none
    case present(Wire.WindowGutter)

    var gutter: Wire.WindowGutter? {
        switch self {
        case .none: nil
        case .present(let gutter): gutter
        }
    }
}

/// One complete editor pane surface captured at transaction publication.
struct PresentedWindowSurface: Sendable {
    let content: GUIWindowContent
    let gutter: GutterPresentation
    let paneGeometry: GUIPaneGeometry
    let indentGuides: IndentGuideData?

    var windowId: UInt16 { content.windowId }

    /// Renderer compatibility projection for code that needs a concrete gutter geometry value.
    /// `.none` stays semantic in the snapshot; this value is derived only after freeze accepted explicit zero-width gutter geometry.
    var renderGutter: Wire.WindowGutter {
        switch gutter {
        case .present(let gutter):
            gutter
        case .none:
            Wire.WindowGutter(
                windowId: windowId,
                contentRow: paneGeometry.textRect.row,
                contentCol: paneGeometry.textRect.col,
                contentHeight: paneGeometry.textRect.height,
                isActive: activeByGeometry,
                contentWidth: paneGeometry.textRect.width,
                cursorLine: UInt32(content.cursorRow),
                lineNumberStyle: .absolute,
                lineNumberWidth: 0,
                signColWidth: 0,
                entries: []
            )
        }
    }

    var visibleRowRange: Range<Int> {
        let viewport = paneGeometry.viewport
        let start = content.rowStore.lowerBound(bufferLine: viewport.top) + Int(viewport.visualRowOffset)
        let end = start + Int(viewport.rows)
        return min(start, content.rowStore.count)..<min(max(end, start), content.rowStore.count)
    }

    private var activeByGeometry: Bool { false }
}

/// Complete semantic editor presentation captured once by Metal and input geometry consumers.
struct CommittedEditorSnapshot {
    let generation: UInt32
    let frameSeq: UInt32
    let frameState: FrameState
    let themeColors: ThemeColors?
    let surfaces: [PresentedWindowSurface]
    let activeWindowId: UInt16?

    var windowContents: [UInt16: GUIWindowContent] {
        Dictionary(uniqueKeysWithValues: surfaces.map { ($0.windowId, $0.content) })
    }

    var windowGutters: [UInt16: Wire.WindowGutter] {
        Dictionary(uniqueKeysWithValues: surfaces.compactMap { surface in
            surface.gutter.gutter.map { (surface.windowId, $0) }
        })
    }

    var windowIndentGuides: [UInt16: IndentGuideData] {
        Dictionary(uniqueKeysWithValues: surfaces.compactMap { surface in
            surface.indentGuides.map { (surface.windowId, $0) }
        })
    }

    var windowIds: Set<UInt16> { Set(surfaces.map(\.windowId)) }

    func content(for windowId: UInt16) -> GUIWindowContent? {
        surfaces.first { $0.windowId == windowId }?.content
    }

    func surface(for windowId: UInt16) -> PresentedWindowSurface? {
        surfaces.first { $0.windowId == windowId }
    }

    static func make(
        generation: UInt32,
        frameSeq: UInt32,
        frameState: FrameState,
        themeColors: ThemeColors?,
        windowContents: [UInt16: GUIWindowContent]
    ) -> Result<CommittedEditorSnapshot, PreparedFrameRejection> {
        var surfaces: [PresentedWindowSurface] = []
        surfaces.reserveCapacity(windowContents.count)

        for content in windowContents.values.sorted(by: { $0.windowId < $1.windowId }) {
            guard let paneGeometry = content.paneGeometry else {
                return .failure(.missingWindowGeometry(windowId: content.windowId))
            }

            let gutterPresentation: GutterPresentation
            if let gutter = frameState.windowGutters[content.windowId] {
                guard gutter.contentRow == paneGeometry.textRect.row,
                      gutter.contentCol == paneGeometry.textRect.col,
                      gutter.contentHeight == paneGeometry.textRect.height,
                      gutter.contentWidth == paneGeometry.textRect.width,
                      gutter.lineNumberWidth == paneGeometry.gutterMetrics.lineNumberWidth,
                      gutter.signColWidth == paneGeometry.gutterMetrics.signColWidth else {
                    return .failure(.incompatibleWindowGeometry(windowId: content.windowId))
                }
                gutterPresentation = .present(gutter)
            } else if paneGeometry.gutterMetrics.lineNumberWidth == 0,
                      paneGeometry.gutterMetrics.signColWidth == 0,
                      !paneGeometry.hitRegions.contains(where: { $0.kind == .gutter || $0.kind == .foldControl }) {
                gutterPresentation = .none
            } else {
                return .failure(.missingWindowGutter(windowId: content.windowId))
            }

            surfaces.append(PresentedWindowSurface(
                content: content,
                gutter: gutterPresentation,
                paneGeometry: paneGeometry,
                indentGuides: frameState.windowIndentGuides[content.windowId]
            ))
        }

        if let activeWindowId = frameState.activeWindowId,
           !windowContents.keys.contains(activeWindowId) {
            return .failure(.invalidActiveWindow(windowId: activeWindowId))
        }

        return .success(CommittedEditorSnapshot(
            generation: generation,
            frameSeq: frameSeq,
            frameState: frameState,
            themeColors: themeColors,
            surfaces: surfaces,
            activeWindowId: frameState.activeWindowId
        ))
    }
}
