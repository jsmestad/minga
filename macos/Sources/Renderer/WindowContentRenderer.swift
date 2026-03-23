/// Renders semantic window content (from 0x80 opcode) into Metal textures.
///
/// Converts `GUIVisualRow` data into `NSAttributedString` via CoreText,
/// rasterizes via `BitmapRasterizer`, and caches textures in `LineTextureAtlas`.
/// Styled runs come from pre-resolved `GUIHighlightSpan` structs (BEAM-computed
/// colors) rather than cell-grid draw_text commands.
///
/// Selection, search matches, and diagnostics are NOT baked into the attributed
/// string. They are returned as overlay quad data for Metal to draw as separate
/// geometry (zero re-rasterization when selection changes).

import Foundation
import CoreText
import CoreGraphics
import Metal
import AppKit

/// Renders `GUIWindowContent` rows into cached Metal line textures.
///
/// Each row's text + spans produce an `NSAttributedString` → `CTLine` →
/// bitmap → `MTLTexture`, cached by content hash.
@MainActor
final class WindowContentRenderer {
    /// Metal device for texture creation.
    private let device: MTLDevice

    /// Font manager for resolving font faces.
    private let fontManager: FontManager

    /// Shared pooled bitmap rasterizer.
    private let rasterizer: BitmapRasterizer

    /// Per-row texture cache keyed by display row index.
    private var lineCache: [UInt16: CachedLineTexture] = [:]

    /// Frame counter for LRU eviction.
    private var frameCounter: UInt64 = 0

    /// Eviction threshold (frames).
    private let evictionThreshold: UInt64 = 120

    /// Backing scale factor.
    let scale: CGFloat

    /// Cell width in points.
    let cellWidth: CGFloat

    /// Cell height in points.
    let cellHeight: CGFloat

    /// Line height in pixels at backing scale.
    let linePixelHeight: Int

    /// Font ascent in points.
    let ascent: CGFloat

    /// Font descent in points.
    let descent: CGFloat

    /// Maximum line width in pixels.
    private var maxLinePixelWidth: Int

    /// Default foreground color (24-bit RGB) for text between spans.
    /// Updated from theme's editor_fg color slot each frame.
    var defaultFgRGB: UInt32 = 0xBBC2CF

    /// Font for pill badge text (1.5pt smaller than primary for visual hierarchy).
    private let pillFont: CTFont

    /// Pill font ascent in points.
    private let pillAscent: CGFloat

    /// Pill font descent in points.
    private let pillDescent: CGFloat

    /// Horizontal padding inside pill badges (points).
    private let pillHPad: CGFloat = 5.0

    /// Corner radius for pill rounded rects (points).
    private let pillCornerRadius: CGFloat = 4.0

    /// Gap between line content and first annotation (points).
    let annotationGap: CGFloat = 12.0

    /// Gap between consecutive annotations (points).
    let annotationSpacing: CGFloat = 4.0

    init(device: MTLDevice, fontManager: FontManager, rasterizer: BitmapRasterizer) {
        self.device = device
        self.fontManager = fontManager
        self.rasterizer = rasterizer
        self.scale = fontManager.scale
        self.cellWidth = CGFloat(fontManager.cellWidth)
        self.cellHeight = CGFloat(fontManager.cellHeight)
        self.ascent = fontManager.ascent
        self.descent = fontManager.primary.descent
        self.linePixelHeight = Int(ceil(cellHeight * scale))
        self.maxLinePixelWidth = Int(ceil(200.0 * cellWidth * scale))

        // Derive pill font: 1.5pt smaller than primary.
        let primarySize = CTFontGetSize(fontManager.primary.ctFont)
        self.pillFont = CTFontCreateCopyWithAttributes(
            fontManager.primary.ctFont,
            max(primarySize - 1.5, 8.0),
            nil, nil
        )
        self.pillAscent = CTFontGetAscent(pillFont)
        self.pillDescent = CTFontGetDescent(pillFont)
    }

    /// Update max line width on viewport resize.
    func updateViewportWidth(cols: UInt16) {
        let newWidth = Int(ceil(CGFloat(cols) * cellWidth * scale))
        if newWidth != maxLinePixelWidth {
            maxLinePixelWidth = newWidth
            lineCache.removeAll(keepingCapacity: true)
        }
    }

    /// Advance frame counter and evict stale textures.
    func beginFrame() {
        frameCounter += 1
        let threshold = frameCounter > evictionThreshold ? frameCounter - evictionThreshold : 0
        lineCache = lineCache.filter { $0.value.lastUsedFrame >= threshold }
    }

    /// Clear all cached textures.
    func invalidateAll() {
        lineCache.removeAll(keepingCapacity: true)
    }

    /// Render a single visual row into a cached Metal texture.
    ///
    /// Returns the cached texture if the content hash matches, or
    /// rasterizes a new texture from the row's text + spans.
    func renderRow(displayRow: UInt16, row: GUIVisualRow) -> CachedLineTexture? {
        let hash = Int(row.contentHash)

        // Cache hit check.
        if var cached = lineCache[displayRow], cached.contentHash == hash {
            cached.lastUsedFrame = frameCounter
            lineCache[displayRow] = cached
            return cached
        }

        guard !row.text.isEmpty else { return nil }

        // Build NSAttributedString from spans.
        let attributedString = buildAttributedString(text: row.text, spans: row.spans)

        // Create CTLine and measure.
        let ctLine = CTLineCreateWithAttributedString(attributedString)
        var lineAscent: CGFloat = 0
        var lineDescent: CGFloat = 0
        var lineLeading: CGFloat = 0
        let lineWidth = CTLineGetTypographicBounds(ctLine, &lineAscent, &lineDescent, &lineLeading)

        let pixelWidth = min(Int(ceil(lineWidth * scale)), maxLinePixelWidth)
        let pixelHeight = linePixelHeight
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        // Rasterize into the pooled BGRA bitmap.
        let result = rasterizer.rasterize(ctLine, width: pixelWidth, height: pixelHeight,
                                          scale: scale, descent: descent)

        // Create texture.
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: pixelWidth,
            height: pixelHeight,
            mipmapped: false
        )
        texDesc.usage = [.shaderRead]
        texDesc.storageMode = .managed

        guard let texture = device.makeTexture(descriptor: texDesc) else { return nil }

        // Upload bitmap data. Pooled pointer valid until next rasterize() call.
        let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                               size: MTLSize(width: pixelWidth, height: pixelHeight, depth: 1))
        texture.replace(region: region, mipmapLevel: 0,
                       withBytes: result.pointer, bytesPerRow: result.bytesPerRow)

        let cached = CachedLineTexture(
            texture: texture,
            contentHash: hash,
            lastUsedFrame: frameCounter,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
        lineCache[displayRow] = cached
        return cached
    }

    /// Render a visual row into an atlas slot.
    ///
    /// Checks the atlas cache first (using a key offset of 0xA000 to avoid
    /// collision with content/gutter keys). On miss, rasterizes and uploads.
    func renderRowToAtlas(displayRow: UInt16, row: GUIVisualRow,
                          atlas: LineTextureAtlas) -> AtlasEntry? {
        let hash = Int(row.contentHash)
        let key = 0xA000 + displayRow  // Namespace to avoid collisions

        guard !row.text.isEmpty else { return nil }

        // Atlas cache hit.
        if let entry = atlas.cachedEntry(forKey: key, contentHash: hash) {
            return entry
        }

        // Build attributed string and CTLine.
        let attributedString = buildAttributedString(text: row.text, spans: row.spans)
        let ctLine = CTLineCreateWithAttributedString(attributedString)

        var lineAscent: CGFloat = 0
        var lineDescent: CGFloat = 0
        var lineLeading: CGFloat = 0
        let lineWidth = CTLineGetTypographicBounds(ctLine, &lineAscent, &lineDescent, &lineLeading)

        let pixelWidth = min(Int(ceil(lineWidth * scale)), maxLinePixelWidth)
        guard pixelWidth > 0, linePixelHeight > 0 else { return nil }

        // Rasterize into pooled bitmap.
        let result = rasterizer.rasterize(ctLine, width: pixelWidth, height: linePixelHeight,
                                          scale: scale, descent: descent)

        // Upload into atlas slot.
        return atlas.upload(key: key, contentHash: hash,
                           pointer: result.pointer, pixelWidth: pixelWidth,
                           bytesPerRow: result.bytesPerRow)
    }

    // MARK: - Simple Text Rendering

    /// Renders a plain text string with a single color into the atlas.
    ///
    /// Used for gutter line numbers, diagnostic signs, and separator labels
    /// that don't need the full span-based rendering pipeline. Bypasses
    /// StyledRun entirely: creates NSAttributedString directly from the
    /// text + color, rasterizes via CTLine, and uploads to the atlas.
    ///
    /// - Parameters:
    ///   - text: The string to render.
    ///   - fg: Foreground color as 24-bit RGB.
    ///   - bold: Whether to use the bold font variant.
    ///   - key: Atlas cache key (must be unique within the atlas namespace).
    ///   - contentHash: Content hash for cache invalidation.
    ///   - atlas: The texture atlas to upload into.
    /// - Returns: An atlas entry, or nil if the text is empty.
    func renderSimpleText(_ text: String, fg: UInt32, bold: Bool = false,
                          key: UInt16, contentHash: Int,
                          atlas: LineTextureAtlas) -> AtlasEntry? {
        guard !text.isEmpty else { return nil }

        // Atlas cache hit.
        if let entry = atlas.cachedEntry(forKey: key, contentHash: contentHash) {
            return entry
        }

        // Build attributed string with single font + color.
        let fgColor = nsColor(from: fg)
        let font = bold ? (fontManager.primary.ctFontBold ?? fontManager.primary.ctFont) : fontManager.primary.ctFont
        let ligatures = fontManager.primary.ligaturesEnabled ? 2 : 0
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fgColor,
            .ligature: ligatures
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let ctLine = CTLineCreateWithAttributedString(attrStr)

        var lineAscent: CGFloat = 0
        var lineDescent: CGFloat = 0
        var lineLeading: CGFloat = 0
        let lineWidth = CTLineGetTypographicBounds(ctLine, &lineAscent, &lineDescent, &lineLeading)

        let pixelWidth = min(Int(ceil(lineWidth * scale)), maxLinePixelWidth)
        guard pixelWidth > 0, linePixelHeight > 0 else { return nil }

        // Rasterize into pooled bitmap.
        let result = rasterizer.rasterize(ctLine, width: pixelWidth, height: linePixelHeight,
                                          scale: scale, descent: descent)

        // Upload into atlas slot.
        return atlas.upload(key: key, contentHash: contentHash,
                           pointer: result.pointer, pixelWidth: pixelWidth,
                           bytesPerRow: result.bytesPerRow)
    }

    // MARK: - Annotation Rendering

    /// Renders a pill badge annotation into the atlas.
    func renderPillToAtlas(text: String, fg: UInt32, bg: UInt32,
                           key: UInt16, contentHash: Int,
                           atlas: LineTextureAtlas) -> AtlasEntry? {
        guard !text.isEmpty else { return nil }

        if let entry = atlas.cachedEntry(forKey: key, contentHash: contentHash) {
            return entry
        }

        let fgColor = nsColor(from: fg)
        let ligatures = fontManager.primary.ligaturesEnabled ? 2 : 0
        let attrs: [NSAttributedString.Key: Any] = [
            .font: pillFont,
            .foregroundColor: fgColor,
            .ligature: ligatures
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let ctLine = CTLineCreateWithAttributedString(attrStr)

        var lineAscent: CGFloat = 0
        var lineDescent: CGFloat = 0
        var lineLeading: CGFloat = 0
        let textWidth = CTLineGetTypographicBounds(ctLine, &lineAscent, &lineDescent, &lineLeading)

        // Pill dimensions: text + horizontal padding, clamped to min width.
        let pillWidth = textWidth + 2 * pillHPad
        let pillContentHeight = pillAscent + pillDescent + 3.0
        let clampedWidth = max(pillWidth, pillContentHeight)

        let pixelWidth = Int(ceil(clampedWidth * scale))
        // Match atlas slot height for consistent upload.
        let pixelHeight = linePixelHeight
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        let bgR = CGFloat((bg >> 16) & 0xFF) / 255.0
        let bgG = CGFloat((bg >> 8) & 0xFF) / 255.0
        let bgB = CGFloat(bg & 0xFF) / 255.0
        let bgCGColor = CGColor(srgbRed: bgR, green: bgG, blue: bgB, alpha: 1.0)

        let result = rasterizer.rasterizePill(
            ctLine, textWidth: CGFloat(textWidth),
            bgColor: bgCGColor,
            width: pixelWidth, height: pixelHeight,
            scale: scale, descent: pillDescent, ascent: pillAscent,
            hPad: pillHPad, cornerRadius: pillCornerRadius
        )

        return atlas.upload(key: key, contentHash: contentHash,
                           pointer: result.pointer, pixelWidth: pixelWidth,
                           bytesPerRow: result.bytesPerRow)
    }

    /// Renders a line annotation (pill or inline text) into the atlas.
    func renderAnnotationToAtlas(annotation: GUILineAnnotation,
                                 key: UInt16, atlas: LineTextureAtlas) -> AtlasEntry? {
        let contentHash = annotationContentHash(annotation)

        switch annotation.kind {
        case .inlinePill:
            return renderPillToAtlas(
                text: annotation.text, fg: annotation.fg, bg: annotation.bg,
                key: key, contentHash: contentHash, atlas: atlas
            )
        case .inlineText:
            return renderSimpleText(
                annotation.text, fg: annotation.fg,
                key: key, contentHash: contentHash, atlas: atlas
            )
        case .gutterIcon:
            return nil
        }
    }

    /// Computes a content hash for annotation atlas cache invalidation.
    private func annotationContentHash(_ ann: GUILineAnnotation) -> Int {
        var hasher = Hasher()
        hasher.combine(ann.text)
        hasher.combine(ann.fg)
        hasher.combine(ann.bg)
        hasher.combine(ann.kind.rawValue)
        return hasher.finalize()
    }

    // MARK: - Attributed String Building

    /// Builds an NSAttributedString from composed text and pre-resolved spans.
    ///
    /// Spans are in display column coordinates (CJK = 2 columns, ASCII = 1).
    /// We build a display-column-to-String.Index mapping once per line (O(n)),
    /// then look up each span boundary in O(1).
    ///
    /// Unlike the LineBuffer path, no gap-filling transparent spaces are needed
    /// because the BEAM sends composed text with virtual text already spliced.
    func buildAttributedString(text: String, spans: [GUIHighlightSpan]) -> NSAttributedString {
        let result = NSMutableAttributedString()

        guard !text.isEmpty else { return result }

        let defaultFgColor = nsColor(from: defaultFgRGB)
        let ligatures = fontManager.primary.ligaturesEnabled ? 2 : 0

        if spans.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: fontManager.primary.ctFont,
                .foregroundColor: defaultFgColor,
                .ligature: ligatures
            ]
            result.append(NSAttributedString(string: text, attributes: attrs))
            return result
        }

        // Build display-column-to-String.Index mapping.
        // Each grapheme cluster maps to 1 or 2 display columns (CJK/fullwidth = 2).
        // columnIndex[displayCol] gives the String.Index at that display column.
        let columnMap = buildDisplayColumnMap(for: text)
        let totalDisplayCols = columnMap.count > 0 ? columnMap.count - 1 : 0

        var lastCol = 0

        for span in spans {
            let spanStart = min(Int(span.startCol), totalDisplayCols)
            let spanEnd = min(Int(span.endCol), totalDisplayCols)

            // Fill gap before this span with default-styled text.
            if spanStart > lastCol {
                let gapStartIdx = columnMap[min(lastCol, columnMap.count - 1)]
                let gapEndIdx = columnMap[min(spanStart, columnMap.count - 1)]
                if gapStartIdx < gapEndIdx {
                    let gapText = String(text[gapStartIdx..<gapEndIdx])
                    let gapAttrs: [NSAttributedString.Key: Any] = [
                        .font: fontManager.primary.ctFont,
                        .foregroundColor: defaultFgColor,
                        .ligature: ligatures
                    ]
                    result.append(NSAttributedString(string: gapText, attributes: gapAttrs))
                }
            }

            guard spanStart < spanEnd else { continue }

            let segStartIdx = columnMap[spanStart]
            let segEndIdx = columnMap[min(spanEnd, columnMap.count - 1)]
            guard segStartIdx < segEndIdx else { continue }
            let segText = String(text[segStartIdx..<segEndIdx])

            let font = resolveFont(for: span)
            let fgColor = span.fg != 0 ? nsColor(from: span.fg) : defaultFgColor

            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: fgColor,
                .ligature: ligatures
            ]

            if span.isUnderline {
                if span.isCurl {
                    attrs[.underlineStyle] = NSUnderlineStyle.thick.rawValue
                } else {
                    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
            }

            if span.isStrikethrough {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attrs[.strikethroughColor] = fgColor
            }

            result.append(NSAttributedString(string: segText, attributes: attrs))
            lastCol = spanEnd
        }

        // Append trailing text after the last span.
        if lastCol < totalDisplayCols {
            let tailStartIdx = columnMap[lastCol]
            let tailText = String(text[tailStartIdx...])
            if !tailText.isEmpty {
                let tailAttrs: [NSAttributedString.Key: Any] = [
                    .font: fontManager.primary.ctFont,
                    .foregroundColor: defaultFgColor,
                    .ligature: ligatures
                ]
                result.append(NSAttributedString(string: tailText, attributes: tailAttrs))
            }
        }

        return result
    }

    // MARK: - Display Column Mapping

    /// Builds a mapping from display column offset to String.Index.
    ///
    /// Display columns use the terminal convention: ASCII/Latin = 1 column,
    /// CJK/fullwidth = 2 columns. The resulting array has `totalDisplayCols + 1`
    /// entries, where `map[col]` is the String.Index at that display column.
    /// Built once per line in O(n), enabling O(1) span boundary lookups.
    func buildDisplayColumnMap(for text: String) -> [String.Index] {
        var map: [String.Index] = []
        // Reserve a reasonable estimate (most chars are 1 column)
        map.reserveCapacity(text.count + text.count / 4)

        for index in text.indices {
            let char = text[index]
            let width = displayColumnWidth(char)
            // First column of this character maps to this index
            map.append(index)
            // Wide characters occupy 2 display columns; the second column
            // also maps to this same index (the span boundary will slice
            // at the character boundary, not mid-character)
            if width == 2 {
                map.append(index)
            }
        }
        // Sentinel: one past the end
        map.append(text.endIndex)
        return map
    }

    /// Returns the display column width of a character (1 or 2).
    /// Matches the BEAM's `Unicode.display_width/1` for monospace terminals.
    private func displayColumnWidth(_ char: Character) -> Int {
        guard let scalar = char.unicodeScalars.first else { return 1 }
        let v = scalar.value
        if (v >= 0x1100 && v <= 0x115F)
            || (v >= 0x2E80 && v <= 0x303E)
            || (v >= 0x3040 && v <= 0x33BF)
            || (v >= 0x3400 && v <= 0x4DBF)
            || (v >= 0x4E00 && v <= 0xA4CF)
            || (v >= 0xAC00 && v <= 0xD7AF)
            || (v >= 0xF900 && v <= 0xFAFF)
            || (v >= 0xFE30 && v <= 0xFE6F)
            || (v >= 0xFF01 && v <= 0xFF60)
            || (v >= 0xFFE0 && v <= 0xFFE6)
            || (v >= 0x20000 && v <= 0x2FA1F)
        {
            return 2
        }
        return 1
    }

    // MARK: - Font Resolution

    /// Resolve CTFont for a highlight span.
    /// When bold attr is set but weight is default (0), use weight 5 (bold).
    private func resolveFont(for span: GUIHighlightSpan) -> CTFont {
        let face = fontManager.fontFace(for: span.fontId)
        let weight: UInt8 = (span.isBold && span.fontWeight == 0) ? 5 : span.fontWeight
        return face.fontForWeight(weight, isItalic: span.isItalic)
    }

    // MARK: - Color Conversion

    /// Convert 24-bit RGB to NSColor.
    private func nsColor(from rgb: UInt32) -> NSColor {
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        return NSColor(red: r, green: g, blue: b, alpha: 1.0)
    }

}
