/// Data types for The Board protocol decoding.
///
/// These types are shared between the ProtocolDecoder (which constructs
/// them from binary protocol data) and BoardState/BoardView (which
/// consumes them for rendering). Kept in Protocol/ so the headless
/// test harness can compile them without SwiftUI/Observation dependencies.

import Foundation

/// A single card on The Board, decoded from the gui_board opcode.
struct BoardCard: Identifiable, Equatable, Sendable {
    let id: UInt32
    let status: CardStatus
    let isYouCard: Bool
    let isFocused: Bool
    let task: String
    let model: String
    let dispatchTimestamp: UInt32  // Unix seconds when card was created
    let recentFiles: [String]

    /// Formatted elapsed time string computed from dispatch timestamp.
    var elapsedDisplay: String {
        let now = UInt32(Date().timeIntervalSince1970)
        let elapsed = Int(now - dispatchTimestamp)
        if elapsed < 60 { return "\(elapsed)s" }
        if elapsed < 3600 { return "\(elapsed / 60)m" }
        return "\(elapsed / 3600)h \((elapsed % 3600) / 60)m"
    }
}

/// Card status badge, decoded from the status byte in the protocol.
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
        case .idle: (0.5, 0.5, 0.5)       // Gray
        case .working: (0.2, 0.8, 0.4)     // Green (pulsing)
        case .iterating: (0.2, 0.7, 0.3)   // Green (steady)
        case .needsYou: (1.0, 0.75, 0.2)   // Amber
        case .done: (0.3, 0.6, 1.0)        // Blue
        case .errored: (1.0, 0.3, 0.3)     // Red
        }
    }
}
