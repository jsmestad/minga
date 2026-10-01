import Foundation

public struct GUIResidentCursor: Sendable, Equatable {
    public let eligible: Bool
    public let row: UInt32
    public let col: UInt16

    public init(eligible: Bool, row: UInt32, col: UInt16) {
        self.eligible = eligible
        self.row = row
        self.col = col
    }
}

public struct GUIResidentCursorline: Sendable, Equatable {
    public let row: UInt32
    public let bg: UInt32

    public init(row: UInt32, bg: UInt32) {
        self.row = row
        self.bg = bg
    }
}

public struct GUIResidentSelection: Sendable, Equatable {
    public let type: GUISelectionType
    public let startRow: UInt32
    public let startCol: UInt16
    public let endRow: UInt32
    public let endCol: UInt16

    public init(type: GUISelectionType, startRow: UInt32, startCol: UInt16, endRow: UInt32, endCol: UInt16) {
        self.type = type
        self.startRow = startRow
        self.startCol = startCol
        self.endRow = endRow
        self.endCol = endCol
    }
}

public struct GUIResidentRowSplice: Sendable, Equatable {
    public let start: UInt32
    public let deleteCount: UInt32
    public let insertCount: UInt32

    public init(start: UInt32, deleteCount: UInt32, insertCount: UInt32) {
        self.start = start
        self.deleteCount = deleteCount
        self.insertCount = insertCount
    }
}

public struct GUIResidentGuideRun: Sendable, Equatable {
    public let start: UInt32
    public let end: UInt32
    public let level: UInt16

    public init(start: UInt32, end: UInt32, level: UInt16) {
        self.start = start
        self.end = end
        self.level = level
    }
}

public struct GUIResidentGuideReplacement: Sendable, Equatable {
    public let start: UInt32
    public let end: UInt32
    public let runs: [GUIResidentGuideRun]

    public init(start: UInt32, end: UInt32, runs: [GUIResidentGuideRun]) {
        self.start = start
        self.end = end
        self.runs = runs
    }
}

public struct GUIResidentDiagnostic: Sendable, Equatable {
    public let startRow: UInt32
    public let startCol: UInt16
    public let endRow: UInt32
    public let endCol: UInt16
    public let severity: GUIDiagnosticSeverity

    public init(startRow: UInt32, startCol: UInt16, endRow: UInt32, endCol: UInt16, severity: GUIDiagnosticSeverity) {
        self.startRow = startRow
        self.startCol = startCol
        self.endRow = endRow
        self.endCol = endCol
        self.severity = severity
    }
}

public struct GUIResidentDiagnosticReplacement: Sendable, Equatable {
    public let start: UInt32
    public let end: UInt32
    public let diagnostics: [GUIResidentDiagnostic]

    public init(start: UInt32, end: UInt32, diagnostics: [GUIResidentDiagnostic]) {
        self.start = start
        self.end = end
        self.diagnostics = diagnostics
    }
}

public struct GUIResidentAnnotation: Sendable, Equatable {
    public let row: UInt32
    public let kind: GUILineAnnotationKind
    public let fg: UInt32
    public let bg: UInt32
    public let text: String

    public init(row: UInt32, kind: GUILineAnnotationKind, fg: UInt32, bg: UInt32, text: String) {
        self.row = row
        self.kind = kind
        self.fg = fg
        self.bg = bg
        self.text = text
    }
}

public struct GUIResidentAnnotationReplacement: Sendable, Equatable {
    public let start: UInt32
    public let end: UInt32
    public let annotations: [GUIResidentAnnotation]

    public init(start: UInt32, end: UInt32, annotations: [GUIResidentAnnotation]) {
        self.start = start
        self.end = end
        self.annotations = annotations
    }
}

public enum GUIResidentAnnotationUpdate: Sendable, Equatable {
    case retain
    case replace([GUIResidentAnnotation])
    case replaceRanges([GUIResidentAnnotationReplacement])
}

public enum GUIResidentDiagnosticUpdate: Sendable, Equatable {
    case retain
    case replace([GUIResidentDiagnostic])
    case replaceRanges([GUIResidentDiagnosticReplacement])
}

public struct GUIResidentSemanticsHeader: Sendable, Equatable {
    public let version: UInt8
    public let mode: UInt8
    public let windowId: UInt16
    public let contentEpoch: UInt32
    public let baseRevision: UInt32
    public let revision: UInt32
    public let targetRowRevision: UInt32
    public let rowCount: UInt32
    public let firstRowId: UInt64
    public let lastRowId: UInt64

    public init(
        version: UInt8, mode: UInt8, windowId: UInt16, contentEpoch: UInt32, baseRevision: UInt32, revision: UInt32,
        targetRowRevision: UInt32, rowCount: UInt32, firstRowId: UInt64, lastRowId: UInt64
    ) {
        self.version = version
        self.mode = mode
        self.windowId = windowId
        self.contentEpoch = contentEpoch
        self.baseRevision = baseRevision
        self.revision = revision
        self.targetRowRevision = targetRowRevision
        self.rowCount = rowCount
        self.firstRowId = firstRowId
        self.lastRowId = lastRowId
    }
}

public struct GUIResidentGuideUpdate: Sendable, Equatable {
    public let tabWidth: UInt8
    public let activeGuideCol: UInt16
    public let guideCols: [UInt16]
    public let rowSplices: [GUIResidentRowSplice]
    public let replacements: [GUIResidentGuideReplacement]

    public init(
        tabWidth: UInt8, activeGuideCol: UInt16, guideCols: [UInt16], rowSplices: [GUIResidentRowSplice],
        replacements: [GUIResidentGuideReplacement]
    ) {
        self.tabWidth = tabWidth
        self.activeGuideCol = activeGuideCol
        self.guideCols = guideCols
        self.rowSplices = rowSplices
        self.replacements = replacements
    }
}

public struct GUIResidentSemanticsUpdate: Sendable, Equatable {
    public let header: GUIResidentSemanticsHeader
    public let cursor: GUIResidentCursor
    public let cursorline: GUIResidentCursorline?
    public let selection: GUIResidentSelection?
    public let guides: GUIResidentGuideUpdate
    public let diagnostics: GUIResidentDiagnosticUpdate
    public let annotations: GUIResidentAnnotationUpdate

    public var version: UInt8 { header.version }
    public var mode: UInt8 { header.mode }
    public var windowId: UInt16 { header.windowId }
    public var contentEpoch: UInt32 { header.contentEpoch }
    public var baseRevision: UInt32 { header.baseRevision }
    public var revision: UInt32 { header.revision }
    public var targetRowRevision: UInt32 { header.targetRowRevision }
    public var rowCount: UInt32 { header.rowCount }
    public var firstRowId: UInt64 { header.firstRowId }
    public var lastRowId: UInt64 { header.lastRowId }
    public var tabWidth: UInt8 { guides.tabWidth }
    public var activeGuideCol: UInt16 { guides.activeGuideCol }
    public var guideCols: [UInt16] { guides.guideCols }
    public var rowSplices: [GUIResidentRowSplice] { guides.rowSplices }
    public var guideReplacements: [GUIResidentGuideReplacement] { guides.replacements }

    public init(
        header: GUIResidentSemanticsHeader, cursor: GUIResidentCursor, cursorline: GUIResidentCursorline?,
        selection: GUIResidentSelection?, guides: GUIResidentGuideUpdate, diagnostics: GUIResidentDiagnosticUpdate,
        annotations: GUIResidentAnnotationUpdate
    ) {
        self.header = header
        self.cursor = cursor
        self.cursorline = cursorline
        self.selection = selection
        self.guides = guides
        self.diagnostics = diagnostics
        self.annotations = annotations
    }

    public init(
        version: UInt8, mode: UInt8, windowId: UInt16, contentEpoch: UInt32, baseRevision: UInt32, revision: UInt32,
        targetRowRevision: UInt32, rowCount: UInt32, firstRowId: UInt64, lastRowId: UInt64, cursor: GUIResidentCursor,
        cursorline: GUIResidentCursorline?, selection: GUIResidentSelection?, tabWidth: UInt8, activeGuideCol: UInt16,
        guideCols: [UInt16], rowSplices: [GUIResidentRowSplice], guideReplacements: [GUIResidentGuideReplacement],
        diagnostics: GUIResidentDiagnosticUpdate, annotations: GUIResidentAnnotationUpdate
    ) {
        self.init(
            header: GUIResidentSemanticsHeader(
                version: version, mode: mode, windowId: windowId, contentEpoch: contentEpoch,
                baseRevision: baseRevision, revision: revision, targetRowRevision: targetRowRevision,
                rowCount: rowCount, firstRowId: firstRowId, lastRowId: lastRowId),
            cursor: cursor,
            cursorline: cursorline,
            selection: selection,
            guides: GUIResidentGuideUpdate(
                tabWidth: tabWidth, activeGuideCol: activeGuideCol, guideCols: guideCols, rowSplices: rowSplices,
                replacements: guideReplacements),
            diagnostics: diagnostics,
            annotations: annotations
        )
    }
}

public enum ResidentSemanticStoreError: Error, Sendable, Equatable {
    case invalid
}

private final class ResidentGuideNode: @unchecked Sendable {
    let start: Int
    let end: Int
    let level: UInt16
    let priority: UInt64
    let left: ResidentGuideNode?
    let right: ResidentGuideNode?
    let lazy: Int
    let covered: Int
    let first: Int
    let last: Int
    init(
        start: Int, end: Int, level: UInt16, left: ResidentGuideNode? = nil, right: ResidentGuideNode? = nil,
        lazy: Int = 0, priority: UInt64? = nil, covered: Int? = nil, first: Int? = nil, last: Int? = nil
    ) {
        self.start = start
        self.end = end
        self.level = level
        self.left = left
        self.right = right
        self.lazy = lazy
        self.priority = priority ?? ResidentSemanticStore.priority(UInt64(start) << 16 | UInt64(level))
        self.covered = covered ?? ((left?.covered ?? 0) + end - start + (right?.covered ?? 0))
        self.first = first ?? (left?.first ?? start)
        self.last = last ?? (right?.last ?? end)
    }
}

private final class ResidentAnnotationNode: @unchecked Sendable {
    let row: Int
    let values: [GUIResidentAnnotation]
    let priority: UInt64
    let left: ResidentAnnotationNode?
    let right: ResidentAnnotationNode?
    let lazy: Int
    init(
        row: Int, values: [GUIResidentAnnotation], left: ResidentAnnotationNode? = nil,
        right: ResidentAnnotationNode? = nil, lazy: Int = 0, priority: UInt64? = nil
    ) {
        self.row = row
        self.values = values
        self.left = left
        self.right = right
        self.lazy = lazy
        self.priority = priority ?? ResidentSemanticStore.priority(UInt64(row))
    }
}

private final class ResidentDiagnosticNode: @unchecked Sendable {
    let start: Int
    let values: [GUIResidentDiagnostic]
    let priority: UInt64
    let left: ResidentDiagnosticNode?
    let right: ResidentDiagnosticNode?
    let lazy: Int
    let maxEnd: Int
    init(
        start: Int, values: [GUIResidentDiagnostic], left: ResidentDiagnosticNode? = nil,
        right: ResidentDiagnosticNode? = nil, lazy: Int = 0, priority: UInt64? = nil, maxEnd: Int? = nil
    ) {
        self.start = start
        self.values = values
        self.left = left
        self.right = right
        self.lazy = lazy
        self.priority = priority ?? ResidentSemanticStore.priority(UInt64(start))
        self.maxEnd =
            maxEnd
            ?? max(values.map { Int($0.endRow) }.max() ?? start, max(left?.maxEnd ?? start, right?.maxEnd ?? start))
    }
}

public struct ResidentSemanticSlice: Sendable {
    public let absoluteRange: Range<Int>
    public let cursor: GUIResidentCursor?
    public let cursorline: GUIResidentCursorline?
    public let selection: GUIResidentSelection?
}

public struct ResidentSemanticStore: Sendable {
    public static let maximumRows = 65_536
    public private(set) var contentEpoch: UInt32 = 0
    public private(set) var revision: UInt32 = 0
    public private(set) var rowRevision: UInt32 = 0
    public private(set) var rowCount: UInt32 = 0
    public private(set) var firstRowId: UInt64 = 0
    public private(set) var lastRowId: UInt64 = 0
    public private(set) var cursor = GUIResidentCursor(eligible: false, row: 0, col: 0)
    public private(set) var cursorline: GUIResidentCursorline?
    public private(set) var selection: GUIResidentSelection?
    public private(set) var tabWidth: UInt8 = 1
    public private(set) var activeGuideCol: UInt16 = 0
    public private(set) var guideCols: [UInt16] = []
    private var guides: ResidentGuideNode?
    private var diagnostics: ResidentDiagnosticNode?
    private var annotations: ResidentAnnotationNode?

    public init() {}

    public func applying(_ update: GUIResidentSemanticsUpdate, content: GUIWindowContent) throws
        -> ResidentSemanticStore
    {
        guard update.version == 1, update.mode == 0 || update.mode == 1,
            content.rowStore.mode == .sequential, update.contentEpoch == content.contentEpoch,
            update.rowCount <= Self.maximumRows, Int(update.rowCount) == content.rowStore.count,
            update.revision > 0
        else { throw ResidentSemanticStoreError.invalid }
        try Self.validateBoundary(update, store: content.rowStore)
        var next: ResidentSemanticStore
        if update.mode == 0 {
            guard update.baseRevision == 0, update.targetRowRevision > 0, update.rowSplices.isEmpty else {
                throw ResidentSemanticStoreError.invalid
            }
            next = ResidentSemanticStore()
        } else {
            guard revision > 0, contentEpoch == update.contentEpoch, revision == update.baseRevision,
                update.revision > update.baseRevision
            else { throw ResidentSemanticStoreError.invalid }
            let expected = rowRevision.addingReportingOverflow(update.rowSplices.isEmpty ? 0 : 1)
            guard !expected.overflow, update.targetRowRevision == expected.partialValue else {
                throw ResidentSemanticStoreError.invalid
            }
            next = self
        }
        try Self.validateScalars(update)
        let baseCount = update.mode == 0 ? Int(update.rowCount) : Int(next.rowCount)
        var count = baseCount
        var offset = 0
        var previousStart: Int?
        var previousEnd = 0
        for splice in update.rowSplices {
            let start = Int(splice.start)
            let deleted = Int(splice.deleteCount)
            let inserted = Int(splice.insertCount)
            guard start <= baseCount, deleted <= baseCount - start, previousStart.map({ start > $0 }) ?? true,
                start >= previousEnd, deleted > 0 || inserted > 0
            else { throw ResidentSemanticStoreError.invalid }
            previousStart = start
            previousEnd = start + deleted
            let actual = start + offset
            guard actual >= 0, actual <= count, deleted <= count - actual else {
                throw ResidentSemanticStoreError.invalid
            }
            next.guides = Self.deleteGuideRange(
                next.guides, actual..<(actual + deleted), shiftingSuffixBy: inserted - deleted)
            next.diagnostics = Self.spliceDiagnostics(
                next.diagnostics, at: actual, deleting: deleted, inserting: inserted)
            next.annotations = Self.deleteAnnotationRange(
                next.annotations, actual..<(actual + deleted), shiftingSuffixBy: inserted - deleted)
            count = count - deleted + inserted
            offset += inserted - deleted
            guard count <= Self.maximumRows else { throw ResidentSemanticStoreError.invalid }
        }
        guard count == Int(update.rowCount) else { throw ResidentSemanticStoreError.invalid }
        next.guides = try Self.replacingGuides(
            next.guides, with: update.guideReplacements, rowCount: Int(update.rowCount), keyframe: update.mode == 0)
        switch update.diagnostics {
        case .retain:
            if update.mode == 0 { throw ResidentSemanticStoreError.invalid }
        case .replace(let replacement):
            try Self.validateDiagnostics(replacement, rowCount: update.rowCount)
            next.diagnostics = Self.buildDiagnostics(replacement)
        case .replaceRanges(let replacements):
            next.diagnostics = try Self.replaceDiagnosticRanges(
                next.diagnostics, replacements: replacements, rowCount: update.rowCount)
        }
        switch update.annotations {
        case .retain:
            if update.mode == 0 { throw ResidentSemanticStoreError.invalid }
        case .replace(let values):
            try Self.validateAnnotations(values, range: 0..<Int(update.rowCount))
            next.annotations = Self.buildAnnotations(values)
        case .replaceRanges(let replacements):
            var priorEnd = 0
            for replacement in replacements {
                let range = Int(replacement.start)..<Int(replacement.end)
                guard range.lowerBound >= priorEnd, range.lowerBound <= range.upperBound,
                    range.upperBound <= Int(update.rowCount)
                else { throw ResidentSemanticStoreError.invalid }
                try Self.validateAnnotations(replacement.annotations, range: range)
                priorEnd = range.upperBound
                let (left, tail) = Self.splitAnnotations(next.annotations, at: range.lowerBound)
                let (_, right) = Self.splitAnnotations(tail, at: range.upperBound)
                next.annotations = Self.mergeAnnotations(
                    Self.mergeAnnotations(left, Self.buildAnnotations(replacement.annotations)), right)
            }
        }
        next.contentEpoch = update.contentEpoch
        next.revision = update.revision
        next.rowRevision = update.targetRowRevision
        next.rowCount = update.rowCount
        next.firstRowId = update.firstRowId
        next.lastRowId = update.lastRowId
        next.cursor = update.cursor
        next.cursorline = update.cursorline
        next.selection = update.selection
        next.tabWidth = update.tabWidth
        next.activeGuideCol = update.activeGuideCol
        next.guideCols = update.guideCols
        return next
    }

    public func slice(_ range: Range<Int>) -> ResidentSemanticSlice {
        let cursorValue = cursor.eligible && range.contains(Int(cursor.row)) ? cursor : nil
        let cursorlineValue = cursorline.flatMap { range.contains(Int($0.row)) ? $0 : nil }
        return ResidentSemanticSlice(
            absoluteRange: range, cursor: cursorValue, cursorline: cursorlineValue, selection: selection)
    }
    public func guideLevel(at row: Int) -> UInt16? { Self.guideLevel(guides, at: row, ancestorShift: 0) }
    public func annotations(at row: Int) -> [GUIResidentAnnotation] {
        Self.annotationValues(annotations, at: row, ancestorShift: 0)
    }
    public func diagnostics(at row: Int) -> [GUIResidentDiagnostic] {
        var result: [GUIResidentDiagnostic] = []
        Self.collectDiagnostics(diagnostics, row: UInt32(row), into: &result)
        return result
    }

    fileprivate static func priority(_ value: UInt64) -> UInt64 {
        var x = value &+ 0x9e37_79b9_7f4a_7c15
        x = (x ^ (x >> 30)) &* 0xbf58_476d_1ce4_e5b9
        x = (x ^ (x >> 27)) &* 0x94d0_49bb_1331_11eb
        return x ^ (x >> 31)
    }
    private static func validateBoundary(_ update: GUIResidentSemanticsUpdate, store: ResidentRowStore) throws {
        if update.rowCount == 0 {
            guard update.firstRowId == 0, update.lastRowId == 0 else { throw ResidentSemanticStoreError.invalid }
            return
        }
        guard let first = store.row(at: 0), let last = store.row(at: store.count - 1), first.rowId != 0,
            first.rowId == update.firstRowId, last.rowId != 0, last.rowId == update.lastRowId
        else { throw ResidentSemanticStoreError.invalid }
    }
    private static func validateScalars(_ update: GUIResidentSemanticsUpdate) throws {
        guard update.tabWidth > 0, zip(update.guideCols, update.guideCols.dropFirst()).allSatisfy({ $0.0 < $0.1 })
        else { throw ResidentSemanticStoreError.invalid }
        if update.rowCount == 0 {
            guard !update.cursor.eligible, update.cursorline == nil, update.selection == nil else {
                throw ResidentSemanticStoreError.invalid
            }
            return
        }
        guard update.cursor.row < update.rowCount else { throw ResidentSemanticStoreError.invalid }
        if let line = update.cursorline {
            guard line.row < update.rowCount else { throw ResidentSemanticStoreError.invalid }
        }
        if let selection = update.selection {
            guard selection.startRow < update.rowCount, selection.endRow < update.rowCount,
                selection.startRow <= selection.endRow
            else { throw ResidentSemanticStoreError.invalid }
        }
    }
    private static func validateDiagnostics(_ values: [GUIResidentDiagnostic], rowCount: UInt32) throws {
        for value in values {
            guard value.startRow < rowCount, value.endRow < rowCount, value.startRow <= value.endRow,
                value.startRow != value.endRow || value.startCol <= value.endCol
            else { throw ResidentSemanticStoreError.invalid }
        }
    }
    private static func validateAnnotations(_ values: [GUIResidentAnnotation], range: Range<Int>) throws {
        for value in values { guard range.contains(Int(value.row)) else { throw ResidentSemanticStoreError.invalid } }
    }

    private static func shiftedGuide(_ node: ResidentGuideNode?, by delta: Int) -> ResidentGuideNode? {
        guard let node else { return nil }
        guard delta != 0 else { return node }
        return ResidentGuideNode(
            start: node.start + delta, end: node.end + delta, level: node.level, left: node.left, right: node.right,
            lazy: node.lazy + delta, priority: node.priority, covered: node.covered, first: node.first + delta,
            last: node.last + delta)
    }
    private static func pushedGuide(_ node: ResidentGuideNode) -> ResidentGuideNode {
        guard node.lazy != 0 else { return node }
        return ResidentGuideNode(
            start: node.start, end: node.end, level: node.level, left: shiftedGuide(node.left, by: node.lazy),
            right: shiftedGuide(node.right, by: node.lazy), priority: node.priority)
    }
    private static func mergeGuides(_ left: ResidentGuideNode?, _ right: ResidentGuideNode?) -> ResidentGuideNode? {
        guard let left else { return right }
        guard let right else { return left }
        let l = pushedGuide(left)
        let r = pushedGuide(right)
        if l.priority >= r.priority {
            return ResidentGuideNode(
                start: l.start, end: l.end, level: l.level, left: l.left, right: mergeGuides(l.right, r),
                priority: l.priority)
        }
        return ResidentGuideNode(
            start: r.start, end: r.end, level: r.level, left: mergeGuides(l, r.left), right: r.right,
            priority: r.priority)
    }
    private static func splitGuides(_ node: ResidentGuideNode?, at rank: Int) -> (
        ResidentGuideNode?, ResidentGuideNode?
    ) {
        guard let original = node else { return (nil, nil) }
        let node = pushedGuide(original)
        if rank <= node.start {
            let (left, remainder) = splitGuides(node.left, at: rank)
            return (
                left,
                ResidentGuideNode(
                    start: node.start, end: node.end, level: node.level, left: remainder, right: node.right,
                    priority: node.priority)
            )
        }
        if rank >= node.end {
            let (prefix, right) = splitGuides(node.right, at: rank)
            return (
                ResidentGuideNode(
                    start: node.start, end: node.end, level: node.level, left: node.left, right: prefix,
                    priority: node.priority), right
            )
        }
        let left = mergeGuides(node.left, ResidentGuideNode(start: node.start, end: rank, level: node.level))
        let right = mergeGuides(ResidentGuideNode(start: rank, end: node.end, level: node.level), node.right)
        return (left, right)
    }
    private static func deleteGuideRange(_ root: ResidentGuideNode?, _ range: Range<Int>, shiftingSuffixBy delta: Int)
        -> ResidentGuideNode?
    {
        let (left, tail) = splitGuides(root, at: range.lowerBound)
        let (_, right) = splitGuides(tail, at: range.upperBound)
        return mergeGuides(left, shiftedGuide(right, by: delta))
    }
    private static func buildGuides(_ runs: [GUIResidentGuideRun]) -> ResidentGuideNode? {
        runs.reduce(nil) { mergeGuides($0, ResidentGuideNode(start: Int($1.start), end: Int($1.end), level: $1.level)) }
    }
    private static func replacingGuides(
        _ original: ResidentGuideNode?, with replacements: [GUIResidentGuideReplacement], rowCount: Int, keyframe: Bool
    ) throws -> ResidentGuideNode? {
        if keyframe {
            guard replacements.count == 1, replacements[0].start == 0, replacements[0].end == UInt32(rowCount) else {
                throw ResidentSemanticStoreError.invalid
            }
        }
        var root = original
        var previousEnd = 0
        for replacement in replacements {
            let range = Int(replacement.start)..<Int(replacement.end)
            guard range.lowerBound >= previousEnd, range.lowerBound <= range.upperBound, range.upperBound <= rowCount
            else { throw ResidentSemanticStoreError.invalid }
            var cursor = range.lowerBound
            for run in replacement.runs {
                guard Int(run.start) == cursor, run.end > run.start, Int(run.end) <= range.upperBound else {
                    throw ResidentSemanticStoreError.invalid
                }
                cursor = Int(run.end)
            }
            guard cursor == range.upperBound else { throw ResidentSemanticStoreError.invalid }
            previousEnd = range.upperBound
            let (left, tail) = splitGuides(root, at: range.lowerBound)
            let (_, right) = splitGuides(tail, at: range.upperBound)
            root = mergeGuides(mergeGuides(left, buildGuides(replacement.runs)), right)
        }
        if rowCount == 0 {
            guard root == nil else { throw ResidentSemanticStoreError.invalid }
        } else {
            guard let root, root.first == 0, root.last == rowCount, root.covered == rowCount else {
                throw ResidentSemanticStoreError.invalid
            }
        }
        return root
    }
    private static func guideLevel(_ node: ResidentGuideNode?, at row: Int, ancestorShift: Int) -> UInt16? {
        guard let node else { return nil }
        let start = node.start + ancestorShift
        let end = node.end + ancestorShift
        if row < start { return guideLevel(node.left, at: row, ancestorShift: ancestorShift + node.lazy) }
        if row >= end { return guideLevel(node.right, at: row, ancestorShift: ancestorShift + node.lazy) }
        return node.level
    }

    private static func shiftedAnnotation(_ node: ResidentAnnotationNode?, by delta: Int) -> ResidentAnnotationNode? {
        guard let node else { return nil }
        guard delta != 0 else { return node }
        return ResidentAnnotationNode(
            row: node.row + delta, values: node.values, left: node.left, right: node.right, lazy: node.lazy + delta,
            priority: node.priority)
    }
    private static func pushedAnnotation(_ node: ResidentAnnotationNode) -> ResidentAnnotationNode {
        guard node.lazy != 0 else { return node }
        return ResidentAnnotationNode(
            row: node.row, values: node.values, left: shiftedAnnotation(node.left, by: node.lazy),
            right: shiftedAnnotation(node.right, by: node.lazy), priority: node.priority)
    }
    private static func mergeAnnotations(_ left: ResidentAnnotationNode?, _ right: ResidentAnnotationNode?)
        -> ResidentAnnotationNode?
    {
        guard let left else { return right }
        guard let right else { return left }
        let l = pushedAnnotation(left)
        let r = pushedAnnotation(right)
        if l.priority >= r.priority {
            return ResidentAnnotationNode(
                row: l.row, values: l.values, left: l.left, right: mergeAnnotations(l.right, r), priority: l.priority)
        }
        return ResidentAnnotationNode(
            row: r.row, values: r.values, left: mergeAnnotations(l, r.left), right: r.right, priority: r.priority)
    }
    private static func splitAnnotations(_ node: ResidentAnnotationNode?, at row: Int) -> (
        ResidentAnnotationNode?, ResidentAnnotationNode?
    ) {
        guard let original = node else { return (nil, nil) }
        let node = pushedAnnotation(original)
        if row <= node.row {
            let (left, remainder) = splitAnnotations(node.left, at: row)
            return (
                left,
                ResidentAnnotationNode(
                    row: node.row, values: node.values, left: remainder, right: node.right, priority: node.priority)
            )
        }
        let (prefix, right) = splitAnnotations(node.right, at: row)
        return (
            ResidentAnnotationNode(
                row: node.row, values: node.values, left: node.left, right: prefix, priority: node.priority), right
        )
    }
    private static func deleteAnnotationRange(
        _ root: ResidentAnnotationNode?, _ range: Range<Int>, shiftingSuffixBy delta: Int
    ) -> ResidentAnnotationNode? {
        let (left, tail) = splitAnnotations(root, at: range.lowerBound)
        let (_, right) = splitAnnotations(tail, at: range.upperBound)
        return mergeAnnotations(left, shiftedAnnotation(right, by: delta))
    }
    private static func buildAnnotations(_ values: [GUIResidentAnnotation]) -> ResidentAnnotationNode? {
        let groups = Dictionary(grouping: values, by: { Int($0.row) })
        return groups.keys.sorted().reduce(nil) {
            mergeAnnotations($0, ResidentAnnotationNode(row: $1, values: groups[$1] ?? []))
        }
    }
    private static func annotationValues(_ node: ResidentAnnotationNode?, at row: Int, ancestorShift: Int)
        -> [GUIResidentAnnotation]
    {
        guard let node else { return [] }
        let effective = node.row + ancestorShift
        if row < effective { return annotationValues(node.left, at: row, ancestorShift: ancestorShift + node.lazy) }
        if row > effective { return annotationValues(node.right, at: row, ancestorShift: ancestorShift + node.lazy) }
        return node.values.map {
            GUIResidentAnnotation(row: UInt32(row), kind: $0.kind, fg: $0.fg, bg: $0.bg, text: $0.text)
        }
    }

    private static func shiftedDiagnostic(_ node: ResidentDiagnosticNode?, by delta: Int) -> ResidentDiagnosticNode? {
        guard let node else { return nil }
        guard delta != 0 else { return node }
        let values = node.values.map {
            GUIResidentDiagnostic(
                startRow: UInt32(Int($0.startRow) + delta), startCol: $0.startCol,
                endRow: UInt32(Int($0.endRow) + delta), endCol: $0.endCol, severity: $0.severity)
        }
        return ResidentDiagnosticNode(
            start: node.start + delta, values: values, left: node.left, right: node.right, lazy: node.lazy + delta,
            priority: node.priority, maxEnd: node.maxEnd + delta)
    }
    private static func pushedDiagnostic(_ node: ResidentDiagnosticNode) -> ResidentDiagnosticNode {
        guard node.lazy != 0 else { return node }
        return ResidentDiagnosticNode(
            start: node.start, values: node.values, left: shiftedDiagnostic(node.left, by: node.lazy),
            right: shiftedDiagnostic(node.right, by: node.lazy), priority: node.priority)
    }
    private static func mergeDiagnostics(_ left: ResidentDiagnosticNode?, _ right: ResidentDiagnosticNode?)
        -> ResidentDiagnosticNode?
    {
        guard let left else { return right }
        guard let right else { return left }
        let l = pushedDiagnostic(left)
        let r = pushedDiagnostic(right)
        if l.priority >= r.priority {
            return ResidentDiagnosticNode(
                start: l.start, values: l.values, left: l.left, right: mergeDiagnostics(l.right, r),
                priority: l.priority)
        }
        return ResidentDiagnosticNode(
            start: r.start, values: r.values, left: mergeDiagnostics(l, r.left), right: r.right, priority: r.priority)
    }
    private static func splitDiagnostics(_ node: ResidentDiagnosticNode?, at row: Int) -> (
        ResidentDiagnosticNode?, ResidentDiagnosticNode?
    ) {
        guard let original = node else { return (nil, nil) }
        let node = pushedDiagnostic(original)
        if row <= node.start {
            let (left, remainder) = splitDiagnostics(node.left, at: row)
            return (
                left,
                ResidentDiagnosticNode(
                    start: node.start, values: node.values, left: remainder, right: node.right, priority: node.priority)
            )
        }
        let (prefix, right) = splitDiagnostics(node.right, at: row)
        return (
            ResidentDiagnosticNode(
                start: node.start, values: node.values, left: node.left, right: prefix, priority: node.priority), right
        )
    }
    private static func diagnosticValues(_ node: ResidentDiagnosticNode?, at start: Int) -> [GUIResidentDiagnostic] {
        guard let original = node else { return [] }
        let node = pushedDiagnostic(original)
        if start < node.start { return diagnosticValues(node.left, at: start) }
        if start > node.start { return diagnosticValues(node.right, at: start) }
        return node.values
    }
    private static func setDiagnostics(_ root: ResidentDiagnosticNode?, at start: Int, values: [GUIResidentDiagnostic])
        -> ResidentDiagnosticNode?
    {
        let (left, tail) = splitDiagnostics(root, at: start)
        let (_, right) = splitDiagnostics(tail, at: start + 1)
        let middle = values.isEmpty ? nil : ResidentDiagnosticNode(start: start, values: values)
        return mergeDiagnostics(mergeDiagnostics(left, middle), right)
    }
    private static func collectCrossingDiagnosticStarts(
        _ node: ResidentDiagnosticNode?, spliceStart: Int, into result: inout [Int]
    ) {
        guard let original = node, original.maxEnd >= spliceStart else { return }
        let node = pushedDiagnostic(original)
        collectCrossingDiagnosticStarts(node.left, spliceStart: spliceStart, into: &result)
        if node.start < spliceStart {
            if node.values.contains(where: { Int($0.endRow) >= spliceStart }) { result.append(node.start) }
            collectCrossingDiagnosticStarts(node.right, spliceStart: spliceStart, into: &result)
        }
    }
    private static func spliceDiagnostics(
        _ original: ResidentDiagnosticNode?, at start: Int, deleting deleted: Int, inserting inserted: Int
    ) -> ResidentDiagnosticNode? {
        var root = original
        let deleteEnd = start + deleted
        let delta = inserted - deleted
        var crossing: [Int] = []
        collectCrossingDiagnosticStarts(root, spliceStart: start, into: &crossing)
        for diagnosticStart in crossing {
            let transformed = diagnosticValues(root, at: diagnosticStart).map { diagnostic -> GUIResidentDiagnostic in
                let end: Int
                if deleted == 0 || Int(diagnostic.endRow) >= deleteEnd {
                    end = Int(diagnostic.endRow) + delta
                } else if inserted > 0 {
                    end = start + inserted - 1
                } else {
                    end = start - 1
                }
                return GUIResidentDiagnostic(
                    startRow: diagnostic.startRow, startCol: diagnostic.startCol, endRow: UInt32(end),
                    endCol: diagnostic.endCol, severity: diagnostic.severity)
            }
            root = setDiagnostics(root, at: diagnosticStart, values: transformed)
        }
        let (left, tail) = splitDiagnostics(root, at: start)
        let (_, right) = splitDiagnostics(tail, at: deleteEnd)
        return mergeDiagnostics(left, shiftedDiagnostic(right, by: delta))
    }
    private static func replaceDiagnosticRanges(
        _ original: ResidentDiagnosticNode?, replacements: [GUIResidentDiagnosticReplacement], rowCount: UInt32
    ) throws -> ResidentDiagnosticNode? {
        var root = original
        var previousEnd = 0
        for (index, replacement) in replacements.enumerated() {
            let range = Int(replacement.start)..<Int(replacement.end)
            guard range.lowerBound <= range.upperBound, range.upperBound <= Int(rowCount),
                index == 0 || range.lowerBound >= previousEnd
            else { throw ResidentSemanticStoreError.invalid }
            try validateDiagnostics(replacement.diagnostics, rowCount: rowCount)
            guard replacement.diagnostics.allSatisfy({ range.contains(Int($0.startRow)) }) else {
                throw ResidentSemanticStoreError.invalid
            }
            previousEnd = range.upperBound
            let (left, tail) = splitDiagnostics(root, at: range.lowerBound)
            let (_, right) = splitDiagnostics(tail, at: range.upperBound)
            root = mergeDiagnostics(mergeDiagnostics(left, buildDiagnostics(replacement.diagnostics)), right)
        }
        return root
    }
    private static func buildDiagnostics(_ values: [GUIResidentDiagnostic]) -> ResidentDiagnosticNode? {
        let groups = Dictionary(grouping: values, by: { Int($0.startRow) })
        return groups.keys.sorted().reduce(nil) {
            mergeDiagnostics($0, ResidentDiagnosticNode(start: $1, values: groups[$1] ?? []))
        }
    }
    private static func collectDiagnostics(
        _ node: ResidentDiagnosticNode?, row: UInt32, into result: inout [GUIResidentDiagnostic]
    ) {
        guard let original = node, original.maxEnd >= Int(row) else { return }
        let node = pushedDiagnostic(original)
        if let left = node.left, left.maxEnd >= Int(row) { collectDiagnostics(left, row: row, into: &result) }
        if node.start <= Int(row) {
            result.append(contentsOf: node.values.filter { $0.endRow >= row })
            collectDiagnostics(node.right, row: row, into: &result)
        }
    }
}

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
    /// Boundary rows inspected while aggregating cached resource weights.
    public var resourceWeightRowsVisited = 0

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
            fullResets: lhs.fullResets + rhs.fullResets,
            resourceWeightRowsVisited: lhs.resourceWeightRowsVisited + rhs.resourceWeightRowsVisited
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
            fullResets: max(lhs.fullResets - rhs.fullResets, 0),
            resourceWeightRowsVisited: max(
                lhs.resourceWeightRowsVisited - rhs.resourceWeightRowsVisited, 0
            )
        )
    }

    private init(rowsVisited: Int, chunksTouched: Int, idsResolved: Int, splices: Int,
                 changedRowsValidated: Int, locatorNodesCopied: Int, fullResets: Int,
                 resourceWeightRowsVisited: Int) {
        self.rowsVisited = rowsVisited
        self.chunksTouched = chunksTouched
        self.idsResolved = idsResolved
        self.splices = splices
        self.changedRowsValidated = changedRowsValidated
        self.locatorNodesCopied = locatorNodesCopied
        self.fullResets = fullResets
        self.resourceWeightRowsVisited = resourceWeightRowsVisited
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
/// Interpretation of `bufLine` metadata stored with resident rows.
public enum ResidentRowStoreMode: Sendable, Equatable {
    /// Rows retain their explicit BEAM-provided buffer-line ordering.
    case windowed
    /// The store is a complete unwrapped document, so row rank is the current buffer line.
    case sequential
}

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
        let resourceWeight: FrameResourceWeight

        init(id: UInt64, rows: [GUIVisualRow]) {
            self.id = id
            self.rows = rows
            minBufferLine = rows.first?.bufLine ?? 0
            maxBufferLine = rows.last?.bufLine ?? 0
            resourceWeight = rows.reduce(into: FrameResourceWeight()) { weight, row in
                weight = weight.addingPrevalidated(ResidentRowStore.weight(of: row))
            }
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
        let resourceWeight: FrameResourceWeight

        init(chunk: Chunk, left: Node? = nil, right: Node? = nil) {
            self.chunk = chunk
            priority = ResidentRowStore.priority(for: chunk.id)
            self.left = left
            self.right = right
            rowCount = (left?.rowCount ?? 0) + chunk.rows.count + (right?.rowCount ?? 0)
            chunkCount = (left?.chunkCount ?? 0) + 1 + (right?.chunkCount ?? 0)
            minBufferLine = left?.minBufferLine ?? chunk.minBufferLine
            maxBufferLine = right?.maxBufferLine ?? chunk.maxBufferLine
            resourceWeight = (left?.resourceWeight ?? FrameResourceWeight())
                .addingPrevalidated(chunk.resourceWeight)
                .addingPrevalidated(right?.resourceWeight ?? FrameResourceWeight())
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
    /// Row-coordinate contract retained across copy-on-write structural updates.
    public private(set) var mode: ResidentRowStoreMode = .windowed

    /// Creates an empty resident row store.
    public init(mode: ResidentRowStoreMode = .windowed) {
        self.mode = mode
    }

    /// Creates a validated store from a complete row snapshot.
    public init(rows: [GUIVisualRow], mode: ResidentRowStoreMode = .windowed) throws {
        self.mode = mode
        try replaceAll(with: rows)
    }

    /// Builds decoded protocol content from a checked row weight. Identity,
    /// ordering, and policy validation all complete before chunks or indexes exist.
    public init(
        decodedRows rows: [GUIVisualRow],
        resourceWeight: FrameResourceWeight,
        mode: ResidentRowStoreMode = .windowed,
        limit: FrameResourceWeight? = nil
    ) throws {
        do {
            try Self.validateRows(rows, validatesBufferLineOrder: mode == .windowed)
            try Self.validate(resourceWeight, limit: limit)
        } catch let error as ResidentRowStoreError {
            throw error
        } catch is FrameResourceError {
            throw ResidentRowStoreError.resourcePolicy
        }
        self.mode = mode
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

    #if DEBUG
    /// Test-only identity seam for proving resident COW storage sharing.
    public func sharesStorage(with other: ResidentRowStore) -> Bool {
        storage === other.storage
    }
    #endif

    /// Replaces the complete sequence and records one explicit full reset.
    public mutating func replaceAll(
        with rows: [GUIVisualRow], limit: FrameResourceWeight? = nil
    ) throws {
        try Self.validateRows(rows, validatesBufferLineOrder: mode == .windowed)
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
        guard let row = rawRow(at: index) else { return nil }
        return projected(row, at: index)
    }

    /// Returns stored row metadata without applying the sequential rank projection.
    private func rawRow(at index: Int) -> GUIVisualRow? {
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
        if mode == .sequential {
            return min(Int(bufferLine), count)
        }
        return Self.lowerBound(node: storage.root, bufferLine: bufferLine, base: 0) ?? count
    }

    /// Visits exactly the requested row range plus O(log chunks) index nodes.
    public func rows(in range: Range<Int>) -> (rows: [GUIVisualRow], counters: ResidentRowStoreCounters) {
        let lower = min(max(range.lowerBound, 0), count)
        let upper = min(max(range.upperBound, lower), count)
        var rows: [GUIVisualRow] = []
        rows.reserveCapacity(upper - lower)
        var touched = Set<UInt64>()
        Self.collect(storage.root, nodeStart: 0, range: lower..<upper, rows: &rows, touched: &touched)
        if mode == .sequential {
            rows = rows.enumerated().map { offset, row in
                projected(row, at: lower + offset)
            }
        }
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
            try Self.validateRows(
                splice.insertedRows, validatesBufferLineOrder: mode == .windowed
            )
            previousStart = splice.startIndex
            previousEnd = splice.startIndex + splice.deleteCount
            computed = computed - splice.deleteCount + splice.insertedRows.count
        }
        guard computed == resultRowCount else {
            throw ResidentRowStoreError.invalidRange(index: computed, removeCount: 0, rowCount: resultRowCount)
        }

        let removedWeight: FrameResourceWeight
        let insertedWeight: FrameResourceWeight
        let resourceWeightRowsVisited: Int
        do {
            var removed = FrameResourceWeight()
            var inserted = FrameResourceWeight()
            var rowsVisited = 0
            for splice in splices {
                let removedRange = try weight(
                    in: splice.startIndex..<(splice.startIndex + splice.deleteCount)
                )
                removed = try removed.adding(removedRange.weight)
                rowsVisited += removedRange.rowsVisited
                inserted = try inserted.adding(try Self.weight(of: splice.insertedRows))
            }
            let resulting = try storage.resourceWeight.subtracting(removed).adding(inserted)
            try Self.validate(resulting, limit: limit)
            removedWeight = removed
            insertedWeight = inserted
            resourceWeightRowsVisited = rowsVisited
        } catch is FrameResourceError {
            throw ResidentRowStoreError.resourcePolicy
        }

        if !splices.isEmpty, let replacements = try inPlaceReplacements(for: splices) {
            var staged = self
            staged.applyInPlaceReplacements(replacements)
            staged.storage.resourceWeight = try staged.storage.resourceWeight
                .subtracting(removedWeight).adding(insertedWeight)
            staged.storage.counters.resourceWeightRowsVisited += resourceWeightRowsVisited
            self = staged
            return
        }

        var staged = self
        staged.storage.counters.resourceWeightRowsVisited += resourceWeightRowsVisited
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
        let resourceWeightRowsVisited: Int
        do {
            let removedRange = try weight(in: index..<(index + removeCount))
            removedResourceWeight = removedRange.weight
            insertedResourceWeight = try Self.weight(of: insertedRows)
            resourceWeightRowsVisited = removedRange.rowsVisited
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
        try Self.validateRows(insertedRows, validatesBufferLineOrder: mode == .windowed)
        if mode == .windowed, let first = insertedRows.first, index > 0, let previous = row(at: index - 1), previous.bufLine > first.bufLine {
            throw ResidentRowStoreError.unsortedBufferLine(previous: previous.bufLine, next: first.bufLine)
        }
        let followingIndex = index + removeCount
        if mode == .windowed, let last = insertedRows.last, followingIndex < count, let following = row(at: followingIndex), last.bufLine > following.bufLine {
            throw ResidentRowStoreError.unsortedBufferLine(previous: last.bufLine, next: following.bufLine)
        }
        if mode == .windowed, insertedRows.isEmpty, index > 0, followingIndex < count,
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
            storage.counters.resourceWeightRowsVisited += resourceWeightRowsVisited
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
        storage.counters.resourceWeightRowsVisited += resourceWeightRowsVisited
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
        guard chunks.allSatisfy({
            !$0.rows.isEmpty && $0.rows.count <= Self.chunkCapacity &&
                (try? Self.weight(of: $0.rows)) == $0.resourceWeight
        }) else { return false }
        guard (storage.root?.resourceWeight ?? FrameResourceWeight()) == storage.resourceWeight else {
            return false
        }
        if chunks.count > 2 {
            guard chunks.dropFirst().dropLast().allSatisfy({ $0.rows.count >= Self.minimumChunkOccupancy }) else { return false }
        }
        var ids = Set<UInt64>()
        var previousBufferLine: UInt32?
        for chunk in chunks {
            for (offset, row) in chunk.rows.enumerated() {
                guard (mode == .sequential || previousBufferLine.map({ $0 <= row.bufLine }) ?? true),
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
            guard let oldRow = rawRow(at: splice.startIndex), oldRow.rowId == newRow.rowId,
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

        for replacement in replacements where mode == .windowed && replacement.newRow.bufLine != replacement.oldRow.bufLine {
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

    private func weight(
        in range: Range<Int>
    ) throws -> (weight: FrameResourceWeight, rowsVisited: Int) {
        guard range.lowerBound >= 0, range.upperBound <= count else {
            throw ResidentRowStoreError.invalidRange(
                index: range.lowerBound, removeCount: range.count, rowCount: count
            )
        }
        var rowsVisited = 0
        let result = try Self.weight(
            in: storage.root, nodeStart: 0, range: range, rowsVisited: &rowsVisited
        )
        return (result, rowsVisited)
    }

    private static func weight(
        in node: Node?, nodeStart: Int, range: Range<Int>, rowsVisited: inout Int
    ) throws -> FrameResourceWeight {
        guard let node, !range.isEmpty else { return FrameResourceWeight() }
        let nodeEnd = nodeStart + node.rowCount
        if range.lowerBound <= nodeStart, range.upperBound >= nodeEnd {
            return node.resourceWeight
        }

        let leftCount = node.left?.rowCount ?? 0
        let chunkStart = nodeStart + leftCount
        let chunkEnd = chunkStart + node.chunk.rows.count
        var result = FrameResourceWeight()

        if range.lowerBound < chunkStart {
            result = try result.adding(try weight(
                in: node.left, nodeStart: nodeStart,
                range: range, rowsVisited: &rowsVisited
            ))
        }

        let overlapStart = max(range.lowerBound, chunkStart)
        let overlapEnd = min(range.upperBound, chunkEnd)
        if overlapStart < overlapEnd {
            rowsVisited += overlapEnd - overlapStart
            for row in node.chunk.rows[(overlapStart - chunkStart)..<(overlapEnd - chunkStart)] {
                result = try result.adding(weight(of: row))
            }
        }

        if range.upperBound > chunkEnd {
            result = try result.adding(try weight(
                in: node.right, nodeStart: chunkEnd,
                range: range, rowsVisited: &rowsVisited
            ))
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

    static func validateRows(
        _ rows: [GUIVisualRow], validatesBufferLineOrder: Bool = true
    ) throws {
        var ids = Set<UInt64>()
        var previousBufferLine: UInt32?
        for row in rows {
            if !ids.insert(row.rowId).inserted {
                throw ResidentRowStoreError.duplicateRowID(row.rowId)
            }
            if validatesBufferLineOrder, let previousBufferLine, previousBufferLine > row.bufLine {
                throw ResidentRowStoreError.unsortedBufferLine(previous: previousBufferLine, next: row.bufLine)
            }
            previousBufferLine = row.bufLine
        }
    }

    private func projected(_ row: GUIVisualRow, at index: Int) -> GUIVisualRow {
        guard mode == .sequential, row.bufLine != UInt32(index) else { return row }
        return GUIVisualRow(
            rowType: row.rowType, rowId: row.rowId, bufLine: UInt32(index),
            contentHash: row.contentHash, text: row.text, spans: row.spans
        )
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
