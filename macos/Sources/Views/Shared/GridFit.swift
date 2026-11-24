/// The authoritative row-fit and initial grid-dimension calculation (ADR-0001).
///
/// Both `EditorNSView` (resize, font change, reconnect) and `MingaApp` (startup
/// seed before the view exists) call these functions so there is exactly one
/// formula: content pixels divided by the spaced cell height, floored once.

import Foundation

/// Pure geometry helpers for grid sizing. Caseless enum to prevent instantiation.
public enum GridFit {
    /// Rows that fit in the given pixel height at the given cell height and line
    /// spacing. This is the single source of truth consumed by `sendReady`,
    /// `setFrameSize`, font updates, and the startup seed.
    ///
    /// - Parameters:
    ///   - height: Available content height in points.
    ///   - cellHeight: Height of one monospaced cell in points.
    ///   - lineSpacing: Multiplier applied to cell height at draw time (clamped >= 1).
    /// - Returns: Row count, minimum 1.
    nonisolated public static func rowsThatFit(height: CGFloat, cellHeight: CGFloat, lineSpacing: Float = 1.0) -> UInt16 {
        let spacedCellHeight = cellHeight * CGFloat(max(lineSpacing, 1.0))
        guard spacedCellHeight > 0 else { return 1 }
        return UInt16(max(floor(height / spacedCellHeight), 1))
    }

    /// Columns that fit in the given pixel width at the given cell width, after
    /// subtracting any gutter padding.
    ///
    /// - Parameters:
    ///   - width: Available content width in points.
    ///   - cellWidth: Width of one monospaced cell in points.
    ///   - gutterPadding: Points reserved for the gutter (0 when no gutter).
    /// - Returns: Column count, minimum 1.
    nonisolated public static func colsThatFit(width: CGFloat, cellWidth: CGFloat, gutterPadding: CGFloat = 0) -> UInt16 {
        guard cellWidth > 0 else { return 1 }
        return UInt16(max((width - gutterPadding) / cellWidth, 1))
    }
}
