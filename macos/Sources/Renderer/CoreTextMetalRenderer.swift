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

import MingaUI
import Dispatch
import Metal
import QuartzCore
import AppKit
import os.log
import os.signpost
import MingaProtocol

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

struct NativeActiveResourceSnapshot: Equatable {
    let atlas: ObjectIdentifier?
    let allocator: SlotAllocator?
    let texture: ObjectIdentifier?
    let windowRenderer: ObjectIdentifier?
    let cache: WindowContentCacheSnapshot?
    let rasterizer: ObjectIdentifier?
    let lineBuffer: ObjectIdentifier?
    let quadBuffers: [ObjectIdentifier]
    let completedGeneration: UInt64
}

/// Renders the editor using CoreText line textures instead of cell-grid instanced drawing.
///
/// `@MainActor` because it accesses `FontManager` (main-actor-isolated)
/// in the render path, and all callers are on the main thread already.
@MainActor
final class CoreTextMetalRenderer {
    /// Left margin before the gutter (breathing room from the window edge).
    static let gutterLeftMarginPt: CGFloat = 6.0
    /// Right gap between gutter and content (separator breathing room).
    static let gutterRightGapPt: CGFloat = 14.0
    /// Total gutter pixel padding in points (left margin + right separator gap).
    /// Subtracted from the view width when computing cols for the BEAM so
    /// `content_w` accurately reflects the visible content area.
    static let gutterPixelPaddingPt: CGFloat = gutterLeftMarginPt + gutterRightGapPt

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private let resourcePolicy: FrameResourcePolicy.NativeRendererLimits
    private let factories: NativeRenderFactories
    private var presentationGeneration = NativePresentationGeneration()
    /// Advances whenever font/scale-dependent renderer resources are rebuilt.
    private var configurationEpoch: UInt64 = 0
    /// Most recent renderer-local presentation failure. Semantic publication is unaffected.
    private(set) var lastNativePresentationFailure: NativePresentationFailure?
    /// Domain-frame presentation telemetry owned by the GUI state.
    weak var presentationMetrics: GUIFramePresentationMetrics?
    /// Generation of the last GPU-completed presentation whose candidate resources were promoted.
    private(set) var lastCompletedPresentationGeneration: UInt64 = 0
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

    init?(resourcePolicy: FrameResourcePolicy.NativeRendererLimits = .default,
          factories: NativeRenderFactories = .production) {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.device = device
        self.resourcePolicy = resourcePolicy
        self.factories = factories
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        self.clearColor = ctBgClearColorDefault

        // Read the system accent color for the cursor.
        self.cursorColor = CoreTextMetalRenderer.readAccentColor()

        // Load the compiled Metal shader library through the renderer-owned
        // resource seam. Production preserves the app/executable lookup.
        guard let library = factories.makeLibrary(device) else {
            NSLog("Failed to load Metal library")
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
    /// Last immutable content value whose staging counters were reported.
    private var residentMetricContentIdentities: [UInt16: ObjectIdentifier] = [:]

    /// Metal buffer for line GPU instances (one instanced draw call).
    private var instanceBuffer: MTLBuffer?
    private var maxInstanceSlots: Int = 0

    /// Number of in-flight frames for triple-buffered quad uploads.
    private static let quadBufferFrameCount = 3

    /// Triple-buffered quad instance buffers for bg/overlay/diagnostic passes.
    ///
    /// `setVertexBytes` silently truncates above Metal's 4 KB inline limit, so
    /// multi-window splits plus overlays could exceed it and drop quads without
    /// any error. These reusable buffers replace that path. One buffer per
    /// in-flight frame (rotated each frame) avoids CPU/GPU contention: the CPU
    /// writes the next frame's buffer while the GPU reads the previous one.
    private var quadBuffers: [MTLBuffer] = []

    /// Capacity (in quads) of each entry in `quadBuffers`. Grows on demand.
    private var quadBufferCapacity: Int = 0

    /// Alignment for per-pass offsets into a quad buffer. 256 bytes satisfies
    /// `setVertexBuffer(offset:)` constant-address-space alignment on all macOS GPUs.
    private static let quadBufferOffsetAlignment = 256

    /// Set up the window content renderer and texture atlas. Called once the FontManager is available.
    func setupRenderers(fontManager: FontManager) {
        configurationEpoch &+= 1
        let rasterizer = factories.makeRasterizer()
        self.bitmapRasterizer = rasterizer
        self.windowContentRenderer = WindowContentRenderer(
            device: device, fontManager: fontManager, rasterizer: rasterizer,
            resourcePolicy: resourcePolicy, makeTexture: factories.makeTexture
        )

        let linePixelHeight = Int(ceil(CGFloat(fontManager.cellHeight) * fontManager.scale))
        self.atlas = LineTextureAtlas(device: device, slotHeight: linePixelHeight,
                                      policy: resourcePolicy, makeTexture: factories.makeTexture)
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
                drawableProvider: @escaping @MainActor () -> CAMetalDrawable?, viewportSize: CGSize,
                contentScale: Float, scrollOffset: SIMD2<Float> = .zero,
                presentationWindowId: UInt16? = nil,
                presentationInputSeq: UInt32 = 0,
                presentationFrame: GUICommittedFrame? = nil,
                latencyRecorder: LatencyRecorder? = nil) {
        let renderSignpostID = OSSignpostID(log: renderLog)
        os_signpost(.begin, log: renderLog, name: "Frame", signpostID: renderSignpostID)
        defer {
            os_signpost(.end, log: renderLog, name: "Frame", signpostID: renderSignpostID,
                        "buffer_rows_rasterized=%{public}d buffer_rows_reused=%{public}d other_textures_rasterized=%{public}d other_textures_reused=%{public}d texture_uploads=%{public}d texture_upload_bytes=%{public}d atlas_new_keys=%{public}d atlas_hash_changes=%{public}d atlas_evictions=%{public}d editor_rows_visited=%{public}d decorations_visited=%{public}d resident_rows_visited=%{public}d resident_chunks_touched=%{public}d resident_ids_resolved=%{public}d resident_splices=%{public}d resident_changed_rows=%{public}d resident_locator_nodes_copied=%{public}d resident_full_resets=%{public}d",
                        frameMetrics.bufferRowsRasterized, frameMetrics.bufferRowsReused,
                        frameMetrics.otherTexturesRasterized, frameMetrics.otherTexturesReused,
                        frameMetrics.textureUploads, frameMetrics.textureUploadBytes,
                        frameMetrics.atlasNewKeys, frameMetrics.atlasHashChanges, frameMetrics.atlasEvictions,
                        frameMetrics.editorRowsVisited, frameMetrics.decorationsVisited,
                        frameMetrics.residentRowsVisited, frameMetrics.residentChunksTouched,
                        frameMetrics.residentIDsResolved, frameMetrics.residentSplices,
                        frameMetrics.residentChangedRowsValidated,
                        frameMetrics.residentLocatorNodesCopied, frameMetrics.residentFullResets)
        }

        // The window that owns the current presentation scroll offset. During a live gesture this
        // is the gesture target; during a settle / spring-back / discrete ease the gesture target
        // is already nil, so the view resolves this from the settle/elastic window instead. The
        // gate below is unchanged: the offset applies only to this one pane.
        let scrollTargetWindowId = presentationWindowId

        frameMetrics.reset()
        // Store theme colors reference for helper methods.
        self.currentThemeColors = themeColors

        let cellW = Float(fontManager.cellWidth)
        let cellH = Float(fontManager.cellHeight)
        let scale = contentScale
        // Display cell height includes line spacing. Use for all row Y positioning
        // and quad heights. The original cellH is used for text texture sizing only.
        let displayCellH = cellH * frameState.lineSpacing
        let smoothScrollOffsetPx = SIMD2<Float>(scrollOffset.x * scale, scrollOffset.y * scale)

        // Gutter spacing is also needed to derive the exact clipped command
        // viewport. Prepare each resident window once, then reuse that result
        // for metrics, atlas demand, gutters, and CoreText rendering.
        let hasGutterChrome = frameState.gutterCol > 0 || !frameState.windowGutters.isEmpty
        let gutterLeftMarginPt: Float = hasGutterChrome ? round(Float(Self.gutterLeftMarginPt) * scale) / scale : 0
        let gutterLeftMarginPx = gutterLeftMarginPt * scale
        let gutterPaddingPt: Float = hasGutterChrome ? round(Float(Self.gutterRightGapPt) * scale) / scale : 0
        let gutterPaddingPx = gutterPaddingPt * scale

        var preparedRowsByWindow: [UInt16: ResidentRenderPreparationResult] = [:]
        var visibleSlices: [UInt16: RendererRowSlice] = [:]
        preparedRowsByWindow.reserveCapacity(windowContents.count)
        visibleSlices.reserveCapacity(windowContents.count)
        for content in windowContents.values {
            let fallbackRows = Int(content.paneGeometry?.textRect.height
                ?? frameState.windowGutters[content.windowId]?.contentHeight
                ?? frameState.rows)
            let gutter = frameState.windowGutters[content.windowId]
            let contentCols = gutter.map {
                CoreTextMetalRenderer.visibleTextCols(
                    geometry: content.paneGeometry,
                    gutter: $0,
                    frameCols: frameState.cols,
                    cellW: cellW,
                    scale: scale,
                    gutterLeftMarginPx: gutterLeftMarginPx,
                    gutterPaddingPx: gutterPaddingPx
                )
            } ?? Int(frameState.cols)
            let scrollLeftInt = Int(content.scrollLeft)
            let localScrollInsetCols = scrollLeftInt > 0 ? 1 : 0
            let prepared = ResidentRenderPreparation.prepare(
                content: content,
                fallbackVisibleRows: fallbackRows,
                overscanRows: RendererSignposts.configuredOverscanRows,
                scrollLeft: max(scrollLeftInt - localScrollInsetCols, 0),
                viewportCols: contentCols + 2
            )
            preparedRowsByWindow[content.windowId] = prepared
            let slice = RendererSignposts.rowSlice(for: prepared)
            visibleSlices[content.windowId] = slice
            // This is the sole production resident traversal counter update.
            RendererSignposts.recordVisibleSlice(slice, in: &frameMetrics)
            frameMetrics.decorationsVisited += prepared.decorationsVisited
            RendererSignposts.recordOperation(
                RendererSignposts.operationCounters(
                    for: content,
                    lastContentIdentities: &residentMetricContentIdentities
                ),
                in: &frameMetrics
            )
        }

        // Every attempt receives a private logical generation, including reuse-only
        // frames. Allocator/cache writes are value copies and atlas writes COW the
        // texture, so no preparation failure can mutate active resources.
        guard let activeAtlas = self.atlas,
              let activeWindowRenderer = self.windowContentRenderer else {
            recordNativeFailure(NativePresentationFailure(
                phase: .atlas, dimension: .texture,
                frameSequence: presentationInputSeq, reason: .unavailable
            ), latencyRecorder: latencyRecorder, presentationFrame: presentationFrame)
            return
        }
        let candidateConfigurationEpoch = configurationEpoch
        let candidateRasterizer = factories.makeRasterizer()
        let candidateWindowRenderer = activeWindowRenderer.makeCandidate(rasterizer: candidateRasterizer)
        let candidateAtlas = activeAtlas.makeCandidate()
        let neededSlots = CoreTextMetalRenderer.atlasSlotDemand(
            frameState: frameState, windowContents: windowContents,
            preparedRows: preparedRowsByWindow
        )
        let atlasPixelWidth = Int(ceil(CGFloat(frameState.cols) * CGFloat(cellW) * CGFloat(scale)))
        switch candidateAtlas.ensureCapacity(maxSlots: neededSlots, width: atlasPixelWidth,
                                             frameSequence: presentationInputSeq) {
        case .success:
            break
        case .failure(let failure):
            recordNativeFailure(failure, latencyRecorder: latencyRecorder, presentationFrame: presentationFrame)
            return
        }

        // Local shadowing guarantees all preparation below targets only candidates.
        let atlas: LineTextureAtlas? = candidateAtlas
        let windowContentRenderer: WindowContentRenderer? = candidateWindowRenderer
        candidateWindowRenderer.beginFrame()
        candidateWindowRenderer.updateViewportWidth(cols: frameState.cols)
        if let tc = themeColors { candidateWindowRenderer.defaultFgRGB = tc.editorFgRGB }
        candidateAtlas.beginFrame()
        Self.invalidateFullRefreshWindows(in: candidateAtlas, windowContents: windowContents)

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
                let presentationScrollOffsetPx = CoreTextMetalRenderer.presentationScrollOffset(
                    scrollLeft: content.scrollLeft,
                    scrollOffsetPx: windowScrollOffsetPx
                )
                let scrollableWindowRowOffset = windowRowOffset - presentationScrollOffsetPx.y
                let scrollableWindowColOffset = presentationScrollOffsetPx.x
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
                let contentTopPx = Float(paneGeometry?.textRect.row ?? gutter.contentRow) * displayCellH * scale
                guard let visibleSlice = visibleSlices[content.windowId] else { continue }
                let overscanBeforeRows = visibleSlice.overscanBeforeRows
                let committedVisibleRows = CoreTextMetalRenderer.committedVisibleRows(
                    paneGeometry: paneGeometry,
                    gutter: gutter,
                    fallback: max(visibleSlice.rows.count - overscanBeforeRows, 0)
                )
                let contentBottomPx = min(contentTopPx + Float(committedVisibleRows) * displayCellH * scale, Float(viewportSize.height))

                // Editor background fill for the pane. The semantic content path
                // rasterizes rows into text-width, transparent-background textures,
                // so every pixel that is not covered by text, gutter, or an overlay
                // shows through to whatever is behind it. Relying on the Metal clear
                // color alone leaves the remainder below the last row painted by an
                // implicit global color; here we paint it explicitly in the editor
                // background so the fill always reaches the status bar edge.
                //
                // The bottom-most pane extends to the full drawable height so both
                // remainder classes are covered: the raw-cell remainder (view height
                // not a multiple of the cell height) and the effective-rows remainder
                // (spaced rows * displayCellH < view height). Interior panes stop at
                // their neighbor's top so horizontal split separators and stacked
                // panes (including the agent panel edge) have no band above them.
                if windowBounds.width > 0,
                   let fill = CoreTextMetalRenderer.windowBackgroundFillBounds(
                       paneTopRow: Int(paneGeometry?.textRect.row ?? gutter.contentRow),
                       paneRows: committedVisibleRows,
                       totalRows: Int(frameState.rows),
                       displayCellH: displayCellH,
                       scale: scale,
                       viewportHeight: Float(viewportSize.height)
                   ) {
                    var bgFill = QuadGPU()
                    bgFill.position = SIMD2<Float>(windowBounds.x, fill.top)
                    bgFill.size = SIMD2<Float>(windowBounds.width, fill.bottom - fill.top)
                    bgFill.color = defaultBg
                    bgFill.alpha = 1.0
                    bgQuads.append(bgFill)
                }

                if let cursorline = content.cursorline, cursorline.bg != 0 {
                    let yPos = CoreTextMetalRenderer.viewportLocalRowY(
                        localRow: Int(cursorline.row), origin: scrollableWindowRowOffset,
                        cellHeight: displayCellH, scale: scale
                    )
                    if let clipped = CoreTextMetalRenderer.clipVerticalQuad(y: yPos, height: displayCellH * scale, top: contentTopPx, bottom: contentBottomPx) {
                        var clQuad = QuadGPU()
                        clQuad.position = SIMD2<Float>(windowBounds.x, clipped.y)
                        clQuad.size = SIMD2<Float>(windowBounds.width, clipped.height)
                        clQuad.color = colorFromU24(cursorline.bg, default: defaultBg)
                        clQuad.alpha = 1.0
                        bgQuads.append(clQuad)
                    }
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
                        colOffset: contentColOffset - scrollableWindowColOffset,
                        scrollLeft: scrollLeftInt,
                        visibleRows: committedVisibleRows,
                        visibleCols: contentCols,
                        cellW: cellW, cellH: displayCellH, scale: scale,
                        viewportWidth: contentRightPx,
                        clipLeft: contentColOffset,
                        clipTop: contentTopPx,
                        clipBottom: contentBottomPx,
                        quads: &semanticOverlayQuads
                    )
                }

                // Document highlight overlay quads (drawn before search matches,
                // so search matches paint over them when they overlap).
                for highlight in content.documentHighlights {
                    guard highlight.endCol > highlight.startCol else { continue }
                    // Document highlights are typically single-line (one identifier).
                    // Draw on startRow only; multi-row highlights are rare for this feature.
                    let hlY = CoreTextMetalRenderer.viewportLocalRowY(
                        localRow: Int(highlight.startRow), origin: scrollableWindowRowOffset,
                        cellHeight: displayCellH, scale: scale
                    )
                    let rawHlX = contentColOffset + Float(highlight.startCol) * cellW * scale - hScrollPx - scrollableWindowColOffset
                    let rawHlRight = rawHlX + Float(highlight.endCol - highlight.startCol) * cellW * scale
                    let hlX = max(rawHlX, contentColOffset)
                    let hlRight = min(rawHlRight, contentRightPx)
                    guard hlRight > hlX,
                          let clipped = CoreTextMetalRenderer.clipVerticalQuad(y: hlY, height: displayCellH * scale, top: contentTopPx, bottom: contentBottomPx) else { continue }

                    var quad = QuadGPU()
                    quad.position = SIMD2<Float>(hlX, clipped.y)
                    quad.size = SIMD2<Float>(hlRight - hlX, clipped.height)
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
                    let matchY = CoreTextMetalRenderer.viewportLocalRowY(
                        localRow: Int(match.row), origin: scrollableWindowRowOffset,
                        cellHeight: displayCellH, scale: scale
                    )
                    let rawMatchX = contentColOffset + Float(match.startCol) * cellW * scale - hScrollPx - scrollableWindowColOffset
                    let rawMatchRight = rawMatchX + Float(match.endCol - match.startCol) * cellW * scale
                    let matchX = max(rawMatchX, contentColOffset)
                    let matchRight = min(rawMatchRight, contentRightPx)
                    guard matchRight > matchX,
                          let clipped = CoreTextMetalRenderer.clipVerticalQuad(y: matchY, height: displayCellH * scale, top: contentTopPx, bottom: contentBottomPx) else { continue }

                    var quad = QuadGPU()
                    quad.position = SIMD2<Float>(matchX, clipped.y)
                    quad.size = SIMD2<Float>(matchRight - matchX, clipped.height)
                    quad.color = match.isCurrent
                        ? SIMD3<Float>(0.95, 0.75, 0.0)    // current match: gold
                        : SIMD3<Float>(0.35, 0.35, 0.15)   // other matches: dim gold
                    quad.alpha = 1.0
                    semanticOverlayQuads.append(quad)
                }

                // Pre-clip visible rows to the viewport window. Drops scrollLeft
                // columns from the start and limits to viewport width, so each
                // texture is at most viewport-wide.
                let localScrollInsetCols = scrollLeftInt > 0 ? 1 : 0
                let localClipXOffset = Float(localScrollInsetCols) * cellW * scale

                // Reuse the shared Metal-free CoreText commands prepared once
                // at the start of this frame.
                guard let preparedRows = preparedRowsByWindow[content.windowId] else { continue }
                var visibleRowWidths: [UInt16: Int] = [:]
                for command in preparedRows.commands {
                    let displayRow = command.displayRow
                    let presentationRow = command.presentationRow
                    let yPos = scrollableWindowRowOffset + Float(presentationRow) * displayCellH * scale
                    let textYOffset = (displayCellH - cellH) * scale * 0.5
                    let rawLineY = yPos + textYOffset
                    guard CoreTextMetalRenderer.clipVerticalQuad(y: rawLineY, height: Float(wcr.linePixelHeight), top: contentTopPx, bottom: contentBottomPx) != nil else { continue }

                    if let atlas, let entry = wcr.renderRowToAtlas(displayRow: displayRow, row: command.row, windowId: content.windowId, contentEpoch: content.contentEpoch, atlas: atlas, metrics: &frameMetrics) {
                        if presentationRow >= 0 && presentationRow < committedVisibleRows {
                            visibleRowWidths[UInt16(presentationRow)] = entry.pixelWidth
                        }

                        let (uvOrigin, uvSize) = atlas.uvForSlot(entry.slotIndex, pixelWidth: entry.pixelWidth)
                        let rawLineX = contentColOffset - localClipXOffset - scrollableWindowColOffset
                        let clippedLeftPx = max(contentColOffset - rawLineX, 0)
                        let lineX = max(rawLineX, contentColOffset)
                        let visiblePixelWidth = min(Float(entry.pixelWidth) - clippedLeftPx, contentRightPx - lineX)
                        let clippedTopPx = max(contentTopPx - rawLineY, 0)
                        let lineY = max(rawLineY, contentTopPx)
                        let visiblePixelHeight = min(Float(entry.pixelHeight) - clippedTopPx, contentBottomPx - lineY)
                        guard visiblePixelWidth > 0, visiblePixelHeight > 0 else { continue }
                        let visibleUVX = uvOrigin.x + uvSize.x * clippedLeftPx / Float(entry.pixelWidth)
                        let visibleUVWidth = uvSize.x * visiblePixelWidth / Float(entry.pixelWidth)
                        let visibleUVY = uvOrigin.y + uvSize.y * clippedTopPx / Float(entry.pixelHeight)
                        let visibleUVHeight = uvSize.y * visiblePixelHeight / Float(entry.pixelHeight)
                        var lineGPU = LineGPU()
                        lineGPU.position = SIMD2<Float>(lineX, lineY)
                        lineGPU.size = SIMD2<Float>(visiblePixelWidth, visiblePixelHeight)
                        lineGPU.uvOrigin = SIMD2<Float>(visibleUVX, visibleUVY)
                        lineGPU.uvSize = SIMD2<Float>(visibleUVWidth, visibleUVHeight)
                        lineInstances.append(lineGPU)
                    }
                }

                // Line annotation pills/text (drawn after line content).
                if !content.lineAnnotations.isEmpty, let atlas {
                    var annotationsByRow: [UInt16: [GUILineAnnotation]] = [:]
                    for ann in content.lineAnnotations where Int(ann.row) < committedVisibleRows {
                        annotationsByRow[ann.row, default: []].append(ann)
                    }

                    for (rowIndex, rowAnnotations) in annotationsByRow {
                        let linePixelWidth = Float(visibleRowWidths[rowIndex] ?? 0)
                        let rowY = CoreTextMetalRenderer.viewportLocalRowY(
                            localRow: Int(rowIndex), origin: scrollableWindowRowOffset,
                            cellHeight: displayCellH, scale: scale
                        )
                        guard let clippedRow = CoreTextMetalRenderer.clipVerticalQuad(y: rowY, height: displayCellH * scale, top: contentTopPx, bottom: contentBottomPx) else { continue }
                        var cursorX = max(contentColOffset, contentColOffset - scrollableWindowColOffset + linePixelWidth
                            + Float(wcr.annotationGap) * scale)

                        for (annIdx, ann) in rowAnnotations.enumerated() {
                            let annKey = AtlasKey.lineAnnotation(windowId: content.windowId, row: rowIndex, subIndex: UInt16(min(annIdx, Int(UInt16.max))))

                            guard let annEntry = wcr.renderAnnotationToAtlas(
                                annotation: ann, key: annKey, atlas: atlas, metrics: &frameMetrics
                            ) else { continue }

                            let (uvOrigin, uvSize) = atlas.uvForSlot(annEntry.slotIndex, pixelWidth: annEntry.pixelWidth)
                            let visiblePixelWidth = min(Float(annEntry.pixelWidth), contentRightPx - cursorX)
                            guard visiblePixelWidth > 0 else { continue }
                            let rawLineY = rowY
                        let clippedTopPx = max(contentTopPx - rawLineY, 0)
                            let visiblePixelHeight = min(Float(annEntry.pixelHeight) - clippedTopPx, contentBottomPx - rawLineY)
                            guard visiblePixelHeight > 0 else { continue }
                            let visibleUVX = uvOrigin.x
                            let visibleUVWidth = uvSize.x * visiblePixelWidth / Float(annEntry.pixelWidth)
                            let visibleUVY = uvOrigin.y + uvSize.y * clippedTopPx / Float(annEntry.pixelHeight)
                            let visibleUVHeight = uvSize.y * visiblePixelHeight / Float(annEntry.pixelHeight)

                            var lineGPU = LineGPU()
                            lineGPU.position = SIMD2<Float>(cursorX, clippedRow.y)
                            lineGPU.size = SIMD2<Float>(visiblePixelWidth, visiblePixelHeight)
                            lineGPU.uvOrigin = SIMD2<Float>(visibleUVX, visibleUVY)
                            lineGPU.uvSize = SIMD2<Float>(visibleUVWidth, visibleUVHeight)
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

                    let diagY = CoreTextMetalRenderer.viewportLocalRowY(
                        localRow: Int(diag.startRow), origin: scrollableWindowRowOffset,
                        cellHeight: displayCellH, scale: scale
                    ) + displayCellH * scale - 2.0 * scale
                    let rawDiagX = contentColOffset + Float(diag.startCol) * cellW * scale - hScrollPx - scrollableWindowColOffset
                    let rawDiagRight = rawDiagX + Float(diag.endCol - diag.startCol) * cellW * scale
                    let diagX = max(rawDiagX, contentColOffset)
                    let diagRight = min(rawDiagRight, contentRightPx)
                    guard diagRight > diagX,
                          let clipped = CoreTextMetalRenderer.clipVerticalQuad(y: diagY, height: 2.0 * scale, top: contentTopPx, bottom: contentBottomPx) else { continue }

                    var quad = QuadGPU()
                    quad.position = SIMD2<Float>(diagX, clipped.y)
                    quad.size = SIMD2<Float>(diagRight - diagX, clipped.height)
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
                entryRange: visibleSlices[windowGutter.windowId].map {
                    RendererSignposts.gutterRange(for: windowGutter, slice: $0)
                } ?? 0..<min(Int(windowGutter.contentHeight), windowGutter.entries.count),
                overscanBeforeRows: visibleSlices[windowGutter.windowId]?.overscanBeforeRows
                    ?? windowContents[windowGutter.windowId].map(CoreTextMetalRenderer.presentationOverscanBeforeRows)
                    ?? CoreTextMetalRenderer.scrollOverscanBefore(windowContents[windowGutter.windowId]?.scrollPresentation),
                atlas: candidateAtlas,
                windowRenderer: candidateWindowRenderer,
                bgQuads: &bgQuads,
                lineInstances: &lineInstances
            )
        }

        if let failure = windowContentRenderer?.nativePresentationFailure ?? candidateAtlas.nativePresentationFailure {
            recordNativeFailure(failure, frameSequence: presentationInputSeq,
                                latencyRecorder: latencyRecorder, presentationFrame: presentationFrame)
            return
        }

        // Derive one exact aggregate buffer request before command creation. No
        // buffer is replaced or grown while a pass is being encoded.
        let gutterChromeQuads = CoreTextMetalRenderer.gutterChromeQuads(
            frameState: frameState, cellW: cellW, cellH: displayCellH, scale: scale,
            gutterLeftMarginPx: gutterLeftMarginPx, gutterPaddingPx: gutterPaddingPx,
            viewportHeight: Float(viewportSize.height), defaultBg: defaultBg,
            separatorColor: colorFromU24(frameState.gutterSeparatorColor,
                                         default: SIMD3<Float>(0.3, 0.3, 0.3))
        )
        let guidePassCounts = indentGuideQuadCounts(
            frameState: frameState, windowContents: windowContents,
            cellW: cellW, displayCellH: displayCellH, scale: scale,
            gutterLeftMarginPx: gutterLeftMarginPx, gutterPaddingPx: gutterPaddingPx,
            viewportSize: viewportSize, scrollTargetWindowId: scrollTargetWindowId,
            smoothScrollOffsetPx: smoothScrollOffsetPx
        )
        let quadPassCounts = [bgQuads.count] + guidePassCounts
            + [semanticOverlayQuads.count, diagnosticQuads.count, gutterChromeQuads.count]
        let bufferDemand: NativeDrawBufferDemand
        do {
            bufferDemand = try NativeDrawBufferDemand.checked(
                lineCount: lineInstances.count, lineStride: MemoryLayout<LineGPU>.stride,
                quadPassCounts: quadPassCounts, quadStride: MemoryLayout<QuadGPU>.stride,
                quadBufferCount: Self.quadBufferFrameCount,
                alignment: Self.quadBufferOffsetAlignment,
                limit: resourcePolicy.aggregateDrawBufferBytes,
                deviceLimit: device.maxBufferLength,
                frameSequence: presentationInputSeq
            )
        } catch let failure as NativePresentationFailure {
            recordNativeFailure(failure, latencyRecorder: latencyRecorder, presentationFrame: presentationFrame)
            return
        } catch {
            recordNativeFailure(NativePresentationFailure(
                phase: .buffers, dimension: .arithmetic,
                frameSequence: presentationInputSeq, reason: .overflow
            ), latencyRecorder: latencyRecorder, presentationFrame: presentationFrame)
            return
        }
        let candidateInstanceBuffer: MTLBuffer?
        if bufferDemand.lineBytes > 0 {
            guard let buffer = factories.makeBuffer(device, bufferDemand.lineBytes, .storageModeShared) else {
                recordNativeFailure(NativePresentationFailure(
                    phase: .buffers, dimension: .lineBuffer,
                    requested: bufferDemand.lineBytes,
                    frameSequence: presentationInputSeq, reason: .allocation
                ), latencyRecorder: latencyRecorder, presentationFrame: presentationFrame)
                return
            }
            candidateInstanceBuffer = buffer
        } else {
            candidateInstanceBuffer = nil
        }
        var candidateQuadBuffers: [MTLBuffer] = []
        if bufferDemand.quadBytesPerBuffer > 0 {
            let dimensions: [NativeRenderResourceDimension] = [.quadBuffer0, .quadBuffer1, .quadBuffer2]
            for index in 0..<Self.quadBufferFrameCount {
                guard let buffer = factories.makeBuffer(device, bufferDemand.quadBytesPerBuffer,
                                                        .storageModeShared) else {
                    recordNativeFailure(NativePresentationFailure(
                        phase: .buffers, dimension: dimensions[index],
                        requested: bufferDemand.quadBytesPerBuffer,
                        frameSequence: presentationInputSeq, reason: .allocation
                    ), latencyRecorder: latencyRecorder, presentationFrame: presentationFrame)
                    return
                }
                candidateQuadBuffers.append(buffer)
            }
        }

        // Render into a private candidate image. The drawable remains untouched
        // until this command has completed successfully.
        guard viewportSize.width.isFinite, viewportSize.height.isFinite,
              viewportSize.width > 0, viewportSize.height > 0 else {
            recordNativeFailure(NativePresentationFailure(
                phase: .drawable, dimension: .renderTarget,
                frameSequence: presentationInputSeq, reason: .overflow
            ), latencyRecorder: latencyRecorder, presentationFrame: presentationFrame)
            return
        }
        let deviceDimensionLimit = nativeDeviceTextureDimensionLimit(device)
        let targetWidthLimit = min(resourcePolicy.textureWidth, deviceDimensionLimit)
        let targetHeightLimit = min(resourcePolicy.textureHeight, deviceDimensionLimit)
        guard viewportSize.width <= CGFloat(targetWidthLimit) else {
            let requested = viewportSize.width <= CGFloat(Int32.max)
                ? Int(viewportSize.width.rounded(.up)) : nil
            recordNativeFailure(NativePresentationFailure(
                phase: .drawable, dimension: .textureWidth,
                requested: requested, limit: targetWidthLimit,
                frameSequence: presentationInputSeq, reason: .limit
            ), latencyRecorder: latencyRecorder, presentationFrame: presentationFrame)
            return
        }
        guard viewportSize.height <= CGFloat(targetHeightLimit) else {
            let requested = viewportSize.height <= CGFloat(Int32.max)
                ? Int(viewportSize.height.rounded(.up)) : nil
            recordNativeFailure(NativePresentationFailure(
                phase: .drawable, dimension: .textureHeight,
                requested: requested, limit: targetHeightLimit,
                frameSequence: presentationInputSeq, reason: .limit
            ), latencyRecorder: latencyRecorder, presentationFrame: presentationFrame)
            return
        }
        let targetWidth = Int(viewportSize.width.rounded(.up))
        let targetHeight = Int(viewportSize.height.rounded(.up))
        let targetDemand: NativeRenderTargetDemand
        do {
            targetDemand = try NativeRenderTargetDemand.checked(
                width: targetWidth, height: targetHeight,
                policy: resourcePolicy,
                deviceTextureDimension: nativeDeviceTextureDimensionLimit(device),
                frameSequence: presentationInputSeq
            )
        } catch let failure as NativePresentationFailure {
            recordNativeFailure(failure, latencyRecorder: latencyRecorder, presentationFrame: presentationFrame)
            return
        } catch {
            recordNativeFailure(NativePresentationFailure(
                phase: .drawable, dimension: .arithmetic,
                frameSequence: presentationInputSeq, reason: .overflow
            ), latencyRecorder: latencyRecorder, presentationFrame: presentationFrame)
            return
        }
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: targetDemand.width,
            height: targetDemand.height,
            mipmapped: false
        )
        targetDescriptor.usage = .renderTarget
        targetDescriptor.storageMode = .private
        guard let candidateRenderTarget = factories.makeTexture(device, targetDescriptor) else {
            recordNativeFailure(NativePresentationFailure(
                phase: .drawable, dimension: .renderTarget,
                requested: targetDemand.byteCount, limit: resourcePolicy.renderTargetBytes,
                frameSequence: presentationInputSeq, reason: .allocation
            ), latencyRecorder: latencyRecorder, presentationFrame: presentationFrame)
            return
        }

        // Set up the offscreen render pass.
        let renderDesc = MTLRenderPassDescriptor()
        renderDesc.colorAttachments[0].texture = candidateRenderTarget
        renderDesc.colorAttachments[0].loadAction = .clear
        renderDesc.colorAttachments[0].storeAction = .store
        renderDesc.colorAttachments[0].clearColor = clearColor

        guard let cmdBuf = factories.makeCommandBuffer(commandQueue) else {
            recordNativeFailure(NativePresentationFailure(
                phase: .command, dimension: .commandBuffer,
                frameSequence: presentationInputSeq, reason: .unavailable
            ), latencyRecorder: latencyRecorder, presentationFrame: presentationFrame)
            return
        }
        guard let encoder = factories.makeEncoder(cmdBuf, renderDesc) else {
            recordNativeFailure(NativePresentationFailure(
                phase: .command, dimension: .encoder,
                frameSequence: presentationInputSeq, reason: .unavailable
            ), latencyRecorder: latencyRecorder, presentationFrame: presentationFrame)
            return
        }

        // Triple-buffered quad uploads: wait until a quad buffer is free (at most
        // `quadBufferFrameCount` frames in flight), then rotate to it and reset
        // its write cursor. The matching `signal()` runs in the command buffer's
        // completion handler below. Acquired after the encoder guard so the early
        // return above never holds the semaphore.
        var candidateQuadWriteOffset = 0
        let candidateQuadBuffer = candidateQuadBuffers.first

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
            drawQuadBatches(bgQuads, buffer: candidateQuadBuffer,
                                            writeOffset: &candidateQuadWriteOffset,
                                            encoder: encoder, uniforms: &uniforms)
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
            let lineCellH = displayCellH * scale
            let inactiveFg = colorFromU24(frameState.gutterColors.fg, default: SIMD3<Float>(0.33, 0.33, 0.33))
            let tabW = max(UInt16(guideData.tabWidth), 1)
            let guideScrollLeft = windowContents[guideData.windowId]?.scrollLeft ?? 0
            let guideScrollOffset = CoreTextMetalRenderer.presentationScrollOffset(
                scrollLeft: guideScrollLeft,
                scrollOffsetPx: CoreTextMetalRenderer.smoothScrollOffset(
                    for: guideData.windowId,
                    targetWindowId: scrollTargetWindowId,
                    scrollOffsetPx: smoothScrollOffsetPx
                )
            )
            let guideScrollOffsetY = guideScrollOffset.y
            let guideScrollOffsetX = guideScrollOffset.x
            let guideTopY = Float(paneGeometry?.textRect.row ?? gutter.contentRow) * displayCellH * scale
            let guideHeightPx = Float(max(Int(paneGeometry?.textRect.height ?? gutter.contentHeight), 0)) * lineCellH
            let guideBottomY = min(guideTopY + guideHeightPx, Float(viewportSize.height))
            let textRightPx = contentRightPx

            var guideQuads: [QuadGPU] = []

            if guideData.lineIndentLevels.isEmpty {
                guideQuads.reserveCapacity(guideData.guideCols.count)
                let baseY = guideTopY - guideScrollOffsetY
                for col in guideData.guideCols {
                    let guideX = windowContentColOffset - guideScrollOffsetX + Float(col) * cellW * scale
                    guard let vertical = CoreTextMetalRenderer.clipVerticalQuad(y: baseY, height: guideHeightPx, top: guideTopY, bottom: guideBottomY),
                          let horizontal = CoreTextMetalRenderer.clipHorizontalRect(x: guideX, width: 1.0 * scale, left: windowContentColOffset, right: textRightPx) else { continue }
                    let isActive = col == guideData.activeGuideCol
                    var quad = QuadGPU()
                    quad.position = SIMD2<Float>(horizontal.x, vertical.y)
                    quad.size = SIMD2<Float>(horizontal.width, vertical.height)
                    quad.color = inactiveFg
                    quad.alpha = isActive ? 0.4 : 0.15
                    guideQuads.append(quad)
                }
            } else {
                guideQuads.reserveCapacity(guideData.guideCols.count * guideData.lineIndentLevels.count)
                for (lineIdx, level) in guideData.lineIndentLevels.enumerated() {
                    let lineY = guideTopY + Float(lineIdx) * lineCellH - guideScrollOffsetY
                    for col in guideData.guideCols {
                        let guideLevel = col / tabW
                        // Strict < so guides appear only in whitespace, not at the text-start column.
                        guard guideLevel < level else { continue }
                        let guideX = windowContentColOffset - guideScrollOffsetX + Float(col) * cellW * scale
                        guard let vertical = CoreTextMetalRenderer.clipVerticalQuad(y: lineY, height: lineCellH, top: guideTopY, bottom: guideBottomY),
                              let horizontal = CoreTextMetalRenderer.clipHorizontalRect(x: guideX, width: 1.0 * scale, left: windowContentColOffset, right: textRightPx) else { continue }
                        let isActive = col == guideData.activeGuideCol
                        var quad = QuadGPU()
                        quad.position = SIMD2<Float>(horizontal.x, vertical.y)
                        quad.size = SIMD2<Float>(horizontal.width, vertical.height)
                        quad.color = inactiveFg
                        quad.alpha = isActive ? 0.4 : 0.15
                        guideQuads.append(quad)
                    }
                }
            }

            if !guideQuads.isEmpty {
                encoder.setRenderPipelineState(bgPipeline)
                drawQuadBatches(guideQuads, buffer: candidateQuadBuffer,
                                                writeOffset: &candidateQuadWriteOffset,
                                                encoder: encoder, uniforms: &uniforms)
            }
        }

        // Pass 1.5: Semantic overlay quads (search matches, selection).
        // Drawn after bg fills but before cursor and text so they appear
        // behind text content. Selection and search highlights render as
        // Metal quads instead of being baked into line textures.
        if !semanticOverlayQuads.isEmpty {
            encoder.setRenderPipelineState(bgPipeline)
            drawQuadBatches(semanticOverlayQuads, buffer: candidateQuadBuffer,
                                            writeOffset: &candidateQuadWriteOffset,
                                            encoder: encoder, uniforms: &uniforms)
        }

        // Pass 2: Cursor background (drawn BEFORE text so text is visible on top).
        // For block cursors, draw the cursor bg here so the text pass composites over it.
        // Beam and underline cursors are drawn AFTER text (pass 5).
        if let renderCursor, cursorBlinkVisible, renderCursor.shape == .block {
            let cursorScrollLeft = renderCursor.windowId.flatMap { windowContents[$0]?.scrollLeft } ?? 0
            let cursorScrollOffsetPx = CoreTextMetalRenderer.presentationScrollOffset(
                scrollLeft: cursorScrollLeft,
                scrollOffsetPx: CoreTextMetalRenderer.smoothScrollOffset(
                    for: renderCursor.windowId,
                    targetWindowId: scrollTargetWindowId,
                    scrollOffsetPx: smoothScrollOffsetPx
                )
            )
            let cursorX = renderCursor.x - cursorScrollOffsetPx.x
            let cursorY = renderCursor.y - cursorScrollOffsetPx.y
            var cursorQuad = QuadGPU()
            let cursorWidth = CoreTextMetalRenderer.snapToPixel(cellW * scale)
            let cursorHeight = CoreTextMetalRenderer.snapToPixel(displayCellH * scale)
            let cursorWindowBounds = renderCursor.windowId.flatMap { windowId -> (x: Float, width: Float)? in
                guard let gutter = frameState.windowGutters[windowId] else { return nil }
                return CoreTextMetalRenderer.cursorHorizontalBounds(
                    geometry: windowContents[windowId]?.paneGeometry,
                    gutter: gutter,
                    frameCols: frameState.cols,
                    cellW: cellW,
                    scale: scale,
                    gutterLeftMarginPx: gutterLeftMarginPx,
                    gutterPaddingPx: gutterPaddingPx,
                    viewportWidth: Float(viewportSize.width)
                )
            }
            let cursorBounds = CoreTextMetalRenderer.paneVerticalBounds(
                for: renderCursor.windowId,
                windowContents: windowContents,
                gutters: frameState.windowGutters,
                displayCellH: displayCellH,
                scale: scale,
                viewportHeight: Float(viewportSize.height)
            )
            var shouldDrawCursor = true
            if let cursorWindowBounds, let cursorBounds {
                if let horizontal = CoreTextMetalRenderer.clipHorizontalRect(x: cursorX, width: cursorWidth, left: cursorWindowBounds.x, right: cursorWindowBounds.x + cursorWindowBounds.width), let clipped = CoreTextMetalRenderer.clipVerticalQuad(y: cursorY, height: cursorHeight, top: cursorBounds.top, bottom: cursorBounds.bottom) {
                    cursorQuad.position = SIMD2<Float>(CoreTextMetalRenderer.snapToPixel(horizontal.x), CoreTextMetalRenderer.snapToPixel(clipped.y))
                    cursorQuad.size = SIMD2<Float>(CoreTextMetalRenderer.snapToPixel(horizontal.width), CoreTextMetalRenderer.snapToPixel(clipped.height))
                } else {
                    shouldDrawCursor = false
                }
            } else {
                cursorQuad.position = SIMD2<Float>(CoreTextMetalRenderer.snapToPixel(cursorX), CoreTextMetalRenderer.snapToPixel(cursorY))
                cursorQuad.size = SIMD2<Float>(cursorWidth, cursorHeight)
            }
            cursorQuad.color = cursorColor
            cursorQuad.alpha = 1.0

            if shouldDrawCursor {
                var cursorBgParams = BgParamsGPU(cornerRadius: 0.0)
                encoder.setRenderPipelineState(bgPipeline)
                encoder.setVertexBytes(&cursorQuad, length: MemoryLayout<QuadGPU>.stride, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<CTUniformsGPU>.size, index: 1)
                encoder.setFragmentBytes(&cursorBgParams, length: MemoryLayout<BgParamsGPU>.size, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
            }

            // Restore default (no rounding) for subsequent draws.
            encoder.setFragmentBytes(&defaultBgParams, length: MemoryLayout<BgParamsGPU>.size, index: 0)
        }

        // Pass 3: Line textures — one instanced draw call with the atlas texture.
        if !lineInstances.isEmpty, let atlas, let atlasTexture = atlas.texture,
           let instBuf = candidateInstanceBuffer {
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
            drawQuadBatches(diagnosticQuads, buffer: candidateQuadBuffer,
                                            writeOffset: &candidateQuadWriteOffset,
                                            encoder: encoder, uniforms: &uniforms)
        }

        // Pass 4/5: Gutter gap fills and separator lines.
        if !gutterChromeQuads.isEmpty {
            encoder.setRenderPipelineState(bgPipeline)
            drawQuadBatches(gutterChromeQuads, buffer: candidateQuadBuffer,
                                            writeOffset: &candidateQuadWriteOffset,
                                            encoder: encoder, uniforms: &uniforms)
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

                        // Small bg fill behind label so it "breaks" the horizontal line.
                        // Clip it to the separator rect so labels in narrow horizontal splits never erase neighboring panes.
                        let padPx: Float = 4.0 * scale
                        if let labelBgBounds = CoreTextMetalRenderer.clipHorizontalRect(x: centerX - padPx, width: labelW + padPx * 2, left: hX, right: hX + hW) {
                            var labelBg = QuadGPU()
                            labelBg.position = SIMD2<Float>(labelBgBounds.x, hY - 1)
                            labelBg.size = SIMD2<Float>(labelBgBounds.width, 3.0)
                            labelBg.color = defaultBg
                            labelBg.alpha = 1.0
                            encoder.setRenderPipelineState(bgPipeline)
                            encoder.setVertexBytes(&labelBg, length: MemoryLayout<QuadGPU>.stride, index: 0)
                            encoder.setVertexBytes(&uniforms, length: MemoryLayout<CTUniformsGPU>.size, index: 1)
                            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
                        }

                        // Render the label texture immediately. The main line texture pass has already run by the time split separators are drawn, so queuing this into lineInstances would leave only the background gap visible.
                        let (uvOrigin, uvSize) = atlas.uvForSlot(entry.slotIndex, pixelWidth: entry.pixelWidth)
                        if var lineGPU = CoreTextMetalRenderer.clippedHorizontalLineGPU(x: centerX, y: labelY, width: Float(entry.pixelWidth), height: Float(entry.pixelHeight), uvOrigin: uvOrigin, uvSize: uvSize, clipLeft: hX, clipRight: hX + hW), let atlasTexture = atlas.texture {
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
            let cursorScrollLeft = renderCursor.windowId.flatMap { windowContents[$0]?.scrollLeft } ?? 0
            let cursorScrollOffsetPx = CoreTextMetalRenderer.presentationScrollOffset(
                scrollLeft: cursorScrollLeft,
                scrollOffsetPx: CoreTextMetalRenderer.smoothScrollOffset(
                    for: renderCursor.windowId,
                    targetWindowId: scrollTargetWindowId,
                    scrollOffsetPx: smoothScrollOffsetPx
                )
            )
            let cursorX = renderCursor.x - cursorScrollOffsetPx.x
            let cursorY = renderCursor.y - cursorScrollOffsetPx.y
            let cursorWindowBounds = renderCursor.windowId.flatMap { windowId -> (x: Float, width: Float)? in
                guard let gutter = frameState.windowGutters[windowId] else { return nil }
                return CoreTextMetalRenderer.cursorHorizontalBounds(
                    geometry: windowContents[windowId]?.paneGeometry,
                    gutter: gutter,
                    frameCols: frameState.cols,
                    cellW: cellW,
                    scale: scale,
                    gutterLeftMarginPx: gutterLeftMarginPx,
                    gutterPaddingPx: gutterPaddingPx,
                    viewportWidth: Float(viewportSize.width)
                )
            }
            var cursorQuad = QuadGPU()
            cursorQuad.color = cursorColor
            cursorQuad.alpha = 1.0
            var shouldDrawCursor = true

            let cursorBounds = CoreTextMetalRenderer.paneVerticalBounds(
                for: renderCursor.windowId,
                windowContents: windowContents,
                gutters: frameState.windowGutters,
                displayCellH: displayCellH,
                scale: scale,
                viewportHeight: Float(viewportSize.height)
            )

            switch renderCursor.shape {
            case .block:
                break  // Handled in pass 2.

            case .beam:
                let beamWidth: Float = 2.0 * scale
                let beamHeight = CoreTextMetalRenderer.snapToPixel(displayCellH * scale)
                if let cursorWindowBounds, let cursorBounds {
                    if let horizontal = CoreTextMetalRenderer.clipHorizontalRect(x: cursorX, width: beamWidth, left: cursorWindowBounds.x, right: cursorWindowBounds.x + cursorWindowBounds.width), let clipped = CoreTextMetalRenderer.clipVerticalQuad(y: cursorY, height: beamHeight, top: cursorBounds.top, bottom: cursorBounds.bottom) {
                        cursorQuad.position = SIMD2<Float>(CoreTextMetalRenderer.snapToPixel(horizontal.x), CoreTextMetalRenderer.snapToPixel(clipped.y))
                        cursorQuad.size = SIMD2<Float>(CoreTextMetalRenderer.snapToPixel(horizontal.width), CoreTextMetalRenderer.snapToPixel(clipped.height))
                    } else {
                        shouldDrawCursor = false
                    }
                } else {
                    cursorQuad.position = SIMD2<Float>(CoreTextMetalRenderer.snapToPixel(cursorX), CoreTextMetalRenderer.snapToPixel(cursorY))
                    cursorQuad.size = SIMD2<Float>(CoreTextMetalRenderer.snapToPixel(beamWidth), beamHeight)
                }

            case .underline:
                let ulHeight: Float = 2.0 * scale
                let cellBottom = cursorY + displayCellH * scale
                if let cursorWindowBounds, let cursorBounds {
                    if let horizontal = CoreTextMetalRenderer.clipHorizontalRect(x: cursorX, width: cellW * scale, left: cursorWindowBounds.x, right: cursorWindowBounds.x + cursorWindowBounds.width), let clipped = CoreTextMetalRenderer.clipVerticalQuad(y: cellBottom - ulHeight, height: ulHeight, top: cursorBounds.top, bottom: cursorBounds.bottom) {
                        cursorQuad.position = SIMD2<Float>(CoreTextMetalRenderer.snapToPixel(horizontal.x), CoreTextMetalRenderer.snapToPixel(clipped.y))
                        cursorQuad.size = SIMD2<Float>(CoreTextMetalRenderer.snapToPixel(horizontal.width), CoreTextMetalRenderer.snapToPixel(clipped.height))
                    } else {
                        shouldDrawCursor = false
                    }
                } else {
                    cursorQuad.position = SIMD2<Float>(CoreTextMetalRenderer.snapToPixel(cursorX), CoreTextMetalRenderer.snapToPixel(cellBottom - ulHeight))
                    cursorQuad.size = SIMD2<Float>(CoreTextMetalRenderer.snapToPixel(cellW * scale), CoreTextMetalRenderer.snapToPixel(ulHeight))
                }
            }

            if shouldDrawCursor {
                encoder.setRenderPipelineState(bgPipeline)
                encoder.setVertexBytes(&cursorQuad, length: MemoryLayout<QuadGPU>.stride, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<CTUniformsGPU>.size, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
            }
        }

        // Pass 7: Scroll indicator (overlay scrollbar).
        // A thin rect on the right edge showing viewport position within the document.
        // Only shown when the document is taller than the viewport.
        let totalLines = frameState.totalLineCount
        let visibleRows = UInt32(frameState.rows)
        let viewportTop = frameState.viewportTopLine

        let scrollIndicatorResident: Bool = {
            guard let wid = frameState.activeWindowId,
                  let content = windowContents[wid],
                  let sp = content.scrollPresentation else { return false }
            let perWindowTotal = content.paneGeometry?.viewport.totalLines ?? totalLines
            return perWindowTotal > 0 && sp.overscanStartLine == 0 && sp.overscanEndLine >= perWindowTotal
        }()

        if totalLines > visibleRows && viewportTop != 0xFFFF_FFFF && scrollIndicatorAlpha > 0 {
            let viewportH = Float(viewportSize.height)
            let indicatorWidth: Float = 6.0 * scale
            let indicatorMargin: Float = 2.0 * scale
            let trackHeight = viewportH

            // Compute thumb size and position.
            let proportion = Float(visibleRows) / Float(totalLines)
            let thumbHeight = max(proportion * trackHeight, 20.0 * scale)
            let maxTop = Float(EditorScrollTrack.maxScrollableTop(
                totalLines: totalLines, visibleRows: visibleRows, resident: scrollIndicatorResident))
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

        if let failure = windowContentRenderer?.nativePresentationFailure ?? candidateAtlas.nativePresentationFailure {
            encoder.endEncoding()
            recordNativeFailure(failure, frameSequence: presentationInputSeq,
                                latencyRecorder: latencyRecorder, presentationFrame: presentationFrame)
            return
        }

        // Submit only the offscreen render. The drawable is neither written nor
        // registered for presentation until this command completes successfully.
        encoder.endEncoding()
        do {
            try factories.preSubmit(cmdBuf)
        } catch {
            recordNativeFailure(NativePresentationFailure(
                phase: .submission, dimension: .submission,
                frameSequence: presentationInputSeq, reason: .submission
            ), latencyRecorder: latencyRecorder, presentationFrame: presentationFrame)
            return
        }

        let commitTime = CACurrentMediaTime()
        let generation = presentationGeneration.issue()
        let candidateInstanceSlots = lineInstances.count
        let candidateQuadCapacity = bufferDemand.quadBytesPerBuffer / MemoryLayout<QuadGPU>.stride
        factories.observeCompletion(cmdBuf) { [weak self] completed, status in
            guard let self else { return }
            let completionLatencyMs = (CACurrentMediaTime() - commitTime) * 1000.0
            os_signpost(.event, log: renderLog, name: "GPU Timing", signpostID: renderSignpostID,
                        "commit_to_complete_ms=%{public}.3f", completionLatencyMs)
            guard completed else {
                self.recordNativeFailure(NativePresentationFailure(
                    phase: .completion, dimension: .completion,
                    frameSequence: presentationInputSeq, reason: .completion
                ), discardLatency: false, latencyRecorder: latencyRecorder, presentationFrame: presentationFrame)
                latencyRecorder?.discard(seq: presentationInputSeq, reason: .gpuFailure)
                os_signpost(.event, log: renderLog, name: "PresentationDropped", signpostID: renderSignpostID,
                            "input=%{public}u status=%{public}d", presentationInputSeq, status)
                return
            }
            guard self.configurationEpoch == candidateConfigurationEpoch else {
                latencyRecorder?.discard(seq: presentationInputSeq, reason: .superseded)
                if let presentationFrame {
                    self.presentationMetrics?.discard(
                        domain: .editor, outcome: .superseded, frame: presentationFrame
                    )
                }
                return
            }
            guard let drawable = drawableProvider() else {
                self.recordNativeFailure(NativePresentationFailure(
                    phase: .drawable, dimension: .drawable,
                    frameSequence: presentationInputSeq, reason: .unavailable
                ), latencyRecorder: latencyRecorder, presentationFrame: presentationFrame)
                return
            }
            guard drawable.texture.width == candidateRenderTarget.width else {
                self.recordNativeFailure(NativePresentationFailure(
                    phase: .drawable, dimension: .textureWidth,
                    requested: drawable.texture.width, limit: candidateRenderTarget.width,
                    frameSequence: presentationInputSeq, reason: .mismatch
                ), latencyRecorder: latencyRecorder, presentationFrame: presentationFrame)
                return
            }
            guard drawable.texture.height == candidateRenderTarget.height else {
                self.recordNativeFailure(NativePresentationFailure(
                    phase: .drawable, dimension: .textureHeight,
                    requested: drawable.texture.height, limit: candidateRenderTarget.height,
                    frameSequence: presentationInputSeq, reason: .mismatch
                ), latencyRecorder: latencyRecorder, presentationFrame: presentationFrame)
                return
            }
            guard drawable.texture.pixelFormat == candidateRenderTarget.pixelFormat else {
                self.recordNativeFailure(NativePresentationFailure(
                    phase: .drawable, dimension: .renderTarget,
                    frameSequence: presentationInputSeq, reason: .mismatch
                ), latencyRecorder: latencyRecorder, presentationFrame: presentationFrame)
                return
            }
            guard let presentationBuffer = self.factories.makeCommandBuffer(self.commandQueue) else {
                self.recordNativeFailure(NativePresentationFailure(
                    phase: .command, dimension: .presentationCommandBuffer,
                    frameSequence: presentationInputSeq, reason: .unavailable
                ), latencyRecorder: latencyRecorder, presentationFrame: presentationFrame)
                return
            }
            guard let blit = self.factories.makeBlitEncoder(presentationBuffer) else {
                self.recordNativeFailure(NativePresentationFailure(
                    phase: .command, dimension: .presentationEncoder,
                    frameSequence: presentationInputSeq, reason: .unavailable
                ), latencyRecorder: latencyRecorder, presentationFrame: presentationFrame)
                return
            }
            blit.copy(
                from: candidateRenderTarget,
                sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: candidateRenderTarget.width,
                                    height: candidateRenderTarget.height, depth: 1),
                to: drawable.texture,
                destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
            do {
                try self.factories.prePresentationSubmit(presentationBuffer)
            } catch {
                self.recordNativeFailure(NativePresentationFailure(
                    phase: .submission, dimension: .presentationCopy,
                    frameSequence: presentationInputSeq, reason: .submission
                ), latencyRecorder: latencyRecorder, presentationFrame: presentationFrame)
                return
            }

            self.factories.observeCompletion(presentationBuffer) { [weak self] copied, _ in
                guard let self else { return }
                guard copied else {
                    self.recordNativeFailure(NativePresentationFailure(
                        phase: .completion, dimension: .presentationCopy,
                        frameSequence: presentationInputSeq, reason: .completion
                    ), discardLatency: false, latencyRecorder: latencyRecorder, presentationFrame: presentationFrame)
                    latencyRecorder?.discard(seq: presentationInputSeq, reason: .gpuFailure)
                    return
                }
                guard self.configurationEpoch == candidateConfigurationEpoch,
                      generation > self.presentationGeneration.completed else {
                    latencyRecorder?.discard(seq: presentationInputSeq, reason: .superseded)
                    if let presentationFrame {
                        self.presentationMetrics?.discard(
                            domain: .editor, outcome: .superseded, frame: presentationFrame
                        )
                    }
                    return
                }
                do {
                    try self.factories.present(drawable)
                } catch {
                    self.recordNativeFailure(NativePresentationFailure(
                        phase: .submission, dimension: .drawable,
                        frameSequence: presentationInputSeq, reason: .submission
                    ), latencyRecorder: latencyRecorder, presentationFrame: presentationFrame)
                    return
                }
                guard self.presentationGeneration.complete(generation) else {
                    latencyRecorder?.discard(seq: presentationInputSeq, reason: .superseded)
                    if let presentationFrame {
                        self.presentationMetrics?.discard(
                            domain: .editor, outcome: .superseded, frame: presentationFrame
                        )
                    }
                    return
                }

                self.atlas = candidateAtlas
                self.bitmapRasterizer = candidateRasterizer
                self.windowContentRenderer = candidateWindowRenderer
                self.instanceBuffer = candidateInstanceBuffer
                self.maxInstanceSlots = candidateInstanceSlots
                self.quadBuffers = candidateQuadBuffers
                self.quadBufferCapacity = candidateQuadCapacity
                self.lastCompletedPresentationGeneration = generation
                latencyRecorder?.markPresented(seq: presentationInputSeq)
                if let presentationFrame {
                    self.presentationMetrics?.recordMetalPresented(presentationFrame: presentationFrame)
                }
                os_signpost(.event, log: renderLog, name: "PresentationComplete",
                            signpostID: renderSignpostID,
                            "input=%{public}u", presentationInputSeq)
            }
            presentationBuffer.commit()
            if let presentationFrame {
                self.presentationMetrics?.recordMetalSubmission(presentationFrame: presentationFrame)
            }
            os_signpost(.event, log: renderLog, name: "MetalPresentationSubmit", signpostID: renderSignpostID,
                        "input=%{public}u frame=%{public}u", presentationInputSeq,
                        presentationFrame?.frameSeq ?? 0)
        }
        cmdBuf.commit()
        latencyRecorder?.markSubmitted(seq: presentationInputSeq)
        os_signpost(.event, log: renderLog, name: "MetalSubmit", signpostID: renderSignpostID,
                    "input=%{public}u", presentationInputSeq)
    }

    func activeResourceSnapshot() -> NativeActiveResourceSnapshot {
        NativeActiveResourceSnapshot(
            atlas: atlas.map(ObjectIdentifier.init), allocator: atlas?.allocator,
            texture: atlas?.texture.map(ObjectIdentifier.init),
            windowRenderer: windowContentRenderer.map(ObjectIdentifier.init),
            cache: windowContentRenderer?.cacheSnapshot(),
            rasterizer: bitmapRasterizer.map(ObjectIdentifier.init),
            lineBuffer: instanceBuffer.map(ObjectIdentifier.init),
            quadBuffers: quadBuffers.map(ObjectIdentifier.init),
            completedGeneration: lastCompletedPresentationGeneration
        )
    }

    private func recordNativeFailure(
        _ failure: NativePresentationFailure,
        frameSequence: UInt32? = nil,
        discardLatency: Bool = true,
        latencyRecorder: LatencyRecorder?,
        presentationFrame: GUICommittedFrame? = nil
    ) {
        let recorded = NativePresentationFailure(
            phase: failure.phase,
            dimension: failure.dimension,
            requested: failure.requested,
            limit: failure.limit,
            frameSequence: frameSequence ?? failure.frameSequence,
            reason: failure.reason
        )
        lastNativePresentationFailure = recorded
        factories.reportFailure(recorded)
        if discardLatency {
            latencyRecorder?.discard(seq: recorded.frameSequence, reason: .nativeResourceFailure)
        }
        if let presentationFrame {
            let outcome: GUIFramePresentationMetrics.Outcome =
                recorded.reason == .unavailable ? .unavailable : .failed
            presentationMetrics?.discard(
                domain: .editor, outcome: outcome, frame: presentationFrame
            )
        }
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
        entryRange: Range<Int>,
        overscanBeforeRows: Int,
        atlas: LineTextureAtlas,
        windowRenderer: WindowContentRenderer,
        bgQuads: inout [QuadGPU],
        lineInstances: inout [LineGPU]
    ) {
        let signColWidth = Int(gutter.signColWidth)
        let baseRow = gutter.contentRow
        let baseCol = gutter.contentCol

        let clipTop = Float(gutter.contentRow) * cellH * scale
        let clipBottom = Float(gutter.contentRow + gutter.contentHeight) * cellH * scale

        for rowIndex in entryRange {
            let entry = gutter.entries[rowIndex]
            let presentationRow = rowIndex - entryRange.lowerBound - overscanBeforeRows
            let screenRowInt = Int(baseRow) + presentationRow
            let screenRow = UInt16(clamping: screenRowInt)
            let atlasRow = UInt16(clamping: rowIndex)
            let rowY = (Float(baseRow) + Float(presentationRow)) * cellH * scale - scrollOffsetY
            guard CoreTextMetalRenderer.clipVerticalQuad(y: rowY, height: cellH * scale, top: clipTop, bottom: clipBottom) != nil else { continue }
            let yPos = rowY
            let xOffset = Float(baseCol) * cellW * scale + gutterLeftMarginPx

            // Sign column (leftmost in gutter)
            if signColWidth > 0 {
                renderGutterSign(
                    entry: entry, windowId: gutter.windowId, atlasRow: atlasRow, yPos: yPos, xOffset: xOffset,
                    cellW: cellW, cellH: cellH, scale: scale,
                    frameState: frameState,
                    clipTop: clipTop, clipBottom: clipBottom,
                    atlas: atlas, windowRenderer: windowRenderer,
                    bgQuads: &bgQuads, lineInstances: &lineInstances,
                )
            }

            // Fold indicator (dedicated cell after the diagnostic/git sign column)
            if signColWidth >= 3 {
                appendFoldRangeHighlight(
                    entry: entry, presentationRow: presentationRow, screenRow: screenRow, yPos: yPos,
                    gutter: gutter, xOffset: xOffset,
                    signColWidth: signColWidth,
                    cellW: cellW, cellH: cellH, scale: scale,
                    gutterPaddingPx: gutterPaddingPx,
                    viewportWidthPx: viewportWidthPx,
                    gutterHoverWindowId: gutterHoverWindowId,
                    gutterHoverRow: gutterHoverRow,
                    frameState: frameState,
                    clipTop: clipTop, clipBottom: clipBottom,
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
                    clipTop: clipTop, clipBottom: clipBottom,
                    bgQuads: &bgQuads,
                )
            }

            // Line number (after sign and fold columns)
            if gutter.lineNumberStyle != .none && gutter.lineNumberWidth > 0 && shouldRenderLineNumber(for: entry) {
                renderGutterLineNumber(
                    entry: entry, gutter: gutter,
                    atlasRow: atlasRow, yPos: yPos, xOffset: xOffset,
                    signColWidth: signColWidth,
                    cellW: cellW, cellH: cellH, scale: scale,
                    frameState: frameState,
                    clipTop: clipTop, clipBottom: clipBottom,
                    atlas: atlas, windowRenderer: windowRenderer,
                    lineInstances: &lineInstances,
                )
            }
        }
    }

    private func appendClippedGutterQuad(
        x: Float, y: Float, width: Float, height: Float,
        color: SIMD3<Float>, alpha: Float,
        clipTop: Float, clipBottom: Float,
        quads: inout [QuadGPU]
    ) {
        guard let clipped = CoreTextMetalRenderer.clipVerticalQuad(y: y, height: height, top: clipTop, bottom: clipBottom) else { return }
        var quad = QuadGPU()
        quad.position = SIMD2<Float>(x, clipped.y)
        quad.size = SIMD2<Float>(width, clipped.height)
        quad.color = color
        quad.alpha = alpha
        quads.append(quad)
    }

    private func appendClippedGutterLine(
        x: Float, y: Float, width: Float, height: Float,
        uvOrigin: SIMD2<Float>, uvSize: SIMD2<Float>,
        clipTop: Float, clipBottom: Float,
        lineInstances: inout [LineGPU]
    ) {
        guard let clipped = CoreTextMetalRenderer.clipVerticalQuad(y: y, height: height, top: clipTop, bottom: clipBottom) else { return }
        let topRatio = height > 0 ? (clipped.y - y) / height : 0
        let visibleRatio = height > 0 ? clipped.height / height : 0
        var lineGPU = LineGPU()
        lineGPU.position = SIMD2<Float>(x, clipped.y)
        lineGPU.size = SIMD2<Float>(width, clipped.height)
        lineGPU.uvOrigin = SIMD2<Float>(uvOrigin.x, uvOrigin.y + uvSize.y * topRatio)
        lineGPU.uvSize = SIMD2<Float>(uvSize.x, uvSize.y * visibleRatio)
        lineInstances.append(lineGPU)
    }

    /// Renders a git or diagnostic sign for one gutter row.
    ///
    /// Git signs (added/modified/deleted) are drawn as thin colored bars
    /// using Metal quads. Diagnostic signs (E/W/I/H) are rendered as
    /// CTLine textures in the diagnostic color.
    private func renderGutterSign(
        entry: Wire.GutterEntry, windowId: UInt16, atlasRow: UInt16, yPos: Float, xOffset: Float,
        cellW: Float, cellH: Float, scale: Float,
        frameState: FrameState,
        clipTop: Float, clipBottom: Float,
        atlas: LineTextureAtlas,
        windowRenderer: WindowContentRenderer,
        bgQuads: inout [QuadGPU],
        lineInstances: inout [LineGPU],
    ) {
        switch entry.signType {
        case .gitAdded:
            let gitBarWidth = round(3.0 * scale)
            appendClippedGutterQuad(x: xOffset, y: yPos, width: gitBarWidth, height: cellH * scale, color: gutterSignColor(entry.signType, frameState: frameState), alpha: 1.0, clipTop: clipTop, clipBottom: clipBottom, quads: &bgQuads)

        case .gitModified:
            let gitBarWidth = round(3.0 * scale)
            appendClippedGutterQuad(x: xOffset, y: yPos, width: gitBarWidth, height: cellH * scale, color: gutterSignColor(entry.signType, frameState: frameState), alpha: 1.0, clipTop: clipTop, clipBottom: clipBottom, quads: &bgQuads)

        case .gitDeleted:
            let barHeight = round(2.0 * scale)
            appendClippedGutterQuad(x: xOffset, y: yPos + cellH * scale - barHeight, width: cellW * 2 * scale, height: barHeight, color: gutterSignColor(entry.signType, frameState: frameState), alpha: 1.0, clipTop: clipTop, clipBottom: clipBottom, quads: &bgQuads)

        case .gitRemoved, .diagError, .diagWarning, .diagInfo, .diagHint, .diagAdvisory:
            let (text, fg) = gutterTextSignAndColor(entry.signType, frameState: frameState)
            let cacheKey = AtlasKey.diagnosticSign(windowId: windowId, row: atlasRow)
            let contentHash = gutterContentHash(text: text, fg: fg)
            if let entry = windowRenderer.renderSimpleText(text, fg: fg, bold: true,
                                                 key: cacheKey, contentHash: contentHash, atlas: atlas, metrics: &frameMetrics) {
                let (uvOrigin, uvSize) = atlas.uvForSlot(entry.slotIndex, pixelWidth: entry.pixelWidth)
                appendClippedGutterLine(x: xOffset, y: yPos, width: Float(entry.pixelWidth), height: Float(entry.pixelHeight), uvOrigin: uvOrigin, uvSize: uvSize, clipTop: clipTop, clipBottom: clipBottom, lineInstances: &lineInstances)
            }

        case .annotation:
            // Render annotation icon text with the annotation's custom fg color.
            let text = entry.signText.isEmpty ? "●" : entry.signText
            let fg = entry.signFg
            let cacheKey = AtlasKey.annotationIcon(windowId: windowId, row: atlasRow)
            let contentHash = gutterContentHash(text: text, fg: fg)
            if let atlasEntry = windowRenderer.renderSimpleText(text, fg: fg, bold: false,
                                                      key: cacheKey, contentHash: contentHash, atlas: atlas, metrics: &frameMetrics) {
                let (uvOrigin, uvSize) = atlas.uvForSlot(atlasEntry.slotIndex, pixelWidth: atlasEntry.pixelWidth)
                appendClippedGutterLine(x: xOffset, y: yPos, width: Float(atlasEntry.pixelWidth), height: Float(atlasEntry.pixelHeight), uvOrigin: uvOrigin, uvSize: uvSize, clipTop: clipTop, clipBottom: clipBottom, lineInstances: &lineInstances)
            }

        case .none:
            break
        }
    }

    /// Draws a subtle range highlight while hovering an unfolded fold chevron.
    private func appendFoldRangeHighlight(
        entry: Wire.GutterEntry, presentationRow: Int, screenRow: UInt16, yPos: Float,
        gutter: Wire.WindowGutter, xOffset: Float,
        signColWidth: Int,
        cellW: Float, cellH: Float, scale: Float,
        gutterPaddingPx: Float,
        viewportWidthPx: Float,
        gutterHoverWindowId: UInt16?,
        gutterHoverRow: UInt16?,
        frameState: FrameState,
        clipTop: Float, clipBottom: Float,
        bgQuads: inout [QuadGPU],
    ) {
        guard gutterHoverWindowId == gutter.windowId else { return }
        guard gutterHoverRow == screenRow else { return }
        guard entry.displayType == .foldOpen else { return }
        guard let foldEndLine = entry.foldEndLine, foldEndLine > entry.bufLine else { return }

        let rowsInRange = Int(foldEndLine - entry.bufLine + 1)
        let visibleRows = max(0, min(rowsInRange, Int(gutter.contentHeight) - presentationRow))
        guard visibleRows > 0 else { return }

        let gutterWidth = Float(gutter.lineNumberWidth) + Float(signColWidth)
        let contentX = xOffset + gutterWidth * cellW * scale + gutterPaddingPx
        let windowRightX = (Float(gutter.contentCol) + Float(gutter.contentWidth)) * cellW * scale
        let width = max(0, min(windowRightX, viewportWidthPx) - contentX)
        guard width > 0 else { return }

        appendClippedGutterQuad(x: contentX, y: yPos, width: width, height: Float(visibleRows) * cellH * scale, color: colorFromU24(frameState.gutterColors.foldFg, default: SIMD3<Float>(0.33, 0.33, 0.33)), alpha: 0.10, clipTop: clipTop, clipBottom: clipBottom, quads: &bgQuads)
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
        clipTop: Float, clipBottom: Float,
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
            appendChevronSegment(from: SIMD2<Float>(centerX - half * 0.35, centerY - half), to: SIMD2<Float>(centerX + half * 0.35, centerY), lineWidth: lineWidth, color: color, clipTop: clipTop, clipBottom: clipBottom, quads: &bgQuads)
            appendChevronSegment(from: SIMD2<Float>(centerX + half * 0.35, centerY), to: SIMD2<Float>(centerX - half * 0.35, centerY + half), lineWidth: lineWidth, color: color, clipTop: clipTop, clipBottom: clipBottom, quads: &bgQuads)
        } else {
            appendChevronSegment(from: SIMD2<Float>(centerX - half, centerY - half * 0.25), to: SIMD2<Float>(centerX, centerY + half * 0.45), lineWidth: lineWidth, color: color, clipTop: clipTop, clipBottom: clipBottom, quads: &bgQuads)
            appendChevronSegment(from: SIMD2<Float>(centerX, centerY + half * 0.45), to: SIMD2<Float>(centerX + half, centerY - half * 0.25), lineWidth: lineWidth, color: color, clipTop: clipTop, clipBottom: clipBottom, quads: &bgQuads)
        }
    }

    /// Approximates a diagonal chevron stroke with overlapping square Metal quads.
    private func appendChevronSegment(
        from start: SIMD2<Float>, to end: SIMD2<Float>, lineWidth: Float,
        color: SIMD3<Float>, clipTop: Float, clipBottom: Float, quads: inout [QuadGPU]
    ) {
        let delta = end - start
        let length = max(1.0, sqrt(delta.x * delta.x + delta.y * delta.y))
        let steps = max(2, Int(ceil(length / max(1.0, lineWidth * 0.55))))

        for index in 0...steps {
            let t = Float(index) / Float(steps)
            let point = start + delta * t
            appendClippedGutterQuad(x: CoreTextMetalRenderer.snapToPixel(point.x - lineWidth * 0.5), y: CoreTextMetalRenderer.snapToPixel(point.y - lineWidth * 0.5), width: lineWidth, height: lineWidth, color: color, alpha: 1.0, clipTop: clipTop, clipBottom: clipBottom, quads: &quads)
        }
    }

    private func indentGuideQuadCounts(
        frameState: FrameState, windowContents: [UInt16: GUIWindowContent],
        cellW: Float, displayCellH: Float, scale: Float,
        gutterLeftMarginPx: Float, gutterPaddingPx: Float,
        viewportSize: CGSize, scrollTargetWindowId: UInt16?,
        smoothScrollOffsetPx: SIMD2<Float>
    ) -> [Int] {
        var counts: [Int] = []
        for (_, guideData) in frameState.windowIndentGuides {
            guard !guideData.guideCols.isEmpty,
                  let gutter = frameState.windowGutters[guideData.windowId] else { continue }
            let paneGeometry = windowContents[guideData.windowId]?.paneGeometry
            let fallbackTextCol = UInt16(Int(gutter.contentCol) + Int(gutter.lineNumberWidth)
                                         + Int(gutter.signColWidth))
            let contentLeft = Float(paneGeometry?.textRect.col ?? fallbackTextCol) * cellW * scale
                + gutterLeftMarginPx + gutterPaddingPx
            let bounds = Self.windowHorizontalBounds(
                geometry: paneGeometry, gutter: gutter, frameCols: frameState.cols,
                cellW: cellW, scale: scale, viewportWidth: Float(viewportSize.width)
            )
            let contentRight = bounds.x + bounds.width
            let lineCellH = displayCellH * scale
            let scrollLeft = windowContents[guideData.windowId]?.scrollLeft ?? 0
            let scroll = Self.presentationScrollOffset(
                scrollLeft: scrollLeft,
                scrollOffsetPx: Self.smoothScrollOffset(
                    for: guideData.windowId, targetWindowId: scrollTargetWindowId,
                    scrollOffsetPx: smoothScrollOffsetPx
                )
            )
            let top = Float(paneGeometry?.textRect.row ?? gutter.contentRow) * displayCellH * scale
            let height = Float(max(Int(paneGeometry?.textRect.height ?? gutter.contentHeight), 0)) * lineCellH
            let bottom = min(top + height, Float(viewportSize.height))
            let tabWidth = max(UInt16(guideData.tabWidth), 1)
            var count = 0
            if guideData.lineIndentLevels.isEmpty {
                let baseY = top - scroll.y
                for col in guideData.guideCols {
                    let x = contentLeft - scroll.x + Float(col) * cellW * scale
                    if Self.clipVerticalQuad(y: baseY, height: height, top: top, bottom: bottom) != nil,
                       Self.clipHorizontalRect(x: x, width: scale, left: contentLeft,
                                               right: contentRight) != nil { count += 1 }
                }
            } else {
                for (lineIndex, level) in guideData.lineIndentLevels.enumerated() {
                    let y = top + Float(lineIndex) * lineCellH - scroll.y
                    for col in guideData.guideCols where col / tabWidth < level {
                        let x = contentLeft - scroll.x + Float(col) * cellW * scale
                        if Self.clipVerticalQuad(y: y, height: lineCellH, top: top, bottom: bottom) != nil,
                           Self.clipHorizontalRect(x: x, width: scale, left: contentLeft,
                                                   right: contentRight) != nil { count += 1 }
                    }
                }
            }
            if count > 0 { counts.append(count) }
        }
        return counts
    }

    /// Draws all `quads` in a single instanced draw call backed by the
    /// current frame's reusable quad buffer.
    ///
    /// This replaces the old `setVertexBytes` path, which Metal silently
    /// truncates above 4 KB of inline data (multi-window splits plus overlays
    /// can exceed that and drop quads with no error). The quad data is copied
    /// into the frame's `MTLBuffer` at a 256-byte-aligned offset and bound with
    /// `setVertexBuffer(_:offset:index:)` at the same index 0 the shader reads.
    ///
    /// Callers may invoke this multiple times per frame (bg, semantic overlay,
    /// diagnostic passes); each call advances `quadBufferWriteOffset` so the
    /// passes occupy distinct regions of the buffer and do not clobber each
    /// other when the command buffer executes on the GPU.
    private func drawQuadBatches(_ quads: [QuadGPU], buffer: MTLBuffer?,
                                 writeOffset: inout Int,
                                 encoder: MTLRenderCommandEncoder,
                                 uniforms: inout CTUniformsGPU) {
        guard !quads.isEmpty, let buffer else { return }

        let stride = MemoryLayout<QuadGPU>.stride
        let alignment = Self.quadBufferOffsetAlignment
        let offset = (writeOffset + alignment - 1) / alignment * alignment
        let byteCount = quads.count * stride

        // The aggregate candidate was checked and allocated before encoding.
        // A mismatch is a programming error, never a reason to grow mid-pass.
        precondition(offset + byteCount <= buffer.length)
        _ = quads.withUnsafeBytes { src in
            memcpy(buffer.contents() + offset, src.baseAddress!, byteCount)
        }
        writeOffset = offset + byteCount

        encoder.setVertexBuffer(buffer, offset: offset, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CTUniformsGPU>.size, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: quads.count)
    }

    /// Renders a line number for one gutter row.
    private func renderGutterLineNumber(
        entry: Wire.GutterEntry, gutter: Wire.WindowGutter,
        atlasRow: UInt16, yPos: Float, xOffset: Float,
        signColWidth: Int,
        cellW: Float, cellH: Float, scale: Float,
        frameState: FrameState,
        clipTop: Float, clipBottom: Float,
        atlas: LineTextureAtlas,
        windowRenderer: WindowContentRenderer,
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

        let cacheKey = AtlasKey.gutterLineNumber(windowId: gutter.windowId, row: atlasRow)
        let contentHash = gutterContentHash(text: numberStr, fg: fg)
        if let entry = windowRenderer.renderSimpleText(numberStr, fg: fg,
                                             key: cacheKey, contentHash: contentHash, atlas: atlas, metrics: &frameMetrics) {
            let (uvOrigin, uvSize) = atlas.uvForSlot(entry.slotIndex, pixelWidth: entry.pixelWidth)
            let xPos = xOffset + Float(startCol) * cellW * scale
            appendClippedGutterLine(x: xPos, y: yPos, width: Float(entry.pixelWidth), height: Float(entry.pixelHeight), uvOrigin: uvOrigin, uvSize: uvSize, clipTop: clipTop, clipBottom: clipBottom, lineInstances: &lineInstances)
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
        // Advisory amber, derived from this theme's warning + error colors
        // (mirrors the TUI renderer) so it suits every palette without a
        // dedicated wire color slot.
        case .diagAdvisory:
            return colorFromU24(blendU24(frameState.gutterColors.warningFg, frameState.gutterColors.errorFg), default: .zero)
        case .annotation: return .zero  // Annotation color is per-entry, not from theme
        case .none: return .zero
        }
    }

    /// Midpoint blend of two 24-bit RGB colors. Matches the BEAM TUI renderer's
    /// `blend_rgb/2` so advisory amber looks identical across clients.
    private func blendU24(_ a: UInt32, _ b: UInt32) -> UInt32 {
        let ar = (a >> 16) & 0xFF, ag = (a >> 8) & 0xFF, ab = a & 0xFF
        let br = (b >> 16) & 0xFF, bg = (b >> 8) & 0xFF, bb = b & 0xFF
        return (((ar + br) / 2) << 16) | (((ag + bg) / 2) << 8) | ((ab + bb) / 2)
    }

    /// Returns the sign character and fg color (as U24) for a text-rendered gutter sign.
    private func gutterTextSignAndColor(_ signType: Wire.GutterSignType, frameState: FrameState) -> (String, UInt32) {
        switch signType {
        case .gitRemoved: return ("-", frameState.gutterColors.gitDeletedFg)
        case .diagError: return ("E", frameState.gutterColors.errorFg)
        case .diagWarning: return ("W", frameState.gutterColors.warningFg)
        case .diagInfo: return ("I", frameState.gutterColors.infoFg)
        case .diagHint: return ("H", frameState.gutterColors.hintFg)
        case .diagAdvisory:
            return ("?", blendU24(frameState.gutterColors.warningFg, frameState.gutterColors.errorFg))
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
        let slices = Dictionary(uniqueKeysWithValues: windowContents.values.map { content in
            let fallback = Int(content.paneGeometry?.textRect.height
                ?? frameState.windowGutters[content.windowId]?.contentHeight
                ?? frameState.rows)
            return (content.windowId, RendererSignposts.visibleSlice(for: content, fallbackVisibleRows: fallback))
        })
        return atlasSlotDemand(frameState: frameState, windowContents: windowContents, visibleSlices: slices)
    }

    nonisolated static func atlasSlotDemand(
        frameState: FrameState,
        windowContents: [UInt16: GUIWindowContent],
        preparedRows: [UInt16: ResidentRenderPreparationResult]
    ) -> Int {
        let slices = Dictionary(uniqueKeysWithValues: preparedRows.map { windowID, prepared in
            (windowID, RendererSignposts.rowSlice(for: prepared))
        })
        return atlasSlotDemand(frameState: frameState, windowContents: windowContents, visibleSlices: slices)
    }

    nonisolated static func atlasSlotDemand(
        frameState: FrameState,
        windowContents: [UInt16: GUIWindowContent],
        visibleSlices: [UInt16: RendererRowSlice]
    ) -> Int {
        let bufferRows = visibleSlices.values.reduce(0) { $0 + $1.rows.count }

        let lineAnnotations = windowContents.values.reduce(0 as Int) { total, content in
            guard let slice = visibleSlices[content.windowId] else { return total }
            let fallback = max(slice.rows.count - slice.overscanBeforeRows, 0)
            let paneRows = Int(content.paneGeometry?.textRect.height ?? 0)
            let gutterRows = Int(frameState.windowGutters[content.windowId]?.contentHeight ?? 0)
            let visibleRows = paneRows > 0 ? paneRows : (gutterRows > 0 ? gutterRows : fallback)
            return total + content.lineAnnotations.filter {
                $0.kind != .gutterIcon && Int($0.row) < visibleRows
            }.count
        }

        let gutterTextures = frameState.windowGutters.values.reduce(0 as Int) { total, gutter in
            guard let slice = visibleSlices[gutter.windowId] else { return total }
            return total + gutterTextureDemand(
                gutter,
                range: RendererSignposts.gutterRange(for: gutter, slice: slice)
            )
        }

        let splitLabels = frameState.horizontalSeparators.reduce(0 as Int) { total, separator in
            total + (separator.filename.isEmpty ? 0 : 1)
        }

        let demand = bufferRows + lineAnnotations + gutterTextures + splitLabels
        let slack = max(Int(frameState.rows), 32)
        return max(demand + slack, 1)
    }

    private nonisolated static func gutterTextureDemand(
        _ gutter: Wire.WindowGutter,
        range: Range<Int>
    ) -> Int {
        var demand = 0
        for index in range {
            demand += lineNumberTextureDemand(gutter) + signTextureDemand(gutter.entries[index].signType)
        }
        return demand
    }

    private nonisolated static func lineNumberTextureDemand(_ gutter: Wire.WindowGutter) -> Int {
        if gutter.lineNumberStyle != .none && gutter.lineNumberWidth > 0 {
            return 1
        }

        return 0
    }

    private nonisolated static func signTextureDemand(_ signType: Wire.GutterSignType) -> Int {
        switch signType {
        case .gitRemoved, .diagError, .diagWarning, .diagInfo, .diagHint, .diagAdvisory, .annotation:
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

    nonisolated static func presentationScrollOffset(scrollLeft: UInt16, scrollOffsetPx: SIMD2<Float>) -> SIMD2<Float> {
        let x = scrollLeft == 0 && scrollOffsetPx.x < 0 ? 0 : scrollOffsetPx.x
        return SIMD2<Float>(x, scrollOffsetPx.y)
    }

    nonisolated static func scrollOverscanBefore(_ presentation: GUIScrollPresentation?) -> Int {
        guard let presentation, presentation.visibleStartLine > presentation.overscanStartLine else { return 0 }
        return Int(presentation.visibleStartLine - presentation.overscanStartLine)
    }

    nonisolated static func presentationOverscanBeforeRows(_ content: GUIWindowContent) -> Int {
        guard let presentation = content.scrollPresentation else { return 0 }
        let anchor = content.rowStore.lowerBound(bufferLine: presentation.anchorTop)
        let anchoredVisualOrigin = min(
            anchor + Int(presentation.anchorVisualRowOffset), content.rowStore.count
        )
        if anchoredVisualOrigin < content.rowStore.count { return anchoredVisualOrigin }
        let visible = content.rowStore.lowerBound(bufferLine: presentation.visibleStartLine)
        return visible < content.rowStore.count ? visible : scrollOverscanBefore(presentation)
    }

    nonisolated static func presentationPayloadOverscanBeforeRows(rows: [GUIVisualRow], scrollPresentation: GUIScrollPresentation?) -> Int {
        guard let scrollPresentation else { return 0 }
        let anchor = lowerBound(rows: rows, bufferLine: scrollPresentation.anchorTop)
        let anchoredVisualOrigin = min(anchor + Int(scrollPresentation.anchorVisualRowOffset), rows.count)
        if anchoredVisualOrigin < rows.count { return anchoredVisualOrigin }
        let visible = lowerBound(rows: rows, bufferLine: scrollPresentation.visibleStartLine)
        return visible < rows.count ? visible : scrollOverscanBefore(scrollPresentation)
    }

    private nonisolated static func lowerBound(rows: [GUIVisualRow], bufferLine: UInt32) -> Int {
        var low = 0
        var high = rows.count
        while low < high {
            let middle = (low + high) / 2
            if rows[middle].bufLine < bufferLine { low = middle + 1 } else { high = middle }
        }
        return low
    }

    nonisolated static func gutterChromeRects(
        frameState: FrameState,
        cellW: Float,
        cellH: Float,
        scale: Float,
        gutterLeftMarginPx: Float,
        gutterPaddingPx: Float,
        viewportHeight: Float
    ) -> (leftFills: [(x: Float, y: Float, width: Float, height: Float)], rightFills: [(x: Float, y: Float, width: Float, height: Float)], separators: [(x: Float, y: Float, width: Float, height: Float)]) {
        guard gutterLeftMarginPx > 0 || gutterPaddingPx > 0 || frameState.gutterSeparatorColor != 0 else { return ([], [], []) }
        var leftFills: [(x: Float, y: Float, width: Float, height: Float)] = []
        var rightFills: [(x: Float, y: Float, width: Float, height: Float)] = []
        var separators: [(x: Float, y: Float, width: Float, height: Float)] = []

        if !frameState.windowGutters.isEmpty {
            for gutter in frameState.windowGutters.values.sorted(by: { $0.windowId < $1.windowId }) {
                let gutterWidthCols = Int(gutter.lineNumberWidth) + Int(gutter.signColWidth)
                guard gutterWidthCols > 0 else { continue }
                let top = Float(gutter.contentRow) * cellH * scale
                let height = Float(gutter.contentHeight) * cellH * scale
                guard let vertical = clipVerticalQuad(y: top, height: height, top: 0, bottom: viewportHeight) else { continue }
                let gutterLeftX = Float(gutter.contentCol) * cellW * scale
                if gutterLeftMarginPx > 0 {
                    leftFills.append((x: gutterLeftX, y: vertical.y, width: gutterLeftMarginPx, height: vertical.height))
                }
                let gutterRightX = Float(Int(gutter.contentCol) + gutterWidthCols) * cellW * scale + gutterLeftMarginPx
                if gutterPaddingPx > 0 {
                    rightFills.append((x: gutterRightX, y: vertical.y, width: gutterPaddingPx, height: vertical.height))
                }
                if frameState.gutterSeparatorColor != 0 {
                    separators.append((x: gutterRightX + gutterPaddingPx * 0.5, y: vertical.y, width: 1.0, height: vertical.height))
                }
            }
            return (leftFills, rightFills, separators)
        }

        guard frameState.gutterCol > 0 else { return ([], [], []) }
        if gutterLeftMarginPx > 0 {
            leftFills.append((x: 0, y: 0, width: gutterLeftMarginPx, height: viewportHeight))
        }
        if gutterPaddingPx > 0 {
            rightFills.append((x: Float(frameState.gutterCol) * cellW * scale + gutterLeftMarginPx, y: 0, width: gutterPaddingPx, height: viewportHeight))
        }
        if frameState.gutterSeparatorColor != 0 {
            let gutterRightX = Float(frameState.gutterCol) * cellW * scale + gutterLeftMarginPx
            separators.append((x: gutterRightX + gutterPaddingPx * 0.5, y: 0, width: 1.0, height: viewportHeight))
        }
        return (leftFills, rightFills, separators)
    }

    nonisolated static func gutterChromeQuads(
        frameState: FrameState,
        cellW: Float,
        cellH: Float,
        scale: Float,
        gutterLeftMarginPx: Float,
        gutterPaddingPx: Float,
        viewportHeight: Float,
        defaultBg: SIMD3<Float>,
        separatorColor: SIMD3<Float>
    ) -> [QuadGPU] {
        let rects = gutterChromeRects(
            frameState: frameState,
            cellW: cellW,
            cellH: cellH,
            scale: scale,
            gutterLeftMarginPx: gutterLeftMarginPx,
            gutterPaddingPx: gutterPaddingPx,
            viewportHeight: viewportHeight
        )
        var quads: [QuadGPU] = []
        for rect in rects.leftFills + rects.rightFills {
            var quad = QuadGPU()
            quad.position = SIMD2<Float>(rect.x, rect.y)
            quad.size = SIMD2<Float>(rect.width, rect.height)
            quad.color = defaultBg
            quad.alpha = 1.0
            quads.append(quad)
        }
        for rect in rects.separators {
            var quad = QuadGPU()
            quad.position = SIMD2<Float>(rect.x, rect.y)
            quad.size = SIMD2<Float>(rect.width, rect.height)
            quad.color = separatorColor
            quad.alpha = 1.0
            quads.append(quad)
        }
        return quads
    }

    /// Converts a wire-contract viewport-local display row to its draw origin.
    nonisolated static func viewportLocalRowY(
        localRow: Int,
        origin: Float,
        cellHeight: Float,
        scale: Float
    ) -> Float {
        origin + Float(localRow) * cellHeight * scale
    }

    nonisolated static func committedVisibleRows(paneGeometry: GUIPaneGeometry?, gutter: Wire.WindowGutter, fallback: Int) -> Int {
        if let paneGeometry {
            let rows = Int(paneGeometry.textRect.height)
            if rows > 0 { return rows }
        }
        if gutter.contentHeight > 0 {
            return Int(gutter.contentHeight)
        }
        return fallback
    }

    nonisolated static func paneVerticalBounds(
        for windowId: UInt16?,
        windowContents: [UInt16: GUIWindowContent],
        gutters: [UInt16: Wire.WindowGutter],
        displayCellH: Float,
        scale: Float,
        viewportHeight: Float
    ) -> (top: Float, bottom: Float)? {
        guard let windowId else { return nil }
        if let geometry = windowContents[windowId]?.paneGeometry {
            let top = Float(geometry.textRect.row) * displayCellH * scale
            let rows = max(Int(geometry.textRect.height), 0)
            let bottom = min(top + Float(rows) * displayCellH * scale, viewportHeight)
            return bottom > top ? (top, bottom) : nil
        }
        if let gutter = gutters[windowId] {
            let top = Float(gutter.contentRow) * displayCellH * scale
            let rows = max(Int(gutter.contentHeight), 0)
            let bottom = min(top + Float(rows) * displayCellH * scale, viewportHeight)
            return bottom > top ? (top, bottom) : nil
        }
        return nil
    }

    /// Vertical span (in device pixels) of a window's editor-background fill.
    ///
    /// Fills from the pane's top row down to its bottom. A pane whose bottom row
    /// reaches (or passes) the grid bottom owns the leftover strip down to the
    /// drawable edge, so the remainder below the last text row is painted the
    /// editor background instead of exposing the clear color. This covers both
    /// the raw-cell remainder (view height not a multiple of the cell height) and
    /// the effective-rows remainder (spaced rows * displayCellH < view height).
    /// Interior panes stop at their neighbor's top so split separators and the
    /// agent-panel edge have no band above them.
    ///
    /// - Parameters:
    ///   - paneTopRow: The pane's top text row in grid rows.
    ///   - paneRows: The pane's committed visible rows (spaced grid rows).
    ///   - totalRows: The editor grid's total spaced rows (`frameState.rows`).
    ///   - displayCellH: Spaced cell height in points (`cellH * lineSpacing`).
    ///   - scale: Backing scale factor.
    ///   - viewportHeight: Drawable height in device pixels.
    /// - Returns: The fill's `(top, bottom)` in device pixels, or nil when empty.
    nonisolated static func windowBackgroundFillBounds(
        paneTopRow: Int,
        paneRows: Int,
        totalRows: Int,
        displayCellH: Float,
        scale: Float,
        viewportHeight: Float
    ) -> (top: Float, bottom: Float)? {
        let top = min(Float(max(paneTopRow, 0)) * displayCellH * scale, viewportHeight)
        let paneBottomRow = max(paneTopRow, 0) + max(paneRows, 0)
        let bottom: Float
        if paneBottomRow >= totalRows {
            // Bottom-most pane: absorb the remainder down to the drawable edge.
            bottom = viewportHeight
        } else {
            bottom = min(Float(paneBottomRow) * displayCellH * scale, viewportHeight)
        }
        guard bottom > top else { return nil }
        return (top, bottom)
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

    nonisolated static func cursorHorizontalBounds(
        geometry: GUIPaneGeometry?,
        gutter: Wire.WindowGutter,
        frameCols: UInt16,
        cellW: Float,
        scale: Float,
        gutterLeftMarginPx: Float,
        gutterPaddingPx: Float,
        viewportWidth: Float
    ) -> (x: Float, width: Float) {
        let windowBounds = windowHorizontalBounds(
            geometry: geometry,
            gutter: gutter,
            frameCols: frameCols,
            cellW: cellW,
            scale: scale,
            viewportWidth: viewportWidth
        )
        let fallbackTextCol = UInt16(Int(gutter.contentCol) + Int(gutter.lineNumberWidth) + Int(gutter.signColWidth))
        let textCol = Float(geometry?.textRect.col ?? fallbackTextCol)
        let left = max(windowBounds.x, textCol * cellW * scale + gutterLeftMarginPx + gutterPaddingPx)
        let right = windowBounds.x + windowBounds.width
        return (x: left, width: max(right - left, 0))
    }

    nonisolated static func clipVerticalQuad(y: Float, height: Float, top: Float, bottom: Float) -> (y: Float, height: Float)? {
        let clippedTop = max(y, top)
        let clippedBottom = min(y + height, bottom)
        guard clippedBottom > clippedTop else { return nil }
        return (clippedTop, clippedBottom - clippedTop)
    }

    nonisolated static func clipHorizontalRect(x: Float, width: Float, left: Float, right: Float) -> (x: Float, width: Float)? {
        let clippedLeft = max(x, left)
        let clippedRight = min(x + width, right)
        guard clippedRight > clippedLeft else { return nil }
        return (clippedLeft, clippedRight - clippedLeft)
    }

    nonisolated static func clippedHorizontalLineGPU(
        x: Float,
        y: Float,
        width: Float,
        height: Float,
        uvOrigin: SIMD2<Float>,
        uvSize: SIMD2<Float>,
        clipLeft: Float,
        clipRight: Float
    ) -> LineGPU? {
        guard width > 0, let clipped = clipHorizontalRect(x: x, width: width, left: clipLeft, right: clipRight) else { return nil }
        let clippedLeftPx = clipped.x - x
        let visibleRatio = clipped.width / width
        let leftRatio = clippedLeftPx / width
        var lineGPU = LineGPU()
        lineGPU.position = SIMD2<Float>(clipped.x, y)
        lineGPU.size = SIMD2<Float>(clipped.width, height)
        lineGPU.uvOrigin = SIMD2<Float>(uvOrigin.x + uvSize.x * leftRatio, uvOrigin.y)
        lineGPU.uvSize = SIMD2<Float>(uvSize.x * visibleRatio, uvSize.y)
        return lineGPU
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
            let y = viewportLocalRowY(
                localRow: Int(content.cursorRow),
                origin: Float(textRow) * displayCellH * scale,
                cellHeight: displayCellH,
                scale: scale
            )
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
        let rowIndex = Int(content.cursorRow) + presentationOverscanBeforeRows(content)
        guard rowIndex >= 0, let row = content.rowStore.row(at: rowIndex) else { return content.cursorCol }

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
        clipLeft: Float,
        clipTop: Float,
        clipBottom: Float,
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

        switch sel.type {
        case .line:
            let fullLineWidthPx = max(viewportWidth - clipLeft, 0)
            guard fullLineWidthPx > 0 else { return }
            for row in startRow...endRow {
                let y = rowOffset + Float(row) * lineHeightPx
                guard let clipped = CoreTextMetalRenderer.clipVerticalQuad(y: y, height: lineHeightPx, top: clipTop, bottom: clipBottom) else { continue }
                var quad = QuadGPU()
                quad.position = SIMD2<Float>(clipLeft, clipped.y)
                quad.size = SIMD2<Float>(fullLineWidthPx, clipped.height)
                quad.color = selColor
                quad.alpha = 1.0
                quads.append(quad)
            }

        case .char:
            for row in startRow...endRow {
                let y = Self.viewportLocalRowY(
                    localRow: row, origin: rowOffset, cellHeight: cellH, scale: scale
                )
                let requestedCols = requestedSelectionCols(row: row, sel: sel, scrollLeft: scrollLeft, visibleCols: visibleCols)
                guard let clampedCols = clampSelectionCols(requestedCols, scrollLeft: scrollLeft, visibleCols: visibleCols) else { continue }

                let visibleStartCol = Float(clampedCols.start - scrollLeft)
                let visibleEndCol = Float(clampedCols.end - scrollLeft)
                let rawX = colOffset + visibleStartCol * colWidthPx
                let rawRight = colOffset + visibleEndCol * colWidthPx
                let x = max(rawX, clipLeft)
                let right = min(rawRight, viewportWidth)
                guard right > x,
                      let clipped = CoreTextMetalRenderer.clipVerticalQuad(y: y, height: lineHeightPx, top: clipTop, bottom: clipBottom) else { continue }

                var quad = QuadGPU()
                quad.position = SIMD2<Float>(x, clipped.y)
                quad.size = SIMD2<Float>(right - x, clipped.height)
                quad.color = selColor
                quad.alpha = 1.0
                quads.append(quad)
            }

        case .block:
            for row in startRow...endRow {
                let y = Self.viewportLocalRowY(
                    localRow: row, origin: rowOffset, cellHeight: cellH, scale: scale
                )
                let requestedCols = (start: Int(sel.startCol), end: Int(sel.endCol))
                guard let clampedCols = clampSelectionCols(requestedCols, scrollLeft: scrollLeft, visibleCols: visibleCols) else { continue }

                let visibleStartCol = Float(clampedCols.start - scrollLeft)
                let visibleEndCol = Float(clampedCols.end - scrollLeft)
                let rawX = colOffset + visibleStartCol * colWidthPx
                let rawRight = colOffset + visibleEndCol * colWidthPx
                let x = max(rawX, clipLeft)
                let right = min(rawRight, viewportWidth)
                guard right > x,
                      let clipped = CoreTextMetalRenderer.clipVerticalQuad(y: y, height: lineHeightPx, top: clipTop, bottom: clipBottom) else { continue }

                var quad = QuadGPU()
                quad.position = SIMD2<Float>(x, clipped.y)
                quad.size = SIMD2<Float>(right - x, clipped.height)
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
