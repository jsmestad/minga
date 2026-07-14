/// Observable state for the Messages tab content.
///
/// Accumulates structured log entries from the BEAM and tracks scroll
/// position for auto-scroll behavior.

import SwiftUI
import MingaProtocol

/// A rendered message entry for display in the Messages tab.
///
/// SwiftUI identity is `id`, a `(streamInstance, seq)` composite carried by the wire contract, NOT the raw backend sequence number (`seq`).
public struct MessageEntry: Identifiable, Equatable {
    public init(id: UInt64, level: UInt8, subsystem: UInt8, timestampSecs: UInt32, filePath: String, text: String) {
        self.id = id
        self.level = level
        self.subsystem = subsystem
        self.timestampSecs = timestampSecs
        self.filePath = filePath
        self.text = text
    }
    /// Restart-safe composite identity: `(UInt64(streamInstance) << 32) | seq`.
    public let id: UInt64
    public let level: UInt8
    public let subsystem: UInt8
    public let timestampSecs: UInt32
    public let filePath: String
    public let text: String

    /// Raw backend sequence number for this entry (the low 32 bits of `id`).
    public var seq: UInt32 { UInt32(id & 0xFFFF_FFFF) }

    /// Builds the restart-safe composite identity from a producer stream instance and a backend sequence number.
    public static func makeID(streamInstance: UInt32, seq: UInt32) -> UInt64 {
        (UInt64(streamInstance) << 32) | UInt64(seq)
    }

    /// Compact timestamp as HH:MM:SS.
    public var timestamp: String {
        let h = timestampSecs / 3600
        let m = (timestampSecs % 3600) / 60
        let s = timestampSecs % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    /// Human-readable level name.
    public var levelName: String {
        switch level {
        case 0: return "DEBUG"
        case 1: return "INFO"
        case 2: return "WARN"
        case 3: return "ERROR"
        default: return "?"
        }
    }

    /// Human-readable subsystem name.
    public var subsystemName: String {
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
    public var levelColor: Color {
        switch level {
        case 0: return .gray
        case 1: return .green
        case 2: return .yellow
        case 3: return .red
        default: return .gray
        }
    }

    /// Color for the subsystem badge.
    public var subsystemColor: Color {
        Self.subsystemColor(for: subsystem)
    }

    /// Static lookup for level color by ID (used by filter bar + severity summary).
    public static func levelColor(for level: UInt8) -> Color {
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
    public static func levelTooltip(for level: UInt8) -> String {
        switch level {
        case 0: return "Debug"
        case 1: return "Info"
        case 2: return "Warning"
        case 3: return "Error"
        default: return "Unknown"
        }
    }

    /// Static lookup for subsystem name by ID (used by filter bar).
    public static func subsystemName(for sub: UInt8) -> String {
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
    public static func subsystemColor(for sub: UInt8) -> Color {
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
public final class MessagesContentState {
    public init(entries: [MessageEntry] = [], isAutoScrolling: Bool = true, hasNewEntries: Bool = false, activeLevels: Set<UInt8> = [1, 2, 3], activeSubsystems: Set<UInt8> = [0, 1, 2, 3, 4, 5, 6, 7], searchText: String = "") {
        self.entries = entries
        self.isAutoScrolling = isAutoScrolling
        self.hasNewEntries = hasNewEntries
        self.activeLevels = activeLevels
        self.activeSubsystems = activeSubsystems
        self.searchText = searchText
    }
    public var entries: [MessageEntry] = []
    /// Whether the view should auto-scroll to the latest entry.
    public var isAutoScrolling: Bool = true
    /// Set to true when new entries arrive while scrolled up (shows "jump to latest").
    public var hasNewEntries: Bool = false

    // MARK: - Filters

    /// Active log levels. Default: info + warning + error (debug hidden).
    public var activeLevels: Set<UInt8> = [1, 2, 3]
    /// Active subsystems. Default: all.
    public var activeSubsystems: Set<UInt8> = [0, 1, 2, 3, 4, 5, 6, 7]
    /// Text search query (case-insensitive substring match).
    public var searchText: String = ""

    /// All known subsystem IDs.
    public static let allSubsystems: Set<UInt8> = [0, 1, 2, 3, 4, 5, 6, 7]
    /// Default active levels (info + warning + error).
    public static let defaultLevels: Set<UInt8> = [1, 2, 3]

    /// Whether any filter is active (not at defaults).
    public var isFiltering: Bool {
        activeLevels != Self.defaultLevels
            || activeSubsystems != Self.allSubsystems
            || !searchText.isEmpty
    }

    /// Entries after applying all filters.
    public var filteredEntries: [MessageEntry] {
        let search = searchText.lowercased()
        return entries.filter { entry in
            activeLevels.contains(entry.level)
                && activeSubsystems.contains(entry.subsystem)
                && (search.isEmpty || entry.text.lowercased().contains(search))
        }
    }

    /// Toggle a level filter on/off.
    public func toggleLevel(_ level: UInt8) {
        if activeLevels.contains(level) {
            activeLevels.remove(level)
        } else {
            activeLevels.insert(level)
        }
    }

    /// Toggle a subsystem filter on/off.
    public func toggleSubsystem(_ sub: UInt8) {
        if activeSubsystems.contains(sub) {
            activeSubsystems.remove(sub)
        } else {
            activeSubsystems.insert(sub)
        }
    }

    /// Reset all filters to defaults.
    public func resetFilters() {
        activeLevels = Self.defaultLevels
        activeSubsystems = Self.allSubsystems
        searchText = ""
    }

    /// Set of subsystem IDs that have at least one entry.
    public var presentSubsystems: Set<UInt8> {
        Set(entries.map(\.subsystem))
    }

    /// Maximum entries to keep (matches BEAM-side cap).
    private let maxEntries = 1000

    /// Append new entries from the protocol decoder.
    public func appendEntries(_ rawEntries: [Wire.MessageEntry]) {
        for raw in rawEntries {
            let entry = MessageEntry(
                id: MessageEntry.makeID(streamInstance: raw.streamInstance, seq: raw.id),
                level: raw.level,
                subsystem: raw.subsystem,
                timestampSecs: raw.timestampSecs,
                filePath: raw.filePath,
                text: raw.text
            )
            entries.append(entry)
        }
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        // Signal new entries for auto-scroll or "jump to latest"
        if !isAutoScrolling {
            hasNewEntries = true
        }
    }

    /// Called when user scrolls to bottom.
    public func scrolledToBottom() {
        isAutoScrolling = true
        hasNewEntries = false
    }

    /// Called when user scrolls up.
    public func scrolledUp() {
        isAutoScrolling = false
    }

    /// Jump to latest and re-enable auto-scroll.
    public func jumpToLatest() {
        isAutoScrolling = true
        hasNewEntries = false
    }
}
