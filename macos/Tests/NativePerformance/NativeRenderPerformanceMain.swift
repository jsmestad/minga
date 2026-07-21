import AppKit
import Darwin
import Foundation
import Metal
import MingaProtocol
import MingaUI
import QuartzCore

private let residentRowCount = 65_536
private let viewportRows: UInt16 = 80
private let viewportCols: UInt16 = 160
private let warmupFrameCount = 9
private let measuredFrameCount = 240

private final class BenchmarkDrawable: NSObject, CAMetalDrawable {
    let texture: MTLTexture
    let layer = CAMetalLayer()
    let drawableID: Int = 1
    let presentedTime: CFTimeInterval = 0

    init(texture: MTLTexture) { self.texture = texture }
    func present() {}
    func present(at presentationTime: CFTimeInterval) { _ = presentationTime }
    func present(afterMinimumDuration duration: CFTimeInterval) { _ = duration }
    func addPresentedHandler(_ block: @escaping MTLDrawablePresentedHandler) { _ = block }
}

private struct CompletedFrame {
    let drawCPUMs: Double
    let gpuMs: Double
    let completionWallMs: Double
    let allocatedBytes: Int
    let allocationCount: Int
    let presented: Bool
}

@MainActor
private final class NativeBenchmarkProbe {
    private enum Phase {
        case idle
        case submitting(CheckedContinuation<CompletedFrame, Never>)
        case awaiting(CheckedContinuation<CompletedFrame, Never>)
        case terminal(CheckedContinuation<CompletedFrame, Never>, presented: Bool)
    }

    private var phase = Phase.idle
    private var startedAt: ContinuousClock.Instant = .now
    private var drawCPUMs = 0.0
    private var gpuMs = 0.0
    private var allocatedBytes = 0
    private var allocationCount = 0
    private(set) var inFlight = 0
    private(set) var maximumInFlight = 0

    func measure(_ submit: () -> Double) async -> CompletedFrame {
        await withCheckedContinuation { continuation in
            guard case .idle = phase else {
                preconditionFailure("cannot start a benchmark frame while another frame is pending")
            }
            startedAt = .now
            drawCPUMs = 0
            gpuMs = 0
            allocatedBytes = 0
            allocationCount = 0
            inFlight += 1
            maximumInFlight = max(maximumInFlight, inFlight)
            phase = .submitting(continuation)
            drawCPUMs = submit()

            switch phase {
            case .submitting(let pending):
                phase = .awaiting(pending)
            case .terminal(let pending, let presented):
                complete(pending, presented: presented)
            case .idle, .awaiting:
                preconditionFailure("invalid benchmark submission transition")
            }
        }
    }

    func recordGPU(_ milliseconds: Double) { gpuMs += milliseconds }

    func recordCompletionCPU(_ milliseconds: Double) { drawCPUMs += milliseconds }

    func recordBufferAllocation(bytes: Int) {
        allocationCount += 1
        allocatedBytes += bytes
    }

    func recordTextureAllocation(_ descriptor: MTLTextureDescriptor) {
        allocationCount += 1
        allocatedBytes += descriptor.width * descriptor.height * 4
    }

    func finishPresented() { finish(presented: true) }

    func finishFailed() { finish(presented: false) }

    private func finish(presented: Bool) {
        switch phase {
        case .submitting(let continuation):
            phase = .terminal(continuation, presented: presented)
        case .awaiting(let continuation):
            complete(continuation, presented: presented)
        case .idle, .terminal:
            return
        }
    }

    private func complete(
        _ continuation: CheckedContinuation<CompletedFrame, Never>,
        presented: Bool
    ) {
        phase = .idle
        inFlight -= 1
        let duration = startedAt.duration(to: .now)
        let completionWallMs = Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
        continuation.resume(returning: CompletedFrame(
            drawCPUMs: drawCPUMs,
            gpuMs: gpuMs,
            completionWallMs: completionWallMs,
            allocatedBytes: allocatedBytes,
            allocationCount: allocationCount,
            presented: presented
        ))
    }
}

private func threadCPUTimeNanoseconds() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
}

private func percentile(_ samples: [Double], _ ratio: Double) -> Double {
    let sorted = samples.sorted()
    let index = min(max(Int((Double(sorted.count) * ratio).rounded(.up)) - 1, 0), sorted.count - 1)
    return sorted[index]
}

@MainActor
private func completeThemeSlots() -> [(UInt8, UInt8, UInt8, UInt8)] {
    CommandDispatcher.requiredThemeSlots.map { slot in (slot, slot, slot, slot) }
}

private func paneGeometry() -> GUIPaneGeometry {
    let gutterWidth: UInt16 = 6
    return GUIPaneGeometry(
        windowId: 1,
        totalRect: GUICellRect(row: 0, col: 0, width: viewportCols, height: viewportRows),
        contentRect: GUICellRect(row: 0, col: 0, width: viewportCols, height: viewportRows),
        textRect: GUICellRect(row: 0, col: gutterWidth, width: viewportCols - gutterWidth, height: viewportRows),
        gutterRect: GUICellRect(row: 0, col: 0, width: gutterWidth, height: viewportRows),
        clipRect: GUICellRect(row: 0, col: 0, width: viewportCols, height: viewportRows),
        viewport: GUIViewportSummary(
            top: 0, left: 0, rows: viewportRows, cols: viewportCols - gutterWidth,
            totalLines: UInt32(residentRowCount), visualRowOffset: 0,
            totalVisualRows: UInt32(residentRowCount)
        ),
        gutterMetrics: GUIGutterMetrics(lineNumberWidth: 5, signColWidth: 1),
        hitRegions: [GUIHitRegion(
            kind: .gutter,
            rect: GUICellRect(row: 0, col: 0, width: gutterWidth, height: viewportRows),
            windowId: 1
        )]
    )
}

private func residentContent(geometry: GUIPaneGeometry) throws -> GUIWindowContent {
    var rows: [GUIVisualRow] = []
    rows.reserveCapacity(residentRowCount)
    for index in 0..<residentRowCount {
        rows.append(GUIVisualRow(
            rowType: .normal,
            rowId: UInt64(index + 1),
            bufLine: UInt32(index),
            contentHash: UInt32(index + 1),
            text: "row \(index) let value = \(index)",
            spans: []
        ))
    }
    return try GUIWindowContent(
        windowId: 1,
        fullRefresh: true,
        contentEpoch: 1,
        cursorVisible: true,
        cursorRow: 20,
        cursorCol: 8,
        cursorShape: .block,
        rows: rows,
        selection: nil,
        searchMatches: [],
        diagnosticUnderlines: [],
        documentHighlights: [],
        paneGeometry: geometry,
        scrollPresentation: GUIScrollPresentation(
            windowId: 1,
            resetRequired: false,
            anchorTop: 0,
            anchorLeft: 0,
            anchorVisualRowOffset: 0,
            visibleStartLine: 0,
            visibleEndLine: UInt32(viewportRows),
            overscanStartLine: 0,
            overscanEndLine: UInt32(residentRowCount),
            contentEpoch: 1,
            layoutGeneration: 1,
            scrollSeq: 1
        )
    )
}

private func gutter(geometry: GUIPaneGeometry) -> Wire.WindowGutter {
    Wire.WindowGutter(
        windowId: 1,
        contentRow: geometry.textRect.row,
        contentCol: geometry.textRect.col,
        contentHeight: geometry.textRect.height,
        isActive: true,
        contentWidth: geometry.textRect.width,
        cursorLine: 20,
        lineNumberStyle: .hybrid,
        lineNumberWidth: 5,
        signColWidth: 1,
        entries: (0..<Int(viewportRows)).map { index in
            Wire.GutterEntry(
                bufLine: UInt32(index), displayType: .normal, signType: .none,
                foldEndLine: 0xFFFF_FFFF, signFg: 0, signText: ""
            )
        }
    )
}

@MainActor
private func commitKeyframe(
    dispatcher: CommandDispatcher,
    content: GUIWindowContent,
    gutter: Wire.WindowGutter
) {
    dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
    dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
    dispatcher.dispatch(.guiWindowContent(data: content))
    dispatcher.dispatch(.guiGutter(data: gutter))
    dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))
}

@MainActor
private func measureFreezePublication(dispatcher: CommandDispatcher) -> [Double] {
    var samples: [Double] = []
    samples.reserveCapacity(measuredFrameCount)
    var priorFrameSeq: UInt32 = 1
    for index in 0..<measuredFrameCount {
        let frameSeq = priorFrameSeq + 1
        let start = threadCPUTimeNanoseconds()
        dispatcher.dispatch(.beginFrame(frameSeq: frameSeq, baseFrameSeq: priorFrameSeq, generation: 1))
        dispatcher.dispatch(.setCursorShape(index.isMultiple(of: 2) ? .block : .beam))
        dispatcher.dispatch(.commitFrame(frameSeq: frameSeq, seq: 0))
        samples.append(Double(threadCPUTimeNanoseconds() - start) / 1_000_000)
        priorFrameSeq = frameSeq
    }
    return samples
}

@MainActor
private func makeFactories(probe: NativeBenchmarkProbe) -> NativeRenderFactories {
    var factories = NativeRenderFactories.production
    factories.makeBuffer = { device, length, options in
        probe.recordBufferAllocation(bytes: length)
        return device.makeBuffer(length: length, options: options)
    }
    factories.makeTexture = { device, descriptor in
        probe.recordTextureAllocation(descriptor)
        return device.makeTexture(descriptor: descriptor)
    }
    factories.observeCompletion = { commandBuffer, completion in
        commandBuffer.addCompletedHandler { completed in
            let succeeded = completed.status == .completed
            let status = Int(completed.status.rawValue)
            let gpuMs = max(completed.gpuEndTime - completed.gpuStartTime, 0) * 1_000
            Task { @MainActor in
                probe.recordGPU(gpuMs)
                let cpuStart = threadCPUTimeNanoseconds()
                completion(succeeded, status)
                probe.recordCompletionCPU(
                    Double(threadCPUTimeNanoseconds() - cpuStart) / 1_000_000
                )
            }
        }
    }
    factories.present = { drawable in
        drawable.present()
        probe.finishPresented()
    }
    factories.reportFailure = { _ in
        probe.finishFailed()
    }
    return factories
}

@MainActor
private func renderFrame(
    renderer: CoreTextMetalRenderer,
    dispatcher: CommandDispatcher,
    guiState: GUIState,
    fontManager: FontManager,
    drawable: BenchmarkDrawable,
    probe: NativeBenchmarkProbe,
    index: Int
) async -> CompletedFrame {
    await probe.measure {
        let cpuStart = threadCPUTimeNanoseconds()
        #if MINGA_SNAPSHOT_RENDERER
        guard let snapshot = dispatcher.committedEditorSnapshot else {
            probe.finishFailed()
            return Double(threadCPUTimeNanoseconds() - cpuStart) / 1_000_000
        }
        renderer.render(
            snapshot: snapshot,
            fontManager: fontManager,
            cursorBlinkVisible: index.isMultiple(of: 2),
            drawableProvider: { drawable },
            viewportSize: CGSize(width: 1_920, height: 1_200),
            contentScale: 1,
            scrollOffset: SIMD2<Float>(0, Float(index % 4) * -0.25),
            presentationWindowId: 1,
            presentationInputSeq: UInt32(index + 1)
        )
        #else
        renderer.render(
            frameState: dispatcher.frameState,
            fontManager: fontManager,
            cursorBlinkVisible: index.isMultiple(of: 2),
            windowContents: guiState.windowContents,
            themeColors: guiState.themeColors,
            drawableProvider: { drawable },
            viewportSize: CGSize(width: 1_920, height: 1_200),
            contentScale: 1,
            scrollOffset: SIMD2<Float>(0, Float(index % 4) * -0.25),
            presentationWindowId: 1,
            presentationInputSeq: UInt32(index + 1)
        )
        #endif
        return Double(threadCPUTimeNanoseconds() - cpuStart) / 1_000_000
    }
}

@main
private struct NativeRenderPerformanceMain {
    @MainActor
    static func main() async throws {
        guard CommandLine.arguments.count == 3,
              CommandLine.arguments[1] == "--measurement-output" else {
            FileHandle.standardError.write(Data("usage: minga-native-render-performance --measurement-output OUTPUT.json\n".utf8))
            exit(2)
        }
        guard MTLCreateSystemDefaultDevice() != nil else {
            FileHandle.standardError.write(Data("error: native render benchmark requires a Metal device\n".utf8))
            exit(2)
        }

        let geometry = paneGeometry()
        let content = try residentContent(geometry: geometry)
        let guiState = GUIState()
        let dispatcher = CommandDispatcher(cols: viewportCols, rows: viewportRows, guiState: guiState)
        commitKeyframe(dispatcher: dispatcher, content: content, gutter: gutter(geometry: geometry))
        let freezeSamples = measureFreezePublication(dispatcher: dispatcher)

        let probe = NativeBenchmarkProbe()
        guard let renderer = CoreTextMetalRenderer(factories: makeFactories(probe: probe)) else {
            FileHandle.standardError.write(Data("error: unable to initialize native renderer\n".utf8))
            exit(2)
        }
        let fontManager = FontManager(name: "Menlo", size: 13, scale: 1)
        renderer.setupRenderers(fontManager: fontManager)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: 1_920, height: 1_200, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = renderer.device.makeTexture(descriptor: descriptor) else {
            FileHandle.standardError.write(Data("error: unable to allocate benchmark drawable\n".utf8))
            exit(2)
        }
        let drawable = BenchmarkDrawable(texture: texture)

        for index in 0..<warmupFrameCount {
            _ = await renderFrame(
                renderer: renderer, dispatcher: dispatcher, guiState: guiState,
                fontManager: fontManager, drawable: drawable, probe: probe, index: index
            )
        }

        var frames: [CompletedFrame] = []
        frames.reserveCapacity(measuredFrameCount)
        for index in 0..<measuredFrameCount {
            frames.append(await renderFrame(
                renderer: renderer, dispatcher: dispatcher, guiState: guiState,
                fontManager: fontManager, drawable: drawable, probe: probe,
                index: warmupFrameCount + index
            ))
        }

        let drawSamples = frames.map(\.drawCPUMs)
        let gpuSamples = frames.map(\.gpuMs)
        let completionWallSamples = frames.map(\.completionWallMs)
        let measurement = NativeRenderPerformanceMeasurement(
            freezePublicationP50Ms: percentile(freezeSamples, 0.50),
            freezePublicationP95Ms: percentile(freezeSamples, 0.95),
            drawCPUP50Ms: percentile(drawSamples, 0.50),
            drawCPUP95Ms: percentile(drawSamples, 0.95),
            drawCPUP99Ms: percentile(drawSamples, 0.99),
            gpuP50Ms: percentile(gpuSamples, 0.50),
            gpuP95Ms: percentile(gpuSamples, 0.95),
            completionWallP50Ms: percentile(completionWallSamples, 0.50),
            completionWallP95Ms: percentile(completionWallSamples, 0.95),
            maximumAllocatedBytesPerFrame: frames.map(\.allocatedBytes).max() ?? 0,
            allocationCountAfterWarmup: frames.reduce(0) { $0 + $1.allocationCount },
            attemptedFrameCount: frames.count,
            copyCompletedFrameCount: frames.filter(\.presented).count,
            failedOrDiscardedFrameCount: frames.filter { !$0.presented }.count,
            maximumInFlightGenerations: probe.maximumInFlight
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(measurement)
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
        print(String(decoding: data, as: UTF8.self))
        #if MINGA_SNAPSHOT_RENDERER
        let rendererPath = "snapshot"
        #else
        let rendererPath = "legacy-fragmented"
        #endif
        print("fixture=native-resident-cursor-local-scroll-v1 path=\(rendererPath) device=\(renderer.device.name) os=\(ProcessInfo.processInfo.operatingSystemVersionString) rows=\(residentRowCount) viewport=\(viewportCols)x\(viewportRows) warmup=\(warmupFrameCount) measured=\(measuredFrameCount)")

        let failures = NativeRenderPerformanceGate.absoluteFailures(measurement)
        for failure in failures {
            FileHandle.standardError.write(Data("error: \(failure)\n".utf8))
        }
        if !failures.isEmpty { exit(1) }
    }
}
