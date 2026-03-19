/// Manages multiple font faces for CoreText rendering.
///
/// The primary font (ID 0) is loaded at startup. Secondary fonts (IDs 1-255)
/// are registered dynamically via the `register_font` protocol command.
///
/// Cell metrics (cellWidth, cellHeight) are determined by the primary font.
/// Secondary fonts with incompatible metrics log a warning but are still
/// loaded; CoreText handles layout positioning.

import Foundation
import AppKit

/// Manages font faces for CoreText line rendering.
final class FontManager {
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
        self.primary = FontFace(name: name, size: size, scale: scale,
                                 ligatures: ligatures, weight: weight)
    }

    /// Replace the primary font (e.g., after a set_font command).
    func setPrimaryFont(name: String, size: CGFloat, scale: CGFloat,
                        ligatures: Bool, weight: UInt8) {
        self.primary = FontFace(name: name, size: size, scale: scale,
                                 ligatures: ligatures, weight: weight)
        secondaryFonts.removeAll()
    }

    /// Register a secondary font at the given ID.
    func registerFont(id: UInt8, name: String) {
        guard id != 0 else {
            PortLogger.warn("Cannot register font at ID 0 (reserved for primary)")
            return
        }

        let size = CTFontGetSize(primary.ctFont)
        let secondary = FontFace(name: name, size: size, scale: primary.scale,
                                  ligatures: primary.ligaturesEnabled, weight: 2)

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
}
