/// Semantic agent activity decoded from status bytes shared by agent chrome.
public enum AgentStatus: Equatable, Sendable {
    case idle
    case thinking
    case executingTool
    case error
    case planning
    case unknown(rawValue: UInt8)

    /// Decodes an agent status byte without discarding future values.
    public init(rawValue: UInt8) {
        switch rawValue {
        case 0: self = .idle
        case 1: self = .thinking
        case 2: self = .executingTool
        case 3: self = .error
        case 4: self = .planning
        default: self = .unknown(rawValue: rawValue)
        }
    }

    /// The original protocol byte.
    public var rawValue: UInt8 {
        switch self {
        case .idle: 0
        case .thinking: 1
        case .executingTool: 2
        case .error: 3
        case .planning: 4
        case .unknown(let rawValue): rawValue
        }
    }

    /// Whether the status represents active agent work.
    public var isWorking: Bool {
        switch self {
        case .thinking, .executingTool: true
        case .idle, .error, .planning, .unknown: false
        }
    }
}
