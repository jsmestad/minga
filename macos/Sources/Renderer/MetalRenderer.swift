/// Metal renderer for the cell grid.
///
/// Two-pass instanced drawing: background quads, then glyph quads with
/// alpha blending. The cursor is drawn as an overlay. Atlas texture is
/// re-uploaded when the font face reports modifications.

import Metal
import QuartzCore
import AppKit

/// GPU cell data (must match CellData in Shaders.metal).
///
/// Uses SIMD3<Float> for colors, which is 16-byte aligned and matches
/// MSL's float3. Total size: 80 bytes per cell.
struct CellGPU {
    var uvOrigin: SIMD2<Float> = .zero
    var uvSize: SIMD2<Float> = .zero
    var glyphSize: SIMD2<Float> = .zero
    var glyphOffset: SIMD2<Float> = .zero
    var fgColor: SIMD3<Float> = .init(1, 1, 1)
    var bgColor: SIMD3<Float> = .init(0.12, 0.12, 0.14)
    var gridPos: SIMD2<Float> = .zero
    var hasGlyph: Float = 0
    var isColor: Float = 0
}

/// Uniforms shared across all cells (must match Uniforms in Shaders.metal).
struct Uniforms {
    var cellSize: SIMD2<Float>
    var viewportSize: SIMD2<Float>
    /// Pixel offset for smooth scrolling (x: horizontal, y: vertical).
    var scrollOffset: SIMD2<Float>
}

/// Background clear color (dark gray matching the default bg).
// Linear equivalents of sRGB (0.12, 0.12, 0.14). MTLClearColor bypasses
// shaders, so it must be specified in linear space for the sRGB framebuffer.
private let bgClearColor = MTLClearColor(red: 0.01298, green: 0.01298, blue: 0.01681, alpha: 1.0)

/// Renders the cell grid to a CAMetalLayer using instanced drawing.
final class MetalRenderer {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private let bgPipeline: MTLRenderPipelineState
    private let glyphPipeline: MTLRenderPipelineState

    /// Reusable Metal buffer for cell data (avoids setVertexBytes 4KB limit).
    private var cellBuffer: MTLBuffer?
    private var cellBufferCapacity: Int = 0

    /// Atlas texture on the GPU.
    private var atlasTexture: MTLTexture?
    private var atlasVersion: Int = 0

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.commandQueue = queue

        // Load the compiled Metal shader library.
        // Xcode compiles .metal files into default.metallib at build time
        // and places it next to the executable.
        let executableURL = Bundle.main.executableURL!
        let metallibURL = executableURL.deletingLastPathComponent().appendingPathComponent("default.metallib")
        guard let library = try? device.makeLibrary(URL: metallibURL) else {
            NSLog("Failed to load Metal library from \(metallibURL.path)")
            return nil
        }

        // Background pipeline.
        let bgDesc = MTLRenderPipelineDescriptor()
        bgDesc.vertexFunction = library.makeFunction(name: "bg_vertex")
        bgDesc.fragmentFunction = library.makeFunction(name: "bg_fragment")
        bgDesc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb

        // Glyph pipeline (premultiplied alpha blending).
        let glyphDesc = MTLRenderPipelineDescriptor()
        glyphDesc.vertexFunction = library.makeFunction(name: "glyph_vertex")
        glyphDesc.fragmentFunction = library.makeFunction(name: "glyph_fragment")
        glyphDesc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        glyphDesc.colorAttachments[0].isBlendingEnabled = true
        glyphDesc.colorAttachments[0].sourceRGBBlendFactor = .one
        glyphDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        glyphDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        glyphDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            self.bgPipeline = try device.makeRenderPipelineState(descriptor: bgDesc)
            self.glyphPipeline = try device.makeRenderPipelineState(descriptor: glyphDesc)
        } catch {
            NSLog("Failed to create Metal pipeline: \(error)")
            return nil
        }
    }

    /// Render the cell grid using the given drawable.
    ///
    /// Render the cell grid using the given drawable.
    ///
    /// The caller (MTKView.draw) provides the already-acquired drawable
    /// and viewport size (in backing pixels). This avoids the blocking
    /// `layer.nextDrawable()` call that caused scroll lag.
    ///
    /// `scrollOffset` is the sub-cell-height pixel offset for smooth scrolling.
    func render(grid: CellGrid, face: FontFace, drawable: CAMetalDrawable,
                viewportSize: CGSize, contentScale: Float, scrollOffset: SIMD2<Float> = .zero) {
        let cellW = Float(face.cellWidth)
        let cellH = Float(face.cellHeight)
        let atlasSize = Float(face.atlas.size)

        // Re-upload atlas if it changed.
        if face.atlas.modified != atlasVersion {
            uploadAtlas(face.atlas)
            atlasVersion = face.atlas.modified
        }

        // Build GPU cell data.
        let count = Int(grid.cols) * Int(grid.rows)
        var gpuCells = [CellGPU](repeating: CellGPU(), count: count)

        // GUI gutter padding: shift content cells right by a fractional amount
        // to create Zed-style breathing room between line numbers and code.
        // Round to whole backing pixels to avoid sub-pixel seams.
        let gutterPaddingPt: Float = grid.gutterCol > 0 ? round(12.0 * contentScale) / contentScale : 0
        let gutterPaddingCells = gutterPaddingPt / cellW

        for i in 0..<count {
            let row = UInt16(i / Int(grid.cols))
            let col = UInt16(i % Int(grid.cols))
            let cell = grid.cells[i]

            var gpu = CellGPU()
            gpu.gridPos = SIMD2<Float>(
                col >= grid.gutterCol ? Float(col) + gutterPaddingCells : Float(col),
                Float(row)
            )

            let isReverse = (cell.attrs & ATTR_REVERSE) != 0
            let defaultFg = SIMD3<Float>(1, 1, 1)
            // Use the theme's default bg from the grid (set via set_window_bg).
            // Falls back to a dark grey if no default has been set yet.
            let defaultBg = grid.defaultBg != 0
                ? colorFromU24(grid.defaultBg, default: SIMD3<Float>(0.12, 0.12, 0.14))
                : SIMD3<Float>(0.12, 0.12, 0.14)
            let fg = colorFromU24(cell.fg, default: defaultFg)
            let bg = colorFromU24(cell.bg, default: defaultBg)
            gpu.fgColor = isReverse ? bg : fg
            gpu.bgColor = isReverse ? fg : bg

            // Skip glyph drawing for ligature continuation cells (bg still draws).
            if cell.isContinuation {
                gpuCells[i] = gpu
                continue
            }

            // Ligature head cell: use the shaped ligature glyph.
            if cell.ligatureCellCount > 1, !cell.ligatureText.isEmpty,
               let lig = face.shapeLigature(cell.ligatureText) {
                gpu.hasGlyph = 1.0
                gpu.isColor = 0.0
                gpu.uvOrigin = SIMD2<Float>(Float(lig.glyph.atlasX) / atlasSize,
                                            Float(lig.glyph.atlasY) / atlasSize)
                gpu.uvSize = SIMD2<Float>(Float(lig.glyph.width) / atlasSize,
                                          Float(lig.glyph.height) / atlasSize)
                gpu.glyphSize = SIMD2<Float>(Float(lig.glyph.width), Float(lig.glyph.height))
                let baseline = Float(face.ascent)
                gpu.glyphOffset = SIMD2<Float>(
                    Float(lig.glyph.offsetX) * contentScale,
                    (baseline - Float(lig.glyph.offsetY)) * contentScale
                )
            }
            // Normal single-cell glyph.
            else if !cell.grapheme.isEmpty, cell.grapheme != " " {
                if let scalar = cell.grapheme.unicodeScalars.first,
                   let glyph = face.getGlyph(scalar.value) {
                    gpu.hasGlyph = 1.0
                    gpu.isColor = glyph.isColor ? 1.0 : 0.0
                    gpu.uvOrigin = SIMD2<Float>(Float(glyph.atlasX) / atlasSize,
                                                Float(glyph.atlasY) / atlasSize)
                    gpu.uvSize = SIMD2<Float>(Float(glyph.width) / atlasSize,
                                              Float(glyph.height) / atlasSize)
                    gpu.glyphSize = SIMD2<Float>(Float(glyph.width), Float(glyph.height))
                    let baseline = Float(face.ascent)
                    gpu.glyphOffset = SIMD2<Float>(
                        Float(glyph.offsetX) * contentScale,
                        (baseline - Float(glyph.offsetY)) * contentScale
                    )
                }
            }

            gpuCells[i] = gpu
        }

        // Ensure the Metal buffer is large enough.
        let cellDataSize = count * MemoryLayout<CellGPU>.stride
        if cellBuffer == nil || cellBufferCapacity < cellDataSize {
            let newCapacity = max(cellDataSize, 65536)
            cellBuffer = device.makeBuffer(length: newCapacity, options: .storageModeShared)
            cellBufferCapacity = newCapacity
        }
        guard let buffer = cellBuffer else { return }

        // Copy cell data into the Metal buffer.
        buffer.contents().copyMemory(from: &gpuCells, byteCount: cellDataSize)

        // Set up render pass.
        let renderDesc = MTLRenderPassDescriptor()
        renderDesc.colorAttachments[0].texture = drawable.texture
        renderDesc.colorAttachments[0].loadAction = .clear
        renderDesc.colorAttachments[0].storeAction = .store
        renderDesc.colorAttachments[0].clearColor = bgClearColor

        guard let cmdBuf = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: renderDesc) else { return }

        var uniforms = Uniforms(
            cellSize: SIMD2<Float>(cellW * contentScale, cellH * contentScale),
            viewportSize: SIMD2<Float>(Float(viewportSize.width), Float(viewportSize.height)),
            scrollOffset: SIMD2<Float>(scrollOffset.x * contentScale, scrollOffset.y * contentScale)
        )

        if count > 0 {
            // Background pass.
            encoder.setRenderPipelineState(bgPipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: count)

            // Glyph pass.
            if let atlas = atlasTexture {
                encoder.setRenderPipelineState(glyphPipeline)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                encoder.setFragmentTexture(atlas, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: count)
            }

            // Gutter gap fill: draw a background-colored rect to cover the
            // pixel gap created by shifting content cells right.
            if grid.gutterCol > 0 && gutterPaddingCells > 0 {
                let fillBg = grid.defaultBg != 0
                    ? colorFromU24(grid.defaultBg, default: SIMD3<Float>(0.12, 0.12, 0.14))
                    : SIMD3<Float>(0.12, 0.12, 0.14)
                var fillCell = CellGPU()
                fillCell.bgColor = fillBg
                fillCell.hasGlyph = 0

                var fillUniforms = uniforms
                let fillWidth = gutterPaddingPt * contentScale
                fillUniforms.cellSize = SIMD2<Float>(fillWidth, Float(viewportSize.height))
                fillCell.gridPos = SIMD2<Float>(
                    Float(grid.gutterCol) * cellW * contentScale / fillWidth,
                    0
                )
                fillUniforms.scrollOffset = .zero

                encoder.setRenderPipelineState(bgPipeline)
                encoder.setVertexBytes(&fillCell, length: MemoryLayout<CellGPU>.stride, index: 0)
                encoder.setVertexBytes(&fillUniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
            }

            // Cursor overlay. Shape varies by mode: block (normal), beam (insert), underline.
            if grid.cursorVisible {
                let cursorIdx = Int(grid.cursorRow) * Int(grid.cols) + Int(grid.cursorCol)
                if cursorIdx >= 0, cursorIdx < count {
                    var cursorCell = gpuCells[cursorIdx]
                    cursorCell.fgColor = SIMD3<Float>(1, 1, 1)
                    cursorCell.bgColor = SIMD3<Float>(0.8, 0.8, 0.8)
                    cursorCell.hasGlyph = 0.0

                    var cursorUniforms = uniforms

                    // Apply gutter padding offset to cursor position.
                    let cursorPadding: Float = (grid.gutterCol > 0 && grid.cursorCol >= grid.gutterCol) ? gutterPaddingCells : 0

                    switch grid.cursorShape {
                    case .beam:
                        // Thin vertical bar at the left edge of the cell (2px at content scale).
                        let beamWidth = 2.0 * contentScale
                        cursorUniforms.cellSize.x = beamWidth
                        cursorCell.gridPos.x = (Float(grid.cursorCol) + cursorPadding) * cellW * contentScale / beamWidth

                    case .underline:
                        // Thin horizontal bar at the bottom of the cell (2px at content scale).
                        let underlineHeight = 2.0 * contentScale
                        cursorUniforms.cellSize.y = underlineHeight
                        let cellBottom = Float(grid.cursorRow + 1) * cellH * contentScale
                        cursorCell.gridPos.y = (cellBottom - underlineHeight) / underlineHeight

                    case .block:
                        break // Full cell, no adjustment needed.
                    }

                    encoder.setRenderPipelineState(bgPipeline)
                    encoder.setVertexBytes(&cursorCell, length: MemoryLayout<CellGPU>.stride, index: 0)
                    encoder.setVertexBytes(&cursorUniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
                }
            }
        }

        encoder.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    // MARK: - Private

    private func uploadAtlas(_ atlas: GlyphAtlas) {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: Int(atlas.size),
            height: Int(atlas.size),
            mipmapped: false
        )
        desc.usage = .shaderRead

        guard let texture = device.makeTexture(descriptor: desc) else { return }

        texture.replace(
            region: MTLRegionMake2D(0, 0, Int(atlas.size), Int(atlas.size)),
            mipmapLevel: 0,
            withBytes: atlas.data,
            bytesPerRow: Int(atlas.size) * 4
        )

        atlasTexture = texture
    }

    /// Convert a 24-bit RGB color to SIMD3<Float>. 0 maps to the provided default.
    private func colorFromU24(_ color: UInt32, default defaultColor: SIMD3<Float>) -> SIMD3<Float> {
        if color == 0 { return defaultColor }
        return SIMD3<Float>(
            Float((color >> 16) & 0xFF) / 255.0,
            Float((color >> 8) & 0xFF) / 255.0,
            Float(color & 0xFF) / 255.0
        )
    }
}
