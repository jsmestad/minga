/// Pure slot allocation and cache management for the line texture atlas.
///
/// Manages key-to-slot mapping, content hash caching, LRU eviction, and
/// UV coordinate computation. No Metal dependency; fully unit-testable.
///
/// `LineTextureAtlas` wraps this with an `MTLTexture` for actual GPU uploads.

import simd

/// Collision-free cache key for atlas entries.
struct AtlasKey: Hashable, CustomStringConvertible {
    enum Namespace: String, Hashable {
        case bufferRow
        case gutterLineNumber
        case diagnosticSign
        case annotationIcon
        case lineAnnotation
        case splitLabel
    }

    let namespace: Namespace
    let windowId: UInt16
    let row: UInt16
    let subIndex: UInt16

    var description: String {
        "\(namespace.rawValue)(window: \(windowId), row: \(row), sub: \(subIndex))"
    }

    static func bufferRow(windowId: UInt16, row: UInt16) -> AtlasKey {
        AtlasKey(namespace: .bufferRow, windowId: windowId, row: row, subIndex: 0)
    }

    static func gutterLineNumber(windowId: UInt16, row: UInt16) -> AtlasKey {
        AtlasKey(namespace: .gutterLineNumber, windowId: windowId, row: row, subIndex: 0)
    }

    static func diagnosticSign(windowId: UInt16, row: UInt16) -> AtlasKey {
        AtlasKey(namespace: .diagnosticSign, windowId: windowId, row: row, subIndex: 0)
    }

    static func annotationIcon(windowId: UInt16, row: UInt16) -> AtlasKey {
        AtlasKey(namespace: .annotationIcon, windowId: windowId, row: row, subIndex: 0)
    }

    static func lineAnnotation(windowId: UInt16, row: UInt16, subIndex: UInt16) -> AtlasKey {
        AtlasKey(namespace: .lineAnnotation, windowId: windowId, row: row, subIndex: subIndex)
    }

    static func splitLabel(row: UInt16, subIndex: UInt16) -> AtlasKey {
        AtlasKey(namespace: .splitLabel, windowId: 0, row: row, subIndex: subIndex)
    }
}

/// Metadata for one slot in the atlas.
struct AtlasSlot {
    var contentHash: Int = 0
    var pixelWidth: Int = 0
    var lastWrittenFrame: UInt64 = 0
}

/// Reason an atlas key needs rasterization and upload.
enum MissReason: Equatable {
    /// The key was not present in the atlas.
    case newKey
    /// The key was present, but its content hash changed.
    case hashChanged
    /// The atlas was full and the least-recently-used key was evicted.
    case evicted(oldKey: AtlasKey)
}

/// Result of a slot lookup or reservation request.
enum LookupResult: Equatable {
    /// Cache hit: the slot already contains the right content.
    case hit(slotIndex: Int)
    /// Cache miss: the slot is reserved and needs new content uploaded.
    case reserved(slotIndex: Int, reason: MissReason)
    /// No slots available (capacity 0).
    case full
}

struct SlotAllocator {
    /// Per-slot metadata.
    private var slots: [AtlasSlot] = []

    /// Maps cache keys to slot indices.
    private var keyToSlot: [AtlasKey: Int] = [:]

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

    /// Look up an existing slot or reserve one upload slot for the given key and content hash.
    ///
    /// - `.hit`: slot is cached with matching hash. No upload needed.
    /// - `.reserved(.hashChanged)`: existing key reused its slot with new content. Upload needed.
    /// - `.reserved(.newKey)`: new key took a free slot. Upload needed.
    /// - `.reserved(.evicted)`: an old key was evicted to make room. Upload needed.
    /// - `.full`: no capacity.
    mutating func lookupOrReserve(key: AtlasKey, contentHash: Int) -> LookupResult {
        if let slotIndex = keyToSlot[key] {
            slots[slotIndex].lastWrittenFrame = frameCounter
            if slots[slotIndex].contentHash == contentHash {
                return .hit(slotIndex: slotIndex)
            }
            return .reserved(slotIndex: slotIndex, reason: .hashChanged)
        }

        if let free = freeSlots.popLast() {
            keyToSlot[key] = free
            slots[free].lastWrittenFrame = frameCounter
            return .reserved(slotIndex: free, reason: .newKey)
        }

        guard let (evictIndex, evictedKey) = evictOldest() else {
            return .full
        }
        keyToSlot[key] = evictIndex
        slots[evictIndex].lastWrittenFrame = frameCounter
        return .reserved(slotIndex: evictIndex, reason: .evicted(oldKey: evictedKey))
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

    private mutating func evictOldest() -> (index: Int, key: AtlasKey)? {
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
