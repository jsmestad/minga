/// A styled text run for proportional rendering.
///
/// Wraps a CoreText `CTLine` with the style information needed to render it.
/// Each TextRun represents one line of proportional text with uniform styling
/// (or a segment of a line if styles change mid-line).
///
/// TextRuns are the proportional equivalent of cell grid rows. Instead of
/// fixed-width character cells, they use CoreText's shaping engine for
/// per-glyph advances, kerning, and ligatures.

import CoreText
import CoreGraphics
import Foundation
import AppKit

/// A single styled line (or line segment) of proportional text.
struct TextRun {
    /// The shaped line from CoreText.
    let line: CTLine

    /// Foreground color (RGB, 0..1).
    let fgColor: SIMD3<Float>

    /// Background color (RGB, 0..1).
    let bgColor: SIMD3<Float>

    /// The typographic width of this run in points.
    let width: CGFloat

    /// The ascent, descent, and leading of this run in points.
    let ascent: CGFloat
    let descent: CGFloat
    let leading: CGFloat

    /// Total line height (ascent + descent + leading) in points.
    var lineHeight: CGFloat { ascent + descent + leading }

    /// Create a TextRun from a string with the given font and colors.
    ///
    /// CoreText shapes the string with the font's full OpenType feature set
    /// (kerning, ligatures, contextual alternates). The resulting CTLine
    /// contains per-glyph positioning information.
    static func create(
        text: String,
        font: CTFont,
        fgColor: SIMD3<Float> = SIMD3<Float>(1, 1, 1),
        bgColor: SIMD3<Float> = SIMD3<Float>(0.12, 0.12, 0.14)
    ) -> TextRun {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font as Any,
            .ligature: 1  // Standard ligatures
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrStr)

        var asc: CGFloat = 0
        var desc: CGFloat = 0
        var lead: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &asc, &desc, &lead)

        return TextRun(
            line: line,
            fgColor: fgColor,
            bgColor: bgColor,
            width: width,
            ascent: asc,
            descent: desc,
            leading: lead
        )
    }

    /// Returns the character index at the given x coordinate (in points).
    ///
    /// Used for click-to-position in proportional text. Returns the index
    /// of the character closest to the given x position.
    func characterIndex(atX x: CGFloat) -> CFIndex {
        return CTLineGetStringIndexForPosition(line, CGPoint(x: x, y: 0))
    }

    /// Returns the x offset (in points) for the given character index.
    ///
    /// Used for cursor positioning in proportional text.
    func xOffset(forIndex index: CFIndex) -> CGFloat {
        return CTLineGetOffsetForStringIndex(line, index, nil)
    }
}
