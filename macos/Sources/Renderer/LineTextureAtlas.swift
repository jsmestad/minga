/// Single-texture atlas backed by `SlotAllocator` for slot management.
///
/// Thin Metal wrapper: delegates slot allocation, caching, and UV math
/// to `SlotAllocator` (pure, testable). Owns the `MTLTexture` and
/// handles `texture.replace` for bitmap uploads.

import Metal
import Foundation

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

@MainActor
final class LineTextureAtlas {
    /// The atlas texture.
    private(set) var texture: MTLTexture?

    private let device: MTLDevice

    /// Pure slot management (testable without Metal).
    private(set) var allocator = SlotAllocator()

    /// Height of each slot in pixels.
    let slotHeight: Int

    /// Width of the atlas in pixels.
    private(set) var atlasWidth: Int = 0

    /// Total atlas height in pixels.
    private(set) var atlasHeight: Int = 0

    /// Number of allocated slots.
    var slotCount: Int { allocator.capacity }

    /// Texture uploads performed in the current frame.
    private(set) var frameTextureUploads: Int = 0

    /// Bytes uploaded to the texture atlas in the current frame.
    private(set) var frameTextureUploadBytes: Int = 0

    init(device: MTLDevice, slotHeight: Int) {
        self.device = device
        self.slotHeight = slotHeight
    }

    /// Grow the atlas if needed. Reallocates the texture on size change.
    func ensureCapacity(maxSlots: Int, width: Int) {
        guard maxSlots > 0, width > 0 else { return }

        let needsRealloc = maxSlots > allocator.capacity || width > atlasWidth
        guard needsRealloc else { return }

        let newSlotCount = max(maxSlots, allocator.capacity)
        let newWidth = max(width, atlasWidth)
        let newHeight = newSlotCount * slotHeight

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: newWidth,
            height: newHeight,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .managed

        texture = device.makeTexture(descriptor: desc)
        atlasWidth = newWidth
        atlasHeight = newHeight

        // Reset allocator on reallocation (texture contents are gone).
        allocator = SlotAllocator()
        allocator.ensureCapacity(maxSlots: newSlotCount)
    }

    func beginFrame() {
        frameTextureUploads = 0
        frameTextureUploadBytes = 0
        allocator.beginFrame()
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
            return nil
        }
    }

    /// Upload bitmap into a previously reserved atlas slot.
    func commitUpload(reservation: Reservation, pointer: UnsafeRawPointer, pixelWidth: Int, bytesPerRow: Int) -> AtlasEntry? {
        guard let tex = texture else { return nil }

        let yOffset = reservation.slotIndex * slotHeight
        let uploadWidth = min(pixelWidth, atlasWidth)
        let region = MTLRegion(
            origin: MTLOrigin(x: 0, y: yOffset, z: 0),
            size: MTLSize(width: uploadWidth, height: slotHeight, depth: 1)
        )
        tex.replace(region: region, mipmapLevel: 0, withBytes: pointer, bytesPerRow: bytesPerRow)

        frameTextureUploads += 1
        frameTextureUploadBytes += bytesPerRow * slotHeight
        allocator.markUploaded(slotIndex: reservation.slotIndex, contentHash: reservation.contentHash, pixelWidth: uploadWidth)

        return AtlasEntry(slotIndex: reservation.slotIndex, pixelWidth: uploadWidth, pixelHeight: slotHeight)
    }

    /// Compute UV for a slot.
    func uvForSlot(_ slotIndex: Int, pixelWidth: Int) -> (SIMD2<Float>, SIMD2<Float>) {
        SlotAllocator.uvForSlot(slotIndex, pixelWidth: pixelWidth,
                                slotHeight: slotHeight, atlasWidth: atlasWidth,
                                atlasHeight: atlasHeight)
    }

    func invalidateAll() {
        allocator.invalidateAll()
    }
}
