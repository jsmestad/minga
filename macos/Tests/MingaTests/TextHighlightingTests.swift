import Testing
@testable import MingaUI

@Suite("Text highlighting offsets")
struct TextHighlightingTests {
    @Test("Unicode scalar ranges map onto decomposed grapheme clusters")
    func unicodeScalarRangesMapOntoDecomposedGraphemes() {
        let text = "e\u{301}x"

        let accent = TextHighlighting.matchPositions(
            in: text,
            ranges: [TextHighlighting.MatchRange(start: 1, length: 1)],
            offsetUnit: .unicodeScalar
        )
        let trailingCharacter = TextHighlighting.matchPositions(
            in: text,
            ranges: [TextHighlighting.MatchRange(start: 2, length: 1)],
            offsetUnit: .unicodeScalar
        )

        #expect(accent == [0])
        #expect(trailingCharacter == [1])
    }
}
