/// CoreText font loader and glyph rasterizer.
///
/// Loads a monospace font, extracts cell metrics, and rasterizes individual
/// glyphs into BGRA bitmaps for the atlas. Uses the same rendering pipeline
/// as native macOS apps: DeviceRGB bitmap context, font smoothing, Retina
/// scaling via CGContextScaleCTM.

import CoreText
import CoreGraphics
import Foundation

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

/// Font face with glyph cache and atlas.
final class FontFace {
    let ctFont: CTFont
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
    private var cache: [UInt32: Glyph] = [:]

    /// Load a font by name at the given point size.
    /// Falls back to the system monospace font if the named font isn't found.
    /// `scale` is the backing scale factor (2.0 for Retina).
    init(name: String, size: CGFloat, scale: CGFloat) {
        let font: CTFont
        if let named = CTFontCreateWithName(name as CFString, size, nil) as CTFont? {
            font = named
        } else {
            // Fallback: system monospace (UserFixedPitch).
            font = CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil)!
        }

        self.ctFont = font
        self.scale = scale

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
    }

    /// Look up a glyph by codepoint, rasterizing on first access.
    func getGlyph(_ codepoint: UInt32) -> Glyph? {
        if let cached = cache[codepoint] {
            return cached
        }

        guard let info = rasterizeGlyph(codepoint) else { return nil }

        let glyph = Glyph(
            atlasX: info.atlasX, atlasY: info.atlasY,
            width: info.width, height: info.height,
            offsetX: info.offsetX, offsetY: info.offsetY,
            isColor: info.isColor
        )
        cache[codepoint] = glyph
        return glyph
    }

    /// Pre-rasterize all printable ASCII glyphs to avoid hitches during rendering.
    func preloadAscii() {
        for cp: UInt32 in 0x20...0x7E {
            _ = getGlyph(cp)
        }
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

    /// Rasterize a single codepoint into the atlas.
    private func rasterizeGlyph(_ codepoint: UInt32) -> GlyphInfo? {
        // Convert codepoint to UTF-16 for CoreText.
        var utf16: [UniChar] = []
        if codepoint <= 0xFFFF {
            utf16 = [UniChar(codepoint)]
        } else {
            // Surrogate pair.
            let cp = codepoint - 0x10000
            utf16 = [UniChar(0xD800 + (cp >> 10)), UniChar(0xDC00 + (cp & 0x3FF))]
        }

        // Look up glyph ID, with font fallback for emoji.
        var glyphs: [CGGlyph] = Array(repeating: 0, count: utf16.count)
        var renderFont = ctFont
        var ownsFallback = false

        if !CTFontGetGlyphsForCharacters(ctFont, &utf16, &glyphs, utf16.count) {
            // Primary font doesn't have this glyph; ask CoreText for a fallback.
            let cfStr = CFStringCreateWithCharacters(nil, &utf16, utf16.count)!
            let range = CFRange(location: 0, length: utf16.count)
            let fallback = CTFontCreateForString(ctFont, cfStr, range)
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
