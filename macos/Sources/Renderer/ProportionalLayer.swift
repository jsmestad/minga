/// A proportional text region rendered via CoreText line shaping.
///
/// This is the variable-pitch equivalent of CellGrid for a specific screen
/// region. Instead of fixed-width character cells, it stores CTLine-based
/// TextRuns that use proportional advances, kerning, and ligatures.
///
/// The layer renders all visible lines to a single BGRA bitmap, which is
/// uploaded to a Metal texture and drawn as one quad. This "line-cached
/// texture" approach avoids per-glyph atlas management for proportional
/// text and preserves CoreText's shaping information.
///
/// Usage:
///   1. Set `lines` with TextRuns for each visible line
///   2. Call `rasterize(scale:)` to produce a BGRA bitmap
///   3. Upload the bitmap to a Metal texture
///   4. Draw as a single textured quad at the layer's screen position

import CoreText
import CoreGraphics
import Foundation
import AppKit
import Metal

/// A proportional text layer with position and cached rendering.
final class ProportionalLayer {
    /// Screen position (in points) of the top-left corner.
    var originX: CGFloat = 0
    var originY: CGFloat = 0

    /// Width and height of the layer (in points).
    var width: CGFloat = 0
    var height: CGFloat = 0

    /// The text runs for each visible line (index 0 = topmost visible line).
    var lines: [TextRun] = []

    /// Default background color (RGB, 0..1).
    var defaultBg: SIMD3<Float> = SIMD3<Float>(0.12, 0.12, 0.14)

    /// Cached rasterized bitmap (BGRA, row-major).
    private(set) var bitmap: [UInt8] = []
    private(set) var bitmapWidth: Int = 0
    private(set) var bitmapHeight: Int = 0

    /// Incremented when the bitmap changes. Compare against a cached value
    /// to know when to re-upload to the GPU.
    private(set) var version: Int = 0

    /// Rasterize all lines into a BGRA bitmap.
    ///
    /// Uses CoreGraphics to draw each CTLine at the correct vertical position.
    /// The resulting bitmap can be uploaded to a Metal texture.
    ///
    /// `scale` is the backing scale factor (2.0 for Retina).
    func rasterize(scale: CGFloat) {
        guard !lines.isEmpty, width > 0, height > 0 else {
            bitmap = []
            bitmapWidth = 0
            bitmapHeight = 0
            return
        }

        let pixelW = Int(ceil(width * scale))
        let pixelH = Int(ceil(height * scale))

        // Create a BGRA bitmap context.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: pixelW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        // Scale for Retina.
        ctx.scaleBy(x: scale, y: scale)

        // Fill background.
        ctx.setFillColor(
            red: CGFloat(defaultBg.x),
            green: CGFloat(defaultBg.y),
            blue: CGFloat(defaultBg.z),
            alpha: 1.0
        )
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // CoreGraphics uses bottom-up coordinates. Flip to top-down for text.
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: height)
        ctx.scaleBy(x: 1, y: -1)

        // Draw each line.
        var y: CGFloat = 0
        for run in lines {
            // Background fill for this line.
            let lineRect = CGRect(x: 0, y: y, width: width, height: run.lineHeight)
            ctx.setFillColor(
                red: CGFloat(run.bgColor.x),
                green: CGFloat(run.bgColor.y),
                blue: CGFloat(run.bgColor.z),
                alpha: 1.0
            )
            ctx.fill(lineRect)

            // Draw text. CTLineDraw uses the text matrix for positioning.
            // In our flipped coordinate system, we position at baseline
            // (y offset + ascent from the top of the line).
            ctx.setFillColor(
                red: CGFloat(run.fgColor.x),
                green: CGFloat(run.fgColor.y),
                blue: CGFloat(run.fgColor.z),
                alpha: 1.0
            )

            // Save/restore to handle the double-flip for CTLineDraw.
            // CTLineDraw expects bottom-up coordinates, so we flip back
            // for this specific draw call.
            ctx.saveGState()
            ctx.translateBy(x: 0, y: y + run.lineHeight)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = CGPoint(x: 0, y: run.descent + run.leading)
            CTLineDraw(run.line, ctx)
            ctx.restoreGState()

            y += run.lineHeight
        }

        // Extract bitmap data.
        guard let data = ctx.data else { return }
        let totalBytes = pixelW * pixelH * 4
        bitmap = [UInt8](UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: UInt8.self),
            count: totalBytes
        ))
        bitmapWidth = pixelW
        bitmapHeight = pixelH
        version += 1
    }

    /// Create a Metal texture from the rasterized bitmap.
    ///
    /// Returns nil if the bitmap is empty. The texture uses BGRA8 sRGB
    /// format to match the cell grid atlas.
    func createTexture(device: MTLDevice) -> MTLTexture? {
        guard bitmapWidth > 0, bitmapHeight > 0, !bitmap.isEmpty else { return nil }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: bitmapWidth,
            height: bitmapHeight,
            mipmapped: false
        )
        desc.usage = .shaderRead

        guard let texture = device.makeTexture(descriptor: desc) else { return nil }

        texture.replace(
            region: MTLRegionMake2D(0, 0, bitmapWidth, bitmapHeight),
            mipmapLevel: 0,
            withBytes: bitmap,
            bytesPerRow: bitmapWidth * 4
        )

        return texture
    }

    /// Returns the character index at the given point (in layer-relative coordinates).
    ///
    /// Finds which line the y coordinate falls in, then asks the CTLine
    /// for the character at the x coordinate. Returns (lineIndex, charIndex).
    func hitTest(x: CGFloat, y: CGFloat) -> (line: Int, char: CFIndex)? {
        guard !lines.isEmpty else { return nil }

        var currentY: CGFloat = 0
        for (i, run) in lines.enumerated() {
            if y < currentY + run.lineHeight {
                let charIdx = run.characterIndex(atX: x)
                return (line: i, char: charIdx)
            }
            currentY += run.lineHeight
        }

        // Past the last line; return end of last line.
        let lastIdx = lines.count - 1
        let lastRun = lines[lastIdx]
        let lastText = (CTLineGetStringRange(lastRun.line).length)
        return (line: lastIdx, char: lastText)
    }
}
