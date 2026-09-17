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
private let transcriptWarmupFrameCount = 12
private let transcriptMeasuredFrameCount = 120
private let accessibilityWarmupCount = 200
private let accessibilityMeasuredCount = 1_000

private struct AccessibilityPerformanceFixture: Codable {
    let caseName: String
    let paneCount: Int
    let residentRows: Int
    let sourceUTF8Bytes: Int
    let rowsVisitedPerQuery: Int
    let utf16UnitsVisitedPerQuery: Int
    let p50Ms: Double
    let p95Ms: Double
}

private struct AccessibilityPerformanceMeasurement: Codable {
    let fixture: String
    let warmupCount: Int
    let measuredCount: Int
    let environment: String
    let results: [AccessibilityPerformanceFixture]
}

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

private func residentContent(geometry: GUIPaneGeometry, rowCount: Int = residentRowCount) throws -> GUIWindowContent {
    var rows: [GUIVisualRow] = []
    rows.reserveCapacity(rowCount)
    for index in 0..<rowCount {
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
            overscanEndLine: UInt32(rowCount),
            contentEpoch: 1,
            layoutGeneration: 1,
            scrollSeq: 1
        ),
        accessibilityGeneration: 1,
        accessibilityCursor: GUIAccessibilityCursor(row: 20, utf16: 8)
    )
}

private func legalPayloadLongLineContent(geometry: GUIPaneGeometry) throws -> GUIWindowContent {
    let text = String(repeating: "x", count: FrameResourcePolicy.default.wire.payloadBytes - 4_096)
    return try GUIWindowContent(
        windowId: 1,
        fullRefresh: true,
        contentEpoch: 1,
        cursorVisible: true,
        cursorRow: 0,
        cursorCol: 0,
        cursorShape: .block,
        rows: [GUIVisualRow(rowType: .normal, rowId: 1, bufLine: 0, contentHash: 1, text: text, spans: [])],
        selection: nil,
        searchMatches: [],
        diagnosticUnderlines: [],
        documentHighlights: [],
        paneGeometry: geometry,
        accessibilityCursor: GUIAccessibilityCursor(row: 0, utf16: 0)
    )
}

private func measureAccessibility(
    caseName: String,
    content: GUIWindowContent,
    geometry: GUIPaneGeometry,
    paneCount: Int,
    sourceUTF8Bytes: Int
) -> AccessibilityPerformanceFixture {
    let surface = PresentedWindowSurface(content: content, gutter: .none, paneGeometry: geometry, indentGuides: nil)
    var checksum = 0
    for _ in 0..<accessibilityWarmupCount {
        for paneIndex in 0..<paneCount {
            let projection = EditorAccessibilityProjection.build(surface: surface, connectionID: 1, isActivePane: paneIndex == 0, localTransform: nil, cellWidth: 8, cellHeight: 16)
            checksum &+= projection.value.utf16.count
            checksum &+= projection.insertionRange?.location ?? 0
        }
    }
    var samples: [Double] = []
    samples.reserveCapacity(accessibilityMeasuredCount)
    var rowsVisited = 0
    var utf16UnitsVisited = 0
    for _ in 0..<accessibilityMeasuredCount {
        let started = threadCPUTimeNanoseconds()
        for paneIndex in 0..<paneCount {
            let projection = EditorAccessibilityProjection.build(surface: surface, connectionID: 1, isActivePane: paneIndex == 0, localTransform: nil, cellWidth: 8, cellHeight: 16)
            checksum &+= projection.value.utf16.count
            checksum &+= projection.insertionRange?.location ?? 0
            checksum &+= Int(projection.localRect(for: projection.insertionRange ?? NSRange(location: 0, length: 0))?.width ?? 0)
            rowsVisited = projection.rowsVisited * paneCount
            utf16UnitsVisited = projection.utf16UnitsVisited * paneCount
        }
        samples.append(Double(threadCPUTimeNanoseconds() - started) / 1_000_000)
    }
    precondition(checksum > 0)
    return AccessibilityPerformanceFixture(
        caseName: caseName,
        paneCount: paneCount,
        residentRows: content.rowStore.count,
        sourceUTF8Bytes: sourceUTF8Bytes,
        rowsVisitedPerQuery: rowsVisited,
        utf16UnitsVisitedPerQuery: utf16UnitsVisited,
        p50Ms: percentile(samples, 0.50),
        p95Ms: percentile(samples, 0.95)
    )
}

private func accessibilityMeasurement() throws -> AccessibilityPerformanceMeasurement {
    let geometry = paneGeometry()
    let small = try residentContent(geometry: geometry, rowCount: 5_000)
    let large = try residentContent(geometry: geometry)
    let longLine = try legalPayloadLongLineContent(geometry: geometry)
    return AccessibilityPerformanceMeasurement(
        fixture: "accessibility-visible-pane-v1",
        warmupCount: accessibilityWarmupCount,
        measuredCount: accessibilityMeasuredCount,
        environment: "\(ProcessInfo.processInfo.operatingSystemVersionString); \(ProcessInfo.processInfo.processorCount) logical CPUs",
        results: [
            measureAccessibility(caseName: "resident-5000", content: small, geometry: geometry, paneCount: 1, sourceUTF8Bytes: 0),
            measureAccessibility(caseName: "resident-5000", content: small, geometry: geometry, paneCount: 4, sourceUTF8Bytes: 0),
            measureAccessibility(caseName: "resident-65536", content: large, geometry: geometry, paneCount: 1, sourceUTF8Bytes: 0),
            measureAccessibility(caseName: "resident-65536", content: large, geometry: geometry, paneCount: 4, sourceUTF8Bytes: 0),
            measureAccessibility(
                caseName: "legal-payload-long-line",
                content: longLine,
                geometry: geometry,
                paneCount: 1,
                sourceUTF8Bytes: FrameResourcePolicy.default.wire.payloadBytes - 4_096
            ),
        ]
    )
}

private func gutter(geometry: GUIPaneGeometry) -> Wire.WindowGutter {
    Wire.WindowGutter(
        windowId: 1,
        contentRow: geometry.contentRect.row,
        contentCol: geometry.contentRect.col,
        contentHeight: geometry.contentRect.height,
        isActive: true,
        contentWidth: geometry.contentRect.width,
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

private struct TranscriptFixture {
    let name: String
    let messageCount: Int
    let textBytesPerMessage: Int
}

private func transcriptMessages(for fixture: TranscriptFixture) -> [Wire.ChatMessage] {
    guard fixture.messageCount > 0 else { return [] }
    let text = String(repeating: "x", count: fixture.textBytesPerMessage)
    let run = Wire.StyledTextRun(
        text: text, fgR: 1, fgG: 2, fgB: 3, bgR: 0, bgG: 0, bgB: 0,
        bold: false, italic: false, underline: false, code: true, linkURL: ""
    )
    let block = Wire.AgentMarkdownBlock(
        id: 1, kind: .paragraph, flags: 0, lines: [[run]], level: 0, indent: 0,
        ordered: false, ordinal: 0, height: 1, language: "swift", label: "",
        targetPath: "", capabilityFlags: 0
    )
    return (0..<fixture.messageCount).map { index in
        let id = UInt32(index + 1)
        switch index % 1_000 {
        case 0:
            return Wire.ChatMessage(beamId: id, content: .assistantMarkdown(blocks: [block]))
        case 1:
            return Wire.ChatMessage(beamId: id, content: .toolCall(
                name: "read_file", summary: "fixture", status: 1, isError: false,
                collapsed: false, autoApprovedScope: 0, durationMs: 1, result: text,
                previewKind: 1, previewLines: ["fixture.swift"]
            ))
        default:
            return Wire.ChatMessage(beamId: id, content: .user(text: text))
        }
    }
}

@MainActor
private func measureTranscriptAccounting(
    fixture: TranscriptFixture
) throws -> NativeTranscriptAccountingMeasurement {
    let guiState = GUIState()
    let dispatcher = CommandDispatcher(
        cols: viewportCols, rows: viewportRows, guiState: guiState,
        applicationEffectSink: { _ in }
    )
    dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
    dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
    dispatcher.dispatch(.guiAgentTranscript(
        mode: 0, epoch: 1, truncated: false, trimFront: 0, baseCount: 0,
        messages: transcriptMessages(for: fixture)
    ))
    dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))
    precondition(dispatcher.publicationCount == 1, "transcript benchmark seed must publish")

    #if MINGA_TRANSCRIPT_ACCOUNTING
    let residentWeight = guiState.agentChatState.transcriptSnapshot.resourceWeight
    #else
    let residentWeight = try guiState.agentChatState.transcriptSnapshot.exactResourceWeight()
    #endif

    var samples: [Double] = []
    samples.reserveCapacity(transcriptMeasuredFrameCount)
    var frameSeq: UInt32 = 1
    var changedEntriesMeasured = 0
    var unchangedEntriesVisited = 0
    var retainedEntriesCopied = 0
    let retainedUTF8BytesCopied = 0
    var sequenceNodeAllocations = 0
    let totalFrames = transcriptWarmupFrameCount + transcriptMeasuredFrameCount
    for index in 0..<totalFrames {
        let nextFrameSeq = frameSeq + 1
        let start = threadCPUTimeNanoseconds()
        dispatcher.dispatch(.beginFrame(
            frameSeq: nextFrameSeq, baseFrameSeq: frameSeq, generation: 1
        ))
        if index.isMultiple(of: 2) {
            dispatcher.dispatch(.setCursorShape(index.isMultiple(of: 4) ? .block : .beam))
        } else {
            dispatcher.dispatch(.setTitle("transcript-accounting-\(index)"))
        }
        dispatcher.dispatch(.commitFrame(frameSeq: nextFrameSeq, seq: 0))
        let elapsed = Double(threadCPUTimeNanoseconds() - start) / 1_000_000
        frameSeq = nextFrameSeq

        #if MINGA_TRANSCRIPT_ACCOUNTING
        guard let counters = dispatcher.lastTranscriptAccountingCounters else {
            preconditionFailure("transcript benchmark frame did not publish accounting counters")
        }
        changedEntriesMeasured += counters.changedEntriesMeasured
        unchangedEntriesVisited += counters.unchangedEntriesVisited
        retainedEntriesCopied += counters.retainedEntriesCopied
        sequenceNodeAllocations += counters.sequenceNodesCreated
        #endif

        if index >= transcriptWarmupFrameCount { samples.append(elapsed) }
    }

    #if MINGA_TRANSCRIPT_ACCOUNTING
    let measuredChangedEntries: Int? = changedEntriesMeasured
    let measuredUnchangedVisits: Int? = unchangedEntriesVisited
    let measuredRetainedCopies: Int? = retainedEntriesCopied
    let measuredRetainedBytesCopied: Int? = retainedUTF8BytesCopied
    let measuredSequenceAllocations: Int? = sequenceNodeAllocations
    let compilerFlags = ["-O", "-DMINGA_SNAPSHOT_RENDERER", "-DMINGA_TRANSCRIPT_ACCOUNTING"]
    #else
    let measuredChangedEntries: Int? = nil
    let measuredUnchangedVisits: Int? = nil
    let measuredRetainedCopies: Int? = nil
    let measuredRetainedBytesCopied: Int? = nil
    let measuredSequenceAllocations: Int? = nil
    let compilerFlags = ["-O", "-DMINGA_SNAPSHOT_RENDERER"]
    #endif

    return NativeTranscriptAccountingMeasurement(
        fixture: fixture.name,
        messageCount: fixture.messageCount,
        ownedUTF8Bytes: residentWeight.ownedUTF8Bytes,
        stageCPUP50Ms: percentile(samples, 0.50),
        stageCPUP95Ms: percentile(samples, 0.95),
        stageCPUP99Ms: percentile(samples, 0.99),
        changedEntriesMeasured: measuredChangedEntries,
        unchangedEntriesVisited: measuredUnchangedVisits,
        retainedEntriesCopied: measuredRetainedCopies,
        retainedUTF8BytesCopied: measuredRetainedBytesCopied,
        sequenceNodeAllocations: measuredSequenceAllocations,
        measuredFrameCount: samples.count,
        compilerFlags: compilerFlags,
        revision: ProcessInfo.processInfo.environment["MINGA_BENCHMARK_REVISION"] ?? "unknown"
    )
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
        commandBuffer.addCompletedHandler { @Sendable completed in
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
        if CommandLine.arguments.count == 3,
           CommandLine.arguments[1] == "--resource-investigation-output" {
            try await runNativeResourceInvestigation(
                outputURL: URL(fileURLWithPath: CommandLine.arguments[2])
            )
            return
        }
        if CommandLine.arguments.count == 3,
           CommandLine.arguments[1] == "--accessibility-measurement-output" {
            let measurement = try accessibilityMeasurement()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(measurement)
            try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
            print(String(decoding: data, as: UTF8.self))
            return
        }
        guard CommandLine.arguments.count == 3,
              CommandLine.arguments[1] == "--measurement-output" else {
            FileHandle.standardError.write(Data("usage: minga-native-render-performance (--measurement-output | --accessibility-measurement-output | --resource-investigation-output) OUTPUT.json\n".utf8))
            exit(2)
        }
        guard MTLCreateSystemDefaultDevice() != nil else {
            FileHandle.standardError.write(Data("error: native render benchmark requires a Metal device\n".utf8))
            exit(2)
        }

        let geometry = paneGeometry()
        let content = try residentContent(geometry: geometry)
        let guiState = GUIState()
        let dispatcher = CommandDispatcher(
            cols: viewportCols, rows: viewportRows, guiState: guiState,
            applicationEffectSink: { _ in }
        )
        commitKeyframe(dispatcher: dispatcher, content: content, gutter: gutter(geometry: geometry))
        let freezeSamples = measureFreezePublication(dispatcher: dispatcher)
        let transcriptFixtures = [
            TranscriptFixture(name: "empty", messageCount: 0, textBytesPerMessage: 0),
            TranscriptFixture(name: "short-100", messageCount: 100, textBytesPerMessage: 200),
            TranscriptFixture(name: "medium-1000", messageCount: 1_000, textBytesPerMessage: 200),
            TranscriptFixture(name: "long-10000", messageCount: 10_000, textBytesPerMessage: 200),
            TranscriptFixture(name: "near-8mib-cap", messageCount: 8_192, textBytesPerMessage: 1_000),
        ]
        var transcriptAccounting: [NativeTranscriptAccountingMeasurement] = []
        for fixture in transcriptFixtures {
            transcriptAccounting.append(try measureTranscriptAccounting(fixture: fixture))
        }

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
            maximumInFlightGenerations: probe.maximumInFlight,
            transcriptAccounting: transcriptAccounting
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
