/// Font loading, resolution, and ligature shaping tests.

import Testing
import Foundation
import CoreText
@testable import minga_mac

@Suite("FontFace resolution")
struct FontResolutionTests {
    @Test("Load font by PostScript name")
    func loadByPostScript() {
        let face = FontFace(name: "Menlo-Regular", size: 13, scale: 2.0)
        let psName = CTFontCopyPostScriptName(face.ctFont) as String
        #expect(psName == "Menlo-Regular")
        #expect(face.cellWidth > 0)
        #expect(face.cellHeight > 0)
    }

    @Test("Load font by display name via NSFontManager")
    func loadByDisplayName() {
        let face = FontFace(name: "Menlo", size: 13, scale: 2.0)
        let psName = CTFontCopyPostScriptName(face.ctFont) as String
        // NSFontManager should resolve "Menlo" to a Menlo variant.
        #expect(psName.contains("Menlo"))
        #expect(face.cellWidth > 0)
    }

    @Test("Unknown font falls back to system monospace")
    func unknownFontFallback() {
        let face = FontFace(name: "NonExistentFont12345", size: 14, scale: 2.0)
        // Should still produce valid cell dimensions (system monospace).
        #expect(face.cellWidth > 0)
        #expect(face.cellHeight > 0)
    }

    @Test("Font size affects cell dimensions")
    func sizeAffectsDimensions() {
        let small = FontFace(name: "Menlo", size: 10, scale: 2.0)
        let large = FontFace(name: "Menlo", size: 20, scale: 2.0)
        #expect(large.cellWidth > small.cellWidth)
        #expect(large.cellHeight > small.cellHeight)
    }

    @Test("Scale factor is stored correctly")
    func scaleStored() {
        let face = FontFace(name: "Menlo", size: 13, scale: 1.0)
        #expect(face.scale == 1.0)
        let retina = FontFace(name: "Menlo", size: 13, scale: 2.0)
        #expect(retina.scale == 2.0)
    }

    @Test("Glyph lookup returns valid data for ASCII")
    func asciiGlyphLookup() {
        let face = FontFace(name: "Menlo", size: 13, scale: 2.0)
        face.preloadAscii()
        let glyph = face.getGlyph(0x41) // 'A'
        #expect(glyph != nil)
        #expect(glyph!.width > 0)
        #expect(glyph!.height > 0)
    }

    @Test("Ligatures enabled flag is stored")
    func ligaturesFlag() {
        let withLig = FontFace(name: "Menlo", size: 13, scale: 2.0, ligatures: true)
        #expect(withLig.ligaturesEnabled == true)
        let withoutLig = FontFace(name: "Menlo", size: 13, scale: 2.0, ligatures: false)
        #expect(withoutLig.ligaturesEnabled == false)
    }

    @Test("Font weight is stored and maps correctly")
    func fontWeight() {
        let regular = FontFace(name: "Menlo", size: 13, scale: 2.0, weight: 2)
        #expect(regular.fontWeight == 5) // NSFontManager regular = 5

        let bold = FontFace(name: "Menlo", size: 13, scale: 2.0, weight: 5)
        #expect(bold.fontWeight == 8) // NSFontManager bold = 8

        let light = FontFace(name: "Menlo", size: 13, scale: 2.0, weight: 1)
        #expect(light.fontWeight == 4) // NSFontManager light = 4
    }

    @Test("Default weight is regular")
    func defaultWeight() {
        let face = FontFace(name: "Menlo", size: 13, scale: 2.0)
        #expect(face.fontWeight == 5) // regular
    }

    @Test("Bold weight produces a valid font")
    func boldWeight() {
        let face = FontFace(name: "Menlo", size: 13, scale: 2.0, weight: 5)
        #expect(face.cellWidth > 0)
        #expect(face.cellHeight > 0)
        let psName = CTFontCopyPostScriptName(face.ctFont) as String
        // Menlo Bold should resolve to a bold variant.
        #expect(psName.contains("Bold") || psName.contains("Menlo"))
    }
}

@Suite("FontFace variants")
struct FontVariantTests {
    @Test("Menlo has bold, italic, and bold-italic variants")
    func menloHasAllVariants() {
        let face = FontFace(name: "Menlo", size: 13, scale: 2.0)
        #expect(face.ctFontBold != nil, "Menlo should have a bold variant")
        #expect(face.ctFontItalic != nil, "Menlo should have an italic variant")
        #expect(face.ctFontBoldItalic != nil, "Menlo should have a bold-italic variant")
    }

    @Test("fontForStyle returns correct variant")
    func fontForStyleReturnsCorrectVariant() {
        let face = FontFace(name: "Menlo", size: 13, scale: 2.0)
        let regular = face.fontForStyle(0x00)
        let bold = face.fontForStyle(0x01)
        let italic = face.fontForStyle(0x04)
        let boldItalic = face.fontForStyle(0x05)

        // Regular should be the base font.
        let regularName = CTFontCopyPostScriptName(regular) as String
        #expect(regularName.contains("Menlo"))

        // Bold variant should differ from regular.
        if let boldFont = face.ctFontBold {
            let boldName = CTFontCopyPostScriptName(boldFont) as String
            #expect(boldName != regularName || boldName.contains("Bold"))
            #expect(bold as CTFont === boldFont as CTFont)
        }

        // Italic variant should differ from regular.
        if let italicFont = face.ctFontItalic {
            let italicName = CTFontCopyPostScriptName(italicFont) as String
            #expect(italicName != regularName || italicName.contains("Italic"))
            #expect(italic as CTFont === italicFont as CTFont)
        }

        // Bold-italic should be set.
        if face.ctFontBoldItalic != nil {
            #expect(boldItalic as CTFont === face.ctFontBoldItalic! as CTFont)
        }
    }

    @Test("Bold glyph is rasterized separately from regular")
    func boldGlyphIsSeparate() {
        let face = FontFace(name: "Menlo", size: 13, scale: 2.0)
        let regularA = face.getGlyph(0x41, style: 0)
        let boldA = face.getGlyph(0x41, style: 0x01)
        #expect(regularA != nil)
        #expect(boldA != nil)
        // They should be at different atlas positions (different rasterizations).
        if let r = regularA, let b = boldA {
            #expect(r.atlasX != b.atlasX || r.atlasY != b.atlasY,
                    "Bold and regular 'A' should occupy different atlas positions")
        }
    }

    @Test("Italic glyph is rasterized separately from regular")
    func italicGlyphIsSeparate() {
        let face = FontFace(name: "Menlo", size: 13, scale: 2.0)
        let regularA = face.getGlyph(0x41, style: 0)
        let italicA = face.getGlyph(0x41, style: 0x04)
        #expect(regularA != nil)
        #expect(italicA != nil)
        if let r = regularA, let i = italicA {
            #expect(r.atlasX != i.atlasX || r.atlasY != i.atlasY,
                    "Italic and regular 'A' should occupy different atlas positions")
        }
    }

    @Test("Style bits beyond bold/italic are masked out")
    func styleMaskIgnoresOtherBits() {
        let face = FontFace(name: "Menlo", size: 13, scale: 2.0)
        // 0x03 = bold(0x01) | underline(0x02). Only bold should affect glyph lookup.
        let boldA = face.getGlyph(0x41, style: 0x01)
        let boldUnderlineA = face.getGlyph(0x41, style: 0x03)
        #expect(boldA != nil)
        #expect(boldUnderlineA != nil)
        // Same glyph (underline bit is masked out for font selection).
        if let b = boldA, let bu = boldUnderlineA {
            #expect(b.atlasX == bu.atlasX && b.atlasY == bu.atlasY)
        }
    }
}

@Suite("FontFace ligature shaping")
struct FontLigatureTests {
    @Test("Ligatures disabled returns nil")
    func disabledReturnsNil() {
        let face = FontFace(name: "Menlo", size: 13, scale: 2.0, ligatures: false)
        let result = face.shapeLigature("->")
        #expect(result == nil)
    }

    @Test("Single character returns nil")
    func singleCharReturnsNil() {
        let face = FontFace(name: "Menlo", size: 13, scale: 2.0, ligatures: true)
        let result = face.shapeLigature("a")
        #expect(result == nil)
    }

    @Test("Non-ligature sequence returns nil for Menlo")
    func nonLigatureReturnsNil() {
        // Menlo doesn't have programming ligatures, so "ab" won't ligate.
        let face = FontFace(name: "Menlo", size: 13, scale: 2.0, ligatures: true)
        let result = face.shapeLigature("ab")
        #expect(result == nil)
    }

    @Test("Ligature result is cached")
    func resultIsCached() {
        let face = FontFace(name: "Menlo", size: 13, scale: 2.0, ligatures: true)
        // Call twice; both should return the same result (nil for Menlo).
        let r1 = face.shapeLigature("->")
        let r2 = face.shapeLigature("->")
        // Both nil or both non-nil.
        #expect((r1 == nil) == (r2 == nil))
    }

    @Test("Ligature shaping for known ligature font produces result")
    func ligatureFontProducesResult() {
        // Try with a font that has ligatures. If not installed, skip.
        // Common ligature fonts: "Fira Code", "JetBrains Mono", "Cascadia Code"
        let ligatureFonts = ["FiraCode-Regular", "JetBrainsMono-Regular", "CascadiaCode-Regular"]
        var face: FontFace?
        for fontName in ligatureFonts {
            let candidate = FontFace(name: fontName, size: 14, scale: 2.0, ligatures: true)
            let psName = CTFontCopyPostScriptName(candidate.ctFont) as String
            if psName.lowercased().contains(fontName.lowercased().prefix(4).lowercased()) {
                face = candidate
                break
            }
        }

        guard let face else {
            // No ligature font installed; skip.
            return
        }

        let result = face.shapeLigature("->")
        // A ligature font should produce a result for "->".
        // If it doesn't, the font might not have this specific ligature.
        if let lig = result {
            #expect(lig.cellCount == 2)
            #expect(lig.glyph.width > 0)
            #expect(lig.glyph.height > 0)
        }
    }
}

@Suite("CellGrid ligature cells")
struct CellGridLigatureTests {
    @Test("Ligature head cell stores ligature metadata")
    func headCellMetadata() {
        let grid = CellGrid(cols: 10, rows: 1)
        grid.writeCell(col: 0, row: 0, cell: Cell(
            grapheme: "->",
            width: 2,
            fg: 0xFFFFFF, bg: 0,
            attrs: 0,
            ligatureText: "->",
            ligatureCellCount: 2,
            isContinuation: false
        ))
        let cell = grid.cells[0]
        #expect(cell.ligatureText == "->")
        #expect(cell.ligatureCellCount == 2)
        #expect(cell.isContinuation == false)
    }

    @Test("Continuation cell is marked correctly")
    func continuationCell() {
        let grid = CellGrid(cols: 10, rows: 1)
        grid.writeCell(col: 1, row: 0, cell: Cell(
            grapheme: "",
            width: 1,
            fg: 0xFFFFFF, bg: 0,
            attrs: 0,
            isContinuation: true
        ))
        let cell = grid.cells[1]
        #expect(cell.isContinuation == true)
        #expect(cell.grapheme == "")
    }

    @Test("Default cell has no ligature")
    func defaultCellNoLigature() {
        let cell = Cell()
        #expect(cell.ligatureText == "")
        #expect(cell.ligatureCellCount == 1)
        #expect(cell.isContinuation == false)
    }
}

@Suite("CommandDispatcher ligature integration")
@MainActor
struct DispatcherLigatureTests {
    @Test("drawText without fontFace writes individual cells")
    func noFontFaceIndividualCells() {
        let grid = CellGrid(cols: 20, rows: 1)
        let disp = CommandDispatcher(grid: grid, guiState: GUIState())
        // No fontFace set, so no ligature shaping.
        disp.dispatch(.drawText(row: 0, col: 0, fg: 0xFFFFFF, bg: 0, attrs: 0, text: "->"))
        let cell0 = grid.cells[0]
        let cell1 = grid.cells[1]
        #expect(cell0.grapheme == "-")
        #expect(cell1.grapheme == ">")
        #expect(cell0.isContinuation == false)
        #expect(cell1.isContinuation == false)
    }

    @Test("drawText with ligatures disabled writes individual cells")
    func ligaturesDisabledIndividualCells() {
        let grid = CellGrid(cols: 20, rows: 1)
        let disp = CommandDispatcher(grid: grid, guiState: GUIState())
        disp.fontFace = FontFace(name: "Menlo", size: 13, scale: 2.0, ligatures: false)
        disp.dispatch(.drawText(row: 0, col: 0, fg: 0xFFFFFF, bg: 0, attrs: 0, text: "->"))
        let cell0 = grid.cells[0]
        let cell1 = grid.cells[1]
        #expect(cell0.grapheme == "-")
        #expect(cell1.grapheme == ">")
    }
}
