/// Tests for the authoritative grid-fit formula (ADR-0001, issue #2816).
/// Verifies that startup, resize, font changes, and reconnect all share one
/// row-fit calculation through `GridFit`.

import Testing
import Foundation
import CoreGraphics
@testable import MingaUI

@Suite("GridFit.rowsThatFit")
struct GridFitRowTests {

    @Test("default line spacing (1.0) produces the same result as plain division")
    func defaultSpacing() {
        // 800 / 16 = 50 rows exactly
        #expect(GridFit.rowsThatFit(height: 800, cellHeight: 16) == 50)
        #expect(GridFit.rowsThatFit(height: 800, cellHeight: 16, lineSpacing: 1.0) == 50)
    }

    @Test("non-default line spacing reduces row count")
    func nonDefaultSpacing() {
        // 800 / (16 * 1.5) = 800 / 24 = 33.33 -> floor -> 33
        #expect(GridFit.rowsThatFit(height: 800, cellHeight: 16, lineSpacing: 1.5) == 33)
    }

    @Test("fractional viewport height floors correctly")
    func fractionalHeight() {
        // 805 / 16 = 50.3125 -> floor -> 50
        #expect(GridFit.rowsThatFit(height: 805, cellHeight: 16) == 50)
        // 799 / 16 = 49.9375 -> floor -> 49
        #expect(GridFit.rowsThatFit(height: 799, cellHeight: 16) == 49)
    }

    @Test("fractional height with non-default spacing")
    func fractionalHeightWithSpacing() {
        // 500 / (16 * 1.3) = 500 / 20.8 = 24.038... -> floor -> 24
        #expect(GridFit.rowsThatFit(height: 500, cellHeight: 16, lineSpacing: 1.3) == 24)
    }

    @Test("very small viewport returns at least 1 row")
    func minimumOneRow() {
        #expect(GridFit.rowsThatFit(height: 5, cellHeight: 16) == 1)
        #expect(GridFit.rowsThatFit(height: 5, cellHeight: 16, lineSpacing: 2.0) == 1)
    }

    @Test("zero cell height returns 1 row")
    func zeroCellHeight() {
        #expect(GridFit.rowsThatFit(height: 800, cellHeight: 0) == 1)
    }

    @Test("line spacing below 1.0 is clamped to 1.0")
    func spacingClampedToOne() {
        // lineSpacing 0.5 should behave like 1.0
        let withLow = GridFit.rowsThatFit(height: 800, cellHeight: 16, lineSpacing: 0.5)
        let withDefault = GridFit.rowsThatFit(height: 800, cellHeight: 16, lineSpacing: 1.0)
        #expect(withLow == withDefault)
    }
}

@Suite("GridFit.colsThatFit")
struct GridFitColTests {

    @Test("exact division produces expected columns")
    func exactDivision() {
        // 800 / 8 = 100
        #expect(GridFit.colsThatFit(width: 800, cellWidth: 8) == 100)
    }

    @Test("gutter padding reduces column count")
    func gutterPadding() {
        // (800 - 40) / 8 = 95
        #expect(GridFit.colsThatFit(width: 800, cellWidth: 8, gutterPadding: 40) == 95)
    }

    @Test("fractional width truncates toward zero")
    func fractionalWidth() {
        // 805 / 8 = 100.625 -> UInt16 truncation -> 100
        #expect(GridFit.colsThatFit(width: 805, cellWidth: 8) == 100)
    }

    @Test("very small viewport returns at least 1 column")
    func minimumOneCol() {
        #expect(GridFit.colsThatFit(width: 3, cellWidth: 8) == 1)
    }

    @Test("zero cell width returns 1 column")
    func zeroCellWidth() {
        #expect(GridFit.colsThatFit(width: 800, cellWidth: 0) == 1)
    }
}
