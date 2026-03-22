/// Shared text highlighting utilities for fuzzy match visualization.
///
/// Both the PickerOverlay and MinibufferView highlight matched characters
/// in completion candidates using accent-colored attributed strings.
/// This utility extracts the common logic.

import SwiftUI

enum TextHighlighting {
    /// Builds an AttributedString with matched character positions highlighted.
    ///
    /// Matched characters are rendered in `matchColor` with semibold weight.
    /// Unmatched characters use `baseColor` with the base font.
    ///
    /// - Parameters:
    ///   - text: The full text to render.
    ///   - matchPositions: Set of grapheme cluster indices to highlight.
    ///   - baseFont: Font for unmatched characters.
    ///   - matchFont: Font for matched characters (typically semibold variant).
    ///   - baseColor: Color for unmatched characters.
    ///   - matchColor: Color for matched characters (typically accent).
    static func attributedString(
        _ text: String,
        matchPositions: Set<Int>,
        baseFont: Font = .system(size: 13),
        matchFont: Font = .system(size: 13, weight: .semibold),
        baseColor: Color,
        matchColor: Color
    ) -> AttributedString {
        var result = AttributedString()
        let chars = Array(text)

        for (idx, char) in chars.enumerated() {
            var segment = AttributedString(String(char))

            if matchPositions.contains(idx) {
                segment.foregroundColor = matchColor
                segment.font = matchFont
            } else {
                segment.foregroundColor = baseColor
                segment.font = baseFont
            }

            result.append(segment)
        }

        return result
    }
}
