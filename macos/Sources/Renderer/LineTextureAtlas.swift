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
        allocator.beginFrame()
    }

    /// Check atlas cache. Returns entry if hit, nil if miss.
    func cachedEntry(forKey key: UInt16, contentHash: Int) -> AtlasEntry? {
        let result = allocator.allocate(key: key, contentHash: contentHash)
        switch result {
        case .hit(let slotIndex):
            return AtlasEntry(
                slotIndex: slotIndex,
                pixelWidth: allocator.pixelWidth(forSlot: slotIndex),
                pixelHeight: slotHeight
            )
        default:
            return nil
        }
    }

    /// Upload bitmap into the atlas. Allocates a slot if needed.
    func upload(key: UInt16, contentHash: Int,
                pointer: UnsafeRawPointer, pixelWidth: Int,
                bytesPerRow: Int) -> AtlasEntry? {
        guard let tex = texture else { return nil }

        let result = allocator.allocate(key: key, contentHash: contentHash)
        let slotIndex: Int

        switch result {
        case .hit(let idx):
            // Already cached and uploaded.
            return AtlasEntry(slotIndex: idx, pixelWidth: allocator.pixelWidth(forSlot: idx), pixelHeight: slotHeight)
        case .miss(let idx):
            slotIndex = idx
        case .evicted(let idx, _):
            slotIndex = idx
        case .full:
            return nil
        }

        // Upload bitmap into the slot region.
        let yOffset = slotIndex * slotHeight
        let uploadWidth = min(pixelWidth, atlasWidth)
        let region = MTLRegion(
            origin: MTLOrigin(x: 0, y: yOffset, z: 0),
            size: MTLSize(width: uploadWidth, height: slotHeight, depth: 1)
        )
        tex.replace(region: region, mipmapLevel: 0,
                    withBytes: pointer, bytesPerRow: bytesPerRow)

        allocator.markUploaded(slotIndex: slotIndex, contentHash: contentHash, pixelWidth: pixelWidth)

        return AtlasEntry(slotIndex: slotIndex, pixelWidth: pixelWidth, pixelHeight: slotHeight)
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
