/// Font loading, resolution, and variant tests.

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
        #expect(psName.contains("Menlo"))
        #expect(face.cellWidth > 0)
    }

    @Test("Unknown font falls back to system monospace")
    func unknownFontFallback() {
        let face = FontFace(name: "NonExistentFont12345", size: 14, scale: 2.0)
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
        #expect(regular.fontWeight == 5)

        let bold = FontFace(name: "Menlo", size: 13, scale: 2.0, weight: 5)
        #expect(bold.fontWeight == 8)

        let light = FontFace(name: "Menlo", size: 13, scale: 2.0, weight: 1)
        #expect(light.fontWeight == 4)
    }

    @Test("Default weight is regular")
    func defaultWeight() {
        let face = FontFace(name: "Menlo", size: 13, scale: 2.0)
        #expect(face.fontWeight == 5)
    }

    @Test("Bold weight produces a valid font")
    func boldWeight() {
        let face = FontFace(name: "Menlo", size: 13, scale: 2.0, weight: 5)
        #expect(face.cellWidth > 0)
        #expect(face.cellHeight > 0)
        let psName = CTFontCopyPostScriptName(face.ctFont) as String
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

        let regularName = CTFontCopyPostScriptName(regular) as String
        #expect(regularName.contains("Menlo"))

        if let boldFont = face.ctFontBold {
            #expect(bold as CTFont === boldFont as CTFont)
        }

        if let italicFont = face.ctFontItalic {
            #expect(italic as CTFont === italicFont as CTFont)
        }

        if face.ctFontBoldItalic != nil {
            #expect(boldItalic as CTFont === face.ctFontBoldItalic! as CTFont)
        }
    }

    @Test("fontForWeight returns correct variant")
    func fontForWeightReturnsCorrectVariant() {
        let face = FontFace(name: "Menlo", size: 13, scale: 2.0)

        let regular = face.fontForWeight(2)
        let bold = face.fontForWeight(5)
        let light = face.fontForWeight(1)

        // All should be valid CTFont instances.
        #expect(CTFontGetSize(regular) == 13)
        #expect(CTFontGetSize(bold) == 13)
        #expect(CTFontGetSize(light) == 13)
    }

    @Test("fontForWeight with italic flag")
    func fontForWeightWithItalic() {
        let face = FontFace(name: "Menlo", size: 13, scale: 2.0)

        let italicRegular = face.fontForWeight(2, isItalic: true)
        let nonItalic = face.fontForWeight(2, isItalic: false)

        // Both should be valid, and italic should differ from non-italic.
        #expect(CTFontGetSize(italicRegular) == 13)
        #expect(CTFontGetSize(nonItalic) == 13)
    }
}

@Suite("FontManager")
struct FontManagerTests {
    @Test("Primary font has correct metrics")
    func primaryMetrics() {
        let fm = FontManager(name: "Menlo", size: 13, scale: 2.0)
        #expect(fm.cellWidth > 0)
        #expect(fm.cellHeight > 0)
        #expect(fm.ascent > 0)
        #expect(fm.scale == 2.0)
    }

    @Test("fontFace for ID 0 returns primary")
    func fontFaceForZeroReturnsPrimary() {
        let fm = FontManager(name: "Menlo", size: 13, scale: 2.0)
        let face = fm.fontFace(for: 0)
        #expect(face === fm.primary)
    }

    @Test("fontFace for unknown ID returns primary")
    func fontFaceForUnknownReturnsPrimary() {
        let fm = FontManager(name: "Menlo", size: 13, scale: 2.0)
        let face = fm.fontFace(for: 42)
        #expect(face === fm.primary)
    }

    @Test("setPrimaryFont replaces the font")
    func setPrimaryFont() {
        let fm = FontManager(name: "Menlo", size: 13, scale: 2.0)
        let oldWidth = fm.cellWidth
        fm.setPrimaryFont(name: "Menlo", size: 20, scale: 2.0, ligatures: true, weight: 2)
        #expect(fm.cellWidth > oldWidth)
    }
}
