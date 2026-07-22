/// Generic agent surface data types decoded from the BEAM protocol.
///
/// These are core protocol/view model types used by shared agent context chrome.

/// Agent status badge, decoded from protocol status bytes.
public enum CardStatus: UInt8, Equatable, Sendable {
    case idle = 0
    case working = 1
    case iterating = 2
    case needsYou = 3
    case done = 4
    case errored = 5

    /// Human-readable label for the status badge.
    public var label: String {
        switch self {
        case .idle: "Idle"
        case .working: "Working"
        case .iterating: "Iterating"
        case .needsYou: "Needs you"
        case .done: "Done"
        case .errored: "Errored"
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
        }
    }
}
