/// Board-specific macOS protocol view model types.
///
/// Generic agent context and change-summary types live in the core macOS protocol source. This file stays extension-owned and contains only Board-specific data.

import Foundation

/// A single card on The Board, decoded from the extension-owned Board payload.
struct BoardCard: Identifiable, Equatable, Sendable {
    let id: UInt32
    let status: CardStatus
    let isYouCard: Bool
    let isFocused: Bool
    let task: String
    let model: String
    let dispatchTimestamp: UInt32  // Unix seconds when card was created
    let recentFiles: [String]
    let sparkline: [Float]

    /// Formatted elapsed time string computed from dispatch timestamp.
    var elapsedDisplay: String {
        let now = UInt32(Date().timeIntervalSince1970)
        let elapsed = Int(now - dispatchTimestamp)
        if elapsed < 60 { return "\(elapsed)s" }
        if elapsed < 3600 { return "\(elapsed / 60)m" }
        return "\(elapsed / 3600)h \((elapsed % 3600) / 60)m"
    }
}
