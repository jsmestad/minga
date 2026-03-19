/// Manages multiple font faces sharing a single glyph atlas.
///
/// The primary font (ID 0) is loaded at startup. Secondary fonts (IDs 1-255)
/// are registered dynamically via the `register_font` protocol command.
/// All fonts share one GlyphAtlas to avoid multiple GPU texture binds.
///
/// Cell metrics (cellWidth, cellHeight) are determined by the primary font.
/// Secondary fonts with incompatible metrics log a warning but are still
/// loaded; glyphs are rasterized at the correct weight/style and positioned
/// within the primary font's cell grid.

import Foundation
import AppKit

/// Manages font faces and a shared glyph atlas.
final class FontManager {
    /// The shared atlas used by all font faces.
    let atlas: GlyphAtlas

    /// The primary font (ID 0). Always set after init.
    private(set) var primary: FontFace

    /// Secondary fonts keyed by font_id (1-255).
    private var secondaryFonts: [UInt8: FontFace] = [:]

    /// Cell dimensions from the primary font (all fonts use these for layout).
    var cellWidth: Int { primary.cellWidth }
    var cellHeight: Int { primary.cellHeight }
    var ascent: CGFloat { primary.ascent }
    var descent: CGFloat { primary.descent }
    var scale: CGFloat { primary.scale }

    init(name: String, size: CGFloat, scale: CGFloat, ligatures: Bool = true, weight: UInt8 = 2) {
        self.atlas = GlyphAtlas(initialSize: 512)
        self.primary = FontFace(name: name, size: size, scale: scale,
                                 ligatures: ligatures, weight: weight, atlas: atlas)
    }

    /// Replace the primary font (e.g., after a set_font command).
    func setPrimaryFont(name: String, size: CGFloat, scale: CGFloat,
                        ligatures: Bool, weight: UInt8) {
        self.primary = FontFace(name: name, size: size, scale: scale,
                                 ligatures: ligatures, weight: weight, atlas: atlas)
        // Clear secondary fonts since the primary metrics may have changed.
        secondaryFonts.removeAll()
    }

    /// Register a secondary font at the given ID.
    ///
    /// The font is loaded at the same size and scale as the primary.
    /// If the secondary font's cell metrics differ from the primary,
    /// a warning is logged but the font is still usable (glyphs will
    /// be positioned using primary metrics).
    func registerFont(id: UInt8, name: String) {
        guard id != 0 else {
            PortLogger.warn("Cannot register font at ID 0 (reserved for primary)")
            return
        }

        let size = CTFontGetSize(primary.ctFont)
        let secondary = FontFace(name: name, size: size, scale: primary.scale,
                                  ligatures: primary.ligaturesEnabled, weight: 2,
                                  atlas: atlas)

        if secondary.cellWidth != primary.cellWidth ||
           secondary.cellHeight != primary.cellHeight {
            PortLogger.warn(
                "Font '\(name)' (id=\(id)) has different metrics " +
                "(\(secondary.cellWidth)x\(secondary.cellHeight)) than primary " +
                "(\(primary.cellWidth)x\(primary.cellHeight)). " +
                "Glyphs will use primary cell layout."
            )
        }

        secondaryFonts[id] = secondary
        PortLogger.info("Registered font '\(name)' at id=\(id)")
    }

    /// Returns the FontFace for a given font_id. Falls back to primary if not found.
    func fontFace(for fontId: UInt8) -> FontFace {
        if fontId == 0 { return primary }
        return secondaryFonts[fontId] ?? primary
    }

    /// Look up a glyph by codepoint, weight, italic flag, and font_id.
    ///
    /// Routes to the correct FontFace for rasterization. All glyphs are
    /// packed into the shared atlas regardless of which font produced them.
    func getGlyph(_ codepoint: UInt32, weight: UInt8, italic: Bool, fontId: UInt8 = 0) -> Glyph? {
        let face = fontFace(for: fontId)
        return face.getGlyph(codepoint, weight: weight, italic: italic)
    }

    /// Look up a glyph using legacy style bits.
    func getGlyph(_ codepoint: UInt32, style: UInt8 = 0, fontId: UInt8 = 0) -> Glyph? {
        let face = fontFace(for: fontId)
        return face.getGlyph(codepoint, style: style)
    }

    /// Attempt to shape a ligature with the correct font face.
    func shapeLigature(_ text: String, weight: UInt8, italic: Bool, fontId: UInt8 = 0) -> FontFace.LigatureResult? {
        let face = fontFace(for: fontId)
        return face.shapeLigature(text, weight: weight, italic: italic)
    }

    /// Pre-rasterize ASCII glyphs for the primary font.
    func preloadAscii() {
        primary.preloadAscii()
    }
}
