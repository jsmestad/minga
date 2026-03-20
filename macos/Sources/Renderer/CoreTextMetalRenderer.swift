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

/// Default background clear color (dark gray matching the default bg).
/// Linear equivalents of sRGB (0.12, 0.12, 0.14).
private let ctBgClearColorDefault = MTLClearColor(red: 0.01298, green: 0.01298, blue: 0.01681, alpha: 1.0)

/// Renders the editor using CoreText line textures instead of cell-grid instanced drawing.
final class CoreTextMetalRenderer {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private let bgPipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState

    /// The CoreText line rendering engine.
    private(set) var lineRenderer: CoreTextLineRenderer?

    /// Dynamic clear color, updated when the theme's default bg changes.
    private var clearColor: MTLClearColor
    /// Cached defaultBg value to detect changes.
    private var cachedDefaultBg: UInt32 = 0

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        self.clearColor = ctBgClearColorDefault

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

        // Update clear color dynamically when the theme's default bg changes.
        if lineBuffer.defaultBg != cachedDefaultBg {
            cachedDefaultBg = lineBuffer.defaultBg
            if lineBuffer.defaultBg != 0 {
                // Convert sRGB [0,1] to linear for MTLClearColor.
                let r = Double(defaultBg.x)
                let g = Double(defaultBg.y)
                let b = Double(defaultBg.z)
                func srgbToLinear(_ c: Double) -> Double {
                    c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
                }
                clearColor = MTLClearColor(red: srgbToLinear(r), green: srgbToLinear(g), blue: srgbToLinear(b), alpha: 1.0)
            } else {
                clearColor = ctBgClearColorDefault
            }
        }

        // Gutter padding (same as MetalRenderer).
        let gutterPaddingPt: Float = lineBuffer.gutterCol > 0 ? round(12.0 * scale) / scale : 0
        let gutterPaddingPx = gutterPaddingPt * scale

        // Build background quads and line texture instances.
        var bgQuads: [QuadGPU] = []
        var lineInstances: [(LineGPU, MTLTexture)] = []

        for row: UInt16 in 0..<lineBuffer.rows {
            let rowF = Float(row)
            let yPos = rowF * cellH * scale

            // Background: fill the full row with default bg, but only if the
            // row has per-run bg colors that differ from the clear color.
            // When the clear color matches the default bg, the row-wide fill
            // is redundant because the render pass already clears to that color.
            let runs = lineBuffer.runsForLine(row)
            let hasExplicitBg = runs.contains { run in
                let isReverse = (run.attrs & 0x08) != 0
                return run.bg != 0 || isReverse
            }
            if hasExplicitBg {
                var bgQuad = QuadGPU()
                bgQuad.position = SIMD2<Float>(0, yPos)
                bgQuad.size = SIMD2<Float>(Float(viewportSize.width), cellH * scale)
                bgQuad.color = defaultBg
                bgQuad.alpha = 1.0
                bgQuads.append(bgQuad)
            }

            // Cursorline: draw a full-width bg fill on the cursor row.
            // This replaces the TUI fill draw (all-space text with bg color)
            // with a native Metal quad for crisp, overlap-free rendering.
            if row == lineBuffer.cursorlineRow && lineBuffer.cursorlineBg != 0 {
                var clQuad = QuadGPU()
                clQuad.position = SIMD2<Float>(0, yPos)
                clQuad.size = SIMD2<Float>(Float(viewportSize.width), cellH * scale)
                clQuad.color = colorFromU24(lineBuffer.cursorlineBg, default: defaultBg)
                clQuad.alpha = 1.0
                bgQuads.append(clQuad)
            }

            // Per-run background fills (for runs with explicit bg color or reverse attribute).
            for (i, run) in runs.enumerated() {
                let isReverse = (run.attrs & 0x08) != 0  // ATTR_REVERSE
                if run.bg != 0 || isReverse {
                    let bgColor = isReverse
                        ? colorFromU24(run.fg, default: SIMD3<Float>(1, 1, 1))
                        : colorFromU24(run.bg, default: defaultBg)
                    let colOffset = Float(run.col) * cellW * scale
                    // Use column span (next run col - this run col) for correct
                    // width with CJK/wide characters, falling back to display
                    // width calculation for the last run on the line.
                    let colSpan: UInt16
                    if i + 1 < runs.count {
                        colSpan = runs[i + 1].col - run.col
                    } else {
                        colSpan = UInt16(displayWidth(run.text))
                    }
                    let runWidth = Float(colSpan) * cellW * scale
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
        renderDesc.colorAttachments[0].clearColor = clearColor

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
