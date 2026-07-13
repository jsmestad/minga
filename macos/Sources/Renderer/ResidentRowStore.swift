import Foundation

/// Deterministic work counters for resident-row updates and viewport reads.
public struct ResidentRowStoreCounters: Sendable, Equatable {
    /// Rows read while validating or serving a changed region.
    public var rowsVisited = 0
    /// Sequence chunks read or rebuilt.
    public var chunksTouched = 0
    /// Retained row references resolved.
    public var idsResolved = 0
    /// Row splices applied.
    public var splices = 0
    /// Rows inserted and validated by splice operations.
    public var changedRowsValidated = 0
    /// Persistent locator radix nodes copied.
    public var locatorNodesCopied = 0
    /// Complete store resets.
    public var fullResets = 0

    /// Creates zeroed counters.
    public init() {}

    /// Adds independently staged operation counters.
    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            rowsVisited: lhs.rowsVisited + rhs.rowsVisited,
            chunksTouched: lhs.chunksTouched + rhs.chunksTouched,
            idsResolved: lhs.idsResolved + rhs.idsResolved,
            splices: lhs.splices + rhs.splices,
            changedRowsValidated: lhs.changedRowsValidated + rhs.changedRowsValidated,
            locatorNodesCopied: lhs.locatorNodesCopied + rhs.locatorNodesCopied,
            fullResets: lhs.fullResets + rhs.fullResets
        )
    }

    /// Computes a nonnegative operation delta between cumulative counters.
    public static func - (lhs: Self, rhs: Self) -> Self {
        Self(
            rowsVisited: max(lhs.rowsVisited - rhs.rowsVisited, 0),
            chunksTouched: max(lhs.chunksTouched - rhs.chunksTouched, 0),
            idsResolved: max(lhs.idsResolved - rhs.idsResolved, 0),
            splices: max(lhs.splices - rhs.splices, 0),
            changedRowsValidated: max(lhs.changedRowsValidated - rhs.changedRowsValidated, 0),
            locatorNodesCopied: max(lhs.locatorNodesCopied - rhs.locatorNodesCopied, 0),
            fullResets: max(lhs.fullResets - rhs.fullResets, 0)
        )
    }

    private init(rowsVisited: Int, chunksTouched: Int, idsResolved: Int, splices: Int,
                 changedRowsValidated: Int, locatorNodesCopied: Int, fullResets: Int) {
        self.rowsVisited = rowsVisited
        self.chunksTouched = chunksTouched
        self.idsResolved = idsResolved
        self.splices = splices
        self.changedRowsValidated = changedRowsValidated
        self.locatorNodesCopied = locatorNodesCopied
        self.fullResets = fullResets
    }
}

/// Failures produced before a resident-row mutation is published.
public enum ResidentRowStoreError: Error, Sendable, Equatable {
    /// A splice or result count does not fit the immutable base.
    case invalidRange(index: Int, removeCount: Int, rowCount: Int)
    /// The resulting sequence contains a duplicate durable row identity.
    case duplicateRowID(UInt64)
    /// Resulting buffer-line metadata is not nondecreasing.
    case unsortedBufferLine(previous: UInt32, next: UInt32)
    /// A retained row identity is absent from the immutable base.
    case missingRowID(UInt64)
    /// A retained identity exists but its content hash differs.
    case contentHashMismatch(rowID: UInt64, expected: UInt32, actual: UInt32)
    /// The exact resulting resident weight exceeds policy or overflows.
    case resourcePolicy
}

/// One resolved immutable-base splice for atomic store application.
public struct ResidentRowSplice: Sendable, Equatable {
    /// Zero-based coordinate in the immutable base sequence.
    public let startIndex: Int
    /// Number of immutable-base rows deleted.
    public let deleteCount: Int
    /// Fully prepared rows inserted at the splice coordinate.
    public let insertedRows: [GUIVisualRow]

    /// Creates a resolved resident row splice.
    public init(startIndex: Int, deleteCount: Int, insertedRows: [GUIVisualRow]) {
        self.startIndex = startIndex
        self.deleteCount = deleteCount
        self.insertedRows = insertedRows
    }
}

/// Lightweight identity and ordering fields used while validating a delta.
struct ResidentRowMetadata: Sendable, Equatable {
    let rowID: UInt64
    let contentHash: UInt32
    let bufferLine: UInt32
}

/// A value-semantic, copy-on-write sequence optimized for resident editor rows.
///
/// Rows live in fixed-capacity leaves of an immutable order-statistics treap.
/// Structural edits rebuild only leaves intersecting the splice and the O(log n)
/// tree paths above them. Durable row locators contain stable leaf identities, so
/// rows after a splice never need their global indexes rewritten.
public struct ResidentRowStore: Sendable {
    /// Maximum rows stored in one sequence leaf.
    public static let chunkCapacity = 128
    /// Target occupancy for non-edge leaves after structural edits.
    public static let minimumChunkOccupancy = chunkCapacity / 2

    private struct Chunk: Sendable {
        let id: UInt64
        let rows: [GUIVisualRow]
        let minBufferLine: UInt32
        let maxBufferLine: UInt32

        init(id: UInt64, rows: [GUIVisualRow]) {
            self.id = id
            self.rows = rows
            minBufferLine = rows.first?.bufLine ?? 0
            maxBufferLine = rows.last?.bufLine ?? 0
        }
    }

    private final class Node: @unchecked Sendable {
        let chunk: Chunk
        let priority: UInt64
        let left: Node?
        let right: Node?
        let rowCount: Int
        let chunkCount: Int
        let minBufferLine: UInt32
        let maxBufferLine: UInt32

        init(chunk: Chunk, left: Node? = nil, right: Node? = nil) {
            self.chunk = chunk
            priority = ResidentRowStore.priority(for: chunk.id)
            self.left = left
            self.right = right
            rowCount = (left?.rowCount ?? 0) + chunk.rows.count + (right?.rowCount ?? 0)
            chunkCount = (left?.chunkCount ?? 0) + 1 + (right?.chunkCount ?? 0)
            minBufferLine = left?.minBufferLine ?? chunk.minBufferLine
            maxBufferLine = right?.maxBufferLine ?? chunk.maxBufferLine
        }
    }

    private struct Locator: Sendable {
        let chunkID: UInt64
        let offset: Int
        let row: GUIVisualRow
    }

    /// Immutable 32-way radix node. Thirteen 5-bit steps cover all 64 row-id bits;
    /// the final step uses the low four bits, so distinct IDs never share a leaf.
    private final class LocatorRadixNode: @unchecked Sendable {
        let children: [LocatorRadixNode?]
        let value: Locator?

        init(children: [LocatorRadixNode?] = Array(repeating: nil, count: 32), value: Locator? = nil) {
            self.children = children
            self.value = value
        }
    }

    private struct LocatorTable: @unchecked Sendable {
        private static let levelCount = 13
        private var roots: [LocatorRadixNode?] = Array(repeating: nil, count: 32)
        private(set) var count = 0

        subscript(rowID: UInt64) -> Locator? {
            var node = roots[Self.branch(for: rowID, level: 0)]
            for level in 1..<Self.levelCount {
                node = node?.children[Self.branch(for: rowID, level: level)]
            }
            return node?.value
        }

        mutating func set(_ locator: Locator, for rowID: UInt64, copiedNodes: inout Int) {
            let existed = self[rowID] != nil
            let rootIndex = Self.branch(for: rowID, level: 0)
            roots[rootIndex] = Self.setting(
                roots[rootIndex], rowID: rowID, locator: locator,
                level: 1, copiedNodes: &copiedNodes
            )
            if !existed { count += 1 }
        }

        mutating func remove(_ rowID: UInt64, copiedNodes: inout Int) {
            guard self[rowID] != nil else { return }
            let rootIndex = Self.branch(for: rowID, level: 0)
            roots[rootIndex] = Self.removing(
                roots[rootIndex], rowID: rowID, level: 1, copiedNodes: &copiedNodes
            )
            count -= 1
        }

        mutating func removeAll() {
            roots = Array(repeating: nil, count: 32)
            count = 0
        }

        private static func branch(for rowID: UInt64, level: Int) -> Int {
            let shift = max(64 - ((level + 1) * 5), 0)
            return Int((rowID >> UInt64(shift)) & (level == levelCount - 1 ? 0x0F : 0x1F))
        }

        private static func setting(_ node: LocatorRadixNode?, rowID: UInt64, locator: Locator,
                                    level: Int, copiedNodes: inout Int) -> LocatorRadixNode {
            copiedNodes += 1
            if level == levelCount {
                return LocatorRadixNode(
                    children: node?.children ?? Array(repeating: nil, count: 32),
                    value: locator
                )
            }
            let index = branch(for: rowID, level: level)
            var children = node?.children ?? Array(repeating: nil, count: 32)
            children[index] = setting(
                children[index], rowID: rowID, locator: locator,
                level: level + 1, copiedNodes: &copiedNodes
            )
            return LocatorRadixNode(children: children, value: node?.value)
        }

        private static func removing(_ node: LocatorRadixNode?, rowID: UInt64, level: Int,
                                     copiedNodes: inout Int) -> LocatorRadixNode? {
            guard let node else { return nil }
            copiedNodes += 1
            if level == levelCount { return nil }
            let index = branch(for: rowID, level: level)
            var children = node.children
            children[index] = removing(children[index], rowID: rowID, level: level + 1,
                                       copiedNodes: &copiedNodes)
            if children.allSatisfy({ $0 == nil }), node.value == nil { return nil }
            return LocatorRadixNode(children: children, value: node.value)
        }
    }

    private final class Storage: @unchecked Sendable {
        var root: Node?
        var locators: LocatorTable
        var nextChunkID: UInt64
        var counters: ResidentRowStoreCounters
        var resourceWeight: FrameResourceWeight

        init(root: Node? = nil, locators: LocatorTable = .init(), nextChunkID: UInt64 = 1,
             counters: ResidentRowStoreCounters = .init(),
             resourceWeight: FrameResourceWeight = .init()) {
            self.root = root
            self.locators = locators
            self.nextChunkID = nextChunkID
            self.counters = counters
            self.resourceWeight = resourceWeight
        }

        func copy() -> Storage {
            Storage(root: root, locators: locators, nextChunkID: nextChunkID,
                    counters: counters, resourceWeight: resourceWeight)
        }
    }

    private var storage = Storage()

    /// Creates an empty resident row store.
    public init() {}

    /// Creates a validated store from a complete row snapshot.
    public init(rows: [GUIVisualRow]) throws {
        try replaceAll(with: rows)
    }

    /// Builds decoded protocol content from a checked row weight. Identity,
    /// ordering, and policy validation all complete before chunks or indexes exist.
    public init(
        decodedRows rows: [GUIVisualRow],
        resourceWeight: FrameResourceWeight,
        limit: FrameResourceWeight? = nil
    ) throws {
        do {
            try Self.validateRows(rows)
            try Self.validate(resourceWeight, limit: limit)
        } catch let error as ResidentRowStoreError {
            throw error
        } catch is FrameResourceError {
            throw ResidentRowStoreError.resourcePolicy
        }

        self.storage = Storage(resourceWeight: resourceWeight)
        let chunks = makeChunks(rows)
        storage.root = Self.buildTree(chunks)
        indexChunks(chunks)
        storage.counters.rowsVisited = rows.count
        storage.counters.chunksTouched = chunks.count
        storage.counters.fullResets = 1
    }

    /// Number of resident visual rows.
    public var count: Int { storage.root?.rowCount ?? 0 }
    /// Whether the store contains no rows.
    public var isEmpty: Bool { count == 0 }
    /// Number of sequence leaf chunks.
    public var chunkCount: Int { storage.root?.chunkCount ?? 0 }
    /// Cumulative deterministic store-operation counters.
    public var counters: ResidentRowStoreCounters { storage.counters }
    /// Exact cached ownership of resident row strings, spans, and locators.
    public var resourceWeight: FrameResourceWeight { storage.resourceWeight }

    /// Replaces the complete sequence and records one explicit full reset.
    public mutating func replaceAll(
        with rows: [GUIVisualRow], limit: FrameResourceWeight? = nil
    ) throws {
        try Self.validateRows(rows)
        let resultingWeight = try Self.weight(of: rows)
        try Self.validate(resultingWeight, limit: limit)
        ensureUniqueStorage()
        storage.root = nil
        storage.locators.removeAll()
        let chunks = makeChunks(rows)
        storage.root = Self.buildTree(chunks)
        indexChunks(chunks)
        storage.resourceWeight = resultingWeight
        storage.counters.rowsVisited += rows.count
        storage.counters.chunksTouched += chunks.count
        storage.counters.fullResets += 1
    }

    /// Returns a row by visual index in O(log chunks).
    public func row(at index: Int) -> GUIVisualRow? {
        guard index >= 0, index < count else { return nil }
        var node = storage.root
        var remaining = index
        while let current = node {
            let leftCount = current.left?.rowCount ?? 0
            if remaining < leftCount {
                node = current.left
            } else if remaining < leftCount + current.chunk.rows.count {
                return current.chunk.rows[remaining - leftCount]
            } else {
                remaining -= leftCount + current.chunk.rows.count
                node = current.right
            }
        }
        return nil
    }

    /// Resolves a durable row identity and content hash without scanning rows.
    public mutating func resolve(rowID: UInt64, contentHash: UInt32) throws -> GUIVisualRow {
        ensureUniqueStorage()
        storage.counters.idsResolved += 1
        guard let locator = storage.locators[rowID] else { throw ResidentRowStoreError.missingRowID(rowID) }
        guard locator.row.contentHash == contentHash else {
            throw ResidentRowStoreError.contentHashMismatch(
                rowID: rowID, expected: locator.row.contentHash, actual: contentHash
            )
        }
        return locator.row
    }

    /// Validates one retained identity without copying its complete row payload.
    mutating func inspectReference(rowID: UInt64, contentHash: UInt32) throws -> ResidentRowMetadata {
        ensureUniqueStorage()
        storage.counters.idsResolved += 1
        guard let locator = storage.locators[rowID] else { throw ResidentRowStoreError.missingRowID(rowID) }
        guard locator.row.contentHash == contentHash else {
            throw ResidentRowStoreError.contentHashMismatch(
                rowID: rowID, expected: locator.row.contentHash, actual: contentHash
            )
        }
        return ResidentRowMetadata(
            rowID: rowID,
            contentHash: contentHash,
            bufferLine: locator.row.bufLine
        )
    }

    /// Records validation and identity-comparison work performed outside the tree.
    mutating func recordRowsVisited(_ count: Int) {
        guard count > 0 else { return }
        ensureUniqueStorage()
        storage.counters.rowsVisited += count
    }

    /// Carries validated staging work into the store that will be published.
    mutating func recordStagingCounters(_ counters: ResidentRowStoreCounters) {
        guard counters != ResidentRowStoreCounters() else { return }
        ensureUniqueStorage()
        storage.counters.rowsVisited += counters.rowsVisited
        storage.counters.chunksTouched += counters.chunksTouched
        storage.counters.idsResolved += counters.idsResolved
        storage.counters.splices += counters.splices
        storage.counters.changedRowsValidated += counters.changedRowsValidated
        storage.counters.locatorNodesCopied += counters.locatorNodesCopied
        storage.counters.fullResets += counters.fullResets
    }

    /// Returns the first visual row whose buffer line is at least `bufferLine`.
    /// Multiple wraps or decorations may share a buffer line; the first is returned.
    public func lowerBound(bufferLine: UInt32) -> Int {
        Self.lowerBound(node: storage.root, bufferLine: bufferLine, base: 0) ?? count
    }

    /// Visits exactly the requested row range plus O(log chunks) index nodes.
    public func rows(in range: Range<Int>) -> (rows: [GUIVisualRow], counters: ResidentRowStoreCounters) {
        let lower = min(max(range.lowerBound, 0), count)
        let upper = min(max(range.upperBound, lower), count)
        var rows: [GUIVisualRow] = []
        rows.reserveCapacity(upper - lower)
        var touched = Set<UInt64>()
        Self.collect(storage.root, nodeStart: 0, range: lower..<upper, rows: &rows, touched: &touched)
        var counters = ResidentRowStoreCounters()
        counters.rowsVisited = rows.count
        counters.chunksTouched = touched.count
        return (rows, counters)
    }

    /// Replaces one row without changing global indexes.
    public mutating func replace(at index: Int, with row: GUIVisualRow) throws {
        try splice(at: index, removeCount: 1, inserting: [row])
    }

    /// Applies disjoint immutable-base splices as one value-semantic batch.
    ///
    /// Every range and result count is validated before the receiver is replaced.
    public mutating func applyBatch(
        _ splices: [ResidentRowSplice], baseRowCount: Int,
        resultRowCount: Int, limit: FrameResourceWeight? = nil
    ) throws {
        guard baseRowCount == count, resultRowCount >= 0 else {
            throw ResidentRowStoreError.invalidRange(index: 0, removeCount: 0, rowCount: count)
        }
        var previousStart: Int?
        var previousEnd = 0
        var computed = baseRowCount
        for splice in splices {
            guard splice.startIndex >= 0, splice.deleteCount >= 0,
                  splice.startIndex <= baseRowCount,
                  splice.startIndex + splice.deleteCount <= baseRowCount,
                  previousStart.map({ splice.startIndex > $0 }) ?? true,
                  splice.startIndex >= previousEnd,
                  splice.deleteCount > 0 || !splice.insertedRows.isEmpty else {
                throw ResidentRowStoreError.invalidRange(
                    index: splice.startIndex, removeCount: splice.deleteCount, rowCount: baseRowCount
                )
            }
            try Self.validateRows(splice.insertedRows)
            previousStart = splice.startIndex
            previousEnd = splice.startIndex + splice.deleteCount
            computed = computed - splice.deleteCount + splice.insertedRows.count
        }
        guard computed == resultRowCount else {
            throw ResidentRowStoreError.invalidRange(index: computed, removeCount: 0, rowCount: resultRowCount)
        }

        let removedWeight: FrameResourceWeight
        let insertedWeight: FrameResourceWeight
        do {
            var removed = FrameResourceWeight()
            var inserted = FrameResourceWeight()
            for splice in splices {
                removed = try removed.adding(
                    try weight(in: splice.startIndex..<(splice.startIndex + splice.deleteCount))
                )
                inserted = try inserted.adding(try Self.weight(of: splice.insertedRows))
            }
            let resulting = try storage.resourceWeight.subtracting(removed).adding(inserted)
            try Self.validate(resulting, limit: limit)
            removedWeight = removed
            insertedWeight = inserted
        } catch is FrameResourceError {
            throw ResidentRowStoreError.resourcePolicy
        }

        if !splices.isEmpty, let replacements = try inPlaceReplacements(for: splices) {
            var staged = self
            staged.applyInPlaceReplacements(replacements)
            staged.storage.resourceWeight = try staged.storage.resourceWeight
                .subtracting(removedWeight).adding(insertedWeight)
            self = staged
            return
        }

        var staged = self
        var coordinateAdjustment = 0
        for splice in splices {
            try staged.splice(
                at: splice.startIndex + coordinateAdjustment,
                removeCount: splice.deleteCount,
                inserting: splice.insertedRows,
                limit: nil
            )
            coordinateAdjustment += splice.insertedRows.count - splice.deleteCount
        }
        guard staged.count == resultRowCount else {
            throw ResidentRowStoreError.invalidRange(index: staged.count, removeCount: 0, rowCount: resultRowCount)
        }
        self = staged
    }

    /// Applies a validated structural edit while preserving unaffected chunk IDs.
    public mutating func splice(
        at index: Int, removeCount: Int, inserting insertedRows: [GUIVisualRow],
        limit: FrameResourceWeight? = nil
    ) throws {
        guard index >= 0, removeCount >= 0, index <= count, index + removeCount <= count else {
            throw ResidentRowStoreError.invalidRange(index: index, removeCount: removeCount, rowCount: count)
        }
        guard removeCount > 0 || !insertedRows.isEmpty else { return }

        let removedResourceWeight: FrameResourceWeight
        let insertedResourceWeight: FrameResourceWeight
        do {
            removedResourceWeight = try weight(in: index..<(index + removeCount))
            insertedResourceWeight = try Self.weight(of: insertedRows)
            let resulting = try storage.resourceWeight
                .subtracting(removedResourceWeight).adding(insertedResourceWeight)
            try Self.validate(resulting, limit: limit)
        } catch is FrameResourceError {
            throw ResidentRowStoreError.resourcePolicy
        }

        let removedIDs = Set((index..<(index + removeCount)).compactMap { row(at: $0)?.rowId })
        for row in insertedRows where storage.locators[row.rowId] != nil && !removedIDs.contains(row.rowId) {
            throw ResidentRowStoreError.duplicateRowID(row.rowId)
        }
        try Self.validateRows(insertedRows)
        if let first = insertedRows.first, index > 0, let previous = row(at: index - 1), previous.bufLine > first.bufLine {
            throw ResidentRowStoreError.unsortedBufferLine(previous: previous.bufLine, next: first.bufLine)
        }
        let followingIndex = index + removeCount
        if let last = insertedRows.last, followingIndex < count, let following = row(at: followingIndex), last.bufLine > following.bufLine {
            throw ResidentRowStoreError.unsortedBufferLine(previous: last.bufLine, next: following.bufLine)
        }
        if insertedRows.isEmpty, index > 0, followingIndex < count,
           let previous = row(at: index - 1), let following = row(at: followingIndex),
           previous.bufLine > following.bufLine {
            throw ResidentRowStoreError.unsortedBufferLine(previous: previous.bufLine, next: following.bufLine)
        }

        ensureUniqueStorage()
        if storage.root == nil {
            let chunks = makeChunks(insertedRows)
            storage.root = Self.buildTree(chunks)
            indexChunks(chunks)
            storage.resourceWeight = insertedResourceWeight
            recordSplice(oldRows: 0, newRows: insertedRows.count, changedRows: insertedRows.count,
                         oldChunks: 0, newChunks: chunks.count)
            return
        }

        guard let startLocation = chunkLocation(
            forRowIndex: min(index, max(count - 1, 0))
        ) else {
            throw ResidentRowStoreError.invalidRange(
                index: index, removeCount: removeCount, rowCount: count
            )
        }
        let endLocation: (rank: Int, offset: Int)
        if removeCount == 0 {
            endLocation = startLocation
        } else {
            guard let resolvedEnd = chunkLocation(forRowIndex: index + removeCount - 1) else {
                throw ResidentRowStoreError.invalidRange(
                    index: index, removeCount: removeCount, rowCount: count
                )
            }
            endLocation = resolvedEnd
        }
        var firstChunk = max(startLocation.rank - 1, 0)
        var lastChunk = min(endLocation.rank + 1, chunkCount - 1)
        var firstRow = rowPrefix(beforeChunk: firstChunk)
        var selectedRows = rowsForChunks(firstChunk...lastChunk)
        var localIndex = index - firstRow
        selectedRows.replaceSubrange(localIndex..<(localIndex + removeCount), with: insertedRows)

        while selectedRows.count < Self.minimumChunkOccupancy && (firstChunk > 0 || lastChunk + 1 < chunkCount) {
            if firstChunk > 0 {
                firstChunk -= 1
                let prefix = rowsForChunks(firstChunk...firstChunk)
                selectedRows.insert(contentsOf: prefix, at: 0)
                firstRow -= prefix.count
                localIndex += prefix.count
            }
            if selectedRows.count < Self.minimumChunkOccupancy, lastChunk + 1 < chunkCount {
                lastChunk += 1
                selectedRows.append(contentsOf: rowsForChunks(lastChunk...lastChunk))
            }
        }

        let oldChunkCount = lastChunk - firstChunk + 1
        let (left, remainder) = Self.splitByChunk(storage.root, count: firstChunk)
        let (removedTree, right) = Self.splitByChunk(remainder, count: oldChunkCount)
        let removedChunks = Self.flattenChunks(removedTree)
        for chunk in removedChunks {
            for row in chunk.rows {
                storage.locators.remove(row.rowId, copiedNodes: &storage.counters.locatorNodesCopied)
            }
        }

        let newChunks = makeChunks(selectedRows)
        indexChunks(newChunks)
        storage.root = Self.merge(Self.merge(left, Self.buildTree(newChunks)), right)
        storage.resourceWeight = try storage.resourceWeight
            .subtracting(removedResourceWeight).adding(insertedResourceWeight)
        recordSplice(
            oldRows: removedChunks.reduce(0) { $0 + $1.rows.count },
            newRows: selectedRows.count,
            changedRows: insertedRows.count,
            oldChunks: removedChunks.count,
            newChunks: newChunks.count
        )
    }

    /// Debug invariant seam used by deterministic and randomized tests.
    public func validateInvariants() -> Bool {
        let chunks = Self.flattenChunks(storage.root)
        guard chunks.allSatisfy({ !$0.rows.isEmpty && $0.rows.count <= Self.chunkCapacity }) else { return false }
        if chunks.count > 2 {
            guard chunks.dropFirst().dropLast().allSatisfy({ $0.rows.count >= Self.minimumChunkOccupancy }) else { return false }
        }
        var ids = Set<UInt64>()
        var previousBufferLine: UInt32?
        for chunk in chunks {
            for (offset, row) in chunk.rows.enumerated() {
                guard previousBufferLine.map({ $0 <= row.bufLine }) ?? true,
                      ids.insert(row.rowId).inserted,
                      let locator = storage.locators[row.rowId],
                      locator.chunkID == chunk.id,
                      locator.offset == offset,
                      locator.row == row else { return false }
                previousBufferLine = row.bufLine
            }
        }
        return ids.count == count && storage.locators.count == count
    }

    /// Chunk occupancies exposed for structural invariant tests.
    public var chunkOccupancies: [Int] { Self.flattenChunks(storage.root).map { $0.rows.count } }

    private struct InPlaceReplacement {
        let index: Int
        let oldRow: GUIVisualRow
        let newRow: GUIVisualRow
        let chunkID: UInt64
        let offset: Int
    }

    /// Recognizes identity-preserving one-for-one edits and validates their final
    /// ordering against the immutable base before any path is copied.
    private func inPlaceReplacements(
        for splices: [ResidentRowSplice]
    ) throws -> [InPlaceReplacement]? {
        guard splices.allSatisfy({ $0.deleteCount == 1 && $0.insertedRows.count == 1 }) else {
            return nil
        }

        var finalRows: [Int: GUIVisualRow] = [:]
        finalRows.reserveCapacity(splices.count)
        var replacements: [InPlaceReplacement] = []
        replacements.reserveCapacity(splices.count)

        for splice in splices {
            let newRow = splice.insertedRows[0]
            guard let oldRow = row(at: splice.startIndex), oldRow.rowId == newRow.rowId,
                  let locator = storage.locators[oldRow.rowId], locator.row == oldRow else {
                return nil
            }
            finalRows[splice.startIndex] = newRow
            replacements.append(InPlaceReplacement(
                index: splice.startIndex,
                oldRow: oldRow,
                newRow: newRow,
                chunkID: locator.chunkID,
                offset: locator.offset
            ))
        }

        for replacement in replacements where replacement.newRow.bufLine != replacement.oldRow.bufLine {
            if replacement.index > 0,
               let previous = finalRows[replacement.index - 1] ?? row(at: replacement.index - 1),
               previous.bufLine > replacement.newRow.bufLine {
                throw ResidentRowStoreError.unsortedBufferLine(
                    previous: previous.bufLine, next: replacement.newRow.bufLine
                )
            }
            if replacement.index + 1 < count,
               let following = finalRows[replacement.index + 1] ?? row(at: replacement.index + 1),
               replacement.newRow.bufLine > following.bufLine {
                throw ResidentRowStoreError.unsortedBufferLine(
                    previous: replacement.newRow.bufLine, next: following.bufLine
                )
            }
        }
        return replacements
    }

    /// Publishes only immutable path copies. Chunk IDs remain stable, so each
    /// durable locator needs one radix update and no neighboring row is reindexed.
    private mutating func applyInPlaceReplacements(_ replacements: [InPlaceReplacement]) {
        ensureUniqueStorage()
        for replacement in replacements {
            storage.root = Self.replacingRow(
                storage.root, at: replacement.index, with: replacement.newRow
            )
            storage.locators.set(
                Locator(
                    chunkID: replacement.chunkID,
                    offset: replacement.offset,
                    row: replacement.newRow
                ),
                for: replacement.newRow.rowId,
                copiedNodes: &storage.counters.locatorNodesCopied
            )
        }
        storage.counters.rowsVisited += replacements.count * 2
        storage.counters.chunksTouched += replacements.count
        storage.counters.splices += replacements.count
        storage.counters.changedRowsValidated += replacements.count
    }

    private mutating func ensureUniqueStorage() {
        if !isKnownUniquelyReferenced(&storage) { storage = storage.copy() }
    }

    private mutating func makeChunks(_ rows: [GUIVisualRow]) -> [Chunk] {
        guard !rows.isEmpty else { return [] }
        let chunkTotal = (rows.count + Self.chunkCapacity - 1) / Self.chunkCapacity
        let base = rows.count / chunkTotal
        let extra = rows.count % chunkTotal
        var chunks: [Chunk] = []
        chunks.reserveCapacity(chunkTotal)
        var offset = 0
        for chunkIndex in 0..<chunkTotal {
            let size = base + (chunkIndex < extra ? 1 : 0)
            let id = storage.nextChunkID
            storage.nextChunkID &+= 1
            chunks.append(Chunk(id: id, rows: Array(rows[offset..<(offset + size)])))
            offset += size
        }
        return chunks
    }

    private mutating func indexChunks(_ chunks: [Chunk]) {
        for chunk in chunks {
            for (offset, row) in chunk.rows.enumerated() {
                storage.locators.set(
                    Locator(chunkID: chunk.id, offset: offset, row: row),
                    for: row.rowId,
                    copiedNodes: &storage.counters.locatorNodesCopied
                )
            }
        }
    }

    private mutating func recordSplice(oldRows: Int, newRows: Int, changedRows: Int,
                                       oldChunks: Int, newChunks: Int) {
        storage.counters.rowsVisited += oldRows + newRows
        storage.counters.changedRowsValidated += changedRows
        storage.counters.chunksTouched += max(oldChunks, newChunks)
        storage.counters.splices += 1
    }

    private func chunkLocation(forRowIndex index: Int) -> (rank: Int, offset: Int)? {
        guard index >= 0, index < count else { return nil }
        var node = storage.root
        var remaining = index
        var rankBase = 0
        while let current = node {
            let leftRows = current.left?.rowCount ?? 0
            let leftChunks = current.left?.chunkCount ?? 0
            if remaining < leftRows {
                node = current.left
            } else if remaining < leftRows + current.chunk.rows.count {
                return (rankBase + leftChunks, remaining - leftRows)
            } else {
                remaining -= leftRows + current.chunk.rows.count
                rankBase += leftChunks + 1
                node = current.right
            }
        }
        return nil
    }

    private func rowPrefix(beforeChunk rank: Int) -> Int {
        let (left, _) = Self.splitByChunk(storage.root, count: rank)
        return left?.rowCount ?? 0
    }

    private func rowsForChunks(_ ranks: ClosedRange<Int>) -> [GUIVisualRow] {
        let (_, remainder) = Self.splitByChunk(storage.root, count: ranks.lowerBound)
        let (selected, _) = Self.splitByChunk(remainder, count: ranks.count)
        return Self.flattenChunks(selected).flatMap(\.rows)
    }

    private func weight(in range: Range<Int>) throws -> FrameResourceWeight {
        var result = FrameResourceWeight()
        for index in range {
            guard let row = row(at: index) else {
                throw ResidentRowStoreError.invalidRange(
                    index: range.lowerBound, removeCount: range.count, rowCount: count
                )
            }
            result = try result.adding(Self.weight(of: row))
        }
        return result
    }

    static func weight(of row: GUIVisualRow) -> FrameResourceWeight {
        FrameResourceWeight(
            ownedUTF8Bytes: row.text.utf8.count,
            arrayEntries: row.spans.count,
            rows: 1,
            spans: row.spans.count,
            locatorEntries: 1
        )
    }

    static func weight(of rows: [GUIVisualRow]) throws -> FrameResourceWeight {
        try rows.reduce(into: FrameResourceWeight()) { result, row in
            result = try result.adding(weight(of: row))
        }
    }

    private static func validate(
        _ weight: FrameResourceWeight, limit: FrameResourceWeight?
    ) throws {
        guard let limit, let dimension = weight.firstExceeded(limit: limit) else { return }
        throw FrameResourceError.limitExceeded(
            dimension: dimension, used: 0, requested: weight.value(dimension),
            limit: limit.value(dimension)
        )
    }

    static func validateRows(_ rows: [GUIVisualRow]) throws {
        var ids = Set<UInt64>()
        var previousBufferLine: UInt32?
        for row in rows {
            if !ids.insert(row.rowId).inserted {
                throw ResidentRowStoreError.duplicateRowID(row.rowId)
            }
            if let previousBufferLine, previousBufferLine > row.bufLine {
                throw ResidentRowStoreError.unsortedBufferLine(previous: previousBufferLine, next: row.bufLine)
            }
            previousBufferLine = row.bufLine
        }
    }

    private static func priority(for id: UInt64) -> UInt64 {
        var value = id &+ 0x9E37_79B9_7F4A_7C15
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    private static func merge(_ left: Node?, _ right: Node?) -> Node? {
        guard let left else { return right }
        guard let right else { return left }
        if left.priority >= right.priority {
            return Node(chunk: left.chunk, left: left.left, right: merge(left.right, right))
        }
        return Node(chunk: right.chunk, left: merge(left, right.left), right: right.right)
    }

    private static func splitByChunk(_ node: Node?, count: Int) -> (Node?, Node?) {
        guard let node else { return (nil, nil) }
        let leftCount = node.left?.chunkCount ?? 0
        if count <= leftCount {
            let (left, middle) = splitByChunk(node.left, count: count)
            return (left, Node(chunk: node.chunk, left: middle, right: node.right))
        }
        let (middle, right) = splitByChunk(node.right, count: count - leftCount - 1)
        return (Node(chunk: node.chunk, left: node.left, right: middle), right)
    }

    private static func buildTree(_ chunks: [Chunk]) -> Node? {
        chunks.reduce(nil as Node?) { merge($0, Node(chunk: $1)) }
    }

    private static func replacingRow(_ node: Node?, at index: Int, with row: GUIVisualRow) -> Node? {
        guard let node else { return nil }
        let leftCount = node.left?.rowCount ?? 0
        if index < leftCount {
            return Node(
                chunk: node.chunk,
                left: replacingRow(node.left, at: index, with: row),
                right: node.right
            )
        }
        let localIndex = index - leftCount
        if localIndex < node.chunk.rows.count {
            var rows = node.chunk.rows
            rows[localIndex] = row
            return Node(
                chunk: Chunk(id: node.chunk.id, rows: rows),
                left: node.left,
                right: node.right
            )
        }
        return Node(
            chunk: node.chunk,
            left: node.left,
            right: replacingRow(
                node.right, at: localIndex - node.chunk.rows.count, with: row
            )
        )
    }

    private static func flattenChunks(_ node: Node?) -> [Chunk] {
        guard let node else { return [] }
        return flattenChunks(node.left) + [node.chunk] + flattenChunks(node.right)
    }

    private static func lowerBound(node: Node?, bufferLine: UInt32, base: Int) -> Int? {
        guard let node, node.maxBufferLine >= bufferLine else { return nil }
        if let left = node.left, left.maxBufferLine >= bufferLine {
            return lowerBound(node: left, bufferLine: bufferLine, base: base)
        }
        let chunkBase = base + (node.left?.rowCount ?? 0)
        if node.chunk.maxBufferLine >= bufferLine {
            var low = 0
            var high = node.chunk.rows.count
            while low < high {
                let middle = (low + high) / 2
                if node.chunk.rows[middle].bufLine < bufferLine { low = middle + 1 } else { high = middle }
            }
            if low < node.chunk.rows.count { return chunkBase + low }
        }
        return lowerBound(
            node: node.right,
            bufferLine: bufferLine,
            base: chunkBase + node.chunk.rows.count
        )
    }

    private static func collect(_ node: Node?, nodeStart: Int, range: Range<Int>,
                                rows: inout [GUIVisualRow], touched: inout Set<UInt64>) {
        guard let node else { return }
        let leftCount = node.left?.rowCount ?? 0
        let chunkStart = nodeStart + leftCount
        let chunkEnd = chunkStart + node.chunk.rows.count
        if range.lowerBound < chunkStart {
            collect(node.left, nodeStart: nodeStart, range: range, rows: &rows, touched: &touched)
        }
        let overlapStart = max(range.lowerBound, chunkStart)
        let overlapEnd = min(range.upperBound, chunkEnd)
        if overlapStart < overlapEnd {
            touched.insert(node.chunk.id)
            rows.append(contentsOf: node.chunk.rows[(overlapStart - chunkStart)..<(overlapEnd - chunkStart)])
        }
        if range.upperBound > chunkEnd {
            collect(node.right, nodeStart: chunkEnd, range: range, rows: &rows, touched: &touched)
        }
    }
}
