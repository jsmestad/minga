/// Shared text highlighting utilities for fuzzy match visualization.
///
/// Both the PickerOverlay and MinibufferView highlight matched characters
/// in completion candidates using accent-colored attributed strings.
/// This utility extracts the common logic.

import SwiftUI

enum TextHighlighting {
    /// Builds an AttributedString with matched character positions highlighted.
    ///
    /// Uses range overrides on a pre-built base string instead of per-character
    /// appends: O(k) allocations where k = matched positions, not O(n) where
    /// n = text length.
    static func attributedString(
        _ text: String,
        matchPositions: Set<Int>,
        baseFont: Font = .system(size: 13),
        matchFont: Font = .system(size: 13, weight: .semibold),
        baseColor: Color,
        matchColor: Color
    ) -> AttributedString {
        var result = AttributedString(text)
        result.font = baseFont
        result.foregroundColor = baseColor

        guard !matchPositions.isEmpty else { return result }

        for pos in matchPositions {
            let strIndex = text.index(text.startIndex, offsetBy: pos, limitedBy: text.endIndex)
            guard let strIndex, strIndex < text.endIndex else { continue }
            let nextIndex = text.index(after: strIndex)
            guard let attrStart = AttributedString.Index(strIndex, within: result),
                  let attrEnd = AttributedString.Index(nextIndex, within: result) else { continue }
            result[attrStart..<attrEnd].foregroundColor = matchColor
            result[attrStart..<attrEnd].font = matchFont
        }

        return result
    }

    /// Computes fuzzy match positions for a query against text.
    ///
    /// Splits the query into space-separated segments and finds each segment's
    /// characters in order within the text. Returns grapheme cluster indices
    /// of all matched characters.
    static func fuzzyMatchPositions(_ text: String, query: String) -> Set<Int> {
        guard !query.isEmpty, !text.isEmpty else { return [] }

        let lowerText = text.lowercased()
        let textChars = Array(lowerText)
        var positions = Set<Int>()

        let segments = query.lowercased().split(separator: " ", omittingEmptySubsequences: true)
        for segment in segments {
            let segChars = Array(segment)
            var segIdx = 0
            for (textIdx, ch) in textChars.enumerated() {
                guard segIdx < segChars.count else { break }
                if ch == segChars[segIdx] {
                    positions.insert(textIdx)
                    segIdx += 1
                }
            }
        }

        return positions
    }
}
