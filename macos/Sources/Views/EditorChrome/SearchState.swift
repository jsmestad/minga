/// Observable search toolbar state driven by BEAM gui_search_state messages (0x9E).
///
/// Holds all state needed to render the native SwiftUI find/replace toolbar:
/// visibility, match count, current match index, and search option flags.
/// Updated by CommandDispatcher when a guiSearchState command arrives.

import SwiftUI

public enum SearchFlags {
    public static let replaceMode: UInt8 = 0x01
    public static let caseSensitive: UInt8 = 0x02
    public static let wholeWord: UInt8 = 0x04
    public static let regex: UInt8 = 0x08
}

@MainActor
@Observable
public final class SearchState {
    public init(visible: Bool = false, matchCount: UInt16 = 0, currentIndex: UInt16 = 0, replaceMode: Bool = false, caseSensitive: Bool = false, wholeWord: Bool = false, regex: Bool = false) {
        self.visible = visible
        self.matchCount = matchCount
        self.currentIndex = currentIndex
        self.replaceMode = replaceMode
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.regex = regex
    }
    /// Whether the search toolbar is visible.
    public var visible: Bool = false

    /// Total number of matches for the current query.
    public var matchCount: UInt16 = 0

    /// 1-based index of the currently highlighted match (0 when no matches).
    public var currentIndex: UInt16 = 0

    /// Whether replace mode is active (shows the replace row).
    public var replaceMode: Bool = false

    /// Whether the search is case-sensitive.
    public var caseSensitive: Bool = false

    /// Whether the search matches whole words only.
    public var wholeWord: Bool = false

    /// Whether the search query is a regular expression.
    public var regex: Bool = false

    /// Updates the search state from a BEAM gui_search_state command.
    ///
    /// The flags byte encodes boolean options as individual bits:
    /// - Bit 0 (0x01): replace_mode
    /// - Bit 1 (0x02): case_sensitive
    /// - Bit 2 (0x04): whole_word
    /// - Bit 3 (0x08): regex
    public func update(active: Bool, matchCount: UInt16, currentIndex: UInt16, flags: UInt8) {
        self.visible = active
        self.matchCount = matchCount
        self.currentIndex = currentIndex
        self.replaceMode = flags & SearchFlags.replaceMode != 0
        self.caseSensitive = flags & SearchFlags.caseSensitive != 0
        self.wholeWord = flags & SearchFlags.wholeWord != 0
        self.regex = flags & SearchFlags.regex != 0
    }

    /// Hides the search toolbar and resets match counters to avoid stale display on re-open.
    public func hide() {
        visible = false
        matchCount = 0
        currentIndex = 0
    }
}
