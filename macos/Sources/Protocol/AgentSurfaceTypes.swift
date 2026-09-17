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

    /// Human-readable label for the status badge.
    public var label: String {
        switch self {
        case .idle: "Idle"
        case .working: "Working"
        case .iterating: "Iterating"
        case .needsYou: "Needs you"
        case .done: "Done"
        case .errored: "Errored"
        case .unknown: "Unknown"
        }
    }

    /// Badge color as RGB tuple.
    public var color: (r: Double, g: Double, b: Double) {
        switch self {
        case .idle: (0.5, 0.5, 0.5)
        case .working: (0.2, 0.8, 0.4)
        case .iterating: (0.2, 0.7, 0.3)
        case .needsYou: (1.0, 0.75, 0.2)
        case .done: (0.3, 0.6, 1.0)
        case .errored: (1.0, 0.3, 0.3)
        case .unknown: (0.5, 0.5, 0.5)
        }
    }
}
