/// Shared text highlighting utilities for fuzzy match visualization.
///
/// Both the PickerOverlay and MinibufferView highlight matched characters
/// in completion candidates using accent-colored attributed strings.
/// This utility extracts the common logic.

import SwiftUI

public enum TextHighlighting {
    public enum OffsetUnit: Sendable {
        case graphemeCluster
        case unicodeScalar
    }

    public struct MatchRange: Sendable {
        public let start: Int
        public let length: Int

        public init(start: Int, length: Int) {
            self.start = start
            self.length = length
        }
    }

    /// Converts ranges in an explicit source unit to grapheme-cluster positions used by `AttributedString`.
    public static func matchPositions(
        in text: String,
        ranges: [MatchRange],
        offsetUnit: OffsetUnit
    ) -> Set<Int> {
        switch offsetUnit {
        case .graphemeCluster:
            let characterCount = text.count
            return Set(ranges.flatMap { range in
                clampedOffsets(range, upperBound: characterCount)
            })

        case .unicodeScalar:
            return unicodeScalarRangesToGraphemePositions(text, ranges: ranges)
        }
    }

    /// Builds an AttributedString with matched character positions highlighted.
    ///
    /// Uses range overrides on a pre-built base string instead of per-character
    /// appends: O(k) allocations where k = matched positions, not O(n) where
    /// n = text length.
    public static func attributedString(
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
    public static func fuzzyMatchPositions(_ text: String, query: String) -> Set<Int> {
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

    private static func unicodeScalarRangesToGraphemePositions(
        _ text: String,
        ranges: [MatchRange]
    ) -> Set<Int> {
        let scalarCount = text.unicodeScalars.count
        let scalarRanges = ranges
            .map { clampedOffsets($0, upperBound: scalarCount) }
            .filter { !$0.isEmpty }
            .sorted { $0.lowerBound < $1.lowerBound }
        guard !scalarRanges.isEmpty else { return [] }

        var positions = Set<Int>()
        var scalarOffset = 0
        var rangeIndex = 0

        for (characterOffset, character) in text.enumerated() {
            let nextScalarOffset = scalarOffset + character.unicodeScalars.count

            while rangeIndex < scalarRanges.count && scalarRanges[rangeIndex].upperBound <= scalarOffset {
                rangeIndex += 1
            }

            if rangeIndex < scalarRanges.count && scalarRanges[rangeIndex].lowerBound < nextScalarOffset {
                positions.insert(characterOffset)
            }

            scalarOffset = nextScalarOffset
        }

        return positions
    }

    private static func clampedOffsets(_ range: MatchRange, upperBound: Int) -> Range<Int> {
        guard range.start >= 0, range.length > 0, range.start < upperBound else { return 0..<0 }
        let clampedLength = min(range.length, upperBound - range.start)
        return range.start..<(range.start + clampedLength)
    }
}
