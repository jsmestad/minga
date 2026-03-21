/// Tests for CoreTextMetalRenderer static helpers.
///
/// These tests cover the `runColSpan` calculation that was extracted to
/// prevent a UInt16 underflow crash (exit 133 / SIGTRAP) when consecutive
/// StyledRuns have out-of-order column positions.

import Testing
@testable import minga_mac

@Suite("CoreTextMetalRenderer.runColSpan")
struct RunColSpanTests {

    // Helper to build a minimal StyledRun at a given column.
    private func run(col: UInt16, text: String = "x") -> StyledRun {
        StyledRun(col: col, text: text, fg: 0xFFFFFF, bg: 0x000000, attrs: 0)
    }

    @Test("Normal case: span equals distance to next run's column")
    func normalSpan() {
        let runs = [run(col: 0), run(col: 5), run(col: 10)]
        #expect(CoreTextMetalRenderer.runColSpan(runs: runs, at: 0) == 5)
        #expect(CoreTextMetalRenderer.runColSpan(runs: runs, at: 1) == 5)
    }

    @Test("Last run: falls back to display width of text")
    func lastRunDisplayWidth() {
        let runs = [run(col: 0, text: "AB")]
        // "AB" has display width 2 (two ASCII characters)
        #expect(CoreTextMetalRenderer.runColSpan(runs: runs, at: 0) == 2)
    }

    @Test("Last run with wide characters uses correct display width")
    func lastRunWideChars() {
        // CJK character U+4E16 (世) is display width 2
        let runs = [run(col: 0, text: "世")]
        #expect(CoreTextMetalRenderer.runColSpan(runs: runs, at: 0) == 2)
    }

    @Test("Out-of-order columns clamp to 1 instead of underflowing")
    func outOfOrderClamps() {
        // col 5 followed by col 3: would underflow UInt16(3 - 5)
        let runs = [run(col: 5), run(col: 3)]
        // Must not crash, and must return 1 (minimum)
        #expect(CoreTextMetalRenderer.runColSpan(runs: runs, at: 0) == 1)
    }

    @Test("Same column runs clamp to 1")
    func sameColumnClamps() {
        let runs = [run(col: 7), run(col: 7)]
        // span = 0, clamped to 1
        #expect(CoreTextMetalRenderer.runColSpan(runs: runs, at: 0) == 1)
    }

    @Test("Single-cell span works correctly")
    func singleCellSpan() {
        let runs = [run(col: 0), run(col: 1)]
        #expect(CoreTextMetalRenderer.runColSpan(runs: runs, at: 0) == 1)
    }

    @Test("Large column gap produces correct span")
    func largeGap() {
        // Tab-expanded or gutter offset could produce large gaps
        let runs = [run(col: 0), run(col: 200)]
        #expect(CoreTextMetalRenderer.runColSpan(runs: runs, at: 0) == 200)
    }
}
