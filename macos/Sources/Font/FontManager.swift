/// Manages multiple font faces for CoreText rendering.
///
/// The primary font (ID 0) is loaded at startup. Secondary fonts (IDs 1-255)
/// are registered dynamically via the `register_font` protocol command.
///
/// Cell metrics (cellWidth, cellHeight) are determined by the primary font.
/// Secondary fonts with incompatible metrics log a warning but are still
/// loaded; CoreText handles layout positioning.

import MingaUI
import Foundation
import AppKit

/// Manages font faces for CoreText line rendering.
///
/// `@MainActor` for the same reason as `FontFace`: the mutable font
/// registry is only accessed from the main thread (protocol dispatch,
/// rendering), and the annotation makes that contract enforceable under
/// Swift 6 strict concurrency.
@MainActor
final class FontManager {
    /// Immutable inputs used to resolve the primary font face.
    struct Configuration: Equatable {
        let family: String
        let size: CGFloat
        let scale: CGFloat
        let ligatures: Bool
        let weight: UInt8

        func withScale(_ scale: CGFloat) -> Configuration {
            Configuration(
                family: family,
                size: size,
                scale: scale,
                ligatures: ligatures,
                weight: weight
            )
        }
    }

    /// Result of applying a primary-font configuration.
    struct PrimaryUpdate {
        let previous: FontFace
        let current: FontFace
        let configurationChanged: Bool
        let metricsChanged: Bool
    }

    /// Inputs that produced `primary`.
    private(set) var configuration: Configuration

    /// The primary font (ID 0). Always set after init.
    private(set) var primary: FontFace

    /// Number of primary faces resolved during this manager's lifetime.
    private(set) var primaryConstructionCount = 1

    /// Secondary fonts keyed by font_id (1-255).
    private var secondaryFonts: [UInt8: FontFace] = [:]

    /// Registered secondary font families keyed by font_id, retained so primary font rebuilds can preserve them.
    private var registeredFontFamilies: [UInt8: String] = [:]

    /// User-configured fallback families, retained so primary font rebuilds can preserve them.
    private var fallbackFamilies: [String] = []

    /// Cell dimensions from the primary font (all fonts use these for layout).
    var cellWidth: CGFloat { primary.cellWidth }
    var cellHeight: Int { primary.cellHeight }
    var ascent: CGFloat { primary.ascent }
    var descent: CGFloat { primary.descent }
    var scale: CGFloat { primary.scale }
    var configuredFallbackFamilies: [String] { fallbackFamilies }

    init(name: String, size: CGFloat, scale: CGFloat, ligatures: Bool = true, weight: UInt8 = 2) {
        let configuration = Configuration(
            family: name,
            size: size,
            scale: scale,
            ligatures: ligatures,
            weight: weight
        )
        self.configuration = configuration
        self.primary = FontFace(
            name: configuration.family,
            size: configuration.size,
            scale: configuration.scale,
            ligatures: configuration.ligatures,
            weight: configuration.weight
        )
    }

    /// Applies one complete primary-font configuration.
    @discardableResult
    func setPrimaryFont(_ configuration: Configuration) -> PrimaryUpdate {
        let previous = primary
        guard configuration != self.configuration else {
            return PrimaryUpdate(
                previous: previous,
                current: previous,
                configurationChanged: false,
                metricsChanged: false
            )
        }

        let current = FontFace(
            name: configuration.family,
            size: configuration.size,
            scale: configuration.scale,
            ligatures: configuration.ligatures,
            weight: configuration.weight
        )
        self.configuration = configuration
        self.primary = current
        primaryConstructionCount += 1
        primary.setFallbackFonts(fallbackFamilies)
        rebuildSecondaryFonts()

        return PrimaryUpdate(
            previous: previous,
            current: current,
            configurationChanged: true,
            metricsChanged: abs(previous.cellWidth - current.cellWidth) > 0.001 || previous.cellHeight != current.cellHeight
        )
    }

    /// Configure the primary font fallback chain and preserve it across primary font rebuilds.
    func setFallbackFonts(_ families: [String]) {
        fallbackFamilies = families
        primary.setFallbackFonts(families)
    }

    /// Register a secondary font at the given ID.
    func registerFont(id: UInt8, name: String) {
        guard id != 0 else {
            PortLogger.warn("Cannot register font at ID 0 (reserved for primary)")
            return
        }

        registeredFontFamilies[id] = name
        secondaryFonts[id] = makeSecondaryFont(id: id, name: name)
        PortLogger.info("Registered font '\(name)' at id=\(id)")
    }

    /// Restores protocol font IDs to the startup baseline for a replacement BEAM connection.
    func resetProtocolRegistrations() {
        registeredFontFamilies.removeAll(keepingCapacity: true)
        secondaryFonts.removeAll(keepingCapacity: true)
        fallbackFamilies.removeAll(keepingCapacity: true)
        primary.setFallbackFonts([])
    }

    /// Returns the FontFace for a given font_id. Falls back to primary if not found.
    func fontFace(for fontId: UInt8) -> FontFace {
        if fontId == 0 { return primary }
        return secondaryFonts[fontId] ?? primary
    }

    /// Rebuilds registered secondary fonts after the primary font's size or scale changes.
    private func rebuildSecondaryFonts() {
        secondaryFonts.removeAll(keepingCapacity: true)
        for (id, name) in registeredFontFamilies {
            secondaryFonts[id] = makeSecondaryFont(id: id, name: name)
        }
    }

    /// Creates a secondary font using the current primary font's size, scale, and ligature setting.
    private func makeSecondaryFont(id: UInt8, name: String) -> FontFace {
        let size = CTFontGetSize(primary.ctFont)
        let secondary = FontFace(name: name, size: size, scale: primary.scale,
                                  ligatures: primary.ligaturesEnabled, weight: 2)

        if abs(secondary.cellWidth - primary.cellWidth) > 0.001 ||
           secondary.cellHeight != primary.cellHeight {
            PortLogger.warn(
                "Font '\(name)' (id=\(id)) has different metrics " +
                "(\(secondary.cellWidth)x\(secondary.cellHeight)) than primary " +
                "(\(primary.cellWidth)x\(primary.cellHeight)). " +
                "Glyphs will use primary cell layout."
            )
        }

        return secondary
    }
}
