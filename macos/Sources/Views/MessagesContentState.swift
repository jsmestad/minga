/// Observable state for the Messages tab content.
///
/// Accumulates structured log entries from the BEAM and tracks scroll
/// position for auto-scroll behavior.

import SwiftUI

/// A rendered message entry for display in the Messages tab.
///
/// SwiftUI identity is `id`, a `(streamGeneration, seq)` composite, NOT the raw
/// backend sequence number (`seq`). The BEAM `MessageStore` restarts its
/// sequence at 1 whenever the backend restarts (or resends), so using `seq`
/// alone as `ForEach`/scroll identity produced duplicate IDs across restarts
/// (issue #2353). `MessagesContentState` bumps the generation when it sees a
/// sequence go backwards, keeping every row's identity unique.
struct MessageEntry: Identifiable, Equatable {
    /// Restart-safe composite identity: `(UInt64(generation) << 32) | seq`.
    /// Static fixtures (previews/tests) may pass a small raw sequence directly;
    /// that is just generation 0, where the composite equals the sequence.
    let id: UInt64
    let level: UInt8
    let subsystem: UInt8
    let timestampSecs: UInt32
    let filePath: String
    let text: String

    /// Raw backend sequence number for this entry (the low 32 bits of `id`).
    /// Resets to 1 on a backend restart; the generation in the high bits keeps
    /// `id` unique even when `seq` repeats.
    var seq: UInt32 { UInt32(id & 0xFFFF_FFFF) }

    /// Builds the restart-safe composite identity from a stream generation and
    /// a backend sequence number.
    static func makeID(generation: UInt32, seq: UInt32) -> UInt64 {
        (UInt64(generation) << 32) | UInt64(seq)
    }

    /// Compact timestamp as HH:MM:SS.
    var timestamp: String {
        let h = timestampSecs / 3600
        let m = (timestampSecs % 3600) / 60
        let s = timestampSecs % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    /// Human-readable level name.
    var levelName: String {
        switch level {
        case 0: return "DEBUG"
        case 1: return "INFO"
        case 2: return "WARN"
        case 3: return "ERROR"
        default: return "?"
        }
    }

    /// Human-readable subsystem name.
    var subsystemName: String {
        switch subsystem {
        case 0: return "EDITOR"
        case 1: return "LSP"
        case 2: return "PARSER"
        case 3: return "GIT"
        case 4: return "RENDER"
        case 5: return "AGENT"
        case 6: return "ZIG"
        case 7: return "GUI"
        default: return "?"
        }
    }

    /// Color for the level indicator dot.
    var levelColor: Color {
        switch level {
        case 0: return .gray
        case 1: return .green
        case 2: return .yellow
        case 3: return .red
        default: return .gray
        }
    }

    /// Color for the subsystem badge.
    var subsystemColor: Color {
        Self.subsystemColor(for: subsystem)
    }

    /// Static lookup for level color by ID (used by filter bar + severity summary).
    static func levelColor(for level: UInt8) -> Color {
        switch level {
        case 0: return .gray
        case 1: return .green
        case 2: return .yellow
        case 3: return .red
        default: return .gray
        }
    }

    /// Title-case level name for tooltips. Distinct from the instance `levelName`,
    /// which returns the uppercase badge form ("WARN"); the two formats serve
    /// different surfaces, so they are intentionally separate.
    static func levelTooltip(for level: UInt8) -> String {
        switch level {
        case 0: return "Debug"
        case 1: return "Info"
        case 2: return "Warning"
        case 3: return "Error"
        default: return "Unknown"
        }
    }

    /// Static lookup for subsystem name by ID (used by filter bar).
    static func subsystemName(for sub: UInt8) -> String {
        switch sub {
        case 0: return "EDITOR"
        case 1: return "LSP"
        case 2: return "PARSER"
        case 3: return "GIT"
        case 4: return "RENDER"
        case 5: return "AGENT"
        case 6: return "ZIG"
        case 7: return "GUI"
        default: return "?"
        }
    }

    /// Static lookup for subsystem color by ID (used by filter bar).
    static func subsystemColor(for sub: UInt8) -> Color {
        switch sub {
        case 0: return .blue        // EDITOR
        case 1: return .purple      // LSP
        case 2: return .orange      // PARSER
        case 3: return .green       // GIT
        case 4: return .cyan        // RENDER
        case 5: return .indigo      // AGENT
        case 6: return .teal        // ZIG
        case 7: return .pink        // GUI
        default: return .gray
        }
    }
}

@MainActor
@Observable
final class MessagesContentState {
    var entries: [MessageEntry] = []
    /// Whether the view should auto-scroll to the latest entry.
    var isAutoScrolling: Bool = true
    /// Set to true when new entries arrive while scrolled up (shows "jump to latest").
    var hasNewEntries: Bool = false

    // MARK: - Filters

    /// Active log levels. Default: info + warning + error (debug hidden).
    var activeLevels: Set<UInt8> = [1, 2, 3]
    /// Active subsystems. Default: all.
    var activeSubsystems: Set<UInt8> = [0, 1, 2, 3, 4, 5, 6, 7]
    /// Text search query (case-insensitive substring match).
    var searchText: String = ""

    /// All known subsystem IDs.
    static let allSubsystems: Set<UInt8> = [0, 1, 2, 3, 4, 5, 6, 7]
    /// Default active levels (info + warning + error).
    static let defaultLevels: Set<UInt8> = [1, 2, 3]

    /// Whether any filter is active (not at defaults).
    var isFiltering: Bool {
        activeLevels != Self.defaultLevels
            || activeSubsystems != Self.allSubsystems
            || !searchText.isEmpty
    }

    /// Entries after applying all filters.
    var filteredEntries: [MessageEntry] {
        let search = searchText.lowercased()
        return entries.filter { entry in
            activeLevels.contains(entry.level)
                && activeSubsystems.contains(entry.subsystem)
                && (search.isEmpty || entry.text.lowercased().contains(search))
        }
    }

    /// Toggle a level filter on/off.
    func toggleLevel(_ level: UInt8) {
        if activeLevels.contains(level) {
            activeLevels.remove(level)
        } else {
            activeLevels.insert(level)
        }
    }

    /// Toggle a subsystem filter on/off.
    func toggleSubsystem(_ sub: UInt8) {
        if activeSubsystems.contains(sub) {
            activeSubsystems.remove(sub)
        } else {
            activeSubsystems.insert(sub)
        }
    }

    /// Reset all filters to defaults.
    func resetFilters() {
        activeLevels = Self.defaultLevels
        activeSubsystems = Self.allSubsystems
        searchText = ""
    }

    /// Set of subsystem IDs that have at least one entry.
    var presentSubsystems: Set<UInt8> {
        Set(entries.map(\.subsystem))
    }

    /// Maximum entries to keep (matches BEAM-side cap).
    private let maxEntries = 1000

    /// Current stream generation. Bumped whenever an incoming backend sequence
    /// number is not greater than the last one seen, which happens when the BEAM
    /// backend restarts (sequence resets to 1) or resends earlier IDs.
    private var streamGeneration: UInt32 = 0
    /// The last backend sequence number appended, or nil before any entry.
    private var lastSeq: UInt32?
    /// Composite IDs currently present, for defensive dedupe (issue #2353).
    private var presentIDs: Set<UInt64> = []

    /// Append new entries from the protocol decoder.
    ///
    /// Each entry is given a restart-safe composite identity. When a backend
    /// sequence number does not advance (`raw.id <= lastSeq`), the stream
    /// generation is bumped so the repeated/reset sequence lands in a fresh
    /// namespace and never collides with an already-displayed row.
    func appendEntries(_ rawEntries: [Wire.MessageEntry]) {
        for raw in rawEntries {
            if let last = lastSeq, raw.id <= last {
                streamGeneration &+= 1
            }
            lastSeq = raw.id

            let id = MessageEntry.makeID(generation: streamGeneration, seq: raw.id)
            // Defensive dedupe: never emit a duplicate SwiftUI identity.
            if presentIDs.contains(id) { continue }

            let entry = MessageEntry(
                id: id,
                level: raw.level,
                subsystem: raw.subsystem,
                timestampSecs: raw.timestampSecs,
                filePath: raw.filePath,
                text: raw.text
            )
            entries.append(entry)
            presentIDs.insert(id)
        }
        // Trim to max, keeping the dedupe set in sync with the retained window.
        if entries.count > maxEntries {
            let overflow = entries.count - maxEntries
            for dropped in entries.prefix(overflow) { presentIDs.remove(dropped.id) }
            entries.removeFirst(overflow)
        }
        // Signal new entries for auto-scroll or "jump to latest"
        if !isAutoScrolling {
            hasNewEntries = true
        }
    }

    /// Called when user scrolls to bottom.
    func scrolledToBottom() {
        isAutoScrolling = true
        hasNewEntries = false
    }

    /// Called when user scrolls up.
    func scrolledUp() {
        isAutoScrolling = false
    }

    /// Jump to latest and re-enable auto-scroll.
    func jumpToLatest() {
        isAutoScrolling = true
        hasNewEntries = false
    }
}
