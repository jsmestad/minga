/// Severity of one structured message entry.
public enum MessageLevel: Equatable, Hashable, Sendable {
    case debug
    case info
    case warning
    case error
    case unknown(rawValue: UInt8)

    /// Decodes a message level without discarding future values.
    public init(rawValue: UInt8) {
        switch rawValue {
        case 0: self = .debug
        case 1: self = .info
        case 2: self = .warning
        case 3: self = .error
        default: self = .unknown(rawValue: rawValue)
        }
    }

    /// The original protocol byte.
    public var rawValue: UInt8 {
        switch self {
        case .debug: 0
        case .info: 1
        case .warning: 2
        case .error: 3
        case .unknown(let rawValue): rawValue
        }
    }
}

/// Subsystem that emitted one structured message entry.
public enum MessageSubsystem: Equatable, Hashable, Sendable {
    case editor
    case lsp
    case parser
    case git
    case render
    case agent
    case zig
    case gui
    case unknown(rawValue: UInt8)

    /// Decodes a message subsystem without discarding future values.
    public init(rawValue: UInt8) {
        switch rawValue {
        case 0: self = .editor
        case 1: self = .lsp
        case 2: self = .parser
        case 3: self = .git
        case 4: self = .render
        case 5: self = .agent
        case 6: self = .zig
        case 7: self = .gui
        default: self = .unknown(rawValue: rawValue)
        }
    }

    /// The original protocol byte.
    public var rawValue: UInt8 {
        switch self {
        case .editor: 0
        case .lsp: 1
        case .parser: 2
        case .git: 3
        case .render: 4
        case .agent: 5
        case .zig: 6
        case .gui: 7
        case .unknown(let rawValue): rawValue
        }
    }
}
