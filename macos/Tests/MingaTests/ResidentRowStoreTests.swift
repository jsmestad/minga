import MingaProtocol
import Testing

@Suite("Resident row store")
struct ResidentRowStoreTests {
    @Test("empty, one row, and exact chunk capacity")
    func basicBoundaries() throws {
        var empty = ResidentRowStore()
        #expect(empty.isEmpty)
        #expect(empty.row(at: 0) == nil)
        #expect(empty.lowerBound(bufferLine: 0) == 0)
        #expect(empty.validateInvariants())

        try empty.replaceAll(with: [row(1)])
        #expect(empty.count == 1)
        #expect(empty.chunkOccupancies == [1])
        #expect(empty.row(at: 0)?.rowId == 1)

        let exact = try ResidentRowStore(rows: rows(0..<ResidentRowStore.chunkCapacity))
        #expect(exact.chunkOccupancies == [ResidentRowStore.chunkCapacity])
        #expect(exact.validateInvariants())
    }

    @Test("split and merge keep bounded occupancy")
    func splitAndMerge() throws {
        var store = try ResidentRowStore(rows: rows(0..<ResidentRowStore.chunkCapacity))
        try store.splice(at: 64, removeCount: 0, inserting: rows(1_000..<1_080, bufferLine: 64))
        #expect(store.chunkCount == 2)
        #expect(store.chunkOccupancies.allSatisfy { $0 <= ResidentRowStore.chunkCapacity })
        #expect(store.validateInvariants())

        try store.splice(at: 40, removeCount: 150, inserting: [])
        #expect(store.count == 58)
        #expect(store.chunkOccupancies == [58])
        #expect(store.validateInvariants())
    }

    @Test("front, middle, and end splices match an array oracle")
    func splicePositions() throws {
        var oracle = rows(0..<300)
        var store = try ResidentRowStore(rows: oracle)

        for operation in [
            (index: 0, remove: 2, insert: rows(1_000..<1_003, bufferLine: 1)),
            (index: 151, remove: 5, insert: rows(2_000..<2_002, bufferLine: 150)),
            (index: 298, remove: 0, insert: rows(3_000..<3_004, bufferLine: 299))
        ] {
            oracle.replaceSubrange(
                operation.index..<(operation.index + operation.remove),
                with: operation.insert
            )
            try store.splice(
                at: operation.index,
                removeCount: operation.remove,
                inserting: operation.insert
            )
            #expect(store.rows(in: 0..<store.count).rows == oracle)
            #expect(store.validateInvariants())
        }
    }

    @Test("identity, not duplicate text, resolves retained rows")
    func duplicateTextIdentity() throws {
        let first = row(1, bufferLine: 4, text: "same", hash: 10)
        let second = row(2, bufferLine: 4, text: "same", hash: 20, type: .wrapContinuation)
        var store = try ResidentRowStore(rows: [first, second])

        #expect(try store.resolve(rowID: 2, contentHash: 20) == second)
        #expect(throws: ResidentRowStoreError.contentHashMismatch(rowID: 2, expected: 20, actual: 10)) {
            try store.resolve(rowID: 2, contentHash: 10)
        }
        #expect(store.counters.idsResolved == 2)
    }

    @Test("buffer-line lower bound returns first wrap or decoration")
    func bufferLineLowerBound() throws {
        let fixture = [
            row(1, bufferLine: 3),
            row(2, bufferLine: 5),
            row(3, bufferLine: 5, type: .wrapContinuation),
            row(4, bufferLine: 5, type: .virtualLine),
            row(5, bufferLine: 8)
        ]
        let store = try ResidentRowStore(rows: fixture)

        #expect(store.lowerBound(bufferLine: 0) == 0)
        #expect(store.lowerBound(bufferLine: 5) == 1)
        #expect(store.lowerBound(bufferLine: 6) == 4)
        #expect(store.lowerBound(bufferLine: 9) == fixture.count)
    }

    @Test("copy-on-write mutation leaves the committed value unchanged")
    func copyOnWrite() throws {
        let committed = try ResidentRowStore(rows: rows(0..<260))
        var staged = committed
        try staged.splice(at: 120, removeCount: 4, inserting: rows(2_000..<2_002, bufferLine: 120))

        #expect(committed.count == 260)
        #expect(committed.row(at: 120)?.rowId == 121)
        #expect(staged.count == 258)
        #expect(staged.row(at: 120)?.rowId == 2_001)
        #expect(committed.validateInvariants())
        #expect(staged.validateInvariants())
    }

    @Test("invalid splice leaves the committed COW value unchanged")
    func invalidSpliceRollback() throws {
        let committed = try ResidentRowStore(rows: rows(0..<200))
        var staged = committed

        #expect(throws: ResidentRowStoreError.invalidRange(index: 199, removeCount: 2, rowCount: 200)) {
            try staged.splice(at: 199, removeCount: 2, inserting: [])
        }
        #expect(staged.rows(in: 0..<staged.count).rows == committed.rows(in: 0..<committed.count).rows)
        #expect(staged.counters == committed.counters)
    }

    @Test("structural updates do not touch chunks after the splice")
    func boundedChunkUpdates() throws {
        var store = try ResidentRowStore(rows: rows(0..<65_536))
        let before = store.counters
        try store.splice(at: 100, removeCount: 2, inserting: rows(70_000..<70_003, bufferLine: 100))
        let touched = store.counters.chunksTouched - before.chunksTouched

        #expect(touched <= 4)
        #expect(store.count == 65_537)
        #expect(store.validateInvariants())
    }

    @Test("randomized operations match an array oracle and preserve indexes")
    func randomizedOracle() throws {
        var generator = Generator(state: 0x2741)
        var nextID: UInt64 = 1
        var oracle: [GUIVisualRow] = []
        var store = ResidentRowStore()

        for _ in 0..<1_000 {
            let index = oracle.isEmpty ? 0 : generator.int(oracle.count + 1)
            let removable = oracle.count - index
            let removeCount = removable == 0 ? 0 : generator.int(min(removable, 12) + 1)
            let insertCount = generator.int(10)
            var inserted: [GUIVisualRow] = []
            let orderedLine: UInt32
            if index > 0 {
                orderedLine = oracle[index - 1].bufLine
            } else if index + removeCount < oracle.count {
                orderedLine = oracle[index + removeCount].bufLine
            } else {
                orderedLine = 0
            }
            for _ in 0..<insertCount {
                inserted.append(row(nextID, bufferLine: orderedLine, text: "v\(nextID % 7)"))
                nextID += 1
            }

            oracle.replaceSubrange(index..<(index + removeCount), with: inserted)
            try store.splice(at: index, removeCount: removeCount, inserting: inserted)

            #expect(store.count == oracle.count)
            #expect(store.rows(in: 0..<store.count).rows == oracle)
            #expect(store.validateInvariants())
            #expect(store.chunkOccupancies.allSatisfy { $0 <= ResidentRowStore.chunkCapacity })
            if !oracle.isEmpty {
                let probe = generator.int(oracle.count)
                #expect(store.row(at: probe) == oracle[probe])
                #expect(try store.resolve(
                    rowID: oracle[probe].rowId,
                    contentHash: oracle[probe].contentHash
                ) == oracle[probe])
                let targetLine = UInt32(generator.int(Int(oracle.last!.bufLine) + 2))
                let oracleBound = oracle.firstIndex { $0.bufLine >= targetLine } ?? oracle.count
                #expect(store.lowerBound(bufferLine: targetLine) == oracleBound)
            }
        }
    }

    @Test("unsorted replacements and splices roll back atomically")
    func unsortedMutationRollback() throws {
        let committed = try ResidentRowStore(rows: [row(1, bufferLine: 1), row(2, bufferLine: 2)])
        var replacement = committed
        #expect(throws: ResidentRowStoreError.unsortedBufferLine(previous: 2, next: 1)) {
            try replacement.replaceAll(with: [row(2, bufferLine: 2), row(1, bufferLine: 1)])
        }
        #expect(replacement.rows(in: 0..<replacement.count).rows == committed.rows(in: 0..<committed.count).rows)
        #expect(replacement.counters == committed.counters)

        var splice = committed
        #expect(throws: ResidentRowStoreError.unsortedBufferLine(previous: 3, next: 2)) {
            try splice.splice(at: 1, removeCount: 0, inserting: [row(3, bufferLine: 3)])
        }
        #expect(splice.rows(in: 0..<splice.count).rows == committed.rows(in: 0..<committed.count).rows)
        #expect(splice.counters == committed.counters)
    }

    private func rows(_ range: Range<Int>, bufferLine: UInt32? = nil) -> [GUIVisualRow] {
        range.map { row(UInt64($0 + 1), bufferLine: bufferLine ?? UInt32($0)) }
    }

    private func row(_ id: UInt64, bufferLine: UInt32? = nil, text: String? = nil,
                     hash: UInt32? = nil, type: GUIVisualRowType = .normal) -> GUIVisualRow {
        GUIVisualRow(
            rowType: type,
            rowId: id,
            bufLine: bufferLine ?? UInt32(clamping: id),
            contentHash: hash ?? UInt32(truncatingIfNeeded: id &* 31),
            text: text ?? "row \(id)",
            spans: []
        )
    }

    private struct Generator {
        var state: UInt64

        mutating func int(_ upperBound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Int(state % UInt64(upperBound))
        }
    }
}
