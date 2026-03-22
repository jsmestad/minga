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
import os.log

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
///
/// `@MainActor` because it accesses `FontManager` (main-actor-isolated)
/// in the render path, and all callers are on the main thread already.
@MainActor
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

    /// Cursor color derived from the system accent color (sRGB components).
    /// Updated when the system appearance changes (user picks a new accent
    /// in System Settings). Note: these are sRGB values, not linear. The
    /// `.bgra8Unorm_srgb` framebuffer handles the sRGB→linear conversion
    /// for blending, so passing sRGB here is correct for visual accuracy.
    private(set) var cursorColor: SIMD3<Float>

    /// Notification observer for system color changes. Stored so we can
    /// remove it in deinit if needed (though the renderer lives for the
    /// app's entire lifetime in practice).
    private var colorChangeObserver: NSObjectProtocol?

    /// Current theme colors reference, set at the start of each render call.
    /// Used by helper methods (appendSelectionQuads, etc.) to read theme-driven
    /// colors without threading the parameter through every call.
    private var currentThemeColors: ThemeColors?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        self.clearColor = ctBgClearColorDefault

        // Read the system accent color for the cursor.
        self.cursorColor = CoreTextMetalRenderer.readAccentColor()

        // Load the compiled Metal shader library.
        // For app bundles, the metallib is in Contents/Resources/. For tool
        // targets, it's next to the executable. Try both paths.
        let library: MTLLibrary
        if let lib = try? device.makeDefaultLibrary(bundle: Bundle.main) {
            // App bundle: Xcode places default.metallib in the Resources dir
            // and makeDefaultLibrary(bundle:) finds it automatically.
            library = lib
        } else {
            let executableURL = Bundle.main.executableURL!
            let metallibURL = executableURL.deletingLastPathComponent().appendingPathComponent("default.metallib")
            guard let lib = try? device.makeLibrary(URL: metallibURL) else {
                NSLog("Failed to load Metal library from \(metallibURL.path)")
                return nil
            }
            library = lib
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

        // Watch for system accent color changes so the cursor color stays
        // in sync with System Settings.
        colorChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleColorPreferencesChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cursorColor = CoreTextMetalRenderer.readAccentColor()
            }
        }
    }

    /// Read `NSColor.controlAccentColor` as an sRGB SIMD3 for Metal.
    ///
    /// Returns sRGB components (not linear). This is correct because the
    /// `.bgra8Unorm_srgb` framebuffer applies sRGB↔linear conversion
    /// during blending, so sRGB input produces accurate output.
    static func readAccentColor() -> SIMD3<Float> {
        guard let rgb = NSColor.controlAccentColor.usingColorSpace(.sRGB) else {
            return SIMD3<Float>(0.8, 0.8, 0.8)
        }
        return SIMD3<Float>(Float(rgb.redComponent),
                            Float(rgb.greenComponent),
                            Float(rgb.blueComponent))
    }

    /// Semantic window content renderer (from 0x80 opcode).
    private(set) var windowContentRenderer: WindowContentRenderer?

    /// Set up the line renderer. Called once the FontManager is available.
    /// Shared pooled bitmap rasterizer for both line renderers.
    private var bitmapRasterizer: BitmapRasterizer?

    /// Line texture atlas for batched instanced drawing.
    private(set) var atlas: LineTextureAtlas?

    /// Metal buffer for line GPU instances (one instanced draw call).
    private var instanceBuffer: MTLBuffer?
    private var maxInstanceSlots: Int = 0

    /// Set up the line renderer. Called once the FontManager is available.
    func setupLineRenderer(fontManager: FontManager) {
        let rasterizer = BitmapRasterizer()
        self.bitmapRasterizer = rasterizer
        self.lineRenderer = CoreTextLineRenderer(device: device, fontManager: fontManager, rasterizer: rasterizer)
        self.windowContentRenderer = WindowContentRenderer(device: device, fontManager: fontManager, rasterizer: rasterizer)

        let linePixelHeight = Int(ceil(CGFloat(fontManager.cellHeight) * fontManager.scale))
        self.atlas = LineTextureAtlas(device: device, slotHeight: linePixelHeight)
    }

    /// Render the editor from LineBuffer data + semantic window content.
    ///
    /// Buffer windows with semantic content (from 0x80 opcode) are rendered
    /// via `WindowContentRenderer`. Everything else (overlays, agent chat,
    /// cursor, gutter, separator) continues through the LineBuffer path.
    func render(lineBuffer: LineBuffer, fontManager: FontManager,
                windowContents: [UInt16: GUIWindowContent] = [:],
                themeColors: ThemeColors? = nil,
                drawable: CAMetalDrawable, viewportSize: CGSize,
                contentScale: Float, scrollOffset: SIMD2<Float> = .zero) {
        guard let lineRenderer else { return }

        // Store theme colors reference for helper methods.
        self.currentThemeColors = themeColors

        let cellW = Float(fontManager.cellWidth)
        let cellH = Float(fontManager.cellHeight)
        let scale = contentScale

        // Advance frame counter for cache eviction.
        lineRenderer.beginFrame()
        lineRenderer.updateViewportWidth(cols: lineBuffer.cols)

        // Advance semantic content renderer.
        if let wcr = windowContentRenderer {
            wcr.beginFrame()
            wcr.updateViewportWidth(cols: lineBuffer.cols)
            if let tc = themeColors {
                wcr.defaultFgRGB = tc.editorFgRGB
            }
        }

        // Ensure atlas can hold all lines (content + gutter + semantic).
        if let atlas {
            let neededSlots = Int(lineBuffer.rows) * 4
            let atlasPixelWidth = Int(ceil(CGFloat(lineBuffer.cols) * CGFloat(cellW) * CGFloat(scale)))
            atlas.ensureCapacity(maxSlots: neededSlots, width: atlasPixelWidth)
            atlas.beginFrame()

            if neededSlots > maxInstanceSlots {
                maxInstanceSlots = neededSlots
                instanceBuffer = device.makeBuffer(
                    length: neededSlots * MemoryLayout<LineGPU>.stride,
                    options: .storageModeShared
                )
            }
        }

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
        var lineInstances: [LineGPU] = []

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
                    let colSpan = Self.runColSpan(runs: runs, at: i)
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
                if let atlas, let entry = lineRenderer.renderLineToAtlas(row: row, runs: runs, contentHash: contentHash, atlas: atlas) {
                    let firstCol = runs.first.map { Float($0.col) } ?? 0
                    let colPx = firstCol * cellW * scale
                    let xPos = firstCol >= Float(lineBuffer.gutterCol)
                        ? colPx + gutterPaddingPx : colPx

                    let (uvOrigin, uvSize) = atlas.uvForSlot(entry.slotIndex, pixelWidth: entry.pixelWidth)
                    var lineGPU = LineGPU()
                    lineGPU.position = SIMD2<Float>(xPos, yPos)
                    lineGPU.size = SIMD2<Float>(Float(entry.pixelWidth), Float(entry.pixelHeight))
                    lineGPU.uvOrigin = uvOrigin
                    lineGPU.uvSize = uvSize
                    lineInstances.append(lineGPU)
                }
            }
        }

        // Semantic window content rendering (from 0x80 opcode).
        // Buffer windows with semantic content bypass LineBuffer for text;
        // their line textures come from WindowContentRenderer instead.
        // Selection, search, and diagnostic overlays are drawn as Metal quads.
        var semanticOverlayQuads: [QuadGPU] = []
        var diagnosticQuads: [QuadGPU] = []

        if let wcr = windowContentRenderer {
            for (_, content) in windowContents {
                // Match gutter data to semantic window content by windowId.
                guard let gutter = lineBuffer.windowGutters[content.windowId] else {
                    continue
                }

                let windowRowOffset = Float(gutter.contentRow) * cellH * scale
                let gutterWidth = Float(gutter.lineNumberWidth) + Float(gutter.signColWidth)
                let contentColOffset = (Float(gutter.contentCol) + gutterWidth) * cellW * scale + gutterPaddingPx

                // Horizontal scroll: shift line textures and overlays left by scrollLeft columns.
                // The gutter stays fixed; only content past the gutter edge scrolls.
                let hScrollPx = Float(content.scrollLeft) * cellW * scale

                // Selection overlay quads (drawn before text).
                if let sel = content.selection {
                    appendSelectionQuads(
                        selection: sel,
                        rowOffset: windowRowOffset,
                        colOffset: contentColOffset - hScrollPx,
                        cellW: cellW, cellH: cellH, scale: scale,
                        viewportWidth: Float(viewportSize.width),
                        quads: &semanticOverlayQuads
                    )
                }

                // Document highlight overlay quads (drawn before search matches,
                // so search matches paint over them when they overlap).
                for highlight in content.documentHighlights {
                    // Document highlights are typically single-line (one identifier).
                    // Draw on startRow only; multi-row highlights are rare for this feature.
                    let hlY = windowRowOffset + Float(highlight.startRow) * cellH * scale
                    let hlX = contentColOffset + Float(highlight.startCol) * cellW * scale - hScrollPx
                    let hlW = Float(highlight.endCol - highlight.startCol) * cellW * scale

                    var quad = QuadGPU()
                    quad.position = SIMD2<Float>(hlX, hlY)
                    quad.size = SIMD2<Float>(hlW, cellH * scale)
                    // Write references get a warmer amber tint; read/text get a subtle blue-gray.
                    // Colors are driven by the theme via ThemeColors slots 0x59/0x5A.
                    quad.color = highlight.kind == .write
                        ? (currentThemeColors?.highlightWriteBgSIMD ?? SIMD3<Float>(0.29, 0.25, 0.17))
                        : (currentThemeColors?.highlightReadBgSIMD ?? SIMD3<Float>(0.23, 0.25, 0.29))
                    quad.alpha = 1.0
                    semanticOverlayQuads.append(quad)
                }

                // Search match overlay quads (drawn before text).
                for match in content.searchMatches {
                    let matchY = windowRowOffset + Float(match.row) * cellH * scale
                    let matchX = contentColOffset + Float(match.startCol) * cellW * scale - hScrollPx
                    let matchW = Float(match.endCol - match.startCol) * cellW * scale

                    var quad = QuadGPU()
                    quad.position = SIMD2<Float>(matchX, matchY)
                    quad.size = SIMD2<Float>(matchW, cellH * scale)
                    quad.color = match.isCurrent
                        ? SIMD3<Float>(0.95, 0.75, 0.0)    // current match: gold
                        : SIMD3<Float>(0.35, 0.35, 0.15)   // other matches: dim gold
                    quad.alpha = 1.0
                    semanticOverlayQuads.append(quad)
                }

                // Render line textures from semantic content into atlas.
                for (rowIdx, row) in content.rows.enumerated() {
                    if let atlas, let entry = wcr.renderRowToAtlas(displayRow: UInt16(rowIdx), row: row, atlas: atlas) {
                        let yPos = windowRowOffset + Float(rowIdx) * cellH * scale

                        let (uvOrigin, uvSize) = atlas.uvForSlot(entry.slotIndex, pixelWidth: entry.pixelWidth)
                        var lineGPU = LineGPU()
                        lineGPU.position = SIMD2<Float>(contentColOffset - hScrollPx, yPos)
                        lineGPU.size = SIMD2<Float>(Float(entry.pixelWidth), Float(entry.pixelHeight))
                        lineGPU.uvOrigin = uvOrigin
                        lineGPU.uvSize = uvSize
                        lineInstances.append(lineGPU)
                    }
                }

                // Diagnostic underline quads (drawn after text).
                for diag in content.diagnosticUnderlines {
                    let diagColor: SIMD3<Float> = switch diag.severity {
                    case .error:   SIMD3<Float>(1.0, 0.42, 0.42)   // red
                    case .warning: SIMD3<Float>(0.93, 0.75, 0.48)  // yellow
                    case .info:    SIMD3<Float>(0.32, 0.69, 0.94)  // blue
                    case .hint:    SIMD3<Float>(0.33, 0.33, 0.33)  // gray
                    }

                    let diagY = windowRowOffset + Float(diag.startRow) * cellH * scale + cellH * scale - 2.0 * scale
                    let diagX = contentColOffset + Float(diag.startCol) * cellW * scale - hScrollPx
                    let diagW = Float(diag.endCol - diag.startCol) * cellW * scale

                    var quad = QuadGPU()
                    quad.position = SIMD2<Float>(diagX, diagY)
                    quad.size = SIMD2<Float>(diagW, 2.0 * scale)
                    quad.color = diagColor
                    quad.alpha = 1.0
                    diagnosticQuads.append(quad)
                }
            }
        }

        // Native gutter rendering from structured data.
        // One GUIWindowGutter per editor window (split pane).
        for (_, windowGutter) in lineBuffer.windowGutters {
            renderGutterEntries(
                gutter: windowGutter,
                lineBuffer: lineBuffer,
                cellW: cellW, cellH: cellH, scale: scale,
                gutterPaddingPx: gutterPaddingPx,
                bgQuads: &bgQuads,
                lineInstances: &lineInstances
            )
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

        // Pass 1.5: Semantic overlay quads (search matches, selection).
        // Drawn after bg fills but before cursor and text so they appear
        // behind text content. Selection and search highlights render as
        // Metal quads instead of being baked into line textures.
        if !semanticOverlayQuads.isEmpty {
            encoder.setRenderPipelineState(bgPipeline)
            encoder.setVertexBytes(&semanticOverlayQuads, length: semanticOverlayQuads.count * MemoryLayout<QuadGPU>.stride, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<CTUniformsGPU>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: semanticOverlayQuads.count)
        }

        // Pass 2: Cursor background (drawn BEFORE text so text is visible on top).
        // For block cursors, draw the cursor bg here so the text pass composites over it.
        // Beam and underline cursors are drawn AFTER text (pass 5).
        // NOTE: Cursor position uses lineBuffer.cursorRow/Col from the TUI cell-grid
        // path, which the BEAM computes as gutter_w + (cursor_col - viewport.left).
        // Horizontal scroll is already baked in. If the TUI rendering path is ever
        // removed for GUI frontends, cursor positioning will need to use the semantic
        // window's cursor_col and scroll_left instead.
        if lineBuffer.cursorVisible && lineBuffer.cursorShape == .block {
            let cursorRow = Float(lineBuffer.cursorRow)
            let cursorCol = Float(lineBuffer.cursorCol)
            let cursorPadding: Float = (lineBuffer.gutterCol > 0 && lineBuffer.cursorCol >= lineBuffer.gutterCol)
                ? gutterPaddingPx : 0

            var cursorQuad = QuadGPU()
            cursorQuad.position = SIMD2<Float>(cursorCol * cellW * scale + cursorPadding, cursorRow * cellH * scale)
            cursorQuad.size = SIMD2<Float>(cellW * scale, cellH * scale)
            cursorQuad.color = cursorColor
            cursorQuad.alpha = 1.0

            encoder.setRenderPipelineState(bgPipeline)
            encoder.setVertexBytes(&cursorQuad, length: MemoryLayout<QuadGPU>.stride, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<CTUniformsGPU>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
        }

        // Pass 3: Line textures — one instanced draw call with the atlas texture.
        if !lineInstances.isEmpty, let atlas, let atlasTexture = atlas.texture,
           let instBuf = instanceBuffer {
            // Copy instance data into the shared Metal buffer.
            let byteCount = lineInstances.count * MemoryLayout<LineGPU>.stride
            _ = lineInstances.withUnsafeBytes { ptr in
                memcpy(instBuf.contents(), ptr.baseAddress!, byteCount)
            }

            encoder.setRenderPipelineState(linePipeline)
            encoder.setVertexBuffer(instBuf, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<CTUniformsGPU>.size, index: 1)
            encoder.setFragmentTexture(atlasTexture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                                   instanceCount: lineInstances.count)
        }

        // Pass 3.5: Diagnostic underline quads (drawn after text, before gutter).
        if !diagnosticQuads.isEmpty {
            encoder.setRenderPipelineState(bgPipeline)
            encoder.setVertexBytes(&diagnosticQuads, length: diagnosticQuads.count * MemoryLayout<QuadGPU>.stride, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<CTUniformsGPU>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: diagnosticQuads.count)
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
            cursorQuad.color = cursorColor
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

    // MARK: - Native Gutter Rendering

    /// Renders line numbers and signs natively from structured gutter data.
    ///
    /// Line numbers are rendered as CTLine textures through the existing
    /// CoreTextLineRenderer. Git signs are drawn as colored Metal quads.
    /// Diagnostic signs are rendered as CTLine textures.
    private func renderGutterEntries(
        gutter: GUIWindowGutter,
        lineBuffer: LineBuffer,
        cellW: Float, cellH: Float, scale: Float,
        gutterPaddingPx: Float,
        bgQuads: inout [QuadGPU],
        lineInstances: inout [LineGPU]
    ) {
        guard let lineRenderer else { return }
        let signColWidth = Int(gutter.signColWidth)
        let baseRow = gutter.contentRow
        let baseCol = gutter.contentCol

        for (rowIndex, entry) in gutter.entries.enumerated() {
            let screenRow = baseRow + UInt16(rowIndex)
            let yPos = Float(screenRow) * cellH * scale
            let xOffset = Float(baseCol) * cellW * scale

            // Sign column (leftmost in gutter)
            if signColWidth > 0 {
                renderGutterSign(
                    entry: entry, screenRow: screenRow, yPos: yPos, xOffset: xOffset,
                    cellW: cellW, cellH: cellH, scale: scale,
                    lineBuffer: lineBuffer,
                    bgQuads: &bgQuads, lineInstances: &lineInstances,
                    lineRenderer: lineRenderer
                )
            }

            // Line number (after sign column)
            if gutter.lineNumberStyle != .none && gutter.lineNumberWidth > 0 {
                renderGutterLineNumber(
                    entry: entry, gutter: gutter,
                    screenRow: screenRow, yPos: yPos, xOffset: xOffset,
                    signColWidth: signColWidth,
                    cellW: cellW, cellH: cellH, scale: scale,
                    lineBuffer: lineBuffer,
                    lineInstances: &lineInstances,
                    lineRenderer: lineRenderer
                )
            }
        }
    }

    /// Renders a git or diagnostic sign for one gutter row.
    ///
    /// Git signs (added/modified/deleted) are drawn as thin colored bars
    /// using Metal quads. Diagnostic signs (E/W/I/H) are rendered as
    /// CTLine textures in the diagnostic color.
    private func renderGutterSign(
        entry: GUIGutterEntry, screenRow: UInt16, yPos: Float, xOffset: Float,
        cellW: Float, cellH: Float, scale: Float,
        lineBuffer: LineBuffer,
        bgQuads: inout [QuadGPU],
        lineInstances: inout [LineGPU],
        lineRenderer: CoreTextLineRenderer
    ) {
        switch entry.signType {
        case .gitAdded:
            var quad = QuadGPU()
            let gitBarWidth = round(3.0 * scale)
            quad.position = SIMD2<Float>(xOffset, yPos)
            quad.size = SIMD2<Float>(gitBarWidth, cellH * scale)
            quad.color = gutterSignColor(entry.signType, lineBuffer: lineBuffer)
            quad.alpha = 1.0
            bgQuads.append(quad)

        case .gitModified:
            var quad = QuadGPU()
            let gitBarWidth = round(3.0 * scale)
            quad.position = SIMD2<Float>(xOffset, yPos)
            quad.size = SIMD2<Float>(gitBarWidth, cellH * scale)
            quad.color = gutterSignColor(entry.signType, lineBuffer: lineBuffer)
            quad.alpha = 1.0
            bgQuads.append(quad)

        case .gitDeleted:
            var quad = QuadGPU()
            let barHeight = round(2.0 * scale)
            quad.position = SIMD2<Float>(xOffset, yPos + cellH * scale - barHeight)
            quad.size = SIMD2<Float>(cellW * 2 * scale, barHeight)
            quad.color = gutterSignColor(entry.signType, lineBuffer: lineBuffer)
            quad.alpha = 1.0
            bgQuads.append(quad)

        case .diagError, .diagWarning, .diagInfo, .diagHint:
            let (text, fg) = diagnosticSignTextAndColor(entry.signType, lineBuffer: lineBuffer)
            let runs = [StyledRun(col: 0, text: text, fg: fg, bg: 0, attrs: 0)]
            let cacheRow = 0x8000 + screenRow
            let contentHash = gutterContentHash(text: text, fg: fg)
            if let atlas, let entry = lineRenderer.renderLineToAtlas(row: cacheRow, runs: runs, contentHash: contentHash, atlas: atlas) {
                let (uvOrigin, uvSize) = atlas.uvForSlot(entry.slotIndex, pixelWidth: entry.pixelWidth)
                var lineGPU = LineGPU()
                lineGPU.position = SIMD2<Float>(xOffset, yPos)
                lineGPU.size = SIMD2<Float>(Float(entry.pixelWidth), Float(entry.pixelHeight))
                lineGPU.uvOrigin = uvOrigin
                lineGPU.uvSize = uvSize
                lineInstances.append(lineGPU)
            }

        case .none:
            break
        }
    }

    /// Renders a line number for one gutter row.
    private func renderGutterLineNumber(
        entry: GUIGutterEntry, gutter: GUIWindowGutter,
        screenRow: UInt16, yPos: Float, xOffset: Float,
        signColWidth: Int,
        cellW: Float, cellH: Float, scale: Float,
        lineBuffer: LineBuffer,
        lineInstances: inout [LineGPU],
        lineRenderer: CoreTextLineRenderer
    ) {
        let (numberStr, isCurrent) = gutterNumberString(
            bufLine: entry.bufLine,
            cursorLine: gutter.cursorLine,
            style: gutter.lineNumberStyle
        )

        guard !numberStr.isEmpty else { return }

        let fg = isCurrent ? lineBuffer.gutterCurrentFgColor : lineBuffer.gutterFgColor
        let lnWidth = Int(gutter.lineNumberWidth)

        // Right-align the number within the line number column space.
        // The number starts after the sign column.
        let padCols = max(lnWidth - numberStr.count - 1, 0)
        let startCol = UInt16(signColWidth + padCols)

        let runs = [StyledRun(col: startCol, text: numberStr, fg: fg, bg: 0, attrs: 0)]
        let cacheRow = 0x9000 + screenRow
        let contentHash = gutterContentHash(text: numberStr, fg: fg)
        if let atlas, let entry = lineRenderer.renderLineToAtlas(row: cacheRow, runs: runs, contentHash: contentHash, atlas: atlas) {
            let (uvOrigin, uvSize) = atlas.uvForSlot(entry.slotIndex, pixelWidth: entry.pixelWidth)
            let xPos = xOffset + Float(startCol) * cellW * scale
            var lineGPU = LineGPU()
            lineGPU.position = SIMD2<Float>(xPos, yPos)
            lineGPU.size = SIMD2<Float>(Float(entry.pixelWidth), Float(entry.pixelHeight))
            lineGPU.uvOrigin = uvOrigin
            lineGPU.uvSize = uvSize
            lineInstances.append(lineGPU)
        }
    }

    /// Computes the display string and current-line flag for a gutter line number.
    private func gutterNumberString(
        bufLine: UInt32, cursorLine: UInt32, style: GUILineNumberStyle
    ) -> (String, Bool) {
        let isCursor = bufLine == cursorLine
        switch style {
        case .absolute:
            return (String(bufLine + 1), isCursor)
        case .relative:
            let rel = abs(Int64(bufLine) - Int64(cursorLine))
            return (String(rel), isCursor)
        case .hybrid:
            if isCursor {
                return (String(bufLine + 1), true)
            } else {
                let rel = abs(Int64(bufLine) - Int64(cursorLine))
                return (String(rel), false)
            }
        case .none:
            return ("", false)
        }
    }

    /// Returns the color for a git/diagnostic gutter sign from the line buffer's theme colors.
    private func gutterSignColor(_ signType: GUIGutterSignType, lineBuffer: LineBuffer) -> SIMD3<Float> {
        switch signType {
        case .gitAdded: return colorFromU24(lineBuffer.gitAddedFgColor, default: .zero)
        case .gitModified: return colorFromU24(lineBuffer.gitModifiedFgColor, default: .zero)
        case .gitDeleted: return colorFromU24(lineBuffer.gitDeletedFgColor, default: .zero)
        case .diagError: return colorFromU24(lineBuffer.gutterErrorFgColor, default: .zero)
        case .diagWarning: return colorFromU24(lineBuffer.gutterWarningFgColor, default: .zero)
        case .diagInfo: return colorFromU24(lineBuffer.gutterInfoFgColor, default: .zero)
        case .diagHint: return colorFromU24(lineBuffer.gutterHintFgColor, default: .zero)
        case .none: return .zero
        }
    }

    /// Returns the sign character and fg color (as U24) for a diagnostic sign type.
    private func diagnosticSignTextAndColor(_ signType: GUIGutterSignType, lineBuffer: LineBuffer) -> (String, UInt32) {
        switch signType {
        case .diagError: return ("E", lineBuffer.gutterErrorFgColor)
        case .diagWarning: return ("W", lineBuffer.gutterWarningFgColor)
        case .diagInfo: return ("I", lineBuffer.gutterInfoFgColor)
        case .diagHint: return ("H", lineBuffer.gutterHintFgColor)
        default: return ("", 0)
        }
    }

    /// Simple content hash for gutter entries.
    private func gutterContentHash(text: String, fg: UInt32) -> Int {
        var hasher = Hasher()
        hasher.combine(text)
        hasher.combine(fg)
        return hasher.finalize()
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

    /// Build selection overlay quads from semantic selection data.
    ///
    /// Char selection: one quad per row (partial for first/last rows).
    /// Line selection: full-width quads for each row in the range.
    private func appendSelectionQuads(
        selection sel: GUISelectionOverlay,
        rowOffset: Float, colOffset: Float,
        cellW: Float, cellH: Float, scale: Float,
        viewportWidth: Float,
        quads: inout [QuadGPU]
    ) {
        let selColor = currentThemeColors?.selectionBgSIMD ?? SIMD3<Float>(0.15, 0.30, 0.55)

        switch sel.type {
        case .line:
            for row in sel.startRow...sel.endRow {
                var quad = QuadGPU()
                quad.position = SIMD2<Float>(colOffset, rowOffset + Float(row) * cellH * scale)
                quad.size = SIMD2<Float>(viewportWidth - colOffset, cellH * scale)
                quad.color = selColor
                quad.alpha = 1.0
                quads.append(quad)
            }

        case .char:
            for row in sel.startRow...sel.endRow {
                let y = rowOffset + Float(row) * cellH * scale
                let startCol: Float
                let endCol: Float

                if row == sel.startRow && row == sel.endRow {
                    startCol = Float(sel.startCol)
                    endCol = Float(sel.endCol)
                } else if row == sel.startRow {
                    startCol = Float(sel.startCol)
                    endCol = (viewportWidth - colOffset) / (cellW * scale)
                } else if row == sel.endRow {
                    startCol = 0
                    endCol = Float(sel.endCol)
                } else {
                    startCol = 0
                    endCol = (viewportWidth - colOffset) / (cellW * scale)
                }

                var quad = QuadGPU()
                quad.position = SIMD2<Float>(colOffset + startCol * cellW * scale, y)
                quad.size = SIMD2<Float>((endCol - startCol) * cellW * scale, cellH * scale)
                quad.color = selColor
                quad.alpha = 1.0
                quads.append(quad)
            }

        case .block:
            for row in sel.startRow...sel.endRow {
                let y = rowOffset + Float(row) * cellH * scale
                let x = colOffset + Float(sel.startCol) * cellW * scale
                let w = Float(sel.endCol - sel.startCol) * cellW * scale

                var quad = QuadGPU()
                quad.position = SIMD2<Float>(x, y)
                quad.size = SIMD2<Float>(w, cellH * scale)
                quad.color = selColor
                quad.alpha = 1.0
                quads.append(quad)
            }
        }
    }

    /// Compute the column span for a run's background fill quad.
    ///
    /// For non-last runs, the span is the distance to the next run's column.
    /// Uses Int arithmetic to avoid UInt16 underflow when runs arrive out of
    /// order (protocol edge case), and clamps to a minimum of 1 cell.
    /// For the last run on a line, falls back to display width calculation.
    nonisolated static func runColSpan(runs: [StyledRun], at index: Int) -> UInt16 {
        if index + 1 < runs.count {
            let span = Int(runs[index + 1].col) - Int(runs[index].col)
            #if DEBUG
            if span <= 0 {
                os_log(.fault, "Renderer: out-of-order runs at index %d, col %u >= %u",
                       index, runs[index].col, runs[index + 1].col)
            }
            #endif
            return UInt16(max(span, 1))
        } else {
            return UInt16(displayWidth(runs[index].text))
        }
    }

    /// Calculate the display width (in cell columns) of a string,
    /// accounting for wide characters (CJK, emoji, etc.).
    nonisolated static func displayWidth(_ text: String) -> Int {
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
