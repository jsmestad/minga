/// Generic agent surface data types decoded from the BEAM protocol.
///
/// These are core protocol/view model types used by shared agent context chrome.

/// Agent context-card status, decoded from its field-specific protocol byte.
public enum CardStatus: Equatable, Sendable {
    case idle
    case working
    case iterating
    case needsYou
    case done
    case errored
    case unknown(rawValue: UInt8)

    /// Decodes a context-card status without discarding future values.
    public init(rawValue: UInt8) {
        switch rawValue {
        case 0: self = .idle
        case 1: self = .working
        case 2: self = .iterating
        case 3: self = .needsYou
        case 4: self = .done
        case 5: self = .errored
        default: self = .unknown(rawValue: rawValue)
        }
    }

    /// The original protocol byte.
    public var rawValue: UInt8 {
        switch self {
        case .idle: 0
        case .working: 1
        case .iterating: 2
        case .needsYou: 3
        case .done: 4
        case .errored: 5
        case .unknown(let rawValue): rawValue
        }
    }

    /// The design token state this status shows, or nil when it shows none.
    public var spineState: SpineState? {
        switch self {
        case .working, .iterating: .working
        case .needsYou: .needsYou
        case .done: .done
        case .errored: .failed
        case .idle, .unknown: nil
        }
    }

    /// The colour role the status badge is drawn in. Idle and unknown statuses use the waiting role.
    public var role: ColorRole {
        spineState?.role ?? .waiting
    }

    /// Human-readable label for the status badge. States use their design token word; iterating says what the working state is doing.
    public var label: String {
        switch self {
        case .idle: "Idle"
        case .iterating: "Iterating"
        case .unknown: "Unknown"
        case .working, .needsYou, .done, .errored: spineState?.word ?? "Unknown"
        }
    }
}
