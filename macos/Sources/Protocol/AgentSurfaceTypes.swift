/// Generic agent surface data types decoded from the BEAM protocol.
///
/// These are core protocol/view model types used by shared agent context chrome and change summaries.

/// Agent status badge, decoded from protocol status bytes.
enum CardStatus: UInt8, Equatable, Sendable {
    case idle = 0
    case working = 1
    case iterating = 2
    case needsYou = 3
    case done = 4
    case errored = 5

    /// Human-readable label for the status badge.
    var label: String {
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
    var color: (r: Double, g: Double, b: Double) {
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

/// A single file entry in the change summary with its diff stats.
struct ChangeSummaryEntry: Identifiable, Equatable, Sendable {
    let id: Int
    let path: String
    let action: FileAction
    let linesAdded: UInt32
    let linesRemoved: UInt32

    /// File action type: modified, added, deleted, or renamed.
    enum FileAction: UInt8, Equatable, Sendable {
        case modified = 0
        case added = 1
        case deleted = 2
        case renamed = 3

        /// Single-letter status indicator.
        var indicator: String {
            switch self {
            case .modified: "M"
            case .added: "A"
            case .deleted: "D"
            case .renamed: "R"
            }
        }

        /// Color for the status indicator.
        var color: (r: Double, g: Double, b: Double) {
            switch self {
            case .modified: (0.38, 0.69, 0.93)
            case .added: (0.2, 0.8, 0.4)
            case .deleted: (1.0, 0.3, 0.3)
            case .renamed: (1.0, 0.75, 0.2)
            }
        }
    }
}
