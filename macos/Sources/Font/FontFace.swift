/// CoreText font loader and glyph rasterizer.
///
/// Loads a monospace font, extracts cell metrics, and rasterizes individual
/// glyphs into BGRA bitmaps for the atlas. Uses the same rendering pipeline
/// as native macOS apps: DeviceRGB bitmap context, font smoothing, Retina
/// scaling via CGContextScaleCTM.

import CoreText
import CoreGraphics
import Foundation
import AppKit

/// Information about a rasterized glyph for atlas storage and positioning.
struct GlyphInfo {
    /// Top-left corner in the atlas texture.
    var atlasX: UInt32
    var atlasY: UInt32
    /// Bitmap dimensions in pixels (at backing scale).
    var width: UInt32
    var height: UInt32
    /// Bearing offsets in point space (fractional precision preserved).
    var offsetX: CGFloat
    var offsetY: CGFloat
    /// True for color emoji; the shader samples BGRA directly instead of fg * alpha.
    var isColor: Bool
}

/// A cached glyph entry combining atlas location and rendering metrics.
struct Glyph {
    var atlasX: UInt32
    var atlasY: UInt32
    var width: UInt32
    var height: UInt32
    var offsetX: CGFloat
    var offsetY: CGFloat
    var isColor: Bool
}

/// Cache key for glyphs: codepoint + font weight + italic flag.
///
/// The key uses the protocol weight byte (0-7) and a boolean italic flag
/// rather than the old bold/italic style bits. This allows per-span font
/// weight selection beyond binary bold/regular.
struct GlyphKey: Hashable {
    let codepoint: UInt32
    /// Protocol font weight (0=thin, 1=light, 2=regular, 3=medium, 4=semibold, 5=bold, 6=heavy, 7=black).
    let weight: UInt8
    /// Whether this glyph uses the italic variant.
    let italic: Bool
}

/// Cache key for ligatures: text + font weight + italic flag.
struct LigatureKey: Hashable {
    let text: String
    /// Protocol font weight (0-7).
    let weight: UInt8
    /// Whether this ligature uses the italic variant.
    let italic: Bool
}

/// Font face with glyph cache and atlas.
///
/// Holds up to four CTFont variants (regular, bold, italic, bold-italic)
/// sharing a single glyph atlas. The glyph cache uses a compound key
/// (codepoint + style bits) so each variant's glyphs are cached separately
/// but packed into the same GPU texture.
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

    let atlas: GlyphAtlas
    private var cache: [GlyphKey: Glyph] = [:]

    /// Whether programming ligatures are enabled. When true, multi-character
    /// sequences like `->`, `!=`, `=>` are shaped via CoreText and rendered
    /// as a single wide glyph spanning multiple cells.
    let ligaturesEnabled: Bool

    /// Cache of shaped ligature glyphs keyed by text + style.
    /// A nil value means "no ligature for this sequence."
    private var ligatureCache: [LigatureKey: LigatureResult?] = [:]

    /// Cache of CTFont instances at different weights, lazily loaded via NSFontManager.
    /// Keyed by protocol weight byte (0-7). The base font's weight is pre-populated.
    private var weightedFonts: [UInt8: CTFont] = [:]

    /// The font family name (for resolving weight variants via NSFontManager).
    private let familyName: String

    /// Protocol weight byte → NSFontManager weight (0-15 scale).
    /// NSFontManager uses: 2=ultralight, 3=thin, 4=light, 5=regular,
    /// 6=medium, 7=semibold, 8=bold, 9=heavy, 10+=black.
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

        // Derive bold, italic, and bold-italic variants from the base font.
        // CTFontCreateCopyWithSymbolicTraits returns nil if the variant doesn't
        // exist in the font family. We fall back to the regular font at
        // rasterization time when a variant is missing.
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

        self.atlas = GlyphAtlas(initialSize: 512)

        // Pre-populate the weighted font cache with the base weight.
        self.weightedFonts[weight] = font
    }

    /// Derive a font variant using CTFontCreateCopyWithSymbolicTraits.
    /// Returns nil if the font family doesn't have the requested variant.
    private static func deriveVariant(_ base: CTFont, traits: CTFontSymbolicTraits) -> CTFont? {
        let size = CTFontGetSize(base)
        // Pass the desired traits as both the value and the mask so only
        // the requested bits are changed.
        guard let derived = CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) else {
            return nil
        }
        return derived
    }

    /// Returns the CTFont for the given style bits (bold=0x01, italic=0x04).
    /// Falls back to regular if the requested variant is unavailable.
    func fontForStyle(_ style: UInt8) -> CTFont {
        switch style & FONT_STYLE_MASK {
        case 0x05: return ctFontBoldItalic ?? ctFont  // bold(0x01) | italic(0x04)
        case 0x01: return ctFontBold ?? ctFont        // bold only
        case 0x04: return ctFontItalic ?? ctFont      // italic only
        default:   return ctFont                      // regular
        }
    }

    /// Returns a CTFont at the specified protocol weight (0-7).
    ///
    /// Lazily resolves weight variants via NSFontManager and caches them.
    /// When `isItalic` is true, derives the italic variant from the weighted font.
    /// Falls back to the base font if the weight variant can't be resolved.
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

    /// Resolve a font name to a CTFont, trying multiple strategies:
    /// 1. PostScript name via CTFontCreateWithName
    /// 2. Display name via NSFontManager (with weight)
    /// 3. Fallback to system monospace
    private static func resolveFont(name: String, size: CGFloat, weight: Int = 5) -> CTFont {
        // Try PostScript name first (e.g., "JetBrainsMonoNF-Regular").
        // PostScript names encode weight in the name itself, so skip weight
        // matching here.
        let directFont = CTFontCreateWithName(name as CFString, size, nil)
        let directName = CTFontCopyPostScriptName(directFont) as String
        // CTFontCreateWithName always returns a font; check if it matched.
        if directName.lowercased().contains(name.lowercased().replacingOccurrences(of: " ", with: "").prefix(8).lowercased()) {
            return directFont
        }

        // Try NSFontManager with display name and requested weight.
        let fm = NSFontManager.shared
        if let nsFont = fm.font(withFamily: name, traits: NSFontTraitMask.fixedPitchFontMask, weight: weight, size: size) {
            return nsFont as CTFont
        }

        // Try without fixed-pitch trait (some fonts don't report it).
        if let nsFont = fm.font(withFamily: name, traits: [], weight: weight, size: size) {
            return nsFont as CTFont
        }

        // Fallback: system monospace.
        PortLogger.warn("Font '\(name)' weight \(weight) not found, falling back to system monospace")
        return CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil)!
    }

    /// Look up a glyph by codepoint, weight, and italic flag, rasterizing on first access.
    ///
    /// `weight` is the protocol font weight byte (0-7). `italic` selects the italic
    /// variant. The glyph is rasterized using the appropriate font variant and
    /// cached with a compound key.
    ///
    /// For backward compatibility, also accepts the old `style` parameter
    /// (bold/italic bits) via the convenience overload below.
    func getGlyph(_ codepoint: UInt32, weight: UInt8, italic: Bool) -> Glyph? {
        let key = GlyphKey(codepoint: codepoint, weight: weight, italic: italic)
        if let cached = cache[key] {
            return cached
        }

        let font = fontForWeight(weight, isItalic: italic)
        guard let info = rasterizeGlyph(codepoint, using: font) else { return nil }

        let glyph = Glyph(
            atlasX: info.atlasX, atlasY: info.atlasY,
            width: info.width, height: info.height,
            offsetX: info.offsetX, offsetY: info.offsetY,
            isColor: info.isColor
        )
        cache[key] = glyph
        return glyph
    }

    /// Convenience: look up a glyph using legacy style bits (bold=0x01, italic=0x04).
    ///
    /// Maps the bold bit to weight 5 (bold) or the base font's weight,
    /// and the italic bit to the italic flag.
    func getGlyph(_ codepoint: UInt32, style: UInt8 = 0) -> Glyph? {
        let isBold = (style & 0x01) != 0
        let isItalic = (style & 0x04) != 0
        let weight: UInt8 = isBold ? 5 : 2  // bold=5, regular=2
        return getGlyph(codepoint, weight: weight, italic: isItalic)
    }

    /// Pre-rasterize all printable ASCII glyphs for the regular variant.
    /// Other variants are rasterized lazily on first use.
    func preloadAscii() {
        for cp: UInt32 in 0x20...0x7E {
            _ = getGlyph(cp, style: 0)
        }
    }

    // MARK: - Ligature shaping

    /// Result of shaping a multi-character sequence into a ligature glyph.
    struct LigatureResult {
        /// The rasterized glyph covering the full ligature width.
        let glyph: Glyph
        /// Number of cells this ligature spans.
        let cellCount: Int
    }

    /// Attempt to shape a string into a ligature glyph.
    ///
    /// Returns a `LigatureResult` if the font produces fewer glyphs than
    /// input characters (indicating a ligature substitution happened).
    /// Returns nil if no ligature was produced or ligatures are disabled.
    ///
    /// `style` is the bold/italic bits (legacy). The correct font variant is
    /// used for shaping so bold ligatures render at the right weight.
    /// Use `shapeLigature(_:weight:italic:)` for per-span weight control.
    func shapeLigature(_ text: String, style: UInt8 = 0) -> LigatureResult? {
        let isBold = (style & 0x01) != 0
        let isItalic = (style & 0x04) != 0
        let weight: UInt8 = isBold ? 5 : 2
        return shapeLigature(text, weight: weight, italic: isItalic)
    }

    /// Attempt to shape a string into a ligature glyph with explicit weight control.
    func shapeLigature(_ text: String, weight: UInt8, italic: Bool) -> LigatureResult? {
        guard ligaturesEnabled, text.count >= 2 else { return nil }

        let key = LigatureKey(text: text, weight: weight, italic: italic)
        if let cached = ligatureCache[key] {
            return cached
        }

        let font = fontForWeight(weight, isItalic: italic)
        let result = detectAndRasterizeLigature(text, using: font)
        ligatureCache[key] = result
        return result
    }

    /// Core ligature detection using CTLine shaping.
    ///
    /// Creates an attributed string with the given font, asks CoreText to shape
    /// it, then inspects the glyph runs. If the number of glyphs is less than
    /// the number of characters, a ligature substitution occurred.
    private func detectAndRasterizeLigature(_ text: String, using font: CTFont) -> LigatureResult? {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font as Any,
            // Enable all ligatures (1 = standard, 2 = all including rare ones).
            .ligature: 2
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrStr)

        // Count total glyphs produced.
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        var totalGlyphs = 0
        for run in runs {
            totalGlyphs += CTRunGetGlyphCount(run)
        }

        let charCount = text.count

        // If CoreText produced the same number of glyphs as characters,
        // no ligature happened. (Or the font doesn't have one.)
        guard totalGlyphs < charCount else { return nil }

        // Rasterize the entire shaped line as a single wide glyph.
        let cellCount = charCount
        let pixelWidth = UInt32(ceil(CGFloat(cellWidth * cellCount) * scale))
        let pixelHeight = UInt32(ceil(CGFloat(cellHeight) * scale))

        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        // Reserve atlas space.
        let pad: UInt32 = 1
        let paddedW = pixelWidth + pad * 2
        let paddedH = pixelHeight + pad * 2

        guard let region = atlas.reserve(width: paddedW, height: paddedH) ?? {
            atlas.grow(newSize: atlas.size * 2)
            return atlas.reserve(width: paddedW, height: paddedH)
        }() else { return nil }

        // Rasterize the shaped line into a bitmap.
        let bgraBuf = rasterizeLine(line, width: Int(pixelWidth), height: Int(pixelHeight))

        let glyphX = region.x + pad
        let glyphY = region.y + pad
        atlas.set(x: glyphX, y: glyphY, width: pixelWidth, height: pixelHeight, data: bgraBuf)

        let glyph = Glyph(
            atlasX: glyphX, atlasY: glyphY,
            width: pixelWidth, height: pixelHeight,
            offsetX: 0,
            offsetY: ascent,
            isColor: false
        )

        return LigatureResult(glyph: glyph, cellCount: cellCount)
    }

    /// Rasterize a CTLine into a BGRA bitmap (white + alpha coverage).
    private func rasterizeLine(_ line: CTLine, width w: Int, height h: Int) -> [UInt8] {
        let grayStride = w
        var grayBuf = [UInt8](repeating: 0, count: grayStride * h)

        guard let graySpace = CGColorSpace(name: CGColorSpace.linearGray),
              let ctx = CGContext(
                  data: &grayBuf,
                  width: w,
                  height: h,
                  bitsPerComponent: 8,
                  bytesPerRow: grayStride,
                  space: graySpace,
                  bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
              ) else {
            return [UInt8](repeating: 0, count: w * h * 4)
        }

        ctx.scaleBy(x: scale, y: scale)
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(true)
        ctx.setAllowsFontSubpixelPositioning(true)
        ctx.setShouldSubpixelPositionFonts(true)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.setFillColor(gray: 1.0, alpha: 1.0)

        // Draw at baseline. CoreText uses a bottom-up coordinate system.
        let textPos = CGPoint(x: 0, y: descent)
        ctx.textPosition = textPos
        CTLineDraw(line, ctx)

        // Convert coverage to BGRA.
        let bgraStride = w * 4
        var bgraBuf = [UInt8](repeating: 0, count: bgraStride * h)
        for row in 0..<h {
            for col in 0..<w {
                let grayOff = row * grayStride + col
                let bgraOff = row * bgraStride + col * 4
                bgraBuf[bgraOff + 0] = 255
                bgraBuf[bgraOff + 1] = 255
                bgraBuf[bgraOff + 2] = 255
                bgraBuf[bgraOff + 3] = grayBuf[grayOff]
            }
        }

        return bgraBuf
    }

    // MARK: - Private

    /// Get the monospace advance width using the 'M' glyph.
    private static func monospaceAdvance(_ font: CTFont) -> CGFloat {
        var chars: [UniChar] = [0x4D] // 'M'
        var glyphs: [CGGlyph] = [0]
        CTFontGetGlyphsForCharacters(font, &chars, &glyphs, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .default, &glyphs, &advance, 1)
        return advance.width
    }

    /// Rasterize a single codepoint into the atlas using the given font variant.
    private func rasterizeGlyph(_ codepoint: UInt32, using baseFont: CTFont? = nil) -> GlyphInfo? {
        let primaryFont = baseFont ?? ctFont
        // Convert codepoint to UTF-16 for CoreText.
        var utf16: [UniChar] = []
        if codepoint <= 0xFFFF {
            utf16 = [UniChar(codepoint)]
        } else {
            // Surrogate pair.
            let cp = codepoint - 0x10000
            utf16 = [UniChar(0xD800 + (cp >> 10)), UniChar(0xDC00 + (cp & 0x3FF))]
        }

        // Look up glyph ID using the requested font variant, with fallback for emoji.
        var glyphs: [CGGlyph] = Array(repeating: 0, count: utf16.count)
        var renderFont = primaryFont
        var ownsFallback = false

        if !CTFontGetGlyphsForCharacters(primaryFont, &utf16, &glyphs, utf16.count) {
            // Variant font doesn't have this glyph; ask CoreText for a fallback.
            let cfStr = CFStringCreateWithCharacters(nil, &utf16, utf16.count)!
            let range = CFRange(location: 0, length: utf16.count)
            let fallback = CTFontCreateForString(primaryFont, cfStr, range)
            if CTFontGetGlyphsForCharacters(fallback, &utf16, &glyphs, utf16.count) {
                renderFont = fallback
                ownsFallback = true
            }
        }
        _ = ownsFallback // ARC handles lifetime

        let glyphId = glyphs[0]

        // Get bounding rect in point space.
        var boundingRect = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(renderFont, .default, [glyphId], &boundingRect, 1)

        // Scale to pixel dimensions for the bitmap.
        let bmpWidth = UInt32(ceil(boundingRect.width * scale))
        let bmpHeight = UInt32(ceil(boundingRect.height * scale))

        let scaledCellW = UInt32(ceil(CGFloat(cellWidth) * scale))
        let scaledCellH = UInt32(ceil(CGFloat(cellHeight) * scale))
        let renderWidth = bmpWidth == 0 ? scaledCellW : bmpWidth
        let renderHeight = bmpHeight == 0 ? scaledCellH : bmpHeight

        // Detect color emoji via 'sbix' table.
        let isColor: Bool = {
            if let data = CTFontCopyTable(renderFont, CTFontTableTag(kCTFontTableSbix), []) {
                _ = data // release via ARC
                return true
            }
            return false
        }()

        // Reserve atlas space with 1px padding to prevent texture bleeding.
        let pad: UInt32 = 1
        let paddedW = renderWidth + pad * 2
        let paddedH = renderHeight + pad * 2
        guard let atlasRegion = atlas.reserve(width: paddedW, height: paddedH) else {
            // Atlas full; grow and retry.
            atlas.grow(newSize: atlas.size * 2)
            guard let retryRegion = atlas.reserve(width: paddedW, height: paddedH) else {
                return nil
            }
            return rasterizeIntoRegion(retryRegion, pad: pad, renderWidth: renderWidth, renderHeight: renderHeight,
                                       renderFont: renderFont, glyphId: glyphId, boundingRect: boundingRect, isColor: isColor)
        }

        return rasterizeIntoRegion(atlasRegion, pad: pad, renderWidth: renderWidth, renderHeight: renderHeight,
                                   renderFont: renderFont, glyphId: glyphId, boundingRect: boundingRect, isColor: isColor)
    }

    private func rasterizeIntoRegion(_ region: AtlasRegion, pad: UInt32,
                                     renderWidth: UInt32, renderHeight: UInt32,
                                     renderFont: CTFont, glyphId: CGGlyph,
                                     boundingRect: CGRect, isColor: Bool) -> GlyphInfo {
        let w = Int(renderWidth)
        let h = Int(renderHeight)

        let bgraBuf: [UInt8]

        if isColor {
            bgraBuf = rasterizeColorGlyph(w: w, h: h, renderFont: renderFont, glyphId: glyphId, boundingRect: boundingRect)
        } else {
            bgraBuf = rasterizeTextGlyph(w: w, h: h, renderFont: renderFont, glyphId: glyphId, boundingRect: boundingRect)
        }

        // Write into the padded atlas region.
        let glyphX = region.x + pad
        let glyphY = region.y + pad
        atlas.set(x: glyphX, y: glyphY, width: renderWidth, height: renderHeight, data: bgraBuf)

        return GlyphInfo(
            atlasX: glyphX, atlasY: glyphY,
            width: renderWidth, height: renderHeight,
            offsetX: boundingRect.origin.x,
            offsetY: boundingRect.origin.y + boundingRect.height,
            isColor: isColor
        )
    }

    /// Rasterize a text glyph using a grayscale alpha-only context.
    ///
    /// Following Ghostty's approach: render into a single-channel context
    /// (linearGray + alphaOnly) to get clean coverage values. Font smoothing
    /// still works in this mode but produces grayscale coverage rather than
    /// per-channel RGB differences. The result is stored as white + alpha
    /// in the BGRA atlas.
    private func rasterizeTextGlyph(w: Int, h: Int, renderFont: CTFont,
                                     glyphId: CGGlyph, boundingRect: CGRect) -> [UInt8] {
        // Single-channel grayscale context for coverage.
        let grayStride = w
        var grayBuf = [UInt8](repeating: 0, count: grayStride * h)

        guard let graySpace = CGColorSpace(name: CGColorSpace.linearGray),
              let ctx = CGContext(
                  data: &grayBuf,
                  width: w,
                  height: h,
                  bitsPerComponent: 8,
                  bytesPerRow: grayStride,
                  space: graySpace,
                  bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
              ) else {
            return [UInt8](repeating: 0, count: w * h * 4)
        }

        // Scale for Retina.
        ctx.scaleBy(x: scale, y: scale)

        // Font rendering settings.
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(true)
        ctx.setAllowsFontSubpixelPositioning(true)
        ctx.setShouldSubpixelPositionFonts(true)
        ctx.setAllowsFontSubpixelQuantization(false)
        ctx.setShouldSubpixelQuantizeFonts(false)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)

        // White fill for maximum coverage in the alpha channel.
        ctx.setFillColor(gray: 1.0, alpha: 1.0)

        // Draw the glyph.
        var position = CGPoint(x: -boundingRect.origin.x, y: -boundingRect.origin.y)
        var glyph = glyphId
        CTFontDrawGlyphs(renderFont, &glyph, &position, 1, ctx)

        // Convert single-channel coverage to BGRA (white + alpha).
        let bgraStride = w * 4
        var bgraBuf = [UInt8](repeating: 0, count: bgraStride * h)
        for row in 0..<h {
            for col in 0..<w {
                let grayOff = row * grayStride + col
                let bgraOff = row * bgraStride + col * 4
                bgraBuf[bgraOff + 0] = 255           // B
                bgraBuf[bgraOff + 1] = 255           // G
                bgraBuf[bgraOff + 2] = 255           // R
                bgraBuf[bgraOff + 3] = grayBuf[grayOff] // A = coverage
            }
        }

        return bgraBuf
    }

    /// Rasterize a color emoji using an RGBA context in device RGB.
    private func rasterizeColorGlyph(w: Int, h: Int, renderFont: CTFont,
                                      glyphId: CGGlyph, boundingRect: CGRect) -> [UInt8] {
        let rgbaStride = w * 4
        var rgbaBuf = [UInt8](repeating: 0, count: rgbaStride * h)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &rgbaBuf,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: rgbaStride,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return [UInt8](repeating: 0, count: w * h * 4)
        }

        ctx.scaleBy(x: scale, y: scale)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)

        var position = CGPoint(x: -boundingRect.origin.x, y: -boundingRect.origin.y)
        var glyph = glyphId
        CTFontDrawGlyphs(renderFont, &glyph, &position, 1, ctx)

        // Convert RGBA to BGRA (premultiplied).
        var bgraBuf = [UInt8](repeating: 0, count: rgbaStride * h)
        for row in 0..<h {
            for col in 0..<w {
                let off = row * rgbaStride + col * 4
                bgraBuf[off + 0] = rgbaBuf[off + 2] // B
                bgraBuf[off + 1] = rgbaBuf[off + 1] // G
                bgraBuf[off + 2] = rgbaBuf[off + 0] // R
                bgraBuf[off + 3] = rgbaBuf[off + 3] // A
            }
        }

        return bgraBuf
    }
}
