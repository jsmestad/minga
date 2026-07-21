import Foundation
import Metal
import MingaProtocol
@testable import MingaUI
import QuartzCore
import Testing

/// Temporal offscreen Metal acceptance tests (Minga issue #2999).
///
/// These exercise the production presentation path
/// `CoreTextMetalRenderer.render(snapshot:..., drawableProvider:, onPresented:)`
/// (via the `render(frameState:...)` fixture wrapper in
/// RendererSnapshotTestSupport) against real GPU work, then read the
/// drawable-copy-completed pixels through `OffscreenReadback`. Completion is always
/// awaited asynchronously via `addCompletedHandler`; nothing here blocks the
/// main actor, spins a run loop, sleeps, or uses a semaphore.
///
/// Live-resize crop cannot be proven at the direct-renderer pixel layer here:
/// the renderer receives an already-committed snapshot and cannot observe the
/// AppKit live-resize gesture that produces a transient crop. That state-machine
/// behaviour is covered by LiveResizeDebounceTests; we deliberately do not fake
/// a pixel test for it.
@Suite("Temporal offscreen Metal rendering", .serialized)
struct TemporalOffscreenMetalTests {
    // Saturated, well-separated background colors make robust A/B regions.
    private static let colorA: UInt32 = 0xE0_10_10 // saturated red
    private static let colorB: UInt32 = 0x10_10_E0 // saturated blue
    private static let neutral: UInt32 = 0x20_20_20 // neutral clear/background

    private static func expectedColor(_ rgb24: UInt32) -> PixelColor {
        PixelColor(
            r: Double((rgb24 >> 16) & 0xFF) / 255.0,
            g: Double((rgb24 >> 8) & 0xFF) / 255.0,
            b: Double(rgb24 & 0xFF) / 255.0,
            a: 1.0
        )
    }

    @MainActor private func nativeTestFactories() -> NativeRenderFactories {
        var factories = NativeRenderFactories.production
        factories.makeLibrary = { device in
            Bundle.allBundles.lazy.compactMap { try? device.makeDefaultLibrary(bundle: $0) }.first
        }
        return factories
    }

    @MainActor
    private func makeRenderer(factories: NativeRenderFactories,
                             fontManager: FontManager) -> CoreTextMetalRenderer? {
        guard let renderer = CoreTextMetalRenderer(factories: factories) else { return nil }
        renderer.setupRenderers(fontManager: fontManager)
        return renderer
    }

    /// Full-width row of `text` painted with a single saturated background span,
    /// so the content area for that row reads back as `bg`.
    private func bandRow(rowId: UInt64, text: String, bg: UInt32) -> GUIVisualRow {
        let span = GUIHighlightSpan(
            startCol: 0, endCol: UInt16(text.count),
            fg: bg, bg: 0, attrs: 0, fontWeight: 0, fontId: 0
        )
        return GUIVisualRow(rowType: .normal, rowId: rowId, bufLine: UInt32(rowId),
                            contentHash: UInt32(truncatingIfNeeded: rowId &* 2_654_435_761),
                            text: text, spans: [span])
    }

    private func windowWithGutter(windowId: UInt16, rows: [GUIVisualRow],
                                  scrollLeft: UInt16 = 0) throws -> GUIWindowContent {
        try GUIWindowContent(
            windowId: windowId, fullRefresh: true, cursorRow: 0, cursorCol: 0,
            cursorShape: .block, scrollLeft: scrollLeft, rows: rows, selection: nil,
            searchMatches: [], diagnosticUnderlines: [], documentHighlights: []
        )
    }

    private func gutter(windowId: UInt16, cols: UInt16, rows: UInt16,
                        lineNumberWidth: UInt8 = 4) -> Wire.WindowGutter {
        let entries = (0..<Int(rows)).map { i in
            Wire.GutterEntry(bufLine: UInt32(i), displayType: .normal, signType: .none)
        }
        return Wire.WindowGutter(
            windowId: windowId, contentRow: 0, contentCol: 0,
            contentHeight: rows, isActive: true, contentWidth: cols,
            cursorLine: 0, lineNumberStyle: .absolute,
            lineNumberWidth: lineNumberWidth, signColWidth: 1, entries: entries
        )
    }

    private func requireDevice() -> (MTLDevice, MTLCommandQueue)? {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            Issue.record("A Metal device and command queue are required for temporal offscreen pixel acceptance tests; none available in this environment")
            return nil
        }
        return (device, queue)
    }

    // MARK: 1. Sequence of production frames: every drawable-copy-completed frame is nonblank
    // with occupied gutter/line-number columns.

    @Test("local-scroll and settle-offset frames each present nonblank content with gutter occupancy")
    @MainActor
    func scrollAndSettleSequenceIsNonblankWithGutter() async throws {
        guard let (device, queue) = requireDevice() else { return }
        let fontManager = FontManager(name: "Menlo", size: 13, scale: 1)
        let waiter = PresentationWaiter()
        var factories = nativeTestFactories()
        factories.reportFailure = { waiter.fail($0) }
        guard let renderer = makeRenderer(factories: factories, fontManager: fontManager) else {
            Issue.record("renderer unavailable"); return
        }

        let cols: UInt16 = 24, rowCount: UInt16 = 8
        let cellW = Float(fontManager.cellWidth)
        let cellH = Float(fontManager.cellHeight)
        let width = Int((Float(cols) * cellW).rounded(.up)) + 16
        let height = Int((Float(rowCount) * cellH).rounded(.up)) + 8

        var frameState = FrameState(cols: cols, rows: rowCount)
        frameState.defaultBg = Self.neutral
        frameState.gutterColors = GutterThemeColors()
        frameState.totalLineCount = UInt32(rowCount)
        frameState.windowGutters[1] = gutter(windowId: 1, cols: cols, rows: rowCount)

        let text = String(repeating: "M", count: Int(cols))
        let rows = (0..<Int(rowCount)).map { bandRow(rowId: UInt64($0), text: text, bg: Self.colorA) }
        let content = try windowWithGutter(windowId: 1, rows: rows)

        // base frame, precise local-scroll frame, settle-offset frame
        let offsets: [SIMD2<Float>] = [.zero, SIMD2<Float>(0, 6), SIMD2<Float>(0, 2.5)]
        let neutralColor = Self.expectedColor(Self.neutral)
        let gutterPixelWidth = Int((Float(4 + 1) * cellW).rounded(.up))

        for (index, offset) in offsets.enumerated() {
            waiter.reset()
            guard let texture = OffscreenReadback.makeDrawableTexture(device: device, width: width, height: height) else {
                Issue.record("drawable texture allocation failed"); return
            }
            let drawable = ReadbackDrawable(texture: texture, drawableID: index + 1)

            let outcome = await waiter.awaitOutcome {
                renderer.render(
                    frameState: frameState, fontManager: fontManager,
                    windowContents: [1: content],
                    drawableProvider: { drawable },
                    viewportSize: CGSize(width: width, height: height),
                    contentScale: 1, scrollOffset: offset,
                    presentationWindowId: 1, presentationInputSeq: UInt32(index + 1),
                    onPresented: { waiter.succeed($0) }
                )
            }
            guard case .presented = outcome else {
                Issue.record("frame \(index) did not present: \(outcome)"); continue
            }
            guard let image = await OffscreenReadback.read(texture: texture, queue: queue) else {
                Issue.record("readback failed for frame \(index)"); continue
            }

            // Content region (to the right of the gutter) must be non-blank:
            // the saturated band must clearly dominate over the neutral clear.
            let contentColor = Self.expectedColor(Self.colorA)
            let contentPixels = image.occupancy(
                x0: gutterPixelWidth + 2, y0: 1, x1: width - 1, y1: Int(cellH),
                differingFrom: neutralColor, thresholdSquared: 0.02
            )
            #expect(contentPixels > 0, "frame \(index) content region is blank")
            let classifiedContent = image.classifyAB(
                x0: gutterPixelWidth + 2, y0: 0, x1: width - 1, y1: Int(cellH),
                a: contentColor, b: neutralColor, ambiguousBand: 0.01
            )
            #expect(classifiedContent.a > 0, "frame \(index) content row has no saturated text pixels")

            // Gutter/line-number occupancy: glyph pixels must appear in the
            // gutter columns (digits painted over the background).
            let gutterOccupancy = image.occupancy(
                x0: 0, y0: 0, x1: gutterPixelWidth, y1: height,
                differingFrom: neutralColor, thresholdSquared: 0.02
            )
            #expect(gutterOccupancy > 0, "frame \(index) gutter has no line-number occupancy")
        }
    }

    @Test("scrollbar track masks editor glyphs beneath the thumb overlay")
    @MainActor
    func scrollbarTrackMasksEditorContent() async throws {
        guard let (device, queue) = requireDevice() else { return }
        let fontManager = FontManager(name: "Menlo", size: 13, scale: 1)
        let waiter = PresentationWaiter()
        var factories = nativeTestFactories()
        factories.reportFailure = { waiter.fail($0) }
        guard let renderer = makeRenderer(factories: factories, fontManager: fontManager) else {
            Issue.record("renderer unavailable"); return
        }
        renderer.scrollIndicatorAlpha = 1

        let cols: UInt16 = 24, rowCount: UInt16 = 8
        let cellW = Float(fontManager.cellWidth)
        let cellH = Float(fontManager.cellHeight)
        let width = Int((Float(cols) * cellW).rounded(.up))
        let height = Int((Float(rowCount) * cellH).rounded(.up)) + 8

        var frameState = FrameState(cols: cols, rows: rowCount)
        frameState.defaultBg = Self.neutral
        frameState.totalLineCount = 100
        frameState.viewportTopLine = 50
        frameState.windowGutters[1] = gutter(windowId: 1, cols: cols, rows: rowCount, lineNumberWidth: 0)

        let text = String(repeating: "M", count: Int(cols))
        let rows = (0..<Int(rowCount)).map { bandRow(rowId: UInt64($0), text: text, bg: Self.colorA) }
        let content = try windowWithGutter(windowId: 1, rows: rows)
        guard let texture = OffscreenReadback.makeDrawableTexture(device: device, width: width, height: height) else {
            Issue.record("drawable texture allocation failed"); return
        }
        let drawable = ReadbackDrawable(texture: texture)
        let outcome = await waiter.awaitOutcome {
            renderer.render(
                frameState: frameState, fontManager: fontManager,
                windowContents: [1: content], drawableProvider: { drawable },
                viewportSize: CGSize(width: width, height: height), contentScale: 1,
                scrollOffset: .zero, presentationWindowId: 1, presentationInputSeq: 100,
                onPresented: { waiter.succeed($0) }
            )
        }
        guard case .presented = outcome,
              let image = await OffscreenReadback.read(texture: texture, queue: queue) else {
            Issue.record("scrollbar frame did not present"); return
        }

        let sampleY = 4
        let trackColor = Self.expectedColor(Self.neutral)
        let contentOccupancy = image.occupancy(
            x0: max(0, width - 32), y0: sampleY, x1: max(1, width - 12), y1: min(height, sampleY + Int(cellH)),
            differingFrom: trackColor, thresholdSquared: 0.02
        )
        #expect(contentOccupancy > 0, "content immediately beside the scrollbar track is blank")
        #expect(image.pixel(x: width - 5, y: sampleY).rgbDistanceSquared(to: trackColor) < 0.02,
                "editor content bled through the opaque scrollbar track")

        renderer.scrollIndicatorAlpha = 0.5
        waiter.reset()
        guard let fadedTexture = OffscreenReadback.makeDrawableTexture(device: device, width: width, height: height) else {
            Issue.record("faded drawable texture allocation failed"); return
        }
        let fadedDrawable = ReadbackDrawable(texture: fadedTexture, drawableID: 2)
        let fadedOutcome = await waiter.awaitOutcome {
            renderer.render(
                frameState: frameState, fontManager: fontManager,
                windowContents: [1: content], drawableProvider: { fadedDrawable },
                viewportSize: CGSize(width: width, height: height), contentScale: 1,
                scrollOffset: .zero, presentationWindowId: 1, presentationInputSeq: 101,
                onPresented: { waiter.succeed($0) }
            )
        }
        guard case .presented = fadedOutcome,
              let fadedImage = await OffscreenReadback.read(texture: fadedTexture, queue: queue) else {
            Issue.record("faded scrollbar frame did not complete"); return
        }
        #expect(fadedImage.pixel(x: width - 5, y: sampleY)
            .rgbDistanceSquared(to: image.pixel(x: width - 5, y: sampleY)) > 0.001,
            "scrollbar track did not fade with the thumb")
    }

    // MARK: 2. Out-of-order A/B completion — pixels are wholly A or wholly B,
    // identity matches pixels, and a late older completion cannot promote.

    @Test("out-of-order A/B completion presents the winner wholly and never promotes the late older frame")
    @MainActor
    func outOfOrderABCompletionIsCoherent() async throws {
        guard let (device, queue) = requireDevice() else { return }
        let fontManager = FontManager(name: "Menlo", size: 13, scale: 1)

        let width = 64, height = 64
        let coordinator = QueuedCompletionCoordinator()
        var presentedDrawables: [Int] = []
        var factories = nativeTestFactories()
        factories.observeCompletion = { coordinator.observeCompletion($0, $1) }
        factories.present = { drawable in
            if let d = drawable as? ReadbackDrawable { presentedDrawables.append(d.drawableID) }
        }
        guard let renderer = makeRenderer(factories: factories, fontManager: fontManager) else {
            Issue.record("renderer unavailable"); return
        }

        func emptyFrame(_ bg: UInt32) -> FrameState {
            var fs = FrameState(cols: 4, rows: 4)
            fs.defaultBg = bg
            return fs
        }
        guard let textureA = OffscreenReadback.makeDrawableTexture(device: device, width: width, height: height),
              let textureB = OffscreenReadback.makeDrawableTexture(device: device, width: width, height: height) else {
            Issue.record("drawable texture allocation failed"); return
        }
        let drawableA = ReadbackDrawable(texture: textureA, drawableID: 1) // older generation
        let drawableB = ReadbackDrawable(texture: textureB, drawableID: 2) // newer generation

        var presentedSnapshotA: CommittedEditorSnapshot?
        var presentedSnapshotB: CommittedEditorSnapshot?

        // Submit A (gen 1) then B (gen 2). GPU runs both; completions are queued.
        renderer.render(
            frameState: emptyFrame(Self.colorA), fontManager: fontManager,
            drawableProvider: { drawableA },
            viewportSize: CGSize(width: width, height: height), contentScale: 1,
            presentationInputSeq: 1,
            onPresented: { presentedSnapshotA = $0 }
        )
        renderer.render(
            frameState: emptyFrame(Self.colorB), fontManager: fontManager,
            drawableProvider: { drawableB },
            viewportSize: CGSize(width: width, height: height), contentScale: 1,
            presentationInputSeq: 2,
            onPresented: { presentedSnapshotB = $0 }
        )

        // Stage 1: both offscreen renders complete (order irrelevant). Flush both
        // to submit the presentation-copy blits.
        await coordinator.waitForPending(2)
        coordinator.flushFirst()
        coordinator.flushFirst()

        // Stage 2: both presentation copies complete. Promote the NEWER frame (B)
        // first, then deliver the older frame (A) late — it must be superseded.
        await coordinator.waitForPending(2)
        coordinator.flushLast() // serial command-queue completion order is A then B, so deliver B first
        coordinator.flushFirst()

        // B is the newer generation; regardless of copy completion order the
        // generation gate guarantees only B promotes and presents.
        #expect(presentedSnapshotB != nil, "newer frame B never presented")
        #expect(presentedSnapshotA == nil, "older frame A promoted after a newer generation completed")
        #expect(presentedDrawables == [2], "only the newer drawable B may present; got \(presentedDrawables)")

        // Identity ↔ pixels: the presented snapshot is B, and B's drawable is wholly B.
        #expect(presentedSnapshotB?.frameState.defaultBg == Self.colorB)
        guard let imageB = await OffscreenReadback.read(texture: textureB, queue: queue) else {
            Issue.record("readback failed for B"); return
        }
        let ab = imageB.classifyAB(x0: 0, y0: 0, x1: width, y1: height,
                                   a: Self.expectedColor(Self.colorA),
                                   b: Self.expectedColor(Self.colorB),
                                   ambiguousBand: 0.01)
        #expect(ab.b > 0, "winner drawable has no B pixels")
        #expect(ab.a == 0, "winner drawable contains A pixels — hybrid frame")

        // The superseded drawable A received its own clean blit (wholly A),
        // proving frames never blend into a hybrid surface even out of order.
        guard let imageA = await OffscreenReadback.read(texture: textureA, queue: queue) else {
            Issue.record("readback failed for A"); return
        }
        let abA = imageA.classifyAB(x0: 0, y0: 0, x1: width, y1: height,
                                    a: Self.expectedColor(Self.colorA),
                                    b: Self.expectedColor(Self.colorB),
                                    ambiguousBand: 0.01)
        #expect(abA.a > 0, "superseded drawable A has no A pixels")
        #expect(abA.b == 0, "superseded drawable A contains B pixels — hybrid frame")
    }

    // MARK: 3. Split panes — saturated colors stay inside each pane's clip
    // rectangle and pane row bands align vertically within one device pixel.

    @Test("split pane saturated colors stay within each pane clip and rows align within one device pixel")
    @MainActor
    func splitPanesClipAndAlign() async throws {
        guard let (device, queue) = requireDevice() else { return }
        let fontManager = FontManager(name: "Menlo", size: 13, scale: 1)

        let cellW = Float(fontManager.cellWidth)
        let cellH = Float(fontManager.cellHeight)
        let leftCols: UInt16 = 16, rightCols: UInt16 = 16, rowCount: UInt16 = 6
        let totalCols = leftCols + rightCols
        let width = Int((Float(totalCols) * cellW).rounded(.up)) + 8
        let height = Int((Float(rowCount) * cellH).rounded(.up)) + 4
        let splitX = Int((Float(leftCols) * cellW).rounded())

        var frameState = FrameState(cols: totalCols, rows: rowCount)
        frameState.defaultBg = Self.neutral
        frameState.totalLineCount = UInt32(rowCount)

        // Left pane window (id 1) at col 0; right pane window (id 2) at leftCols.
        frameState.windowGutters[1] = Wire.WindowGutter(
            windowId: 1, contentRow: 0, contentCol: 0, contentHeight: rowCount,
            isActive: true, contentWidth: leftCols, cursorLine: 0,
            lineNumberStyle: .absolute, lineNumberWidth: 0, signColWidth: 0, entries: []
        )
        frameState.windowGutters[2] = Wire.WindowGutter(
            windowId: 2, contentRow: 0, contentCol: leftCols, contentHeight: rowCount,
            isActive: false, contentWidth: rightCols, cursorLine: 0,
            lineNumberStyle: .absolute, lineNumberWidth: 0, signColWidth: 0, entries: []
        )

        let leftText = String(repeating: "M", count: Int(leftCols))
        let rightText = String(repeating: "M", count: Int(rightCols))
        let leftRows = (0..<Int(rowCount)).map { bandRow(rowId: UInt64($0), text: leftText, bg: Self.colorA) }
        let rightRows = (0..<Int(rowCount)).map { bandRow(rowId: UInt64(100 + $0), text: rightText, bg: Self.colorB) }
        let leftContent = try windowWithGutter(windowId: 1, rows: leftRows)
        let rightContent = try windowWithGutter(windowId: 2, rows: rightRows)

        let waiter = PresentationWaiter()
        var factories = nativeTestFactories()
        factories.reportFailure = { waiter.fail($0) }
        guard let renderer = makeRenderer(factories: factories, fontManager: fontManager) else {
            Issue.record("renderer unavailable"); return
        }
        guard let texture = OffscreenReadback.makeDrawableTexture(device: device, width: width, height: height) else {
            Issue.record("drawable texture allocation failed"); return
        }
        let drawable = ReadbackDrawable(texture: texture)

        let outcome = await waiter.awaitOutcome {
            renderer.render(
                frameState: frameState, fontManager: fontManager,
                windowContents: [1: leftContent, 2: rightContent],
                drawableProvider: { drawable },
                viewportSize: CGSize(width: width, height: height), contentScale: 1,
                onPresented: { waiter.succeed($0) }
            )
        }
        guard case .presented = outcome else { Issue.record("split frame did not present: \(outcome)"); return }
        guard let image = await OffscreenReadback.read(texture: texture, queue: queue) else {
            Issue.record("readback failed"); return
        }

        let a = Self.expectedColor(Self.colorA)
        let b = Self.expectedColor(Self.colorB)
        let yMid = Int(cellH / 2)

        // Color A must be confined to the left of the split; B to the right.
        let paneBottom = Int(Float(rowCount) * cellH)
        let leftA = image.matching(x0: 1, y0: 0, x1: splitX - 2, y1: paneBottom, reference: a, thresholdSquared: 0.02)
        let leftB = image.matching(x0: 1, y0: 0, x1: splitX - 2, y1: paneBottom, reference: b, thresholdSquared: 0.02)
        #expect(leftA > 0, "left pane has no A pixels")
        #expect(leftB == 0, "B color leaked into the left pane clip rect")
        let rightB = image.matching(x0: splitX + 2, y0: 0, x1: width - 1, y1: paneBottom, reference: b, thresholdSquared: 0.02)
        let rightA = image.matching(x0: splitX + 2, y0: 0, x1: width - 1, y1: paneBottom, reference: a, thresholdSquared: 0.02)
        #expect(rightB > 0, "right pane has no B pixels")
        #expect(rightA == 0, "A color leaked into the right pane clip rect")

        // Row-band top edges must align vertically across panes within 1 device px.
        func firstBandTop(x0: Int, x1: Int, reference: PixelColor) -> Int? {
            var y = 0
            while y < height {
                if image.matching(x0: x0, y0: y, x1: x1, y1: y + 1, reference: reference, thresholdSquared: 0.02) > 0 {
                    return y
                }
                y += 1
            }
            return nil
        }
        let leftTop = firstBandTop(x0: 1, x1: splitX - 2, reference: a)
        let rightTop = firstBandTop(x0: splitX + 2, x1: width - 1, reference: b)
        _ = yMid
        if let lt = leftTop, let rt = rightTop {
            #expect(abs(lt - rt) <= 1, "pane row bands misaligned: left top \(lt) vs right top \(rt)")
        } else {
            Issue.record("could not locate a row band in one of the panes (left: \(String(describing: leftTop)), right: \(String(describing: rightTop)))")
        }
    }

    // MARK: 4. Cursor blink toggles only the cursor ROI.

    @Test("cursor blink toggles only the cursor region of interest")
    @MainActor
    func cursorBlinkTogglesOnlyCursorROI() async throws {
        guard let (device, queue) = requireDevice() else { return }
        let fontManager = FontManager(name: "Menlo", size: 13, scale: 1)

        let cellW = Float(fontManager.cellWidth)
        let cellH = Float(fontManager.cellHeight)
        let cols: UInt16 = 20, rowCount: UInt16 = 6
        let width = Int((Float(cols) * cellW).rounded(.up)) + 8
        let height = Int((Float(rowCount) * cellH).rounded(.up)) + 4

        var frameState = FrameState(cols: cols, rows: rowCount)
        frameState.defaultBg = Self.neutral
        frameState.cursorRow = 2
        frameState.cursorCol = 3
        frameState.cursorShape = .block
        frameState.totalLineCount = UInt32(rowCount)
        frameState.windowGutters[1] = Wire.WindowGutter(
            windowId: 1, contentRow: 0, contentCol: 0, contentHeight: rowCount,
            isActive: true, contentWidth: cols, cursorLine: 2,
            lineNumberStyle: .absolute, lineNumberWidth: 0, signColWidth: 0, entries: []
        )
        let text = String(repeating: " ", count: Int(cols))
        let rows = (0..<Int(rowCount)).map { bandRow(rowId: UInt64($0), text: text, bg: Self.neutral) }
        let content = try GUIWindowContent(
            windowId: 1, fullRefresh: true, cursorVisible: true, cursorRow: 2, cursorCol: 3,
            cursorShape: .block, rows: rows, selection: nil, searchMatches: [],
            diagnosticUnderlines: [], documentHighlights: []
        )

        let waiter = PresentationWaiter()
        var factories = nativeTestFactories()
        factories.reportFailure = { waiter.fail($0) }
        guard let renderer = makeRenderer(factories: factories, fontManager: fontManager) else {
            Issue.record("renderer unavailable"); return
        }

        func renderFrame(cursorVisible: Bool, seq: UInt32) async -> ReadbackImage? {
            waiter.reset()
            guard let texture = OffscreenReadback.makeDrawableTexture(device: device, width: width, height: height) else { return nil }
            let drawable = ReadbackDrawable(texture: texture, drawableID: Int(seq))
            let outcome = await waiter.awaitOutcome {
                renderer.render(
                    frameState: frameState, fontManager: fontManager,
                    cursorBlinkVisible: cursorVisible, windowContents: [1: content],
                    drawableProvider: { drawable },
                    viewportSize: CGSize(width: width, height: height), contentScale: 1,
                    presentationWindowId: 1, presentationInputSeq: seq,
                    onPresented: { waiter.succeed($0) }
                )
            }
            guard case .presented = outcome else {
                Issue.record("cursor frame (visible=\(cursorVisible)) did not present: \(outcome)")
                return nil
            }
            return await OffscreenReadback.read(texture: texture, queue: queue)
        }

        guard let onImage = await renderFrame(cursorVisible: true, seq: 1),
              let offImage = await renderFrame(cursorVisible: false, seq: 2) else { return }

        // Cursor ROI around (row 2, col 3).
        let roiX0 = Int((Float(3) * cellW).rounded()) - 1
        let roiX1 = Int((Float(4) * cellW).rounded()) + 1
        let roiY0 = Int((Float(2) * cellH).rounded()) - 1
        let roiY1 = Int((Float(3) * cellH).rounded()) + 1

        // Inside the ROI, the two frames must differ (cursor drawn vs not).
        var roiDiffers = false
        var y = max(0, roiY0)
        while y < min(height, roiY1) && !roiDiffers {
            var x = max(0, roiX0)
            while x < min(width, roiX1) {
                if onImage.pixel(x: x, y: y).rgbDistanceSquared(to: offImage.pixel(x: x, y: y)) > 0.01 {
                    roiDiffers = true; break
                }
                x += 1
            }
            y += 1
        }
        #expect(roiDiffers, "cursor ROI did not change between blink-on and blink-off frames")

        // Outside the ROI, the two frames must be identical (blink is local).
        var outsideDiffCount = 0
        y = 0
        while y < height {
            var x = 0
            while x < width {
                let inRoi = x >= roiX0 && x < roiX1 && y >= roiY0 && y < roiY1
                if !inRoi {
                    if onImage.pixel(x: x, y: y).rgbDistanceSquared(to: offImage.pixel(x: x, y: y)) > 0.01 {
                        outsideDiffCount += 1
                    }
                }
                x += 1
            }
            y += 1
        }
        #expect(outsideDiffCount == 0, "blink changed \(outsideDiffCount) pixels outside the cursor ROI")
    }

    // MARK: 5. Failure preservation + recovery — a nil drawable preserves the
    // last good presented pixels and snapshot; a later valid frame recovers.

    @Test("nil drawable preserves last good pixels and snapshot, then a valid frame recovers")
    @MainActor
    func nilDrawablePreservesThenRecovers() async throws {
        guard let (device, queue) = requireDevice() else { return }
        let fontManager = FontManager(name: "Menlo", size: 13, scale: 1)

        let width = 64, height = 64
        // A single renderer preserves last-good state across frames; its
        // reportFailure is routed through a mutable sink the test retargets.
        final class FailureSink { var handler: (@MainActor (NativePresentationFailure) -> Void)? }
        let sink = FailureSink()
        var factories = nativeTestFactories()
        factories.reportFailure = { failure in sink.handler?(failure) }
        guard let renderer = makeRenderer(factories: factories, fontManager: fontManager) else {
            Issue.record("renderer unavailable"); return
        }

        func emptyFrame(_ bg: UInt32) -> FrameState {
            var fs = FrameState(cols: 4, rows: 4); fs.defaultBg = bg; return fs
        }

        // Frame 1: good frame (color A). Await onPresented, read pixels A.
        guard let goodTexture = OffscreenReadback.makeDrawableTexture(device: device, width: width, height: height) else {
            Issue.record("texture alloc failed"); return
        }
        let goodDrawable = ReadbackDrawable(texture: goodTexture, drawableID: 1)
        let goodWaiter = PresentationWaiter()
        sink.handler = { goodWaiter.fail($0) }
        let goodOutcome = await goodWaiter.awaitOutcome {
            renderer.render(
                frameState: emptyFrame(Self.colorA), fontManager: fontManager,
                drawableProvider: { goodDrawable },
                viewportSize: CGSize(width: width, height: height), contentScale: 1,
                presentationInputSeq: 1,
                onPresented: { goodWaiter.succeed($0) }
            )
        }
        guard case .presented(let goodSnapshot) = goodOutcome else {
            Issue.record("good frame did not present: \(goodOutcome)"); return
        }
        #expect(goodSnapshot.frameState.defaultBg == Self.colorA)
        let goodGeneration = renderer.lastCompletedPresentationGeneration
        #expect(goodGeneration > 0)
        guard let goodImage = await OffscreenReadback.read(texture: goodTexture, queue: queue) else {
            Issue.record("readback failed for good frame"); return
        }
        #expect(goodImage.pixel(x: width / 2, y: height / 2)
            .rgbDistanceSquared(to: Self.expectedColor(Self.colorA)) < 0.02)

        // Frame 2: nil drawable at acquisition time. The offscreen render still
        // runs; the drawable is nil so presentation is refused. Must NOT promote
        // and must NOT present onto the good drawable.
        let failWaiter = PresentationWaiter()
        sink.handler = { failWaiter.fail($0) }
        let failOutcome = await failWaiter.awaitOutcome {
            renderer.render(
                frameState: emptyFrame(Self.colorB), fontManager: fontManager,
                drawableProvider: { nil },
                viewportSize: CGSize(width: width, height: height), contentScale: 1,
                presentationInputSeq: 2,
                onPresented: { failWaiter.succeed($0) }
            )
        }
        guard case .failed(let failure) = failOutcome else {
            Issue.record("nil-drawable frame unexpectedly presented: \(failOutcome)"); return
        }
        #expect(failure.phase == .drawable)
        // Generation must be unchanged — the good frame is still the last good one.
        #expect(renderer.lastCompletedPresentationGeneration == goodGeneration,
                "failed frame promoted its generation")
        // The good drawable's pixels are untouched by the failed frame.
        guard let preservedImage = await OffscreenReadback.read(texture: goodTexture, queue: queue) else {
            Issue.record("readback failed for preserved frame"); return
        }
        #expect(preservedImage.pixel(x: width / 2, y: height / 2)
            .rgbDistanceSquared(to: Self.expectedColor(Self.colorA)) < 0.02,
            "failed frame corrupted the last good presented pixels")

        // Frame 3: valid recovery frame (color B) onto a fresh drawable.
        guard let recoveryTexture = OffscreenReadback.makeDrawableTexture(device: device, width: width, height: height) else {
            Issue.record("texture alloc failed"); return
        }
        let recoveryDrawable = ReadbackDrawable(texture: recoveryTexture, drawableID: 3)
        let recoveryWaiter = PresentationWaiter()
        sink.handler = { recoveryWaiter.fail($0) }
        let recoveryOutcome = await recoveryWaiter.awaitOutcome {
            renderer.render(
                frameState: emptyFrame(Self.colorB), fontManager: fontManager,
                drawableProvider: { recoveryDrawable },
                viewportSize: CGSize(width: width, height: height), contentScale: 1,
                presentationInputSeq: 3,
                onPresented: { recoveryWaiter.succeed($0) }
            )
        }
        guard case .presented(let recoverySnapshot) = recoveryOutcome else {
            Issue.record("recovery frame did not present: \(recoveryOutcome)"); return
        }
        #expect(recoverySnapshot.frameState.defaultBg == Self.colorB)
        #expect(renderer.lastCompletedPresentationGeneration > goodGeneration)
        guard let recoveryImage = await OffscreenReadback.read(texture: recoveryTexture, queue: queue) else {
            Issue.record("readback failed for recovery frame"); return
        }
        #expect(recoveryImage.pixel(x: width / 2, y: height / 2)
            .rgbDistanceSquared(to: Self.expectedColor(Self.colorB)) < 0.02,
            "recovery frame did not present the new content")
    }
}
