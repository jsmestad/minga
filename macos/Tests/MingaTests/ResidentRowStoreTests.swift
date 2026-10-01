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

    @Test("cached resident weight exactly owns UTF-8, spans, rows, and locators")
    func exactResidentWeight() throws {
        let styled = GUIVisualRow(
            rowType: .normal, rowId: 1, bufLine: 0, contentHash: 1,
            text: "a😀", spans: [
                GUIHighlightSpan(
                    startCol: 0, endCol: 1, fg: 1, bg: 0,
                    attrs: 0, fontWeight: 0, fontId: 0
                )
            ]
        )
        var store = try ResidentRowStore(rows: [styled, row(2, text: "xy")])

        #expect(store.resourceWeight == FrameResourceWeight(
            ownedUTF8Bytes: 7, arrayEntries: 1, rows: 2, spans: 1,
            locatorEntries: 2
        ))

        let replacement = row(2, bufferLine: 1, text: "four", hash: 9)
        try store.replace(at: 1, with: replacement)
        #expect(store.resourceWeight.ownedUTF8Bytes == 9)
        #expect(store.resourceWeight.rows == 2)
        #expect(store.resourceWeight.locatorEntries == 2)
    }

    @Test("decoded construction rejects checked weight and identities before indexing")
    func decodedConstructionRejectsBeforeIndexing() throws {
        let validRows = [row(1, bufferLine: 0, text: "ok")]
        let overLimit = FrameResourceWeight(
            commands: .max, ownedUTF8Bytes: 3, arrayEntries: .max,
            rows: 1, spans: .max, overlays: .max,
            spliceEntries: .max, locatorEntries: 1
        )

        #expect(throws: ResidentRowStoreError.resourcePolicy) {
            _ = try ResidentRowStore(
                decodedRows: validRows,
                resourceWeight: FrameResourceWeight(ownedUTF8Bytes: .max),
                limit: overLimit
            )
        }
        #expect(throws: ResidentRowStoreError.duplicateRowID(1)) {
            _ = try ResidentRowStore(
                decodedRows: validRows + validRows,
                resourceWeight: FrameResourceWeight(rows: 2, locatorEntries: 2)
            )
        }
    }

    @Test("replacement validates exact resulting weight before publication")
    func replacementWeightRejectsAtomically() throws {
        let original = try ResidentRowStore(rows: [row(1, bufferLine: 0, text: "ok")])
        var staged = original
        let limit = FrameResourceWeight(
            commands: .max, ownedUTF8Bytes: 3, arrayEntries: .max,
            rows: 1, spans: .max, overlays: .max,
            spliceEntries: .max, locatorEntries: 1
        )

        #expect(throws: ResidentRowStoreError.resourcePolicy) {
            try staged.splice(
                at: 0, removeCount: 1,
                inserting: [row(1, bufferLine: 0, text: "four")], limit: limit
            )
        }
        #expect(staged.resourceWeight == original.resourceWeight)
        #expect(staged.row(at: 0) == original.row(at: 0))
    }

    @Test("5k and 65,536-row corpora retain calibrated default headroom")
    func calibratedCorpusHeadroom() throws {
        for count in [5_000, 65_536] {
            let fixture = rows(0..<count)
            let store = try ResidentRowStore(rows: fixture)
            let limit = FrameResourcePolicy.default.resident.weightPerWindow

            #expect(store.resourceWeight.rows == count)
            #expect(store.resourceWeight.locatorEntries == count)
            #expect(store.resourceWeight.spans == 0)
            #expect(store.resourceWeight.ownedUTF8Bytes == fixture.reduce(0) {
                $0 + $1.text.utf8.count
            })
            #expect(store.resourceWeight.firstExceeded(limit: limit) == nil)
        }
    }

    @Test("full-corpus removal uses cached aggregate resource weight")
    func fullCorpusRemovalUsesCachedWeight() throws {
        let count = 65_536
        var store = try ResidentRowStore(rows: rows(0..<count))
        let before = store.counters.resourceWeightRowsVisited

        try store.splice(at: 0, removeCount: count, inserting: [])

        #expect(store.isEmpty)
        #expect(store.counters.resourceWeightRowsVisited - before == 0)
        #expect(store.validateInvariants())
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

    @Test("identity-preserving batch replacement isolates COW values and copies one locator path")
    func batchReplacementCopyOnWriteAndCounters() throws {
        let committed = try ResidentRowStore(rows: rows(0..<65_536))
        var staged = committed
        #expect(staged.sharesStorage(with: committed))
        let before = staged.counters
        let replacement = row(32_769, bufferLine: 32_768, text: "edited", hash: 900_001)

        try staged.applyBatch(
            [ResidentRowSplice(startIndex: 32_768, deleteCount: 1, insertedRows: [replacement])],
            baseRowCount: committed.count,
            resultRowCount: committed.count
        )

        #expect(committed.row(at: 32_768)?.text == "row 32769")
        #expect(staged.row(at: 32_768) == replacement)
        #expect(!staged.sharesStorage(with: committed))
        let work = staged.counters - before
        #expect(work.rowsVisited == 2)
        #expect(work.chunksTouched == 1)
        #expect(work.idsResolved == 0)
        #expect(work.splices == 1)
        #expect(work.changedRowsValidated == 1)
        #expect(work.locatorNodesCopied == 13)
        #expect(work.fullResets == 0)
        #expect(committed.validateInvariants())
        #expect(staged.validateInvariants())
    }

    @Test("batch replacement rejects duplicate identity and changed ordering atomically")
    func batchReplacementRejection() throws {
        let committed = try ResidentRowStore(rows: rows(0..<8))

        var duplicate = committed
        #expect(throws: ResidentRowStoreError.duplicateRowID(1)) {
            try duplicate.applyBatch(
                [ResidentRowSplice(startIndex: 4, deleteCount: 1, insertedRows: [row(1, bufferLine: 4)])],
                baseRowCount: 8,
                resultRowCount: 8
            )
        }
        #expect(duplicate.counters == committed.counters)
        #expect(duplicate.rows(in: 0..<8).rows == committed.rows(in: 0..<8).rows)

        var unordered = committed
        #expect(throws: ResidentRowStoreError.unsortedBufferLine(previous: 2, next: 1)) {
            try unordered.applyBatch(
                [ResidentRowSplice(startIndex: 3, deleteCount: 1,
                                   insertedRows: [row(4, bufferLine: 1, text: "moved")])],
                baseRowCount: 8,
                resultRowCount: 8
            )
        }
        #expect(unordered.counters == committed.counters)
        #expect(unordered.rows(in: 0..<8).rows == committed.rows(in: 0..<8).rows)

        var reference = committed
        #expect(throws: ResidentRowStoreError.missingRowID(99)) {
            try reference.resolve(rowID: 99, contentHash: 1)
        }
        #expect(reference.rows(in: 0..<8).rows == committed.rows(in: 0..<8).rows)
    }

    @Test("sequential replacement keeps the identity fast path after a structural shift")
    func sequentialReplacementAfterStructuralShift() throws {
        var store = try ResidentRowStore(rows: rows(0..<300), mode: .sequential)
        try store.splice(
            at: 50,
            removeCount: 1,
            inserting: rows(1_000..<1_003, bufferLine: 50)
        )
        #expect(store.row(at: 53)?.rowId == 52)
        #expect(store.row(at: 53)?.bufLine == 53)

        let before = store.counters
        let replacement = row(
            52, bufferLine: 53, text: "edited retained suffix", hash: 900_052
        )
        try store.applyBatch(
            [ResidentRowSplice(
                startIndex: 53, deleteCount: 1, insertedRows: [replacement]
            )],
            baseRowCount: 302,
            resultRowCount: 302
        )

        #expect(store.row(at: 53) == replacement)
        let work = store.counters - before
        #expect(work.changedRowsValidated == 1)
        #expect(work.chunksTouched == 1)
        #expect(work.locatorNodesCopied == 13)
        #expect(store.validateInvariants())
    }

    @Test("multiple disjoint identity-preserving replacements publish atomically")
    func multipleBatchReplacements() throws {
        let original = rows(0..<300)
        var store = try ResidentRowStore(rows: original)
        let replacements = [
            (5, row(6, bufferLine: 5, text: "five", hash: 501)),
            (130, row(131, bufferLine: 130, text: "middle", hash: 502)),
            (270, row(271, bufferLine: 270, text: "late", hash: 503))
        ]
        let before = store.counters

        try store.applyBatch(
            replacements.map {
                ResidentRowSplice(startIndex: $0.0, deleteCount: 1, insertedRows: [$0.1])
            },
            baseRowCount: original.count,
            resultRowCount: original.count
        )

        var oracle = original
        for (index, replacement) in replacements { oracle[index] = replacement }
        #expect(store.rows(in: 0..<store.count).rows == oracle)
        let work = store.counters - before
        #expect(work.changedRowsValidated == replacements.count)
        #expect(work.chunksTouched == replacements.count)
        #expect(work.locatorNodesCopied == replacements.count * 13)
        #expect(work.splices == replacements.count)
        #expect(store.validateInvariants())
    }

    @Test("randomized replacement batches match generic splice semantics")
    func randomizedBatchReplacementParity() throws {
        var generator = Generator(state: 0x2743)
        var oracle = rows(0..<512)
        var fast = try ResidentRowStore(rows: oracle)

        for generation in 0..<100 {
            let replacementCount = generator.int(8) + 1
            var indexes = Set<Int>()
            while indexes.count < replacementCount { indexes.insert(generator.int(oracle.count)) }
            let sortedIndexes = indexes.sorted()
            let replacements = sortedIndexes.map { index in
                row(
                    oracle[index].rowId,
                    bufferLine: oracle[index].bufLine,
                    text: "generation-\(generation)-\(index)",
                    hash: UInt32(generation * 1_000 + index + 1)
                )
            }
            let splices = zip(sortedIndexes, replacements).map {
                ResidentRowSplice(startIndex: $0.0, deleteCount: 1, insertedRows: [$0.1])
            }

            try fast.applyBatch(splices, baseRowCount: oracle.count, resultRowCount: oracle.count)
            var generic = try ResidentRowStore(rows: oracle)
            for (index, replacement) in zip(sortedIndexes, replacements) {
                try generic.splice(at: index, removeCount: 1, inserting: [replacement])
                oracle[index] = replacement
            }

            #expect(fast.rows(in: 0..<fast.count).rows == oracle)
            #expect(fast.rows(in: 0..<fast.count).rows == generic.rows(in: 0..<generic.count).rows)
            #expect(fast.validateInvariants())
        }
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

    @Test("resident semantics remain absolute across local slices")
    func residentSemanticsQueries() throws {
        let content = try semanticContent(rows: rows(0..<8))
        let update = GUIResidentSemanticsUpdate(
            version: 1, mode: 0, windowId: 7, contentEpoch: 9,
            baseRevision: 0, revision: 1, targetRowRevision: 1,
            rowCount: 8, firstRowId: 1, lastRowId: 8,
            cursor: GUIResidentCursor(eligible: true, row: 4, col: 3),
            cursorline: GUIResidentCursorline(row: 4, bg: 0x223344),
            selection: GUIResidentSelection(type: .char, startRow: 4, startCol: 2, endRow: 6, endCol: 1),
            tabWidth: 2, activeGuideCol: 0, guideCols: [0], rowSplices: [],
            guideReplacements: [GUIResidentGuideReplacement(start: 0, end: 8, runs: [
                GUIResidentGuideRun(start: 0, end: 4, level: 0),
                GUIResidentGuideRun(start: 4, end: 6, level: 2),
                GUIResidentGuideRun(start: 6, end: 8, level: 0)
            ])],
            diagnostics: .replace([GUIResidentDiagnostic(startRow: 4, startCol: 1, endRow: 5, endCol: 2, severity: .error)]),
            annotations: .replace([GUIResidentAnnotation(row: 4, kind: .inlineText, fg: 1, bg: 0, text: "hint")])
        )
        let store = try ResidentSemanticStore().applying(update, content: content)
        let slice = store.slice(3..<6)

        #expect(slice.cursor?.row == 4)
        #expect(slice.cursorline?.row == 4)
        #expect(slice.selection?.endRow == 6)
        #expect(store.guideLevel(at: 4) == 2)
        #expect(store.annotations(at: 4).map(\.text) == ["hint"])
        #expect(store.diagnostics(at: 5).count == 1)
    }

    @Test("recovery keyframes accept a positive row revision and point diagnostics")
    func residentSemanticRecoveryKeyframe() throws {
        let content = try semanticContent(rows: rows(0..<2))
        let update = GUIResidentSemanticsUpdate(
            version: 1, mode: 0, windowId: 7, contentEpoch: 9,
            baseRevision: 0, revision: 2, targetRowRevision: 7,
            rowCount: 2, firstRowId: 1, lastRowId: 2,
            cursor: GUIResidentCursor(eligible: true, row: 0, col: 0),
            cursorline: nil,
            selection: nil,
            tabWidth: 2, activeGuideCol: 0, guideCols: [], rowSplices: [],
            guideReplacements: [GUIResidentGuideReplacement(start: 0, end: 2, runs: [GUIResidentGuideRun(start: 0, end: 2, level: 0)])],
            diagnostics: .replace([GUIResidentDiagnostic(startRow: 0, startCol: 3, endRow: 0, endCol: 3, severity: .warning)]),
            annotations: .replace([])
        )

        let recovered = try ResidentSemanticStore().applying(update, content: content)

        #expect(recovered.rowRevision == 7)
        #expect(recovered.diagnostics(at: 0).count == 1)
    }

    @Test("structural splices shift retained semantics before sparse replacements")
    func residentSemanticSplice() throws {
        let originalRows = rows(0..<8)
        let original = try semanticContent(rows: originalRows)
        let keyframe = GUIResidentSemanticsUpdate(
            version: 1, mode: 0, windowId: 7, contentEpoch: 9, baseRevision: 0, revision: 1, targetRowRevision: 1,
            rowCount: 8, firstRowId: 1, lastRowId: 8, cursor: GUIResidentCursor(eligible: true, row: 4, col: 0), cursorline: nil, selection: nil,
            tabWidth: 2, activeGuideCol: 0, guideCols: [0], rowSplices: [],
            guideReplacements: [GUIResidentGuideReplacement(start: 0, end: 8, runs: [GUIResidentGuideRun(start: 0, end: 8, level: 1)])],
            diagnostics: .replace([GUIResidentDiagnostic(startRow: 4, startCol: 0, endRow: 5, endCol: 1, severity: .warning)]),
            annotations: .replace([GUIResidentAnnotation(row: 4, kind: .inlineText, fg: 1, bg: 0, text: "hint")])
        )
        let committed = try ResidentSemanticStore().applying(keyframe, content: original)
        var changedRows = originalRows
        changedRows.insert(row(99, bufferLine: 2), at: 2)
        let changed = try semanticContent(rows: changedRows)
        let delta = GUIResidentSemanticsUpdate(
            version: 1, mode: 1, windowId: 7, contentEpoch: 9, baseRevision: 1, revision: 2, targetRowRevision: 2,
            rowCount: 9, firstRowId: 1, lastRowId: 8, cursor: GUIResidentCursor(eligible: true, row: 5, col: 0), cursorline: nil, selection: nil,
            tabWidth: 2, activeGuideCol: 0, guideCols: [0], rowSplices: [GUIResidentRowSplice(start: 2, deleteCount: 0, insertCount: 1)],
            guideReplacements: [GUIResidentGuideReplacement(start: 2, end: 3, runs: [GUIResidentGuideRun(start: 2, end: 3, level: 0)])],
            diagnostics: .replaceRanges([GUIResidentDiagnosticReplacement(start: 5, end: 6, diagnostics: [GUIResidentDiagnostic(startRow: 5, startCol: 1, endRow: 6, endCol: 1, severity: .info)])]),
            annotations: .replaceRanges([])
        )
        let next = try committed.applying(delta, content: changed)

        #expect(next.annotations(at: 5).map(\.text) == ["hint"])
        #expect(next.diagnostics(at: 5).map(\.severity) == [.info])
        #expect(committed.annotations(at: 4).map(\.text) == ["hint"])
    }

    @Test("invalid resident semantic candidates preserve the committed value")
    func residentSemanticRejection() throws {
        let content = try semanticContent(rows: rows(0..<2))
        let keyframe = GUIResidentSemanticsUpdate(
            version: 1, mode: 0, windowId: 7, contentEpoch: 9, baseRevision: 0, revision: 1, targetRowRevision: 1,
            rowCount: 2, firstRowId: 1, lastRowId: 2, cursor: GUIResidentCursor(eligible: true, row: 0, col: 0), cursorline: nil, selection: nil,
            tabWidth: 2, activeGuideCol: 0, guideCols: [], rowSplices: [],
            guideReplacements: [GUIResidentGuideReplacement(start: 0, end: 2, runs: [GUIResidentGuideRun(start: 0, end: 2, level: 0)])],
            diagnostics: .replace([]), annotations: .replace([])
        )
        let committed = try ResidentSemanticStore().applying(keyframe, content: content)
        let invalid = GUIResidentSemanticsUpdate(
            version: 1, mode: 1, windowId: 7, contentEpoch: 10, baseRevision: 1, revision: 2, targetRowRevision: 1,
            rowCount: 2, firstRowId: 1, lastRowId: 2, cursor: GUIResidentCursor(eligible: true, row: 0, col: 0), cursorline: nil, selection: nil,
            tabWidth: 2, activeGuideCol: 0, guideCols: [], rowSplices: [], guideReplacements: [], diagnostics: .retain, annotations: .retain
        )

        #expect(throws: ResidentSemanticStoreError.invalid) { try committed.applying(invalid, content: content) }
        #expect(committed.revision == 1)
        #expect(committed.rowCount == 2)
    }

    private func semanticContent(rows: [GUIVisualRow]) throws -> GUIWindowContent {
        try GUIWindowContent(
            windowId: 7, fullRefresh: true, contentEpoch: 9, cursorVisible: false,
            cursorRow: 0, cursorCol: 0, cursorShape: .block, rowStoreMode: .sequential,
            rows: rows, selection: nil, searchMatches: [], diagnosticUnderlines: [], documentHighlights: []
        )
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
