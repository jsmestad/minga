/// Kind of content shown by the active editor surface.
public enum EditorContentKind: Equatable, Sendable {
    case buffer
    case agent
    case unknown(rawValue: UInt8)

    /// Decodes a content-kind byte without discarding future values.
    public init(rawValue: UInt8) {
        switch rawValue {
        case 0: self = .buffer
        case 1: self = .agent
        default: self = .unknown(rawValue: rawValue)
        }
    }

    /// The original protocol byte.
    public var rawValue: UInt8 {
        switch self {
        case .buffer: 0
        case .agent: 1
        case .unknown(let rawValue): rawValue
        }
    }
}

/// Modal state encoded in the status-bar identity section.
public enum EditorMode: Equatable, Sendable {
    case normal
    case insert
    case visual
    case command
    case operatorPending
    case search
    case replace
    case unknown(rawValue: UInt8)

    /// Decodes an editor-mode byte without discarding future values.
    public init(rawValue: UInt8) {
        switch rawValue {
        case 0: self = .normal
        case 1: self = .insert
        case 2: self = .visual
        case 3: self = .command
        case 4: self = .operatorPending
        case 5: self = .search
        case 6: self = .replace
        default: self = .unknown(rawValue: rawValue)
        }
    }

    /// The original protocol byte.
    public var rawValue: UInt8 {
        switch self {
        case .normal: 0
        case .insert: 1
        case .visual: 2
        case .command: 3
        case .operatorPending: 4
        case .search: 5
        case .replace: 6
        case .unknown(let rawValue): rawValue
        }
    }

    /// The label every mode indicator shows, so the status bar and the Agent composer never disagree.
    public var displayName: String {
        switch self {
        case .normal: "NORMAL"
        case .insert: "INSERT"
        case .visual: "VISUAL"
        case .command: "COMMAND"
        case .operatorPending: "O-PENDING"
        case .search: "SEARCH"
        case .replace: "REPLACE"
        case .unknown: "NORMAL"
        }
    }

    /// Whether typed text is inserted at the cursor.
    public var isInsert: Bool { self == .insert }

    /// Whether a text surface in this mode renders a block cursor.
    public var usesBlockCursor: Bool { self != .insert }
}

/// Operation hosted by the minibuffer.
public enum MinibufferMode: Equatable, Sendable {
    case command
    case searchForward
    case searchBackward
    case searchPrompt
    case eval
    case substituteConfirm
    case extensionConfirm
    case describeKey
    case deleteConfirm
    case branchDeleteConfirm
    case textPrompt
    case unknown(rawValue: UInt8)

    private static let knownValues: [MinibufferMode] = [
        .command,
        .searchForward,
        .searchBackward,
        .searchPrompt,
        .eval,
        .substituteConfirm,
        .extensionConfirm,
        .describeKey,
        .deleteConfirm,
        .branchDeleteConfirm,
        .textPrompt
    ]

    /// Decodes a minibuffer mode byte without discarding future values.
    public init(rawValue: UInt8) {
        let index = Int(rawValue)
        if Self.knownValues.indices.contains(index) {
            self = Self.knownValues[index]
        } else {
            self = .unknown(rawValue: rawValue)
        }
    }

    /// The original protocol byte.
    public var rawValue: UInt8 {
        switch self {
        case .command: 0
        case .searchForward: 1
        case .searchBackward: 2
        case .searchPrompt: 3
        case .eval: 4
        case .substituteConfirm: 5
        case .extensionConfirm: 6
        case .describeKey: 7
        case .deleteConfirm: 8
        case .branchDeleteConfirm: 9
        case .textPrompt: 10
        case .unknown(let rawValue): rawValue
        }
    }

    /// Whether the mode accepts text and shows an insertion cursor.
    public var acceptsTextInput: Bool {
        switch self {
        case .command, .searchForward, .searchBackward, .searchPrompt, .eval, .textPrompt: true
        case .substituteConfirm, .extensionConfirm, .describeKey, .deleteConfirm, .branchDeleteConfirm, .unknown: false
        }
    }

    /// Whether the mode presents action keys instead of editable input.
    public var presentsActionKeys: Bool {
        switch self {
        case .substituteConfirm, .extensionConfirm, .describeKey, .deleteConfirm, .branchDeleteConfirm, .unknown: true
        case .command, .searchForward, .searchBackward, .searchPrompt, .eval, .textPrompt: false
        }
    }
}

/// Semantic kind of a completion candidate.
public enum CompletionKind: Equatable, Hashable, Sendable {
    case function
    case method
    case variable
    case field
    case module
    case keyword
    case snippet
    case constant
    case `struct`
    case `enum`
    case unknown(rawValue: UInt8)

    private static let knownValues: [UInt8: CompletionKind] = [
        1: .function,
        2: .method,
        3: .variable,
        4: .field,
        5: .module,
        7: .keyword,
        8: .snippet,
        9: .constant,
        11: .struct,
        12: .enum
    ]

    /// Decodes a completion-kind byte without discarding future values.
    public init(rawValue: UInt8) {
        self = Self.knownValues[rawValue] ?? .unknown(rawValue: rawValue)
    }

    /// The original protocol byte.
    public var rawValue: UInt8 {
        switch self {
        case .function: 1
        case .method: 2
        case .variable: 3
        case .field: 4
        case .module: 5
        case .keyword: 7
        case .snippet: 8
        case .constant: 9
        case .struct: 11
        case .enum: 12
        case .unknown(let rawValue): rawValue
        }
    }
}

/// Status-bar capability flags decoded from the identity section.
public struct StatusBarFlags: OptionSet, Sendable {
    public let rawValue: UInt8

    /// Creates flags while retaining all unknown bits.
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let hasLSP = StatusBarFlags(rawValue: 0x01)
    public static let hasGit = StatusBarFlags(rawValue: 0x02)
    public static let dirty = StatusBarFlags(rawValue: 0x04)
    public static let safeMode = StatusBarFlags(rawValue: 0x08)
    public static let knownMask: StatusBarFlags = [.hasLSP, .hasGit, .dirty, .safeMode]

    /// Bits not understood by this frontend version.
    public var unknownBits: UInt8 { rawValue & ~Self.knownMask.rawValue }
}

/// The BEAM-owned menu projected by the frontend; a nil command payload clears it.
extension Wire {
    public struct ActMenu: Sendable, Equatable {
        public enum Role: UInt8, Sendable {
            case neutral, minga, failure
        }

        public enum Anchor: Sendable, Equatable {
            case centered
            case caret
            case grid(row: UInt16, column: UInt16)
        }

        public struct Row: Sendable, Equatable, Identifiable {
            public let id: UInt16
            public let key: String
            public let label: String
            public let hint: String
            public let detail: String
            public let section: String
            public let destructive: Bool

            public init(id: UInt16, key: String, label: String, hint: String, detail: String, section: String, destructive: Bool) {
                self.id = id
                self.key = key
                self.label = label
                self.hint = hint
                self.detail = detail
                self.section = section
                self.destructive = destructive
            }
        }

        public let offerID: UInt64
        public let role: Role
        public let anchor: Anchor
        public let selectedID: UInt16
        public let title: String
        public let query: String
        public let lead: [Row]
        public let rows: [Row]

        public init(offerID: UInt64, role: Role, anchorRow: UInt16, anchorColumn: UInt16, selectedID: UInt16, title: String, query: String, lead: [Row], rows: [Row]) {
            self.offerID = offerID
            self.role = role
            switch (anchorRow, anchorColumn) {
            case (0xFFFF, 0xFFFF): anchor = .centered
            case (0xFFFE, 0xFFFE): anchor = .caret
            default: anchor = .grid(row: anchorRow, column: anchorColumn)
            }
            self.selectedID = selectedID
            self.title = title
            self.query = query
            self.lead = lead
            self.rows = rows
        }
    }
}

public extension Wire.FocusOwner {
    /// The shared menu uses the editor responder, not a native query field.
    static let actMenuSurface: UInt8 = 16
    var ownsActMenu: Bool { surface == Self.actMenuSurface }
}
