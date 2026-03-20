/// Tests for SlotAllocator: pure slot management logic for the line texture atlas.
/// No Metal dependency. Runs on all platforms.

import Testing
import simd

@Suite("SlotAllocator — Allocation")
struct SlotAllocatorAllocationTests {

    @Test("New key returns miss with a valid slot index")
    func newKeyReturnsMiss() {
        var alloc = SlotAllocator()
        alloc.ensureCapacity(maxSlots: 10)

        let result = alloc.allocate(key: 0, contentHash: 42)

        guard case .miss(let slot) = result else {
            Issue.record("Expected .miss, got \(result)")
            return
        }
        #expect(slot >= 0 && slot < 10)
        #expect(alloc.occupiedCount == 1)
    }

    @Test("Same key and hash returns cache hit")
    func sameKeyAndHashReturnsHit() {
        var alloc = SlotAllocator()
        alloc.ensureCapacity(maxSlots: 10)

        let first = alloc.allocate(key: 5, contentHash: 42)
        guard case .miss(let slot1) = first else {
            Issue.record("Expected first .miss"); return
        }
        alloc.markUploaded(slotIndex: slot1, contentHash: 42, pixelWidth: 100)

        let second = alloc.allocate(key: 5, contentHash: 42)
        guard case .hit(let slot2) = second else {
            Issue.record("Expected .hit, got \(second)"); return
        }
        #expect(slot1 == slot2)
    }

    @Test("Same key with different hash returns miss, reuses slot")
    func sameKeyDifferentHashReturnsMiss() {
        var alloc = SlotAllocator()
        alloc.ensureCapacity(maxSlots: 10)

        let first = alloc.allocate(key: 5, contentHash: 42)
        guard case .miss(let slot1) = first else {
            Issue.record("Expected first .miss"); return
        }
        alloc.markUploaded(slotIndex: slot1, contentHash: 42, pixelWidth: 100)

        let second = alloc.allocate(key: 5, contentHash: 99)
        guard case .miss(let slot2) = second else {
            Issue.record("Expected .miss, got \(second)"); return
        }
        #expect(slot1 == slot2)
        #expect(alloc.occupiedCount == 1)
    }

    @Test("Multiple keys get distinct slots")
    func multipleKeysGetDistinctSlots() {
        var alloc = SlotAllocator()
        alloc.ensureCapacity(maxSlots: 10)

        var slots: Set<Int> = []
        for key: UInt16 in 0..<5 {
            let result = alloc.allocate(key: key, contentHash: Int(key))
            guard case .miss(let slot) = result else {
                Issue.record("Expected .miss for key \(key)"); return
            }
            slots.insert(slot)
        }
        #expect(slots.count == 5)
        #expect(alloc.occupiedCount == 5)
    }

    @Test("Zero capacity returns .full")
    func zeroCapacityReturnsFull() {
        var alloc = SlotAllocator()
        // Don't call ensureCapacity
        let result = alloc.allocate(key: 0, contentHash: 1)
        #expect(result == .full)
    }
}

@Suite("SlotAllocator — Eviction")
struct SlotAllocatorEvictionTests {

    @Test("Evicts oldest slot when full")
    func evictsOldestWhenFull() {
        var alloc = SlotAllocator()
        alloc.ensureCapacity(maxSlots: 3)

        // Fill all 3 slots.
        for key: UInt16 in 0..<3 {
            let r = alloc.allocate(key: key, contentHash: Int(key))
            guard case .miss(let s) = r else { Issue.record("Expected .miss"); return }
            alloc.markUploaded(slotIndex: s, contentHash: Int(key), pixelWidth: 100)
            alloc.beginFrame()
        }

        // Touch keys 1 and 2 (not key 0).
        _ = alloc.allocate(key: 1, contentHash: 1)
        _ = alloc.allocate(key: 2, contentHash: 2)
        alloc.beginFrame()

        // Allocate key 3 — should evict key 0.
        let result = alloc.allocate(key: 3, contentHash: 3)
        guard case .evicted(_, let evictedKey) = result else {
            Issue.record("Expected .evicted, got \(result)"); return
        }
        #expect(evictedKey == 0)
    }

    @Test("Evicted slot is reused for new key")
    func evictedSlotIsReused() {
        var alloc = SlotAllocator()
        alloc.ensureCapacity(maxSlots: 2)

        // Fill slots.
        let r0 = alloc.allocate(key: 0, contentHash: 0)
        guard case .miss(let slot0) = r0 else { Issue.record("Expected .miss"); return }
        alloc.markUploaded(slotIndex: slot0, contentHash: 0, pixelWidth: 100)
        alloc.beginFrame()

        let r1 = alloc.allocate(key: 1, contentHash: 1)
        guard case .miss(let slot1) = r1 else { Issue.record("Expected .miss"); return }
        alloc.markUploaded(slotIndex: slot1, contentHash: 1, pixelWidth: 100)
        alloc.beginFrame()

        // Touch key 1 only.
        _ = alloc.allocate(key: 1, contentHash: 1)
        alloc.beginFrame()

        // Evict: should get key 0's slot.
        let r2 = alloc.allocate(key: 2, contentHash: 2)
        guard case .evicted(let evictedSlot, _) = r2 else {
            Issue.record("Expected .evicted, got \(r2)"); return
        }
        #expect(evictedSlot == slot0)
    }
}

@Suite("SlotAllocator — Capacity")
struct SlotAllocatorCapacityTests {

    @Test("ensureCapacity grows but never shrinks")
    func growNeverShrink() {
        var alloc = SlotAllocator()
        alloc.ensureCapacity(maxSlots: 10)
        #expect(alloc.capacity == 10)

        alloc.ensureCapacity(maxSlots: 5) // should not shrink
        #expect(alloc.capacity == 10)

        alloc.ensureCapacity(maxSlots: 20) // should grow
        #expect(alloc.capacity == 20)
    }

    @Test("Growing preserves existing slots")
    func growPreservesExisting() {
        var alloc = SlotAllocator()
        alloc.ensureCapacity(maxSlots: 5)

        let r = alloc.allocate(key: 0, contentHash: 42)
        guard case .miss(let slot) = r else { Issue.record("Expected .miss"); return }
        alloc.markUploaded(slotIndex: slot, contentHash: 42, pixelWidth: 100)

        alloc.ensureCapacity(maxSlots: 20)

        // Original key should still be cached.
        let r2 = alloc.allocate(key: 0, contentHash: 42)
        #expect(r2 == .hit(slotIndex: slot))
    }

    @Test("invalidateAll clears all slots, preserves capacity")
    func invalidateAll() {
        var alloc = SlotAllocator()
        alloc.ensureCapacity(maxSlots: 5)

        for key: UInt16 in 0..<5 {
            let r = alloc.allocate(key: key, contentHash: Int(key))
            guard case .miss(let s) = r else { Issue.record("Expected .miss"); return }
            alloc.markUploaded(slotIndex: s, contentHash: Int(key), pixelWidth: 100)
        }
        #expect(alloc.occupiedCount == 5)

        alloc.invalidateAll()
        #expect(alloc.occupiedCount == 0)
        #expect(alloc.capacity == 5)

        // Allocating the same key should be a miss (not stale hit).
        let r = alloc.allocate(key: 0, contentHash: 0)
        guard case .miss = r else {
            Issue.record("Expected .miss after invalidate, got \(r)"); return
        }
    }
}

@Suite("SlotAllocator — UV Computation")
struct SlotAllocatorUVTests {

    @Test("First slot has UV origin at (0, 0)")
    func firstSlotOrigin() {
        let (origin, size) = SlotAllocator.uvForSlot(0, pixelWidth: 500,
                                                      slotHeight: 40, atlasWidth: 1024, atlasHeight: 400)
        #expect(origin.x == 0.0)
        #expect(origin.y == 0.0)
        #expect(abs(size.x - 500.0 / 1024.0) < 0.001)
        #expect(abs(size.y - 40.0 / 400.0) < 0.001)
    }

    @Test("Nth slot has correct vertical offset")
    func nthSlotOffset() {
        let (origin, _) = SlotAllocator.uvForSlot(3, pixelWidth: 200,
                                                    slotHeight: 40, atlasWidth: 1024, atlasHeight: 400)
        #expect(abs(origin.y - (3.0 * 40.0 / 400.0)) < 0.001)
    }

    @Test("Width fraction matches pixel width ratio")
    func widthFraction() {
        let (_, size) = SlotAllocator.uvForSlot(0, pixelWidth: 200,
                                                  slotHeight: 40, atlasWidth: 1024, atlasHeight: 400)
        #expect(abs(size.x - 200.0 / 1024.0) < 0.001)
    }

    @Test("Zero pixel width returns zero UV width")
    func zeroPixelWidth() {
        let (_, size) = SlotAllocator.uvForSlot(0, pixelWidth: 0,
                                                  slotHeight: 40, atlasWidth: 1024, atlasHeight: 400)
        #expect(size.x == 0.0)
    }

    @Test("Zero atlas dimensions return default UV")
    func zeroAtlasDimensions() {
        let (origin, size) = SlotAllocator.uvForSlot(0, pixelWidth: 100,
                                                      slotHeight: 40, atlasWidth: 0, atlasHeight: 0)
        #expect(origin == .zero)
        #expect(size == SIMD2<Float>(1, 1))
    }
}

@Suite("SlotAllocator — Edge Cases")
struct SlotAllocatorEdgeCaseTests {

    @Test("Single slot capacity: every new key evicts the previous")
    func singleSlotCapacity() {
        var alloc = SlotAllocator()
        alloc.ensureCapacity(maxSlots: 1)

        let r0 = alloc.allocate(key: 0, contentHash: 0)
        guard case .miss(let s0) = r0 else { Issue.record("Expected .miss"); return }
        alloc.markUploaded(slotIndex: s0, contentHash: 0, pixelWidth: 100)
        alloc.beginFrame()

        let r1 = alloc.allocate(key: 1, contentHash: 1)
        guard case .evicted(let s1, let evicted) = r1 else {
            Issue.record("Expected .evicted, got \(r1)"); return
        }
        #expect(s1 == 0) // only slot available
        #expect(evicted == 0) // key 0 was evicted
    }

    @Test("Key 0 and UInt16.max work correctly")
    func boundaryKeys() {
        var alloc = SlotAllocator()
        alloc.ensureCapacity(maxSlots: 10)

        let r0 = alloc.allocate(key: 0, contentHash: 1)
        let rMax = alloc.allocate(key: UInt16.max, contentHash: 2)

        guard case .miss = r0, case .miss = rMax else {
            Issue.record("Both should be .miss"); return
        }
        #expect(alloc.occupiedCount == 2)
    }

    @Test("Same content hash, different keys get separate slots")
    func sameHashDifferentKeys() {
        var alloc = SlotAllocator()
        alloc.ensureCapacity(maxSlots: 10)

        let r0 = alloc.allocate(key: 0, contentHash: 42)
        let r1 = alloc.allocate(key: 1, contentHash: 42) // same hash!

        guard case .miss(let s0) = r0, case .miss(let s1) = r1 else {
            Issue.record("Both should be .miss"); return
        }
        #expect(s0 != s1) // different slots despite same hash
    }
}
