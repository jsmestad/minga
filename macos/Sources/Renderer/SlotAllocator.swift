/// Pure slot allocation and cache management for the line texture atlas.
///
/// Manages key-to-slot mapping, content hash caching, LRU eviction, and
/// UV coordinate computation. No Metal dependency; fully unit-testable.
///
/// `LineTextureAtlas` wraps this with an `MTLTexture` for actual GPU uploads.

import simd

/// Metadata for one slot in the atlas.
struct AtlasSlot {
    var contentHash: Int = 0
    var pixelWidth: Int = 0
    var lastWrittenFrame: UInt64 = 0
}

/// Result of a slot allocation request.
enum SlotResult: Equatable {
    /// Cache hit: the slot already contains the right content.
    case hit(slotIndex: Int)
    /// Cache miss: the slot needs new content uploaded.
    /// For a reused key with changed hash, the slot index is the same.
    case miss(slotIndex: Int)
    /// All slots were full. An old slot was evicted to make room.
    case evicted(slotIndex: Int, evictedKey: UInt16)
    /// No slots available (capacity 0).
    case full
}

struct SlotAllocator {
    /// Per-slot metadata.
    private var slots: [AtlasSlot] = []

    /// Maps cache keys to slot indices.
    private var keyToSlot: [UInt16: Int] = [:]

    /// Free slot indices.
    private var freeSlots: [Int] = []

    /// Current frame counter for LRU tracking.
    private var frameCounter: UInt64 = 0

    /// Current capacity.
    private(set) var capacity: Int = 0

    /// Number of occupied slots.
    var occupiedCount: Int { capacity - freeSlots.count }

    /// Initialize with zero capacity. Call `ensureCapacity` before use.
    init() {}

    /// Grow capacity if needed. Never shrinks. Preserves existing slots.
    mutating func ensureCapacity(maxSlots: Int) {
        guard maxSlots > capacity else { return }

        let oldCount = capacity
        capacity = maxSlots
        slots.append(contentsOf: Array(repeating: AtlasSlot(), count: maxSlots - oldCount))
        // New slots are free, added in reverse order for LIFO allocation.
        freeSlots.append(contentsOf: ((oldCount)..<maxSlots).reversed())
    }

    /// Advance frame counter.
    mutating func beginFrame() {
        frameCounter += 1
    }

    /// Request a slot for the given key and content hash.
    ///
    /// - `.hit`: slot is cached with matching hash. No upload needed.
    /// - `.miss`: slot is assigned but content changed. Upload needed.
    /// - `.evicted`: an old slot was freed to make room. Upload needed.
    /// - `.full`: no capacity.
    mutating func allocate(key: UInt16, contentHash: Int) -> SlotResult {
        // Existing key: check if hash matches.
        if let slotIndex = keyToSlot[key] {
            slots[slotIndex].lastWrittenFrame = frameCounter
            if slots[slotIndex].contentHash == contentHash {
                return .hit(slotIndex: slotIndex)
            }
            // Same key, different hash: reuse slot, caller re-uploads.
            return .miss(slotIndex: slotIndex)
        }

        // New key: allocate a free slot.
        if let free = freeSlots.popLast() {
            keyToSlot[key] = free
            slots[free].lastWrittenFrame = frameCounter
            return .miss(slotIndex: free)
        }

        // No free slots: evict LRU.
        guard let (evictIndex, evictedKey) = evictOldest() else {
            return .full
        }
        keyToSlot[key] = evictIndex
        slots[evictIndex].lastWrittenFrame = frameCounter
        return .evicted(slotIndex: evictIndex, evictedKey: evictedKey)
    }

    /// Mark a slot as successfully uploaded with the given hash and width.
    mutating func markUploaded(slotIndex: Int, contentHash: Int, pixelWidth: Int) {
        guard slotIndex < slots.count else { return }
        slots[slotIndex].contentHash = contentHash
        slots[slotIndex].pixelWidth = pixelWidth
        slots[slotIndex].lastWrittenFrame = frameCounter
    }

    /// Get the pixel width of a cached slot (for UV computation).
    func pixelWidth(forSlot slotIndex: Int) -> Int {
        guard slotIndex < slots.count else { return 0 }
        return slots[slotIndex].pixelWidth
    }

    /// Compute UV origin and size for a slot.
    ///
    /// - Parameters:
    ///   - slotIndex: Slot index in the atlas.
    ///   - pixelWidth: Actual content width.
    ///   - slotHeight: Height of each slot in pixels.
    ///   - atlasWidth: Total atlas width in pixels.
    ///   - atlasHeight: Total atlas height in pixels.
    static func uvForSlot(_ slotIndex: Int, pixelWidth: Int,
                          slotHeight: Int, atlasWidth: Int,
                          atlasHeight: Int) -> (SIMD2<Float>, SIMD2<Float>) {
        let aw = Float(atlasWidth)
        let ah = Float(atlasHeight)
        guard aw > 0, ah > 0 else { return (.zero, SIMD2<Float>(1, 1)) }

        let origin = SIMD2<Float>(0, Float(slotIndex * slotHeight) / ah)
        let size = SIMD2<Float>(
            pixelWidth > 0 ? Float(pixelWidth) / aw : 0,
            Float(slotHeight) / ah
        )
        return (origin, size)
    }

    /// Clear all slots. Capacity is preserved.
    mutating func invalidateAll() {
        for i in 0..<slots.count {
            slots[i].contentHash = 0
            slots[i].pixelWidth = 0
        }
        keyToSlot.removeAll(keepingCapacity: true)
        freeSlots = Array((0..<capacity).reversed())
    }

    // MARK: - Private

    private mutating func evictOldest() -> (index: Int, key: UInt16)? {
        guard !slots.isEmpty else { return nil }

        var oldestFrame: UInt64 = .max
        var oldestIndex = 0

        for (i, slot) in slots.enumerated() {
            if keyToSlot.values.contains(i), slot.lastWrittenFrame < oldestFrame {
                oldestFrame = slot.lastWrittenFrame
                oldestIndex = i
            }
        }

        guard let oldKey = keyToSlot.first(where: { $0.value == oldestIndex })?.key else {
            return nil
        }
        keyToSlot.removeValue(forKey: oldKey)
        return (oldestIndex, oldKey)
    }
}
