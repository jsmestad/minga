/// CoreText font face manager.
///
/// Loads a monospace font, extracts cell metrics, and provides CTFont
/// variants for CoreText line rendering. Weight variants are lazily
/// resolved via NSFontManager and cached.

import CoreText
import CoreGraphics
import Foundation
import AppKit

/// Font face with weight/style variant resolution.
///
/// Holds up to four CTFont variants (regular, bold, italic, bold-italic).
/// Weight variants beyond bold/regular are resolved lazily via NSFontManager.
final class FontFace {
    let ctFont: CTFont
    /// Bold variant, or nil if the font family doesn't have one.
    let ctFontBold: CTFont?
    /// Italic variant, or nil if the font family doesn't have one.
    let ctFontItalic: CTFont?
    /// Bold-italic variant, or nil if the font family doesn't have one.
    let ctFontBoldItalic: CTFont?
    /// Cell dimensions in points (for grid layout).
    let cellWidth: Int
    let cellHeight: Int
    /// Font metrics in points.
    let ascent: CGFloat
    let descent: CGFloat
    let leading: CGFloat
    /// Backing scale factor (2.0 for Retina).
    let scale: CGFloat

    /// Whether programming ligatures are enabled. When true, CoreText
    /// shapes multi-character sequences like `->`, `!=`, `=>` as ligatures.
    let ligaturesEnabled: Bool

    /// Cache of CTFont instances at different weights, lazily loaded via NSFontManager.
    /// Keyed by protocol weight byte (0-7). The base font's weight is pre-populated.
    private var weightedFonts: [UInt8: CTFont] = [:]

    /// The font family name (for resolving weight variants via NSFontManager).
    private let familyName: String

    /// User-configured font fallback chain. Tried in order before the system
    /// fallback (CTFontCreateForString) when the primary font doesn't have a glyph.
    /// Populated by the set_font_fallback protocol command.
    private var fallbackFonts: [CTFont] = []

    /// Protocol weight byte → NSFontManager weight (0-15 scale).
    static let weightMap: [UInt8: Int] = [
        0: 3,   // thin
        1: 4,   // light
        2: 5,   // regular
        3: 6,   // medium
        4: 7,   // semibold
        5: 8,   // bold
        6: 9,   // heavy
        7: 10   // black
    ]

    /// The NSFontManager weight used to resolve this font.
    let fontWeight: Int

    /// Load a font by name at the given point size.
    ///
    /// Font name resolution uses NSFontManager so both display names
    /// ("JetBrains Mono") and PostScript names ("JetBrainsMonoNF-Regular")
    /// work. Falls back to the system monospace font if not found.
    ///
    /// `scale` is the backing scale factor (2.0 for Retina).
    /// `ligatures` enables programming ligature shaping via CoreText.
    /// `weight` is the protocol weight byte (0-7), mapped to NSFontManager's scale.
    init(name: String, size: CGFloat, scale: CGFloat, ligatures: Bool = true, weight: UInt8 = 2) {
        let nsFontWeight = FontFace.weightMap[weight] ?? 5
        self.fontWeight = nsFontWeight
        self.familyName = name
        let font = FontFace.resolveFont(name: name, size: size, weight: nsFontWeight)
        self.ctFont = font
        self.scale = scale
        self.ligaturesEnabled = ligatures

        self.ctFontBold = FontFace.deriveVariant(font, traits: .boldTrait)
        self.ctFontItalic = FontFace.deriveVariant(font, traits: .italicTrait)
        self.ctFontBoldItalic = FontFace.deriveVariant(font, traits: [.boldTrait, .italicTrait])

        if ctFontBold == nil {
            PortLogger.warn("Font '\(name)' has no bold variant; bold text will render as regular")
        }
        if ctFontItalic == nil {
            PortLogger.warn("Font '\(name)' has no italic variant; italic text will render as regular")
        }

        let asc = CTFontGetAscent(font)
        let desc = CTFontGetDescent(font)
        let lead = CTFontGetLeading(font)
        self.ascent = asc
        self.descent = desc
        self.leading = lead

        let advanceWidth = FontFace.monospaceAdvance(font)
        self.cellWidth = Int(ceil(advanceWidth))
        self.cellHeight = Int(ceil(asc + desc + lead))

        self.weightedFonts[weight] = font
    }

    /// Derive a font variant using CTFontCreateCopyWithSymbolicTraits.
    private static func deriveVariant(_ base: CTFont, traits: CTFontSymbolicTraits) -> CTFont? {
        let size = CTFontGetSize(base)
        guard let derived = CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) else {
            return nil
        }
        return derived
    }

    /// Returns the CTFont for the given style bits (bold=0x01, italic=0x04).
    func fontForStyle(_ style: UInt8) -> CTFont {
        switch style & FONT_STYLE_MASK {
        case 0x05: return ctFontBoldItalic ?? ctFont
        case 0x01: return ctFontBold ?? ctFont
        case 0x04: return ctFontItalic ?? ctFont
        default:   return ctFont
        }
    }

    /// Returns a CTFont at the specified protocol weight (0-7).
    func fontForWeight(_ weight: UInt8, isItalic: Bool = false) -> CTFont {
        let baseFont = weightedFont(weight)
        if isItalic {
            return FontFace.deriveVariant(baseFont, traits: .italicTrait) ?? baseFont
        }
        return baseFont
    }

    /// Lazily resolves and caches a CTFont at the given protocol weight.
    private func weightedFont(_ weight: UInt8) -> CTFont {
        if let cached = weightedFonts[weight] {
            return cached
        }

        let nsFontWeight = FontFace.weightMap[weight] ?? 5
        let size = CTFontGetSize(ctFont)
        let resolved = FontFace.resolveFont(name: familyName, size: size, weight: nsFontWeight)
        weightedFonts[weight] = resolved
        return resolved
    }

    /// Resolve a font name to a CTFont, trying multiple strategies.
    private static func resolveFont(name: String, size: CGFloat, weight: Int = 5) -> CTFont {
        let directFont = CTFontCreateWithName(name as CFString, size, nil)
        let directName = CTFontCopyPostScriptName(directFont) as String
        if directName.lowercased().contains(name.lowercased().replacingOccurrences(of: " ", with: "").prefix(8).lowercased()) {
            return directFont
        }

        let fm = NSFontManager.shared
        if let nsFont = fm.font(withFamily: name, traits: NSFontTraitMask.fixedPitchFontMask, weight: weight, size: size) {
            return nsFont as CTFont
        }

        if let nsFont = fm.font(withFamily: name, traits: [], weight: weight, size: size) {
            return nsFont as CTFont
        }

        PortLogger.warn("Font '\(name)' weight \(weight) not found, falling back to system monospace")
        return CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil)!
    }

    /// Configure the font fallback chain from a list of family names.
    func setFallbackFonts(_ families: [String]) {
        let size = CTFontGetSize(ctFont)
        fallbackFonts = families.compactMap { name in
            let fm = NSFontManager.shared
            if let nsFont = fm.font(withFamily: name, traits: .fixedPitchFontMask, weight: 5, size: size) {
                PortLogger.info("Font fallback: loaded '\(name)'")
                return nsFont as CTFont
            }
            if let nsFont = fm.font(withFamily: name, traits: [], weight: 5, size: size) {
                PortLogger.info("Font fallback: loaded '\(name)' (non-fixed-pitch)")
                return nsFont as CTFont
            }
            let direct = CTFontCreateWithName(name as CFString, size, nil)
            let directName = CTFontCopyPostScriptName(direct) as String
            if directName.lowercased().contains(name.lowercased().prefix(6).lowercased()) {
                PortLogger.info("Font fallback: loaded '\(name)' (PostScript)")
                return direct
            }
            PortLogger.warn("Font fallback: '\(name)' not found, skipping")
            return nil
        }
    }

    // MARK: - Private

    /// Get the monospace advance width using the 'M' glyph.
    private static func monospaceAdvance(_ font: CTFont) -> CGFloat {
        var chars: [UniChar] = [0x4D]
        var glyphs: [CGGlyph] = [0]
        CTFontGetGlyphsForCharacters(font, &chars, &glyphs, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .default, &glyphs, &advance, 1)
        return advance.width
    }
}
