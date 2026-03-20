/// Observable state for the Messages tab content.
///
/// Accumulates structured log entries from the BEAM and tracks scroll
/// position for auto-scroll behavior.

import SwiftUI

/// A rendered message entry for display in the Messages tab.
struct MessageEntry: Identifiable, Equatable {
    let id: UInt32
    let level: UInt8
    let subsystem: UInt8
    let timestampSecs: UInt32
    let filePath: String
    let text: String

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

    /// Append new entries from the protocol decoder.
    func appendEntries(_ rawEntries: [GUIMessageEntry]) {
        for raw in rawEntries {
            let entry = MessageEntry(
                id: raw.id,
                level: raw.level,
                subsystem: raw.subsystem,
                timestampSecs: raw.timestampSecs,
                filePath: raw.filePath,
                text: raw.text
            )
            entries.append(entry)
        }
        // Trim to max
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
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
