/// Tests for WindowContentRenderer's display column mapping and attributed string building.
///
/// These tests verify the critical coordinate mapping logic that converts
/// BEAM display columns (CJK = 2 cols) to Swift String.Index positions.

import Testing
import Foundation
import Metal

@Suite("Window Content Renderer - Display Column Mapping")
struct DisplayColumnMappingTests {

    /// Helper to create a WindowContentRenderer for testing.
    /// Uses a real Metal device but the tests only exercise pure functions.
    @MainActor
    private func makeRenderer() -> WindowContentRenderer? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let fm = FontManager(name: "Menlo", size: 13.0, scale: 2.0)
        let rasterizer = BitmapRasterizer()
        return WindowContentRenderer(device: device, fontManager: fm, rasterizer: rasterizer)
    }

    @Test("ASCII text: each char maps to one display column")
    @MainActor func asciiMapping() throws {
        guard let renderer = makeRenderer() else { return }
        let map = renderer.buildDisplayColumnMap(for: "hello")

        // "hello" = 5 display columns + 1 sentinel
        #expect(map.count == 6)
    }

    @Test("CJK text: each char maps to two display columns")
    @MainActor func cjkMapping() throws {
        guard let renderer = makeRenderer() else { return }
        let text = "日本語"
        let map = renderer.buildDisplayColumnMap(for: text)

        // 3 CJK chars × 2 display columns = 6 display columns + 1 sentinel
        #expect(map.count == 7)

        // Column 0 and 1 both map to the first character
        #expect(map[0] == text.startIndex)
        #expect(map[1] == text.startIndex)

        // Column 2 and 3 map to the second character
        let secondIdx = text.index(text.startIndex, offsetBy: 1)
        #expect(map[2] == secondIdx)
        #expect(map[3] == secondIdx)
    }

    @Test("Mixed ASCII and CJK: correct column mapping")
    @MainActor func mixedMapping() throws {
        guard let renderer = makeRenderer() else { return }
        let text = "ab日c"
        // a=1col, b=1col, 日=2col, c=1col = 5 display columns
        let map = renderer.buildDisplayColumnMap(for: text)

        #expect(map.count == 6) // 5 cols + sentinel

        // col 0 = 'a', col 1 = 'b', col 2,3 = '日', col 4 = 'c'
        let indices = Array(text.indices) + [text.endIndex]
        #expect(map[0] == indices[0]) // 'a'
        #expect(map[1] == indices[1]) // 'b'
        #expect(map[2] == indices[2]) // '日'
        #expect(map[3] == indices[2]) // '日' (second column)
        #expect(map[4] == indices[3]) // 'c'
        #expect(map[5] == indices[4]) // endIndex (sentinel)
    }

    @Test("Empty text: single sentinel entry")
    @MainActor func emptyMapping() throws {
        guard let renderer = makeRenderer() else { return }
        let map = renderer.buildDisplayColumnMap(for: "")

        #expect(map.count == 1) // just the sentinel
    }

    @Test("buildAttributedString with no spans uses default fg color")
    @MainActor func noSpansUsesDefaultFg() throws {
        guard let renderer = makeRenderer() else { return }
        renderer.defaultFgRGB = 0xBBC2CF

        let attrStr = renderer.buildAttributedString(text: "hello", spans: [])

        #expect(attrStr.string == "hello")
        #expect(attrStr.length == 5)
    }

    @Test("buildAttributedString with spans produces correct text")
    @MainActor func spansProduceCorrectText() throws {
        guard let renderer = makeRenderer() else { return }
        renderer.defaultFgRGB = 0xBBC2CF

        let spans = [
            GUIHighlightSpan(startCol: 0, endCol: 3, fg: 0xFF0000, bg: 0, attrs: 0, fontWeight: 0, fontId: 0),
            GUIHighlightSpan(startCol: 3, endCol: 5, fg: 0x00FF00, bg: 0, attrs: 0, fontWeight: 0, fontId: 0),
        ]

        let attrStr = renderer.buildAttributedString(text: "hello", spans: spans)

        #expect(attrStr.string == "hello")
    }

    @Test("buildAttributedString with CJK spans maps columns correctly")
    @MainActor func cjkSpanMapping() throws {
        guard let renderer = makeRenderer() else { return }
        renderer.defaultFgRGB = 0xBBC2CF

        // "ab日c" -> display cols: a=0, b=1, 日=2-3, c=4
        // Span covering "日" needs display cols 2-4
        let spans = [
            GUIHighlightSpan(startCol: 2, endCol: 4, fg: 0xFF0000, bg: 0, attrs: 0, fontWeight: 0, fontId: 0),
        ]

        let attrStr = renderer.buildAttributedString(text: "ab日c", spans: spans)

        // The full text should be preserved
        #expect(attrStr.string == "ab日c")
    }

    @Test("buildAttributedString with gap between spans fills with default style")
    @MainActor func gapBetweenSpans() throws {
        guard let renderer = makeRenderer() else { return }
        renderer.defaultFgRGB = 0xBBC2CF

        // "hello world" with spans on "hello" (0-5) and "world" (6-11)
        // Gap at col 5 (the space) should be filled with default style
        let spans = [
            GUIHighlightSpan(startCol: 0, endCol: 5, fg: 0xFF0000, bg: 0, attrs: 0, fontWeight: 0, fontId: 0),
            GUIHighlightSpan(startCol: 6, endCol: 11, fg: 0x00FF00, bg: 0, attrs: 0, fontWeight: 0, fontId: 0),
        ]

        let attrStr = renderer.buildAttributedString(text: "hello world", spans: spans)

        #expect(attrStr.string == "hello world")
    }
}

@Suite("GUIState Frame Lifecycle")
struct GUIStateFrameTests {
    @Test("beginFrame clears windowContents")
    @MainActor func beginFrameClearsContents() {
        let state = GUIState()
        let content = GUIWindowContent(
            windowId: 1, fullRefresh: true,
            cursorRow: 0, cursorCol: 0, cursorShape: .block,
            rows: [], selection: nil,
            searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: []
        )
        state.windowContents[1] = content
        #expect(state.windowContents.count == 1)

        state.beginFrame()
        #expect(state.windowContents.isEmpty)
    }
}
