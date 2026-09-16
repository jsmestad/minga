/// Single-texture atlas backed by `SlotAllocator` for slot management.
///
/// Thin Metal wrapper: delegates slot allocation, caching, and UV math
/// to `SlotAllocator` (pure, testable). Owns the `MTLTexture` and
/// handles `texture.replace` for bitmap uploads.

import Metal
import Foundation
import MingaProtocol

/// Result of rendering a line into the atlas.
struct AtlasEntry {
    let slotIndex: Int
    let pixelWidth: Int
    let pixelHeight: Int
}

/// Reserved atlas slot awaiting upload.
struct Reservation {
    let key: AtlasKey
    let slotIndex: Int
    let contentHash: Int
    let reason: MissReason
}

/// Result of looking up or reserving an atlas entry.
enum AtlasLookupResult {
    case hit(AtlasEntry)
    case reserved(Reservation)
}

/// Why the atlas copied an existing texture generation.
enum AtlasTextureCopyKind: String, Sendable, Equatable {
    case growth
    case copyOnWrite = "copy_on_write"
}

/// One reusable physical atlas generation. Its allocator describes the exact
/// pixels stored in `texture`, including candidates that were not published.
private struct AtlasTextureGeneration {
    var texture: MTLTexture?
    var allocator = SlotAllocator()
    var width = 0
    var height = 0
}

/// Bounded physical texture storage shared by every logical atlas candidate.
/// Presentation reservations guarantee that only one candidate writes a slot.
@MainActor
private final class AtlasTexturePool {
    private var generations: [AtlasTextureGeneration]

    init(slotCount: Int) {
        generations = Array(repeating: AtlasTextureGeneration(), count: slotCount)
    }

    func generation(at index: Int) -> AtlasTextureGeneration {
        generations[index]
    }

    func store(_ generation: AtlasTextureGeneration, at index: Int) {
        generations[index] = generation
    }
}

@MainActor
final class LineTextureAtlas {
    static let textureGenerationCount = 3

    /// The atlas texture.
    private(set) var texture: MTLTexture?

    private let device: MTLDevice
    private let policy: FrameResourcePolicy.NativeRendererLimits
    private let makeTexture: (MTLDevice, MTLTextureDescriptor) -> MTLTexture?
    private let allocateStaging: (Int) -> UnsafeMutableRawPointer?
    private let deallocateStaging: (UnsafeMutableRawPointer) -> Void
    private let observeTextureCopy: (AtlasTextureCopyKind, Int) -> Void
    private let texturePool: AtlasTexturePool
    private let texturePoolSlot: Int

    /// Pure slot management (testable without Metal).
    private(set) var allocator = SlotAllocator()

    /// Height of each slot in pixels.
    let slotHeight: Int

    /// Width of the atlas in pixels.
    private(set) var atlasWidth: Int = 0

    /// Total atlas height in pixels.
    private(set) var atlasHeight: Int = 0

    /// Maximum complete slots derived from the exact native byte and dimension ceilings.
    var maxSlotCapacity: Int {
        (try? NativeRenderDemand.maximumAtlasSlots(
            textureWidth: max(atlasWidth, 1), slotHeight: slotHeight,
            policy: policy, deviceTextureHeight: nativeDeviceTextureDimensionLimit(device)
        )) ?? 0
    }

    /// Number of allocated slots.
    var slotCount: Int { allocator.capacity }

    /// Texture uploads performed in the current frame.
    private(set) var frameTextureUploads: Int = 0

    /// Bytes uploaded to the texture atlas in the current frame.
    private(set) var frameTextureUploadBytes: Int = 0

    /// First failure while making a private texture generation.
    private(set) var nativePresentationFailure: NativePresentationFailure?

    convenience init(device: MTLDevice, slotHeight: Int,
                     policy: FrameResourcePolicy.NativeRendererLimits = .default,
                     makeTexture: @escaping (MTLDevice, MTLTextureDescriptor) -> MTLTexture? = {
                         $0.makeTexture(descriptor: $1)
                     },
                     allocateStaging: @escaping (Int) -> UnsafeMutableRawPointer? = { malloc($0) },
                     deallocateStaging: @escaping (UnsafeMutableRawPointer) -> Void = { free($0) },
                     observeTextureCopy: @escaping (AtlasTextureCopyKind, Int) -> Void = { _, _ in }) {
        self.init(
            device: device, slotHeight: slotHeight, policy: policy,
            makeTexture: makeTexture, allocateStaging: allocateStaging,
            deallocateStaging: deallocateStaging, observeTextureCopy: observeTextureCopy,
            texturePool: AtlasTexturePool(slotCount: Self.textureGenerationCount),
            texturePoolSlot: 0
        )
    }

    private init(device: MTLDevice, slotHeight: Int,
                 policy: FrameResourcePolicy.NativeRendererLimits,
                 makeTexture: @escaping (MTLDevice, MTLTextureDescriptor) -> MTLTexture?,
                 allocateStaging: @escaping (Int) -> UnsafeMutableRawPointer?,
                 deallocateStaging: @escaping (UnsafeMutableRawPointer) -> Void,
                 observeTextureCopy: @escaping (AtlasTextureCopyKind, Int) -> Void,
                 texturePool: AtlasTexturePool,
                 texturePoolSlot: Int) {
        self.device = device
        self.slotHeight = slotHeight
        self.policy = policy
        self.makeTexture = makeTexture
        self.allocateStaging = allocateStaging
        self.deallocateStaging = deallocateStaging
        self.observeTextureCopy = observeTextureCopy
        self.texturePool = texturePool
        self.texturePoolSlot = texturePoolSlot
        let generation = self.texturePool.generation(at: texturePoolSlot)
        texture = generation.texture
        allocator = generation.allocator
        atlasWidth = generation.width
        atlasHeight = generation.height
    }

    /// Selects the private physical generation reserved for this native frame.
    /// The candidate starts from the exact allocator state stored with that texture,
    /// so only rows changed since this slot's last use need rasterization.
    func makeCandidate(texturePoolSlot: Int) -> LineTextureAtlas {
        let candidate = LineTextureAtlas(
            device: device, slotHeight: slotHeight, policy: policy,
            makeTexture: makeTexture, allocateStaging: allocateStaging,
            deallocateStaging: deallocateStaging, observeTextureCopy: observeTextureCopy,
            texturePool: texturePool, texturePoolSlot: texturePoolSlot
        )
        return candidate
    }

    /// Grow the atlas if needed. A replacement texture and allocator are built
    /// first; allocation refusal leaves the active texture/cache untouched.
    @discardableResult
    func ensureCapacity(maxSlots: Int, width: Int, frameSequence: UInt32 = 0) -> Result<Void, NativePresentationFailure> {
        guard maxSlots > 0, width > 0 else { return .success(()) }
        let requestedSlots = max(maxSlots, allocator.capacity)
        let requestedWidth = max(width, atlasWidth)
        let needsRealloc = requestedSlots > allocator.capacity || requestedWidth > atlasWidth
        guard needsRealloc else { return .success(()) }
        do {
            _ = try NativeRenderDemand.checked(
                textureWidth: requestedWidth, slotHeight: slotHeight, atlasSlots: requestedSlots,
                lineInstances: 0, lineStride: MemoryLayout<LineGPU>.stride,
                quadInstances: 0, quadStride: MemoryLayout<QuadGPU>.stride, quadBufferCount: 3,
                policy: policy, deviceTextureWidth: nativeDeviceTextureDimensionLimit(device),
                deviceTextureHeight: nativeDeviceTextureDimensionLimit(device),
                deviceMaxBufferLength: device.maxBufferLength, frameSequence: frameSequence
            )
        } catch let failure as NativePresentationFailure { return .failure(failure) }
        catch { return .failure(NativePresentationFailure(phase: .atlas, dimension: .arithmetic,
                                                          frameSequence: frameSequence, reason: .overflow)) }

        let newHeight = requestedSlots * slotHeight

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: requestedWidth,
            height: newHeight,
            mipmapped: false
        )
        desc.usage = MTLTextureUsage.shaderRead
        desc.storageMode = MTLStorageMode.managed

        guard let candidateTexture = makeTexture(device, desc) else {
            let requestedBytes = (try? NativeRenderDemand.checked(
                textureWidth: requestedWidth, slotHeight: slotHeight, atlasSlots: requestedSlots,
                lineInstances: 0, lineStride: 0, quadInstances: 0, quadStride: 0,
                quadBufferCount: 0, policy: policy,
                deviceTextureWidth: nativeDeviceTextureDimensionLimit(device),
                deviceTextureHeight: nativeDeviceTextureDimensionLimit(device),
                deviceMaxBufferLength: device.maxBufferLength,
                frameSequence: frameSequence
            ).atlasBytes)
            return .failure(NativePresentationFailure(
                phase: .atlas, dimension: .texture,
                requested: requestedBytes, limit: policy.atlasBytes,
                frameSequence: frameSequence, reason: .allocation
            ))
        }
        if let source = texture {
            switch copyTexture(
                source, to: candidateTexture,
                width: min(atlasWidth, requestedWidth),
                height: min(atlasHeight, newHeight), kind: .growth,
                frameSequence: frameSequence
            ) {
            case .success: break
            case .failure(let failure): return .failure(failure)
            }
        }
        var candidateAllocator = allocator
        candidateAllocator.ensureCapacity(maxSlots: requestedSlots)
        texture = candidateTexture
        atlasWidth = requestedWidth
        atlasHeight = newHeight
        allocator = candidateAllocator
        persistTextureGeneration()
        return .success(())
    }

    func beginFrame() {
        frameTextureUploads = 0
        frameTextureUploadBytes = 0
        nativePresentationFailure = nil
        allocator.beginFrame()
        persistTextureGeneration()
    }

    /// Look up an atlas entry or reserve one slot that the caller must rasterize and commit.
    func lookupOrReserve(key: AtlasKey, contentHash: Int) -> AtlasLookupResult? {
        switch allocator.lookupOrReserve(key: key, contentHash: contentHash) {
        case .hit(let slotIndex):
            return .hit(
                AtlasEntry(
                    slotIndex: slotIndex,
                    pixelWidth: allocator.pixelWidth(forSlot: slotIndex),
                    pixelHeight: slotHeight
                )
            )
        case .reserved(let slotIndex, let reason):
            return .reserved(Reservation(key: key, slotIndex: slotIndex, contentHash: contentHash, reason: reason))
        case .full:
            nativePresentationFailure = nativePresentationFailure ?? NativePresentationFailure(
                phase: .atlas, dimension: .atlasSlots,
                requested: allocator.capacity == Int.max ? nil : allocator.capacity + 1,
                limit: allocator.capacity, reason: .limit
            )
            return nil
        }
    }

    /// Upload bitmap into a previously reserved atlas slot.
    func commitUpload(reservation: Reservation, pointer: UnsafeRawPointer, pixelWidth: Int, bytesPerRow: Int) -> AtlasEntry? {
        let (minimumRowBytes, rowOverflow) = pixelWidth.multipliedReportingOverflow(by: 4)
        let (uploadBytes, uploadOverflow) = bytesPerRow.multipliedReportingOverflow(by: slotHeight)
        guard pixelWidth > 0, pixelWidth <= atlasWidth else {
            nativePresentationFailure = nativePresentationFailure ?? NativePresentationFailure(
                phase: .atlas, dimension: .textureWidth,
                requested: pixelWidth, limit: atlasWidth, reason: .limit
            )
            return nil
        }
        guard !rowOverflow, !uploadOverflow, bytesPerRow >= minimumRowBytes,
              uploadBytes <= policy.rasterBytes else {
            nativePresentationFailure = nativePresentationFailure ?? NativePresentationFailure(
                phase: .atlas, dimension: rowOverflow || uploadOverflow ? .arithmetic : .rasterBytes,
                requested: uploadOverflow ? nil : uploadBytes,
                limit: policy.rasterBytes,
                reason: rowOverflow || uploadOverflow ? .overflow : .limit
            )
            return nil
        }
        guard let tex = texture else {
            nativePresentationFailure = nativePresentationFailure ?? NativePresentationFailure(
                phase: .atlas, dimension: .texture, reason: .allocation
            )
            return nil
        }

        let yOffset = reservation.slotIndex * slotHeight
        let region = MTLRegion(
            origin: MTLOrigin(x: 0, y: yOffset, z: 0),
            size: MTLSize(width: pixelWidth, height: slotHeight, depth: 1)
        )
        tex.replace(region: region, mipmapLevel: 0, withBytes: pointer, bytesPerRow: bytesPerRow)

        frameTextureUploads += 1
        frameTextureUploadBytes += uploadBytes
        allocator.markUploaded(slotIndex: reservation.slotIndex, contentHash: reservation.contentHash, pixelWidth: pixelWidth)
        persistTextureGeneration()

        return AtlasEntry(slotIndex: reservation.slotIndex, pixelWidth: pixelWidth, pixelHeight: slotHeight)
    }

    private func persistTextureGeneration() {
        texturePool.store(
            AtlasTextureGeneration(
                texture: texture, allocator: allocator,
                width: atlasWidth, height: atlasHeight
            ),
            at: texturePoolSlot
        )
    }

    private func copyTexture(_ source: MTLTexture, to destination: MTLTexture,
                             width: Int, height: Int,
                             kind: AtlasTextureCopyKind,
                             frameSequence: UInt32 = 0) -> Result<Void, NativePresentationFailure> {
        guard width > 0, height > 0 else { return .success(()) }
        let (bytesPerRow, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        let (byteCount, countOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !rowOverflow, !countOverflow else {
            return .failure(NativePresentationFailure(
                phase: .atlas, dimension: .arithmetic,
                frameSequence: frameSequence, reason: .overflow
            ))
        }
        guard byteCount <= policy.atlasBytes else {
            return .failure(NativePresentationFailure(
                phase: .atlas, dimension: .atlasBytes,
                requested: byteCount, limit: policy.atlasBytes,
                frameSequence: frameSequence, reason: .limit
            ))
        }
        guard let storage = allocateStaging(byteCount) else {
            return .failure(NativePresentationFailure(
                phase: .atlas, dimension: .atlasBytes,
                requested: byteCount, limit: policy.atlasBytes,
                frameSequence: frameSequence, reason: .allocation
            ))
        }
        defer { deallocateStaging(storage) }
        let region = MTLRegion(origin: .init(x: 0, y: 0, z: 0),
                               size: .init(width: width, height: height, depth: 1))
        source.getBytes(storage, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
        destination.replace(region: region, mipmapLevel: 0,
                            withBytes: storage, bytesPerRow: bytesPerRow)
        observeTextureCopy(kind, byteCount)
        return .success(())
    }

    /// Compute UV for a slot.
    func uvForSlot(_ slotIndex: Int, pixelWidth: Int) -> (SIMD2<Float>, SIMD2<Float>) {
        SlotAllocator.uvForSlot(slotIndex, pixelWidth: pixelWidth,
                                slotHeight: slotHeight, atlasWidth: atlasWidth,
                                atlasHeight: atlasHeight)
    }

    func invalidateAll() {
        allocator.invalidateAll()
        persistTextureGeneration()
    }

    func invalidateWindow(_ windowId: UInt16) {
        allocator.invalidateWindow(windowId)
        persistTextureGeneration()
    }
}
