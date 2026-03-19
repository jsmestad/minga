/// Tests for LineBuffer and StyledRun data structures.

import Testing
import Foundation
@testable import minga_mac

@Suite("StyledRun")
struct StyledRunTests {
    @Test("Hashable conformance produces consistent hashes")
    func hashableConformance() {
        let run1 = StyledRun(col: 0, text: "hello", fg: 0xFF0000, bg: 0x000000, attrs: 0x01)
        let run2 = StyledRun(col: 0, text: "hello", fg: 0xFF0000, bg: 0x000000, attrs: 0x01)
        let run3 = StyledRun(col: 0, text: "world", fg: 0xFF0000, bg: 0x000000, attrs: 0x01)

        #expect(run1 == run2)
        #expect(run1.hashValue == run2.hashValue)
        #expect(run1 != run3)
    }

    @Test("Different attributes produce different hashes")
    func differentAttrsHash() {
        let run1 = StyledRun(col: 5, text: "test", fg: 0xFFFFFF, bg: 0, attrs: 0x00)
        let run2 = StyledRun(col: 5, text: "test", fg: 0xFFFFFF, bg: 0, attrs: 0x01)

        #expect(run1 != run2)
    }

    @Test("Font weight and ID included in equality")
    func fontWeightAndIdEquality() {
        let run1 = StyledRun(col: 0, text: "a", fg: 0, bg: 0, attrs: 0, fontWeight: 2, fontId: 0)
        let run2 = StyledRun(col: 0, text: "a", fg: 0, bg: 0, attrs: 0, fontWeight: 5, fontId: 0)
        let run3 = StyledRun(col: 0, text: "a", fg: 0, bg: 0, attrs: 0, fontWeight: 2, fontId: 1)

        #expect(run1 != run2)
        #expect(run1 != run3)
    }

    @Test("Underline attributes included in equality")
    func underlineEquality() {
        let run1 = StyledRun(col: 0, text: "x", fg: 0, bg: 0, attrs: 0, underlineColor: 0xFF0000, underlineStyle: 1)
        let run2 = StyledRun(col: 0, text: "x", fg: 0, bg: 0, attrs: 0, underlineColor: 0x00FF00, underlineStyle: 1)

        #expect(run1 != run2)
    }
}

@Suite("LineBuffer")
struct LineBufferTests {
    @Test("Init creates empty buffer with correct dimensions")
    func initEmpty() {
        let buf = LineBuffer(cols: 80, rows: 24)
        #expect(buf.cols == 80)
        #expect(buf.rows == 24)
        #expect(buf.activeLineCount == 0)
    }

    @Test("appendRun adds a run to the correct row")
    func appendRun() {
        let buf = LineBuffer(cols: 80, rows: 24)
        buf.appendRun(row: 5, col: 0, text: "hello", fg: 0xFFFFFF, bg: 0, attrs: 0)

        let runs = buf.runsForLine(5)
        #expect(runs.count == 1)
        #expect(runs[0].text == "hello")
        #expect(runs[0].col == 0)
        #expect(runs[0].fg == 0xFFFFFF)
    }

    @Test("Multiple runs on the same line are preserved in order")
    func multipleRunsSameLine() {
        let buf = LineBuffer(cols: 80, rows: 24)
        buf.appendRun(row: 0, col: 0, text: "def", fg: 0xFF0000, bg: 0, attrs: 0x01)
        buf.appendRun(row: 0, col: 3, text: "module", fg: 0x00FF00, bg: 0, attrs: 0)

        let runs = buf.runsForLine(0)
        #expect(runs.count == 2)
        #expect(runs[0].text == "def")
        #expect(runs[0].fg == 0xFF0000)
        #expect(runs[1].text == "module")
        #expect(runs[1].col == 3)
    }

    @Test("Out-of-bounds row is silently ignored")
    func outOfBoundsRow() {
        let buf = LineBuffer(cols: 80, rows: 24)
        buf.appendRun(row: 30, col: 0, text: "nope", fg: 0, bg: 0, attrs: 0)
        #expect(buf.activeLineCount == 0)
    }

    @Test("clear resets all lines")
    func clearResetsAll() {
        let buf = LineBuffer(cols: 80, rows: 24)
        buf.appendRun(row: 0, col: 0, text: "a", fg: 0, bg: 0, attrs: 0)
        buf.appendRun(row: 5, col: 0, text: "b", fg: 0, bg: 0, attrs: 0)
        #expect(buf.activeLineCount == 2)

        buf.clear()
        #expect(buf.activeLineCount == 0)
        #expect(buf.runsForLine(0).isEmpty)
        #expect(buf.runsForLine(5).isEmpty)
    }

    @Test("resize clears content and updates dimensions")
    func resizeClears() {
        let buf = LineBuffer(cols: 80, rows: 24)
        buf.appendRun(row: 0, col: 0, text: "test", fg: 0, bg: 0, attrs: 0)

        buf.resize(newCols: 120, newRows: 40)
        #expect(buf.cols == 120)
        #expect(buf.rows == 40)
        #expect(buf.activeLineCount == 0)
    }

    @Test("resize with same dimensions is a no-op")
    func resizeSameDimensions() {
        let buf = LineBuffer(cols: 80, rows: 24)
        buf.appendRun(row: 0, col: 0, text: "keep", fg: 0, bg: 0, attrs: 0)

        buf.resize(newCols: 80, newRows: 24)
        #expect(buf.activeLineCount == 1)
    }

    @Test("resize with zero dimensions is a no-op")
    func resizeZeroDimensions() {
        let buf = LineBuffer(cols: 80, rows: 24)
        buf.resize(newCols: 0, newRows: 10)
        #expect(buf.cols == 80)
    }

    @Test("cursor position tracking")
    func cursorTracking() {
        let buf = LineBuffer(cols: 80, rows: 24)
        buf.showCursor(col: 10, row: 5)
        #expect(buf.cursorCol == 10)
        #expect(buf.cursorRow == 5)
    }

    @Test("clearRect removes runs in the region")
    func clearRect() {
        let buf = LineBuffer(cols: 80, rows: 24)
        buf.appendRun(row: 2, col: 5, text: "inside", fg: 0, bg: 0, attrs: 0)
        buf.appendRun(row: 2, col: 20, text: "outside", fg: 0, bg: 0, attrs: 0)

        buf.clearRect(col: 0, row: 2, width: 15, height: 1)

        let runs = buf.runsForLine(2)
        #expect(runs.count == 1)
        #expect(runs[0].text == "outside")
    }

    @Test("clearRect spans multiple rows")
    func clearRectMultipleRows() {
        let buf = LineBuffer(cols: 80, rows: 24)
        buf.appendRun(row: 0, col: 0, text: "row0", fg: 0, bg: 0, attrs: 0)
        buf.appendRun(row: 1, col: 0, text: "row1", fg: 0, bg: 0, attrs: 0)
        buf.appendRun(row: 2, col: 0, text: "row2", fg: 0, bg: 0, attrs: 0)

        buf.clearRect(col: 0, row: 0, width: 80, height: 2)

        #expect(buf.runsForLine(0).isEmpty)
        #expect(buf.runsForLine(1).isEmpty)
        #expect(buf.runsForLine(2).count == 1)
    }

    @Test("content hash changes when line content changes")
    func contentHashInvalidation() {
        let buf = LineBuffer(cols: 80, rows: 24)
        buf.appendRun(row: 0, col: 0, text: "hello", fg: 0xFFFFFF, bg: 0, attrs: 0)
        let hash1 = buf.computeLineHash(row: 0)

        // Same content on a different call returns cached hash.
        let hash1b = buf.computeLineHash(row: 0)
        #expect(hash1 == hash1b)

        // Adding a run invalidates the hash.
        buf.appendRun(row: 0, col: 5, text: " world", fg: 0xFFFFFF, bg: 0, attrs: 0)
        let hash2 = buf.computeLineHash(row: 0)
        #expect(hash1 != hash2)
    }

    @Test("empty line hash is 0")
    func emptyLineHash() {
        let buf = LineBuffer(cols: 80, rows: 24)
        let hash = buf.computeLineHash(row: 5)
        #expect(hash == 0)
    }

    @Test("dirty flag is set on modifications and can be cleared")
    func dirtyFlag() {
        let buf = LineBuffer(cols: 80, rows: 24)
        #expect(buf.dirty == true)  // Dirty on creation.

        buf.dirty = false
        buf.appendRun(row: 0, col: 0, text: "x", fg: 0, bg: 0, attrs: 0)
        #expect(buf.dirty == true)

        buf.dirty = false
        buf.clear()
        #expect(buf.dirty == true)

        buf.dirty = false
        buf.showCursor(col: 1, row: 1)
        #expect(buf.dirty == true)
    }

    @Test("defaultBg and gutter properties")
    func defaultProperties() {
        let buf = LineBuffer(cols: 80, rows: 24)
        buf.defaultBg = 0x1A1A2E
        buf.gutterCol = 4
        buf.gutterSeparatorColor = 0x333333

        #expect(buf.defaultBg == 0x1A1A2E)
        #expect(buf.gutterCol == 4)
        #expect(buf.gutterSeparatorColor == 0x333333)
    }

    @Test("styled run with all attributes preserved")
    func fullAttributePreservation() {
        let buf = LineBuffer(cols: 80, rows: 24)
        buf.appendRun(
            row: 0, col: 10, text: "styled",
            fg: 0xFF0000, bg: 0x00FF00, attrs: 0x05,
            underlineColor: 0x0000FF, underlineStyle: 2,
            fontWeight: 5, fontId: 3
        )

        let run = buf.runsForLine(0)[0]
        #expect(run.col == 10)
        #expect(run.text == "styled")
        #expect(run.fg == 0xFF0000)
        #expect(run.bg == 0x00FF00)
        #expect(run.attrs == 0x05)
        #expect(run.underlineColor == 0x0000FF)
        #expect(run.underlineStyle == 2)
        #expect(run.fontWeight == 5)
        #expect(run.fontId == 3)
    }
}
