/// Availability of the chat surface, independent of the current turn.
public enum AgentChatLifecycle: Equatable, Sendable {
    case conversation
    case starting
    case failed(String)
    case unavailable
}

/// Semantic agent activity decoded from status bytes shared by agent chrome.
public enum AgentStatus: Equatable, Sendable {
    case idle
    case thinking
    case executingTool
    case error
    case planning
    case approvalWaiting
    case unknown(rawValue: UInt8)

    /// Decodes an agent status byte without discarding future values.
    public init(rawValue: UInt8) {
        switch rawValue {
        case 0: self = .idle
        case 1: self = .thinking
        case 2: self = .executingTool
        case 3: self = .error
        case 4: self = .planning
        case 5: self = .approvalWaiting
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
        case .approvalWaiting: 5
        case .unknown(let rawValue): rawValue
        }
    }

    /// Whether execution should animate (approval waiting is deliberately static).
    public var isWorking: Bool {
        switch self {
        case .thinking, .executingTool: true
        case .idle, .error, .planning, .approvalWaiting, .unknown: false
        }
    }

    /// Whether the current turn owns Stop and prevents another submission.
    public var hasActiveTurn: Bool {
        switch self {
        case .thinking, .executingTool, .approvalWaiting: true
        case .idle, .error, .planning, .unknown: false
        }
    }
}

/// Committed semantic tool outcome; approval expiry is a view projection, not an execution outcome.
public enum ToolCallStatus: Equatable, Sendable {
    case running
    case complete
    case error
    case denied
    case cancelled
    case approvalExpired
    case unknown(rawValue: UInt8)

    /// Decodes the shared tool status byte, preserving future values.
    public init(rawValue: UInt8) {
        switch rawValue {
        case 0: self = .running
        case 1: self = .complete
        case 2: self = .error
        case 3: self = .denied
        case 4: self = .cancelled
        case 5: self = .approvalExpired
        default: self = .unknown(rawValue: rawValue)
        }
    }

    /// The original protocol byte.
    public var rawValue: UInt8 {
        switch self {
        case .running: 0
        case .complete: 1
        case .error: 2
        case .denied: 3
        case .cancelled: 4
        case .approvalExpired: 5
        case .unknown(let rawValue): rawValue
        }
    }
}
