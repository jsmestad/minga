/// Pooled bitmap rasterizer for CoreText line rendering.
///
/// Owns a single reusable raw memory buffer for CTLine rasterization,
/// eliminating per-line [UInt8] array allocation (~22KB per line at
/// Retina scale, ~6.6MB/s at 60fps with 5 dirty lines/frame).
///
/// Both `CoreTextLineRenderer` and `WindowContentRenderer` share a
/// single instance. The pool grows but never shrinks (worst-case ~44KB
/// for a 400-column Retina line). Memory is freed in deinit.
///
/// Thread safety: `@MainActor` isolated, same as both renderers.
/// Lines are processed sequentially; one buffer is sufficient.

import Foundation
import CoreText
import CoreGraphics

/// Result of a rasterization: a raw pointer to BGRA pixel data and
/// the bytes-per-row stride. The pointer is valid until the next
/// `rasterize()` call (the caller must copy the data via
/// `MTLTexture.replace` before then).
struct RasterizeResult {
    /// Pointer to the BGRA pixel data. Valid until next rasterize() call.
    let pointer: UnsafeRawPointer
    /// Bytes per row (width * 4).
    let bytesPerRow: Int
}

/// Owns the cached CGContext and its backing allocation as one teardown unit.
/// Property destruction releases the context before `deinit` frees the pool.
private final class BitmapRasterStorage {
    var pool: UnsafeMutableRawPointer?
    var lineContext: CGContext?
    var lineContextWidth: Int = 0
    var lineContextHeight: Int = 0
    var lineContextBytesPerRow: Int = 0

    private let deallocate: (UnsafeMutableRawPointer) -> Void

    init(deallocate: @escaping (UnsafeMutableRawPointer) -> Void) {
        self.deallocate = deallocate
    }

    deinit {
        lineContext = nil
        if let pool { deallocate(pool) }
    }
}

@MainActor
final class BitmapRasterizer {
    struct Factories {
        var allocate: (Int) -> UnsafeMutableRawPointer?
        var deallocate: (UnsafeMutableRawPointer) -> Void
        var makeContext: (UnsafeMutableRawPointer, Int, Int, Int, CGColorSpace, UInt32) -> CGContext?

        @MainActor static let production = Self(
            allocate: { byteCount in malloc(byteCount) },
            deallocate: { free($0) },
            makeContext: { data, width, height, bytesPerRow, colorSpace, bitmapInfo in
                CGContext(data: data, width: width, height: height, bitsPerComponent: 8,
                          bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo)
            }
        )
    }

    private let factories: Factories
    private let storage: BitmapRasterStorage

    /// Current capacity of the pool in bytes.
    private var poolByteCount: Int = 0

    /// Shared sRGB color space (allocated once, reused).
    private let colorSpace: CGColorSpace

    /// Bitmap info flags for BGRA premultiplied alpha.
    private let bitmapInfo: UInt32

    init(factories: Factories = .production) {
        self.factories = factories
        self.storage = BitmapRasterStorage(deallocate: factories.deallocate)
        self.colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        self.bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
    }

    /// Rasterizes a CTLine into the pooled BGRA bitmap buffer.
    ///
    /// The returned pointer is valid until the next `rasterize()` call.
    /// Callers must copy the data (e.g., via `MTLTexture.replace`) before
    /// calling rasterize again.
    ///
    /// - Parameters:
    ///   - ctLine: The CoreText line to draw.
    ///   - width: Pixel width of the output bitmap.
    ///   - height: Pixel height of the output bitmap.
    ///   - scale: Backing scale factor (2.0 for Retina).
    ///   - descent: Font descent in points (for baseline positioning).
    /// - Returns: A `RasterizeResult` with the raw pointer and bytesPerRow.
    func rasterize(_ ctLine: CTLine, width: Int, height: Int,
                   scale: CGFloat, descent: CGFloat) throws -> RasterizeResult {
        let bytesPerRow = try checkedMultiply(width, 4)
        let byteCount = try checkedMultiply(bytesPerRow, height)

        try ensureCapacity(byteCount: byteCount)

        guard let ptr = storage.pool else {
            throw NativePresentationFailure(phase: .raster, dimension: .buffer,
                                            reason: .allocation)
        }

        // Zero only the used region (not the full pool capacity).
        memset(ptr, 0, byteCount)

        guard let ctx = lineRasterContext(width: width, height: height, bytesPerRow: bytesPerRow, data: ptr, scale: scale) else {
            throw NativePresentationFailure(phase: .raster, dimension: .rasterContext,
                                            requested: byteCount, reason: .context)
        }

        // CoreText baseline positioning.
        ctx.textPosition = CGPoint(x: 0, y: descent)

        // Draw the line.
        CTLineDraw(ctLine, ctx)

        return RasterizeResult(pointer: UnsafeRawPointer(ptr), bytesPerRow: bytesPerRow)
    }

    /// Rasterizes a pill badge: rounded rect background + centered text.
    ///
    /// The pill is drawn as a single bitmap containing both the colored
    /// background and the text, suitable for a single atlas entry.
    func rasterizePill(_ ctLine: CTLine, textWidth: CGFloat,
                       bgColor: CGColor,
                       width: Int, height: Int,
                       scale: CGFloat, descent: CGFloat, ascent: CGFloat,
                       hPad: CGFloat, cornerRadius: CGFloat) throws -> RasterizeResult {
        let bytesPerRow = try checkedMultiply(width, 4)
        let byteCount = try checkedMultiply(bytesPerRow, height)

        try ensureCapacity(byteCount: byteCount)

        guard let ptr = storage.pool else {
            throw NativePresentationFailure(phase: .raster, dimension: .buffer,
                                            reason: .allocation)
        }

        memset(ptr, 0, byteCount)

        guard let ctx = factories.makeContext(
            ptr, width, height, bytesPerRow, colorSpace, bitmapInfo
        ) else {
            throw NativePresentationFailure(phase: .raster, dimension: .rasterContext,
                                            requested: byteCount, reason: .context)
        }

        ctx.scaleBy(x: scale, y: scale)
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(true)
        ctx.setAllowsFontSubpixelPositioning(true)
        ctx.setShouldSubpixelPositionFonts(true)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)

        // Draw rounded rect background centered vertically in the bitmap.
        // The bitmap may be taller than the pill (to match atlas slot height),
        // so the pill content is vertically centered within the bitmap height.
        let pointWidth = CGFloat(width) / scale
        let bitmapPointHeight = CGFloat(height) / scale
        let pillHeight = min(ascent + descent + 3.0, bitmapPointHeight)
        let pillY = (bitmapPointHeight - pillHeight) / 2

        let pillRect = CGRect(x: 0, y: pillY, width: pointWidth, height: pillHeight)
        let clampedRadius = min(cornerRadius, pillHeight / 2)
        let path = CGPath(roundedRect: pillRect,
                          cornerWidth: clampedRadius, cornerHeight: clampedRadius,
                          transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(bgColor)
        ctx.fillPath()

        // Position text: horizontally padded, vertically centered within pill.
        let lineHeight = ascent + descent
        let textY = pillY + descent + (pillHeight - lineHeight) / 2
        ctx.textPosition = CGPoint(x: hPad, y: textY)

        CTLineDraw(ctLine, ctx)

        return RasterizeResult(pointer: UnsafeRawPointer(ptr), bytesPerRow: bytesPerRow)
    }

    // MARK: - Private

    /// Grows the pool if needed. Never shrinks.
    private func ensureCapacity(byteCount: Int) throws {
        guard byteCount > poolByteCount else { return }
        guard let candidate = factories.allocate(byteCount) else {
            throw NativePresentationFailure(phase: .raster, dimension: .buffer,
                                            requested: byteCount, reason: .allocation)
        }

        storage.lineContext = nil
        if let pool = storage.pool { factories.deallocate(pool) }
        storage.pool = candidate
        poolByteCount = byteCount
    }

    private func checkedMultiply(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else {
            throw NativePresentationFailure(phase: .raster, dimension: .arithmetic,
                                            reason: .overflow)
        }
        return value
    }

    private func lineRasterContext(width: Int, height: Int, bytesPerRow: Int, data: UnsafeMutableRawPointer, scale: CGFloat) -> CGContext? {
        if let ctx = storage.lineContext,
           width == storage.lineContextWidth,
           height == storage.lineContextHeight,
           bytesPerRow == storage.lineContextBytesPerRow {
            return ctx
        }

        guard let ctx = factories.makeContext(
            data, width, height, bytesPerRow, colorSpace, bitmapInfo
        ) else { return nil }

        ctx.scaleBy(x: scale, y: scale)
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(true)
        ctx.setAllowsFontSubpixelPositioning(true)
        ctx.setShouldSubpixelPositionFonts(true)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)

        storage.lineContext = ctx
        storage.lineContextWidth = width
        storage.lineContextHeight = height
        storage.lineContextBytesPerRow = bytesPerRow
        return ctx
    }
}
