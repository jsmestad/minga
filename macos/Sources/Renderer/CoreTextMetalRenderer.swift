/// CoreText-based Metal renderer.
///
/// Renders the screen from LineBuffer + CoreTextLineRenderer, replacing
/// the cell-grid instanced drawing. Each visible line is a pre-rendered
/// texture composited as a textured quad over background color fills.
///
/// Passes:
/// 1. Background fill: one colored quad per line (using run bg colors)
/// 2. Block cursor background (drawn before text so text shows on top)
/// 3. Line texture blit: one textured quad per line (CoreText-rendered text)
/// 4. Gutter gap fill: colored rect to cover gutter padding gap
/// 5. Gutter separator line
/// 6. Beam/underline cursor overlay (drawn after text)

import Metal
import QuartzCore
import AppKit

/// GPU quad instance for background fills and cursor (must match QuadInstance in CoreTextShaders.metal).
struct QuadGPU {
    var position: SIMD2<Float> = .zero
    var size: SIMD2<Float> = .zero
    var color: SIMD3<Float> = .zero
    var alpha: Float = 1.0
}

/// GPU line instance for texture blitting (must match LineInstance in CoreTextShaders.metal).
struct LineGPU {
    var position: SIMD2<Float> = .zero
    var size: SIMD2<Float> = .zero
    var uvOrigin: SIMD2<Float> = .zero
    var uvSize: SIMD2<Float> = SIMD2<Float>(1, 1)
}

/// Uniforms for the CoreText renderer (must match CTUniforms in CoreTextShaders.metal).
struct CTUniformsGPU {
    var viewportSize: SIMD2<Float> = .zero
    var scrollOffset: SIMD2<Float> = .zero
}

/// Background clear color (dark gray matching the default bg).
/// Linear equivalents of sRGB (0.12, 0.12, 0.14).
private let ctBgClearColor = MTLClearColor(red: 0.01298, green: 0.01298, blue: 0.01681, alpha: 1.0)

/// Renders the editor using CoreText line textures instead of cell-grid instanced drawing.
final class CoreTextMetalRenderer {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private let bgPipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState

    /// The CoreText line rendering engine.
    private(set) var lineRenderer: CoreTextLineRenderer?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue

        // Load the compiled Metal shader library.
        let executableURL = Bundle.main.executableURL!
        let metallibURL = executableURL.deletingLastPathComponent().appendingPathComponent("default.metallib")
        guard let library = try? device.makeLibrary(URL: metallibURL) else {
            NSLog("Failed to load Metal library from \(metallibURL.path)")
            return nil
        }

        // Background fill pipeline (also used for cursor overlay).
        let bgDesc = MTLRenderPipelineDescriptor()
        bgDesc.vertexFunction = library.makeFunction(name: "ct_bg_vertex")
        bgDesc.fragmentFunction = library.makeFunction(name: "ct_bg_fragment")
        bgDesc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        // Premultiplied alpha blending for cursor overlay transparency.
        bgDesc.colorAttachments[0].isBlendingEnabled = true
        bgDesc.colorAttachments[0].sourceRGBBlendFactor = .one
        bgDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        bgDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        bgDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        // Line texture blit pipeline.
        let lineDesc = MTLRenderPipelineDescriptor()
        lineDesc.vertexFunction = library.makeFunction(name: "ct_line_vertex")
        lineDesc.fragmentFunction = library.makeFunction(name: "ct_line_fragment")
        lineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        lineDesc.colorAttachments[0].isBlendingEnabled = true
        lineDesc.colorAttachments[0].sourceRGBBlendFactor = .one
        lineDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        lineDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        lineDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            self.bgPipeline = try device.makeRenderPipelineState(descriptor: bgDesc)
            self.linePipeline = try device.makeRenderPipelineState(descriptor: lineDesc)
        } catch {
            NSLog("Failed to create CoreText Metal pipeline: \(error)")
            return nil
        }
    }

    /// Set up the line renderer. Called once the FontManager is available.
    func setupLineRenderer(fontManager: FontManager) {
        self.lineRenderer = CoreTextLineRenderer(device: device, fontManager: fontManager)
    }

    /// Render the editor from LineBuffer data.
    func render(lineBuffer: LineBuffer, fontManager: FontManager,
                drawable: CAMetalDrawable, viewportSize: CGSize,
                contentScale: Float, scrollOffset: SIMD2<Float> = .zero) {
        guard let lineRenderer else { return }

        let cellW = Float(fontManager.cellWidth)
        let cellH = Float(fontManager.cellHeight)
        let scale = contentScale

        // Advance frame counter for cache eviction.
        lineRenderer.beginFrame()
        lineRenderer.updateViewportWidth(cols: lineBuffer.cols)

        // Default background color.
        let defaultBg = lineBuffer.defaultBg != 0
            ? colorFromU24(lineBuffer.defaultBg, default: SIMD3<Float>(0.12, 0.12, 0.14))
            : SIMD3<Float>(0.12, 0.12, 0.14)

        // Gutter padding (same as MetalRenderer).
        let gutterPaddingPt: Float = lineBuffer.gutterCol > 0 ? round(12.0 * scale) / scale : 0
        let gutterPaddingPx = gutterPaddingPt * scale

        // Build background quads and line texture instances.
        var bgQuads: [QuadGPU] = []
        var lineInstances: [(LineGPU, MTLTexture)] = []

        for row: UInt16 in 0..<lineBuffer.rows {
            let rowF = Float(row)
            let yPos = rowF * cellH * scale

            // Background: fill the full row with default bg.
            var bgQuad = QuadGPU()
            bgQuad.position = SIMD2<Float>(0, yPos)
            bgQuad.size = SIMD2<Float>(Float(viewportSize.width), cellH * scale)
            bgQuad.color = defaultBg
            bgQuad.alpha = 1.0
            bgQuads.append(bgQuad)

            // Per-run background fills (for runs with explicit bg color or reverse attribute).
            let runs = lineBuffer.runsForLine(row)
            for run in runs {
                let isReverse = (run.attrs & 0x08) != 0  // ATTR_REVERSE
                if run.bg != 0 || isReverse {
                    let bgColor = isReverse
                        ? colorFromU24(run.fg, default: SIMD3<Float>(1, 1, 1))
                        : colorFromU24(run.bg, default: defaultBg)
                    let colOffset = Float(run.col) * cellW * scale
                    let runWidth = Float(run.text.count) * cellW * scale
                    let xPos = run.col >= lineBuffer.gutterCol
                        ? colOffset + gutterPaddingPx : colOffset

                    var runBg = QuadGPU()
                    runBg.position = SIMD2<Float>(xPos, yPos)
                    runBg.size = SIMD2<Float>(runWidth, cellH * scale)
                    runBg.color = bgColor
                    runBg.alpha = 1.0
                    bgQuads.append(runBg)
                }
            }

            // Line texture.
            if !runs.isEmpty {
                let contentHash = lineBuffer.computeLineHash(row: row)
                if let cached = lineRenderer.renderLine(row: row, runs: runs, contentHash: contentHash) {
                    // The texture starts at the first run's column. Gap-filling
                    // spaces in the attributed string handle intra-line positioning.
                    let firstCol = runs.first.map { Float($0.col) } ?? 0
                    let colPx = firstCol * cellW * scale
                    let xPos = firstCol >= Float(lineBuffer.gutterCol)
                        ? colPx + gutterPaddingPx : colPx

                    var lineGPU = LineGPU()
                    lineGPU.position = SIMD2<Float>(xPos, yPos)
                    lineGPU.size = SIMD2<Float>(Float(cached.pixelWidth), Float(cached.pixelHeight))
                    lineGPU.uvOrigin = .zero
                    lineGPU.uvSize = SIMD2<Float>(1, 1)
                    lineInstances.append((lineGPU, cached.texture))
                }
            }
        }

        // Set up render pass.
        let renderDesc = MTLRenderPassDescriptor()
        renderDesc.colorAttachments[0].texture = drawable.texture
        renderDesc.colorAttachments[0].loadAction = .clear
        renderDesc.colorAttachments[0].storeAction = .store
        renderDesc.colorAttachments[0].clearColor = ctBgClearColor

        guard let cmdBuf = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: renderDesc) else { return }

        var uniforms = CTUniformsGPU(
            viewportSize: SIMD2<Float>(Float(viewportSize.width), Float(viewportSize.height)),
            scrollOffset: SIMD2<Float>(scrollOffset.x * scale, scrollOffset.y * scale)
        )

        // Pass 1: Background fills.
        if !bgQuads.isEmpty {
            encoder.setRenderPipelineState(bgPipeline)
            encoder.setVertexBytes(&bgQuads, length: bgQuads.count * MemoryLayout<QuadGPU>.stride, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<CTUniformsGPU>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: bgQuads.count)
        }

        // Pass 2: Cursor background (drawn BEFORE text so text is visible on top).
        // For block cursors, draw the cursor bg here so the text pass composites over it.
        // Beam and underline cursors are drawn AFTER text (pass 5).
        if lineBuffer.cursorVisible && lineBuffer.cursorShape == .block {
            let cursorRow = Float(lineBuffer.cursorRow)
            let cursorCol = Float(lineBuffer.cursorCol)
            let cursorPadding: Float = (lineBuffer.gutterCol > 0 && lineBuffer.cursorCol >= lineBuffer.gutterCol)
                ? gutterPaddingPx : 0

            var cursorQuad = QuadGPU()
            cursorQuad.position = SIMD2<Float>(cursorCol * cellW * scale + cursorPadding, cursorRow * cellH * scale)
            cursorQuad.size = SIMD2<Float>(cellW * scale, cellH * scale)
            cursorQuad.color = SIMD3<Float>(0.8, 0.8, 0.8)
            cursorQuad.alpha = 1.0

            encoder.setRenderPipelineState(bgPipeline)
            encoder.setVertexBytes(&cursorQuad, length: MemoryLayout<QuadGPU>.stride, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<CTUniformsGPU>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
        }

        // Pass 3: Line textures (one draw call per line since each has its own texture).
        if !lineInstances.isEmpty {
            encoder.setRenderPipelineState(linePipeline)
            for var (lineGPU, texture) in lineInstances {
                encoder.setVertexBytes(&lineGPU, length: MemoryLayout<LineGPU>.stride, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<CTUniformsGPU>.size, index: 1)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
            }
        }

        // Pass 4: Gutter gap fill.
        if lineBuffer.gutterCol > 0 && gutterPaddingPx > 0 {
            var fillQuad = QuadGPU()
            fillQuad.position = SIMD2<Float>(Float(lineBuffer.gutterCol) * cellW * scale, 0)
            fillQuad.size = SIMD2<Float>(gutterPaddingPx, Float(viewportSize.height))
            fillQuad.color = defaultBg
            fillQuad.alpha = 1.0

            encoder.setRenderPipelineState(bgPipeline)
            encoder.setVertexBytes(&fillQuad, length: MemoryLayout<QuadGPU>.stride, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<CTUniformsGPU>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
        }

        // Pass 5: Gutter separator line.
        if lineBuffer.gutterCol > 0 && lineBuffer.gutterSeparatorColor != 0 {
            var sepQuad = QuadGPU()
            let sepX = (Float(lineBuffer.gutterCol) * cellW + gutterPaddingPt) * scale - 1.0
            sepQuad.position = SIMD2<Float>(sepX, 0)
            sepQuad.size = SIMD2<Float>(1.0, Float(viewportSize.height))
            sepQuad.color = colorFromU24(lineBuffer.gutterSeparatorColor, default: SIMD3<Float>(0.3, 0.3, 0.3))
            sepQuad.alpha = 1.0

            encoder.setRenderPipelineState(bgPipeline)
            encoder.setVertexBytes(&sepQuad, length: MemoryLayout<QuadGPU>.stride, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<CTUniformsGPU>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
        }

        // Pass 6: Cursor overlay for beam and underline shapes.
        // Block cursor is drawn in pass 2 (before text) so text shows on top.
        // Beam and underline are drawn AFTER text so they overlay it.
        if lineBuffer.cursorVisible && lineBuffer.cursorShape != .block {
            let cursorRow = Float(lineBuffer.cursorRow)
            let cursorCol = Float(lineBuffer.cursorCol)
            let cursorPadding: Float = (lineBuffer.gutterCol > 0 && lineBuffer.cursorCol >= lineBuffer.gutterCol)
                ? gutterPaddingPx : 0

            var cursorQuad = QuadGPU()
            cursorQuad.color = SIMD3<Float>(0.8, 0.8, 0.8)
            cursorQuad.alpha = 1.0

            switch lineBuffer.cursorShape {
            case .block:
                break  // Handled in pass 2.

            case .beam:
                let beamWidth: Float = 2.0 * scale
                cursorQuad.position = SIMD2<Float>(cursorCol * cellW * scale + cursorPadding, cursorRow * cellH * scale)
                cursorQuad.size = SIMD2<Float>(beamWidth, cellH * scale)

            case .underline:
                let ulHeight: Float = 2.0 * scale
                let cellBottom = (cursorRow + 1) * cellH * scale
                cursorQuad.position = SIMD2<Float>(cursorCol * cellW * scale + cursorPadding, cellBottom - ulHeight)
                cursorQuad.size = SIMD2<Float>(cellW * scale, ulHeight)
            }

            encoder.setRenderPipelineState(bgPipeline)
            encoder.setVertexBytes(&cursorQuad, length: MemoryLayout<QuadGPU>.stride, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<CTUniformsGPU>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
        }

        encoder.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    // MARK: - Private

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
