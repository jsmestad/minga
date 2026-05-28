/// Tests for SlotAllocator: pure slot management logic for the line texture atlas.
/// No Metal dependency. Runs on all platforms.

import Testing
import simd

private func testKey(_ raw: UInt16) -> AtlasKey {
    AtlasKey.bufferRow(windowId: 0, rowId: UInt64(raw))
}

@Suite("SlotAllocator — Allocation")
struct SlotAllocatorAllocationTests {

    @Test("New key returns reserved with new-key reason")
    func newKeyReturnsReserved() {
        var alloc = SlotAllocator()
        alloc.ensureCapacity(maxSlots: 10)

        let result = alloc.lookupOrReserve(key: testKey(0), contentHash: 42)

        guard case .reserved(let slot, .newKey) = result else {
            Issue.record("Expected .reserved(.newKey), got \(result)")
            return
        }
        #expect(slot >= 0 && slot < 10)
        #expect(alloc.occupiedCount == 1)
    }

    @Test("Same key and hash returns cache hit")
    func sameKeyAndHashReturnsHit() {
        var alloc = SlotAllocator()
        alloc.ensureCapacity(maxSlots: 10)

        let first = alloc.lookupOrReserve(key: testKey(5), contentHash: 42)
        guard case .reserved(let slot1, .newKey) = first else {
            Issue.record("Expected first .reserved(.newKey)"); return
        }
        alloc.markUploaded(slotIndex: slot1, contentHash: 42, pixelWidth: 100)

        let second = alloc.lookupOrReserve(key: testKey(5), contentHash: 42)
        guard case .hit(let slot2) = second else {
            Issue.record("Expected .hit, got \(second)"); return
        }
        #expect(slot1 == slot2)
    }

    @Test("Same key with different hash returns reserved with hash-changed reason")
    func sameKeyDifferentHashReturnsHashChanged() {
        var alloc = SlotAllocator()
        alloc.ensureCapacity(maxSlots: 10)

        let first = alloc.lookupOrReserve(key: testKey(5), contentHash: 42)
        guard case .reserved(let slot1, .newKey) = first else {
            Issue.record("Expected first .reserved(.newKey)"); return
        }
        alloc.markUploaded(slotIndex: slot1, contentHash: 42, pixelWidth: 100)

        let second = alloc.lookupOrReserve(key: testKey(5), contentHash: 99)
        guard case .reserved(let slot2, .hashChanged) = second else {
            Issue.record("Expected .reserved(.hashChanged), got \(second)"); return
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
            let result = alloc.lookupOrReserve(key: testKey(key), contentHash: Int(key))
            guard case .reserved(let slot, .newKey) = result else {
                Issue.record("Expected .reserved(.newKey) for key \(key)"); return
            }
            slots.insert(slot)
        }
        #expect(slots.count == 5)
        #expect(alloc.occupiedCount == 5)
    }

    @Test("Zero capacity returns .full")
    func zeroCapacityReturnsFull() {
        var alloc = SlotAllocator()
        let result = alloc.lookupOrReserve(key: testKey(0), contentHash: 1)
        #expect(result == .full)
    }
}

@Suite("SlotAllocator — Eviction")
struct SlotAllocatorEvictionTests {

    @Test("Evicts oldest slot when full")
    func evictsOldestWhenFull() {
        var alloc = SlotAllocator()
        alloc.ensureCapacity(maxSlots: 3)

        for key: UInt16 in 0..<3 {
            let r = alloc.lookupOrReserve(key: testKey(key), contentHash: Int(key))
            guard case .reserved(let s, .newKey) = r else { Issue.record("Expected .reserved(.newKey)"); return }
            alloc.markUploaded(slotIndex: s, contentHash: Int(key), pixelWidth: 100)
            alloc.beginFrame()
        }

        _ = alloc.lookupOrReserve(key: testKey(1), contentHash: 1)
        _ = alloc.lookupOrReserve(key: testKey(2), contentHash: 2)
        alloc.beginFrame()

        let result = alloc.lookupOrReserve(key: testKey(3), contentHash: 3)
        guard case .reserved(_, .evicted(let evictedKey)) = result else {
            Issue.record("Expected .reserved(.evicted), got \(result)"); return
        }
        #expect(evictedKey == testKey(0))
    }

    @Test("Evicted slot is reused for new key")
    func evictedSlotIsReused() {
        var alloc = SlotAllocator()
        alloc.ensureCapacity(maxSlots: 2)

        let r0 = alloc.lookupOrReserve(key: testKey(0), contentHash: 0)
        guard case .reserved(let slot0, .newKey) = r0 else { Issue.record("Expected .reserved(.newKey)"); return }
        alloc.markUploaded(slotIndex: slot0, contentHash: 0, pixelWidth: 100)
        alloc.beginFrame()

        let r1 = alloc.lookupOrReserve(key: testKey(1), contentHash: 1)
        guard case .reserved(let slot1, .newKey) = r1 else { Issue.record("Expected .reserved(.newKey)"); return }
        alloc.markUploaded(slotIndex: slot1, contentHash: 1, pixelWidth: 100)
        alloc.beginFrame()

        _ = alloc.lookupOrReserve(key: testKey(1), contentHash: 1)
        alloc.beginFrame()

        let r2 = alloc.lookupOrReserve(key: testKey(2), contentHash: 2)
        guard case .reserved(let evictedSlot, .evicted(_)) = r2 else {
            Issue.record("Expected .reserved(.evicted), got \(r2)"); return
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

        alloc.ensureCapacity(maxSlots: 5)
        #expect(alloc.capacity == 10)

        alloc.ensureCapacity(maxSlots: 20)
        #expect(alloc.capacity == 20)
    }

    @Test("Growing preserves existing slots")
    func growPreservesExisting() {
        var alloc = SlotAllocator()
        alloc.ensureCapacity(maxSlots: 5)

        let r = alloc.lookupOrReserve(key: testKey(0), contentHash: 42)
        guard case .reserved(let slot, .newKey) = r else { Issue.record("Expected .reserved(.newKey)"); return }
        alloc.markUploaded(slotIndex: slot, contentHash: 42, pixelWidth: 100)

        alloc.ensureCapacity(maxSlots: 20)

        let r2 = alloc.lookupOrReserve(key: testKey(0), contentHash: 42)
        #expect(r2 == .hit(slotIndex: slot))
    }

    @Test("invalidateAll clears all slots, preserves capacity")
    func invalidateAll() {
        var alloc = SlotAllocator()
        alloc.ensureCapacity(maxSlots: 5)

        for key: UInt16 in 0..<5 {
            let r = alloc.lookupOrReserve(key: testKey(key), contentHash: Int(key))
            guard case .reserved(let s, .newKey) = r else { Issue.record("Expected .reserved(.newKey)"); return }
            alloc.markUploaded(slotIndex: s, contentHash: Int(key), pixelWidth: 100)
        }
        #expect(alloc.occupiedCount == 5)

        alloc.invalidateAll()
        #expect(alloc.occupiedCount == 0)
        #expect(alloc.capacity == 5)

        let r = alloc.lookupOrReserve(key: testKey(0), contentHash: 0)
        guard case .reserved(_, .newKey) = r else {
            Issue.record("Expected .reserved(.newKey) after invalidate, got \(r)"); return
        }
    }

    @Test("invalidateWindow clears only slots for that window")
    func invalidateWindow() {
        var alloc = SlotAllocator()
        alloc.ensureCapacity(maxSlots: 4)
        let win1 = AtlasKey.bufferRow(windowId: 1, rowId: 0)
        let win2 = AtlasKey.bufferRow(windowId: 2, rowId: 0)

        guard case .reserved(let slot1, .newKey) = alloc.lookupOrReserve(key: win1, contentHash: 11) else { Issue.record("Expected win1 reserve"); return }
        alloc.markUploaded(slotIndex: slot1, contentHash: 11, pixelWidth: 100)
        guard case .reserved(let slot2, .newKey) = alloc.lookupOrReserve(key: win2, contentHash: 22) else { Issue.record("Expected win2 reserve"); return }
        alloc.markUploaded(slotIndex: slot2, contentHash: 22, pixelWidth: 100)

        alloc.invalidateWindow(1)

        #expect(alloc.lookupOrReserve(key: win2, contentHash: 22) == .hit(slotIndex: slot2))
        guard case .reserved(_, .newKey) = alloc.lookupOrReserve(key: win1, contentHash: 11) else {
            Issue.record("Expected win1 to be evicted by window invalidation"); return
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

        let r0 = alloc.lookupOrReserve(key: testKey(0), contentHash: 0)
        guard case .reserved(let s0, .newKey) = r0 else { Issue.record("Expected .reserved(.newKey)"); return }
        alloc.markUploaded(slotIndex: s0, contentHash: 0, pixelWidth: 100)
        alloc.beginFrame()

        let r1 = alloc.lookupOrReserve(key: testKey(1), contentHash: 1)
        guard case .reserved(let s1, .evicted(let evicted)) = r1 else {
            Issue.record("Expected .reserved(.evicted), got \(r1)"); return
        }
        #expect(s1 == 0)
        #expect(evicted == testKey(0))
    }

    @Test("Key 0 and UInt16.max work correctly")
    func boundaryKeys() {
        var alloc = SlotAllocator()
        alloc.ensureCapacity(maxSlots: 10)

        let r0 = alloc.lookupOrReserve(key: testKey(0), contentHash: 1)
        let rMax = alloc.lookupOrReserve(key: testKey(UInt16.max), contentHash: 2)

        guard case .reserved(_, .newKey) = r0, case .reserved(_, .newKey) = rMax else {
            Issue.record("Both should be .reserved(.newKey)"); return
        }
        #expect(alloc.occupiedCount == 2)
    }

    @Test("Same content hash, different keys get separate slots")
    func sameHashDifferentKeys() {
        var alloc = SlotAllocator()
        alloc.ensureCapacity(maxSlots: 10)

        let r0 = alloc.lookupOrReserve(key: testKey(0), contentHash: 42)
        let r1 = alloc.lookupOrReserve(key: testKey(1), contentHash: 42)

        guard case .reserved(let s0, .newKey) = r0, case .reserved(let s1, .newKey) = r1 else {
            Issue.record("Both should be .reserved(.newKey)"); return
        }
        #expect(s0 != s1)
    }
}
