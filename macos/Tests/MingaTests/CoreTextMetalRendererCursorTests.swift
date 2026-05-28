/// Tests for CoreTextMetalRenderer cursor coordinate selection.

import Testing
import Foundation
import QuartzCore

@Suite("CoreTextMetalRenderer cursor geometry")
struct CoreTextMetalRendererCursorTests {
    @Test("semantic window cursor overrides legacy frameState cursor")
    func semanticCursorOverridesLegacyCursor() {
        let cellW: Float = 7.5
        let displayCellH: Float = 16.0
        let scale: Float = 2.0
        let gutterLeft: Float = 3.0
        let gutterPadding: Float = 5.0

        var frameState = FrameState(cols: 80, rows: 24)
        frameState.cursorRow = 20
        frameState.cursorCol = 70
        frameState.cursorShape = .block
        frameState.windowGutters[2] = Wire.WindowGutter(
            windowId: 2, contentRow: 4, contentCol: 1, contentHeight: 20,
            isActive: true, contentWidth: 80, cursorLine: 10, lineNumberStyle: .hybrid,
            lineNumberWidth: 4, signColWidth: 1, entries: []
        )

        let content = GUIWindowContent(
            windowId: 2, fullRefresh: true,
            cursorRow: 2, cursorCol: 10, cursorShape: .beam,
            scrollLeft: 3,
            rows: [], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: []
        )

        let cursor = CoreTextMetalRenderer.resolveCursor(
            frameState: frameState,
            windowContents: [2: content],
            cellW: cellW,
            displayCellH: displayCellH,
            scale: scale,
            gutterLeftMarginPx: gutterLeft,
            gutterPaddingPx: gutterPadding
        )

        let contentColOffset = (Float(1 + 4 + 1) * cellW * scale) + gutterLeft + gutterPadding
        let expectedX = contentColOffset + Float(10 - 3) * cellW * scale
        let expectedY = Float(4 + 2) * displayCellH * scale

        #expect(cursor?.shape == .beam)
        #expect(cursor?.windowId == 2)
        #expect(abs((cursor?.x ?? 0) - expectedX) < 0.001)
        #expect(abs((cursor?.y ?? 0) - expectedY) < 0.001)
    }

    @Test("smooth scroll offset applies only to its target window")
    func smoothScrollOffsetAppliesOnlyToTargetWindow() {
        let offset = SIMD2<Float>(0, 7)

        #expect(CoreTextMetalRenderer.smoothScrollOffset(for: 2, targetWindowId: 2, scrollOffsetPx: offset) == offset)
        #expect(CoreTextMetalRenderer.smoothScrollOffset(for: 1, targetWindowId: 2, scrollOffsetPx: offset) == .zero)
        #expect(CoreTextMetalRenderer.smoothScrollOffset(for: 2, targetWindowId: nil, scrollOffsetPx: offset) == .zero)
        #expect(CoreTextMetalRenderer.smoothScrollOffset(for: nil, targetWindowId: 2, scrollOffsetPx: offset) == .zero)
    }

    @Test("cursorline smooth scroll offset stays disabled without an owning window id")
    func cursorlineSmoothScrollOffsetStaysDisabledWithoutOwningWindowId() {
        let offset = SIMD2<Float>(0, 7)

        #expect(CoreTextMetalRenderer.smoothScrollOffset(for: nil, targetWindowId: 1, scrollOffsetPx: offset) == .zero)
    }

    @Test("split panes use per-window text width for semantic clipping")
    func splitPanesUsePerWindowTextWidthForSemanticClipping() {
        let gutter = Wire.WindowGutter(
            windowId: 1, contentRow: 0, contentCol: 0, contentHeight: 20,
            isActive: true, contentWidth: 40, cursorLine: 3, lineNumberStyle: .hybrid,
            lineNumberWidth: 4, signColWidth: 1, entries: []
        )

        #expect(CoreTextMetalRenderer.visibleTextCols(
            gutter: gutter,
            frameCols: 100,
            cellW: 8,
            scale: 2,
            gutterLeftMarginPx: 0,
            gutterPaddingPx: 0
        ) == 35)
    }

    @Test("cursorline is clipped to the active split pane")
    func cursorlineIsClippedToActiveSplitPane() {
        let gutters: [UInt16: Wire.WindowGutter] = [
            1: Wire.WindowGutter(
                windowId: 1, contentRow: 0, contentCol: 0, contentHeight: 20,
                isActive: true, contentWidth: 40, cursorLine: 3, lineNumberStyle: .hybrid,
                lineNumberWidth: 4, signColWidth: 1, entries: []
            ),
            2: Wire.WindowGutter(
                windowId: 2, contentRow: 0, contentCol: 41, contentHeight: 20,
                isActive: false, contentWidth: 39, cursorLine: 3, lineNumberStyle: .hybrid,
                lineNumberWidth: 4, signColWidth: 1, entries: []
            )
        ]

        let bounds = CoreTextMetalRenderer.cursorlineHorizontalBounds(
            row: 5,
            gutters: gutters,
            frameCols: 80,
            cellW: 8,
            scale: 2,
            viewportWidth: 1_600
        )

        #expect(bounds.x == 0)
        #expect(bounds.width == 640)
    }

    @Test("smooth scroll target requires content column even for one row match")
    func smoothScrollTargetRequiresContentColumnForSingleRowMatch() {
        let gutters: [UInt16: Wire.WindowGutter] = [
            1: Wire.WindowGutter(
                windowId: 1, contentRow: 0, contentCol: 10, contentHeight: 20,
                isActive: true, contentWidth: 30, cursorLine: 3, lineNumberStyle: .hybrid,
                lineNumberWidth: 4, signColWidth: 1, entries: []
            )
        ]

        #expect(EditorNSView.smoothScrollTargetWindowId(row: 5, col: 9, windowGutters: gutters) == nil)
        #expect(EditorNSView.smoothScrollTargetWindowId(row: 5, col: 10, windowGutters: gutters) == 1)
        #expect(EditorNSView.smoothScrollTargetWindowId(row: 5, col: 40, windowGutters: gutters) == nil)
    }

    @Test("smooth scroll target chooses rightmost content hit for split panes")
    func smoothScrollTargetChoosesRightmostContentHitForSplitPanes() {
        let gutters: [UInt16: Wire.WindowGutter] = [
            1: Wire.WindowGutter(
                windowId: 1, contentRow: 0, contentCol: 0, contentHeight: 20,
                isActive: false, contentWidth: 40, cursorLine: 3, lineNumberStyle: .hybrid,
                lineNumberWidth: 4, signColWidth: 1, entries: []
            ),
            2: Wire.WindowGutter(
                windowId: 2, contentRow: 0, contentCol: 40, contentHeight: 20,
                isActive: true, contentWidth: 40, cursorLine: 3, lineNumberStyle: .hybrid,
                lineNumberWidth: 4, signColWidth: 1, entries: []
            )
        ]

        #expect(EditorNSView.smoothScrollTargetWindowId(row: 5, col: 39, windowGutters: gutters) == 1)
        #expect(EditorNSView.smoothScrollTargetWindowId(row: 5, col: 40, windowGutters: gutters) == 2)
        #expect(EditorNSView.smoothScrollTargetWindowId(row: -1, col: 40, windowGutters: gutters) == nil)
    }

    @Test("semantic block cursor at end of line renders over final character")
    func semanticBlockCursorAtEndOfLineUsesFinalCharacterCell() {
        let content = GUIWindowContent(
            windowId: 1, fullRefresh: true,
            cursorRow: 0, cursorCol: 4, cursorShape: .block,
            rows: [GUIVisualRow(rowType: .normal, bufLine: 0, contentHash: 1, text: "this", spans: [])],
            selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: []
        )

        #expect(CoreTextMetalRenderer.resolvedSemanticCursorCol(content) == 3)
    }

    @Test("semantic beam cursor at end of line keeps insertion point column")
    func semanticBeamCursorAtEndOfLineKeepsInsertionPointColumn() {
        let content = GUIWindowContent(
            windowId: 1, fullRefresh: true,
            cursorRow: 0, cursorCol: 4, cursorShape: .beam,
            rows: [GUIVisualRow(rowType: .normal, bufLine: 0, contentHash: 1, text: "this", spans: [])],
            selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: []
        )

        #expect(CoreTextMetalRenderer.resolvedSemanticCursorCol(content) == 4)
    }

    @Test("semantic block cursor uses display width for wide characters")
    func semanticBlockCursorUsesDisplayWidthForWideCharacters() {
        let content = GUIWindowContent(
            windowId: 1, fullRefresh: true,
            cursorRow: 0, cursorCol: 2, cursorShape: .block,
            rows: [GUIVisualRow(rowType: .normal, bufLine: 0, contentHash: 1, text: "界", spans: [])],
            selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: []
        )

        #expect(CoreTextMetalRenderer.resolvedSemanticCursorCol(content) == 1)
    }

    @Test("legacy cursor is used when semantic content is unavailable")
    func legacyCursorFallback() {
        let cellW: Float = 7.5
        let displayCellH: Float = 16.0
        let scale: Float = 2.0
        let gutterLeft: Float = 3.0
        let gutterPadding: Float = 5.0

        var frameState = FrameState(cols: 80, rows: 24)
        frameState.cursorRow = 3
        frameState.cursorCol = 10
        frameState.cursorShape = .underline
        frameState.gutterCol = 5

        let cursor = CoreTextMetalRenderer.resolveCursor(
            frameState: frameState,
            windowContents: [:],
            cellW: cellW,
            displayCellH: displayCellH,
            scale: scale,
            gutterLeftMarginPx: gutterLeft,
            gutterPaddingPx: gutterPadding
        )

        let expectedX = Float(10) * cellW * scale + gutterLeft + gutterPadding
        let expectedY = Float(3) * displayCellH * scale

        #expect(cursor?.shape == .underline)
        #expect(abs((cursor?.x ?? 0) - expectedX) < 0.001)
        #expect(abs((cursor?.y ?? 0) - expectedY) < 0.001)
    }

    @Test("cursor animation progress clamps to timeline bounds")
    func cursorAnimationProgressClamps() {
        #expect(CoreTextMetalRenderer.cursorAnimationProgress(now: 0.0, startTime: 1.0, duration: 0.08) == 0.0)
        #expect(CoreTextMetalRenderer.cursorAnimationProgress(now: 1.04, startTime: 1.0, duration: 0.08) == 0.5)
        #expect(CoreTextMetalRenderer.cursorAnimationProgress(now: 1.2, startTime: 1.0, duration: 0.08) == 1.0)
    }

    @Test("cursor animation uses cubic ease-out interpolation")
    func cursorAnimationUsesCubicEaseOut() {
        let start = RenderCursor(x: 0, y: 0, shape: .block)
        let target = RenderCursor(x: 100, y: 40, shape: .beam)

        let atStart = CoreTextMetalRenderer.interpolateCursor(start: start, target: target, progress: 0)
        let halfway = CoreTextMetalRenderer.interpolateCursor(start: start, target: target, progress: 0.5)
        let atEnd = CoreTextMetalRenderer.interpolateCursor(start: start, target: target, progress: 1)

        #expect(atStart == RenderCursor(x: 0, y: 0, shape: .beam))
        #expect(abs(halfway.x - 87.5) < 0.001)
        #expect(abs(halfway.y - 35.0) < 0.001)
        #expect(atEnd == target)
    }

    @Test("first cursor render snaps without animating from origin")
    @MainActor func firstCursorRenderSnapsWithoutAnimatingFromOrigin() {
        guard let renderer = CoreTextMetalRenderer() else { return }
        let first = RenderCursor(x: 120, y: 64, shape: .beam)

        let rendered = renderer.animatedCursor(for: first, teleportLineThresholdPx: 1_000)

        #expect(rendered == first)
        #expect(renderer.cursorAnimating == false)
        #expect(renderer.cursorAnimationGeneration == 0)
    }

    @Test("small cursor move starts and completes animation")
    @MainActor func smallCursorMoveStartsAndCompletesAnimation() {
        guard let renderer = CoreTextMetalRenderer() else { return }
        let start = RenderCursor(x: 10, y: 10, shape: .block)
        let target = RenderCursor(x: 20, y: 20, shape: .beam)

        _ = renderer.animatedCursor(for: start, teleportLineThresholdPx: 1_000)
        let firstAnimatedFrame = renderer.animatedCursor(for: target, teleportLineThresholdPx: 1_000)

        #expect(firstAnimatedFrame?.shape == .beam)
        #expect(renderer.cursorAnimating == true)
        #expect(renderer.cursorAnimationGeneration == 1)

        let completed = renderer.updateCursorAnimation(now: CACurrentMediaTime() + 1.0)

        #expect(completed == target)
        #expect(renderer.cursorAnimating == false)
    }

    @Test("disabled cursor animation snaps to new target")
    @MainActor func disabledCursorAnimationSnapsToNewTarget() {
        guard let renderer = CoreTextMetalRenderer() else { return }
        let start = RenderCursor(x: 10, y: 10, shape: .block)
        let target = RenderCursor(x: 20, y: 20, shape: .beam)

        _ = renderer.animatedCursor(for: start, teleportLineThresholdPx: 1_000)
        renderer.setCursorAnimateConfigEnabled(false)
        let rendered = renderer.animatedCursor(for: target, teleportLineThresholdPx: 1_000)

        #expect(rendered == target)
        #expect(renderer.cursorAnimateEnabled == false)
        #expect(renderer.cursorAnimating == false)
        #expect(renderer.updateCursorAnimation() == target)
    }

    @Test("Reduce Motion override snaps even when config enables animation")
    @MainActor func reduceMotionOverrideSnapsWhenConfigEnablesAnimation() {
        guard let renderer = CoreTextMetalRenderer() else { return }
        let start = RenderCursor(x: 10, y: 10, shape: .block)
        let target = RenderCursor(x: 20, y: 20, shape: .beam)

        renderer.setCursorAnimateConfigEnabled(true)
        _ = renderer.animatedCursor(for: start, teleportLineThresholdPx: 1_000)
        renderer.setCursorAnimationReduceMotionDisabled(true)
        let rendered = renderer.animatedCursor(for: target, teleportLineThresholdPx: 1_000)

        #expect(rendered == target)
        #expect(renderer.cursorAnimateEnabled == false)
        #expect(renderer.cursorAnimating == false)
        #expect(renderer.updateCursorAnimation() == target)
    }

    @Test("large vertical cursor jumps teleport instead of animating")
    @MainActor func largeVerticalCursorJumpsTeleport() {
        guard let renderer = CoreTextMetalRenderer() else { return }
        let start = RenderCursor(x: 10, y: 10, shape: .block)
        let farTarget = RenderCursor(x: 10, y: 2_000, shape: .block)

        _ = renderer.animatedCursor(for: start, teleportLineThresholdPx: 100)
        let rendered = renderer.animatedCursor(for: farTarget, teleportLineThresholdPx: 100)

        #expect(rendered == farTarget)
        #expect(renderer.cursorAnimating == false)
        #expect(renderer.cursorAnimationGeneration == 0)
    }

    @Test("hidden semantic cursor suppresses legacy fallback after dispatcher sync")
    @MainActor func hiddenSemanticCursorSuppressesFallback() {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 80, rows: 24, guiState: gui)
        dispatcher.frameState.cursorRow = 3
        dispatcher.frameState.cursorCol = 10
        dispatcher.frameState.cursorShape = .block
        dispatcher.frameState.windowGutters[1] = Wire.WindowGutter(
            windowId: 1, contentRow: 0, contentCol: 0, contentHeight: 24,
            isActive: true, contentWidth: 80, cursorLine: 1, lineNumberStyle: .hybrid,
            lineNumberWidth: 4, signColWidth: 1, entries: []
        )

        let content = GUIWindowContent(
            windowId: 1, fullRefresh: true, cursorVisible: false,
            cursorRow: 0, cursorCol: 0, cursorShape: .beam,
            rows: [], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: []
        )
        dispatcher.dispatch(.guiWindowContent(data: content))

        let cursor = CoreTextMetalRenderer.resolveCursor(
            frameState: dispatcher.frameState,
            windowContents: gui.windowContents,
            cellW: 7.5,
            displayCellH: 16.0,
            scale: 2.0,
            gutterLeftMarginPx: 0,
            gutterPaddingPx: 0
        )

        #expect(dispatcher.frameState.cursorVisible == false)
        #expect(cursor == nil)
    }
}
