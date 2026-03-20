/// CoreText line rendering engine.
///
/// Converts styled text runs into cached Metal textures via CoreText:
/// 1. Convert `[StyledRun]` → `NSAttributedString` (map Face attributes to CoreText)
/// 2. Create `CTLine` from the attributed string
/// 3. Render into a `CGBitmapContext` sized to `linePixelWidth x lineHeight` at Retina scale
/// 4. Upload to a `MTLTexture` (create or reuse from cache)
/// 5. Cache per line with invalidation when runs change (content hash)
///
/// This engine is decoupled from the live renderer so it can be tested
/// independently: given styled runs, it produces a texture of known dimensions.

import Foundation
import CoreText
import CoreGraphics
import Metal
import AppKit

/// A cached line texture with its content hash for invalidation.
struct CachedLineTexture {
    /// The Metal texture containing the rendered line.
    let texture: MTLTexture
    /// Content hash of the `[StyledRun]` that produced this texture.
    let contentHash: Int
    /// Frame number when this texture was last used (for LRU eviction).
    var lastUsedFrame: UInt64
    /// Pixel width of the rendered content.
    let pixelWidth: Int
    /// Pixel height of the rendered content.
    let pixelHeight: Int
}

/// Renders styled text runs into Metal textures using CoreText.
///
/// Each line's runs are converted to an NSAttributedString, shaped by
/// CoreText into a CTLine, rasterized into a bitmap context, then uploaded
/// to a Metal texture. Textures are cached per line and invalidated when
/// the content hash changes.
final class CoreTextLineRenderer {
    /// The Metal device for texture creation.
    private let device: MTLDevice

    /// Per-line texture cache keyed by row index.
    private var lineCache: [UInt16: CachedLineTexture] = [:]

    /// Current frame counter for LRU eviction.
    private var frameCounter: UInt64 = 0

    /// Number of frames a texture can go unused before eviction.
    private let evictionThreshold: UInt64 = 120  // ~2 seconds at 60fps

    /// Font manager for resolving font faces by ID.
    private let fontManager: FontManager

    /// Texture descriptor reused for line textures (avoids repeated allocation).
    private let textureDescriptor: MTLTextureDescriptor

    /// Maximum line width in pixels (based on viewport).
    private var maxLinePixelWidth: Int

    /// Line height in pixels at backing scale.
    let linePixelHeight: Int

    /// Backing scale factor (2.0 for Retina).
    let scale: CGFloat

    /// Cell width in points (for column-to-pixel mapping).
    let cellWidth: CGFloat

    /// Cell height in points.
    let cellHeight: CGFloat

    /// Font ascent in points (for baseline positioning).
    let ascent: CGFloat

    /// Font descent in points.
    let descent: CGFloat

    /// Attribute bitmask constants (matching protocol/CellGrid).
    private static let ATTR_BOLD: UInt8 = 0x01
    private static let ATTR_UNDERLINE: UInt8 = 0x02
    private static let ATTR_ITALIC: UInt8 = 0x04
    private static let ATTR_REVERSE: UInt8 = 0x08
    private static let ATTR_STRIKETHROUGH: UInt8 = 0x10

    init(device: MTLDevice, fontManager: FontManager) {
        self.device = device
        self.fontManager = fontManager
        self.scale = fontManager.scale
        self.cellWidth = CGFloat(fontManager.cellWidth)
        self.cellHeight = CGFloat(fontManager.cellHeight)
        self.ascent = fontManager.ascent
        self.descent = fontManager.primary.descent
        self.linePixelHeight = Int(ceil(cellHeight * scale))

        // Default max width; updated on viewport resize.
        self.maxLinePixelWidth = Int(ceil(120.0 * cellWidth * scale))

        // Pre-configure texture descriptor.
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: self.maxLinePixelWidth,
            height: self.linePixelHeight,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .managed
        self.textureDescriptor = desc
    }

    /// Update the maximum line width when the viewport changes.
    func updateViewportWidth(cols: UInt16) {
        let newWidth = Int(ceil(CGFloat(cols) * cellWidth * scale))
        if newWidth != maxLinePixelWidth {
            maxLinePixelWidth = newWidth
            textureDescriptor.width = newWidth
            // Invalidate all cached textures since they may be wrong size.
            lineCache.removeAll(keepingCapacity: true)
        }
    }

    /// Render a line's styled runs into a cached Metal texture.
    ///
    /// Returns the cached texture if the content hasn't changed (hash match),
    /// or rasterizes a new texture and caches it.
    ///
    /// Returns nil if the line has no runs or texture creation fails.
    func renderLine(row: UInt16, runs: [StyledRun], contentHash: Int) -> CachedLineTexture? {
        guard !runs.isEmpty else { return nil }

        // Check cache.
        if var cached = lineCache[row], cached.contentHash == contentHash {
            cached.lastUsedFrame = frameCounter
            lineCache[row] = cached
            return cached
        }

        // Build NSAttributedString from runs.
        let attributedString = buildAttributedString(runs: runs)

        // Create CTLine.
        let ctLine = CTLineCreateWithAttributedString(attributedString)

        // Determine line width from CTLine typographic bounds.
        var lineAscent: CGFloat = 0
        var lineDescent: CGFloat = 0
        var lineLeading: CGFloat = 0
        let lineWidth = CTLineGetTypographicBounds(ctLine, &lineAscent, &lineDescent, &lineLeading)

        // Size the bitmap to cover the full line.
        let pixelWidth = min(Int(ceil(lineWidth * scale)), maxLinePixelWidth)
        let pixelHeight = linePixelHeight

        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        // Rasterize into a BGRA bitmap.
        let bgraData = rasterizeLine(ctLine, runs: runs, width: pixelWidth, height: pixelHeight)

        // Create or reuse texture.
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: pixelWidth,
            height: pixelHeight,
            mipmapped: false
        )
        texDesc.usage = [.shaderRead]
        texDesc.storageMode = .managed

        guard let texture = device.makeTexture(descriptor: texDesc) else { return nil }

        // Upload bitmap data.
        let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                               size: MTLSize(width: pixelWidth, height: pixelHeight, depth: 1))
        bgraData.withUnsafeBytes { ptr in
            texture.replace(region: region, mipmapLevel: 0,
                           withBytes: ptr.baseAddress!, bytesPerRow: pixelWidth * 4)
        }

        let cached = CachedLineTexture(
            texture: texture,
            contentHash: contentHash,
            lastUsedFrame: frameCounter,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
        lineCache[row] = cached
        return cached
    }

    /// Advance the frame counter and evict stale textures.
    func beginFrame() {
        frameCounter += 1

        // Evict textures not used recently.
        let threshold = frameCounter > evictionThreshold ? frameCounter - evictionThreshold : 0
        lineCache = lineCache.filter { $0.value.lastUsedFrame >= threshold }
    }

    /// Clear all cached textures (e.g., on font change or viewport resize).
    func invalidateAll() {
        lineCache.removeAll(keepingCapacity: true)
    }

    /// Number of currently cached line textures.
    var cacheCount: Int { lineCache.count }

    // MARK: - Private

    /// Build an NSAttributedString from styled runs.
    ///
    /// Each run becomes a range in the attributed string with the appropriate
    /// CoreText attributes: font (from weight/italic/fontId), foreground color,
    /// underline style, and strikethrough.
    private func buildAttributedString(runs: [StyledRun]) -> NSAttributedString {
        let result = NSMutableAttributedString()

        // Track the current column position to insert gap-filling spaces
        // when runs aren't contiguous. This ensures each run's text starts
        // at its declared column position in the final CTLine.
        var currentCol: UInt16 = runs.first?.col ?? 0

        for run in runs {
            // Fill gaps between runs with transparent spaces using the
            // primary font so CoreText advances by exactly the right amount.
            if run.col > currentCol {
                let gapCount = Int(run.col - currentCol)
                let gapText = String(repeating: " ", count: gapCount)
                let gapAttrs: [NSAttributedString.Key: Any] = [
                    .font: fontManager.primary.ctFont,
                    .foregroundColor: NSColor.clear,
                    .ligature: 0
                ]
                result.append(NSAttributedString(string: gapText, attributes: gapAttrs))
            }

            let font = resolveFont(for: run)

            // Handle reverse attribute: swap fg and bg colors for text rendering.
            let isReverse = (run.attrs & Self.ATTR_REVERSE) != 0
            let textColor: NSColor
            if isReverse {
                // Reversed: use bg color as text color (or default white if bg is 0).
                textColor = run.bg != 0 ? nsColor(from: run.bg) : NSColor.white
            } else {
                textColor = nsColor(from: run.fg)
            }

            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor,
                // Enable all ligatures for CoreText shaping.
                .ligature: fontManager.primary.ligaturesEnabled ? 2 : 0
            ]

            // Underline.
            if (run.attrs & Self.ATTR_UNDERLINE) != 0 {
                let ulStyle = mapUnderlineStyle(run.underlineStyle)
                attrs[.underlineStyle] = ulStyle.rawValue
                if run.underlineColor != 0 {
                    attrs[.underlineColor] = nsColor(from: run.underlineColor)
                }
            }

            // Strikethrough.
            if (run.attrs & Self.ATTR_STRIKETHROUGH) != 0 {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attrs[.strikethroughColor] = nsColor(from: run.fg)
            }

            let attrStr = NSAttributedString(string: run.text, attributes: attrs)
            result.append(attrStr)

            // Advance current column past this run's text, using display width
            // to correctly handle wide characters (CJK, fullwidth, etc.).
            currentCol = run.col + UInt16(displayWidth(run.text))
        }

        return result
    }

    /// Resolve the correct CTFont for a styled run based on weight, italic, and fontId.
    ///
    /// When the bold attribute bit (0x01) is set and fontWeight is still the
    /// default (2 = regular), override to weight 5 (bold). This matches the
    /// legacy `draw_text` path where only attrs are set without explicit weight.
    private func resolveFont(for run: StyledRun) -> CTFont {
        let face = fontManager.fontFace(for: run.fontId)
        let isItalic = (run.attrs & Self.ATTR_ITALIC) != 0
        let isBold = (run.attrs & Self.ATTR_BOLD) != 0

        // If the bold bit is set but the weight wasn't explicitly overridden
        // (still at default 2=regular), use weight 5 (bold).
        let weight: UInt8 = (isBold && run.fontWeight == 2) ? 5 : run.fontWeight
        return face.fontForWeight(weight, isItalic: isItalic)
    }

    /// Convert a 24-bit RGB value to NSColor.
    private func nsColor(from rgb: UInt32) -> NSColor {
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        return NSColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    /// Map protocol underline style to NSUnderlineStyle.
    private func mapUnderlineStyle(_ style: UInt8) -> NSUnderlineStyle {
        switch style {
        case 1: return .thick          // curl (approximate with thick)
        case 2: return .patternDash    // dashed
        case 3: return .patternDot     // dotted
        case 4: return .double         // double
        default: return .single        // line (default)
        }
    }

    /// Rasterize a CTLine into a premultiplied BGRA bitmap.
    ///
    /// Renders each run's text in its foreground color into a premultiplied BGRA
    /// context with a transparent background. The resulting texture is composited
    /// over the background quad in Metal.
    private func rasterizeLine(_ ctLine: CTLine, runs: [StyledRun],
                                width: Int, height: Int) -> [UInt8] {
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return buffer
        }

        // Scale for Retina.
        ctx.scaleBy(x: scale, y: scale)

        // Font rendering quality settings.
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(true)
        ctx.setAllowsFontSubpixelPositioning(true)
        ctx.setShouldSubpixelPositionFonts(true)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)

        // CoreText uses a bottom-up coordinate system.
        let baselineY = descent

        // The CTLine starts at x=0 within the texture. Column positioning
        // is handled by CoreTextMetalRenderer when it places the texture
        // quad. The gap-filling spaces in buildAttributedString ensure
        // each run's text appears at the correct relative offset.
        ctx.textPosition = CGPoint(x: 0, y: baselineY)

        // Draw the complete CTLine.
        CTLineDraw(ctLine, ctx)

        return buffer
    }

    /// Calculate the display width (in cell columns) of a string,
    /// accounting for wide characters (CJK, emoji, etc.).
    private func displayWidth(_ text: String) -> Int {
        var width = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            // CJK Unified Ideographs and common fullwidth ranges
            if (v >= 0x1100 && v <= 0x115F)    // Hangul Jamo
                || (v >= 0x2E80 && v <= 0x303E)  // CJK Radicals, Kangxi, Ideographic Description, CJK Symbols
                || (v >= 0x3040 && v <= 0x33BF)  // Hiragana, Katakana, Bopomofo, etc.
                || (v >= 0x3400 && v <= 0x4DBF)  // CJK Unified Ideographs Extension A
                || (v >= 0x4E00 && v <= 0xA4CF)  // CJK Unified Ideographs, Yi
                || (v >= 0xAC00 && v <= 0xD7AF)  // Hangul Syllables
                || (v >= 0xF900 && v <= 0xFAFF)  // CJK Compatibility Ideographs
                || (v >= 0xFE30 && v <= 0xFE6F)  // CJK Compatibility Forms
                || (v >= 0xFF01 && v <= 0xFF60)  // Fullwidth Forms
                || (v >= 0xFFE0 && v <= 0xFFE6)  // Fullwidth Signs
                || (v >= 0x20000 && v <= 0x2FA1F) // CJK Extensions B-F, Compatibility Supplement
            {
                width += 2
            } else {
                width += 1
            }
        }
        return width
    }
}
