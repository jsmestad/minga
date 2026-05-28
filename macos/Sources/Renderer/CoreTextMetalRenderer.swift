/// CoreText-based Metal renderer.
///
/// Renders the editor screen from FrameState metadata + WindowContentRenderer, replacing
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
import os.signpost

private let rendererLog = OSLog(subsystem: "com.minga.editor", category: "Renderer")

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

/// Per-draw-call parameters for bg/cursor passes (must match BgParams in CoreTextShaders.metal).
struct BgParamsGPU {
    var cornerRadius: Float = 0.0
}

/// Cursor geometry in device pixels for the current render frame.
struct RenderCursor: Equatable {
    let x: Float
    let y: Float
    let shape: CursorShape
    let windowId: UInt16?

    init(x: Float, y: Float, shape: CursorShape, windowId: UInt16? = nil) {
        self.x = x
        self.y = y
        self.shape = shape
        self.windowId = windowId
    }
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
    /// Left margin before the gutter (breathing room from the window edge).
    static let gutterLeftMarginPt: CGFloat = 6.0
    /// Right gap between gutter and content (separator breathing room).
    static let gutterRightGapPt: CGFloat = 8.0
    /// Total gutter pixel padding in points (left margin + right separator gap).
    /// Subtracted from the view width when computing cols for the BEAM so
    /// `content_w` accurately reflects the visible content area.
    static let gutterPixelPaddingPt: CGFloat = gutterLeftMarginPt + gutterRightGapPt

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private let bgPipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState

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

    /// Whether the cursor is currently gliding toward a new renderer-side target.
    private(set) var cursorAnimating: Bool = false

    /// Incremented each time a new cursor animation starts so the view can keep blink visible during movement.
    private(set) var cursorAnimationGeneration: UInt64 = 0

    /// Effective cursor animation setting after combining user config and Reduce Motion.
    private(set) var cursorAnimateEnabled: Bool = true

    /// User-configured cursor animation preference received from the BEAM.
    private var cursorAnimateConfigEnabled: Bool = true

    /// System accessibility Reduce Motion state, which always disables cursor animation.
    private var cursorAnimationReduceMotionDisabled: Bool = false

    private var hasCursorAnimationPosition: Bool = false
    private var currentCursorX: Float = 0
    private var currentCursorY: Float = 0
    private var startCursorX: Float = 0
    private var startCursorY: Float = 0
    private var targetCursorX: Float = 0
    private var targetCursorY: Float = 0
    private var targetCursorShape: CursorShape = .block
    private var targetCursorWindowId: UInt16?
    private var cursorAnimationStartTime: CFTimeInterval = 0
    private let cursorAnimationDuration: CFTimeInterval = 0.035

    /// Scroll indicator opacity (0.0 = hidden, 1.0 = fully visible).
    /// Set by EditorNSView based on scroll activity and fade timer.
    var scrollIndicatorAlpha: Float = 0.0

    /// Notification observer for system color changes. Stored so we can
    /// remove it in deinit if needed (though the renderer lives for the
    /// app's entire lifetime in practice).
    private var colorChangeObserver: NSObjectProtocol?

    /// System selection color from NSColor.selectedTextBackgroundColor.
    /// Used as fallback when no theme override is set. Computed once at
    /// class load time (macOS caches the system color).
    private static let systemSelectionColor: SIMD3<Float> = {
        let nsColor = NSColor.selectedTextBackgroundColor.usingColorSpace(.sRGB)
            ?? NSColor.selectedTextBackgroundColor
        return SIMD3<Float>(
            Float(nsColor.redComponent),
            Float(nsColor.greenComponent),
            Float(nsColor.blueComponent)
        )
    }()

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

        // Try loading cached pipeline states first, fall back to runtime compilation.
        let pipelineStart = CFAbsoluteTimeGetCurrent()

        if let cached = PipelineCache.loadCachedPipelines(
            device: device, library: library,
            bgDescriptor: bgDesc, lineDescriptor: lineDesc
        ) {
            self.bgPipeline = cached.bg
            self.linePipeline = cached.line
            let elapsed = (CFAbsoluteTimeGetCurrent() - pipelineStart) * 1000
            os_log(.info, log: rendererLog, "Metal pipelines loaded from cache in %.1fms", elapsed)
        } else {
            do {
                self.bgPipeline = try device.makeRenderPipelineState(descriptor: bgDesc)
                self.linePipeline = try device.makeRenderPipelineState(descriptor: lineDesc)
                let elapsed = (CFAbsoluteTimeGetCurrent() - pipelineStart) * 1000
                os_log(.info, log: rendererLog, "Metal pipelines compiled from shaders in %.1fms", elapsed)

                // Cache the compiled pipelines for next launch.
                PipelineCache.savePipelineCache(
                    device: device, library: library,
                    bgDescriptor: bgDesc, lineDescriptor: lineDesc
                )
            } catch {
                os_log(.error, log: rendererLog, "Failed to create CoreText Metal pipeline: %{public}@",
                       error.localizedDescription)
                return nil
            }
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

    /// Per-frame render metrics emitted through os_signpost.
    private var frameMetrics = FrameMetrics()

    /// Metal buffer for line GPU instances (one instanced draw call).
    private var instanceBuffer: MTLBuffer?
    private var maxInstanceSlots: Int = 0

    /// Set up the window content renderer and texture atlas. Called once the FontManager is available.
    func setupRenderers(fontManager: FontManager) {
        let rasterizer = BitmapRasterizer()
        self.bitmapRasterizer = rasterizer
        self.windowContentRenderer = WindowContentRenderer(device: device, fontManager: fontManager, rasterizer: rasterizer)

        let linePixelHeight = Int(ceil(CGFloat(fontManager.cellHeight) * fontManager.scale))
        self.atlas = LineTextureAtlas(device: device, slotHeight: linePixelHeight)
    }

    /// Render the editor from FrameState metadata + semantic window content.
    ///
    /// Buffer windows with semantic content (from 0x80 opcode) are rendered
    /// via `WindowContentRenderer`. Frame metadata (cursor, gutter, cursorline,
    /// default bg) comes from FrameState. Content comes from WindowContentRenderer
    /// via the gui_window_content (0x80) semantic rendering pipeline.
    func render(frameState: FrameState, fontManager: FontManager,
                cursorBlinkVisible: Bool = true,
                windowContents: [UInt16: GUIWindowContent] = [:],
                themeColors: ThemeColors? = nil,
                isMouseInGutter: Bool = false,
                gutterHoverWindowId: UInt16? = nil,
                gutterHoverRow: UInt16? = nil,
                drawable: CAMetalDrawable, viewportSize: CGSize,
                contentScale: Float, scrollOffset: SIMD2<Float> = .zero,
                scrollTargetWindowId: UInt16? = nil) {

        frameMetrics.reset()
        let renderSignpostID = OSSignpostID(log: renderLog)
        os_signpost(.begin, log: renderLog, name: "Frame", signpostID: renderSignpostID)
        defer {
            os_signpost(.end, log: renderLog, name: "Frame", signpostID: renderSignpostID,
                        "buffer_rows_rasterized=%{public}d buffer_rows_reused=%{public}d other_textures_rasterized=%{public}d other_textures_reused=%{public}d texture_uploads=%{public}d texture_upload_bytes=%{public}d atlas_new_keys=%{public}d atlas_hash_changes=%{public}d atlas_evictions=%{public}d",
                        frameMetrics.bufferRowsRasterized, frameMetrics.bufferRowsReused,
                        frameMetrics.otherTexturesRasterized, frameMetrics.otherTexturesReused,
                        frameMetrics.textureUploads, frameMetrics.textureUploadBytes,
                        frameMetrics.atlasNewKeys, frameMetrics.atlasHashChanges, frameMetrics.atlasEvictions)
        }

        // Store theme colors reference for helper methods.
        self.currentThemeColors = themeColors

        let cellW = Float(fontManager.cellWidth)
        let cellH = Float(fontManager.cellHeight)
        let scale = contentScale
        // Display cell height includes line spacing. Use for all row Y positioning
        // and quad heights. The original cellH is used for text texture sizing only.
        let displayCellH = cellH * frameState.lineSpacing
        let smoothScrollOffsetPx = SIMD2<Float>(scrollOffset.x * scale, scrollOffset.y * scale)

        // Advance semantic content renderer.
        if let wcr = windowContentRenderer {
            wcr.beginFrame()
            wcr.updateViewportWidth(cols: frameState.cols)
            if let tc = themeColors {
                wcr.defaultFgRGB = tc.editorFgRGB
            }
        }

        // Ensure atlas can hold all lines (content + gutter + semantic).
        if let atlas {
            let neededSlots = CoreTextMetalRenderer.atlasSlotDemand(frameState: frameState, windowContents: windowContents)
            let atlasPixelWidth = Int(ceil(CGFloat(frameState.cols) * CGFloat(cellW) * CGFloat(scale)))
            atlas.ensureCapacity(maxSlots: neededSlots, width: atlasPixelWidth)
            atlas.beginFrame()

            Self.invalidateFullRefreshWindows(in: atlas, windowContents: windowContents)

            if neededSlots > maxInstanceSlots {
                maxInstanceSlots = neededSlots
                instanceBuffer = device.makeBuffer(
                    length: neededSlots * MemoryLayout<LineGPU>.stride,
                    options: .storageModeShared
                )
            }
        }

        // Default background color.
        let defaultBg = frameState.defaultBg != 0
            ? colorFromU24(frameState.defaultBg, default: SIMD3<Float>(0.12, 0.12, 0.14))
            : SIMD3<Float>(0.12, 0.12, 0.14)

        // Update clear color dynamically when the theme's default bg changes.
        if frameState.defaultBg != cachedDefaultBg {
            cachedDefaultBg = frameState.defaultBg
            if frameState.defaultBg != 0 {
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

        // Gutter spacing: left margin for breathing room, right padding before separator.
        // The sign column is always reserved (2 cell widths) for consistent layout.
        let gutterLeftMarginPt: Float = frameState.gutterCol > 0 ? round(Float(Self.gutterLeftMarginPt) * scale) / scale : 0
        let gutterLeftMarginPx = gutterLeftMarginPt * scale
        let gutterPaddingPt: Float = frameState.gutterCol > 0 ? round(Float(Self.gutterRightGapPt) * scale) / scale : 0
        let gutterPaddingPx = gutterPaddingPt * scale

        let resolvedCursor = CoreTextMetalRenderer.resolveCursor(
            frameState: frameState,
            windowContents: windowContents,
            cellW: cellW,
            displayCellH: displayCellH,
            scale: scale,
            gutterLeftMarginPx: gutterLeftMarginPx,
            gutterPaddingPx: gutterPaddingPx
        )
        let renderCursor = animatedCursor(for: resolvedCursor, teleportLineThresholdPx: displayCellH * scale * 50.0)

        // Build background quads and line texture instances.
        var bgQuads: [QuadGPU] = []
        var lineInstances: [LineGPU] = []

        // Semantic window content rendering (from 0x80 opcode).
        // Buffer windows with semantic content rendered via WindowContentRenderer;
        // their line textures come from WindowContentRenderer instead.
        // Selection, search, and diagnostic overlays are drawn as Metal quads.
        var semanticOverlayQuads: [QuadGPU] = []
        var diagnosticQuads: [QuadGPU] = []

        if let wcr = windowContentRenderer {
            for (_, content) in windowContents {
                // Match gutter data to semantic window content by windowId.
                guard let gutter = frameState.windowGutters[content.windowId] else {
                    continue
                }

                let paneGeometry = content.paneGeometry
                let windowScrollOffsetPx = CoreTextMetalRenderer.smoothScrollOffset(
                    for: content.windowId,
                    targetWindowId: scrollTargetWindowId,
                    scrollOffsetPx: smoothScrollOffsetPx
                )
                let windowRowOffset = Float(paneGeometry?.textRect.row ?? gutter.contentRow) * displayCellH * scale
                let scrollableWindowRowOffset = windowRowOffset - windowScrollOffsetPx.y
                let fallbackTextCol = UInt16(Int(gutter.contentCol) + Int(gutter.lineNumberWidth) + Int(gutter.signColWidth))
                let textCol = Float(paneGeometry?.textRect.col ?? fallbackTextCol)
                let contentColOffset = textCol * cellW * scale + gutterLeftMarginPx + gutterPaddingPx
                let windowBounds = CoreTextMetalRenderer.windowHorizontalBounds(
                    geometry: paneGeometry,
                    gutter: gutter,
                    frameCols: frameState.cols,
                    cellW: cellW,
                    scale: scale,
                    viewportWidth: Float(viewportSize.width)
                )
                let contentRightPx = windowBounds.x + windowBounds.width

                if let cursorline = content.cursorline, cursorline.bg != 0 {
                    let yPos = scrollableWindowRowOffset + Float(cursorline.row) * displayCellH * scale
                    var clQuad = QuadGPU()
                    clQuad.position = SIMD2<Float>(windowBounds.x, yPos)
                    clQuad.size = SIMD2<Float>(windowBounds.width, displayCellH * scale)
                    clQuad.color = colorFromU24(cursorline.bg, default: defaultBg)
                    clQuad.alpha = 1.0
                    bgQuads.append(clQuad)
                }

                // Horizontal scroll: shift line textures and overlays left by scrollLeft columns.
                // The gutter stays fixed; only content past the gutter edge scrolls.
                let scrollLeftInt = Int(content.scrollLeft)
                let hScrollPx = Float(scrollLeftInt) * cellW * scale
                let contentCols = CoreTextMetalRenderer.visibleTextCols(
                    geometry: paneGeometry,
                    gutter: gutter,
                    frameCols: frameState.cols,
                    cellW: cellW,
                    scale: scale,
                    gutterLeftMarginPx: gutterLeftMarginPx,
                    gutterPaddingPx: gutterPaddingPx
                )

                // Selection overlay quads (drawn before text).
                if let sel = content.selection {
                    appendSelectionQuads(
                        selection: sel,
                        rowOffset: scrollableWindowRowOffset,
                        colOffset: contentColOffset,
                        scrollLeft: scrollLeftInt,
                        visibleRows: content.rows.count,
                        visibleCols: contentCols,
                        cellW: cellW, cellH: displayCellH, scale: scale,
                        viewportWidth: contentRightPx,
                        quads: &semanticOverlayQuads
                    )
                }

                // Document highlight overlay quads (drawn before search matches,
                // so search matches paint over them when they overlap).
                for highlight in content.documentHighlights {
                    guard highlight.endCol > highlight.startCol else { continue }
                    // Document highlights are typically single-line (one identifier).
                    // Draw on startRow only; multi-row highlights are rare for this feature.
                    let hlY = scrollableWindowRowOffset + Float(highlight.startRow) * displayCellH * scale
                    let rawHlX = contentColOffset + Float(highlight.startCol) * cellW * scale - hScrollPx
                    let rawHlRight = rawHlX + Float(highlight.endCol - highlight.startCol) * cellW * scale
                    let hlX = max(rawHlX, contentColOffset)
                    let hlRight = min(rawHlRight, contentRightPx)
                    guard hlRight > hlX else { continue }

                    var quad = QuadGPU()
                    quad.position = SIMD2<Float>(hlX, hlY)
                    quad.size = SIMD2<Float>(hlRight - hlX, displayCellH * scale)
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
                    guard match.endCol > match.startCol else { continue }
                    let matchY = scrollableWindowRowOffset + Float(match.row) * displayCellH * scale
                    let rawMatchX = contentColOffset + Float(match.startCol) * cellW * scale - hScrollPx
                    let rawMatchRight = rawMatchX + Float(match.endCol - match.startCol) * cellW * scale
                    let matchX = max(rawMatchX, contentColOffset)
                    let matchRight = min(rawMatchRight, contentRightPx)
                    guard matchRight > matchX else { continue }

                    var quad = QuadGPU()
                    quad.position = SIMD2<Float>(matchX, matchY)
                    quad.size = SIMD2<Float>(matchRight - matchX, displayCellH * scale)
                    quad.color = match.isCurrent
                        ? SIMD3<Float>(0.95, 0.75, 0.0)    // current match: gold
                        : SIMD3<Float>(0.35, 0.35, 0.15)   // other matches: dim gold
                    quad.alpha = 1.0
                    semanticOverlayQuads.append(quad)
                }

                // Pre-clip all rows to the visible viewport window.
                // Drops scrollLeft columns from the start and limits to viewport width,
                // so each texture is at most viewport-wide. Fixes gutter bleedthrough
                // (no leftward position shift) and text truncation (texture always
                // covers the visible portion).
                var clippedRows: [GUIVisualRow] = []
                clippedRows.reserveCapacity(content.rows.count)
                for row in content.rows {
                    clippedRows.append(
                        wcr.clipRowToViewport(row, scrollLeft: scrollLeftInt, viewportCols: contentCols)
                    )
                }

                // Render pre-clipped line textures into atlas.
                var rowEntriesByRow: [UInt16: AtlasEntry] = [:]
                for (rowIdx, clippedRow) in clippedRows.enumerated() {
                    let displayRow = UInt16(rowIdx)
                    if let atlas, let entry = wcr.renderRowToAtlas(displayRow: displayRow, row: clippedRow, windowId: content.windowId, contentEpoch: content.contentEpoch, atlas: atlas, metrics: &frameMetrics) {
                        rowEntriesByRow[displayRow] = entry
                        let yPos = scrollableWindowRowOffset + Float(rowIdx) * displayCellH * scale
                        let textYOffset = (displayCellH - cellH) * scale * 0.5

                        let (uvOrigin, uvSize) = atlas.uvForSlot(entry.slotIndex, pixelWidth: entry.pixelWidth)
                        var lineGPU = LineGPU()
                        lineGPU.position = SIMD2<Float>(contentColOffset, yPos + textYOffset)
                        lineGPU.size = SIMD2<Float>(Float(entry.pixelWidth), Float(entry.pixelHeight))
                        lineGPU.uvOrigin = uvOrigin
                        lineGPU.uvSize = uvSize
                        lineInstances.append(lineGPU)
                    }
                }

                // Line annotation pills/text (drawn after line content).
                if !content.lineAnnotations.isEmpty, let atlas {
                    var annotationsByRow: [UInt16: [GUILineAnnotation]] = [:]
                    for ann in content.lineAnnotations {
                        annotationsByRow[ann.row, default: []].append(ann)
                    }

                    for (rowIndex, rowAnnotations) in annotationsByRow {
                        let linePixelWidth = Float(rowEntriesByRow[rowIndex]?.pixelWidth ?? 0)
                        let rowY = scrollableWindowRowOffset + Float(rowIndex) * displayCellH * scale
                        var cursorX = contentColOffset + linePixelWidth
                            + Float(wcr.annotationGap) * scale

                        for (annIdx, ann) in rowAnnotations.enumerated() {
                            let annKey = AtlasKey.lineAnnotation(windowId: content.windowId, row: rowIndex, subIndex: UInt16(min(annIdx, Int(UInt16.max))))

                            guard let annEntry = wcr.renderAnnotationToAtlas(
                                annotation: ann, key: annKey, atlas: atlas, metrics: &frameMetrics
                            ) else { continue }

                            let (uvOrigin, uvSize) = atlas.uvForSlot(annEntry.slotIndex, pixelWidth: annEntry.pixelWidth)
                            let visiblePixelWidth = min(Float(annEntry.pixelWidth), contentRightPx - cursorX)
                            guard visiblePixelWidth > 0 else { continue }
                            let visibleUVWidth = uvSize.x * visiblePixelWidth / Float(annEntry.pixelWidth)

                            var lineGPU = LineGPU()
                            lineGPU.position = SIMD2<Float>(cursorX, rowY)
                            lineGPU.size = SIMD2<Float>(visiblePixelWidth, Float(annEntry.pixelHeight))
                            lineGPU.uvOrigin = uvOrigin
                            lineGPU.uvSize = SIMD2<Float>(visibleUVWidth, uvSize.y)
                            lineInstances.append(lineGPU)

                            cursorX += Float(annEntry.pixelWidth) + Float(wcr.annotationSpacing) * scale
                        }
                    }
                }

                // Diagnostic underline quads (drawn after text).
                for diag in content.diagnosticUnderlines {
                    guard diag.endCol > diag.startCol else { continue }
                    let diagColor: SIMD3<Float> = switch diag.severity {
                    case .error:   SIMD3<Float>(1.0, 0.42, 0.42)   // red
                    case .warning: SIMD3<Float>(0.93, 0.75, 0.48)  // yellow
                    case .info:    SIMD3<Float>(0.32, 0.69, 0.94)  // blue
                    case .hint:    SIMD3<Float>(0.33, 0.33, 0.33)  // gray
                    }

                    let diagY = scrollableWindowRowOffset + Float(diag.startRow) * displayCellH * scale + displayCellH * scale - 2.0 * scale
                    let rawDiagX = contentColOffset + Float(diag.startCol) * cellW * scale - hScrollPx
                    let rawDiagRight = rawDiagX + Float(diag.endCol - diag.startCol) * cellW * scale
                    let diagX = max(rawDiagX, contentColOffset)
                    let diagRight = min(rawDiagRight, contentRightPx)
                    guard diagRight > diagX else { continue }

                    var quad = QuadGPU()
                    quad.position = SIMD2<Float>(diagX, diagY)
                    quad.size = SIMD2<Float>(diagRight - diagX, 2.0 * scale)
                    quad.color = diagColor
                    quad.alpha = 1.0
                    diagnosticQuads.append(quad)
                }
            }
        }

        // Native gutter rendering from structured data.
        // One Wire.WindowGutter per editor window (split pane).
        for (_, windowGutter) in frameState.windowGutters {
            renderGutterEntries(
                gutter: windowGutter,
                frameState: frameState,
                cellW: cellW, cellH: displayCellH, scale: scale,
                gutterLeftMarginPx: gutterLeftMarginPx,
                gutterPaddingPx: gutterPaddingPx,
                viewportWidthPx: Float(viewportSize.width),
                isMouseInGutter: isMouseInGutter,
                gutterHoverWindowId: gutterHoverWindowId,
                gutterHoverRow: gutterHoverRow,
                scrollOffsetY: CoreTextMetalRenderer.smoothScrollOffset(
                    for: windowGutter.windowId,
                    targetWindowId: scrollTargetWindowId,
                    scrollOffsetPx: smoothScrollOffsetPx
                ).y,
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

        // Keep shader uniforms fixed. Smooth-scroll deltas are baked only into scrollable buffer content and cursor positions above, so fixed chrome such as gutters, split separators, labels, and scroll indicators does not drift during fractional scroll frames.
        var uniforms = CTUniformsGPU(
            viewportSize: SIMD2<Float>(Float(viewportSize.width), Float(viewportSize.height)),
            scrollOffset: .zero
        )

        // Default fragment params: no corner radius (sharp rectangles).
        // The cursor draw call overrides this with a nonzero radius.
        var defaultBgParams = BgParamsGPU(cornerRadius: 0.0)
        encoder.setFragmentBytes(&defaultBgParams, length: MemoryLayout<BgParamsGPU>.size, index: 0)

        // Pass 1: Background fills.
        if !bgQuads.isEmpty {
            encoder.setRenderPipelineState(bgPipeline)
            drawQuadBatches(bgQuads, encoder: encoder, uniforms: &uniforms)
        }

        // Pass 1.25: Indent guides (vertical lines at indentation levels).
        // Drawn after bg fills but before text, cursor, and selection overlays.
        // When per-line indent levels are available, draw segments only in
        // leading whitespace so guides don't bleed through text content.
        for (_, guideData) in frameState.windowIndentGuides {
            guard !guideData.guideCols.isEmpty else { continue }

            guard let gutter = frameState.windowGutters[guideData.windowId] else { continue }
            let paneGeometry = windowContents[guideData.windowId]?.paneGeometry
            let fallbackTextCol = UInt16(Int(gutter.contentCol) + Int(gutter.lineNumberWidth) + Int(gutter.signColWidth))
            let windowContentColOffset = Float(paneGeometry?.textRect.col ?? fallbackTextCol) * cellW * scale + gutterLeftMarginPx + gutterPaddingPx
            let windowBounds = CoreTextMetalRenderer.windowHorizontalBounds(
                geometry: paneGeometry,
                gutter: gutter,
                frameCols: frameState.cols,
                cellW: cellW,
                scale: scale,
                viewportWidth: Float(viewportSize.width)
            )
            let contentRightPx = windowBounds.x + windowBounds.width
            let guideScrollOffsetY = CoreTextMetalRenderer.smoothScrollOffset(
                for: guideData.windowId,
                targetWindowId: scrollTargetWindowId,
                scrollOffsetPx: smoothScrollOffsetPx
            ).y
            let contentTopY = Float(gutter.contentRow) * displayCellH * scale - guideScrollOffsetY
            let lineCellH = displayCellH * scale

            let inactiveFg = colorFromU24(frameState.gutterColors.fg, default: SIMD3<Float>(0.33, 0.33, 0.33))
            let tabW = max(UInt16(guideData.tabWidth), 1)

            var guideQuads: [QuadGPU] = []

            if guideData.lineIndentLevels.isEmpty {
                let contentHeightPx = Float(gutter.contentHeight) * displayCellH * scale
                guideQuads.reserveCapacity(guideData.guideCols.count)
                for col in guideData.guideCols {
                    let guideX = windowContentColOffset + Float(col) * cellW * scale
                    let guideWidth = min(1.0 * scale, contentRightPx - guideX)
                    guard guideWidth > 0 else { continue }
                    let isActive = col == guideData.activeGuideCol
                    var quad = QuadGPU()
                    quad.position = SIMD2<Float>(guideX, contentTopY)
                    quad.size = SIMD2<Float>(guideWidth, contentHeightPx)
                    quad.color = inactiveFg
                    quad.alpha = isActive ? 0.4 : 0.15
                    guideQuads.append(quad)
                }
            } else {
                guideQuads.reserveCapacity(guideData.guideCols.count * guideData.lineIndentLevels.count)
                for (lineIdx, level) in guideData.lineIndentLevels.enumerated() {
                    let lineY = contentTopY + Float(lineIdx) * lineCellH
                    for col in guideData.guideCols {
                        let guideLevel = col / tabW
                        // Strict < so guides appear only in whitespace, not at the text-start column.
                        guard guideLevel < level else { continue }
                        let guideX = windowContentColOffset + Float(col) * cellW * scale
                        let guideWidth = min(1.0 * scale, contentRightPx - guideX)
                        guard guideWidth > 0 else { continue }
                        let isActive = col == guideData.activeGuideCol
                        var quad = QuadGPU()
                        quad.position = SIMD2<Float>(guideX, lineY)
                        quad.size = SIMD2<Float>(guideWidth, lineCellH)
                        quad.color = inactiveFg
                        quad.alpha = isActive ? 0.4 : 0.15
                        guideQuads.append(quad)
                    }
                }
            }

            if !guideQuads.isEmpty {
                encoder.setRenderPipelineState(bgPipeline)
                // setVertexBytes is capped at 4 KB of inline data by Metal.
                let maxPerBatch = 4096 / MemoryLayout<QuadGPU>.stride
                var batchStart = 0
                while batchStart < guideQuads.count {
                    let batchCount = min(guideQuads.count - batchStart, maxPerBatch)
                    guideQuads.withUnsafeMutableBufferPointer { ptr in
                        let base = ptr.baseAddress! + batchStart
                        encoder.setVertexBytes(base, length: batchCount * MemoryLayout<QuadGPU>.stride, index: 0)
                    }
                    encoder.setVertexBytes(&uniforms, length: MemoryLayout<CTUniformsGPU>.size, index: 1)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: batchCount)
                    batchStart += batchCount
                }
            }
        }

        // Pass 1.5: Semantic overlay quads (search matches, selection).
        // Drawn after bg fills but before cursor and text so they appear
        // behind text content. Selection and search highlights render as
        // Metal quads instead of being baked into line textures.
        if !semanticOverlayQuads.isEmpty {
            encoder.setRenderPipelineState(bgPipeline)
            drawQuadBatches(semanticOverlayQuads, encoder: encoder, uniforms: &uniforms)
        }

        // Pass 2: Cursor background (drawn BEFORE text so text is visible on top).
        // For block cursors, draw the cursor bg here so the text pass composites over it.
        // Beam and underline cursors are drawn AFTER text (pass 5).
        if let renderCursor, cursorBlinkVisible, renderCursor.shape == .block {
            let cursorScrollOffsetPx = CoreTextMetalRenderer.smoothScrollOffset(
                for: renderCursor.windowId,
                targetWindowId: scrollTargetWindowId,
                scrollOffsetPx: smoothScrollOffsetPx
            )
            let cursorX = renderCursor.x - cursorScrollOffsetPx.x
            let cursorY = renderCursor.y - cursorScrollOffsetPx.y
            var cursorQuad = QuadGPU()
            cursorQuad.position = SIMD2<Float>(CoreTextMetalRenderer.snapToPixel(cursorX), CoreTextMetalRenderer.snapToPixel(cursorY))
            cursorQuad.size = SIMD2<Float>(CoreTextMetalRenderer.snapToPixel(cellW * scale), CoreTextMetalRenderer.snapToPixel(displayCellH * scale))
            cursorQuad.color = cursorColor
            cursorQuad.alpha = 1.0

            var cursorBgParams = BgParamsGPU(cornerRadius: 0.0)
            encoder.setRenderPipelineState(bgPipeline)
            encoder.setVertexBytes(&cursorQuad, length: MemoryLayout<QuadGPU>.stride, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<CTUniformsGPU>.size, index: 1)
            encoder.setFragmentBytes(&cursorBgParams, length: MemoryLayout<BgParamsGPU>.size, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)

            // Restore default (no rounding) for subsequent draws.
            encoder.setFragmentBytes(&defaultBgParams, length: MemoryLayout<BgParamsGPU>.size, index: 0)
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
            drawQuadBatches(diagnosticQuads, encoder: encoder, uniforms: &uniforms)
        }

        // Pass 4: Gutter gap fills (left margin + right padding).
        let totalGutterExtraPx = gutterLeftMarginPx + gutterPaddingPx
        if frameState.gutterCol > 0 && totalGutterExtraPx > 0 {
            // Left margin fill: from window edge to the start of gutter content.
            if gutterLeftMarginPx > 0 {
                var leftFill = QuadGPU()
                leftFill.position = SIMD2<Float>(0, 0)
                leftFill.size = SIMD2<Float>(gutterLeftMarginPx, Float(viewportSize.height))
                leftFill.color = defaultBg
                leftFill.alpha = 1.0
                encoder.setRenderPipelineState(bgPipeline)
                encoder.setVertexBytes(&leftFill, length: MemoryLayout<QuadGPU>.stride, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<CTUniformsGPU>.size, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
            }

            // Right padding fill: between gutter columns and content separator.
            var rightFill = QuadGPU()
            rightFill.position = SIMD2<Float>(Float(frameState.gutterCol) * cellW * scale + gutterLeftMarginPx, 0)
            rightFill.size = SIMD2<Float>(gutterPaddingPx, Float(viewportSize.height))
            rightFill.color = defaultBg
            rightFill.alpha = 1.0
            encoder.setRenderPipelineState(bgPipeline)
            encoder.setVertexBytes(&rightFill, length: MemoryLayout<QuadGPU>.stride, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<CTUniformsGPU>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
        }

        // Pass 5: Gutter separator line.
        if frameState.gutterCol > 0 && frameState.gutterSeparatorColor != 0 {
            var sepQuad = QuadGPU()
            let sepX = (Float(frameState.gutterCol) * cellW + gutterLeftMarginPt + gutterPaddingPt) * scale - 1.0
            sepQuad.position = SIMD2<Float>(sepX, 0)
            sepQuad.size = SIMD2<Float>(1.0, Float(viewportSize.height))
            sepQuad.color = colorFromU24(frameState.gutterSeparatorColor, default: SIMD3<Float>(0.3, 0.3, 0.3))
            sepQuad.alpha = 1.0

            encoder.setRenderPipelineState(bgPipeline)
            encoder.setVertexBytes(&sepQuad, length: MemoryLayout<QuadGPU>.stride, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<CTUniformsGPU>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
        }

        // Pass 5.5: Split separators (vertical lines between split panes,
        // horizontal bars with centered filenames for horizontal splits).
        if frameState.splitBorderColor != 0 {
            let sepColor = colorFromU24(frameState.splitBorderColor, default: SIMD3<Float>(0.3, 0.3, 0.3))

            // Vertical separators: 1px-wide lines spanning startRow..endRow
            for vert in frameState.verticalSeparators {
                let sepX = Float(vert.col) * cellW * scale
                let sepY = Float(vert.startRow) * displayCellH * scale
                let sepH = Float(vert.endRow &- vert.startRow &+ 1) * displayCellH * scale

                var vertQuad = QuadGPU()
                vertQuad.position = SIMD2<Float>(sepX, sepY)
                vertQuad.size = SIMD2<Float>(1.0, sepH)
                vertQuad.color = sepColor
                vertQuad.alpha = 1.0

                encoder.setRenderPipelineState(bgPipeline)
                encoder.setVertexBytes(&vertQuad, length: MemoryLayout<QuadGPU>.stride, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<CTUniformsGPU>.size, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
            }

            // Horizontal separators: 1px-high line + centered filename label
            for (separatorIndex, horiz) in frameState.horizontalSeparators.enumerated() {
                let hY = Float(horiz.row) * displayCellH * scale + (displayCellH * scale * 0.5) - 0.5
                let hX = Float(horiz.col) * cellW * scale
                let hW = Float(horiz.width) * cellW * scale

                // Background line spanning the full width
                var horizQuad = QuadGPU()
                horizQuad.position = SIMD2<Float>(hX, hY)
                horizQuad.size = SIMD2<Float>(hW, 1.0)
                horizQuad.color = sepColor
                horizQuad.alpha = 1.0

                encoder.setRenderPipelineState(bgPipeline)
                encoder.setVertexBytes(&horizQuad, length: MemoryLayout<QuadGPU>.stride, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<CTUniformsGPU>.size, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)

                // Centered filename label rendered as a CoreText texture
                if !horiz.filename.isEmpty, let atlas = atlas, let wcr = windowContentRenderer {
                    let labelHash = horiz.filename.hashValue ^ Int(frameState.splitBorderColor)
                    let labelKey = AtlasKey.splitLabel(row: horiz.row, subIndex: UInt16(min(separatorIndex, Int(UInt16.max))))
                    if let entry = wcr.renderSimpleText(horiz.filename, fg: frameState.splitBorderColor,
                                                         key: labelKey, contentHash: labelHash, atlas: atlas, metrics: &frameMetrics) {
                        // Center the label text within the separator width
                        let labelW = Float(entry.pixelWidth)
                        let centerX = hX + (hW - labelW) * 0.5
                        let labelY = Float(horiz.row) * displayCellH * scale

                        // Small bg fill behind label so it "breaks" the horizontal line
                        let padPx: Float = 4.0 * scale
                        var labelBg = QuadGPU()
                        labelBg.position = SIMD2<Float>(centerX - padPx, hY - 1)
                        labelBg.size = SIMD2<Float>(labelW + padPx * 2, 3.0)
                        labelBg.color = defaultBg
                        labelBg.alpha = 1.0
                        encoder.setRenderPipelineState(bgPipeline)
                        encoder.setVertexBytes(&labelBg, length: MemoryLayout<QuadGPU>.stride, index: 0)
                        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CTUniformsGPU>.size, index: 1)
                        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)

                        // Render the label texture immediately. The main line texture pass has already run by the time split separators are drawn, so queuing this into lineInstances would leave only the background gap visible.
                        let (uvOrigin, uvSize) = atlas.uvForSlot(entry.slotIndex, pixelWidth: entry.pixelWidth)
                        var lineGPU = LineGPU()
                        lineGPU.position = SIMD2<Float>(centerX, labelY)
                        lineGPU.size = SIMD2<Float>(Float(entry.pixelWidth), Float(entry.pixelHeight))
                        lineGPU.uvOrigin = uvOrigin
                        lineGPU.uvSize = uvSize

                        if let atlasTexture = atlas.texture {
                            encoder.setRenderPipelineState(linePipeline)
                            encoder.setVertexBytes(&lineGPU, length: MemoryLayout<LineGPU>.stride, index: 0)
                            encoder.setVertexBytes(&uniforms, length: MemoryLayout<CTUniformsGPU>.size, index: 1)
                            encoder.setFragmentTexture(atlasTexture, index: 0)
                            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
                        }
                    }
                }
            }
        }

        // Pass 6: Cursor overlay for beam and underline shapes.
        // Block cursor is drawn in pass 2 (before text) so text shows on top.
        // Beam and underline are drawn AFTER text so they overlay it.
        if let renderCursor, cursorBlinkVisible, renderCursor.shape != .block {
            let cursorScrollOffsetPx = CoreTextMetalRenderer.smoothScrollOffset(
                for: renderCursor.windowId,
                targetWindowId: scrollTargetWindowId,
                scrollOffsetPx: smoothScrollOffsetPx
            )
            let cursorX = renderCursor.x - cursorScrollOffsetPx.x
            let cursorY = renderCursor.y - cursorScrollOffsetPx.y
            var cursorQuad = QuadGPU()
            cursorQuad.color = cursorColor
            cursorQuad.alpha = 1.0

            switch renderCursor.shape {
            case .block:
                break  // Handled in pass 2.

            case .beam:
                let beamWidth: Float = 2.0 * scale
                cursorQuad.position = SIMD2<Float>(CoreTextMetalRenderer.snapToPixel(cursorX), CoreTextMetalRenderer.snapToPixel(cursorY))
                cursorQuad.size = SIMD2<Float>(CoreTextMetalRenderer.snapToPixel(beamWidth), CoreTextMetalRenderer.snapToPixel(displayCellH * scale))

            case .underline:
                let ulHeight: Float = 2.0 * scale
                let cellBottom = cursorY + displayCellH * scale
                cursorQuad.position = SIMD2<Float>(CoreTextMetalRenderer.snapToPixel(cursorX), CoreTextMetalRenderer.snapToPixel(cellBottom - ulHeight))
                cursorQuad.size = SIMD2<Float>(CoreTextMetalRenderer.snapToPixel(cellW * scale), CoreTextMetalRenderer.snapToPixel(ulHeight))
            }

            encoder.setRenderPipelineState(bgPipeline)
            encoder.setVertexBytes(&cursorQuad, length: MemoryLayout<QuadGPU>.stride, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<CTUniformsGPU>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
        }

        // Pass 7: Scroll indicator (overlay scrollbar).
        // A thin rect on the right edge showing viewport position within the document.
        // Only shown when the document is taller than the viewport.
        let totalLines = frameState.totalLineCount
        let visibleRows = UInt32(frameState.rows)
        let viewportTop = frameState.viewportTopLine

        if totalLines > visibleRows && viewportTop != 0xFFFF_FFFF && scrollIndicatorAlpha > 0 {
            let viewportH = Float(viewportSize.height)
            let indicatorWidth: Float = 6.0 * scale
            let indicatorMargin: Float = 2.0 * scale
            let trackHeight = viewportH

            // Compute thumb size and position.
            let proportion = Float(visibleRows) / Float(totalLines)
            let thumbHeight = max(proportion * trackHeight, 20.0 * scale)
            let maxTop = Float(max(Int64(totalLines) - Int64(visibleRows), 1))
            let thumbY = (Float(viewportTop) / maxTop) * (trackHeight - thumbHeight)

            let thumbX = Float(viewportSize.width) - indicatorWidth - indicatorMargin

            var scrollQuad = QuadGPU()
            scrollQuad.position = SIMD2<Float>(thumbX, thumbY)
            scrollQuad.size = SIMD2<Float>(indicatorWidth, thumbHeight)
            // Use gutter fg color at reduced alpha for the indicator.
            scrollQuad.color = colorFromU24(frameState.scrollIndicatorColor, default: SIMD3<Float>(0.4, 0.4, 0.4))
            scrollQuad.alpha = 0.4 * scrollIndicatorAlpha

            encoder.setRenderPipelineState(bgPipeline)
            encoder.setVertexBytes(&scrollQuad, length: MemoryLayout<QuadGPU>.stride, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<CTUniformsGPU>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
        }

        if let atlas {
            frameMetrics.textureUploads = atlas.frameTextureUploads
            frameMetrics.textureUploadBytes = atlas.frameTextureUploadBytes
        }

        encoder.endEncoding()
        cmdBuf.present(drawable)
        let commitTime = CACurrentMediaTime()
        cmdBuf.addCompletedHandler { completedBuffer in
            let completionLatencyMs = (CACurrentMediaTime() - commitTime) * 1000.0
            let gpuStart = completedBuffer.gpuStartTime
            let gpuEnd = completedBuffer.gpuEndTime

            if gpuStart > 0, gpuEnd > gpuStart {
                os_signpost(.event, log: renderLog, name: "GPU Timing", signpostID: renderSignpostID, "gpu_ms=%{public}.3f commit_to_complete_ms=%{public}.3f", (gpuEnd - gpuStart) * 1000.0, completionLatencyMs)
            } else {
                os_signpost(.event, log: renderLog, name: "GPU Timing", signpostID: renderSignpostID, "gpu_ms=%{public}.3f commit_to_complete_ms=%{public}.3f", 0.0, completionLatencyMs)
            }
        }
        cmdBuf.commit()
    }

    // MARK: - Native Gutter Rendering

    /// Renders line numbers and signs natively from structured gutter data.
    ///
    /// Line numbers are rendered as CTLine textures through the existing
    /// WindowContentRenderer. Git signs are drawn as colored Metal quads.
    /// Diagnostic signs are rendered as CTLine textures.
    private func renderGutterEntries(
        gutter: Wire.WindowGutter,
        frameState: FrameState,
        cellW: Float, cellH: Float, scale: Float,
        gutterLeftMarginPx: Float,
        gutterPaddingPx: Float,
        viewportWidthPx: Float,
        isMouseInGutter: Bool,
        gutterHoverWindowId: UInt16?,
        gutterHoverRow: UInt16?,
        scrollOffsetY: Float,
        bgQuads: inout [QuadGPU],
        lineInstances: inout [LineGPU]
    ) {
        let signColWidth = Int(gutter.signColWidth)
        let baseRow = gutter.contentRow
        let baseCol = gutter.contentCol

        for (rowIndex, entry) in gutter.entries.enumerated() {
            let screenRow = baseRow + UInt16(rowIndex)
            let yPos = Float(screenRow) * cellH * scale - scrollOffsetY
            let xOffset = Float(baseCol) * cellW * scale + gutterLeftMarginPx

            // Sign column (leftmost in gutter)
            if signColWidth > 0 {
                renderGutterSign(
                    entry: entry, windowId: gutter.windowId, screenRow: screenRow, yPos: yPos, xOffset: xOffset,
                    cellW: cellW, cellH: cellH, scale: scale,
                    frameState: frameState,
                    bgQuads: &bgQuads, lineInstances: &lineInstances,
                )
            }

            // Fold indicator (dedicated cell after the diagnostic/git sign column)
            if signColWidth >= 3 {
                appendFoldRangeHighlight(
                    entry: entry, rowIndex: rowIndex, screenRow: screenRow, yPos: yPos,
                    gutter: gutter, xOffset: xOffset,
                    signColWidth: signColWidth,
                    cellW: cellW, cellH: cellH, scale: scale,
                    gutterPaddingPx: gutterPaddingPx,
                    viewportWidthPx: viewportWidthPx,
                    gutterHoverWindowId: gutterHoverWindowId,
                    gutterHoverRow: gutterHoverRow,
                    frameState: frameState,
                    bgQuads: &bgQuads,
                )

                renderGutterFoldIndicator(
                    entry: entry, yPos: yPos, xOffset: xOffset,
                    signColWidth: signColWidth,
                    cellW: cellW, cellH: cellH, scale: scale,
                    isMouseInGutter: isMouseInGutter,
                    gutterHoverWindowId: gutterHoverWindowId,
                    gutter: gutter,
                    frameState: frameState,
                    bgQuads: &bgQuads,
                )
            }

            // Line number (after sign and fold columns)
            if gutter.lineNumberStyle != .none && gutter.lineNumberWidth > 0 && shouldRenderLineNumber(for: entry) {
                renderGutterLineNumber(
                    entry: entry, gutter: gutter,
                    screenRow: screenRow, yPos: yPos, xOffset: xOffset,
                    signColWidth: signColWidth,
                    cellW: cellW, cellH: cellH, scale: scale,
                    frameState: frameState,
                    lineInstances: &lineInstances,
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
        entry: Wire.GutterEntry, windowId: UInt16, screenRow: UInt16, yPos: Float, xOffset: Float,
        cellW: Float, cellH: Float, scale: Float,
        frameState: FrameState,
        bgQuads: inout [QuadGPU],
        lineInstances: inout [LineGPU],
    ) {
        switch entry.signType {
        case .gitAdded:
            var quad = QuadGPU()
            let gitBarWidth = round(3.0 * scale)
            quad.position = SIMD2<Float>(xOffset, yPos)
            quad.size = SIMD2<Float>(gitBarWidth, cellH * scale)
            quad.color = gutterSignColor(entry.signType, frameState: frameState)
            quad.alpha = 1.0
            bgQuads.append(quad)

        case .gitModified:
            var quad = QuadGPU()
            let gitBarWidth = round(3.0 * scale)
            quad.position = SIMD2<Float>(xOffset, yPos)
            quad.size = SIMD2<Float>(gitBarWidth, cellH * scale)
            quad.color = gutterSignColor(entry.signType, frameState: frameState)
            quad.alpha = 1.0
            bgQuads.append(quad)

        case .gitDeleted:
            var quad = QuadGPU()
            let barHeight = round(2.0 * scale)
            quad.position = SIMD2<Float>(xOffset, yPos + cellH * scale - barHeight)
            quad.size = SIMD2<Float>(cellW * 2 * scale, barHeight)
            quad.color = gutterSignColor(entry.signType, frameState: frameState)
            quad.alpha = 1.0
            bgQuads.append(quad)

        case .gitRemoved, .diagError, .diagWarning, .diagInfo, .diagHint:
            let (text, fg) = gutterTextSignAndColor(entry.signType, frameState: frameState)
            let cacheKey = AtlasKey.diagnosticSign(windowId: windowId, row: screenRow)
            let contentHash = gutterContentHash(text: text, fg: fg)
            if let atlas, let wcr = windowContentRenderer,
               let entry = wcr.renderSimpleText(text, fg: fg, bold: true,
                                                 key: cacheKey, contentHash: contentHash, atlas: atlas, metrics: &frameMetrics) {
                let (uvOrigin, uvSize) = atlas.uvForSlot(entry.slotIndex, pixelWidth: entry.pixelWidth)
                var lineGPU = LineGPU()
                lineGPU.position = SIMD2<Float>(xOffset, yPos)
                lineGPU.size = SIMD2<Float>(Float(entry.pixelWidth), Float(entry.pixelHeight))
                lineGPU.uvOrigin = uvOrigin
                lineGPU.uvSize = uvSize
                lineInstances.append(lineGPU)
            }

        case .annotation:
            // Render annotation icon text with the annotation's custom fg color.
            let text = entry.signText.isEmpty ? "●" : entry.signText
            let fg = entry.signFg
            let cacheKey = AtlasKey.annotationIcon(windowId: windowId, row: screenRow)
            let contentHash = gutterContentHash(text: text, fg: fg)
            if let atlas, let wcr = windowContentRenderer,
               let atlasEntry = wcr.renderSimpleText(text, fg: fg, bold: false,
                                                      key: cacheKey, contentHash: contentHash, atlas: atlas, metrics: &frameMetrics) {
                let (uvOrigin, uvSize) = atlas.uvForSlot(atlasEntry.slotIndex, pixelWidth: atlasEntry.pixelWidth)
                var lineGPU = LineGPU()
                lineGPU.position = SIMD2<Float>(xOffset, yPos)
                lineGPU.size = SIMD2<Float>(Float(atlasEntry.pixelWidth), Float(atlasEntry.pixelHeight))
                lineGPU.uvOrigin = uvOrigin
                lineGPU.uvSize = uvSize
                lineInstances.append(lineGPU)
            }

        case .none:
            break
        }
    }

    /// Draws a subtle range highlight while hovering an unfolded fold chevron.
    private func appendFoldRangeHighlight(
        entry: Wire.GutterEntry, rowIndex: Int, screenRow: UInt16, yPos: Float,
        gutter: Wire.WindowGutter, xOffset: Float,
        signColWidth: Int,
        cellW: Float, cellH: Float, scale: Float,
        gutterPaddingPx: Float,
        viewportWidthPx: Float,
        gutterHoverWindowId: UInt16?,
        gutterHoverRow: UInt16?,
        frameState: FrameState,
        bgQuads: inout [QuadGPU],
    ) {
        guard gutterHoverWindowId == gutter.windowId else { return }
        guard gutterHoverRow == screenRow else { return }
        guard entry.displayType == .foldOpen else { return }
        guard let foldEndLine = entry.foldEndLine, foldEndLine > entry.bufLine else { return }

        let rowsInRange = Int(foldEndLine - entry.bufLine + 1)
        let visibleRows = max(0, min(rowsInRange, Int(gutter.contentHeight) - rowIndex))
        guard visibleRows > 0 else { return }

        let gutterWidth = Float(gutter.lineNumberWidth) + Float(signColWidth)
        let contentX = xOffset + gutterWidth * cellW * scale + gutterPaddingPx
        let windowRightX = (Float(gutter.contentCol) + Float(gutter.contentWidth)) * cellW * scale
        let width = max(0, min(windowRightX, viewportWidthPx) - contentX)
        guard width > 0 else { return }

        var quad = QuadGPU()
        quad.position = SIMD2<Float>(contentX, yPos)
        quad.size = SIMD2<Float>(width, Float(visibleRows) * cellH * scale)
        quad.color = colorFromU24(frameState.gutterColors.foldFg, default: SIMD3<Float>(0.33, 0.33, 0.33))
        quad.alpha = 0.10
        bgQuads.append(quad)
    }

    /// Renders the fold indicator for one gutter row as a path-style chevron.
    private func renderGutterFoldIndicator(
        entry: Wire.GutterEntry, yPos: Float, xOffset: Float,
        signColWidth: Int,
        cellW: Float, cellH: Float, scale: Float,
        isMouseInGutter: Bool,
        gutterHoverWindowId: UInt16?,
        gutter: Wire.WindowGutter,
        frameState: FrameState,
        bgQuads: inout [QuadGPU],
    ) {
        let collapsed: Bool
        switch entry.displayType {
        case .foldStart:
            collapsed = true
        case .foldOpen:
            guard isMouseInGutter && gutterHoverWindowId == gutter.windowId else { return }
            collapsed = false
        case .normal, .foldContinuation, .wrapContinuation, .blank:
            return
        }

        let foldColumnOffset = signColWidth - 1
        let cellX = xOffset + Float(foldColumnOffset) * cellW * scale
        let centerX = cellX + cellW * scale * 0.5
        let centerY = yPos + cellH * scale * 0.5
        let size = cellH * scale * 0.42
        let half = size * 0.5
        let color = colorFromU24(frameState.gutterColors.foldFg, default: SIMD3<Float>(0.33, 0.33, 0.33))
        let lineWidth = max(1.0, round(1.5 * scale))

        if collapsed {
            appendChevronSegment(from: SIMD2<Float>(centerX - half * 0.35, centerY - half), to: SIMD2<Float>(centerX + half * 0.35, centerY), lineWidth: lineWidth, color: color, quads: &bgQuads)
            appendChevronSegment(from: SIMD2<Float>(centerX + half * 0.35, centerY), to: SIMD2<Float>(centerX - half * 0.35, centerY + half), lineWidth: lineWidth, color: color, quads: &bgQuads)
        } else {
            appendChevronSegment(from: SIMD2<Float>(centerX - half, centerY - half * 0.25), to: SIMD2<Float>(centerX, centerY + half * 0.45), lineWidth: lineWidth, color: color, quads: &bgQuads)
            appendChevronSegment(from: SIMD2<Float>(centerX, centerY + half * 0.45), to: SIMD2<Float>(centerX + half, centerY - half * 0.25), lineWidth: lineWidth, color: color, quads: &bgQuads)
        }
    }

    /// Approximates a diagonal chevron stroke with overlapping square Metal quads.
    private func appendChevronSegment(
        from start: SIMD2<Float>, to end: SIMD2<Float>, lineWidth: Float,
        color: SIMD3<Float>, quads: inout [QuadGPU]
    ) {
        let delta = end - start
        let length = max(1.0, sqrt(delta.x * delta.x + delta.y * delta.y))
        let steps = max(2, Int(ceil(length / max(1.0, lineWidth * 0.55))))

        for index in 0...steps {
            let t = Float(index) / Float(steps)
            let point = start + delta * t
            var quad = QuadGPU()
            quad.position = SIMD2<Float>(CoreTextMetalRenderer.snapToPixel(point.x - lineWidth * 0.5), CoreTextMetalRenderer.snapToPixel(point.y - lineWidth * 0.5))
            quad.size = SIMD2<Float>(lineWidth, lineWidth)
            quad.color = color
            quad.alpha = 1.0
            quads.append(quad)
        }
    }

    /// Draws quads in batches that fit Metal's 4 KB inline `setVertexBytes` limit.
    private func drawQuadBatches(_ quads: [QuadGPU], encoder: MTLRenderCommandEncoder, uniforms: inout CTUniformsGPU) {
        let stride = MemoryLayout<QuadGPU>.stride
        let maxPerBatch = max(1, 4096 / stride)
        var batchStart = 0

        while batchStart < quads.count {
            let batchCount = min(quads.count - batchStart, maxPerBatch)
            quads.withUnsafeBufferPointer { ptr in
                let base = ptr.baseAddress! + batchStart
                encoder.setVertexBytes(base, length: batchCount * stride, index: 0)
            }
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<CTUniformsGPU>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: batchCount)
            batchStart += batchCount
        }
    }

    /// Renders a line number for one gutter row.
    private func renderGutterLineNumber(
        entry: Wire.GutterEntry, gutter: Wire.WindowGutter,
        screenRow: UInt16, yPos: Float, xOffset: Float,
        signColWidth: Int,
        cellW: Float, cellH: Float, scale: Float,
        frameState: FrameState,
        lineInstances: inout [LineGPU],
    ) {
        let (numberStr, isCurrent) = gutterNumberString(
            bufLine: entry.bufLine,
            cursorLine: gutter.cursorLine,
            style: gutter.lineNumberStyle
        )

        guard !numberStr.isEmpty else { return }

        let fg = isCurrent ? frameState.gutterColors.currentFg : frameState.gutterColors.fg
        let lnWidth = Int(gutter.lineNumberWidth)

        // Right-align the number within the line number column space.
        // The number starts after the reserved sign/fold prefix columns.
        let padCols = max(lnWidth - numberStr.count - 1, 0)
        let startCol = UInt16(signColWidth + padCols)

        let cacheKey = AtlasKey.gutterLineNumber(windowId: gutter.windowId, row: screenRow)
        let contentHash = gutterContentHash(text: numberStr, fg: fg)
        if let atlas, let wcr = windowContentRenderer,
           let entry = wcr.renderSimpleText(numberStr, fg: fg,
                                             key: cacheKey, contentHash: contentHash, atlas: atlas, metrics: &frameMetrics) {
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
        bufLine: UInt32, cursorLine: UInt32, style: Wire.LineNumberStyle
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
    private func gutterSignColor(_ signType: Wire.GutterSignType, frameState: FrameState) -> SIMD3<Float> {
        switch signType {
        case .gitAdded: return colorFromU24(frameState.gutterColors.gitAddedFg, default: .zero)
        case .gitModified: return colorFromU24(frameState.gutterColors.gitModifiedFg, default: .zero)
        case .gitDeleted: return colorFromU24(frameState.gutterColors.gitDeletedFg, default: .zero)
        case .gitRemoved: return colorFromU24(frameState.gutterColors.gitDeletedFg, default: .zero)
        case .diagError: return colorFromU24(frameState.gutterColors.errorFg, default: .zero)
        case .diagWarning: return colorFromU24(frameState.gutterColors.warningFg, default: .zero)
        case .diagInfo: return colorFromU24(frameState.gutterColors.infoFg, default: .zero)
        case .diagHint: return colorFromU24(frameState.gutterColors.hintFg, default: .zero)
        case .annotation: return .zero  // Annotation color is per-entry, not from theme
        case .none: return .zero
        }
    }

    /// Returns the sign character and fg color (as U24) for a text-rendered gutter sign.
    private func gutterTextSignAndColor(_ signType: Wire.GutterSignType, frameState: FrameState) -> (String, UInt32) {
        switch signType {
        case .gitRemoved: return ("-", frameState.gutterColors.gitDeletedFg)
        case .diagError: return ("E", frameState.gutterColors.errorFg)
        case .diagWarning: return ("W", frameState.gutterColors.warningFg)
        case .diagInfo: return ("I", frameState.gutterColors.infoFg)
        case .diagHint: return ("H", frameState.gutterColors.hintFg)
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

    /// Computes a conservative atlas slot count for all text textures that may be touched by the current frame.
    @MainActor
    static func invalidateFullRefreshWindows(in atlas: LineTextureAtlas, windowContents: [UInt16: GUIWindowContent]) {
        for content in windowContents.values where content.fullRefresh {
            atlas.invalidateWindow(content.windowId)
        }
    }

    nonisolated static func atlasSlotDemand(frameState: FrameState, windowContents: [UInt16: GUIWindowContent]) -> Int {
        let bufferRows = windowContents.values.reduce(0) { total, content in
            total + content.rows.count
        }

        let lineAnnotations = windowContents.values.reduce(0) { total, content in
            total + content.lineAnnotations.filter { $0.kind != .gutterIcon }.count
        }

        let gutterTextures = frameState.windowGutters.values.reduce(0) { total, gutter in
            total + gutterTextureDemand(gutter)
        }

        let splitLabels = frameState.horizontalSeparators.reduce(0) { total, separator in
            total + (separator.filename.isEmpty ? 0 : 1)
        }

        let demand = bufferRows + lineAnnotations + gutterTextures + splitLabels
        let slack = max(Int(frameState.rows), 32)
        return max(demand + slack, 1)
    }

    private nonisolated static func gutterTextureDemand(_ gutter: Wire.WindowGutter) -> Int {
        gutter.entries.reduce(0) { total, entry in
            total + lineNumberTextureDemand(gutter) + signTextureDemand(entry.signType)
        }
    }

    private nonisolated static func lineNumberTextureDemand(_ gutter: Wire.WindowGutter) -> Int {
        if gutter.lineNumberStyle != .none && gutter.lineNumberWidth > 0 {
            return 1
        }

        return 0
    }

    private nonisolated static func signTextureDemand(_ signType: Wire.GutterSignType) -> Int {
        switch signType {
        case .gitRemoved, .diagError, .diagWarning, .diagInfo, .diagHint, .annotation:
            return 1
        case .gitAdded, .gitModified, .gitDeleted, .none:
            return 0
        }
    }

    private func shouldRenderLineNumber(for entry: Wire.GutterEntry) -> Bool {
        switch entry.displayType {
        case .wrapContinuation, .blank:
            return false
        case .normal, .foldStart, .foldContinuation, .foldOpen:
            return true
        }
    }

    // MARK: - Private

    /// Updates the user-configured cursor animation preference.
    func setCursorAnimateConfigEnabled(_ enabled: Bool) {
        cursorAnimateConfigEnabled = enabled
        refreshCursorAnimateEnabled()
    }

    /// Updates the Reduce Motion override for cursor animation.
    func setCursorAnimationReduceMotionDisabled(_ disabled: Bool) {
        cursorAnimationReduceMotionDisabled = disabled
        refreshCursorAnimateEnabled()
    }

    private func refreshCursorAnimateEnabled() {
        cursorAnimateEnabled = cursorAnimateConfigEnabled && !cursorAnimationReduceMotionDisabled
        guard !cursorAnimateEnabled else { return }
        snapCursorAnimationToTarget()
    }

    func animatedCursor(for resolvedCursor: RenderCursor?, teleportLineThresholdPx: Float) -> RenderCursor? {
        guard let resolvedCursor else {
            cursorAnimating = false
            hasCursorAnimationPosition = false
            return nil
        }

        guard cursorAnimateEnabled else {
            snapCursorAnimation(to: resolvedCursor)
            return resolvedCursor
        }

        if !hasCursorAnimationPosition {
            snapCursorAnimation(to: resolvedCursor)
            return resolvedCursor
        }

        if cursorTargetChanged(resolvedCursor) {
            updateCursorAnimation()
            startCursorAnimation(to: resolvedCursor, teleportLineThresholdPx: teleportLineThresholdPx)
        }

        return updateCursorAnimation() ?? resolvedCursor
    }

    private func cursorTargetChanged(_ cursor: RenderCursor) -> Bool {
        abs(targetCursorX - cursor.x) > 0.001 || abs(targetCursorY - cursor.y) > 0.001 || targetCursorShape != cursor.shape || targetCursorWindowId != cursor.windowId || !hasCursorAnimationPosition
    }

    private func startCursorAnimation(to cursor: RenderCursor, teleportLineThresholdPx: Float) {
        let distanceY = abs(cursor.y - currentCursorY)
        guard distanceY <= teleportLineThresholdPx else {
            snapCursorAnimation(to: cursor)
            return
        }

        startCursorX = currentCursorX
        startCursorY = currentCursorY
        targetCursorX = cursor.x
        targetCursorY = cursor.y
        targetCursorShape = cursor.shape
        targetCursorWindowId = cursor.windowId
        cursorAnimationStartTime = CACurrentMediaTime()
        cursorAnimating = true
        cursorAnimationGeneration &+= 1
    }

    @discardableResult
    func updateCursorAnimation(now: CFTimeInterval = CACurrentMediaTime()) -> RenderCursor? {
        guard hasCursorAnimationPosition else { return nil }
        guard cursorAnimating else {
            currentCursorX = targetCursorX
            currentCursorY = targetCursorY
            return RenderCursor(x: currentCursorX, y: currentCursorY, shape: targetCursorShape, windowId: targetCursorWindowId)
        }

        let progress = CoreTextMetalRenderer.cursorAnimationProgress(now: now, startTime: cursorAnimationStartTime, duration: cursorAnimationDuration)
        currentCursorX = CoreTextMetalRenderer.lerp(startCursorX, targetCursorX, progress)
        currentCursorY = CoreTextMetalRenderer.lerp(startCursorY, targetCursorY, progress)

        if progress >= 1.0 {
            cursorAnimating = false
            currentCursorX = targetCursorX
            currentCursorY = targetCursorY
        }

        return RenderCursor(x: currentCursorX, y: currentCursorY, shape: targetCursorShape, windowId: targetCursorWindowId)
    }

    nonisolated static func cursorAnimationProgress(now: CFTimeInterval, startTime: CFTimeInterval, duration: CFTimeInterval) -> Float {
        guard duration > 0 else { return 1.0 }
        return min(max(Float((now - startTime) / duration), 0.0), 1.0)
    }

    nonisolated static func lerp(_ start: Float, _ end: Float, _ progress: Float) -> Float {
        start + (end - start) * progress
    }

    nonisolated static func smoothScrollOffset(for windowId: UInt16?, targetWindowId: UInt16?, scrollOffsetPx: SIMD2<Float>) -> SIMD2<Float> {
        guard let windowId, let targetWindowId, windowId == targetWindowId else { return .zero }
        return scrollOffsetPx
    }

    nonisolated static func windowWidthCols(gutter: Wire.WindowGutter, frameCols: UInt16) -> Int {
        if gutter.contentWidth > 0 {
            return Int(gutter.contentWidth)
        }

        return max(Int(frameCols) - Int(gutter.contentCol), 1)
    }

    nonisolated static func visibleTextCols(
        geometry: GUIPaneGeometry?,
        gutter: Wire.WindowGutter,
        frameCols: UInt16,
        cellW: Float,
        scale: Float,
        gutterLeftMarginPx: Float,
        gutterPaddingPx: Float
    ) -> Int {
        if let geometry {
            let cellWidthPx = max(cellW * scale, 1)
            let paddingCols = Int(ceil((gutterLeftMarginPx + gutterPaddingPx) / cellWidthPx))
            return max(Int(geometry.textRect.width) - paddingCols, 1)
        }

        let gutterCols = Int(gutter.lineNumberWidth) + Int(gutter.signColWidth)
        let availableCols = max(windowWidthCols(gutter: gutter, frameCols: frameCols) - gutterCols, 1)
        let cellWidthPx = max(cellW * scale, 1)
        let paddingCols = Int(ceil((gutterLeftMarginPx + gutterPaddingPx) / cellWidthPx))
        return max(availableCols - paddingCols, 1)
    }

    nonisolated static func windowHorizontalBounds(
        geometry: GUIPaneGeometry?,
        gutter: Wire.WindowGutter,
        frameCols: UInt16,
        cellW: Float,
        scale: Float,
        viewportWidth: Float
    ) -> (x: Float, width: Float) {
        if let geometry {
            let left = Float(geometry.clipRect.col) * cellW * scale
            let right = min(left + Float(geometry.clipRect.width) * cellW * scale, viewportWidth)
            return (x: left, width: max(right - left, 0))
        }

        let left = Float(gutter.contentCol) * cellW * scale
        let right = min(left + Float(windowWidthCols(gutter: gutter, frameCols: frameCols)) * cellW * scale, viewportWidth)
        return (x: left, width: max(right - left, 0))
    }

    nonisolated static func cursorlineHorizontalBounds(
        row: UInt16,
        gutters: [UInt16: Wire.WindowGutter],
        frameCols: UInt16,
        cellW: Float,
        scale: Float,
        viewportWidth: Float
    ) -> (x: Float, width: Float) {
        let rowIndex = Int(row)
        let matchingGutter = gutters.values.first { gutter in
            let start = Int(gutter.contentRow)
            let end = start + Int(gutter.contentHeight)
            return gutter.isActive && rowIndex >= start && rowIndex < end
        } ?? gutters.values.first { gutter in
            let start = Int(gutter.contentRow)
            let end = start + Int(gutter.contentHeight)
            return rowIndex >= start && rowIndex < end
        }

        guard let matchingGutter else {
            return (x: 0, width: viewportWidth)
        }

        return windowHorizontalBounds(
            geometry: nil,
            gutter: matchingGutter,
            frameCols: frameCols,
            cellW: cellW,
            scale: scale,
            viewportWidth: viewportWidth
        )
    }

    nonisolated static func interpolateCursor(start: RenderCursor, target: RenderCursor, progress: Float) -> RenderCursor {
        let clamped = min(max(progress, 0.0), 1.0)
        return RenderCursor(x: lerp(start.x, target.x, clamped), y: lerp(start.y, target.y, clamped), shape: target.shape, windowId: target.windowId)
    }

    private func snapCursorAnimationToTarget() {
        guard hasCursorAnimationPosition else { return }
        currentCursorX = targetCursorX
        currentCursorY = targetCursorY
        cursorAnimating = false
    }

    private func snapCursorAnimation(to cursor: RenderCursor) {
        hasCursorAnimationPosition = true
        currentCursorX = cursor.x
        currentCursorY = cursor.y
        startCursorX = cursor.x
        startCursorY = cursor.y
        targetCursorX = cursor.x
        targetCursorY = cursor.y
        targetCursorShape = cursor.shape
        targetCursorWindowId = cursor.windowId
        cursorAnimating = false
    }

    /// Resolve the cursor position in the same coordinate system as the text renderer.
    /// Semantic GUI window content is preferred because it carries window-relative cursor coordinates and horizontal scroll. Legacy frameState cursor data remains the fallback for transition frames and non-semantic surfaces.
    nonisolated static func resolveCursor(
        frameState: FrameState,
        windowContents: [UInt16: GUIWindowContent],
        cellW: Float,
        displayCellH: Float,
        scale: Float,
        gutterLeftMarginPx: Float,
        gutterPaddingPx: Float
    ) -> RenderCursor? {
        var sawActiveSemanticCursorOwner = false
        for windowId in semanticCursorWindowIds(frameState.windowGutters) {
            guard let gutter = frameState.windowGutters[windowId], let content = windowContents[windowId] else { continue }
            sawActiveSemanticCursorOwner = true
            guard content.cursorVisible else { continue }

            let fallbackTextCol = UInt16(Int(gutter.contentCol) + Int(gutter.lineNumberWidth) + Int(gutter.signColWidth))
            let contentColOffset = Float(content.paneGeometry?.textRect.col ?? fallbackTextCol) * cellW * scale + gutterLeftMarginPx + gutterPaddingPx
            let hScrollPx = Float(content.scrollLeft) * cellW * scale
            let cursorCol = resolvedSemanticCursorCol(content)
            let x = contentColOffset + Float(cursorCol) * cellW * scale - hScrollPx
            let textRow = content.paneGeometry?.textRect.row ?? gutter.contentRow
            let y = (Float(textRow) + Float(content.cursorRow)) * displayCellH * scale
            return RenderCursor(x: x, y: y, shape: content.cursorShape, windowId: windowId)
        }

        if sawActiveSemanticCursorOwner { return nil }
        guard frameState.cursorVisible else { return nil }

        let cursorPadding: Float = (frameState.gutterCol > 0 && frameState.cursorCol >= frameState.gutterCol)
            ? gutterLeftMarginPx + gutterPaddingPx : 0
        let x = Float(frameState.cursorCol) * cellW * scale + cursorPadding
        let y = Float(frameState.cursorRow) * displayCellH * scale
        return RenderCursor(x: x, y: y, shape: frameState.cursorShape)
    }

    /// Returns active semantic cursor owners in deterministic priority order. The agent prompt uses a reserved window id and must win over the retained chat content when both are active during focus transitions.
    nonisolated static func semanticCursorWindowIds(_ gutters: [UInt16: Wire.WindowGutter]) -> [UInt16] {
        gutters.values
            .filter(\.isActive)
            .map(\.windowId)
            .sorted { lhs, rhs in
                let leftPriority = semanticCursorPriority(windowId: lhs)
                let rightPriority = semanticCursorPriority(windowId: rhs)
                if leftPriority == rightPriority { return lhs < rhs }
                return leftPriority < rightPriority
            }
    }

    nonisolated static func semanticCursorPriority(windowId: UInt16) -> Int {
        windowId == 65_534 ? 0 : 1
    }

    /// Converts the semantic cursor column into the rendered column for the active cursor shape.
    /// Insert-mode beam cursors use the insertion point exactly. Normal-mode block cursors render over a character cell, so an end-of-line insertion point must draw over the final rendered character instead of the next empty cell.
    nonisolated static func resolvedSemanticCursorCol(_ content: GUIWindowContent) -> UInt16 {
        guard content.cursorShape == .block else { return content.cursorCol }
        guard Int(content.cursorRow) < content.rows.count else { return content.cursorCol }

        let row = content.rows[Int(content.cursorRow)]
        let width = displayWidth(row.text)
        guard width > 0, Int(content.cursorCol) >= width else { return content.cursorCol }
        return UInt16(width - 1)
    }

    /// Snap device-pixel coordinates so cursor edges stay crisp while logical cell width remains fractional.
    nonisolated static func snapToPixel(_ value: Float) -> Float {
        round(value)
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

    /// Build selection overlay quads from semantic selection data.
    ///
    /// Char selection: one quad per row (partial for first/last rows).
    /// Line selection: full-width quads for each row in the range.
    private func appendSelectionQuads(
        selection sel: GUISelectionOverlay,
        rowOffset: Float, colOffset: Float,
        scrollLeft: Int,
        visibleRows: Int,
        visibleCols: Int,
        cellW: Float, cellH: Float, scale: Float,
        viewportWidth: Float,
        quads: inout [QuadGPU]
    ) {
        guard visibleRows > 0, visibleCols > 0, cellW > 0, cellH > 0, scale > 0 else {
            assertionFailure("appendSelectionQuads called with invalid dimensions: rows=\(visibleRows) cols=\(visibleCols) cellW=\(cellW) cellH=\(cellH) scale=\(scale)")
            return
        }

        let requestedStartRow = Int(sel.startRow)
        let requestedEndRow = Int(sel.endRow)
        guard requestedStartRow <= requestedEndRow else {
            assertionFailure("Selection startRow (\(requestedStartRow)) > endRow (\(requestedEndRow))")
            return
        }

        let startRow = max(requestedStartRow, 0)
        let endRow = min(requestedEndRow, visibleRows - 1)
        guard startRow <= endRow else { return }

        let selColor = currentThemeColors?.selectionBgSIMD ?? Self.systemSelectionColor
        let lineHeightPx = cellH * scale
        let colWidthPx = cellW * scale
        let rightEdgePx = min(colOffset + Float(visibleCols) * colWidthPx, viewportWidth)
        let fullLineWidthPx = max(rightEdgePx - colOffset, 0)
        guard fullLineWidthPx > 0 else { return }

        switch sel.type {
        case .line:
            for row in startRow...endRow {
                var quad = QuadGPU()
                quad.position = SIMD2<Float>(colOffset, rowOffset + Float(row) * lineHeightPx)
                quad.size = SIMD2<Float>(fullLineWidthPx, lineHeightPx)
                quad.color = selColor
                quad.alpha = 1.0
                quads.append(quad)
            }

        case .char:
            for row in startRow...endRow {
                let y = rowOffset + Float(row) * lineHeightPx
                let requestedCols = requestedSelectionCols(row: row, sel: sel, scrollLeft: scrollLeft, visibleCols: visibleCols)
                guard let clampedCols = clampSelectionCols(requestedCols, scrollLeft: scrollLeft, visibleCols: visibleCols) else { continue }

                let visibleStartCol = Float(clampedCols.start - scrollLeft)
                let visibleEndCol = Float(clampedCols.end - scrollLeft)

                var quad = QuadGPU()
                quad.position = SIMD2<Float>(colOffset + visibleStartCol * colWidthPx, y)
                quad.size = SIMD2<Float>((visibleEndCol - visibleStartCol) * colWidthPx, lineHeightPx)
                quad.color = selColor
                quad.alpha = 1.0
                quads.append(quad)
            }

        case .block:
            for row in startRow...endRow {
                let y = rowOffset + Float(row) * lineHeightPx
                let requestedCols = (start: Int(sel.startCol), end: Int(sel.endCol))
                guard let clampedCols = clampSelectionCols(requestedCols, scrollLeft: scrollLeft, visibleCols: visibleCols) else { continue }

                let visibleStartCol = Float(clampedCols.start - scrollLeft)
                let visibleEndCol = Float(clampedCols.end - scrollLeft)

                var quad = QuadGPU()
                quad.position = SIMD2<Float>(colOffset + visibleStartCol * colWidthPx, y)
                quad.size = SIMD2<Float>((visibleEndCol - visibleStartCol) * colWidthPx, lineHeightPx)
                quad.color = selColor
                quad.alpha = 1.0
                quads.append(quad)
            }
        }
    }

    private func requestedSelectionCols(row: Int, sel: GUISelectionOverlay, scrollLeft: Int, visibleCols: Int) -> (start: Int, end: Int) {
        let fullStart = scrollLeft
        let fullEnd = scrollLeft + visibleCols
        let startRow = Int(sel.startRow)
        let endRow = Int(sel.endRow)

        if row == startRow && row == endRow {
            return (Int(sel.startCol), Int(sel.endCol))
        }

        if row == startRow {
            return (Int(sel.startCol), fullEnd)
        }

        if row == endRow {
            return (fullStart, Int(sel.endCol))
        }

        return (fullStart, fullEnd)
    }

    private func clampSelectionCols(_ cols: (start: Int, end: Int), scrollLeft: Int, visibleCols: Int) -> (start: Int, end: Int)? {
        let visibleStart = scrollLeft
        let visibleEnd = scrollLeft + visibleCols
        let start = max(cols.start, visibleStart)
        let end = min(cols.end, visibleEnd)

        guard start < end else { return nil }
        return (start, end)
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
