import AppKit
import Darwin
import Foundation
import Metal
import MingaProtocol
import MingaUI
import QuartzCore

private let investigationResidentRows = 65_536
private let investigationCols: UInt16 = 160
private let investigationRows: UInt16 = 80
private let investigationWarmupFrames = 9
private let investigationMeasuredFrames = 31

private final class InvestigationDrawable: NSObject, CAMetalDrawable {
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

private final class WeakNativeResource {
    weak var value: AnyObject?
    let bytes: Int

    init(_ value: AnyObject, bytes: Int) {
        self.value = value
        self.bytes = bytes
    }
}

private struct InvestigationFrameMetrics: Codable {
    let bufferRowsRasterized: Int
    let bufferRowsReused: Int
    let otherTexturesRasterized: Int
    let otherTexturesReused: Int
    let textureUploads: Int
    let textureUploadBytes: Int
    let atlasNewKeys: Int
    let atlasHashChanges: Int
    let atlasEvictions: Int
    let editorRowsVisited: Int
    let decorationsVisited: Int
    let residentRowsVisited: Int
    let residentChunksTouched: Int
    let residentIDsResolved: Int
    let residentSplices: Int
    let residentChangedRowsValidated: Int
    let residentLocatorNodesCopied: Int
    let residentFullResets: Int

    init(_ metrics: FrameMetrics) {
        bufferRowsRasterized = metrics.bufferRowsRasterized
        bufferRowsReused = metrics.bufferRowsReused
        otherTexturesRasterized = metrics.otherTexturesRasterized
        otherTexturesReused = metrics.otherTexturesReused
        textureUploads = metrics.textureUploads
        textureUploadBytes = metrics.textureUploadBytes
        atlasNewKeys = metrics.atlasNewKeys
        atlasHashChanges = metrics.atlasHashChanges
        atlasEvictions = metrics.atlasEvictions
        editorRowsVisited = metrics.editorRowsVisited
        decorationsVisited = metrics.decorationsVisited
        residentRowsVisited = metrics.residentRowsVisited
        residentChunksTouched = metrics.residentChunksTouched
        residentIDsResolved = metrics.residentIDsResolved
        residentSplices = metrics.residentSplices
        residentChangedRowsValidated = metrics.residentChangedRowsValidated
        residentLocatorNodesCopied = metrics.residentLocatorNodesCopied
        residentFullResets = metrics.residentFullResets
    }
}

private struct InvestigationFrameSample: Codable {
    let drawCPUMs: Double
    let gpuMs: Double
    let completionWallMs: Double
    let textureAllocationCount: Int
    let textureAllocatedBytes: Int
    let bufferAllocationCount: Int
    let bufferAllocatedBytes: Int
    let candidateObjectCount: Int
    let atlasGrowthCopyBytes: Int
    let atlasCopyOnWriteBytes: Int
    let retainedNativeBytes: Int
    let residentMemoryBytes: UInt64
    let presented: Bool
    let metrics: InvestigationFrameMetrics?
}

private struct InvestigationWorkloadMeasurement: Codable {
    let name: String
    let phase: String
    let paneCount: Int
    let targetHz: Int?
    let frameIntervalMs: Double?
    let residentRowCount: Int
    let visibleRowsPlusOverscanBound: Int
    let samples: [InvestigationFrameSample]
    let drawCPUP50Ms: Double
    let drawCPUP95Ms: Double
    let drawCPUP99Ms: Double
    let gpuP50Ms: Double
    let gpuP95Ms: Double
    let gpuP99Ms: Double
    let completionWallP50Ms: Double
    let completionWallP95Ms: Double
    let completionWallP99Ms: Double
    let maximumInFlightGenerations: Int
    let droppedFrameCount: Int
    let peakRetainedNativeBytes: Int
    let peakResidentMemoryBytes: UInt64
    let totalTextureAllocations: Int
    let totalBufferAllocations: Int
    let totalCandidateObjects: Int
    let totalAtlasGrowthCopyBytes: Int
    let totalAtlasCopyOnWriteBytes: Int
    let totalRasterUploadBytes: Int
    let maximumEditorRowsVisited: Int
}

private struct InvestigationEnvironment: Codable {
    let measuredAt: String
    let revision: String
    let deviceName: String
    let deviceRegistryID: UInt64
    let operatingSystem: String
    let processorCount: Int
    let physicalMemoryBytes: UInt64
    let thermalState: String
    let lowPowerModeEnabled: Bool
    let compilerFlags: [String]
    let workloadOrder: [String]
}

private struct NativeResourceInvestigationReport: Codable {
    let schemaVersion: Int
    let fixture: String
    let environment: InvestigationEnvironment
    let workloads: [InvestigationWorkloadMeasurement]
}

private struct InvestigationCompletedFrame {
    let drawCPUMs: Double
    let gpuMs: Double
    let completionWallMs: Double
    let presented: Bool
}

@MainActor
private final class InvestigationProbe {
    private enum Phase {
        case idle
        case submitting(CheckedContinuation<InvestigationCompletedFrame, Never>)
        case awaiting(CheckedContinuation<InvestigationCompletedFrame, Never>)
        case terminal(CheckedContinuation<InvestigationCompletedFrame, Never>, Bool)
    }

    private var phase = Phase.idle
    private var startedAt: ContinuousClock.Instant = .now
    private var drawCPUMs = 0.0
    private var gpuMs = 0.0
    private var textureAllocationCount = 0
    private var textureAllocatedBytes = 0
    private var bufferAllocationCount = 0
    private var bufferAllocatedBytes = 0
    private var candidateObjectCount = 0
    private var atlasGrowthCopyBytes = 0
    private var atlasCopyOnWriteBytes = 0
    private var metrics: InvestigationFrameMetrics?
    private var resources: [WeakNativeResource] = []
    private(set) var maximumInFlight = 0
    private var inFlight = 0

    func measure(_ submit: () -> Double) async -> InvestigationFrameSample {
        let completed = await withCheckedContinuation { continuation in
            guard case .idle = phase else {
                preconditionFailure("cannot start an investigation frame while another frame is pending")
            }
            startedAt = .now
            drawCPUMs = 0
            gpuMs = 0
            textureAllocationCount = 0
            textureAllocatedBytes = 0
            bufferAllocationCount = 0
            bufferAllocatedBytes = 0
            candidateObjectCount = 0
            atlasGrowthCopyBytes = 0
            atlasCopyOnWriteBytes = 0
            metrics = nil
            inFlight += 1
            maximumInFlight = max(maximumInFlight, inFlight)
            phase = .submitting(continuation)
            drawCPUMs = submit()
            switch phase {
            case .submitting(let pending): phase = .awaiting(pending)
            case .terminal(let pending, let presented): complete(pending, presented: presented)
            case .idle, .awaiting: preconditionFailure("invalid investigation submission transition")
            }
        }
        resources.removeAll { $0.value == nil }
        return InvestigationFrameSample(
            drawCPUMs: completed.drawCPUMs,
            gpuMs: completed.gpuMs,
            completionWallMs: completed.completionWallMs,
            textureAllocationCount: textureAllocationCount,
            textureAllocatedBytes: textureAllocatedBytes,
            bufferAllocationCount: bufferAllocationCount,
            bufferAllocatedBytes: bufferAllocatedBytes,
            candidateObjectCount: candidateObjectCount,
            atlasGrowthCopyBytes: atlasGrowthCopyBytes,
            atlasCopyOnWriteBytes: atlasCopyOnWriteBytes,
            retainedNativeBytes: resources.reduce(0) { $0 + $1.bytes },
            residentMemoryBytes: residentMemoryBytes(),
            presented: completed.presented,
            metrics: metrics
        )
    }

    func recordTexture(_ texture: MTLTexture, descriptor: MTLTextureDescriptor) {
        let bytes = max(descriptor.width, 0) * max(descriptor.height, 0) * 4
        textureAllocationCount += 1
        textureAllocatedBytes += bytes
        resources.append(WeakNativeResource(texture as AnyObject, bytes: bytes))
    }

    func recordBuffer(_ buffer: MTLBuffer, length: Int) {
        bufferAllocationCount += 1
        bufferAllocatedBytes += length
        resources.append(WeakNativeResource(buffer as AnyObject, bytes: length))
    }

    func recordCandidates(_ count: Int) { candidateObjectCount += count }

    func recordAtlasCopy(_ kind: AtlasTextureCopyKind, bytes: Int) {
        switch kind {
        case .growth: atlasGrowthCopyBytes += bytes
        case .copyOnWrite: atlasCopyOnWriteBytes += bytes
        }
    }

    func recordMetrics(_ value: FrameMetrics) { metrics = InvestigationFrameMetrics(value) }

    func recordGPU(_ milliseconds: Double) { gpuMs += milliseconds }

    func finishPresented() { finish(presented: true) }

    func finishFailed() { finish(presented: false) }

    private func finish(presented: Bool) {
        switch phase {
        case .submitting(let continuation): phase = .terminal(continuation, presented)
        case .awaiting(let continuation): complete(continuation, presented: presented)
        case .idle, .terminal: return
        }
    }

    private func complete(
        _ continuation: CheckedContinuation<InvestigationCompletedFrame, Never>,
        presented: Bool
    ) {
        phase = .idle
        inFlight -= 1
        let duration = startedAt.duration(to: .now)
        let wall = Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
        continuation.resume(returning: InvestigationCompletedFrame(
            drawCPUMs: drawCPUMs, gpuMs: gpuMs, completionWallMs: wall,
            presented: presented
        ))
    }
}

private struct InvestigationFixture {
    let frameState: FrameState
    let contents: [UInt16: GUIWindowContent]
    let rows: [UInt16: [GUIVisualRow]]
    let gutters: [UInt16: Wire.WindowGutter]
    let metadata: EditorSnapshotMetadata
    let visibleRowsPlusOverscanBound: Int

    func snapshot(
        generation: UInt32,
        frameSeq: UInt32,
        contents replacement: [UInt16: GUIWindowContent]? = nil,
        frameState replacementFrameState: FrameState? = nil
    ) throws -> CommittedEditorSnapshot {
        switch CommittedEditorSnapshot.make(
            generation: generation,
            frameSeq: frameSeq,
            frameState: replacementFrameState ?? frameState,
            themeColors: nil,
            windowContents: replacement ?? contents,
            windowGutters: gutters,
            windowIndentGuides: [:],
            metadata: metadata
        ) {
        case .success(let snapshot): return snapshot
        case .failure(let rejection):
            throw InvestigationError.invalidSnapshot(String(describing: rejection))
        }
    }
}

private enum InvestigationError: Error {
    case rendererUnavailable
    case drawableUnavailable
    case invalidSnapshot(String)
    case rowMutationFailed
}

@MainActor
private func investigationFactories(_ probe: InvestigationProbe) -> NativeRenderFactories {
    var factories = NativeRenderFactories.production
    factories.makeTexture = { device, descriptor in
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        probe.recordTexture(texture, descriptor: descriptor)
        return texture
    }
    factories.makeBuffer = { device, length, options in
        guard let buffer = device.makeBuffer(length: length, options: options) else { return nil }
        probe.recordBuffer(buffer, length: length)
        return buffer
    }
    factories.observeCandidateObjects = { probe.recordCandidates($0) }
    factories.observeAtlasCopy = { probe.recordAtlasCopy($0, bytes: $1) }
    factories.observeFrameMetrics = { probe.recordMetrics($0) }
    factories.observeCompletion = { commandBuffer, completion in
        commandBuffer.addCompletedHandler { @Sendable completed in
            let succeeded = completed.status == .completed
            let status = Int(completed.status.rawValue)
            let gpuMs = max(completed.gpuEndTime - completed.gpuStartTime, 0) * 1_000
            Task { @MainActor in
                probe.recordGPU(gpuMs)
                completion(succeeded, status)
            }
        }
    }
    factories.present = { drawable in
        drawable.present()
        probe.finishPresented()
    }
    factories.reportFailure = { _ in probe.finishFailed() }
    return factories
}

private func residentMemoryBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
}

private func investigationPercentile(_ values: [Double], _ ratio: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = min(max(Int((Double(sorted.count) * ratio).rounded(.up)) - 1, 0), sorted.count - 1)
    return sorted[index]
}

private func investigationThreadCPUTimeNanoseconds() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
}

private func investigationFixture(paneCount: Int, cols: UInt16 = investigationCols) throws -> InvestigationFixture {
    let gridColumns = paneCount == 1 ? 1 : (paneCount == 4 ? 2 : 4)
    let gridRows = paneCount / gridColumns
    let paneWidth = cols / UInt16(gridColumns)
    let paneHeight = investigationRows / UInt16(gridRows)
    let gutterWidth: UInt16 = 6
    var contents: [UInt16: GUIWindowContent] = [:]
    var sourceRows: [UInt16: [GUIVisualRow]] = [:]
    var gutters: [UInt16: Wire.WindowGutter] = [:]
    var visibleBound = 0

    for index in 0..<paneCount {
        let windowID = UInt16(index + 1)
        let rowCount = index == 0 ? investigationResidentRows : 512
        let rowOffset = UInt64(index) << 32
        var rows: [GUIVisualRow] = []
        rows.reserveCapacity(rowCount)
        for row in 0..<rowCount {
            let rowIdentity = rowOffset + UInt64(row + 1)
            rows.append(GUIVisualRow(
                rowType: .normal,
                rowId: rowIdentity,
                bufLine: UInt32(row),
                contentHash: UInt32(truncatingIfNeeded: rowIdentity),
                text: "pane \(index) row \(row) let measuredValue = \(row)",
                spans: []
            ))
        }
        let paneRow = UInt16(index / gridColumns) * paneHeight
        let paneCol = UInt16(index % gridColumns) * paneWidth
        let visibleEnd = min(Int(paneHeight), rowCount)
        let overscanEnd = min(visibleEnd + 2, rowCount)
        visibleBound += overscanEnd
        let totalRect = GUICellRect(row: paneRow, col: paneCol, width: paneWidth, height: paneHeight)
        let geometry = GUIPaneGeometry(
            windowId: windowID,
            totalRect: totalRect,
            contentRect: totalRect,
            textRect: GUICellRect(
                row: paneRow, col: paneCol + gutterWidth,
                width: paneWidth - gutterWidth, height: paneHeight
            ),
            gutterRect: GUICellRect(
                row: paneRow, col: paneCol, width: gutterWidth, height: paneHeight
            ),
            clipRect: totalRect,
            viewport: GUIViewportSummary(
                top: 0, left: 0, rows: paneHeight, cols: paneWidth - gutterWidth,
                totalLines: UInt32(rowCount), visualRowOffset: 0,
                totalVisualRows: UInt32(rowCount)
            ),
            gutterMetrics: GUIGutterMetrics(lineNumberWidth: 5, signColWidth: 1),
            hitRegions: [GUIHitRegion(
                kind: .gutter,
                rect: GUICellRect(
                    row: paneRow, col: paneCol, width: gutterWidth, height: paneHeight
                ),
                windowId: windowID
            )]
        )
        let scroll = GUIScrollPresentation(
            windowId: windowID, resetRequired: false,
            anchorTop: 0, anchorLeft: 0, anchorVisualRowOffset: 0,
            visibleStartLine: 0, visibleEndLine: UInt32(visibleEnd),
            overscanStartLine: 0, overscanEndLine: UInt32(overscanEnd),
            contentEpoch: 1, layoutGeneration: 1, scrollSeq: 1
        )
        contents[windowID] = try GUIWindowContent(
            windowId: windowID, fullRefresh: true, contentEpoch: 1,
            cursorVisible: index == 0, cursorRow: 20, cursorCol: 8,
            cursorShape: .block, rows: rows, selection: nil,
            searchMatches: [], diagnosticUnderlines: [], documentHighlights: [],
            paneGeometry: geometry, scrollPresentation: scroll
        )
        sourceRows[windowID] = rows
        gutters[windowID] = Wire.WindowGutter(
            windowId: windowID,
            contentRow: paneRow, contentCol: paneCol,
            contentHeight: paneHeight, isActive: index == 0,
            contentWidth: paneWidth, cursorLine: 20,
            lineNumberStyle: .hybrid, lineNumberWidth: 5, signColWidth: 1,
            entries: (0..<overscanEnd).map { row in
                Wire.GutterEntry(
                    bufLine: UInt32(row), displayType: .normal, signType: .none,
                    foldEndLine: 0xFFFF_FFFF, signFg: 0, signText: ""
                )
            }
        )
    }

    var frameState = FrameState(cols: cols, rows: investigationRows)
    frameState.defaultBg = 0x1E1E1E
    frameState.totalLineCount = UInt32(investigationResidentRows)
    var metadata = EditorSnapshotMetadata.empty
    metadata.gutterCol = gutterWidth
    return InvestigationFixture(
        frameState: frameState, contents: contents, rows: sourceRows,
        gutters: gutters, metadata: metadata,
        visibleRowsPlusOverscanBound: visibleBound
    )
}

private func replacementContent(
    _ content: GUIWindowContent,
    version: Int,
    rowIndex: Int = 20
) throws -> GUIWindowContent {
    let row = GUIVisualRow(
        rowType: .normal,
        rowId: UInt64(rowIndex + 1),
        bufLine: UInt32(rowIndex),
        contentHash: UInt32(1_000_000 + version),
        text: "row \(rowIndex) let measuredValue = \(version)",
        spans: []
    )
    let delta = GUIWindowRowsDelta(
        windowId: content.windowId, contentEpoch: content.contentEpoch,
        cursorVisible: true, cursorRow: UInt16(rowIndex), cursorCol: 8,
        cursorShape: .block, scrollLeft: 0,
        baseRowCount: UInt32(content.rowStore.count),
        resultRowCount: UInt32(content.rowStore.count),
        rowSplices: [GUIWindowRowSplice(
            startIndex: UInt32(rowIndex), deleteCount: 1,
            insertEntries: [.full(row)]
        )],
        selection: nil, searchMatches: [], diagnosticUnderlines: [],
        documentHighlights: [], lineAnnotations: [],
        paneGeometry: content.paneGeometry, cursorline: nil,
        scrollPresentation: content.scrollPresentation
    )
    guard let next = content.applyingRowsDelta(delta) else {
        throw InvestigationError.rowMutationFailed
    }
    return next
}

@MainActor
private func investigationRenderer(
    probe: InvestigationProbe,
    fontManager: FontManager
) throws -> CoreTextMetalRenderer {
    guard let renderer = CoreTextMetalRenderer(factories: investigationFactories(probe)) else {
        throw InvestigationError.rendererUnavailable
    }
    renderer.setupRenderers(fontManager: fontManager)
    return renderer
}

@MainActor
private func investigationDrawable(
    renderer: CoreTextMetalRenderer,
    width: Int = 1_920,
    height: Int = 1_200
) throws -> InvestigationDrawable {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false
    )
    descriptor.usage = [.renderTarget, .shaderRead]
    guard let texture = renderer.device.makeTexture(descriptor: descriptor) else {
        throw InvestigationError.drawableUnavailable
    }
    return InvestigationDrawable(texture: texture)
}

@MainActor
private func measureInvestigationFrame(
    renderer: CoreTextMetalRenderer,
    snapshot: CommittedEditorSnapshot,
    fontManager: FontManager,
    drawable: InvestigationDrawable,
    probe: InvestigationProbe,
    cursorBlinkVisible: Bool,
    scrollOffset: SIMD2<Float>,
    inputSequence: UInt32
) async -> InvestigationFrameSample {
    await probe.measure {
        let start = investigationThreadCPUTimeNanoseconds()
        renderer.render(
            snapshot: snapshot,
            fontManager: fontManager,
            cursorBlinkVisible: cursorBlinkVisible,
            drawableProvider: { drawable },
            viewportSize: CGSize(width: 1_920, height: 1_200),
            contentScale: 1,
            scrollOffset: scrollOffset,
            presentationWindowId: 1,
            presentationInputSeq: inputSequence
        )
        return Double(investigationThreadCPUTimeNanoseconds() - start) / 1_000_000
    }
}

private func summarizeWorkload(
    name: String,
    phase: String,
    paneCount: Int,
    targetHz: Int?,
    residentRowCount: Int,
    visibleRowsPlusOverscanBound: Int,
    samples: [InvestigationFrameSample],
    maximumInFlight: Int
) -> InvestigationWorkloadMeasurement {
    let cpu = samples.map(\.drawCPUMs)
    let gpu = samples.map(\.gpuMs)
    let wall = samples.map(\.completionWallMs)
    return InvestigationWorkloadMeasurement(
        name: name,
        phase: phase,
        paneCount: paneCount,
        targetHz: targetHz,
        frameIntervalMs: targetHz.map { 1_000 / Double($0) },
        residentRowCount: residentRowCount,
        visibleRowsPlusOverscanBound: visibleRowsPlusOverscanBound,
        samples: samples,
        drawCPUP50Ms: investigationPercentile(cpu, 0.50),
        drawCPUP95Ms: investigationPercentile(cpu, 0.95),
        drawCPUP99Ms: investigationPercentile(cpu, 0.99),
        gpuP50Ms: investigationPercentile(gpu, 0.50),
        gpuP95Ms: investigationPercentile(gpu, 0.95),
        gpuP99Ms: investigationPercentile(gpu, 0.99),
        completionWallP50Ms: investigationPercentile(wall, 0.50),
        completionWallP95Ms: investigationPercentile(wall, 0.95),
        completionWallP99Ms: investigationPercentile(wall, 0.99),
        maximumInFlightGenerations: maximumInFlight,
        droppedFrameCount: samples.filter { !$0.presented }.count,
        peakRetainedNativeBytes: samples.map(\.retainedNativeBytes).max() ?? 0,
        peakResidentMemoryBytes: samples.map(\.residentMemoryBytes).max() ?? 0,
        totalTextureAllocations: samples.reduce(0) { $0 + $1.textureAllocationCount },
        totalBufferAllocations: samples.reduce(0) { $0 + $1.bufferAllocationCount },
        totalCandidateObjects: samples.reduce(0) { $0 + $1.candidateObjectCount },
        totalAtlasGrowthCopyBytes: samples.reduce(0) { $0 + $1.atlasGrowthCopyBytes },
        totalAtlasCopyOnWriteBytes: samples.reduce(0) { $0 + $1.atlasCopyOnWriteBytes },
        totalRasterUploadBytes: samples.reduce(0) { $0 + ($1.metrics?.textureUploadBytes ?? 0) },
        maximumEditorRowsVisited: samples.compactMap { $0.metrics?.editorRowsVisited }.max() ?? 0
    )
}

@MainActor
private func steadyWorkload(
    name: String,
    paneCount: Int,
    targetHz: Int?,
    fixture: InvestigationFixture,
    fontManager: FontManager,
    cursor: @escaping (Int) -> Bool,
    scroll: @escaping (Int) -> SIMD2<Float>
) async throws -> InvestigationWorkloadMeasurement {
    let probe = InvestigationProbe()
    let renderer = try investigationRenderer(probe: probe, fontManager: fontManager)
    let drawable = try investigationDrawable(renderer: renderer)
    let snapshot = try fixture.snapshot(generation: 1, frameSeq: 1)
    for index in 0..<investigationWarmupFrames {
        _ = await measureInvestigationFrame(
            renderer: renderer, snapshot: snapshot, fontManager: fontManager,
            drawable: drawable, probe: probe, cursorBlinkVisible: cursor(index),
            scrollOffset: scroll(index), inputSequence: UInt32(index + 1)
        )
    }
    var samples: [InvestigationFrameSample] = []
    for index in 0..<investigationMeasuredFrames {
        samples.append(await measureInvestigationFrame(
            renderer: renderer, snapshot: snapshot, fontManager: fontManager,
            drawable: drawable, probe: probe,
            cursorBlinkVisible: cursor(investigationWarmupFrames + index),
            scrollOffset: scroll(investigationWarmupFrames + index),
            inputSequence: UInt32(investigationWarmupFrames + index + 1)
        ))
    }
    return summarizeWorkload(
        name: name, phase: "steady_state", paneCount: paneCount,
        targetHz: targetHz, residentRowCount: investigationResidentRows,
        visibleRowsPlusOverscanBound: fixture.visibleRowsPlusOverscanBound,
        samples: samples, maximumInFlight: probe.maximumInFlight
    )
}

@MainActor
private func coldStartWorkload(
    fixture: InvestigationFixture,
    fontManager: FontManager
) async throws -> InvestigationWorkloadMeasurement {
    let probe = InvestigationProbe()
    let renderer = try investigationRenderer(probe: probe, fontManager: fontManager)
    let drawable = try investigationDrawable(renderer: renderer)
    let snapshot = try fixture.snapshot(generation: 1, frameSeq: 1)
    let sample = await measureInvestigationFrame(
        renderer: renderer, snapshot: snapshot, fontManager: fontManager,
        drawable: drawable, probe: probe, cursorBlinkVisible: true,
        scrollOffset: .zero, inputSequence: 1
    )
    return summarizeWorkload(
        name: "cold_start", phase: "cold_start", paneCount: 1, targetHz: nil,
        residentRowCount: investigationResidentRows,
        visibleRowsPlusOverscanBound: fixture.visibleRowsPlusOverscanBound,
        samples: [sample], maximumInFlight: probe.maximumInFlight
    )
}

@MainActor
private func oneRowEditWorkload(
    fixture: InvestigationFixture,
    fontManager: FontManager,
    paneCount: Int,
    editedWindowCount: Int = 1,
    name: String
) async throws -> InvestigationWorkloadMeasurement {
    let probe = InvestigationProbe()
    let renderer = try investigationRenderer(probe: probe, fontManager: fontManager)
    let drawable = try investigationDrawable(renderer: renderer)
    var contents = fixture.contents
    var sequence: UInt32 = 1
    let baseline = try fixture.snapshot(generation: 1, frameSeq: sequence, contents: contents)
    for index in 0..<investigationWarmupFrames {
        _ = await measureInvestigationFrame(
            renderer: renderer, snapshot: baseline, fontManager: fontManager,
            drawable: drawable, probe: probe, cursorBlinkVisible: true,
            scrollOffset: .zero, inputSequence: UInt32(index + 1)
        )
    }
    var samples: [InvestigationFrameSample] = []
    for index in 0..<investigationMeasuredFrames {
        for windowID in contents.keys.sorted().prefix(editedWindowCount) {
            guard let content = contents[windowID] else { continue }
            contents[windowID] = try replacementContent(
                content, version: index * editedWindowCount + Int(windowID)
            )
        }
        sequence += 1
        let snapshot = try fixture.snapshot(
            generation: sequence, frameSeq: sequence, contents: contents
        )
        samples.append(await measureInvestigationFrame(
            renderer: renderer, snapshot: snapshot, fontManager: fontManager,
            drawable: drawable, probe: probe, cursorBlinkVisible: true,
            scrollOffset: .zero,
            inputSequence: UInt32(investigationWarmupFrames + index + 1)
        ))
    }
    return summarizeWorkload(
        name: name, phase: editedWindowCount == 1 ? "ordinary_edit" : "resource_pressure",
        paneCount: paneCount, targetHz: 120,
        residentRowCount: investigationResidentRows,
        visibleRowsPlusOverscanBound: fixture.visibleRowsPlusOverscanBound,
        samples: samples, maximumInFlight: probe.maximumInFlight
    )
}

@MainActor
private func keyframeWorkload(
    fixture: InvestigationFixture,
    fontManager: FontManager
) async throws -> InvestigationWorkloadMeasurement {
    let probe = InvestigationProbe()
    let renderer = try investigationRenderer(probe: probe, fontManager: fontManager)
    let drawable = try investigationDrawable(renderer: renderer)
    var samples: [InvestigationFrameSample] = []
    for index in 0..<7 {
        var contents: [UInt16: GUIWindowContent] = [:]
        for windowID in fixture.rows.keys.sorted() {
            guard let rows = fixture.rows[windowID],
                  let prior = fixture.contents[windowID] else { continue }
            contents[windowID] = try GUIWindowContent(
                windowId: windowID, fullRefresh: true, contentEpoch: UInt32(index + 2),
                cursorVisible: windowID == 1, cursorRow: 20, cursorCol: 8,
                cursorShape: .block, rows: rows, selection: nil,
                searchMatches: [], diagnosticUnderlines: [], documentHighlights: [],
                paneGeometry: prior.paneGeometry,
                scrollPresentation: prior.scrollPresentation.map {
                    GUIScrollPresentation(
                        windowId: $0.windowId, resetRequired: true,
                        anchorTop: $0.anchorTop, anchorLeft: $0.anchorLeft,
                        anchorVisualRowOffset: $0.anchorVisualRowOffset,
                        visibleStartLine: $0.visibleStartLine,
                        visibleEndLine: $0.visibleEndLine,
                        overscanStartLine: $0.overscanStartLine,
                        overscanEndLine: $0.overscanEndLine,
                        contentEpoch: UInt32(index + 2),
                        layoutGeneration: $0.layoutGeneration + UInt32(index + 1),
                        scrollSeq: $0.scrollSeq + UInt32(index + 1)
                    )
                }
            )
        }
        let sequence = UInt32(index + 1)
        let snapshot = try fixture.snapshot(
            generation: sequence, frameSeq: sequence, contents: contents
        )
        samples.append(await measureInvestigationFrame(
            renderer: renderer, snapshot: snapshot, fontManager: fontManager,
            drawable: drawable, probe: probe, cursorBlinkVisible: true,
            scrollOffset: .zero, inputSequence: sequence
        ))
    }
    return summarizeWorkload(
        name: "keyframe", phase: "atlas_growth", paneCount: 1, targetHz: nil,
        residentRowCount: investigationResidentRows,
        visibleRowsPlusOverscanBound: fixture.visibleRowsPlusOverscanBound,
        samples: samples, maximumInFlight: probe.maximumInFlight
    )
}

private func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "unknown"
    }
}

@MainActor
func runNativeResourceInvestigation(outputURL: URL) async throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw InvestigationError.rendererUnavailable
    }
    let fontManager = FontManager(name: "Menlo", size: 13, scale: 1)
    let onePane = try investigationFixture(paneCount: 1)
    let fourPanes = try investigationFixture(paneCount: 4)
    let eightPanes = try investigationFixture(paneCount: 8)
    var workloads: [InvestigationWorkloadMeasurement] = []
    workloads.append(try await coldStartWorkload(fixture: onePane, fontManager: fontManager))
    workloads.append(try await steadyWorkload(
        name: "idle_redraw", paneCount: 1, targetHz: nil,
        fixture: onePane, fontManager: fontManager,
        cursor: { _ in true }, scroll: { _ in .zero }
    ))
    workloads.append(try await steadyWorkload(
        name: "cursor_blink_60hz", paneCount: 1, targetHz: 60,
        fixture: onePane, fontManager: fontManager,
        cursor: { $0.isMultiple(of: 2) }, scroll: { _ in .zero }
    ))
    workloads.append(try await steadyWorkload(
        name: "cursor_blink_120hz", paneCount: 1, targetHz: 120,
        fixture: onePane, fontManager: fontManager,
        cursor: { $0.isMultiple(of: 2) }, scroll: { _ in .zero }
    ))
    workloads.append(try await steadyWorkload(
        name: "local_scroll_60hz", paneCount: 1, targetHz: 60,
        fixture: onePane, fontManager: fontManager,
        cursor: { _ in true },
        scroll: { SIMD2<Float>(0, Float($0 % 4) * -0.25) }
    ))
    workloads.append(try await steadyWorkload(
        name: "local_scroll_120hz", paneCount: 1, targetHz: 120,
        fixture: onePane, fontManager: fontManager,
        cursor: { _ in true },
        scroll: { SIMD2<Float>(0, Float($0 % 4) * -0.25) }
    ))
    workloads.append(try await oneRowEditWorkload(
        fixture: onePane, fontManager: fontManager, paneCount: 1,
        name: "one_row_edit"
    ))
    workloads.append(try await keyframeWorkload(fixture: onePane, fontManager: fontManager))
    workloads.append(try await steadyWorkload(
        name: "panes_1", paneCount: 1, targetHz: 120,
        fixture: onePane, fontManager: fontManager,
        cursor: { _ in true }, scroll: { _ in .zero }
    ))
    workloads.append(try await steadyWorkload(
        name: "panes_4", paneCount: 4, targetHz: 120,
        fixture: fourPanes, fontManager: fontManager,
        cursor: { _ in true }, scroll: { _ in .zero }
    ))
    workloads.append(try await steadyWorkload(
        name: "panes_8", paneCount: 8, targetHz: 120,
        fixture: eightPanes, fontManager: fontManager,
        cursor: { _ in true }, scroll: { _ in .zero }
    ))
    workloads.append(try await oneRowEditWorkload(
        fixture: fourPanes, fontManager: fontManager, paneCount: 4,
        name: "one_row_edit_panes_4"
    ))
    workloads.append(try await oneRowEditWorkload(
        fixture: eightPanes, fontManager: fontManager, paneCount: 8,
        name: "one_row_edit_panes_8"
    ))
    workloads.append(try await oneRowEditWorkload(
        fixture: eightPanes, fontManager: fontManager, paneCount: 8,
        editedWindowCount: 8,
        name: "atlas_miss_resource_pressure"
    ))

    let processInfo = ProcessInfo.processInfo
    let environment = InvestigationEnvironment(
        measuredAt: ISO8601DateFormatter().string(from: Date()),
        revision: processInfo.environment["MINGA_BENCHMARK_REVISION"] ?? "unknown",
        deviceName: device.name,
        deviceRegistryID: device.registryID,
        operatingSystem: processInfo.operatingSystemVersionString,
        processorCount: processInfo.activeProcessorCount,
        physicalMemoryBytes: processInfo.physicalMemory,
        thermalState: thermalStateName(processInfo.thermalState),
        lowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
        compilerFlags: ["-O", "-DMINGA_SNAPSHOT_RENDERER", "-DMINGA_TRANSCRIPT_ACCOUNTING"],
        workloadOrder: workloads.map(\.name)
    )
    let report = NativeResourceInvestigationReport(
        schemaVersion: 1,
        fixture: "native-resource-lifetime-investigation-v1",
        environment: environment,
        workloads: workloads
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: outputURL, options: .atomic)
}
