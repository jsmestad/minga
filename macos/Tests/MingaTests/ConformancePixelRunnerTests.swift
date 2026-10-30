import Foundation
import Testing
@testable import MingaUI
import MingaProtocol

@Suite("Conformance pixel expectation contract")
@MainActor
struct ConformancePixelRunnerTests {
    @Test("cell conversion uses spaced fixture height and rounds outward")
    func spacedCellConversion() {
        let bounds = ConformancePixelRunner.pixelBounds(
            cells: [2, 3, 1, 2], cellWidth: 7.5, cellHeight: 16 * 1.2)
        #expect(bounds.x0 == 22)
        #expect(bounds.x1 == 38)
        #expect(bounds.y0 == 38)
        #expect(bounds.y1 == 58)
    }

    @Test("only the exact applied transaction qualifies its committed editor snapshot")
    func transactionMustMatchSnapshot() {
        let snapshot = rendererSnapshot(generation: 7, frameSeq: 11,
            frameState: FrameState(cols: 2, rows: 2), windowContents: [:])
        let applied = FrameTransactionResult.applied(generation: 7, frameSeq: 11)
        #expect(ConformancePixelRunner.snapshotForPixels(snapshot, result: applied) != nil)
        #expect(ConformancePixelRunner.snapshotForPixels(nil, result: applied) == nil)
        #expect(ConformancePixelRunner.snapshotForPixels(snapshot, result: nil) == nil)
        #expect(ConformancePixelRunner.snapshotForPixels(snapshot,
            result: .applied(generation: 8, frameSeq: 11)) == nil)
        #expect(ConformancePixelRunner.snapshotForPixels(snapshot,
            result: .applied(generation: 7, frameSeq: 12)) == nil)
        #expect(ConformancePixelRunner.snapshotForPixels(snapshot,
            result: .rejected(generation: 7, frameSeq: 11, lastAppliedFrameSeq: 10, reason: .missingTheme)) == nil)
        #expect(ConformancePixelRunner.snapshotForPixels(snapshot,
            result: .windowRefMiss(generation: 7, frameSeq: 11, lastAppliedFrameSeq: 10, windowId: 1)) == nil)
    }

    @Test("a production shell-only commit cannot resample the previous editor frame")
    func shellOnlyCommitDoesNotQualifyRetainedEditorSnapshot() throws {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 2, rows: 2, guiState: gui)
        var result: FrameTransactionResult?
        dispatcher.onTransactionResult = { result = $0 }
        let rect = GUICellRect(row: 0, col: 0, width: 2, height: 2)
        let geometry = GUIPaneGeometry(
            windowId: 1, totalRect: rect, contentRect: rect, textRect: rect,
            gutterRect: GUICellRect(row: 0, col: 0, width: 0, height: 2), clipRect: rect,
            viewport: GUIViewportSummary(top: 0, left: 0, rows: 2, cols: 2,
                totalLines: 2, visualRowOffset: 0, totalVisualRows: 2),
            gutterMetrics: GUIGutterMetrics(lineNumberWidth: 0, signColWidth: 0), hitRegions: [])
        let content = try GUIWindowContent(
            windowId: 1, fullRefresh: true, cursorRow: 0, cursorCol: 0, cursorShape: .block,
            rows: [], selection: nil, searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: [], paneGeometry: geometry)
        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: CommandDispatcher.requiredThemeSlots.map { ($0, 32, 32, 32) }))
        dispatcher.dispatch(.guiWindowContent(data: content))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))
        let first = try #require(dispatcher.committedEditorSnapshot)
        #expect(result == .applied(generation: 1, frameSeq: 1))
        #expect(ConformancePixelRunner.snapshotForPixels(first, result: result) != nil)

        result = nil
        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 1, generation: 1))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: []))
        dispatcher.dispatch(.commitFrame(frameSeq: 2, seq: 0))
        #expect(result == .applied(generation: 1, frameSeq: 2))
        let retained = try #require(dispatcher.committedEditorSnapshot)
        #expect(retained.generation == first.generation && retained.frameSeq == first.frameSeq)
        #expect(ConformancePixelRunner.snapshotForPixels(retained, result: result) == nil)
    }

    @Test("color, empty and glyph occupancy classify saturated fixture pixels")
    func regionClassification() throws {
        let neutral = ReadbackImage(width: 2, height: 2, bytesPerRow: 8,
                                    bytes: Array(repeating: [UInt8(32), 32, 32, 255], count: 4).flatMap { $0 })
        let region: [String: Any] = ["region": "last row", "cells": [0.0, 0.0, 2.0, 2.0],
                                     "color": "0x202020", "tolerance": 0.02]
        for assertion in ["color", "empty"] {
            try ConformancePixelRunner.assertRegion(region.merging(["assert": assertion]) { _, new in new },
                image: neutral, cellWidth: 1, cellHeight: 1, context: "fixture step 0")
        }
        var bytes = neutral.bytes
        bytes[2] = 224
        let occupied = ReadbackImage(width: 2, height: 2, bytesPerRow: 8, bytes: bytes)
        try ConformancePixelRunner.assertRegion(region.merging(["assert": "occupied"]) { _, new in new },
            image: occupied, cellWidth: 1, cellHeight: 1, context: "fixture step 1")
    }

    @Test("a color mismatch reports a sampled region failure")
    func mismatchedRegionReportsIssue() throws {
        let image = ReadbackImage(width: 1, height: 1, bytesPerRow: 4, bytes: [16, 16, 224, 255])
        try withKnownIssue("Deliberately wrong blue expectation for a saturated red sample") {
            try ConformancePixelRunner.assertRegion(
                ["region": "frame edge", "cells": [0.0, 0.0, 1.0, 1.0],
                 "assert": "color", "color": "0x1010E0"], image: image,
                cellWidth: 1, cellHeight: 1, context: "sampled_failure step 7")
        }
    }
}
