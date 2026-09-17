/// Kind of workspace represented by a workspace summary.
public enum WorkspaceKind: Equatable, Sendable {
    case manual
    case agent
    case unknown(rawValue: UInt8)

    /// Decodes a workspace kind without discarding future values.
    public init(rawValue: UInt8) {
        switch rawValue {
        case 0: self = .manual
        case 1: self = .agent
        default: self = .unknown(rawValue: rawValue)
        }
    }

    /// The original protocol byte.
    public var rawValue: UInt8 {
        switch self {
        case .manual: 0
        case .agent: 1
        case .unknown(let rawValue): rawValue
        }
    }
}

/// Active presentation mode of the workspace surface.
public enum WorkspaceViewMode: Equatable, Sendable {
    case editor
    case agent
    case fileTree
    case other
    case unknown(rawValue: UInt8)

    /// Decodes a workspace mode without discarding future values.
    public init(rawValue: UInt8) {
        switch rawValue {
        case 0: self = .editor
        case 1: self = .agent
        case 2: self = .fileTree
        case 3: self = .other
        default: self = .unknown(rawValue: rawValue)
        }
    }

    /// The original protocol byte.
    public var rawValue: UInt8 {
        switch self {
        case .editor: 0
        case .agent: 1
        case .fileTree: 2
        case .other: 3
        case .unknown(let rawValue): rawValue
        }
    }
}

/// Flags that apply to the complete workspace payload.
public struct WorkspaceFlags: OptionSet, Sendable {
    public let rawValue: UInt8
    /// Creates flags while retaining all unknown bits.
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let hasAttention = WorkspaceFlags(rawValue: 0x01)
    public static let knownMask: WorkspaceFlags = [.hasAttention]
    /// Bits not understood by this frontend version.
    public var unknownBits: UInt8 { rawValue & ~Self.knownMask.rawValue }
}

/// Flags attached to one workspace summary.
public struct WorkspaceEntryFlags: OptionSet, Sendable {
    public let rawValue: UInt16
    /// Creates flags while retaining all unknown bits.
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let attention = WorkspaceEntryFlags(rawValue: 0x0001)
    public static let closeable = WorkspaceEntryFlags(rawValue: 0x0002)
    public static let knownMask: WorkspaceEntryFlags = [.attention, .closeable]
    /// Bits not understood by this frontend version.
    public var unknownBits: UInt16 { rawValue & ~Self.knownMask.rawValue }
}

/// Kind of tab in a canonical workspace payload.
public enum WorkspaceTabKind: Equatable, Sendable {
    case file
    case agent
    case unknown(rawValue: UInt8)

    /// Decodes a workspace tab kind without discarding future values.
    public init(rawValue: UInt8) {
        switch rawValue {
        case 0: self = .file
        case 1: self = .agent
        default: self = .unknown(rawValue: rawValue)
        }
    }

    /// The original protocol byte.
    public var rawValue: UInt8 {
        switch self {
        case .file: 0
        case .agent: 1
        case .unknown(let rawValue): rawValue
        }
    }
}

/// Flags attached to one canonical workspace tab.
public struct WorkspaceTabFlags: OptionSet, Sendable {
    public let rawValue: UInt16
    /// Creates flags while retaining all unknown bits.
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let dirty = WorkspaceTabFlags(rawValue: 0x0001)
    public static let attention = WorkspaceTabFlags(rawValue: 0x0002)
    public static let draft = WorkspaceTabFlags(rawValue: 0x0004)
    public static let draftElsewhere = WorkspaceTabFlags(rawValue: 0x0008)
    public static let conflict = WorkspaceTabFlags(rawValue: 0x0010)
    public static let pinned = WorkspaceTabFlags(rawValue: 0x0020)
    public static let ephemeral = WorkspaceTabFlags(rawValue: 0x0040)
    public static let knownMask: WorkspaceTabFlags = [
        .dirty,
        .attention,
        .draft,
        .draftElsewhere,
        .conflict,
        .pinned,
        .ephemeral
    ]
    /// Bits not understood by this frontend version.
    public var unknownBits: UInt16 { rawValue & ~Self.knownMask.rawValue }
}
