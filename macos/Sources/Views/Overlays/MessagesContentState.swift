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
        self.level = MessageLevel(rawValue: level)
        self.subsystem = MessageSubsystem(rawValue: subsystem)
        self.timestampSecs = timestampSecs
        self.filePath = filePath
        self.text = text
    }
    public init(id: UInt64, level: MessageLevel, subsystem: MessageSubsystem, timestampSecs: UInt32, filePath: String, text: String) {
        self.id = id
        self.level = level
        self.subsystem = subsystem
        self.timestampSecs = timestampSecs
        self.filePath = filePath
        self.text = text
    }
    /// Restart-safe composite identity: `(UInt64(streamInstance) << 32) | seq`.
    public let id: UInt64
    public let level: MessageLevel
    public let subsystem: MessageSubsystem
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
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        case .unknown: return "?"
        }
    }

    /// Human-readable subsystem name.
    public var subsystemName: String {
        switch subsystem {
        case .editor: return "EDITOR"
        case .lsp: return "LSP"
        case .parser: return "PARSER"
        case .git: return "GIT"
        case .render: return "RENDER"
        case .agent: return "AGENT"
        case .zig: return "ZIG"
        case .gui: return "GUI"
        case .unknown: return "?"
        }
    }

    /// Color for the level indicator dot.
    public var levelColor: Color {
        switch level {
        case .debug: return .gray
        case .info: return .green
        case .warning: return .yellow
        case .error: return .red
        case .unknown: return .gray
        }
    }

    /// Color for the subsystem badge.
    public var subsystemColor: Color {
        Self.subsystemColor(for: subsystem)
    }

    /// Static lookup for level color by ID (used by filter bar + severity summary).
    public static func levelColor(for level: MessageLevel) -> Color {
        switch level {
        case .debug: return .gray
        case .info: return .green
        case .warning: return .yellow
        case .error: return .red
        case .unknown: return .gray
        }
    }

    /// Title-case level name for tooltips. Distinct from the instance `levelName`,
    /// which returns the uppercase badge form ("WARN"); the two formats serve
    /// different surfaces, so they are intentionally separate.
    public static func levelTooltip(for level: MessageLevel) -> String {
        switch level {
        case .debug: return "Debug"
        case .info: return "Info"
        case .warning: return "Warning"
        case .error: return "Error"
        case .unknown: return "Unknown"
        }
    }

    /// Static lookup for subsystem name by ID (used by filter bar).
    public static func subsystemName(for sub: MessageSubsystem) -> String {
        switch sub {
        case .editor: return "EDITOR"
        case .lsp: return "LSP"
        case .parser: return "PARSER"
        case .git: return "GIT"
        case .render: return "RENDER"
        case .agent: return "AGENT"
        case .zig: return "ZIG"
        case .gui: return "GUI"
        case .unknown: return "?"
        }
    }

    /// Static lookup for subsystem color by ID (used by filter bar).
    public static func subsystemColor(for sub: MessageSubsystem) -> Color {
        switch sub {
        case .editor: return .blue
        case .lsp: return .purple
        case .parser: return .orange
        case .git: return .green
        case .render: return .cyan
        case .agent: return .indigo
        case .zig: return .teal
        case .gui: return .pink
        case .unknown: return .gray
        }
    }
}

@MainActor
@Observable
public final class MessagesContentState {
    public init(entries: [MessageEntry] = [], isAutoScrolling: Bool = true, hasNewEntries: Bool = false, activeLevels: Set<MessageLevel> = [.info, .warning, .error], activeSubsystems: Set<MessageSubsystem> = [.editor, .lsp, .parser, .git, .render, .agent, .zig, .gui], searchText: String = "") {
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
    public var activeLevels: Set<MessageLevel> = [.info, .warning, .error]
    /// Active subsystems. Default: all.
    public var activeSubsystems: Set<MessageSubsystem> = [.editor, .lsp, .parser, .git, .render, .agent, .zig, .gui]
    /// Text search query (case-insensitive substring match).
    public var searchText: String = ""

    /// All known subsystem IDs.
    public static let allSubsystems: Set<MessageSubsystem> = [.editor, .lsp, .parser, .git, .render, .agent, .zig, .gui]
    /// Default active levels (info + warning + error).
    public static let defaultLevels: Set<MessageLevel> = [.info, .warning, .error]

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
    public func toggleLevel(_ level: MessageLevel) {
        if activeLevels.contains(level) {
            activeLevels.remove(level)
        } else {
            activeLevels.insert(level)
        }
    }

    /// Toggle a subsystem filter on/off.
    public func toggleSubsystem(_ sub: MessageSubsystem) {
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
    public var presentSubsystems: Set<MessageSubsystem> {
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
