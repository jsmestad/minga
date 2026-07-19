import Foundation
import MingaProtocol
import MingaUI

/// Frontend-local transform captured with the Metal draw that produced a visible editor frame.
struct EditorLocalPresentationTransform: Sendable, Equatable {
    let windowId: UInt16
    let offset: CGPoint
}

/// One editor presentation known to have reached the display surface.
struct VisibleEditorPresentation: Sendable {
    let snapshot: CommittedEditorSnapshot
    let localTransform: EditorLocalPresentationTransform?
}

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

    var isActive: Bool {
        switch self {
        case .none: false
        case .present(let gutter): gutter.isActive
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
                isActive: false,
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

    var cursorLineOffset: Int {
        Int(content.cursorRow) * Int(paneGeometry.viewport.cols) + Int(content.cursorCol)
    }
}

/// Complete semantic editor presentation captured once by Metal and input geometry consumers.
struct CommittedEditorSnapshot {
    let generation: UInt32
    let frameSeq: UInt32
    let frameState: FrameState
    let themeColors: ThemeColors?
    let surfaces: [PresentedWindowSurface]
    let activeWindowId: UInt16?

    var activeSurface: PresentedWindowSurface? {
        if let activeWindowId, let surface = surface(for: activeWindowId) { return surface }
        if let active = surfaces.first(where: { $0.gutter.isActive }) { return active }
        let cursorVisibleSurfaces = surfaces.filter(\.content.cursorVisible)
        if cursorVisibleSurfaces.count == 1 { return cursorVisibleSurfaces[0] }
        return surfaces.first
    }

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
        windowContents: [UInt16: GUIWindowContent],
        windowGutters: [UInt16: Wire.WindowGutter],
        windowIndentGuides: [UInt16: IndentGuideData]
    ) -> Result<CommittedEditorSnapshot, PreparedFrameRejection> {
        var surfaces: [PresentedWindowSurface] = []
        surfaces.reserveCapacity(windowContents.count)

        for content in windowContents.values.sorted(by: { $0.windowId < $1.windowId }) {
            guard let paneGeometry = content.paneGeometry else {
                return .failure(.missingWindowGeometry(windowId: content.windowId))
            }

            let gutterPresentation: GutterPresentation
            if let gutter = windowGutters[content.windowId] {
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
                indentGuides: windowIndentGuides[content.windowId]
            ))
        }

        let activeGutters = windowGutters.values.filter(\.isActive)
        if activeGutters.count > 1 {
            return .failure(.invalidActiveWindow(windowId: activeGutters.sorted(by: { $0.windowId < $1.windowId })[1].windowId))
        }
        let activeWindowId = activeGutters.first?.windowId
        if let activeWindowId, !windowContents.keys.contains(activeWindowId) {
            return .failure(.invalidActiveWindow(windowId: activeWindowId))
        }

        return .success(CommittedEditorSnapshot(
            generation: generation,
            frameSeq: frameSeq,
            frameState: frameState,
            themeColors: themeColors,
            surfaces: surfaces,
            activeWindowId: activeWindowId
        ))
    }
}
