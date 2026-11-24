/// Availability of the chat surface, independent of the current turn.
/// Every non-conversation lifecycle carries the BEAM's notice copy; this frontend authors none of it.
public enum AgentChatLifecycle: Equatable, Sendable {
    case conversation
    case starting(notice: AgentLifecycleNotice)
    /// A failed start: one plain sentence about the cause and the one action that can fix it, if any.
    case failed(reason: String, remedy: AgentStartRemedy?, notice: AgentLifecycleNotice)
    case unavailable(notice: AgentLifecycleNotice)

    /// The notice shown instead of a live conversation, or nil during a conversation.
    public var notice: AgentLifecycleNotice? {
        switch self {
        case .conversation: nil
        case .starting(let notice), .failed(_, _, let notice), .unavailable(let notice): notice
        }
    }
}

/// The BEAM-authored copy of a non-conversation chat notice: what happened to the tab, and the draft note shown under it.
/// An empty note means no note line; the BEAM sends one only when the composer is visible.
public struct AgentLifecycleNotice: Equatable, Sendable {
    public let headline: String
    public let note: String

    public init(headline: String, note: String) {
        self.headline = headline
        self.note = note
    }
}

/// The one action a failed Agent start offers. The label and key hint come from the BEAM; the frontend never authors remedy copy.
public struct AgentStartRemedy: Equatable, Sendable {
    /// What the action does, echoed back to the BEAM when activated.
    public enum Kind: UInt8, Equatable, Sendable {
        case retry = 1
        case setUpProvider = 2
    }

    public let kind: Kind
    public let label: String
    public let keyHint: String

    public init(kind: Kind, label: String, keyHint: String) {
        self.kind = kind
        self.label = label
        self.keyHint = keyHint
    }
}

/// Semantic agent activity decoded from status bytes shared by agent chrome.
public enum AgentStatus: Equatable, Sendable {
    case idle
    case thinking
    case executingTool
    case error
    case planning
    case approvalWaiting
    /// A failed start waits for the user's action. Not an error and not an active turn.
    case needsYou
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
        case 6: self = .needsYou
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
        case .needsYou: 6
        case .unknown(let rawValue): rawValue
        }
    }

    /// The design-token state this status speaks as, from the table in docs/design_tokens.toml, or nil when it shows none.
    /// Every surface that shows an Agent status names it through this, so the modeline, the workspace pill, the chat header and the activity card agree.
    public var spineState: SpineState? { SpineState(agentStatus: rawValue) }

    /// The word every surface shows for this status: its state's word, or "Idle" when Minga shows no state.
    public var label: String { spineState?.word ?? "Idle" }

    /// Whether execution should animate (approval waiting is deliberately static).
    public var isWorking: Bool {
        switch self {
        case .thinking, .executingTool: true
        case .idle, .error, .planning, .approvalWaiting, .needsYou, .unknown: false
        }
    }

    /// Whether the current turn owns Stop and prevents another submission.
    public var hasActiveTurn: Bool {
        switch self {
        case .thinking, .executingTool, .approvalWaiting: true
        case .idle, .error, .planning, .needsYou, .unknown: false
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
