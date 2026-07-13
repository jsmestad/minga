import CoreText
import Metal
import MingaProtocol
@testable import MingaUI
import QuartzCore
import Testing

private final class NativeTestDrawable: NSObject, CAMetalDrawable {
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

private enum InjectedSubmissionFailure: Error { case failed }

@Suite("Failure-atomic native render demand")
struct NativeRenderResourcesTests {
    private let policy = FrameResourcePolicy.NativeRendererLimits(
        rasterBytes: 4_096, atlasBytes: 16_384,
        aggregateDrawBufferBytes: 8_192, renderTargetBytes: 4_096,
        textureWidth: 128, textureHeight: 128
    )

    @MainActor private func nativeTestFactories() -> NativeRenderFactories {
        var factories = NativeRenderFactories.production
        factories.makeLibrary = { device in
            Bundle.allBundles.lazy.compactMap { try? device.makeDefaultLibrary(bundle: $0) }.first
        }
        return factories
    }

    @Test("checked multiply overflow is a typed local failure")
    func multiplyOverflow() {
        #expect(throws: NativePresentationFailure.self) {
            _ = try NativeRenderDemand.checked(
                textureWidth: Int.max, slotHeight: 2, atlasSlots: 1,
                lineInstances: 0, lineStride: 32,
                quadInstances: 0, quadStride: 48, quadBufferCount: 3,
                policy: policy, deviceTextureWidth: Int.max,
                deviceTextureHeight: Int.max, deviceMaxBufferLength: Int.max
            )
        }
    }

    @Test("checked aggregate add overflow is a typed local failure")
    func addOverflow() {
        let permissive = FrameResourcePolicy.NativeRendererLimits(
            rasterBytes: .max, atlasBytes: .max,
            aggregateDrawBufferBytes: .max,
            textureWidth: 1, textureHeight: 1
        )
        #expect(throws: NativePresentationFailure.self) {
            _ = try NativeRenderDemand.checked(
                textureWidth: 1, slotHeight: 1, atlasSlots: 1,
                lineInstances: Int.max / 2, lineStride: 2,
                quadInstances: 1, quadStride: 2, quadBufferCount: 1,
                policy: permissive, deviceTextureWidth: 1,
                deviceTextureHeight: 1, deviceMaxBufferLength: .max
            )
        }
    }

    @Test("exact texture atlas raster and triple-buffer boundaries pass")
    func exactBoundaries() throws {
        let demand = try NativeRenderDemand.checked(
            textureWidth: 64, slotHeight: 16, atlasSlots: 4,
            lineInstances: 64, lineStride: 32,
            quadInstances: 32, quadStride: 48, quadBufferCount: 3,
            policy: policy, deviceTextureWidth: 128,
            deviceTextureHeight: 128, deviceMaxBufferLength: 8_192
        )
        #expect(demand.rasterBytes == 4_096)
        #expect(demand.atlasBytes == 16_384)
        #expect(demand.textureHeight == 64)
        #expect(demand.lineBufferBytes == 2_048)
        #expect(demand.quadBufferBytes == 4_608)
        #expect(demand.aggregateDrawBufferBytes == 6_656)
    }

    @Test("offscreen target dimensions and bytes are checked before allocation")
    func checkedRenderTargetDemand() throws {
        let exact = try NativeRenderTargetDemand.checked(
            width: 32, height: 32, policy: policy,
            deviceTextureDimension: 128, frameSequence: 5
        )
        #expect(exact.byteCount == 4_096)

        #expect(throws: NativePresentationFailure.self) {
            _ = try NativeRenderTargetDemand.checked(
                width: 33, height: 32, policy: policy,
                deviceTextureDimension: 128, frameSequence: 6
            )
        }
        #expect(throws: NativePresentationFailure.self) {
            _ = try NativeRenderTargetDemand.checked(
                width: 129, height: 1, policy: policy,
                deviceTextureDimension: 128, frameSequence: 7
            )
        }
    }

    @Test("atlas slots derive from bytes and native geometry")
    func derivedAtlasSlots() throws {
        #expect(try NativeRenderDemand.maximumAtlasSlots(
            textureWidth: 64, slotHeight: 16, policy: policy,
            deviceTextureHeight: 48
        ) == 3)
    }

    @Test("one byte beyond each hard ceiling fails without truncation")
    func beyondBoundaries() {
        #expect(throws: NativePresentationFailure.self) {
            _ = try NativeRenderDemand.checked(
                textureWidth: 65, slotHeight: 16, atlasSlots: 4,
                lineInstances: 0, lineStride: 32,
                quadInstances: 0, quadStride: 48, quadBufferCount: 3,
                policy: policy, deviceTextureWidth: 128,
                deviceTextureHeight: 128, deviceMaxBufferLength: 8_192
            )
        }
        #expect(throws: NativePresentationFailure.self) {
            _ = try NativeRenderDemand.checked(
                textureWidth: 64, slotHeight: 16, atlasSlots: 5,
                lineInstances: 0, lineStride: 32,
                quadInstances: 0, quadStride: 48, quadBufferCount: 3,
                policy: policy, deviceTextureWidth: 128,
                deviceTextureHeight: 128, deviceMaxBufferLength: 8_192
            )
        }
    }

    @Test("line and every triple-buffered quad allocation contribute to aggregate demand")
    func aggregateBufferClasses() throws {
        let demand = try NativeRenderDemand.checked(
            textureWidth: 1, slotHeight: 1, atlasSlots: 1,
            lineInstances: 17, lineStride: MemoryLayout<LineGPU>.stride,
            quadInstances: 19, quadStride: MemoryLayout<QuadGPU>.stride,
            quadBufferCount: 3, policy: policy,
            deviceTextureWidth: 128, deviceTextureHeight: 128,
            deviceMaxBufferLength: 8_192
        )
        #expect(demand.lineBufferBytes == 17 * MemoryLayout<LineGPU>.stride)
        #expect(demand.quadBufferBytes == 19 * MemoryLayout<QuadGPU>.stride * 3)
        #expect(demand.aggregateDrawBufferBytes == demand.lineBufferBytes + demand.quadBufferBytes)
    }

    @Test("aggregate may exceed the per-buffer device limit when every buffer fits")
    func aggregateMayExceedDeviceLimit() throws {
        let boundaryPolicy = FrameResourcePolicy.NativeRendererLimits(
            rasterBytes: 4, atlasBytes: 4, aggregateDrawBufferBytes: 400,
            textureWidth: 1, textureHeight: 1
        )
        let demand = try NativeRenderDemand.checked(
            textureWidth: 1, slotHeight: 1, atlasSlots: 1,
            lineInstances: 80, lineStride: 1,
            quadInstances: 80, quadStride: 1, quadBufferCount: 3,
            policy: boundaryPolicy, deviceTextureWidth: 1,
            deviceTextureHeight: 1, deviceMaxBufferLength: 100
        )
        let prepared = try NativeDrawBufferDemand.checked(
            lineCount: 80, lineStride: 1, quadPassCounts: [80], quadStride: 1,
            quadBufferCount: 3, alignment: 0, limit: 400,
            deviceLimit: 100, frameSequence: 1
        )
        #expect(demand.aggregateDrawBufferBytes == 320)
        #expect(prepared.aggregateBytes == 320)
    }

    @Test("one individual buffer above the device limit fails")
    func individualBufferExceedsDeviceLimit() {
        let boundaryPolicy = FrameResourcePolicy.NativeRendererLimits(
            rasterBytes: 4, atlasBytes: 4, aggregateDrawBufferBytes: 1_000,
            textureWidth: 1, textureHeight: 1
        )
        #expect(throws: NativePresentationFailure.self) {
            _ = try NativeRenderDemand.checked(
                textureWidth: 1, slotHeight: 1, atlasSlots: 1,
                lineInstances: 101, lineStride: 1,
                quadInstances: 1, quadStride: 1, quadBufferCount: 3,
                policy: boundaryPolicy, deviceTextureWidth: 1,
                deviceTextureHeight: 1, deviceMaxBufferLength: 100
            )
        }
        #expect(throws: NativePresentationFailure.self) {
            _ = try NativeDrawBufferDemand.checked(
                lineCount: 101, lineStride: 1, quadPassCounts: [1], quadStride: 1,
                quadBufferCount: 3, alignment: 0, limit: 1_000,
                deviceLimit: 100, frameSequence: 2
            )
        }
    }

    @Test("aggregate above product policy fails even when each buffer fits the device")
    func aggregateExceedsProductPolicy() {
        let boundaryPolicy = FrameResourcePolicy.NativeRendererLimits(
            rasterBytes: 4, atlasBytes: 4, aggregateDrawBufferBytes: 319,
            textureWidth: 1, textureHeight: 1
        )
        #expect(throws: NativePresentationFailure.self) {
            _ = try NativeRenderDemand.checked(
                textureWidth: 1, slotHeight: 1, atlasSlots: 1,
                lineInstances: 80, lineStride: 1,
                quadInstances: 80, quadStride: 1, quadBufferCount: 3,
                policy: boundaryPolicy, deviceTextureWidth: 1,
                deviceTextureHeight: 1, deviceMaxBufferLength: 100
            )
        }
        #expect(throws: NativePresentationFailure.self) {
            _ = try NativeDrawBufferDemand.checked(
                lineCount: 80, lineStride: 1, quadPassCounts: [80], quadStride: 1,
                quadBufferCount: 3, alignment: 0, limit: 319,
                deviceLimit: 100, frameSequence: 3
            )
        }
    }

    @Test("65,536 visible rows retain a fixed exact instance range")
    func fixedVisibleRange65536() throws {
        let permissive = FrameResourcePolicy.NativeRendererLimits(
            rasterBytes: 1_048_576, atlasBytes: 1_073_741_824,
            aggregateDrawBufferBytes: 1_073_741_824,
            textureWidth: 1, textureHeight: 65_536
        )
        let demand = try NativeRenderDemand.checked(
            textureWidth: 1, slotHeight: 1, atlasSlots: 65_536,
            lineInstances: 65_536, lineStride: MemoryLayout<LineGPU>.stride,
            quadInstances: 0, quadStride: MemoryLayout<QuadGPU>.stride,
            quadBufferCount: 3, policy: permissive,
            deviceTextureWidth: 1, deviceTextureHeight: 65_536,
            deviceMaxBufferLength: 1_073_741_824
        )
        #expect(demand.atlasSlots == 65_536)
        #expect(demand.lineInstances == 65_536)
        #expect(demand.lineBufferBytes == 65_536 * MemoryLayout<LineGPU>.stride)
    }

    @Test("atlas texture factory refusal preserves allocator index and cache")
    @MainActor func atlasTextureRefusalIsAtomic() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let atlas = LineTextureAtlas(
            device: device, slotHeight: 16, policy: policy,
            makeTexture: { _, _ in nil }
        )
        let originalAllocator = atlas.allocator
        let result = atlas.ensureCapacity(maxSlots: 4, width: 64, frameSequence: 42)
        guard case .failure(let failure) = result else {
            Issue.record("texture refusal unexpectedly succeeded")
            return
        }
        #expect(failure.phase == .atlas)
        #expect(failure.dimension == .texture)
        #expect(atlas.slotCount == originalAllocator.capacity)
        #expect(atlas.texture == nil)
    }

    @Test("atlas exhaustion records one typed slot failure")
    @MainActor func atlasFullIsTyped() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let atlas = LineTextureAtlas(device: device, slotHeight: 16, policy: policy)
        atlas.beginFrame()

        if case .some = atlas.lookupOrReserve(
            key: .bufferRow(windowId: 1, rowId: 1), contentHash: 1
        ) {
            Issue.record("zero-capacity atlas unexpectedly reserved a slot")
        }
        #expect(atlas.nativePresentationFailure == NativePresentationFailure(
            phase: .atlas, dimension: .atlasSlots,
            requested: 1, limit: 0, reason: .limit
        ))

        _ = atlas.lookupOrReserve(key: .bufferRow(windowId: 1, rowId: 2), contentHash: 2)
        #expect(atlas.nativePresentationFailure?.requested == 1)
    }

    @Test("no-growth COW staging refusal leaves the active atlas untouched")
    @MainActor func noGrowthUploadRefusalIsAtomic() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var refuseStaging = false
        let atlas = LineTextureAtlas(
            device: device, slotHeight: 16, policy: policy,
            allocateStaging: { refuseStaging ? nil : malloc($0) },
            deallocateStaging: { free($0) }
        )
        guard case .success = atlas.ensureCapacity(maxSlots: 4, width: 64) else { return }
        atlas.beginFrame()
        let key = AtlasKey.bufferRow(windowId: 1, rowId: 9)
        guard case .reserved(let reservation)? = atlas.lookupOrReserve(key: key, contentHash: 1),
              let bytes = malloc(64 * 16 * 4) else { return }
        defer { free(bytes) }
        memset(bytes, 0x7f, 64 * 16 * 4)
        #expect(atlas.commitUpload(reservation: reservation, pointer: bytes,
                                  pixelWidth: 64, bytesPerRow: 256) != nil)
        let activeAllocator = atlas.allocator
        let activeTexture = atlas.texture.map(ObjectIdentifier.init)

        let candidate = atlas.makeCandidate()
        candidate.beginFrame()
        guard case .reserved(let changed)? = candidate.lookupOrReserve(key: key, contentHash: 2) else { return }
        let candidateAllocator = candidate.allocator
        let candidateTexture = candidate.texture.map(ObjectIdentifier.init)
        refuseStaging = true
        #expect(candidate.commitUpload(reservation: changed, pointer: bytes,
                                       pixelWidth: 64, bytesPerRow: 256) == nil)
        #expect(candidate.nativePresentationFailure?.phase == .atlas)
        #expect(candidate.nativePresentationFailure?.dimension == .atlasBytes)
        #expect(candidate.allocator == candidateAllocator)
        #expect(candidate.texture.map(ObjectIdentifier.init) == candidateTexture)
        #expect(atlas.allocator == activeAllocator)
        #expect(atlas.texture.map(ObjectIdentifier.init) == activeTexture)
    }

    @Test("growth COW staging refusal rolls back texture and allocator")
    @MainActor func growthStagingRefusalIsAtomic() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var refuseStaging = false
        let atlas = LineTextureAtlas(
            device: device, slotHeight: 16, policy: policy,
            allocateStaging: { refuseStaging ? nil : malloc($0) },
            deallocateStaging: { free($0) }
        )
        guard case .success = atlas.ensureCapacity(maxSlots: 2, width: 32) else { return }
        let activeAllocator = atlas.allocator
        let activeTexture = atlas.texture.map(ObjectIdentifier.init)
        let activeWidth = atlas.atlasWidth
        let activeHeight = atlas.atlasHeight

        refuseStaging = true
        let result = atlas.ensureCapacity(maxSlots: 4, width: 64, frameSequence: 43)
        guard case .failure(let failure) = result else {
            Issue.record("staging refusal unexpectedly grew atlas")
            return
        }
        #expect(failure.phase == .atlas)
        #expect(failure.dimension == .atlasBytes)
        #expect(failure.reason == .allocation)
        #expect(atlas.allocator == activeAllocator)
        #expect(atlas.texture.map(ObjectIdentifier.init) == activeTexture)
        #expect(atlas.atlasWidth == activeWidth)
        #expect(atlas.atlasHeight == activeHeight)
    }

    @Test("late older completion cannot replace a newer completed generation")
    func completionOrdering() {
        var ordering = NativePresentationGeneration()
        let older = ordering.issue()
        let newer = ordering.issue()
        let promotedNewer = ordering.complete(newer)
        let promotedOlder = ordering.complete(older)
        #expect(promotedNewer)
        #expect(!promotedOlder)
        #expect(ordering.completed == newer)
    }

    @Test("production raster allocator refusal is a typed local failure")
    @MainActor func productionRasterAllocatorRefusal() {
        let rasterizer = BitmapRasterizer()
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "x"))
        do {
            _ = try rasterizer.rasterize(
                line, width: Int.max / 8, height: 1, scale: 1, descent: 0
            )
            Issue.record("operating-system allocator unexpectedly accepted an impossible request")
        } catch let failure as NativePresentationFailure {
            #expect(failure.phase == .raster)
            #expect(failure.dimension == .buffer)
            #expect(failure.reason == .allocation)
        } catch {
            Issue.record("unexpected failure type: \(error)")
        }
    }

    @Test("raster allocation refusal is typed and does not create a context")
    @MainActor func rasterAllocationFailure() {
        var contextCalls = 0
        let rasterizer = BitmapRasterizer(factories: .init(
            allocate: { _ in nil },
            deallocate: { free($0) },
            makeContext: { _, _, _, _, _, _ in
                contextCalls += 1
                return nil
            }
        ))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "x"))
        #expect(throws: NativePresentationFailure.self) {
            _ = try rasterizer.rasterize(line, width: 8, height: 16, scale: 1, descent: 2)
        }
        #expect(contextCalls == 0)
    }

    @Test("raster context refusal is typed after successful candidate allocation")
    @MainActor func rasterContextFailure() {
        let rasterizer = BitmapRasterizer(factories: .init(
            allocate: { malloc($0) },
            deallocate: { free($0) },
            makeContext: { _, _, _, _, _, _ in nil }
        ))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "x"))
        do {
            _ = try rasterizer.rasterize(line, width: 8, height: 16, scale: 1, descent: 2)
            Issue.record("context refusal unexpectedly rasterized")
        } catch let failure as NativePresentationFailure {
            #expect(failure.phase == .raster)
            #expect(failure.dimension == .rasterContext)
            #expect(failure.reason == .context)
        } catch {
            Issue.record("unexpected failure type: \(error)")
        }
    }

    @Test("rasterizer releases cached context before freeing its pool")
    @MainActor func rasterizerTeardownOrdering() throws {
        weak var cachedContext: CGContext?
        var contextReleasedBeforeFree = false
        var rasterizer: BitmapRasterizer? = BitmapRasterizer(factories: .init(
            allocate: { malloc($0) },
            deallocate: { pointer in
                contextReleasedBeforeFree = cachedContext == nil
                free(pointer)
            },
            makeContext: { data, width, height, bytesPerRow, colorSpace, bitmapInfo in
                let context = CGContext(
                    data: data, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo
                )
                cachedContext = context
                return context
            }
        ))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "x"))
        _ = try rasterizer?.rasterize(line, width: 8, height: 16, scale: 1, descent: 2)
        #expect(cachedContext != nil)

        rasterizer = nil
        #expect(contextReleasedBeforeFree)
    }

    @Test("exact aggregate includes alignment once for every prebuilt quad pass")
    func exactAlignedAggregate() throws {
        let demand = try NativeDrawBufferDemand.checked(
            lineCount: 2, lineStride: 32,
            quadPassCounts: [1, 2, 0, 3], quadStride: 48,
            quadBufferCount: 3, alignment: 256,
            limit: 4_096, deviceLimit: 4_096, frameSequence: 9
        )
        #expect(demand.lineBytes == 64)
        #expect(demand.quadBytesPerBuffer == 656)
        #expect(demand.aggregateBytes == 64 + (656 * 3))
    }

    @Test("each exact line and quad candidate allocation failure is atomic")
    @MainActor func eachBufferClassFailureIsAtomic() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let drawableDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: 640, height: 128, mipmapped: false
        )
        drawableDescriptor.usage = .renderTarget
        guard let drawableTexture = device.makeTexture(descriptor: drawableDescriptor) else { return }
        let row = GUIVisualRow(rowType: .normal, rowId: 1, bufLine: 0,
                               contentHash: 1, text: "atomic", spans: [])
        let content = try GUIWindowContent(
            windowId: 1, fullRefresh: true, cursorRow: 0, cursorCol: 0,
            cursorShape: .block, rows: [row], selection: nil,
            searchMatches: [], diagnosticUnderlines: [], documentHighlights: []
        )
        var frame = FrameState(cols: 40, rows: 2)
        frame.windowGutters[1] = Wire.WindowGutter(
            windowId: 1, contentRow: 0, contentCol: 0, contentHeight: 2,
            isActive: true, contentWidth: 40, cursorLine: 0,
            lineNumberStyle: .absolute, lineNumberWidth: 2, signColWidth: 1,
            entries: [.init(bufLine: 0, displayType: .normal, signType: .none)]
        )
        let expected: [NativeRenderResourceDimension] = [
            .lineBuffer, .quadBuffer0, .quadBuffer1, .quadBuffer2
        ]
        for preallocatedAtlas in [false, true] {
            for failedCall in expected.indices {
                var bufferCall = 0
                var reports: [NativePresentationFailure] = []
                var presentCalls = 0
                var factories = nativeTestFactories()
                factories.makeBuffer = { device, length, options in
                    defer { bufferCall += 1 }
                    return bufferCall == failedCall ? nil : device.makeBuffer(length: length, options: options)
                }
                factories.present = { _ in presentCalls += 1 }
                factories.reportFailure = { reports.append($0) }
                guard let renderer = CoreTextMetalRenderer(factories: factories) else { continue }
                let fontManager = FontManager(name: "Menlo", size: 13, scale: 1)
                renderer.setupRenderers(fontManager: fontManager)
                if preallocatedAtlas {
                    guard case .success = renderer.atlas?.ensureCapacity(maxSlots: 32, width: 640) else {
                        Issue.record("failed to prepare no-growth atlas")
                        return
                    }
                }
                let before = renderer.activeResourceSnapshot()
                renderer.render(
                    frameState: frame, fontManager: fontManager,
                    windowContents: [1: content],
                    drawableProvider: { NativeTestDrawable(texture: drawableTexture) },
                    viewportSize: CGSize(width: 640, height: 128), contentScale: 1,
                    presentationInputSeq: UInt32(100 + failedCall)
                )
                #expect(reports.count == 1)
                #expect(reports.first?.dimension == expected[failedCall])
                #expect(renderer.activeResourceSnapshot() == before)
                #expect(renderer.lastCompletedPresentationGeneration == 0)
                #expect(presentCalls == 0)
            }
        }
    }

    @Test("growth preparation failures stay local across atlas raster context and encoder phases")
    @MainActor func growthPreparationFailuresAreAtomic() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let drawableDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: 640, height: 128, mipmapped: false
        )
        drawableDescriptor.usage = .renderTarget
        guard let drawableTexture = device.makeTexture(descriptor: drawableDescriptor) else { return }
        let row = GUIVisualRow(rowType: .normal, rowId: 2, bufLine: 0,
                               contentHash: 2, text: "fault", spans: [])
        let content = try GUIWindowContent(
            windowId: 1, fullRefresh: true, cursorRow: 0, cursorCol: 0,
            cursorShape: .block, rows: [row], selection: nil,
            searchMatches: [], diagnosticUnderlines: [], documentHighlights: []
        )
        var frame = FrameState(cols: 40, rows: 2)
        frame.windowGutters[1] = Wire.WindowGutter(
            windowId: 1, contentRow: 0, contentCol: 0, contentHeight: 2,
            isActive: true, contentWidth: 40, cursorLine: 0,
            lineNumberStyle: .none, lineNumberWidth: 0, signColWidth: 0,
            entries: [.init(bufLine: 0, displayType: .normal, signType: .none)]
        )
        let cases: [(NativePresentationFailure.Phase, (inout NativeRenderFactories) -> Void)] = [
            (.atlas, { factories in factories.makeTexture = { _, _ in nil } }),
            (.raster, { factories in
                factories.makeRasterizer = {
                    BitmapRasterizer(factories: .init(
                        allocate: { _ in nil },
                        deallocate: { free($0) },
                        makeContext: { _, _, _, _, _, _ in nil }
                    ))
                }
            }),
            (.raster, { factories in
                factories.makeRasterizer = {
                    BitmapRasterizer(factories: .init(
                        allocate: { malloc($0) },
                        deallocate: { free($0) },
                        makeContext: { _, _, _, _, _, _ in nil }
                    ))
                }
            }),
            (.command, { factories in factories.makeEncoder = { _, _ in nil } })
        ]
        for (expectedPhase, configure) in cases {
            var reports: [NativePresentationFailure] = []
            var presentCalls = 0
            var factories = nativeTestFactories()
            configure(&factories)
            factories.present = { _ in presentCalls += 1 }
            factories.reportFailure = { reports.append($0) }
            guard let renderer = CoreTextMetalRenderer(factories: factories) else {
                Issue.record("renderer unavailable")
                return
            }
            let fontManager = FontManager(name: "Menlo", size: 13, scale: 1)
            renderer.setupRenderers(fontManager: fontManager)
            let before = renderer.activeResourceSnapshot()
            renderer.render(
                frameState: frame, fontManager: fontManager,
                windowContents: [1: content],
                drawableProvider: { NativeTestDrawable(texture: drawableTexture) },
                viewportSize: CGSize(width: 640, height: 128), contentScale: 1,
                presentationInputSeq: 200
            )
            #expect(reports.count == 1)
            #expect(reports.first?.phase == expectedPhase)
            #expect(renderer.activeResourceSnapshot() == before)
            #expect(renderer.lastCompletedPresentationGeneration == 0)
            #expect(presentCalls == 0)
        }
    }

    @Test("submission gate failure preserves active generation and never registers present")
    @MainActor func submissionFailurePrecedesPresent() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: 64, height: 64, mipmapped: false
        )
        descriptor.usage = .renderTarget
        guard let texture = device.makeTexture(descriptor: descriptor) else { return }

        var reports: [NativePresentationFailure] = []
        var presentCalls = 0
        var factories = nativeTestFactories()
        factories.preSubmit = { _ in throw InjectedSubmissionFailure.failed }
        factories.present = { _ in presentCalls += 1 }
        factories.reportFailure = { reports.append($0) }
        guard let renderer = CoreTextMetalRenderer(factories: factories) else { return }
        let fontManager = FontManager(name: "Menlo", size: 13, scale: 1)
        renderer.setupRenderers(fontManager: fontManager)
        let before = renderer.activeResourceSnapshot()

        renderer.render(
            frameState: FrameState(cols: 4, rows: 4), fontManager: fontManager,
            drawableProvider: { NativeTestDrawable(texture: texture) },
            viewportSize: CGSize(width: 64, height: 64), contentScale: 1,
            presentationInputSeq: 77
        )

        #expect(presentCalls == 0)
        #expect(reports.count == 1)
        #expect(reports.first?.phase == .submission)
        #expect(renderer.lastNativePresentationFailure == reports.first)
        #expect(renderer.activeResourceSnapshot() == before)
        #expect(renderer.lastCompletedPresentationGeneration == 0)
    }

    @Test("completion failure cannot promote its candidate generation")
    @MainActor func completionFailureIsAtomic() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: 64, height: 64, mipmapped: false
        )
        descriptor.usage = .renderTarget
        guard let texture = device.makeTexture(descriptor: descriptor) else { return }
        var reports: [NativePresentationFailure] = []
        var factories = nativeTestFactories()
        factories.present = { _ in }
        factories.observeCompletion = { _, completion in
            completion(false, Int(MTLCommandBufferStatus.error.rawValue))
        }
        factories.reportFailure = { reports.append($0) }
        guard let renderer = CoreTextMetalRenderer(factories: factories) else {
            Issue.record("renderer unavailable")
            return
        }
        let fontManager = FontManager(name: "Menlo", size: 13, scale: 1)
        renderer.setupRenderers(fontManager: fontManager)
        let before = renderer.activeResourceSnapshot()
        renderer.render(
            frameState: FrameState(cols: 4, rows: 4), fontManager: fontManager,
            drawableProvider: { NativeTestDrawable(texture: texture) },
            viewportSize: CGSize(width: 64, height: 64), contentScale: 1,
            presentationInputSeq: 301
        )
        #expect(reports.count == 1)
        #expect(reports.first?.phase == .completion)
        #expect(renderer.activeResourceSnapshot() == before)
        #expect(renderer.lastCompletedPresentationGeneration == 0)
    }

    @Test("candidate presents and promotes only after both commands complete")
    @MainActor func twoStagePresentationOrdering() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: 64, height: 64, mipmapped: false
        )
        descriptor.usage = .renderTarget
        guard let texture = device.makeTexture(descriptor: descriptor) else { return }

        typealias Completion = @MainActor @Sendable (Bool, Int) -> Void
        var completions: [Completion] = []
        var presentCalls = 0
        let metrics = GUIFramePresentationMetrics()
        let committedFrame = GUICommittedFrame(generation: 3, frameSeq: 42)
        metrics.beginCommitted(frame: committedFrame, impact: .editor)
        var factories = nativeTestFactories()
        factories.observeCompletion = { _, completion in completions.append(completion) }
        factories.present = { _ in presentCalls += 1 }
        guard let renderer = CoreTextMetalRenderer(factories: factories) else { return }
        renderer.presentationMetrics = metrics
        let fontManager = FontManager(name: "Menlo", size: 13, scale: 1)
        renderer.setupRenderers(fontManager: fontManager)
        let before = renderer.activeResourceSnapshot()

        renderer.render(
            frameState: FrameState(cols: 4, rows: 4), fontManager: fontManager,
            drawableProvider: { NativeTestDrawable(texture: texture) },
            viewportSize: CGSize(width: 64, height: 64), contentScale: 1,
            presentationInputSeq: 302, presentationFrameSeq: 42
        )
        #expect(completions.count == 1)
        #expect(presentCalls == 0)
        #expect(metrics.snapshot().isEmpty)
        #expect(renderer.activeResourceSnapshot() == before)

        completions[0](true, Int(MTLCommandBufferStatus.completed.rawValue))
        #expect(completions.count == 2)
        #expect(presentCalls == 0)
        #expect(metrics.snapshot() == [
            .init(frame: committedFrame, domain: .editor, outcome: .submitted)
        ])
        #expect(renderer.activeResourceSnapshot() == before)

        completions[1](true, Int(MTLCommandBufferStatus.completed.rawValue))
        #expect(presentCalls == 1)
        #expect(metrics.snapshot() == [
            .init(frame: committedFrame, domain: .editor, outcome: .submitted),
            .init(frame: committedFrame, domain: .editor, outcome: .presented)
        ])
        #expect(renderer.lastCompletedPresentationGeneration == 1)
        #expect(renderer.activeResourceSnapshot() != before)
    }

    @Test("failed frame preserves a populated completed frame")
    @MainActor func failedFramePreservesPopulatedFrame() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: 64, height: 64, mipmapped: false
        )
        descriptor.usage = .renderTarget
        guard let texture = device.makeTexture(descriptor: descriptor) else { return }
        let row = GUIVisualRow(rowType: .normal, rowId: 41, bufLine: 0,
                               contentHash: 41, text: "ok", spans: [])
        let content = try GUIWindowContent(
            windowId: 1, fullRefresh: true, cursorRow: 0, cursorCol: 0,
            cursorShape: .block, rows: [row], selection: nil,
            searchMatches: [], diagnosticUnderlines: [], documentHighlights: []
        )
        var frame = FrameState(cols: 4, rows: 4)
        frame.windowGutters[1] = Wire.WindowGutter(
            windowId: 1, contentRow: 0, contentCol: 0, contentHeight: 4,
            isActive: true, contentWidth: 4, cursorLine: 0,
            lineNumberStyle: .none, lineNumberWidth: 0, signColWidth: 0,
            entries: [.init(bufLine: 0, displayType: .normal, signType: .none)]
        )

        var refuseSubmission = false
        var reports: [NativePresentationFailure] = []
        var presentCalls = 0
        var factories = nativeTestFactories()
        factories.preSubmit = { _ in
            if refuseSubmission { throw InjectedSubmissionFailure.failed }
        }
        factories.observeCompletion = { _, completion in
            completion(true, Int(MTLCommandBufferStatus.completed.rawValue))
        }
        factories.present = { _ in presentCalls += 1 }
        factories.reportFailure = { reports.append($0) }
        guard let renderer = CoreTextMetalRenderer(factories: factories) else { return }
        let fontManager = FontManager(name: "Menlo", size: 13, scale: 1)
        renderer.setupRenderers(fontManager: fontManager)
        let drawable = NativeTestDrawable(texture: texture)

        renderer.render(
            frameState: frame, fontManager: fontManager,
            windowContents: [1: content], drawableProvider: { drawable },
            viewportSize: CGSize(width: 64, height: 64),
            contentScale: 1, presentationInputSeq: 310
        )
        let completed = renderer.activeResourceSnapshot()
        #expect(renderer.lastCompletedPresentationGeneration == 1)
        #expect(completed.allocator?.occupiedCount == 1)
        #expect(presentCalls == 1)

        refuseSubmission = true
        renderer.render(
            frameState: frame, fontManager: fontManager,
            windowContents: [1: content], drawableProvider: { drawable },
            viewportSize: CGSize(width: 64, height: 64),
            contentScale: 1, presentationInputSeq: 311
        )

        #expect(reports.count == 1)
        #expect(reports.first?.phase == .submission)
        #expect(presentCalls == 1)
        #expect(renderer.activeResourceSnapshot() == completed)
        #expect(renderer.lastCompletedPresentationGeneration == 1)
    }

    @Test("late older renderer completion cannot replace newer resources")
    @MainActor func rendererCompletionOrdering() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: 64, height: 64, mipmapped: false
        )
        descriptor.usage = .renderTarget
        guard let texture = device.makeTexture(descriptor: descriptor) else { return }

        typealias Completion = @MainActor @Sendable (Bool, Int) -> Void
        var completions: [Completion] = []
        var presentCalls = 0
        var factories = nativeTestFactories()
        factories.observeCompletion = { _, completion in completions.append(completion) }
        factories.present = { _ in presentCalls += 1 }
        guard let renderer = CoreTextMetalRenderer(factories: factories) else { return }
        let fontManager = FontManager(name: "Menlo", size: 13, scale: 1)
        renderer.setupRenderers(fontManager: fontManager)
        let drawable = NativeTestDrawable(texture: texture)

        renderer.render(
            frameState: FrameState(cols: 4, rows: 4), fontManager: fontManager,
            drawableProvider: { drawable }, viewportSize: CGSize(width: 64, height: 64),
            contentScale: 1, presentationInputSeq: 320
        )
        renderer.render(
            frameState: FrameState(cols: 5, rows: 4), fontManager: fontManager,
            drawableProvider: { drawable }, viewportSize: CGSize(width: 64, height: 64),
            contentScale: 1, presentationInputSeq: 321
        )
        #expect(completions.count == 2)

        completions[1](true, Int(MTLCommandBufferStatus.completed.rawValue))
        #expect(completions.count == 3)
        completions[2](true, Int(MTLCommandBufferStatus.completed.rawValue))
        let newer = renderer.activeResourceSnapshot()
        #expect(renderer.lastCompletedPresentationGeneration == 2)
        #expect(presentCalls == 1)

        completions[0](true, Int(MTLCommandBufferStatus.completed.rawValue))
        #expect(completions.count == 4)
        completions[3](true, Int(MTLCommandBufferStatus.completed.rawValue))
        #expect(renderer.activeResourceSnapshot() == newer)
        #expect(renderer.lastCompletedPresentationGeneration == 2)
        #expect(presentCalls == 1)
    }

    @Test("renderer setup rejects promotion from an older configuration epoch")
    @MainActor func setupInvalidatesInFlightCandidate() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: 64, height: 64, mipmapped: false
        )
        descriptor.usage = .renderTarget
        guard let texture = device.makeTexture(descriptor: descriptor) else { return }

        typealias Completion = @MainActor @Sendable (Bool, Int) -> Void
        var completions: [Completion] = []
        var presentCalls = 0
        var factories = nativeTestFactories()
        factories.observeCompletion = { _, completion in completions.append(completion) }
        factories.present = { _ in presentCalls += 1 }
        guard let renderer = CoreTextMetalRenderer(factories: factories) else { return }
        let oldFontManager = FontManager(name: "Menlo", size: 13, scale: 1)
        renderer.setupRenderers(fontManager: oldFontManager)
        renderer.render(
            frameState: FrameState(cols: 4, rows: 4), fontManager: oldFontManager,
            drawableProvider: { NativeTestDrawable(texture: texture) },
            viewportSize: CGSize(width: 64, height: 64), contentScale: 1,
            presentationInputSeq: 303
        )
        #expect(completions.count == 1)

        let newFontManager = FontManager(name: "Menlo", size: 15, scale: 2)
        renderer.setupRenderers(fontManager: newFontManager)
        let configured = renderer.activeResourceSnapshot()
        completions[0](true, Int(MTLCommandBufferStatus.completed.rawValue))

        #expect(completions.count == 1)
        #expect(presentCalls == 0)
        #expect(renderer.activeResourceSnapshot() == configured)
        #expect(renderer.lastCompletedPresentationGeneration == 0)
    }

    @Test("presentation-copy submission failure leaves drawable and resources untouched")
    @MainActor func presentationCopySubmissionFailureIsAtomic() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: 64, height: 64, mipmapped: false
        )
        descriptor.usage = .renderTarget
        guard let texture = device.makeTexture(descriptor: descriptor) else { return }

        var reports: [NativePresentationFailure] = []
        var presentCalls = 0
        var factories = nativeTestFactories()
        factories.observeCompletion = { _, completion in
            completion(true, Int(MTLCommandBufferStatus.completed.rawValue))
        }
        factories.prePresentationSubmit = { _ in throw InjectedSubmissionFailure.failed }
        factories.present = { _ in presentCalls += 1 }
        factories.reportFailure = { reports.append($0) }
        guard let renderer = CoreTextMetalRenderer(factories: factories) else { return }
        let fontManager = FontManager(name: "Menlo", size: 13, scale: 1)
        renderer.setupRenderers(fontManager: fontManager)
        let before = renderer.activeResourceSnapshot()

        renderer.render(
            frameState: FrameState(cols: 4, rows: 4), fontManager: fontManager,
            drawableProvider: { NativeTestDrawable(texture: texture) },
            viewportSize: CGSize(width: 64, height: 64), contentScale: 1,
            presentationInputSeq: 304
        )

        #expect(reports.count == 1)
        #expect(reports.first?.phase == .submission)
        #expect(reports.first?.dimension == .presentationCopy)
        #expect(presentCalls == 0)
        #expect(renderer.activeResourceSnapshot() == before)
    }

    @Test("oversized viewport fails before integer conversion or allocation")
    @MainActor func oversizedViewportIsTyped() {
        var reports: [NativePresentationFailure] = []
        var factories = nativeTestFactories()
        factories.reportFailure = { reports.append($0) }
        guard let renderer = CoreTextMetalRenderer(factories: factories) else { return }
        let fontManager = FontManager(name: "Menlo", size: 13, scale: 1)
        renderer.setupRenderers(fontManager: fontManager)

        renderer.render(
            frameState: FrameState(cols: 4, rows: 4), fontManager: fontManager,
            drawableProvider: { nil },
            viewportSize: CGSize(width: CGFloat.greatestFiniteMagnitude, height: 64),
            contentScale: 1, presentationInputSeq: 307
        )

        #expect(reports.count == 1)
        #expect(reports.first?.dimension == .textureWidth)
        #expect(reports.first?.reason == .limit)
    }

    @Test("resized late-acquired drawable is rejected before copy or presentation")
    @MainActor func resizedDrawableIsAtomic() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: 65, height: 64, mipmapped: false
        )
        descriptor.usage = .renderTarget
        guard let texture = device.makeTexture(descriptor: descriptor) else { return }

        var reports: [NativePresentationFailure] = []
        var presentCalls = 0
        var factories = nativeTestFactories()
        factories.observeCompletion = { _, completion in
            completion(true, Int(MTLCommandBufferStatus.completed.rawValue))
        }
        factories.present = { _ in presentCalls += 1 }
        factories.reportFailure = { reports.append($0) }
        guard let renderer = CoreTextMetalRenderer(factories: factories) else { return }
        let fontManager = FontManager(name: "Menlo", size: 13, scale: 1)
        renderer.setupRenderers(fontManager: fontManager)
        let before = renderer.activeResourceSnapshot()

        renderer.render(
            frameState: FrameState(cols: 4, rows: 4), fontManager: fontManager,
            drawableProvider: { NativeTestDrawable(texture: texture) },
            viewportSize: CGSize(width: 64, height: 64),
            contentScale: 1, presentationInputSeq: 306
        )

        #expect(reports.count == 1)
        #expect(reports.first?.dimension == .textureWidth)
        #expect(reports.first?.reason == .mismatch)
        #expect(presentCalls == 0)
        #expect(renderer.activeResourceSnapshot() == before)
    }

    @Test("nil late-acquired drawable failure is typed and leaves resources untouched")
    @MainActor func nilDrawableIsAtomic() {
        var reports: [NativePresentationFailure] = []
        var factories = nativeTestFactories()
        factories.observeCompletion = { _, completion in
            completion(true, Int(MTLCommandBufferStatus.completed.rawValue))
        }
        factories.reportFailure = { reports.append($0) }
        guard let renderer = CoreTextMetalRenderer(factories: factories) else { return }
        let fontManager = FontManager(name: "Menlo", size: 13, scale: 1)
        renderer.setupRenderers(fontManager: fontManager)
        let before = renderer.activeResourceSnapshot()

        renderer.render(
            frameState: FrameState(cols: 4, rows: 4), fontManager: fontManager,
            drawableProvider: { nil }, viewportSize: CGSize(width: 64, height: 64),
            contentScale: 1, presentationInputSeq: 305
        )

        #expect(reports.count == 1)
        #expect(reports.first?.phase == .drawable)
        #expect(reports.first?.frameSequence == 305)
        #expect(renderer.activeResourceSnapshot() == before)
    }

    @Test("device dimensions tighten configured policy")
    func deviceLimits() {
        #expect(throws: NativePresentationFailure.self) {
            _ = try NativeRenderDemand.checked(
                textureWidth: 65, slotHeight: 1, atlasSlots: 1,
                lineInstances: 0, lineStride: 32,
                quadInstances: 0, quadStride: 48, quadBufferCount: 3,
                policy: policy, deviceTextureWidth: 64,
                deviceTextureHeight: 128, deviceMaxBufferLength: 8_192
            )
        }
    }
}
